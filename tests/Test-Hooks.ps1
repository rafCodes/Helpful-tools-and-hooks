$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$hookRoot = Join-Path $root 'hooks'
$testLogDir = Join-Path ([System.IO.Path]::GetTempPath()) ("helpful-hooks-test-{0}" -f [guid]::NewGuid().ToString('N'))
$previousPluginData = $env:COPILOT_PLUGIN_DATA

try {
    Get-ChildItem -LiteralPath $hookRoot -Filter '*.ps1' | ForEach-Object {
        [void][scriptblock]::Create((Get-Content -LiteralPath $_.FullName -Raw))
    }
    Get-Content -LiteralPath (Join-Path $root 'hooks.json') -Raw | ConvertFrom-Json | Out-Null
    Get-Content -LiteralPath (Join-Path $root 'plugin.json') -Raw | ConvertFrom-Json | Out-Null

    . (Join-Path $hookRoot 'HookLog.Common.ps1')

    if (-not (Test-MainAgentStop `
        -SessionId '11111111-1111-1111-1111-111111111111' `
        -TranscriptPath 'C:\sessions\11111111-1111-1111-1111-111111111111\events.jsonl')) {
        throw 'Main-agent stop classification failed.'
    }
    if (Test-MainAgentStop `
        -SessionId '22222222-2222-2222-2222-222222222222' `
        -TranscriptPath 'C:\sessions\11111111-1111-1111-1111-111111111111\events.jsonl') {
        throw 'Sub-agent stop classification failed.'
    }

    $env:COPILOT_PLUGIN_DATA = $testLogDir
    Write-HookResult -Hook 'notification' -Outcome 'worked' -Code 'toast_dispatched'
    Write-HookResult -Hook 'agent-stop-sound' -Outcome 'did_not_work' -Code 'sound_play_failed'

    $entries = Get-Content -LiteralPath (Join-Path $testLogDir 'hooks.log') | ForEach-Object {
        $_ | ConvertFrom-Json
    }
    if ($entries.Count -ne 2) { throw 'Unexpected hook log entry count.' }

    foreach ($entry in $entries) {
        $properties = @($entry.PSObject.Properties.Name | Sort-Object)
        if (($properties -join ',') -ne 'code,hook,outcome,timestampUtc') {
            throw 'Hook log contains an unexpected field.'
        }
    }

    $hooks = Get-Content -LiteralPath (Join-Path $root 'hooks.json') -Raw | ConvertFrom-Json
    $matchers = @($hooks.hooks.notification.matcher)
    if ('elicitation_dialog' -notin $matchers) { throw 'Question notification matcher is missing.' }
    if ($hooks.hooks.preToolUse) { throw 'Obsolete ask_user preToolUse hook remains.' }

    $tts = Get-Content -LiteralPath (Join-Path $hookRoot 'text-to-speech\speak.py') -Raw
    if ($tts -match 'escaped_text' -or $tts -match '\$synth\.Speak\("') {
        throw 'TTS still interpolates speech text into PowerShell code.'
    }
    if ($tts -notmatch 'UTF8Encoding' -or $tts -notmatch '\$synth\.Speak\(\$reader\.ReadToEnd\(\)\)') {
        throw 'TTS stdin data channel is missing.'
    }
    if ($tts -notmatch 'input=text\.encode\("utf-8"\)') {
        throw 'TTS does not send explicit UTF-8 bytes.'
    }
    if ($tts -notmatch 'hook_env' -or $tts -notmatch 'COPILOT_SPEAK_TEXT') {
        throw 'TTS hook environment channel is missing.'
    }
    if ($tts -notmatch 'timeout_seconds' -or $tts -match 'WaitForSingleObject\(mutex, 0xFFFFFFFF\)') {
        throw 'TTS waits are not bounded.'
    }

    $toast = Get-Content -LiteralPath (Join-Path $hookRoot 'Show-Toast.ps1') -Raw
    if ($toast -match 'COPILOT_TOAST_PAYLOAD' -or $toast -match '\$payloadMessage') {
        throw 'Toast renderer can receive notification text.'
    }

    'PASS hook regression checks'
} finally {
    $env:COPILOT_PLUGIN_DATA = $previousPluginData
    if (Test-Path -LiteralPath $testLogDir) {
        Remove-Item -LiteralPath $testLogDir -Recurse -Force
    }
}
