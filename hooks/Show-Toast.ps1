<#
    Show-Toast.ps1

    Raises a single modern Windows toast (WinRT ToastNotification). Shared by the focus-toast
    hooks. Does NOT perform a focus check -- callers decide whether to show a toast.

    IMPORTANT: WinRT toast types are only projected in Windows PowerShell 5.1 (powershell.exe),
    not PowerShell 7 (pwsh). This script MUST be launched with powershell.exe. The pwsh hook
    handlers launch it detached for exactly this reason. (NotifyIcon balloons were tried first
    but do not display from a detached/background process even though ShowBalloonTip succeeds;
    the WinRT toast displays reliably from a detached process.)

    The parent passes only a fixed notification kind. The toast does not include question,
    permission, command, path, or session text.

    Based ONLY on:
        https://docs.github.com/en/copilot/reference/hooks-reference
        https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/use-hooks
#>
param(
    [Parameter(Mandatory)]
    [ValidateSet('question', 'permission')]
    [string]$Kind
)

. "$PSScriptRoot\HookLog.Common.ps1"

try {
    $title = if ($Kind -eq 'question') {
        'Copilot CLI - question'
    } else {
        'Copilot CLI - permission needed'
    }
    $body = 'Switch to the terminal to respond.'

    [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
    [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom, ContentType = WindowsRuntime]

    $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
    $template = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
    $texts = $template.GetElementsByTagName('text')
    [void]$texts.Item(0).AppendChild($template.CreateTextNode($title))
    [void]$texts.Item(1).AppendChild($template.CreateTextNode($body))

    $toast = New-Object Windows.UI.Notifications.ToastNotification($template)
    $notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId)
    if ([string]$notifier.Setting -ne 'Enabled') { throw 'notifications disabled' }
    $notifier.Show($toast)
    Write-HookResult -Hook 'toast-renderer' -Outcome 'worked' -Code 'toast_displayed'
} catch {
    Write-HookResult -Hook 'toast-renderer' -Outcome 'did_not_work' -Code 'toast_display_failed'
    exit 0
}
