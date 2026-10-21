param([switch]$SoundFailure)

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

. "$PSScriptRoot\..\..\hooks\QuestionAlert.Common.ps1"

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
$fixtureCoordination = $null
$coordinationId = [guid]::NewGuid()
$signalProcesses = [System.Collections.Generic.List[object]]::new()
$elapsed = [System.Diagnostics.Stopwatch]::new()
$fixtureState = [pscustomobject]@{ Rendered = $false; Failure = $null }

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

function Test-FixtureWindowAbove {
    param([IntPtr]$Upper, [IntPtr]$Lower)

    $next = [CopilotQuestionAlertTest.Native]::GetWindow($Upper, 2)
    for ($i = 0; $i -lt 10000 -and $next -ne [IntPtr]::Zero -and $next -ne $Lower; $i++) {
        $next = [CopilotQuestionAlertTest.Native]::GetWindow($next, 2)
    }
    return $next -eq $Lower
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
    $fixtureContent = New-QuestionAlertContent
    $fixtureContent.WindowStyle = [System.Windows.WindowStyle]::None
    $fixtureContent.AllowsTransparency = $true
    $fixtureContent.Opacity = 0
    function New-FixtureQuestionAlertContent { return $script:fixtureContent }
    Set-Alias -Name New-QuestionAlertContent -Value New-FixtureQuestionAlertContent
    $window = New-QuestionAlertWindow
    if (-not $window.Topmost -or $window.ShowActivated -or $window.ShowInTaskbar -or
        $window.Title -cne 'Copilot CLI - question' -or
        $window.FindName('Dismiss').Content -cne 'Dismiss') {
        throw 'The question alert has incorrect visibility, focus, or content settings.'
    }

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
                if ($child.Process.ExitCode -ne 0 -or $childOutput.Trim() -cne 'PASS question alert reuse checks' -or
                    $childError.Length -ne 0) {
                    throw "A repeat notification did not reuse the alert (exit $($child.Process.ExitCode)): $childOutput $childError"
                }
            }
            $results = @(Get-Content -LiteralPath (Join-Path $testLogDir 'hooks.log') | ForEach-Object {
                $_ | ConvertFrom-Json
            })
            if (-not $SoundFailure -and 'question_alert_replayed' -notin $results.code) { return }
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
            if (-not $SoundFailure -and $player.Position -le [TimeSpan]::Zero -and 'sound_played' -notin $results.code) {
                throw 'The question notification tone did not start playback.'
            }
            if (-not $SoundFailure -and (-not $player.NaturalDuration.HasTimeSpan -or
                $player.NaturalDuration.TimeSpan.TotalSeconds -gt 1.5)) {
                throw 'The question notification tone must not exceed 1.5 seconds.'
            }
            $cover.Close()
            [void]$fixtureCoordination.Signal.Set()
            $window.FindName('Dismiss').RaiseEvent(
                [System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)
            )
            if (-not $window.IsVisible) { throw 'Dismissing the alert lost a concurrent question.' }
            $window.FindName('Dismiss').RaiseEvent(
                [System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)
            )
            $fixtureState.Rendered = $true
        } catch {
            $verifyTimer.Stop()
            $fixtureState.Failure = $_
            Stop-FixtureSignalProcesses
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
            $powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            for ($i = 0; $i -lt 3; $i++) {
                $stdoutFile = Join-Path $testLogDir "signal-$i-stdout.txt"
                $stderrFile = Join-Path $testLogDir "signal-$i-stderr.txt"
                $arguments = "-NoProfile -NonInteractive -STA -File `"$signalScript`" -CoordinationId $coordinationId"
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
            [void]$fixtureCoordination.Signal.Reset()
            $cover.Close()
            $window.Close()
        }
    })
    $window.Add_ContentRendered({ $raiseTimer.Start() })

    $watchdog = [System.Windows.Threading.DispatcherTimer]::new()
    $watchdog.Interval = [TimeSpan]::FromSeconds(12)
    $watchdog.Add_Tick({
        $watchdog.Stop()
        $fixtureState.Failure = 'The question alert did not render before the test timeout.'
        Stop-FixtureSignalProcesses
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
    function New-FixtureQuestionAlertCoordination { return $script:fixtureCoordination }
    Set-Alias -Name New-QuestionAlertWindow -Value New-FixtureQuestionAlertWindow
    Set-Alias -Name New-QuestionAlertPlayer -Value New-FixtureQuestionAlertPlayer
    Set-Alias -Name New-QuestionAlertCoordination -Value New-FixtureQuestionAlertCoordination
    Show-QuestionAlert

    if ($fixtureState.Failure) { throw $fixtureState.Failure }
    if (-not $fixtureState.Rendered -or $window.IsVisible) {
        throw 'The question alert did not render and close through its Dismiss button.'
    }
    $results = @(Get-Content -LiteralPath (Join-Path $env:COPILOT_PLUGIN_DATA 'hooks.log') | ForEach-Object {
        $_ | ConvertFrom-Json
    })
    $unexpectedFailures = @($results | Where-Object {
        $_.outcome -ceq 'did_not_work' -and (-not $SoundFailure -or $_.code -cne 'sound_play_failed')
    })
    if (@($results | Where-Object code -CEQ 'question_alert_displayed').Count -ne 1 -or $unexpectedFailures.Count -ne 0) {
        throw 'The question alert lifecycle did not log a successful display.'
    }
    if ($SoundFailure -and 'sound_play_failed' -notin $results.code) {
        throw 'The visual-only alert did not log its sound failure.'
    }
    if (-not $SoundFailure -and @($results | Where-Object code -CEQ 'question_alert_replayed').Count -lt 2) {
        throw 'The alert did not replay its notification tone for repeated and concurrent-close questions.'
    }

    function Show-FixtureQuestionAlert { 'question-alert-routed' }
    Set-Alias -Name Show-QuestionAlert -Value Show-FixtureQuestionAlert
    $rendererOutput = @(& "$PSScriptRoot\..\..\hooks\Show-Toast.ps1" -Kind question)
    if (($rendererOutput -join '').Trim() -cne 'question-alert-routed') {
        throw 'The question renderer did not select the persistent alert.'
    }
    'PASS question alert renderer checks'
} finally {
    if ($watchdog) { $watchdog.Stop() }
    if ($raiseTimer) { $raiseTimer.Stop() }
    if ($verifyTimer) { $verifyTimer.Stop() }
    Stop-FixtureSignalProcesses
    foreach ($child in $signalProcesses) { $child.Process.Dispose() }
    if ($player) { $player.Close() }
    if ($cover) { $cover.Close() }
    if ($window) { $window.Close() }
    if ($fixtureContent -and $fixtureContent -ne $window) { $fixtureContent.Close() }
    if ($fixtureCoordination) {
        $fixtureCoordination.Signal.Dispose()
        $fixtureCoordination.Owner.Dispose()
        $fixtureCoordination.Gate.Dispose()
    }
}
