<#
    Hook-AgentStopSound.ps1

    Copilot CLI "agentStop" hook -- fires when the main agent finishes its turn and yields
    control back to you (its final message has come in). It does NOT fire on turns that end by
    asking a question via ask_user, so this "done" cue stays distinct from the question toast.

    Plays a short, distinct "done" sound (chimes) so you know -- by ear -- that the agent has
    finished its final response. No toast.

    SUB-AGENT FILTER: agentStop also fires when a sub-agent (spawned via the task/explore tools)
    finishes. Those stops are suppressed so only the MAIN agent chimes. A sub-agent stop is
    identified from the stdin payload: its "sessionId" is the parent tool-call id (e.g. "toolu_..."
    / "call_...") and its "transcriptPath" is empty, whereas the main agent's "sessionId" is the
    real session GUID and its "transcriptPath" points at events.jsonl. We therefore play ONLY when
    "sessionId" is a GUID -- model-agnostic, since a tool-call id is never a GUID. Verified against
    the session events.jsonl (18 main-agent stops = GUID; 3 sub-agent stops = non-GUID/empty path).

    The sound is played by a DETACHED copy of this script (-Play), so the hook returns
    immediately and never delays the next prompt (PlaySync would otherwise block ~1s).

    This is a side-effect-only hook: it never blocks the agent (no decision output, exit 0).

    Based ONLY on:
        https://docs.github.com/en/copilot/reference/hooks-reference
        https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/use-hooks
#>
param([switch]$Play)

$soundFile = 'C:\Windows\Media\chimes.wav'

if ($Play) {
    # Detached worker: play the sound to completion, then exit.
    try { (New-Object System.Media.SoundPlayer $soundFile).PlaySync() } catch {}
    return
}

# Hook mode: read the agentStop payload from stdin and suppress sub-agent stops.
# Play only when sessionId is a real session GUID (main agent). Any sub-agent stop, empty
# stdin, or unparseable payload yields silence -- fail toward no spurious chime.
try {
    $raw = [Console]::In.ReadToEnd()
    $payload = $raw | ConvertFrom-Json
    $sessionId = [string]$payload.sessionId
} catch {
    exit 0
}

$guidRegex = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
if ($sessionId -notmatch $guidRegex) {
    # Sub-agent (tool-call-id sessionId) or unknown -- stay silent.
    exit 0
}

# Main-agent stop: launch a detached copy to play the sound, then return at once. The script
# path may contain a space, so it is quoted inside the single argument string
# (Start-Process -ArgumentList arrays do not quote individual args).
try {
    $argLine = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Play"
    Start-Process -FilePath 'powershell' -ArgumentList $argLine -WindowStyle Hidden | Out-Null
} catch {}

exit 0
