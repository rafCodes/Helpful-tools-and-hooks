<#
    Hook: agentStop — fires after each Copilot turn completes.
    Reads the assistant's last message from events.jsonl and speaks it
    via the bundled text-to-speech engine.
    Receives JSON on stdin with: sessionId, timestamp, cwd, transcriptPath, stopReason
#>
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. "$scriptDir\HookLog.Common.ps1"

$enabledFile = Join-Path $scriptDir 'text-to-speech\enabled.txt'
$enabledValue = if (Test-Path -LiteralPath $enabledFile -PathType Leaf) {
    [string](Get-Content -LiteralPath $enabledFile -Raw -ErrorAction SilentlyContinue)
} else {
    ''
}
if ($enabledValue.Trim().ToLowerInvariant() -ne 'true') {
    Write-HookResult -Hook 'agent-stop-tts' -Outcome 'worked' -Code 'tts_disabled'
    exit 0
}

try {
    $inputJson = Read-HookStdin | ConvertFrom-Json -ErrorAction Stop
    if ($null -eq $inputJson) { throw 'invalid input' }
    $sessionId = [string]$inputJson.sessionId
    $transcriptPath = [string]$inputJson.transcriptPath
} catch {
    Write-HookResult -Hook 'agent-stop-tts' -Outcome 'did_not_work' -Code 'invalid_stop_payload'
    exit 0
}

if (-not (Test-MainAgentStop -SessionId $sessionId -TranscriptPath $transcriptPath)) {
    Write-HookResult -Hook 'agent-stop-tts' -Outcome 'worked' -Code 'subagent_suppressed'
    exit 0
}

try {
    $sessionRoot = [System.IO.Path]::GetFullPath((Join-Path $HOME '.copilot\session-state')) + [System.IO.Path]::DirectorySeparatorChar
    $resolvedTranscript = [System.IO.Path]::GetFullPath($transcriptPath)
} catch {
    Write-HookResult -Hook 'agent-stop-tts' -Outcome 'did_not_work' -Code 'transcript_rejected'
    exit 0
}

if ($resolvedTranscript.StartsWith('\\') -or
    -not $resolvedTranscript.StartsWith($sessionRoot, [StringComparison]::OrdinalIgnoreCase) -or
    [System.IO.Path]::GetFileName($resolvedTranscript) -ne 'events.jsonl') {
    Write-HookResult -Hook 'agent-stop-tts' -Outcome 'did_not_work' -Code 'transcript_rejected'
    exit 0
}

if (-not (Test-Path -LiteralPath $resolvedTranscript -PathType Leaf)) {
    Write-HookResult -Hook 'agent-stop-tts' -Outcome 'did_not_work' -Code 'transcript_missing'
    exit 0
}

$lastMsg = ""
Get-Content -LiteralPath $resolvedTranscript -Tail 30 -ErrorAction SilentlyContinue | ForEach-Object {
    try {
        $e = $_ | ConvertFrom-Json
        if ($e.type -eq "assistant.message" -and -not $e.data.parentToolCallId) {
            if ($e.data.content) {
                $lastMsg = $e.data.content
            } elseif ($e.data.toolRequests) {
                foreach ($req in $e.data.toolRequests) {
                    if ($req.name -eq "ask_user") {
                        $argsObj = $req.arguments
                        if ($argsObj.message) { $lastMsg = $argsObj.message }
                        elseif ($argsObj.question) { $lastMsg = $argsObj.question }
                    }
                }
            }
        }
    } catch {}
}

if (-not $lastMsg) {
    Write-HookResult -Hook 'agent-stop-tts' -Outcome 'did_not_work' -Code 'message_missing'
    exit 0
}

$speakScript = Join-Path $scriptDir "text-to-speech\speak.py"
$speakScript = [System.IO.Path]::GetFullPath($speakScript)
if (-not (Test-Path -LiteralPath $speakScript -PathType Leaf)) {
    Write-HookResult -Hook 'agent-stop-tts' -Outcome 'did_not_work' -Code 'tts_script_missing'
    exit 0
}

$python = Get-Command python -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $python) {
    Write-HookResult -Hook 'agent-stop-tts' -Outcome 'did_not_work' -Code 'python_missing'
    exit 0
}

$lastMsg = $lastMsg.Substring(0, [Math]::Min(16000, $lastMsg.Length))
$dispatched = $false
$previousSpeakText = [Environment]::GetEnvironmentVariable('COPILOT_SPEAK_TEXT', 'Process')
try {
    $argLine = "`"$speakScript`" --hook-env"
    [Environment]::SetEnvironmentVariable('COPILOT_SPEAK_TEXT', $lastMsg, 'Process')
    Start-Process -FilePath $python.Source `
        -ArgumentList $argLine `
        -WindowStyle Hidden `
        -ErrorAction Stop | Out-Null
    $dispatched = $true
} catch {
    $dispatched = $false
} finally {
    [Environment]::SetEnvironmentVariable('COPILOT_SPEAK_TEXT', $previousSpeakText, 'Process')
}

if ($dispatched) {
    Write-HookResult -Hook 'agent-stop-tts' -Outcome 'worked' -Code 'tts_dispatched'
} else {
    Write-HookResult -Hook 'agent-stop-tts' -Outcome 'did_not_work' -Code 'tts_dispatch_failed'
}
