param(
    [switch]$SoundFailure,
    [switch]$NameFailure,
    [ValidateSet('question', 'compaction', 'failure')][string]$Kind = 'question'
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
$nextSessionId = '66666666-6666-6666-6666-666666666666'
$fixtureExpectedSessionId = $sessionId
$codePrefix = switch ($Kind) {
    'compaction' { 'compaction_alert' }
    'failure' { 'failure_alert' }
    'question' { 'question_alert' }
}
$fixtureExpectedSessionName = 'Compaction test <name> & "quotes"'
foreach ($fixtureId in @($sessionId, $nextSessionId, '22222222-2222-2222-2222-222222222222', '33333333-3333-3333-3333-333333333333', '77777777-7777-7777-7777-777777777777')) {
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
$narrowPlacementChecked = $false

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

function Test-FixtureCaptionedQuestionContent {
    $captioned = New-QuestionAlertWindow -Kind $script:Kind -SessionId '22222222-2222-2222-2222-222222222222'
    try {
        $handle = [System.Windows.Interop.WindowInteropHelper]::new($captioned).Handle
        $captioned.Left = [System.Windows.SystemParameters]::VirtualScreenLeft
        $captioned.Top = [System.Windows.SystemParameters]::VirtualScreenTop + [System.Windows.SystemParameters]::VirtualScreenHeight + 100
        $captioned.Show()
        $captioned.UpdateLayout()
        $bounds = [CopilotQuestionAlert.Native+Bounds]::new()
        if (-not [CopilotQuestionAlert.Native]::GetWindowRect($handle, [ref]$bounds)) {
            throw 'The captioned question card has no bounds.'
        }
        foreach ($controlName in @('Heading', 'Instruction', 'MessageViewport', 'SessionId', 'Dismiss')) {
            Assert-FixtureControlInsideFrame -Window $captioned -ControlName $controlName
            $control = $captioned.FindName($controlName)
            $start = $control.PointToScreen([System.Windows.Point]::new(0, 0))
            $end = $control.PointToScreen([System.Windows.Point]::new($control.ActualWidth, $control.ActualHeight))
            if ($control.ActualHeight -le 0 -or $start.X -lt $bounds.Left -or $start.Y -lt $bounds.Top -or
                $end.X -gt $bounds.Right -or $end.Y -gt $bounds.Bottom) {
                throw "The captioned question card clips $controlName."
            }
        }
        if ([CopilotQuestionAlert.Native]::GetForegroundWindow() -eq $handle -or
            $captioned.FindName('SessionId').Text -cne 'Session ID: 22222222-2222-2222-2222-222222222222') {
            throw 'The captioned question card took focus or lost its full ID.'
        }
        $captioned.FindName('MessageViewport').ScrollToEnd()
        $captioned.UpdateLayout()
        if ($captioned.FindName('MessageViewport').VerticalOffset -le 0) {
            throw 'The captioned scroll fixture did not start with a scrolled long name.'
        }
        Set-SessionAlertContent -Window $captioned -Kind $script:Kind -SessionId $script:nextSessionId
        $captioned.UpdateLayout()
        if ($captioned.FindName('MessageViewport').VerticalOffset -ne 0) {
            throw 'A new question session did not reset the name scroll position.'
        }
    } finally {
        $captioned.Close()
    }
}

function Assert-FixtureControlInsideFrame {
    param([System.Windows.Window]$Window, [string]$ControlName)

    $frame = $Window.FindName('Frame')
    $control = $Window.FindName($ControlName)
    $start = $control.TranslatePoint([System.Windows.Point]::new(0, 0), $frame)
    $end = $control.TranslatePoint([System.Windows.Point]::new($control.ActualWidth, $control.ActualHeight), $frame)
    if ($control.ActualHeight -le 0 -or
        $start.X -lt ($frame.BorderThickness.Left + $frame.Padding.Left - 0.01) -or
        $start.Y -lt ($frame.BorderThickness.Top + $frame.Padding.Top - 0.01) -or
        $end.X -gt ($frame.ActualWidth - $frame.BorderThickness.Right - $frame.Padding.Right + 0.01) -or
        $end.Y -gt ($frame.ActualHeight - $frame.BorderThickness.Bottom - $frame.Padding.Bottom + 0.01)) {
        throw "The alert frame clips $ControlName."
    }
}

function Test-FixtureNarrowFailurePlacement {
    $failure = $script:window
    $question = @($script:coexistWindows | Where-Object Tag -EQ 'question')[0]
    $handle = [System.Windows.Interop.WindowInteropHelper]::new($failure).Handle
    $scale = [CopilotQuestionAlert.Native]::GetDpiForWindow($handle) / 96.0
    $area = [System.Windows.Forms.Screen]::FromHandle($handle).WorkingArea
    try {
        foreach ($width in @(960, 1024, 1072, 1280)) {
            $testArea = [System.Drawing.Rectangle]::new($area.Left, $area.Top, [int]($width * $scale), $area.Height)
            Move-CornerAlertToWorkArea -Window $failure -WorkArea $testArea
            Move-CornerAlertToWorkArea -Window $question -WorkArea $testArea
            $failureBounds = [CopilotQuestionAlert.Native+Bounds]::new()
            $questionBounds = [CopilotQuestionAlert.Native+Bounds]::new()
            if (-not [CopilotQuestionAlert.Native]::GetWindowRect($handle, [ref]$failureBounds) -or
                -not [CopilotQuestionAlert.Native]::GetWindowRect(
                    [System.Windows.Interop.WindowInteropHelper]::new($question).Handle, [ref]$questionBounds
                )) {
                throw 'Narrow-work-area alert bounds are unavailable.'
            }
            $expectedTop = $area.Top + $(if ($width -lt 1072) { 248 * $scale } else { 16 * $scale })
            if ([Math]::Abs($failureBounds.Left - ($area.Left + 16 * $scale)) -gt 2 -or
                [Math]::Abs($failureBounds.Top - $expectedTop) -gt 2 -or
                ($failureBounds.Left -lt $questionBounds.Right -and $questionBounds.Left -lt $failureBounds.Right -and
                    $failureBounds.Top -lt $questionBounds.Bottom -and $questionBounds.Top -lt $failureBounds.Bottom)) {
                throw 'The full-size left failure card overlaps the question card in a narrow work area.'
            }
            Assert-FixtureControlInsideFrame -Window $failure -ControlName 'SessionId'
            Assert-FixtureControlInsideFrame -Window $failure -ControlName 'Dismiss'
        }
    } finally {
        Move-QuestionAlertToActiveMonitor -Window $failure
        Move-QuestionAlertToActiveMonitor -Window $question
    }
    $script:narrowPlacementChecked = $true
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
            if ($item.Tag -eq 'failure') {
                $dpi = [CopilotQuestionAlert.Native]::GetDpiForWindow($handle) / 96.0
                $expectedTop = $area.Top + 16 * $dpi
                if ($area.Width -lt (1072 * $dpi)) { $expectedTop += 232 * $dpi }
                if ([Math]::Abs($bounds.Left - ($area.Left + 16 * $dpi)) -gt 2 -or
                    [Math]::Abs($bounds.Top - $expectedTop) -gt 2) {
                    throw 'The execution-failure card is not in its left-side monitor position.'
                }
            }
            if ($item.Tag -in @('question', 'compaction', 'failure')) {
                foreach ($controlName in @('SessionId', 'Dismiss')) {
                    Assert-FixtureControlInsideFrame -Window $item -ControlName $controlName
                    $control = $item.FindName($controlName)
                    $start = $control.PointToScreen([System.Windows.Point]::new(0, 0))
                    $end = $control.PointToScreen([System.Windows.Point]::new($control.ActualWidth, $control.ActualHeight))
                    if ($start.Y -lt $bounds.Top -or $end.Y -gt $bounds.Bottom -or $end.X -gt $bounds.Right) {
                        throw 'A session alert hid its session ID or Dismiss control.'
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
        $standardCoordination = New-QuestionAlertCoordination -NamePrefix $scopeTestPrefix -IncludeSession
        $fixtureSecurityScope = 'fixture-administrator'
        $administratorCoordination = New-QuestionAlertCoordination -NamePrefix $scopeTestPrefix -IncludeSession
        Set-QuestionAlertSession -Coordination $standardCoordination -SessionId $sessionId
        Set-QuestionAlertSession -Coordination $administratorCoordination -SessionId $nextSessionId
        if ((Get-QuestionAlertSession -Coordination $standardCoordination) -cne $sessionId -or
            (Get-QuestionAlertSession -Coordination $administratorCoordination) -cne $nextSessionId) {
            throw 'The question session channel crossed security scopes.'
        }
        [void]$standardCoordination.Signal.Set()
        if ($administratorCoordination.Signal.WaitOne(0) -or -not $standardCoordination.Signal.WaitOne(0)) {
            throw 'The question alert coordination crossed security scopes.'
        }
    } finally {
        Remove-Item -LiteralPath 'Alias:\Get-QuestionAlertScope'
        foreach ($item in @($standardCoordination, $administratorCoordination)) {
            if ($item) {
                if ($item.Session) { $item.Session.Dispose() }
                $item.Signal.Dispose()
                $item.Owner.Dispose()
                $item.Gate.Dispose()
            }
        }
    }

    $fixtureCoordination = New-QuestionAlertCoordination -NamePrefix (
        'Local\CopilotHelpfulToolsQuestionAlertTest-' + $coordinationId.ToString('N')
    ) -IncludeSession:($Kind -ne 'compaction')
    function Get-FixtureLayoutScope { return ('fixture-layout-' + $script:coordinationId.ToString('N')) }
    Set-Alias -Name Get-QuestionAlertScope -Value Get-FixtureLayoutScope
    if ($Kind -in @('question', 'failure') -and -not $SoundFailure -and -not $NameFailure) {
        Test-FixtureCaptionedQuestionContent
    }
    $fixtureContent = New-QuestionAlertContent -Kind $Kind -SessionId ("`n" + $sessionId + "`n")
    $fixtureContent.WindowStyle = [System.Windows.WindowStyle]::None
    $fixtureContent.AllowsTransparency = $true
    $fixtureContent.Opacity = 0
    function New-FixtureQuestionAlertContent { return $script:fixtureContent }
    Set-Alias -Name New-QuestionAlertContent -Value New-FixtureQuestionAlertContent
    $window = New-QuestionAlertWindow -Kind $Kind -SessionId $sessionId
    $expectedTitle = switch ($Kind) {
        'compaction' { 'Copilot CLI - compacting' }
        'failure' { 'Copilot CLI - execution failed' }
        'question' { 'Copilot CLI - question' }
    }
    if (-not $window.Topmost -or $window.ShowActivated -or $window.ShowInTaskbar -or
        $window.Title -cne $expectedTitle -or
        $window.FindName('Dismiss').Content -cne 'Dismiss') {
        throw 'The question alert has incorrect visibility, focus, or content settings.'
    }
    $expectedHeading = switch ($Kind) {
        'compaction' { 'Copilot is compacting' }
        'failure' { 'Copilot execution failed' }
        'question' { 'Copilot needs your answer' }
    }
    if ($window.FindName('Heading').Text -cne $expectedHeading -or
        $window.FindName('Message').Text -cne "Session: $fixtureExpectedSessionName" -or
        $window.FindName('SessionId').Text -cne "Session ID: $sessionId") {
        throw 'The alert did not render its session identity as literal text.'
    }
    if ($Kind -eq 'question' -and ($window.FindName('Instruction').Text -cne 'Switch to the terminal to respond.' -or
        $window.FindName('Instruction').Visibility -ne [System.Windows.Visibility]::Visible)) {
        throw 'The question alert lost its response instruction.'
    }
    if ($Kind -eq 'compaction' -and $window.FindName('Instruction').Visibility -ne [System.Windows.Visibility]::Collapsed) {
        throw 'The compaction alert displayed the question instruction.'
    }
    if ($Kind -eq 'failure' -and ($window.FindName('Instruction').Text -cne 'Switch to the terminal to inspect the error.' -or
        $window.FindName('Instruction').Visibility -ne [System.Windows.Visibility]::Visible)) {
        throw 'The failure alert lost its error-inspection instruction.'
    }
    Remove-Item -LiteralPath 'Alias:\New-QuestionAlertContent'
    $auxiliaryKinds = switch ($Kind) {
        'question' { @('compaction', 'compaction') }
        'compaction' { @('question', 'compaction') }
        'failure' { @('question', 'compaction', 'compaction') }
    }
    for ($i = 0; $i -lt $auxiliaryKinds.Count; $i++) {
        $auxiliaryId = @('22222222-2222-2222-2222-222222222222', '33333333-3333-3333-3333-333333333333', '77777777-7777-7777-7777-777777777777')[$i]
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
            if ($window.FindName('Message').Text -cne $expectedMessage -or
                $window.FindName('SessionId').Text -cne "Session ID: $fixtureExpectedSessionId") {
                return
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
            if ($Kind -eq 'failure' -and -not $SoundFailure -and -not $NameFailure) {
                Test-FixtureNarrowFailurePlacement
            }
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
            if ($Kind -in @('question', 'failure')) {
                $script:fixtureExpectedSessionId = $sessionId
                $script:fixtureExpectedSessionName = 'Latest question during dismissal'
                $metadataPath = Join-Path $env:COPILOT_HOME "session-state\$sessionId\workspace.yaml"
                [System.IO.File]::WriteAllText($metadataPath, "id: $sessionId`nname: $fixtureExpectedSessionName`n")
                if (-not (Wait-QuestionAlertMutex -Mutex $fixtureCoordination.Gate -TimeoutMilliseconds 2000)) {
                    throw 'The concurrent question could not acquire its session channel.'
                }
                try {
                    Set-QuestionAlertSession -Coordination $fixtureCoordination -SessionId $sessionId
                } finally {
                    $fixtureCoordination.Gate.ReleaseMutex()
                }
            }
            if ($NameFailure) {
                $script:fixtureExpectedSessionName = 'Restored session'
                $metadataPath = Join-Path $env:COPILOT_HOME "session-state\$sessionId\workspace.yaml"
                [System.IO.File]::WriteAllText($metadataPath, "id: $sessionId`nname: $fixtureExpectedSessionName`n")
            }
            [void]$fixtureCoordination.Signal.Set()
            $window.FindName('Dismiss').RaiseEvent(
                [System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)
            )
            if (-not $window.IsVisible) { throw 'Dismissing the alert lost a concurrent question.' }
            if ($window.FindName('Message').Text -cne "Session: $fixtureExpectedSessionName" -or
                $window.FindName('SessionId').Text -cne "Session ID: $fixtureExpectedSessionId") {
                throw 'The alert lost the latest session identity or name recovery during dismissal.'
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
            $script:fixtureExpectedSessionId = if ($Kind -eq 'compaction') { $sessionId } else { $nextSessionId }
            $script:fixtureExpectedSessionName = 'Renamed session <literal> & "quotes"'
            $metadataPath = Join-Path $env:COPILOT_HOME "session-state\$fixtureExpectedSessionId\workspace.yaml"
            [System.IO.File]::WriteAllText(
                $metadataPath,
                $(if ($NameFailure) { "id: $fixtureExpectedSessionId`nname: null`n" } else {
                    "id: $fixtureExpectedSessionId`nname: " + ($fixtureExpectedSessionName | ConvertTo-Json -Compress) + "`n"
                })
            )
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
                $arguments = "-NoProfile -NonInteractive -STA -File `"$signalScript`" -CoordinationId $coordinationId -Kind $Kind -SessionId $fixtureExpectedSessionId"
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
        param([string]$NamePrefix, [switch]$IncludeSession)
        $expectedPrefix = switch ($script:Kind) {
            'compaction' { 'Local\CopilotHelpfulToolsCompactionAlert-' + $script:sessionId }
            'failure' { 'Local\CopilotHelpfulToolsExecutionFailureAlert' }
            'question' { '' }
        }
        if ($NamePrefix -cne $expectedPrefix -or $IncludeSession.IsPresent -ne ($script:Kind -ne 'compaction')) {
            throw 'The alert used the wrong coordination scope or session channel.'
        }
        return $script:fixtureCoordination
    }
    Set-Alias -Name New-QuestionAlertWindow -Value New-FixtureQuestionAlertWindow
    Set-Alias -Name New-QuestionAlertPlayer -Value New-FixtureQuestionAlertPlayer
    Set-Alias -Name New-QuestionAlertCoordination -Value New-FixtureQuestionAlertCoordination
    Show-QuestionAlert -Kind $Kind -SessionId $sessionId

    if ($fixtureState.Failure) { throw $fixtureState.Failure }
    if (-not $fixtureState.Rendered -or $window.IsVisible) {
        throw 'The question alert did not render and close through its Dismiss button.'
    }
    if ($Kind -eq 'failure' -and -not $SoundFailure -and -not $NameFailure -and -not $narrowPlacementChecked) {
        throw 'The narrow-work-area failure placement checks did not execute.'
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
    if ($logText.Contains($sessionId) -or $logText.Contains($nextSessionId) -or
        $logText.Contains('Renamed session') -or $logText.Contains('Latest question')) {
        throw 'The alert renderer logged session identity.'
    }
    function Show-FixtureQuestionAlert {
        param([string]$Kind = 'question', [string]$SessionId)
        if ($Kind -cne $script:Kind -or $SessionId -cne $script:sessionId) {
            throw 'The renderer routed an incorrect kind or session ID.'
        }
        "$Kind-alert-routed"
    }
    Set-Alias -Name Show-QuestionAlert -Value Show-FixtureQuestionAlert
    $rendererArguments = @{ Kind = $Kind; SessionId = $sessionId }
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
        if ($fixtureCoordination.Session) { $fixtureCoordination.Session.Dispose() }
        $fixtureCoordination.Signal.Dispose()
        $fixtureCoordination.Owner.Dispose()
        $fixtureCoordination.Gate.Dispose()
    }
}
