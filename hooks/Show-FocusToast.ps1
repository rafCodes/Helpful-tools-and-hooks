<#
    Show-FocusToast.ps1

    Copilot CLI "notification" hook handler.

    Configured (in the shared setup-hooks hooks.json) with matcher "permission_prompt", so
    this script only runs when the agent requests permission to execute a tool.

    Behaviour: if the terminal window hosting this CLI is NOT the foreground window,
    raise a Windows toast so the user knows to switch back to the terminal. If the
    terminal already has focus, do nothing.

    (Questions asked via the ask_user tool are handled separately by Hook-AskUserToast.ps1,
    because this terminal renders ask_user inline and does not emit an elicitation_dialog
    notification.)

    Input  (stdin, JSON): notification_type, message (+ sessionId, timestamp, cwd, hook_event_name, title)
    Output (stdout, JSON): {}  -> take no session action.

    Based ONLY on:
        https://docs.github.com/en/copilot/reference/hooks-reference
        https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/use-hooks
#>

. "$PSScriptRoot\FocusToast.Common.ps1"

# --- Read the notification payload from stdin (UTF-8; see Read-HookStdin). ---
$notificationType = $null
$payloadMessage = $null
$raw = Read-HookStdin
if ($raw) {
    $payload = $raw | ConvertFrom-Json
    $notificationType = $payload.notification_type
    $payloadMessage = $payload.message
}

if (Test-TerminalFocused) {
    # Terminal already has focus -> the user can see the prompt. Do nothing.
    '{}'
    return
}

# --- Terminal is NOT focused -> raise a toast. Title is trusted, not from the payload. ---
$title = 'GitHub Copilot CLI'
if ($notificationType -eq 'permission_prompt') { $title = 'Copilot CLI - permission needed' }

Start-FocusToast -Title $title -Message ([string]$payloadMessage)

'{}'
