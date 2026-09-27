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

    $notificationCases = @(
        @{
            Name = 'question'
            Input = '{"hook_event_name":"Notification","notification_type":"elicitation_dialog","message":"private-test-canary","title":"untrusted-test-title"}'
            Focused = $false
            Outcome = 'worked'
            Code = 'toast_dispatched'
            Kind = 'question'
        },
        @{
            Name = 'permission'
            Input = '{"hook_event_name":"Notification","notification_type":"permission_prompt","message":"private-test-canary"}'
            Focused = $false
            Outcome = 'worked'
            Code = 'toast_dispatched'
            Kind = 'permission'
        },
        @{
            Name = 'focused-question'
            Input = '{"hook_event_name":"Notification","notification_type":"elicitation_dialog","message":"private-test-canary"}'
            Focused = $true
            Outcome = 'worked'
            Code = 'focused'
            Kind = $null
        },
        @{
            Name = 'unrelated-notification'
            Input = '{"notification_type":"agent_idle","message":"private-test-canary"}'
            Focused = $false
            Outcome = 'did_not_work'
            Code = 'unsupported_notification'
            Kind = $null
        },
        @{
            Name = 'camelcase-field-rejected'
            Input = '{"notificationType":"elicitation_dialog","message":"private-test-canary"}'
            Focused = $false
            Outcome = 'did_not_work'
            Code = 'invalid_input'
            Kind = $null
        },
        @{
            Name = 'scalar-input'
            Input = '"elicitation_dialog"'
            Focused = $false
            Outcome = 'did_not_work'
            Code = 'invalid_input'
            Kind = $null
        },
        @{
            Name = 'array-input'
            Input = '[{"notification_type":"elicitation_dialog"}]'
            Focused = $false
            Outcome = 'did_not_work'
            Code = 'invalid_input'
            Kind = $null
        },
        @{
            Name = 'array-type'
            Input = '{"notification_type":["elicitation_dialog"]}'
            Focused = $false
            Outcome = 'did_not_work'
            Code = 'invalid_input'
            Kind = $null
        },
        @{
            Name = 'malformed-input'
            Input = '{not-json'
            Focused = $false
            Outcome = 'did_not_work'
            Code = 'invalid_input'
            Kind = $null
        },
        @{
            Name = 'null-input'
            Input = 'null'
            Focused = $false
            Outcome = 'did_not_work'
            Code = 'invalid_input'
            Kind = $null
        }
    )

    Push-Location -LiteralPath $root
    try {
        foreach ($case in $notificationCases) {
            $env:COPILOT_PLUGIN_DATA = Join-Path $testLogDir $case.Name
            [void][System.IO.Directory]::CreateDirectory($env:COPILOT_PLUGIN_DATA)
            $stderrFile = Join-Path $env:COPILOT_PLUGIN_DATA 'stderr.txt'
            if ($case.Focused) {
                $output = @($case.Input | pwsh -NoProfile -NonInteractive -File .\tests\fixtures\Invoke-NotificationHook.ps1 -Focused 2> $stderrFile)
            } else {
                $output = @($case.Input | pwsh -NoProfile -NonInteractive -File .\tests\fixtures\Invoke-NotificationHook.ps1 2> $stderrFile)
            }
            if ($LASTEXITCODE -ne 0 -or ($output -join '').Trim() -cne '{}' -or
                (Get-Item -LiteralPath $stderrFile).Length -ne 0) {
                throw "Notification case '$($case.Name)' did not return a successful empty decision with empty stderr."
            }

            $logFile = Join-Path $env:COPILOT_PLUGIN_DATA 'hooks.log'
            if (-not (Test-Path -LiteralPath $logFile -PathType Leaf)) {
                throw "Notification case '$($case.Name)' did not write its result log."
            }
            $logText = Get-Content -LiteralPath $logFile -Raw
            $results = @($logText.Trim() -split '\r?\n' | ForEach-Object { $_ | ConvertFrom-Json })
            if ($results.Count -ne 1 -or $results[0].hook -cne 'notification' -or
                $results[0].outcome -cne $case.Outcome -or $results[0].code -cne $case.Code) {
                throw "Notification case '$($case.Name)' logged $($results.Count) entries with $($results[0].outcome)/$($results[0].code); expected one $($case.Outcome)/$($case.Code)."
            }
            if ((@($results[0].PSObject.Properties.Name | Sort-Object) -join ',') -ne 'code,hook,outcome,timestampUtc' -or
                $logText.Contains('private-test-canary') -or $logText.Contains('untrusted-test-title')) {
                throw "Notification case '$($case.Name)' logged payload content or unexpected fields."
            }

            $dispatchFile = Join-Path $env:COPILOT_PLUGIN_DATA 'dispatch.txt'
            if ($null -ne $case.Kind) {
                if (-not (Test-Path -LiteralPath $dispatchFile -PathType Leaf)) {
                    throw "Notification case '$($case.Name)' did not dispatch its toast."
                }
                if ((Get-Content -LiteralPath $dispatchFile -Raw).Trim() -cne $case.Kind) {
                    throw "Notification case '$($case.Name)' dispatched the wrong toast kind."
                }
            } elseif (Test-Path -LiteralPath $dispatchFile) {
                throw "Notification case '$($case.Name)' dispatched an unexpected toast."
            }
        }
    } finally {
        Pop-Location
    }

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
