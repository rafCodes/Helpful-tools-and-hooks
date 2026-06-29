<#
    Show-Toast.ps1

    Raises a single modern Windows toast (WinRT ToastNotification). Shared by the focus-toast
    hooks. Does NOT perform a focus check -- callers decide whether to show a toast.

    IMPORTANT: WinRT toast types are only projected in Windows PowerShell 5.1 (powershell.exe),
    not PowerShell 7 (pwsh). This script MUST be launched with powershell.exe. The pwsh hook
    handlers launch it detached for exactly this reason. (NotifyIcon balloons were tried first
    but do not display from a detached/background process even though ShowBalloonTip succeeds;
    the WinRT toast displays reliably from a detached process.)

    Invocation:
      powershell.exe -NoProfile -ExecutionPolicy Bypass -File Show-Toast.ps1 -PayloadFile <json>

    The temp JSON file holds { Title, Message }. A temp file is used (rather than command-line
    args) so arbitrary question text -- spaces, quotes, em-dashes, parentheses -- is passed
    without command-line quoting hazards. The file is deleted once read.

    The caller's title is trusted. The caller's message is untrusted (agent-supplied): it is
    whitespace/control-stripped and length-capped so it cannot spoof the title or push the
    trusted action line out of view. (WinRT also XML-escapes the text nodes.)

    Based ONLY on:
        https://docs.github.com/en/copilot/reference/hooks-reference
        https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/use-hooks
#>
param(
    [string]$Title,
    [string]$Message,
    [string]$PayloadFile
)

if ($PayloadFile) {
    # Written as UTF-8 by the pwsh launcher; read it back as UTF-8 explicitly so non-ASCII
    # (em-dashes, smart quotes, accents) survive -- Windows PowerShell 5.1 would otherwise
    # default to the ANSI code page and mojibake them.
    $p = Get-Content -LiteralPath $PayloadFile -Raw -Encoding UTF8 | ConvertFrom-Json
    Remove-Item -LiteralPath $PayloadFile -Force -ErrorAction SilentlyContinue
    $Title = [string]$p.Title
    $Message = [string]$p.Message
}

$action = 'Switch to the terminal to respond.'
$body = $action
if ($Message) {
    $clean = ($Message -replace '[\p{C}\s]+', ' ').Trim()
    if ($clean.Length -gt 120) { $clean = $clean.Substring(0, 120).TrimEnd() + '...' }
    if ($clean) { $body = "$clean - $action" }
}
if (-not $Title) { $Title = 'GitHub Copilot CLI' }

# WinRT toast (reliable from a detached process; requires Windows PowerShell 5.1).
[void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
[void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom, ContentType = WindowsRuntime]

$appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
$template = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
$texts = $template.GetElementsByTagName('text')
[void]$texts.Item(0).AppendChild($template.CreateTextNode($Title))
[void]$texts.Item(1).AppendChild($template.CreateTextNode($body))

$toast = New-Object Windows.UI.Notifications.ToastNotification($template)
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show($toast)
