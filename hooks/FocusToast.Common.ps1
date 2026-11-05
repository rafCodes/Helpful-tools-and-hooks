<#
    FocusToast.Common.ps1

    Shared helper for the terminal-focus-toast hooks. Dot-source this file:
        . "$PSScriptRoot\FocusToast.Common.ps1"

    Provides focus detection and detached dispatch for notification and compaction hooks.

    Based ONLY on:
        https://docs.github.com/en/copilot/reference/hooks-reference
        https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/use-hooks
#>

. "$PSScriptRoot\Compaction.Common.ps1"

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
    if (-not ('CopilotFocus.Win' -as [type])) {
        Add-Type -Namespace CopilotFocus -Name Win -MemberDefinition @'
[DllImport("user32.dll")] public static extern System.IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr hWnd, out uint processId);
'@ -ErrorAction Stop
    }
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
        Launch the notification renderer (Show-Toast.ps1) detached, so the calling hook
        returns immediately and is never delayed by the alert.

        Show-Toast uses the WinRT toast API, which is only projected in Windows PowerShell 5.1.
        The command line contains a fixed kind and, for compaction, a validated session ID.
        The renderer reads the session name from local metadata. No agent text is passed.
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateSet('question', 'permission', 'compaction')]
        [string]$Kind,
        [string]$SessionId
    )

    $toast = Join-Path $PSScriptRoot 'Show-Toast.ps1'
    $powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $argLine = "-NoProfile -STA -ExecutionPolicy Bypass -File `"$toast`" -Kind $Kind"
    $dispatched = $false
    $hook = if ($Kind -eq 'compaction') { 'pre-compact' } else { 'notification' }
    $codePrefix = switch ($Kind) {
        'question' { 'question_alert' }
        'compaction' { 'compaction_alert' }
        'permission' { 'toast' }
    }

    try {
        if ($Kind -eq 'compaction') {
            $argLine += ' -SessionId ' + (ConvertTo-CompactionSessionId -SessionId $SessionId)
        }
        Start-Process -FilePath $powershellPath `
            -ArgumentList $argLine `
            -WindowStyle Hidden `
            -ErrorAction Stop | Out-Null
        $dispatched = $true
    } catch {
        $dispatched = $false
    }

    if ($dispatched) {
        Write-HookResult -Hook $hook -Outcome 'worked' -Code ($codePrefix + '_dispatched')
    } else {
        Write-HookResult -Hook $hook -Outcome 'did_not_work' -Code ($codePrefix + '_dispatch_failed')
    }
    return $dispatched
}
