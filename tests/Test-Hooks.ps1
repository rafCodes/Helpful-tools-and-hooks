$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$hookRoot = Join-Path $root 'hooks'
$testLogDir = Join-Path ([System.IO.Path]::GetTempPath()) ("helpful-hooks-test-{0}" -f [guid]::NewGuid().ToString('N'))
$previousPluginData = $env:COPILOT_PLUGIN_DATA
$previousCopilotHome = $env:COPILOT_HOME

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
    if (@($hooks.hooks.preCompact).Count -ne 1 -or @($hooks.hooks.sessionStart).Count -ne 1) {
        throw 'Compaction and configuration hooks must each be registered once.'
    }

    . (Join-Path $hookRoot 'Compaction.Common.ps1')
    $sessionId = '11111111-1111-1111-1111-111111111111'
    $compactionCases = @(
        @{ Name = 'missing-config'; Config = $null; Code = 'configuration_failed'; Failed = $true },
        @{ Name = 'disabled'; Config = '{"compactionToastEnabled":false}'; Code = 'compaction_disabled' },
        @{ Name = 'auto'; Config = '{"compactionToastEnabled":true}'; Code = 'compaction_alert_dispatched'; Dispatch = $true },
        @{ Name = 'manual'; Config = '{"compactionToastEnabled":true}'; Trigger = 'manual'; Code = 'compaction_alert_dispatched'; Dispatch = $true },
        @{ Name = 'string-setting'; Config = '{"compactionToastEnabled":"true"}'; Code = 'configuration_failed'; Failed = $true },
        @{ Name = 'missing-setting'; Config = '{}'; Code = 'configuration_failed'; Failed = $true },
        @{ Name = 'array-config'; Config = '[{"compactionToastEnabled":true}]'; Code = 'configuration_failed'; Failed = $true },
        @{ Name = 'malformed-config'; Config = '{not-json'; Code = 'configuration_failed'; Failed = $true },
        @{ Name = 'malformed-compaction'; Config = '{"compactionToastEnabled":true}'; Input = '{not-json'; Code = 'invalid_input'; Failed = $true },
        @{ Name = 'array-compaction'; Config = '{"compactionToastEnabled":true}'; Input = '[{"sessionId":"11111111-1111-1111-1111-111111111111","trigger":"auto"}]'; Code = 'invalid_input'; Failed = $true },
        @{ Name = 'wrong-session'; Config = '{"compactionToastEnabled":true}'; WrongSession = $true; Code = 'invalid_input'; Failed = $true },
        @{ Name = 'injected-session-id'; Config = '{"compactionToastEnabled":true}'; Input = '{"sessionId":"11111111-1111-1111-1111-111111111111 -Command private-test-canary","trigger":"auto","transcriptPath":"C:\\private-test-canary"}'; Code = 'invalid_input'; Failed = $true },
        @{ Name = 'compaction-dispatch-failure'; Config = '{"compactionToastEnabled":true}'; DispatchFailure = $true; Code = 'compaction_alert_dispatch_failed'; Failed = $true }
    )
    foreach ($case in $compactionCases) {
        $env:COPILOT_PLUGIN_DATA = Join-Path $testLogDir $case.Name
        $env:COPILOT_HOME = Join-Path $env:COPILOT_PLUGIN_DATA 'copilot-home'
        [void][System.IO.Directory]::CreateDirectory($env:COPILOT_HOME)
        $configPath = Join-Path $env:COPILOT_HOME 'helpful-tools-and-hooks.json'
        if ($null -ne $case.Config) { [System.IO.File]::WriteAllText($configPath, $case.Config) }
        $trigger = if ($case.Trigger) { $case.Trigger } else { 'auto' }
        $transcriptSession = if ($case.WrongSession) { '22222222-2222-2222-2222-222222222222' } else { $sessionId }
        $inputJson = if ($case.Input) { $case.Input } else {
            @{
                sessionId = $sessionId
                trigger = $trigger
                transcriptPath = Join-Path $env:COPILOT_HOME "session-state\$transcriptSession\events.jsonl"
                customInstructions = 'private-test-canary'
            } | ConvertTo-Json -Compress
        }
        $stderrFile = Join-Path $env:COPILOT_PLUGIN_DATA 'stderr.txt'
        $fixtureArguments = @('-NoProfile', '-NonInteractive', '-File', (Join-Path $PSScriptRoot 'fixtures\Invoke-CompactionHook.ps1'))
        if ($case.DispatchFailure) { $fixtureArguments += '-DispatchFailure' }
        $output = @($inputJson | pwsh @fixtureArguments 2> $stderrFile)
        if ($LASTEXITCODE -ne 0 -or ($output -join '').Trim() -cne '{}' -or
            (Get-Item -LiteralPath $stderrFile).Length -ne 0) {
            throw "Compaction case '$($case.Name)' did not return an empty decision with empty stderr."
        }
        $logText = Get-Content -LiteralPath (Join-Path $env:COPILOT_PLUGIN_DATA 'hooks.log') -Raw
        $results = @($logText.Trim() -split '\r?\n' | ForEach-Object { $_ | ConvertFrom-Json })
        $expectedOutcome = if ($case.Failed) { 'did_not_work' } else { 'worked' }
        if ($results.Count -ne 1 -or $results[0].hook -cne 'pre-compact' -or
            $results[0].outcome -cne $expectedOutcome -or $results[0].code -cne $case.Code -or
            $logText.Contains('private-test-canary') -or $logText.Contains($sessionId)) {
            throw "Compaction case '$($case.Name)' has an incorrect or privacy-unsafe result log."
        }
        $dispatchPath = Join-Path $env:COPILOT_PLUGIN_DATA 'dispatch.json'
        if ($case.Dispatch) {
            $dispatch = Get-Content -LiteralPath $dispatchPath -Raw | ConvertFrom-Json
            if ($dispatch.kind -cne 'compaction' -or $dispatch.sessionId -cne $sessionId) {
                throw "Compaction case '$($case.Name)' dispatched the wrong alert or session."
            }
        } elseif (Test-Path -LiteralPath $dispatchPath) {
            throw "Compaction case '$($case.Name)' unexpectedly dispatched an alert."
        }
        if ($null -eq $case.Config -and (Test-Path -LiteralPath $configPath)) {
            throw 'The compaction hook wrote configuration instead of reading it.'
        }
    }

    $env:COPILOT_HOME = Join-Path $testLogDir 'startup-home'
    $env:COPILOT_PLUGIN_DATA = Join-Path $testLogDir 'session-start'
    [void][System.IO.Directory]::CreateDirectory($env:COPILOT_PLUGIN_DATA)
    $stderrFile = Join-Path $env:COPILOT_PLUGIN_DATA 'stderr.txt'
    $fixture = Join-Path $PSScriptRoot 'fixtures\Invoke-CompactionHook.ps1'
    $output = @('{}' | pwsh -NoProfile -NonInteractive -File $fixture -SessionStart 2> $stderrFile)
    $configPath = Join-Path $env:COPILOT_HOME 'helpful-tools-and-hooks.json'
    if ($LASTEXITCODE -ne 0 -or ($output -join '').Trim() -cne '{}' -or
        (Get-Item -LiteralPath $stderrFile).Length -ne 0 -or
        -not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        throw 'Session start did not create a disabled compaction configuration.'
    }
    $createdConfig = [System.IO.File]::ReadAllText($configPath) | ConvertFrom-Json
    $startupResults = @(Get-Content -LiteralPath (Join-Path $env:COPILOT_PLUGIN_DATA 'hooks.log') | ForEach-Object { $_ | ConvertFrom-Json })
    if ($createdConfig.compactionToastEnabled -isnot [bool] -or $createdConfig.compactionToastEnabled -ne $false -or
        $startupResults.Count -ne 1 -or $startupResults[0].hook -cne 'session-start' -or
        $startupResults[0].outcome -cne 'worked' -or $startupResults[0].code -cne 'configuration_ready') {
        throw 'Session start did not persist and log its default-disabled configuration.'
    }
    $preservedConfig = '{"compactionToastEnabled":true,"otherSetting":"private-test-canary"}'
    [System.IO.File]::WriteAllText($configPath, $preservedConfig)
    $output = @('{}' | pwsh -NoProfile -NonInteractive -File $fixture -SessionStart 2> $stderrFile)
    if ($LASTEXITCODE -ne 0 -or ($output -join '').Trim() -cne '{}' -or
        (Get-Item -LiteralPath $stderrFile).Length -ne 0 -or
        [System.IO.File]::ReadAllText($configPath) -cne $preservedConfig) {
        throw 'Session start changed an existing user configuration.'
    }

    $env:COPILOT_PLUGIN_DATA = Join-Path $testLogDir 'name-parser'
    [void][System.IO.Directory]::CreateDirectory($env:COPILOT_PLUGIN_DATA)
    $stderrFile = Join-Path $env:COPILOT_PLUGIN_DATA 'stderr.txt'
    $nameFixture = Join-Path $PSScriptRoot 'fixtures\Test-CompactionNames.ps1'
    $powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $output = @(& $powershellPath -NoProfile -NonInteractive -File $nameFixture 2> $stderrFile)
    if ($LASTEXITCODE -ne 0 -or ($output -join '').Trim() -cne 'PASS compaction name checks' -or
        (Get-Item -LiteralPath $stderrFile).Length -ne 0) {
        throw "Production session-name parser checks failed: $($output -join ' ') $(Get-Content -LiteralPath $stderrFile -Raw)"
    }

    $notificationCases = @(
        @{
            Name = 'question'
            Input = '{"hook_event_name":"Notification","notification_type":"elicitation_dialog","message":"private-test-canary","title":"untrusted-test-title"}'
            Focused = $false
            Outcome = 'worked'
            Code = 'question_alert_dispatched'
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
            Name = 'focused-permission'
            Input = '{"notification_type":"permission_prompt"}'
            Focused = $true
            Outcome = 'worked'
            Code = 'focused'
            Kind = $null
        },
        @{
            Name = 'focus-check-failure'
            Input = '{"notification_type":"elicitation_dialog"}'
            FocusFailure = $true
            Outcome = 'did_not_work'
            Code = 'focus_check_failed'
            Kind = $null
        },
        @{
            Name = 'question-dispatch-failure'
            Input = '{"notification_type":"elicitation_dialog"}'
            DispatchFailure = $true
            Outcome = 'did_not_work'
            Code = 'question_alert_dispatch_failed'
            Kind = $null
        },
        @{
            Name = 'permission-dispatch-failure'
            Input = '{"notification_type":"permission_prompt"}'
            DispatchFailure = $true
            Outcome = 'did_not_work'
            Code = 'toast_dispatch_failed'
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
            $fixtureArguments = @('-NoProfile', '-NonInteractive', '-File', '.\tests\fixtures\Invoke-NotificationHook.ps1')
            if ($case.Focused) { $fixtureArguments += '-Focused' }
            if ($case.FocusFailure) { $fixtureArguments += '-FocusFailure' }
            if ($case.DispatchFailure) { $fixtureArguments += '-DispatchFailure' }
            $output = @($case.Input | pwsh @fixtureArguments 2> $stderrFile)
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

        foreach ($rendererCase in @(
            @{ Kind = 'question'; Mode = 'normal' },
            @{ Kind = 'question'; Mode = 'sound-failure' },
            @{ Kind = 'compaction'; Mode = 'normal' },
            @{ Kind = 'compaction'; Mode = 'sound-failure' },
            @{ Kind = 'compaction'; Mode = 'name-failure' }
        )) {
            $kind = $rendererCase.Kind
            $mode = $rendererCase.Mode
            $env:COPILOT_PLUGIN_DATA = Join-Path $testLogDir "$kind-renderer-$mode"
            [void][System.IO.Directory]::CreateDirectory($env:COPILOT_PLUGIN_DATA)
            $stderrFile = Join-Path $env:COPILOT_PLUGIN_DATA 'stderr.txt'
            $stdoutFile = Join-Path $env:COPILOT_PLUGIN_DATA 'stdout.txt'
            $renderer = Join-Path $root 'tests\fixtures\Test-QuestionAlert.ps1'
            $powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            $rendererArguments = "-NoProfile -NonInteractive -STA -File `"$renderer`" -Kind $kind"
            if ($mode -eq 'sound-failure') { $rendererArguments += ' -SoundFailure' }
            if ($mode -eq 'name-failure') { $rendererArguments += ' -NameFailure' }
            $rendererProcess = Start-Process -FilePath $powershellPath -ArgumentList $rendererArguments `
                -WindowStyle Hidden -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile -PassThru
            try {
                if (-not $rendererProcess.WaitForExit(30000)) {
                    Stop-Process -Id $rendererProcess.Id -Force
                    [void]$rendererProcess.WaitForExit(5000)
                    throw 'The question renderer process exceeded its test timeout.'
                }
                $rendererProcess.WaitForExit()
                $rendererProcess.Refresh()
                [string]$rendererOutput = Get-Content -LiteralPath $stdoutFile -Raw
                if ($rendererProcess.ExitCode -ne 0 -or $rendererOutput.Trim() -cne "PASS $kind alert renderer checks" -or
                    (Get-Item -LiteralPath $stderrFile).Length -ne 0) {
                    throw "Alert renderer checks failed ($kind/$mode): $rendererOutput $(Get-Content -LiteralPath $stderrFile -Raw)"
                }
            } finally {
                $rendererProcess.Dispose()
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
    $env:COPILOT_HOME = $previousCopilotHome
    if (Test-Path -LiteralPath $testLogDir) {
        Remove-Item -LiteralPath $testLogDir -Recurse -Force
    }
}
