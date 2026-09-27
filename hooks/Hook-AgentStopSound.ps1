<#
    Hook-AgentStopSound.ps1

    Copilot CLI "agentStop" hook -- fires when the main agent finishes its turn and yields
    control back to you (its final message has come in). It does NOT fire on turns that end by
    asking a question via ask_user, so this "done" cue stays distinct from the question toast.

    Plays a short, distinct "done" sound (chimes) so you know -- by ear -- that the agent has
    finished its final response. No toast.

    SUB-AGENT FILTER: agentStop also fires when a sub-agent finishes. The main agent's
    sessionId matches the session directory that contains transcriptPath. Sub-agent IDs do not
    match that directory, so those stops are suppressed.

    The sound is played by a DETACHED copy of this script (-Play), so the hook returns
    immediately and never delays the next prompt (PlaySync would otherwise block ~1s).

    This is a side-effect-only hook: it never blocks the agent (no decision output, exit 0).

    Based ONLY on:
        https://docs.github.com/en/copilot/reference/hooks-reference
        https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/use-hooks
#>
param([switch]$Play)

$soundFile = Join-Path $env:SystemRoot 'Media\chimes.wav'
. "$PSScriptRoot\HookLog.Common.ps1"

if ($Play) {
    try {
        (New-Object System.Media.SoundPlayer $soundFile).PlaySync()
        Write-HookResult -Hook 'agent-stop-sound' -Outcome 'worked' -Code 'sound_played'
    } catch {
        Write-HookResult -Hook 'agent-stop-sound' -Outcome 'did_not_work' -Code 'sound_play_failed'
    }
    return
}

# Hook mode: read the payload and play only when sessionId matches the transcript session.
try {
    $raw = Read-HookStdin
    if (-not $raw) { throw 'invalid input' }
    $payload = $raw | ConvertFrom-Json -ErrorAction Stop
    if ($null -eq $payload) { throw 'invalid input' }
    $sessionId = [string]$payload.sessionId
    $transcriptPath = [string]$payload.transcriptPath
} catch {
    Write-HookResult -Hook 'agent-stop-sound' -Outcome 'did_not_work' -Code 'invalid_stop_payload'
    exit 0
}

if (-not (Test-MainAgentStop -SessionId $sessionId -TranscriptPath $transcriptPath)) {
    Write-HookResult -Hook 'agent-stop-sound' -Outcome 'worked' -Code 'subagent_suppressed'
    exit 0
}

# Main-agent stop: launch a detached copy to play the sound, then return at once. The script
# path may contain a space, so it is quoted inside the single argument string
# (Start-Process -ArgumentList arrays do not quote individual args).
try {
    $argLine = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Play"
    $powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Start-Process -FilePath $powershellPath -ArgumentList $argLine -WindowStyle Hidden -ErrorAction Stop | Out-Null
    $dispatched = $true
} catch {
    $dispatched = $false
}

if ($dispatched) {
    Write-HookResult -Hook 'agent-stop-sound' -Outcome 'worked' -Code 'sound_dispatched'
} else {
    Write-HookResult -Hook 'agent-stop-sound' -Outcome 'did_not_work' -Code 'sound_dispatch_failed'
}

exit 0
