<#
    Hook-AskUserToast.ps1

    Copilot CLI "preToolUse" hook handler, configured with matcher "ask_user".

    Why preToolUse instead of the notification hook: this terminal renders the ask_user
    tool inline and does not emit an elicitation_dialog notification, so the notification
    hook never fires for questions. The ask_user tool call itself DOES go through
    preToolUse, and the question text is in its arguments.

    Behaviour: when the agent is about to ask the user a question and the terminal is NOT
    the foreground window, raise a Windows toast showing the question. If the terminal is
    focused, do nothing.

    preToolUse is BLOCKING and fail-closed (a crash / non-zero exit would DENY the tool
    call). Therefore:
      * The focus check runs here, in this live hook process, while it is still attached to
        the terminal's process tree (a detached child could not see the terminal).
      * The toast is launched DETACHED (a separate powershell.exe running the WinRT renderer)
        so this blocking hook returns immediately and never delays the prompt.
      * This script always returns "{}" and exits 0 so it can never deny the question.

    Input  (stdin, JSON): preToolUse camelCase payload incl. toolName (string) and
                          toolArgs (JSON string; ask_user's args contain "question").
    Output (stdout, JSON): {}  -> no permission decision (fall through to normal flow).

    Based ONLY on:
        https://docs.github.com/en/copilot/reference/hooks-reference
        https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/use-hooks
#>

. "$PSScriptRoot\FocusToast.Common.ps1"

# preToolUse is fail-closed: an unhandled error / non-zero exit would DENY the ask_user
# call. Wrap everything so this hook can NEVER block a question -- on any failure it falls
# through to the unconditional "{}" / exit 0 below.
try {
    # Read the preToolUse payload as UTF-8 (see Read-HookStdin re: console encoding).
    $question = $null
    $raw = Read-HookStdin
    if ($raw) {
        $payload = $raw | ConvertFrom-Json
        # preToolUse camelCase payload: toolName (string) + toolArgs (JSON string).
        if ($payload.toolName -eq 'ask_user' -and $payload.toolArgs) {
            $question = ($payload.toolArgs | ConvertFrom-Json).question
        }
    }

    # Only act on an ask_user call while the terminal is not focused. Start-FocusToast
    # launches the toast detached (and via powershell.exe for WinRT), so this returns at once.
    if ($question -and -not (Test-TerminalFocused)) {
        Start-FocusToast -Title 'Copilot CLI - question' -Message $question
    }
} catch {
    # Intentionally swallow: this fail-closed hook must never deny a question on error.
}

# Never deny the tool: emit an empty decision and exit 0.
'{}'
exit 0
