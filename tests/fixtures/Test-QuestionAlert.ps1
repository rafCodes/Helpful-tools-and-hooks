param(
    [switch]$SoundFailure,
    [switch]$NameFailure,
    [ValidateSet('question', 'compaction')][string]$Kind = 'question'
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($env:COPILOT_PLUGIN_DATA)) {
    throw 'Run tests\Test-Hooks.ps1. The renderer fixture requires its isolated test directory.'
}
$testLogDir = [System.IO.Path]::GetFullPath($env:COPILOT_PLUGIN_DATA)
$testParentName = [System.IO.Path]::GetFileName([System.IO.Path]::GetDirectoryName($testLogDir))
if ($testParentName -notmatch '^helpful-hooks-test-[0-9a-f]{32}$' -or
    -not (Test-Path -LiteralPath $testLogDir -PathType Container)) {
    throw 'Run tests\Test-Hooks.ps1. The renderer fixture must not use real plugin data.'
}
$env:COPILOT_HOME = Join-Path $testLogDir 'copilot-home'

. "$PSScriptRoot\..\..\hooks\QuestionAlert.Common.ps1"
$sessionId = '11111111-1111-1111-1111-111111111111'
$codePrefix = if ($Kind -eq 'compaction') { 'compaction_alert' } else { 'question_alert' }
$fixtureExpectedSessionName = 'Compaction test <name> & "quotes"'
foreach ($fixtureId in @($sessionId, '22222222-2222-2222-2222-222222222222', '33333333-3333-3333-3333-333333333333')) {
    $directory = Join-Path $env:COPILOT_HOME "session-state\$fixtureId"
    [void][System.IO.Directory]::CreateDirectory($directory)
    $name = if ($fixtureId -eq $sessionId) { $fixtureExpectedSessionName } else { 'Long name ' * 51 }
    [System.IO.File]::WriteAllText(
        (Join-Path $directory 'workspace.yaml'),
        ("id: $fixtureId`nname: " + ($name | ConvertTo-Json -Compress) + "`n")
    )
}

Add-Type -Namespace CopilotQuestionAlertTest -Name Native -MemberDefinition @'
[DllImport("user32.dll")]
public static extern int GetWindowLong(System.IntPtr window, int index);

[DllImport("user32.dll")]
public static extern System.IntPtr GetWindow(System.IntPtr window, uint command);

[DllImport("user32.dll")]
public static extern System.IntPtr SendMessage(
    System.IntPtr window, uint message, System.IntPtr wParam, System.IntPtr lParam);

[DllImport("user32.dll")]
[return: MarshalAs(UnmanagedType.Bool)]
public static extern bool IsWindowVisible(System.IntPtr window);

'@ -ErrorAction Stop

$window = $null
$fixtureContent = $null
$cover = $null
$player = $null
$watchdog = $null
$raiseTimer = $null
$verifyTimer = $null
$coexistTimer = $null
$coexistWindows = [System.Collections.Generic.List[object]]::new()
$fixtureCoordination = $null
$coordinationId = [guid]::NewGuid()
$signalProcesses = [System.Collections.Generic.List[object]]::new()
$layoutPeers = [System.Collections.Generic.List[object]]::new()
$elapsed = [System.Diagnostics.Stopwatch]::new()
$fixtureState = [pscustomobject]@{ Rendered = $false; Failure = $null }
$admittedOverflowChecked = $false

function Test-FixtureWindowVisibleAndTransparent {
    param([System.Windows.Window]$Window)

    $handle = [System.Windows.Interop.WindowInteropHelper]::new($Window).Handle
    if (-not [CopilotQuestionAlertTest.Native]::IsWindowVisible($handle)) {
        throw 'The hidden child did not show its native WPF window.'
    }
    if (-not $Window.AllowsTransparency -or $Window.Opacity -ne 0 -or
        $Window.WindowStyle -ne [System.Windows.WindowStyle]::None -or
        ([CopilotQuestionAlertTest.Native]::GetWindowLong($handle, -20) -band 0x00080000) -eq 0) {
        throw 'The fixture window is not fully transparent.'
    }
}

function Stop-FixtureSignalProcesses {
    foreach ($child in $signalProcesses) {
        if (-not $child.Process.HasExited) {
            Stop-Process -Id $child.Process.Id -Force
            [void]$child.Process.WaitForExit(5000)
        }
    }
}

function Stop-FixtureLayoutPeers {
    foreach ($peer in $layoutPeers) { [void]$peer.Stop.Set() }
    foreach ($peer in $layoutPeers) {
        if (-not $peer.Process.WaitForExit(5000)) {
            Stop-Process -Id $peer.Process.Id -Force
            [void]$peer.Process.WaitForExit(5000)
        }
    }
}

function Test-FixtureWindowAbove {
    param([IntPtr]$Upper, [IntPtr]$Lower)

    $next = [CopilotQuestionAlertTest.Native]::GetWindow($Upper, 2)
    for ($i = 0; $i -lt 10000 -and $next -ne [IntPtr]::Zero -and $next -ne $Lower; $i++) {
        $next = [CopilotQuestionAlertTest.Native]::GetWindow($next, 2)
    }
    return $next -eq $Lower
}

function Test-FixtureAlertCoexistence {
    $allWindows = @($script:window) + @($script:coexistWindows.ToArray())
    $handles = @(
        foreach ($item in $allWindows) {
            Test-FixtureWindowVisibleAndTransparent -Window $item
            $handle = [System.Windows.Interop.WindowInteropHelper]::new($item).Handle
            $bounds = [CopilotQuestionAlert.Native+Bounds]::new()
            if (-not [CopilotQuestionAlert.Native]::GetWindowRect($handle, [ref]$bounds)) {
                throw 'A coexistence window has no native bounds.'
            }
            $area = [System.Windows.Forms.Screen]::FromHandle($handle).WorkingArea
            if ($bounds.Left -lt $area.Left -or $bounds.Top -lt $area.Top -or
                $bounds.Right -gt $area.Right -or $bounds.Bottom -gt $area.Bottom) {
                throw "A $($item.Tag) alert is outside the monitor work area: bounds=$($bounds.Left),$($bounds.Top),$($bounds.Right),$($bounds.Bottom); area=$($area.Left),$($area.Top),$($area.Right),$($area.Bottom)."
            }
            if ($item.Tag -eq 'compaction') {
                foreach ($controlName in @('SessionId', 'Dismiss')) {
                    $control = $item.FindName($controlName)
                    $start = $control.PointToScreen([System.Windows.Point]::new(0, 0))
                    $end = $control.PointToScreen([System.Windows.Point]::new($control.ActualWidth, $control.ActualHeight))
                    if ($start.Y -lt $bounds.Top -or $end.Y -gt $bounds.Bottom -or $end.X -gt $bounds.Right) {
                        throw 'A compaction alert hid its session ID or Dismiss control.'
                    }
                }
            }
            $handle
        }
        [CopilotQuestionAlert.Native]::GetCompactionWindows('CopilotHelpfulToolsAlert-fixture-layout-' + $script:coordinationId.ToString('N'))
    ) | Sort-Object { $_.ToInt64() } -Unique
    $rectangles = @(
        foreach ($handle in $handles) {
            $bounds = [CopilotQuestionAlert.Native+Bounds]::new()
            if (-not [CopilotQuestionAlertTest.Native]::IsWindowVisible($handle) -or
                -not [CopilotQuestionAlert.Native]::GetWindowRect($handle, [ref]$bounds)) {
                throw 'A separate-process compaction alert is not visible.'
            }
            $area = [System.Windows.Forms.Screen]::FromHandle($handle).WorkingArea
            if ($bounds.Left -lt $area.Left -or $bounds.Top -lt $area.Top -or
                $bounds.Right -gt $area.Right -or $bounds.Bottom -gt $area.Bottom) {
                throw 'A separate-process compaction alert is outside the monitor work area.'
            }
            $bounds
        }
    )
    for ($i = 0; $i -lt $rectangles.Count; $i++) {
        for ($j = $i + 1; $j -lt $rectangles.Count; $j++) {
            if ($rectangles[$i].Left -lt $rectangles[$j].Right -and $rectangles[$j].Left -lt $rectangles[$i].Right -and
                $rectangles[$i].Top -lt $rectangles[$j].Bottom -and $rectangles[$j].Top -lt $rectangles[$i].Bottom) {
                throw 'Concurrent question and compaction alerts overlap.'
            }
        }
    }
    $foreground = [CopilotQuestionAlert.Native]::GetForegroundWindow()
    foreach ($item in $allWindows) {
        if ([System.Windows.Interop.WindowInteropHelper]::new($item).Handle -eq $foreground) {
            throw 'An alert took keyboard focus during coexistence.'
        }
    }
}

function Test-FixtureRejectedAdmission {
    $existing = @($script:window) + @($script:coexistWindows.ToArray())
    $script:admissionPeer = @($existing | Where-Object Tag -EQ 'compaction')[0]
    $area = [System.Windows.Forms.Screen]::FromHandle(
        [System.Windows.Interop.WindowInteropHelper]::new($script:admissionPeer).Handle
    ).WorkingArea
    $script:admissionCandidate = New-QuestionAlertContent -Kind compaction -SessionId '33333333-3333-3333-3333-333333333333'
    $script:admissionCandidate.Width = $area.Width * 2
    $script:admissionCandidate.WindowStyle = [System.Windows.WindowStyle]::None
    $script:admissionCandidate.AllowsTransparency = $true
    $script:admissionCandidate.Opacity = 0
    $script:simulateAdmissionPeer = $true
    $script:admissionPeerWorked = $false

    function New-FixtureAdmissionContent { return $script:admissionCandidate }
    function Move-FixtureAdmissionToMonitor {
        param([System.Windows.Window]$Window)
        $screen = [System.Windows.Forms.Screen]::FromHandle(
            [System.Windows.Interop.WindowInteropHelper]::new($script:admissionPeer).Handle
        )
        Set-CompactionAlertLayout -Window $Window -Screen $screen
    }
    function Wait-FixtureAdmissionMutex {
        param([System.Threading.Mutex]$Mutex, [int]$TimeoutMilliseconds)

        if ($script:simulateAdmissionPeer) {
            $script:simulateAdmissionPeer = $false
            $handle = [System.Windows.Interop.WindowInteropHelper]::new($script:admissionCandidate).Handle
            $propertyName = 'CopilotHelpfulToolsAlert-fixture-layout-' + $script:coordinationId.ToString('N')
            if ([CopilotQuestionAlert.Native]::GetProp($handle, $propertyName) -eq [IntPtr]::new(2)) {
                throw 'The newcomer was published before admission acquired its mutex.'
            }
            Set-QuestionAlertTopmost -Window $script:admissionPeer
            $script:admissionPeerWorked = $true
        }
        try { return $Mutex.WaitOne($TimeoutMilliseconds) } catch [System.Threading.AbandonedMutexException] { return $true }
    }

    Remove-Item -LiteralPath 'Alias:\New-QuestionAlertWindow'
    Set-Alias -Name New-QuestionAlertContent -Value New-FixtureAdmissionContent
    Set-Alias -Name Wait-QuestionAlertMutex -Value Wait-FixtureAdmissionMutex
    Set-Alias -Name Move-QuestionAlertToActiveMonitor -Value Move-FixtureAdmissionToMonitor
    $rejected = $false
    try {
        $unexpected = New-QuestionAlertWindow -Kind compaction -SessionId '33333333-3333-3333-3333-333333333333'
        $unexpected.Close()
    } catch {
        if ($_.Exception.Message -cne 'The compaction alerts do not fit in the monitor work area.') { throw }
        $rejected = $true
    } finally {
        Remove-Item -LiteralPath 'Alias:\New-QuestionAlertContent'
        Remove-Item -LiteralPath 'Alias:\Wait-QuestionAlertMutex'
        Remove-Item -LiteralPath 'Alias:\Move-QuestionAlertToActiveMonitor'
        Set-Alias -Name New-QuestionAlertWindow -Value New-FixtureQuestionAlertWindow -Scope Script
        $script:admissionCandidate.Close()
    }
    if (-not $rejected -or -not $script:admissionPeerWorked) {
        throw 'The overflow request did not preserve peer reflow during admission.'
    }
    foreach ($item in $existing) {
        if (-not $item.IsVisible) { throw 'Rejecting a new alert closed an existing alert.' }
    }
    Test-FixtureAlertCoexistence
}

function Test-FixtureAdmittedOverflow {
    $cards = @($script:coexistWindows | Where-Object Tag -EQ 'compaction')
    $card = $cards[0]
    $peer = $cards[1]
    $handle = [System.Windows.Interop.WindowInteropHelper]::new($card).Handle
    $screen = [System.Windows.Forms.Screen]::FromHandle($handle)
    $area = $screen.WorkingArea
    $source = [System.Windows.Interop.HwndSource]::FromHwnd($handle)
    $originalWidth = $peer.Width
    $originalLeft = $peer.Left
    $logPath = Join-Path $script:testLogDir 'hooks.log'
    $before = @(Get-Content -LiteralPath $logPath | ForEach-Object { $_ | ConvertFrom-Json })
    try {
        $peer.Width = ($area.Width * 2) / $source.CompositionTarget.TransformToDevice.M11
        $peer.Left = $source.CompositionTarget.TransformFromDevice.Transform(
            [System.Windows.Point]::new(($area.Left - $area.Width / 2), $area.Top)
        ).X
        $card.Top = $source.CompositionTarget.TransformFromDevice.Transform(
            [System.Windows.Point]::new($area.Left, ($area.Bottom - 150 * $source.CompositionTarget.TransformToDevice.M22))
        ).Y
        $state = [pscustomobject]@{
            Kind = 'compaction'
            SessionId = $card.FindName('SessionId').Text.Substring('Session ID: '.Length)
            SoundFailed = $false
        }
        Invoke-QuestionAlertRepeat -Window $card -Player $script:player -State $state
        Invoke-QuestionAlertRepeat -Window $card -Player $script:player -State $state
        $after = @(Get-Content -LiteralPath $logPath | ForEach-Object { $_ | ConvertFrom-Json })
        if (-not $card.IsVisible -or [System.Windows.Forms.Screen]::FromHandle($handle).DeviceName -cne $screen.DeviceName -or
            (@($after | Where-Object code -EQ 'compaction_alert_layout_failed').Count -
                @($before | Where-Object code -EQ 'compaction_alert_layout_failed').Count) -ne 1 -or
            (@($after | Where-Object code -EQ 'compaction_alert_replayed').Count -
                @($before | Where-Object code -EQ 'compaction_alert_replayed').Count) -lt 2) {
            throw 'An admitted card did not survive, stay on its monitor, and replay after overflow.'
        }
        $bounds = [CopilotQuestionAlert.Native+Bounds]::new()
        if (-not [CopilotQuestionAlert.Native]::GetWindowRect($handle, [ref]$bounds) -or
            $bounds.Top -lt $area.Top -or $bounds.Bottom -gt $area.Bottom) {
            throw 'An admitted card was not clamped back into view.'
        }
        $peer.Width = $originalWidth
        $peer.Left = $originalLeft
        Set-QuestionAlertTopmost -Window $card
        $peer.Width = ($area.Width * 2) / $source.CompositionTarget.TransformToDevice.M11
        $peer.Left = $source.CompositionTarget.TransformFromDevice.Transform(
            [System.Windows.Point]::new(($area.Left - $area.Width / 2), $area.Top)
        ).X
        Invoke-QuestionAlertRepeat -Window $card -Player $script:player -State $state
        $recovered = @(Get-Content -LiteralPath $logPath | ForEach-Object { $_ | ConvertFrom-Json })
        if ((@($recovered | Where-Object code -EQ 'compaction_alert_layout_failed').Count -
            @($before | Where-Object code -EQ 'compaction_alert_layout_failed').Count) -ne 2) {
            throw 'Layout failure logging did not reset after recovery.'
        }
        $script:admittedOverflowChecked = $true
    } finally {
        $peer.Width = $originalWidth
        $peer.Left = $originalLeft
        Set-QuestionAlertTopmost -Window $card
    }
    Test-FixtureAlertCoexistence
}

try {
    $standardCoordination = $null
    $administratorCoordination = $null
    $fixtureSecurityScope = 'fixture-standard'
    function Get-FixtureQuestionAlertScope { return $script:fixtureSecurityScope }
    Set-Alias -Name Get-QuestionAlertScope -Value Get-FixtureQuestionAlertScope
    try {
        $scopeTestPrefix = 'Local\CopilotHelpfulToolsQuestionAlertScopeTest-' + $coordinationId.ToString('N')
        $standardCoordination = New-QuestionAlertCoordination -NamePrefix $scopeTestPrefix
        $fixtureSecurityScope = 'fixture-administrator'
        $administratorCoordination = New-QuestionAlertCoordination -NamePrefix $scopeTestPrefix
        [void]$standardCoordination.Signal.Set()
        if ($administratorCoordination.Signal.WaitOne(0) -or -not $standardCoordination.Signal.WaitOne(0)) {
            throw 'The question alert coordination crossed security scopes.'
        }
    } finally {
        Remove-Item -LiteralPath 'Alias:\Get-QuestionAlertScope'
        foreach ($item in @($standardCoordination, $administratorCoordination)) {
            if ($item) {
                $item.Signal.Dispose()
                $item.Owner.Dispose()
                $item.Gate.Dispose()
            }
        }
    }

    $fixtureCoordination = New-QuestionAlertCoordination -NamePrefix (
        'Local\CopilotHelpfulToolsQuestionAlertTest-' + $coordinationId.ToString('N')
    )
    function Get-FixtureLayoutScope { return ('fixture-layout-' + $script:coordinationId.ToString('N')) }
    Set-Alias -Name Get-QuestionAlertScope -Value Get-FixtureLayoutScope
    $fixtureContent = New-QuestionAlertContent -Kind $Kind -SessionId ("`n" + $sessionId + "`n")
    $fixtureContent.WindowStyle = [System.Windows.WindowStyle]::None
    $fixtureContent.AllowsTransparency = $true
    $fixtureContent.Opacity = 0
    function New-FixtureQuestionAlertContent { return $script:fixtureContent }
    Set-Alias -Name New-QuestionAlertContent -Value New-FixtureQuestionAlertContent
    $window = New-QuestionAlertWindow -Kind $Kind -SessionId $sessionId
    $expectedTitle = if ($Kind -eq 'compaction') { 'Copilot CLI - compacting' } else { 'Copilot CLI - question' }
    if (-not $window.Topmost -or $window.ShowActivated -or $window.ShowInTaskbar -or
        $window.Title -cne $expectedTitle -or
        $window.FindName('Dismiss').Content -cne 'Dismiss') {
        throw 'The question alert has incorrect visibility, focus, or content settings.'
    }
    if ($Kind -eq 'compaction' -and ($window.FindName('Heading').Text -cne 'Copilot is compacting' -or
        $window.FindName('Message').Text -cne "Session: $fixtureExpectedSessionName" -or
        $window.FindName('SessionId').Text -cne "Session ID: $sessionId")) {
        throw 'The compaction alert did not render its session identity as literal text.'
    }
    Remove-Item -LiteralPath 'Alias:\New-QuestionAlertContent'
    $auxiliaryKinds = if ($Kind -eq 'question') { @('compaction', 'compaction') } else { @('question', 'compaction') }
    for ($i = 0; $i -lt $auxiliaryKinds.Count; $i++) {
        $auxiliaryId = if ($i -eq 0) { '22222222-2222-2222-2222-222222222222' } else { '33333333-3333-3333-3333-333333333333' }
        $fixtureAuxiliaryContent = New-QuestionAlertContent -Kind $auxiliaryKinds[$i] -SessionId $auxiliaryId
        $fixtureAuxiliaryContent.WindowStyle = [System.Windows.WindowStyle]::None
        $fixtureAuxiliaryContent.AllowsTransparency = $true
        $fixtureAuxiliaryContent.Opacity = 0
        function New-FixtureAuxiliaryContent { return $script:fixtureAuxiliaryContent }
        Set-Alias -Name New-QuestionAlertContent -Value New-FixtureAuxiliaryContent
        $auxiliaryWindow = New-QuestionAlertWindow -Kind $auxiliaryKinds[$i] -SessionId $auxiliaryId
        $auxiliaryWindow.Add_ContentRendered({ Set-QuestionAlertTopmost -Window $auxiliaryWindow }.GetNewClosure())
        $coexistWindows.Add($auxiliaryWindow)
        Remove-Item -LiteralPath 'Alias:\New-QuestionAlertContent'
    }
    $coexistTimer = [System.Windows.Threading.DispatcherTimer]::new()
    $coexistTimer.Interval = [TimeSpan]::FromSeconds(1)
    $coexistTimer.Add_Tick({
        try {
            foreach ($item in $coexistWindows) { Set-QuestionAlertTopmost -Window $item }
        } catch {
            $fixtureState.Failure = $_
            $window.Close()
        }
    })

    if (-not $SoundFailure) {
        $player = New-QuestionAlertPlayer
        $expectedSound = Join-Path $env:SystemRoot 'Media\Windows Background.wav'
        if ($player.Volume -ne 0.75 -or $player.Source.LocalPath -cne $expectedSound) {
            throw 'The question alert does not use the soft notification tone at 75% player volume.'
        }
        $player.IsMuted = $true
    }

    $cover = [System.Windows.Window]::new()
    $cover.WindowStyle = [System.Windows.WindowStyle]::None
    $cover.AllowsTransparency = $true
    $cover.Opacity = 0
    $cover.Topmost = $true
    $cover.ShowActivated = $false
    $cover.ShowInTaskbar = $false
    $screen = [System.Windows.Forms.Screen]::FromHandle([CopilotQuestionAlert.Native]::GetForegroundWindow())
    $source = [System.Windows.Interop.HwndSource]::FromHwnd(
        [System.Windows.Interop.WindowInteropHelper]::new($window).Handle
    )
    $bounds = [System.Windows.Rect]::Transform(
        [System.Windows.Rect]::new($screen.Bounds.Left, $screen.Bounds.Top, $screen.Bounds.Width, $screen.Bounds.Height),
        $source.CompositionTarget.TransformFromDevice
    )
    $cover.Left = $bounds.Left
    $cover.Top = $bounds.Top
    $cover.Width = $bounds.Width
    $cover.Height = $bounds.Height

    $verifyTimer = [System.Windows.Threading.DispatcherTimer]::new()
    $verifyTimer.Interval = [TimeSpan]::FromMilliseconds(100)
    $verifyTimer.Add_Tick({
        try {
            if ($elapsed.ElapsedMilliseconds -lt 1500) { return }
            foreach ($child in $signalProcesses) {
                if (-not $child.Process.HasExited) { return }
                $child.Process.WaitForExit()
                $child.Process.Refresh()
                [string]$childOutput = Get-Content -LiteralPath $child.Stdout -Raw
                [string]$childError = Get-Content -LiteralPath $child.Stderr -Raw
                if ($child.Process.ExitCode -ne 0 -or $childOutput.Trim() -cne "PASS $Kind alert reuse checks" -or
                    $childError.Length -ne 0) {
                    throw "A repeat notification did not reuse the alert (exit $($child.Process.ExitCode)): $childOutput $childError"
                }
                foreach ($peer in $layoutPeers) {
                    if ($peer.Process.HasExited) {
                        throw "A layout peer exited early: $(Get-Content -LiteralPath $peer.Stderr -Raw)"
                    }
                }
                $peerWindows = @([CopilotQuestionAlert.Native]::GetCompactionWindows(
                    'CopilotHelpfulToolsAlert-fixture-layout-' + $coordinationId.ToString('N')
                ))
                if ($peerWindows.Count -lt 4 -or @($peerWindows | Where-Object {
                    -not [CopilotQuestionAlertTest.Native]::IsWindowVisible($_)
                }).Count -ne 0) { return }
            }
            $results = @(Get-Content -LiteralPath (Join-Path $testLogDir 'hooks.log') | ForEach-Object {
                $_ | ConvertFrom-Json
            })
            if (-not $SoundFailure -and ($codePrefix + '_replayed') -notin $results.code) { return }
            $expectedMessage = if ($NameFailure) { 'Session name unavailable' } else { "Session: $fixtureExpectedSessionName" }
            if ($Kind -eq 'compaction' -and ($window.FindName('Message').Text -cne $expectedMessage -or
                $window.FindName('SessionId').Text -cne "Session ID: $sessionId")) {
                throw 'A repeated compaction did not refresh its name or preserve the full ID.'
            }
            $verifyTimer.Stop()
            $handle = [System.Windows.Interop.WindowInteropHelper]::new($window).Handle
            $coverHandle = [System.Windows.Interop.WindowInteropHelper]::new($cover).Handle
            Test-FixtureWindowVisibleAndTransparent -Window $window
            Test-FixtureWindowVisibleAndTransparent -Window $cover
            $extendedStyle = [CopilotQuestionAlertTest.Native]::GetWindowLong($handle, -20)
            if (($extendedStyle -band 0x0008) -eq 0 -or ($extendedStyle -band 0x08000000) -eq 0) {
                throw 'The question alert is not a native non-activating topmost window.'
            }
            $foreground = [CopilotQuestionAlert.Native]::GetForegroundWindow()
            if ($foreground -eq $handle -or $foreground -eq $coverHandle) {
                throw 'Showing the question alert or full-screen fixture took keyboard focus.'
            }
            $activation = [CopilotQuestionAlertTest.Native]::SendMessage(
                $handle, 0x0021, $handle, [IntPtr]::new(0x02010001)
            )
            if ($activation.ToInt32() -ne 3) {
                throw "The question alert returned the wrong native mouse activation result: $activation."
            }

            if (-not (Test-FixtureWindowAbove -Upper $handle -Lower $coverHandle)) {
                throw 'The question alert timer did not restore its position above the full-screen window.'
            }
            Test-FixtureAlertCoexistence
            Stop-FixtureLayoutPeers
            foreach ($peer in $layoutPeers) {
                $peer.Process.Refresh()
                [string]$peerOutput = Get-Content -LiteralPath $peer.Stdout -Raw
                if ($peer.Process.ExitCode -ne 0 -or $peerOutput.Trim() -cne 'PASS compaction layout peer checks' -or
                    (Get-Item -LiteralPath $peer.Stderr).Length -ne 0) {
                    throw "Cross-process layout checks failed: $peerOutput $(Get-Content -LiteralPath $peer.Stderr -Raw)"
                }
            }
            if ($Kind -eq 'question' -and -not $SoundFailure) {
                Test-FixtureRejectedAdmission
                Test-FixtureAdmittedOverflow
            }
            foreach ($item in $coexistWindows) {
                $item.FindName('Dismiss').RaiseEvent(
                    [System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)
                )
                if ($item.IsVisible -or -not $window.IsVisible) { throw 'Alert dismissal was not independent.' }
            }
            $coexistTimer.Stop()
            if (-not $SoundFailure -and $player.Position -le [TimeSpan]::Zero -and 'sound_played' -notin $results.code) {
                throw 'The question notification tone did not start playback.'
            }
            if (-not $SoundFailure -and (-not $player.NaturalDuration.HasTimeSpan -or
                $player.NaturalDuration.TimeSpan.TotalSeconds -gt 1.5)) {
                throw 'The question notification tone must not exceed 1.5 seconds.'
            }
            $cover.Close()
            if ($NameFailure) {
                $script:fixtureExpectedSessionName = 'Compaction restored session'
                $metadataPath = Join-Path $env:COPILOT_HOME "session-state\$sessionId\workspace.yaml"
                [System.IO.File]::WriteAllText($metadataPath, "id: $sessionId`nname: $fixtureExpectedSessionName`n")
            }
            [void]$fixtureCoordination.Signal.Set()
            $window.FindName('Dismiss').RaiseEvent(
                [System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)
            )
            if (-not $window.IsVisible) { throw 'Dismissing the alert lost a concurrent question.' }
            if ($NameFailure -and $window.FindName('Message').Text -cne "Session: $fixtureExpectedSessionName") {
                throw 'The compaction name did not recover after a metadata failure.'
            }
            $window.FindName('Dismiss').RaiseEvent(
                [System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)
            )
            $fixtureState.Rendered = $true
        } catch {
            $verifyTimer.Stop()
            $fixtureState.Failure = $_
            Stop-FixtureSignalProcesses
            Stop-FixtureLayoutPeers
            [void]$fixtureCoordination.Signal.Reset()
            $cover.Close()
            $window.Close()
        }
    })

    $raiseTimer = [System.Windows.Threading.DispatcherTimer]::new()
    $raiseTimer.Interval = [TimeSpan]::FromMilliseconds(100)
    $raiseTimer.Add_Tick({
        $raiseTimer.Stop()
        try {
            $cover.Show()
            Set-QuestionAlertTopmost -Window $cover
            $handle = [System.Windows.Interop.WindowInteropHelper]::new($window).Handle
            $coverHandle = [System.Windows.Interop.WindowInteropHelper]::new($cover).Handle
            if (-not (Test-FixtureWindowAbove -Upper $coverHandle -Lower $handle)) {
                throw 'The full-screen fixture did not cover the question alert before its timer ran.'
            }
            $signalScript = Join-Path $PSScriptRoot 'Invoke-QuestionAlertSignal.ps1'
            if ($Kind -eq 'compaction') {
                $script:fixtureExpectedSessionName = 'Compaction renamed <session> & "quotes"'
                $metadataPath = Join-Path $env:COPILOT_HOME "session-state\$sessionId\workspace.yaml"
                [System.IO.File]::WriteAllText(
                    $metadataPath,
                    $(if ($NameFailure) { "id: $sessionId`nname: null`n" } else {
                        "id: $sessionId`nname: " + ($fixtureExpectedSessionName | ConvertTo-Json -Compress) + "`n"
                    })
                )
            }
            $powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            $peerScript = Join-Path $PSScriptRoot 'Invoke-CompactionLayoutPeer.ps1'
            foreach ($peerId in @('44444444-4444-4444-4444-444444444444', '55555555-5555-5555-5555-555555555555')) {
                $stdoutFile = Join-Path $testLogDir "peer-$peerId-stdout.txt"
                $stderrFile = Join-Path $testLogDir "peer-$peerId-stderr.txt"
                $stop = [System.Threading.EventWaitHandle]::new(
                    $false, [System.Threading.EventResetMode]::ManualReset,
                    ('Local\CopilotHelpfulToolsLayoutPeer-' + $coordinationId.ToString('N') + '-' + $peerId)
                )
                $arguments = "-NoProfile -NonInteractive -STA -File `"$peerScript`" -CoordinationId $coordinationId -SessionId $peerId"
                try {
                    $process = Start-Process -FilePath $powershellPath -ArgumentList $arguments -WindowStyle Hidden `
                        -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile -PassThru
                    [void]$process.Handle
                    $layoutPeers.Add([pscustomobject]@{ Process = $process; Stop = $stop; Stdout = $stdoutFile; Stderr = $stderrFile })
                } catch {
                    $stop.Dispose()
                    throw
                }
            }
            for ($i = 0; $i -lt 3; $i++) {
                $stdoutFile = Join-Path $testLogDir "signal-$i-stdout.txt"
                $stderrFile = Join-Path $testLogDir "signal-$i-stderr.txt"
                $arguments = "-NoProfile -NonInteractive -STA -File `"$signalScript`" -CoordinationId $coordinationId -Kind $Kind"
                $process = Start-Process -FilePath $powershellPath -ArgumentList $arguments -WindowStyle Hidden `
                    -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile -PassThru
                # Retain the handle so Windows PowerShell 5.1 can read ExitCode after the child exits.
                [void]$process.Handle
                $signalProcesses.Add([pscustomobject]@{ Process = $process; Stdout = $stdoutFile; Stderr = $stderrFile })
            }
            $elapsed.Start()
            $verifyTimer.Start()
        } catch {
            $fixtureState.Failure = $_
            Stop-FixtureSignalProcesses
            Stop-FixtureLayoutPeers
            [void]$fixtureCoordination.Signal.Reset()
            $cover.Close()
            $window.Close()
        }
    })
    $window.Add_ContentRendered({
        foreach ($item in $coexistWindows) { $item.Show() }
        $coexistTimer.Start()
        $raiseTimer.Start()
    })

    $watchdog = [System.Windows.Threading.DispatcherTimer]::new()
    $watchdog.Interval = [TimeSpan]::FromSeconds(12)
    $watchdog.Add_Tick({
        $watchdog.Stop()
        $fixtureState.Failure = 'The question alert did not render before the test timeout.'
        Stop-FixtureSignalProcesses
        Stop-FixtureLayoutPeers
        [void]$fixtureCoordination.Signal.Reset()
        $cover.Close()
        $window.Close()
    })
    $watchdog.Start()

    function New-FixtureQuestionAlertWindow { return $script:window }
    function New-FixtureQuestionAlertPlayer {
        if ($script:SoundFailure) { throw 'Fixture sound player failure.' }
        return $script:player
    }
    function New-FixtureQuestionAlertCoordination {
        param([string]$NamePrefix)
        $expectedPrefix = if ($script:Kind -eq 'compaction') { 'Local\CopilotHelpfulToolsCompactionAlert-' + $script:sessionId } else { '' }
        if ($NamePrefix -cne $expectedPrefix) { throw 'The alert used the wrong coordination scope.' }
        return $script:fixtureCoordination
    }
    Set-Alias -Name New-QuestionAlertWindow -Value New-FixtureQuestionAlertWindow
    Set-Alias -Name New-QuestionAlertPlayer -Value New-FixtureQuestionAlertPlayer
    Set-Alias -Name New-QuestionAlertCoordination -Value New-FixtureQuestionAlertCoordination
    if ($Kind -eq 'compaction') {
        Show-QuestionAlert -Kind compaction -SessionId $sessionId
    } else {
        Show-QuestionAlert
    }

    if ($fixtureState.Failure) { throw $fixtureState.Failure }
    if (-not $fixtureState.Rendered -or $window.IsVisible) {
        throw 'The question alert did not render and close through its Dismiss button.'
    }
    $results = @(Get-Content -LiteralPath (Join-Path $env:COPILOT_PLUGIN_DATA 'hooks.log') | ForEach-Object {
        $_ | ConvertFrom-Json
    })
    $unexpectedFailures = @($results | Where-Object {
        $_.outcome -ceq 'did_not_work' -and
        (-not $SoundFailure -or $_.code -cne 'sound_play_failed') -and
        (-not $NameFailure -or $_.code -cne 'session_name_unavailable') -and
        (-not $admittedOverflowChecked -or $_.code -cne 'compaction_alert_layout_failed')
    })
    if (@($results | Where-Object code -CEQ ($codePrefix + '_displayed')).Count -ne 1 -or $unexpectedFailures.Count -ne 0) {
        throw 'The question alert lifecycle did not log a successful display.'
    }
    if ($SoundFailure -and 'sound_play_failed' -notin $results.code) {
        throw 'The visual-only alert did not log its sound failure.'
    }
    if ($NameFailure -and 'session_name_unavailable' -notin $results.code) {
        throw 'The name-unavailable alert did not log its metadata failure.'
    }
    if (-not $SoundFailure -and @($results | Where-Object code -CEQ ($codePrefix + '_replayed')).Count -lt 2) {
        throw 'The alert did not replay its notification tone for repeated and concurrent-close questions.'
    }

    $logText = Get-Content -LiteralPath (Join-Path $env:COPILOT_PLUGIN_DATA 'hooks.log') -Raw
    if ($logText.Contains($sessionId) -or $logText.Contains('Compaction renamed')) {
        throw 'The alert renderer logged session identity.'
    }
    function Show-FixtureQuestionAlert {
        param([string]$Kind = 'question', [string]$SessionId)
        if ($Kind -cne $script:Kind -or ($Kind -eq 'compaction' -and $SessionId -cne $script:sessionId)) {
            throw 'The renderer routed an incorrect kind or session ID.'
        }
        "$Kind-alert-routed"
    }
    Set-Alias -Name Show-QuestionAlert -Value Show-FixtureQuestionAlert
    $rendererArguments = @{ Kind = $Kind }
    if ($Kind -eq 'compaction') { $rendererArguments.SessionId = $sessionId }
    $rendererOutput = @(& "$PSScriptRoot\..\..\hooks\Show-Toast.ps1" @rendererArguments)
    if (($rendererOutput -join '').Trim() -cne "$Kind-alert-routed") {
        throw 'The question renderer did not select the persistent alert.'
    }
    "PASS $Kind alert renderer checks"
} finally {
    if ($watchdog) { $watchdog.Stop() }
    if ($raiseTimer) { $raiseTimer.Stop() }
    if ($verifyTimer) { $verifyTimer.Stop() }
    if ($coexistTimer) { $coexistTimer.Stop() }
    Stop-FixtureSignalProcesses
    Stop-FixtureLayoutPeers
    foreach ($child in $signalProcesses) { $child.Process.Dispose() }
    foreach ($peer in $layoutPeers) { $peer.Process.Dispose(); $peer.Stop.Dispose() }
    if ($player) { $player.Close() }
    if ($cover) { $cover.Close() }
    foreach ($item in $coexistWindows) { $item.Close() }
    if ($window) { $window.Close() }
    if ($fixtureContent -and $fixtureContent -ne $window) { $fixtureContent.Close() }
    if ($fixtureCoordination) {
        $fixtureCoordination.Signal.Dispose()
        $fixtureCoordination.Owner.Dispose()
        $fixtureCoordination.Gate.Dispose()
    }
}
