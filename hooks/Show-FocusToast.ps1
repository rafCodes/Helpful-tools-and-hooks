<#
    Show-FocusToast.ps1

    Copilot CLI "notification" hook handler.

    Configured for "permission_prompt" and "elicitation_dialog" notifications.

    Behaviour: if the terminal window hosting this CLI is NOT the foreground window,
    raise a Windows toast so the user knows to switch back to the terminal. If the
    terminal already has focus, do nothing.

    Reads only notification_type from stdin. This notification field uses snake_case.
    The handler ignores message and title.
    Output (stdout, JSON): {}  -> take no session action.

    Based ONLY on:
        https://docs.github.com/en/copilot/reference/hooks-reference
        https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/use-hooks
#>

. "$PSScriptRoot\FocusToast.Common.ps1"

# --- Read the notification payload from stdin (UTF-8; see Read-HookStdin). ---
try {
    $raw = Read-HookStdin
    if (-not $raw) { throw 'invalid input' }

    $payload = $raw | ConvertFrom-Json -AsHashtable -NoEnumerate -ErrorAction Stop
    if ($payload -isnot [System.Collections.IDictionary] -or $payload['notification_type'] -isnot [string]) {
        throw 'invalid input'
    }
    $notificationType = $payload['notification_type']

    if ($notificationType -cnotin @('permission_prompt', 'elicitation_dialog')) {
        Write-HookResult -Hook 'notification' -Outcome 'did_not_work' -Code 'unsupported_notification'
        '{}'
        exit 0
    }
} catch {
    Write-HookResult -Hook 'notification' -Outcome 'did_not_work' -Code 'invalid_input'
    '{}'
    exit 0
}

try {
    if (Test-TerminalFocused) {
        Write-HookResult -Hook 'notification' -Outcome 'worked' -Code 'focused'
        '{}'
        exit 0
    }
} catch {
    Write-HookResult -Hook 'notification' -Outcome 'did_not_work' -Code 'focus_check_failed'
    '{}'
    exit 0
}

$kind = if ($notificationType -ceq 'elicitation_dialog') {
    'question'
} else {
    'permission'
}

[void](Start-FocusToast -Kind $kind)

'{}'
