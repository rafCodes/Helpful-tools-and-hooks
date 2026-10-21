. "$PSScriptRoot\HookLog.Common.ps1"

function Initialize-QuestionAlert {
    Add-Type -AssemblyName PresentationFramework, System.Windows.Forms -ErrorAction Stop

    if (-not ('CopilotQuestionAlert.Native' -as [type])) {
        Add-Type -Namespace CopilotQuestionAlert -Name Native -MemberDefinition @'
[DllImport("user32.dll")]
public static extern System.IntPtr GetForegroundWindow();

[DllImport("user32.dll", SetLastError = true)]
public static extern int GetWindowLong(System.IntPtr window, int index);

[DllImport("user32.dll", SetLastError = true)]
public static extern int SetWindowLong(System.IntPtr window, int index, int value);

[DllImport("user32.dll", SetLastError = true)]
[return: MarshalAs(UnmanagedType.Bool)]
public static extern bool SetWindowPos(
    System.IntPtr window, System.IntPtr insertAfter,
    int x, int y, int width, int height, uint flags);

[UnmanagedFunctionPointer(CallingConvention.Winapi)]
private delegate System.IntPtr SubclassProc(
    System.IntPtr window, uint message, System.IntPtr wParam, System.IntPtr lParam,
    System.UIntPtr subclassId, System.UIntPtr referenceData);

private static readonly SubclassProc NoActivateProc = HandleWindowMessage;

[DllImport("comctl32.dll")]
[return: MarshalAs(UnmanagedType.Bool)]
private static extern bool SetWindowSubclass(
    System.IntPtr window, SubclassProc callback, System.UIntPtr subclassId, System.UIntPtr referenceData);

[DllImport("comctl32.dll")]
[return: MarshalAs(UnmanagedType.Bool)]
private static extern bool RemoveWindowSubclass(
    System.IntPtr window, SubclassProc callback, System.UIntPtr subclassId);

[DllImport("comctl32.dll")]
private static extern System.IntPtr DefSubclassProc(
    System.IntPtr window, uint message, System.IntPtr wParam, System.IntPtr lParam);

public static bool PreventMouseActivation(System.IntPtr window) {
    return SetWindowSubclass(window, NoActivateProc, new System.UIntPtr(1u), System.UIntPtr.Zero);
}

private static System.IntPtr HandleWindowMessage(
    System.IntPtr window, uint message, System.IntPtr wParam, System.IntPtr lParam,
    System.UIntPtr subclassId, System.UIntPtr referenceData) {
    if (message == 0x0021) { return new System.IntPtr(3); }
    if (message == 0x0082) { RemoveWindowSubclass(window, NoActivateProc, subclassId); }
    return DefSubclassProc(window, message, wParam, lParam);
}
'@ -ErrorAction Stop
    }
}

function Get-QuestionAlertScope {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        $principal = [System.Security.Principal.WindowsPrincipal]::new($identity)
        $level = if ($principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
            'Administrator'
        } else {
            'Standard'
        }
        return ($identity.User.Value + '-' + $level)
    } finally {
        $identity.Dispose()
    }
}

function New-QuestionAlertCoordination {
    param([ValidateNotNullOrEmpty()][string]$NamePrefix = 'Local\CopilotHelpfulToolsQuestionAlert')

    $NamePrefix += '-' + (Get-QuestionAlertScope)
    $coordination = [pscustomobject]@{ Gate = $null; Owner = $null; Signal = $null }
    try {
        $coordination.Gate = [System.Threading.Mutex]::new($false, ($NamePrefix + 'Gate'))
        $coordination.Owner = [System.Threading.Mutex]::new($false, ($NamePrefix + 'Owner'))
        $coordination.Signal = [System.Threading.EventWaitHandle]::new(
            $false, [System.Threading.EventResetMode]::AutoReset, ($NamePrefix + 'Signal')
        )
        return $coordination
    } catch {
        foreach ($handle in @($coordination.Signal, $coordination.Owner, $coordination.Gate)) {
            if ($handle) { $handle.Dispose() }
        }
        throw
    }
}

function Wait-QuestionAlertMutex {
    param(
        [Parameter(Mandatory)][System.Threading.Mutex]$Mutex,
        [Parameter(Mandatory)][int]$TimeoutMilliseconds
    )

    try {
        return $Mutex.WaitOne($TimeoutMilliseconds)
    } catch [System.Threading.AbandonedMutexException] {
        # WaitOne grants ownership when it reports an abandoned mutex.
        return $true
    }
}

function New-QuestionAlertContent {
    Initialize-QuestionAlert
    $markup = [xml]@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Copilot CLI - question" Width="420" Height="180"
        WindowStyle="ToolWindow" ResizeMode="NoResize"
        Topmost="True" ShowActivated="False" ShowInTaskbar="False"
        Background="#0F172A" Foreground="White">
    <Border BorderBrush="#F59E0B" BorderThickness="3" Padding="18">
        <StackPanel>
            <TextBlock Text="Copilot needs your answer" FontSize="20" FontWeight="Bold"/>
            <TextBlock Text="Switch to the terminal to respond." Margin="0,10,0,0"/>
            <Button x:Name="Dismiss" Content="Dismiss" Width="90" Height="30"
                    HorizontalAlignment="Right" Margin="0,14,0,0"/>
        </StackPanel>
    </Border>
</Window>
'@
    $reader = [System.Xml.XmlNodeReader]::new($markup)
    try {
        return [System.Windows.Markup.XamlReader]::Load($reader)
    } finally {
        $reader.Close()
    }
}

function New-QuestionAlertWindow {
    $window = New-QuestionAlertContent
    try {
        $handle = [System.Windows.Interop.WindowInteropHelper]::new($window).EnsureHandle()
        $extendedStyle = [CopilotQuestionAlert.Native]::GetWindowLong($handle, -20)
        # WS_EX_NOACTIVATE also prevents activation when the user clicks the alert.
        if ($extendedStyle -eq 0 -or
            [CopilotQuestionAlert.Native]::SetWindowLong($handle, -20, ($extendedStyle -bor 0x08000000)) -eq 0) {
            throw [System.ComponentModel.Win32Exception]::new(
                [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
            )
        }
        # WPF handles WM_MOUSEACTIVATE itself, so intercept it before WPF's window procedure.
        if (-not [CopilotQuestionAlert.Native]::PreventMouseActivation($handle)) {
            throw 'The question alert could not suppress mouse activation.'
        }
        Move-QuestionAlertToActiveMonitor -Window $window
        $window.FindName('Dismiss').Add_Click({ $window.Close() }.GetNewClosure())
        return $window
    } catch {
        $window.Close()
        throw
    }
}

function Move-QuestionAlertToActiveMonitor {
    param([Parameter(Mandatory)][System.Windows.Window]$Window)

    $screen = [System.Windows.Forms.Screen]::FromHandle([CopilotQuestionAlert.Native]::GetForegroundWindow())
    $handle = [System.Windows.Interop.WindowInteropHelper]::new($Window).EnsureHandle()
    $source = [System.Windows.Interop.HwndSource]::FromHwnd($handle)
    $edge = $source.CompositionTarget.TransformFromDevice.Transform(
        [System.Windows.Point]::new($screen.WorkingArea.Right, $screen.WorkingArea.Top)
    )
    $Window.Left = $edge.X - $Window.Width - 16
    $Window.Top = $edge.Y + 16
}

function Set-QuestionAlertTopmost {
    param([Parameter(Mandatory)][System.Windows.Window]$Window)

    $handle = [System.Windows.Interop.WindowInteropHelper]::new($Window).EnsureHandle()
    # Reassert the topmost position without moving, resizing, or activating the window.
    if (-not [CopilotQuestionAlert.Native]::SetWindowPos($handle, [IntPtr]::new(-1), 0, 0, 0, 0, 0x0013)) {
        throw [System.ComponentModel.Win32Exception]::new(
            [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
        )
    }
}

function New-QuestionAlertPlayer {
    $soundFile = Join-Path $env:SystemRoot 'Media\Windows Background.wav'
    if (-not (Test-Path -LiteralPath $soundFile -PathType Leaf)) {
        throw 'The Windows question notification tone is missing.'
    }

    $player = [System.Windows.Media.MediaPlayer]::new()
    try {
        $player.Volume = 0.75
        $player.Open([Uri]::new($soundFile))
        return $player
    } catch {
        $player.Close()
        throw
    }
}

function Start-QuestionAlertPlayback {
    param(
        [Parameter(Mandatory)][System.Windows.Media.MediaPlayer]$Player,
        [switch]$Replay
    )

    try {
        $Player.Stop()
        $Player.Play()
        if ($Replay) {
            Write-HookResult -Hook 'question-alert' -Outcome 'worked' -Code 'question_alert_replayed'
        }
        return $true
    } catch {
        Write-HookResult -Hook 'question-alert' -Outcome 'did_not_work' -Code 'sound_play_failed'
        return $false
    }
}

function Invoke-QuestionAlertRepeat {
    param(
        [Parameter(Mandatory)][System.Windows.Window]$Window,
        [System.Windows.Media.MediaPlayer]$Player,
        [Parameter(Mandatory)][pscustomobject]$State
    )

    Move-QuestionAlertToActiveMonitor -Window $Window
    Set-QuestionAlertTopmost -Window $Window
    if ($Player -and -not $State.SoundFailed) {
        if (-not (Start-QuestionAlertPlayback -Player $Player -Replay)) { $State.SoundFailed = $true }
    }
}

function Show-QuestionAlert {
    $window = $null
    $player = $null
    $timer = $null
    $coordination = $null
    $state = [pscustomobject]@{
        DisplayFailed = $false
        SoundFailed = $false
        OwnsGate = $false
        OwnsOwner = $false
        Finalizing = $false
    }

    try {
        $coordination = New-QuestionAlertCoordination
        $state.OwnsGate = Wait-QuestionAlertMutex -Mutex $coordination.Gate -TimeoutMilliseconds 2000
        if (-not $state.OwnsGate) { throw 'The question alert coordination lock timed out.' }
        $state.OwnsOwner = Wait-QuestionAlertMutex -Mutex $coordination.Owner -TimeoutMilliseconds 0
        if (-not $state.OwnsOwner) {
            if (-not $coordination.Signal.Set()) { throw 'The question alert could not signal its existing window.' }
            $coordination.Gate.ReleaseMutex()
            $state.OwnsGate = $false
            Write-HookResult -Hook 'question-alert' -Outcome 'worked' -Code 'question_alert_reused'
            return
        }
        [void]$coordination.Signal.Reset()
        $coordination.Gate.ReleaseMutex()
        $state.OwnsGate = $false

        $window = New-QuestionAlertWindow
        $window.Add_Closing({
            param($Sender, $EventArgs)

            try {
                if (-not $state.OwnsGate) {
                    $state.OwnsGate = Wait-QuestionAlertMutex -Mutex $coordination.Gate -TimeoutMilliseconds 2000
                    if (-not $state.OwnsGate) { throw 'The question alert close lock timed out.' }
                }
                if (-not $state.Finalizing -and -not $state.DisplayFailed -and $coordination.Signal.WaitOne(0)) {
                    $EventArgs.Cancel = $true
                    $coordination.Gate.ReleaseMutex()
                    $state.OwnsGate = $false
                    Invoke-QuestionAlertRepeat -Window $window -Player $player -State $state
                }
                # Hold the gate through final cleanup when closing, so a new request cannot be lost.
            } catch {
                $state.DisplayFailed = $true
                $EventArgs.Cancel = $false
            }
        })

        $timer = [System.Windows.Threading.DispatcherTimer]::new()
        $timer.Interval = [TimeSpan]::FromSeconds(1)
        $timer.Add_Tick({
            try {
                if ($coordination.Signal.WaitOne(0)) {
                    Invoke-QuestionAlertRepeat -Window $window -Player $player -State $state
                } else {
                    Set-QuestionAlertTopmost -Window $window
                }
            } catch {
                $state.DisplayFailed = $true
                $window.Close()
            }
        })

        try {
            $player = New-QuestionAlertPlayer
            $player.Add_MediaEnded({
                Write-HookResult -Hook 'question-alert' -Outcome 'worked' -Code 'sound_played'
                $player.Stop()
            })
            $player.Add_MediaFailed({
                $state.SoundFailed = $true
                Write-HookResult -Hook 'question-alert' -Outcome 'did_not_work' -Code 'sound_play_failed'
                $player.Close()
            })
        } catch {
            $state.SoundFailed = $true
            Write-HookResult -Hook 'question-alert' -Outcome 'did_not_work' -Code 'sound_play_failed'
        }

        $window.Add_ContentRendered({
            try {
                Set-QuestionAlertTopmost -Window $window
                $timer.Start()
                Write-HookResult -Hook 'question-alert' -Outcome 'worked' -Code 'question_alert_displayed'
            } catch {
                $state.DisplayFailed = $true
                $window.Close()
                return
            }

            if ($player -and -not $state.SoundFailed) {
                if (-not (Start-QuestionAlertPlayback -Player $player)) { $state.SoundFailed = $true }
            }
        })

        $application = [System.Windows.Application]::new()
        $application.ShutdownMode = [System.Windows.ShutdownMode]::OnMainWindowClose
        [void]$application.Run($window)
        if ($state.DisplayFailed) { throw 'The question alert could not stay topmost.' }
    } finally {
        $state.Finalizing = $true
        try {
            if ($timer) { $timer.Stop() }
            if ($player) { $player.Close() }
            if ($window) { $window.Close() }
        } finally {
            if ($coordination) {
                try {
                    if ($state.OwnsOwner) { $coordination.Owner.ReleaseMutex() }
                } finally {
                    if ($state.OwnsGate) { $coordination.Gate.ReleaseMutex() }
                    $coordination.Signal.Dispose()
                    $coordination.Owner.Dispose()
                    $coordination.Gate.Dispose()
                }
            }
        }
    }
}
