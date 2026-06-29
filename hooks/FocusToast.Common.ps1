<#
    FocusToast.Common.ps1

    Shared helper for the terminal-focus-toast hooks. Dot-source this file:
        . "$PSScriptRoot\FocusToast.Common.ps1"

    Provides Test-TerminalFocused, used by both the notification-hook handler
    (Show-FocusToast.ps1) and the preToolUse ask_user handler (Hook-AskUserToast.ps1).

    Based ONLY on:
        https://docs.github.com/en/copilot/reference/hooks-reference
        https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/use-hooks
#>

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

function Read-HookStdin {
    <#
        Read the hook's stdin payload as UTF-8 (bounded). [Console]::In decodes using
        [Console]::InputEncoding, which is the OEM code page on Windows (e.g. IBM437) and
        mojibakes UTF-8 bytes -- em-dashes, smart quotes, accents. The CLI writes the payload
        as UTF-8, so read the raw standard-input stream decoded as UTF-8 instead.
    #>
    if (-not [Console]::IsInputRedirected) { return '' }
    $reader = New-Object System.IO.StreamReader([Console]::OpenStandardInput(), [System.Text.Encoding]::UTF8)
    $buffer = [char[]]::new(65536)
    $count = $reader.Read($buffer, 0, $buffer.Length)
    if ($count -gt 0) { return [string]::new($buffer, 0, $count) }
    return ''
}

function Start-FocusToast {
    <#
        Launch the toast renderer (Show-Toast.ps1) detached, so the calling hook returns
        immediately and is never delayed by the toast.

        Show-Toast uses the WinRT toast API, which is only projected in Windows PowerShell 5.1
        (powershell.exe), NOT PowerShell 7 (pwsh) -- so we launch it via powershell.exe even
        though the hooks themselves run under pwsh. The title/message are passed via a temp
        JSON file so arbitrary question text needs no command-line quoting; Show-Toast deletes
        the file once read.
    #>
    param(
        [Parameter(Mandatory)][string]$Title,
        [string]$Message
    )
    $toast = Join-Path $PSScriptRoot 'Show-Toast.ps1'
    $tmp = Join-Path $env:TEMP ("copilot-toast-{0}.json" -f [guid]::NewGuid().ToString('N'))
    (@{ Title = $Title; Message = [string]$Message } | ConvertTo-Json -Compress) |
        Set-Content -LiteralPath $tmp -Encoding utf8
    $argLine = "-NoProfile -ExecutionPolicy Bypass -File `"$toast`" -PayloadFile `"$tmp`""
    Start-Process -FilePath 'powershell' -ArgumentList $argLine -WindowStyle Hidden | Out-Null
}

