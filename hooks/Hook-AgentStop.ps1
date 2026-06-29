<#
    Hook: agentStop — fires after each Copilot turn completes.
    Reads the assistant's last message from events.jsonl and speaks it
    via the bundled text-to-speech engine.
    Receives JSON on stdin with: sessionId, timestamp, cwd, transcriptPath, stopReason
#>
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

$input_json = [Console]::In.ReadToEnd() | ConvertFrom-Json
$cwd = $input_json.cwd

# Find the active session's events.jsonl
$copilotDir = Join-Path $HOME ".copilot" "session-state"
$eventsFile = Get-ChildItem -Path $copilotDir -Recurse -Filter "events.jsonl" -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1

if (-not $eventsFile) { exit 0 }

# Find the last assistant.message with text content or ask_user question
$lastMsg = ""
Get-Content $eventsFile.FullName -Tail 30 | ForEach-Object {
    try {
        $e = $_ | ConvertFrom-Json
        if ($e.type -eq "assistant.message") {
            if ($e.data.content) {
                $lastMsg = $e.data.content
            } elseif ($e.data.toolRequests) {
                foreach ($req in $e.data.toolRequests) {
                    if ($req.name -eq "ask_user") {
                        $args_obj = $req.arguments | ConvertFrom-Json
                        if ($args_obj.question) { $lastMsg = $args_obj.question }
                    }
                }
            }
        }
    } catch {}
}

if (-not $lastMsg) { exit 0 }

# Fire-and-forget TTS via the bundled engine so the hook isn't blocked.
# Pass the FULL multi-line message via a temp file so speak.py's markdown
# cleanup regexes (which depend on line anchors) work correctly.
# Concurrent invocations serialize via a named mutex inside speak.py, so
# messages queue and play back-to-back rather than overlapping.
# TTS engine is bundled inside this plugin's hooks folder.
$speakScript = Join-Path $scriptDir "text-to-speech\speak.py"
$speakScript = [System.IO.Path]::GetFullPath($speakScript)
if (Test-Path $speakScript) {
    try {
        $tmpFile = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "copilot-speak-$([guid]::NewGuid().ToString('N')).txt")
        [System.IO.File]::WriteAllText($tmpFile, $lastMsg, [System.Text.UTF8Encoding]::new($false))
        $argLine = "`"$speakScript`" --file=`"$tmpFile`""
        Start-Process -FilePath "python" `
            -ArgumentList $argLine `
            -WindowStyle Hidden `
            -ErrorAction Stop | Out-Null
    } catch {
        # Silently ignore if python isn't on PATH or speak fails
    }
}
