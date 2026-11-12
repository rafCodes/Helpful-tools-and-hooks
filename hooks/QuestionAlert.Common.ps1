. "$PSScriptRoot\Compaction.Common.ps1"
$script:QuestionAlertHeight = 220
$script:CornerAlertWidth = 520

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

public struct Bounds {
    public int Left, Top, Right, Bottom;
}

[DllImport("user32.dll", SetLastError = true)]
[return: MarshalAs(UnmanagedType.Bool)]
public static extern bool GetWindowRect(System.IntPtr window, out Bounds bounds);

[DllImport("user32.dll")]
public static extern uint GetDpiForWindow(System.IntPtr window);

[DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
[return: MarshalAs(UnmanagedType.Bool)]
public static extern bool SetProp(System.IntPtr window, string name, System.IntPtr value);

[DllImport("user32.dll", CharSet = CharSet.Unicode)]
public static extern System.IntPtr GetProp(System.IntPtr window, string name);

[DllImport("user32.dll", CharSet = CharSet.Unicode)]
public static extern System.IntPtr RemoveProp(System.IntPtr window, string name);

private delegate bool EnumWindowsProc(System.IntPtr window, System.IntPtr data);

[DllImport("user32.dll", SetLastError = true)]
[return: MarshalAs(UnmanagedType.Bool)]
private static extern bool EnumWindows(EnumWindowsProc callback, System.IntPtr data);

public static System.IntPtr[] GetCompactionWindows(string propertyName) {
    var windows = new System.Collections.Generic.List<System.IntPtr>();
    EnumWindowsProc callback = (window, data) => {
        if (GetProp(window, propertyName) == new System.IntPtr(2)) { windows.Add(window); }
        return true;
    };
    if (!EnumWindows(callback, System.IntPtr.Zero)) {
        throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
    }
    return windows.ToArray();
}

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
    param(
        [ValidateNotNullOrEmpty()][string]$NamePrefix = 'Local\CopilotHelpfulToolsQuestionIdentityAlert',
        [switch]$IncludeSession
    )

    $NamePrefix += '-' + (Get-QuestionAlertScope)
    $coordination = [pscustomobject]@{ Gate = $null; Owner = $null; Signal = $null; Session = $null }
    try {
        $coordination.Gate = [System.Threading.Mutex]::new($false, ($NamePrefix + 'Gate'))
        $coordination.Owner = [System.Threading.Mutex]::new($false, ($NamePrefix + 'Owner'))
        $coordination.Signal = [System.Threading.EventWaitHandle]::new(
            $false, [System.Threading.EventResetMode]::AutoReset, ($NamePrefix + 'Signal')
        )
        if ($IncludeSession) {
            $coordination.Session = [System.IO.MemoryMappedFiles.MemoryMappedFile]::CreateOrOpen(($NamePrefix + 'Session'), 36)
        }
        return $coordination
    } catch {
        foreach ($handle in @($coordination.Session, $coordination.Signal, $coordination.Owner, $coordination.Gate)) {
            if ($handle) { $handle.Dispose() }
        }
        throw
    }
}

function Set-QuestionAlertSession {
    param(
        [Parameter(Mandatory)][pscustomobject]$Coordination,
        [Parameter(Mandatory)][string]$SessionId
    )

    # Callers hold Gate so another process cannot read a partially written ID.
    $bytes = [System.Text.Encoding]::ASCII.GetBytes((ConvertTo-CompactionSessionId -SessionId $SessionId))
    $view = $Coordination.Session.CreateViewAccessor(0, 36)
    try {
        $view.WriteArray(0, $bytes, 0, $bytes.Length)
    } finally {
        $view.Dispose()
    }
}

function Get-QuestionAlertSession {
    param([Parameter(Mandatory)][pscustomobject]$Coordination)

    # Callers hold Gate, as on the write path.
    $view = $Coordination.Session.CreateViewAccessor(0, 36, [System.IO.MemoryMappedFiles.MemoryMappedFileAccess]::Read)
    try {
        $bytes = [byte[]]::new(36)
        if ($view.ReadArray(0, $bytes, 0, $bytes.Length) -ne $bytes.Length) {
            throw 'The question alert session ID is incomplete.'
        }
        return (ConvertTo-CompactionSessionId -SessionId ([System.Text.Encoding]::ASCII.GetString($bytes)))
    } finally {
        $view.Dispose()
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
    param(
        [ValidateSet('question', 'compaction', 'failure')][string]$Kind = 'question',
        [Parameter(Mandatory)][string]$SessionId
    )

    Initialize-QuestionAlert
    $markup = [xml]@"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Copilot CLI - question" Width="$script:CornerAlertWidth" Height="$script:QuestionAlertHeight"
        WindowStyle="ToolWindow" ResizeMode="NoResize"
        Topmost="True" ShowActivated="False" ShowInTaskbar="False"
        Background="#0F172A" Foreground="White">
    <Border x:Name="Frame" BorderBrush="#F59E0B" BorderThickness="3" Padding="18">
        <StackPanel>
            <TextBlock x:Name="Heading" Text="Copilot needs your answer" FontSize="20" FontWeight="Bold"/>
            <TextBlock x:Name="Instruction" Text="Switch to the terminal to respond." Margin="0,4,0,0"/>
            <ScrollViewer x:Name="MessageViewport" HorizontalScrollBarVisibility="Disabled"
                          VerticalScrollBarVisibility="Auto" MaxHeight="120">
                <TextBlock x:Name="Message" Margin="0,10,0,0" TextWrapping="Wrap"/>
            </ScrollViewer>
            <TextBlock x:Name="SessionId" Margin="0,6,0,0"/>
            <Button x:Name="Dismiss" Content="Dismiss" Width="90" Height="30"
                    HorizontalAlignment="Right" Margin="0,14,0,0"/>
        </StackPanel>
    </Border>
</Window>
"@
    $reader = [System.Xml.XmlNodeReader]::new($markup)
    try {
        $window = [System.Windows.Markup.XamlReader]::Load($reader)
        try {
            if ($Kind -eq 'compaction') {
                $window.Height = 300
                $window.FindName('Instruction').Visibility = [System.Windows.Visibility]::Collapsed
                $window.Title = 'Copilot CLI - compacting'
                $window.FindName('Heading').Text = 'Copilot is compacting'
            } else {
                $window.FindName('Frame').Padding = [System.Windows.Thickness]::new(12)
                $window.FindName('Message').Margin = [System.Windows.Thickness]::new(0, 2, 0, 0)
                $window.FindName('MessageViewport').MaxHeight = 34
                if ($Kind -eq 'failure') {
                    $window.Title = 'Copilot CLI - execution failed'
                    $window.FindName('Heading').Text = 'Copilot execution failed'
                    $window.FindName('Instruction').Text = 'Switch to the terminal to inspect the error.'
                    $window.FindName('Frame').BorderBrush = [System.Windows.Media.Brushes]::Tomato
                }
            }
            Set-SessionAlertContent -Window $window -Kind $Kind -SessionId $SessionId
        } catch {
            $window.Close()
            throw
        }
        return $window
    } finally {
        $reader.Close()
    }
}

function Set-SessionAlertContent {
    param(
        [Parameter(Mandatory)][System.Windows.Window]$Window,
        [Parameter(Mandatory)][ValidateSet('question', 'compaction', 'failure')][string]$Kind,
        [Parameter(Mandatory)][string]$SessionId
    )

    $SessionId = ConvertTo-CompactionSessionId -SessionId $SessionId
    if ($Kind -in @('question', 'failure')) { $Window.FindName('MessageViewport').ScrollToTop() }
    $Window.FindName('SessionId').Text = "Session ID: $SessionId"
    try {
        $sessionName = Get-CompactionSessionName -SessionId $SessionId
    } catch {
        $Window.FindName('Message').Text = 'Session name unavailable'
        $hook = switch ($Kind) {
            'compaction' { 'compaction-alert' }
            'failure' { 'failure-alert' }
            'question' { 'question-alert' }
        }
        Write-HookResult -Hook $hook -Outcome 'did_not_work' -Code 'session_name_unavailable'
        return
    }
    $Window.FindName('Message').Text = "Session: $sessionName"
}

function New-QuestionAlertWindow {
    param(
        [ValidateSet('question', 'compaction', 'failure')][string]$Kind = 'question',
        [Parameter(Mandatory)][string]$SessionId
    )

    $window = New-QuestionAlertContent -Kind $Kind -SessionId $SessionId
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
            throw 'The alert could not suppress mouse activation.'
        }
        $window.Tag = $Kind
        if ($Kind -eq 'compaction') {
            $scope = Get-QuestionAlertScope
            $window.Resources['AlertScope'] = $scope
            $window.Resources['CompactionLayoutFailed'] = $false
            $window.Resources['CompactionClampFailed'] = $false
            $propertyName = 'CopilotHelpfulToolsAlert-' + $scope
            $window.Add_Closed({ [void][CopilotQuestionAlert.Native]::RemoveProp($handle, $propertyName) }.GetNewClosure())
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
    if ($Window.Tag -ceq 'compaction') {
        Set-CompactionAlertLayout -Window $Window -Screen $screen
        return
    }
    Move-CornerAlertToWorkArea -Window $Window -WorkArea $screen.WorkingArea
}

function Move-CornerAlertToWorkArea {
    param(
        [Parameter(Mandatory)][System.Windows.Window]$Window,
        [Parameter(Mandatory)][System.Drawing.Rectangle]$WorkArea
    )

    $handle = [System.Windows.Interop.WindowInteropHelper]::new($Window).EnsureHandle()
    $source = [System.Windows.Interop.HwndSource]::FromHwnd($handle)
    $leftEdge = $source.CompositionTarget.TransformFromDevice.Transform(
        [System.Windows.Point]::new($WorkArea.Left, $WorkArea.Top)
    )
    $rightEdge = $source.CompositionTarget.TransformFromDevice.Transform(
        [System.Windows.Point]::new($WorkArea.Right, $WorkArea.Top)
    )
    $Window.Top = $leftEdge.Y + 16
    if ($Window.Tag -ceq 'failure') {
        $Window.Left = $leftEdge.X + 16
        if (($rightEdge.X - $leftEdge.X) -lt (2 * $script:CornerAlertWidth + 32)) {
            $Window.Top += $script:QuestionAlertHeight + 12
        }
    } else {
        $Window.Left = $rightEdge.X - $Window.Width - 16
    }
}

function Set-CompactionAlertLayout {
    param(
        [Parameter(Mandatory)][System.Windows.Window]$Window,
        [Parameter(Mandatory)][System.Windows.Forms.Screen]$Screen
    )

    $handle = [System.Windows.Interop.WindowInteropHelper]::new($Window).EnsureHandle()
    $propertyName = 'CopilotHelpfulToolsAlert-' + $Window.Resources['AlertScope']
    $isAdmitted = [CopilotQuestionAlert.Native]::GetProp($handle, $propertyName) -eq [IntPtr]::new(2)
    $mutex = [System.Threading.Mutex]::new($false, ('Local\CopilotHelpfulToolsAlertLayout-' + $Window.Resources['AlertScope']))
    $locked = $false
    $logLayoutFailure = $false
    $logClampFailure = $false
    try {
        $locked = Wait-QuestionAlertMutex -Mutex $mutex -TimeoutMilliseconds 2000
        if (-not $locked) { throw 'The compaction alert layout lock timed out.' }
        $isAdmitted = [CopilotQuestionAlert.Native]::GetProp($handle, $propertyName) -eq [IntPtr]::new(2)
        if ($isAdmitted) { $Screen = [System.Windows.Forms.Screen]::FromHandle($handle) }
        if (-not $isAdmitted -and [System.Windows.Forms.Screen]::FromHandle($handle).DeviceName -cne $Screen.DeviceName) {
            [void][CopilotQuestionAlert.Native]::RemoveProp($handle, $propertyName)
            if (-not [CopilotQuestionAlert.Native]::SetWindowPos(
                $handle, [IntPtr]::Zero, ($Screen.WorkingArea.Left + 16), ($Screen.WorkingArea.Top + 16), 0, 0, 0x0015
            )) {
                throw 'The compaction alert could not move to the active monitor.'
            }
        }
        $Window.UpdateLayout()
        $dpi = [CopilotQuestionAlert.Native]::GetDpiForWindow($handle)
        if ($dpi -eq 0) { throw 'The compaction alert DPI is unavailable.' }
        $scale = $dpi / 96.0
        $margin = [int][Math]::Ceiling(16 * $scale)
        $gap = [int][Math]::Ceiling(12 * $scale)
        $handles = @([CopilotQuestionAlert.Native]::GetCompactionWindows($propertyName))
        if ($handle -notin $handles) { $handles += $handle }
        $alerts = @(
            foreach ($item in $handles) {
                if ($item -ne $handle -and [System.Windows.Forms.Screen]::FromHandle($item).DeviceName -cne $Screen.DeviceName) {
                    continue
                }
                $bounds = [CopilotQuestionAlert.Native+Bounds]::new()
                if ($item -ne $handle -and [CopilotQuestionAlert.Native]::GetProp($item, $propertyName) -ne [IntPtr]::new(2)) { continue }
                if (-not [CopilotQuestionAlert.Native]::GetWindowRect($item, [ref]$bounds)) {
                    if ($item -eq $handle -or [CopilotQuestionAlert.Native]::GetProp($item, $propertyName) -eq [IntPtr]::new(2)) {
                        throw 'The compaction alert bounds are unavailable.'
                    }
                    continue
                }
                [pscustomobject]@{ Handle = $item; Bounds = $bounds }
            }
        ) | Sort-Object { $_.Handle.ToInt64() }
        $columnWidth = ($alerts | ForEach-Object { $_.Bounds.Right - $_.Bounds.Left } | Measure-Object -Maximum).Maximum
        $left = $Screen.WorkingArea.Right - $margin - $columnWidth
        $bottom = $Screen.WorkingArea.Bottom - $margin
        # Reserve the question and failure cards' top corners even when they are closed.
        $leftCornerHeight = $script:QuestionAlertHeight
        if ($Screen.WorkingArea.Width -lt ((2 * $script:CornerAlertWidth + 32) * $scale)) {
            $leftCornerHeight += $script:QuestionAlertHeight + 12
        }
        $leftCornerEdge = $Screen.WorkingArea.Left + $margin + [int][Math]::Ceiling($script:CornerAlertWidth * $scale)
        $top = $Screen.WorkingArea.Top + $margin + [int][Math]::Ceiling($script:QuestionAlertHeight * $scale) + $gap
        if ($left -lt $leftCornerEdge) {
            $top = [Math]::Max($top, ($Screen.WorkingArea.Top + $margin + [int][Math]::Ceiling($leftCornerHeight * $scale) + $gap))
        }
        $positions = [System.Collections.Generic.List[object]]::new()
        foreach ($alert in $alerts) {
            $height = $alert.Bounds.Bottom - $alert.Bounds.Top
            if ($bottom - $height -lt $top) {
                $left -= $columnWidth + $gap
                $bottom = $Screen.WorkingArea.Bottom - $margin
                $top = $Screen.WorkingArea.Top + $margin
                if ($left -lt $leftCornerEdge) {
                    $top += [int][Math]::Ceiling($leftCornerHeight * $scale) + $gap
                }
            }
            if ($height -le 0 -or $columnWidth -le 0 -or $left -lt $Screen.WorkingArea.Left + $margin -or
                $bottom - $height -lt $top) {
                throw 'The compaction alerts do not fit in the monitor work area.'
            }
            $positions.Add([pscustomobject]@{ Alert = $alert; Left = [int]$left; Top = [int]($bottom - $height) })
            $bottom -= $height + $gap
        }
        # Publish only after admission, while peer reflows still hold off on this mutex.
        if ([CopilotQuestionAlert.Native]::GetProp($handle, $propertyName) -ne [IntPtr]::new(2) -and
            -not [CopilotQuestionAlert.Native]::SetProp($handle, $propertyName, [IntPtr]::new(2))) {
            throw [System.ComponentModel.Win32Exception]::new(
                [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
            )
        }
        foreach ($position in $positions) {
            if ($position.Alert.Handle -eq $handle) {
                $source = [System.Windows.Interop.HwndSource]::FromHwnd($handle)
                $point = $source.CompositionTarget.TransformFromDevice.Transform(
                    [System.Windows.Point]::new($position.Left, $position.Top)
                )
                $Window.Left = $point.X
                $Window.Top = $point.Y
                continue
            }
            if ($position.Alert.Bounds.Left -eq $position.Left -and $position.Alert.Bounds.Top -eq $position.Top) { continue }
            if ([CopilotQuestionAlert.Native]::GetProp($position.Alert.Handle, $propertyName) -ne [IntPtr]::new(2)) { continue }
            # Post cross-process moves so a GUI thread waiting for this lock cannot block us.
            if (-not [CopilotQuestionAlert.Native]::SetWindowPos(
                $position.Alert.Handle, [IntPtr]::Zero, $position.Left, $position.Top, 0, 0, 0x4015
            )) {
                if ([CopilotQuestionAlert.Native]::GetProp($position.Alert.Handle, $propertyName) -eq [IntPtr]::new(2)) {
                    throw 'The compaction alerts could not be positioned.'
                }
            }
        }
        $Window.Resources['CompactionLayoutFailed'] = $false
        $Window.Resources['CompactionClampFailed'] = $false
    } catch {
        if ($isAdmitted) {
            if (-not $Window.Resources['CompactionLayoutFailed']) {
                $Window.Resources['CompactionLayoutFailed'] = $true
                $logLayoutFailure = $true
            }
            try {
                $bounds = [CopilotQuestionAlert.Native+Bounds]::new()
                if (-not [CopilotQuestionAlert.Native]::GetWindowRect($handle, [ref]$bounds)) {
                    throw 'The existing compaction card bounds are unavailable.'
                }
                $area = [System.Windows.Forms.Screen]::FromHandle($handle).WorkingArea
                $left = [Math]::Min([Math]::Max($bounds.Left, $area.Left), [Math]::Max($area.Left, $area.Right - ($bounds.Right - $bounds.Left)))
                $top = [Math]::Min([Math]::Max($bounds.Top, $area.Top), [Math]::Max($area.Top, $area.Bottom - ($bounds.Bottom - $bounds.Top)))
                $source = [System.Windows.Interop.HwndSource]::FromHwnd($handle)
                $point = $source.CompositionTarget.TransformFromDevice.Transform([System.Windows.Point]::new($left, $top))
                $Window.Left = $point.X
                $Window.Top = $point.Y
                $Window.Resources['CompactionClampFailed'] = $false
            } catch {
                if (-not $Window.Resources['CompactionClampFailed']) {
                    $Window.Resources['CompactionClampFailed'] = $true
                    $logClampFailure = $true
                }
            }
            return
        }
        [void][CopilotQuestionAlert.Native]::RemoveProp($handle, $propertyName)
        throw
    } finally {
        if ($locked) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
        if ($logLayoutFailure) {
            Write-HookResult -Hook 'compaction-alert' -Outcome 'did_not_work' -Code 'compaction_alert_layout_failed'
        }
        if ($logClampFailure) {
            Write-HookResult -Hook 'compaction-alert' -Outcome 'did_not_work' -Code 'compaction_alert_clamp_failed'
        }
    }
}

function Set-QuestionAlertTopmost {
    param([Parameter(Mandatory)][System.Windows.Window]$Window)

    $handle = [System.Windows.Interop.WindowInteropHelper]::new($Window).EnsureHandle()
    if ($Window.Tag -ceq 'compaction') {
        Set-CompactionAlertLayout -Window $Window -Screen ([System.Windows.Forms.Screen]::FromHandle($handle))
    }
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
        [switch]$Replay,
        [ValidateSet('question', 'compaction', 'failure')][string]$Kind = 'question'
    )

    $hook = switch ($Kind) {
        'compaction' { 'compaction-alert' }
        'failure' { 'failure-alert' }
        'question' { 'question-alert' }
    }
    $codePrefix = switch ($Kind) {
        'compaction' { 'compaction_alert' }
        'failure' { 'failure_alert' }
        'question' { 'question_alert' }
    }
    try {
        $Player.Stop()
        $Player.Play()
        if ($Replay) {
            Write-HookResult -Hook $hook -Outcome 'worked' -Code ($codePrefix + '_replayed')
        }
        return $true
    } catch {
        Write-HookResult -Hook $hook -Outcome 'did_not_work' -Code 'sound_play_failed'
        return $false
    }
}

function Invoke-QuestionAlertRepeat {
    param(
        [Parameter(Mandatory)][System.Windows.Window]$Window,
        [System.Windows.Media.MediaPlayer]$Player,
        [Parameter(Mandatory)][pscustomobject]$State
    )

    if ($State.Kind -in @('question', 'failure')) {
        $locked = Wait-QuestionAlertMutex -Mutex $State.Coordination.Gate -TimeoutMilliseconds 2000
        if (-not $locked) { throw 'The question alert session lock timed out.' }
        try {
            $State.SessionId = Get-QuestionAlertSession -Coordination $State.Coordination
        } finally {
            $State.Coordination.Gate.ReleaseMutex()
        }
    }
    Set-SessionAlertContent -Window $Window -Kind $State.Kind -SessionId $State.SessionId
    Move-QuestionAlertToActiveMonitor -Window $Window
    Set-QuestionAlertTopmost -Window $Window
    if ($Player -and -not $State.SoundFailed) {
        if (-not (Start-QuestionAlertPlayback -Player $Player -Replay -Kind $State.Kind)) { $State.SoundFailed = $true }
    }
}

function Show-QuestionAlert {
    param(
        [ValidateSet('question', 'compaction', 'failure')][string]$Kind = 'question',
        [Parameter(Mandatory)][string]$SessionId
    )

    $SessionId = ConvertTo-CompactionSessionId -SessionId $SessionId
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
        Kind = $Kind
        SessionId = $SessionId
        Coordination = $null
        Hook = switch ($Kind) {
            'compaction' { 'compaction-alert' }
            'failure' { 'failure-alert' }
            'question' { 'question-alert' }
        }
        CodePrefix = switch ($Kind) {
            'compaction' { 'compaction_alert' }
            'failure' { 'failure_alert' }
            'question' { 'question_alert' }
        }
    }

    try {
        $coordination = if ($Kind -eq 'compaction') {
            New-QuestionAlertCoordination -NamePrefix ('Local\CopilotHelpfulToolsCompactionAlert-' + $SessionId)
        } elseif ($Kind -eq 'failure') {
            New-QuestionAlertCoordination -NamePrefix 'Local\CopilotHelpfulToolsExecutionFailureAlert' -IncludeSession
        } else {
            New-QuestionAlertCoordination -IncludeSession
        }
        $state.Coordination = $coordination
        $state.OwnsGate = Wait-QuestionAlertMutex -Mutex $coordination.Gate -TimeoutMilliseconds 2000
        if (-not $state.OwnsGate) { throw 'The question alert coordination lock timed out.' }
        if ($Kind -in @('question', 'failure')) {
            Set-QuestionAlertSession -Coordination $coordination -SessionId $SessionId
        }
        $state.OwnsOwner = Wait-QuestionAlertMutex -Mutex $coordination.Owner -TimeoutMilliseconds 0
        if (-not $state.OwnsOwner) {
            if (-not $coordination.Signal.Set()) { throw 'The question alert could not signal its existing window.' }
            $coordination.Gate.ReleaseMutex()
            $state.OwnsGate = $false
            Write-HookResult -Hook $state.Hook -Outcome 'worked' -Code ($state.CodePrefix + '_reused')
            return
        }
        [void]$coordination.Signal.Reset()
        $coordination.Gate.ReleaseMutex()
        $state.OwnsGate = $false

        $window = New-QuestionAlertWindow -Kind $Kind -SessionId $SessionId
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
                Write-HookResult -Hook $state.Hook -Outcome 'worked' -Code 'sound_played'
                $player.Stop()
            })
            $player.Add_MediaFailed({
                $state.SoundFailed = $true
                Write-HookResult -Hook $state.Hook -Outcome 'did_not_work' -Code 'sound_play_failed'
                $player.Close()
            })
        } catch {
            $state.SoundFailed = $true
            Write-HookResult -Hook $state.Hook -Outcome 'did_not_work' -Code 'sound_play_failed'
        }

        $window.Add_ContentRendered({
            try {
                Set-QuestionAlertTopmost -Window $window
                $timer.Start()
                Write-HookResult -Hook $state.Hook -Outcome 'worked' -Code ($state.CodePrefix + '_displayed')
            } catch {
                $state.DisplayFailed = $true
                $window.Close()
                return
            }

            if ($player -and -not $state.SoundFailed) {
                if (-not (Start-QuestionAlertPlayback -Player $player -Kind $Kind)) { $state.SoundFailed = $true }
            }
        })

        $application = [System.Windows.Application]::new()
        $application.ShutdownMode = [System.Windows.ShutdownMode]::OnMainWindowClose
        [void]$application.Run($window)
        if ($state.DisplayFailed) { throw 'The alert could not stay topmost.' }
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
                    if ($coordination.Session) { $coordination.Session.Dispose() }
                    $coordination.Signal.Dispose()
                    $coordination.Owner.Dispose()
                    $coordination.Gate.Dispose()
                }
            }
        }
    }
}
