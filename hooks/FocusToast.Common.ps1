<#
    FocusToast.Common.ps1

    Shared helper for the terminal-focus-toast hooks. Dot-source this file:
        . "$PSScriptRoot\FocusToast.Common.ps1"

    Provides focus detection and detached toast dispatch for Show-FocusToast.ps1.

    Based ONLY on:
        https://docs.github.com/en/copilot/reference/hooks-reference
        https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/use-hooks
#>

. "$PSScriptRoot\HookLog.Common.ps1"

Add-Type -Namespace CopilotFocus -Name Win -MemberDefinition @'
[DllImport("user32.dll")] public static extern System.IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr hWnd, out uint processId);
'@

function Test-TerminalFocused {
    <#
        Returns $true if the terminal window hosting this CLI is the foreground window.

        The hook runs as a descendant of the terminal process, so the terminal's
        window-owning process is one of THIS process's ancestors. We compare the
        foreground window's owning process against our ancestor PIDs.

        IMPORTANT: this must run inside a process that is still attached to the terminal's
        process tree (the live hook process). A detached child whose parent has already
        exited would have a broken ancestor chain and must NOT call this.
    #>
    $ancestorPids = New-Object 'System.Collections.Generic.HashSet[uint32]'
    $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$PID"
    while ($proc) {
        # HashSet.Add returns $false if the PID was already seen -> stop (guards against PID-reuse cycles).
        if (-not $ancestorPids.Add([uint32]$proc.ProcessId)) { break }
        if ($proc.ParentProcessId -le 0) { break }
        $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$($proc.ParentProcessId)"
    }

    $foregroundPid = [uint32]0
    [void][CopilotFocus.Win]::GetWindowThreadProcessId([CopilotFocus.Win]::GetForegroundWindow(), [ref]$foregroundPid)

    return ($foregroundPid -ne 0) -and $ancestorPids.Contains($foregroundPid)
}

function Start-FocusToast {
    <#
        Launch the toast renderer (Show-Toast.ps1) detached, so the calling hook returns
        immediately and is never delayed by the toast.

        Show-Toast uses the WinRT toast API, which is only projected in Windows PowerShell 5.1.
        The command line contains only a fixed notification kind. It does not contain agent text.
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateSet('question', 'permission')]
        [string]$Kind
    )

    $toast = Join-Path $PSScriptRoot 'Show-Toast.ps1'
    $powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $argLine = "-NoProfile -ExecutionPolicy Bypass -File `"$toast`" -Kind $Kind"
    $dispatched = $false

    try {
        Start-Process -FilePath $powershellPath `
            -ArgumentList $argLine `
            -WindowStyle Hidden `
            -ErrorAction Stop | Out-Null
        $dispatched = $true
    } catch {
        $dispatched = $false
    }

    if ($dispatched) {
        Write-HookResult -Hook 'notification' -Outcome 'worked' -Code 'toast_dispatched'
    } else {
        Write-HookResult -Hook 'notification' -Outcome 'did_not_work' -Code 'toast_dispatch_failed'
    }
    return $dispatched
}
