<#
    Privacy-safe hook result logging.

    Log entries contain only a timestamp and fixed enum values. Callers cannot write
    notification text, paths, session identifiers, tool arguments, or exception messages.
#>

function Write-HookResult {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('notification', 'toast-renderer', 'agent-stop-tts', 'agent-stop-sound')]
        [string]$Hook,

        [Parameter(Mandatory)]
        [ValidateSet('worked', 'did_not_work')]
        [string]$Outcome,

        [Parameter(Mandatory)]
        [ValidateSet(
            'focused',
            'invalid_input',
            'unsupported_notification',
            'focus_check_failed',
            'toast_dispatched',
            'toast_dispatch_failed',
            'toast_displayed',
            'toast_display_failed',
            'transcript_missing',
            'transcript_rejected',
            'message_missing',
            'tts_script_missing',
            'python_missing',
            'tts_disabled',
            'tts_dispatched',
            'tts_dispatch_failed',
            'invalid_stop_payload',
            'subagent_suppressed',
            'sound_dispatched',
            'sound_dispatch_failed',
            'sound_played',
            'sound_play_failed'
        )]
        [string]$Code
    )

    $mutex = $null
    $lockTaken = $false
    try {
        $logDir = [string]$env:COPILOT_PLUGIN_DATA
        if (-not $logDir) { return }
        if ($logDir -notmatch '^[A-Za-z]:\\') { return }

        $logPath = Join-Path $logDir 'hooks.log'
        [void][System.IO.Directory]::CreateDirectory($logDir)
        if ((Get-Item -LiteralPath $logDir).Attributes -band [System.IO.FileAttributes]::ReparsePoint) { return }
        if ((Test-Path -LiteralPath $logPath) -and
            ((Get-Item -LiteralPath $logPath).Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
            return
        }

        $mutex = [System.Threading.Mutex]::new($false, 'Local\CopilotHelpfulToolsHookLog')
        try {
            $lockTaken = $mutex.WaitOne(2000)
        } catch [System.Threading.AbandonedMutexException] {
            $lockTaken = $true
        }
        if (-not $lockTaken) { return }

        if ((Test-Path -LiteralPath $logPath) -and
            (Get-Item -LiteralPath $logPath).Length -ge 1MB) {
            [System.IO.File]::WriteAllText($logPath, '')
        }

        $entry = [ordered]@{
            timestampUtc = [DateTime]::UtcNow.ToString('o')
            hook = $Hook
            outcome = $Outcome
            code = $Code
        }
        [System.IO.File]::AppendAllText(
            $logPath,
            (($entry | ConvertTo-Json -Compress) + [Environment]::NewLine),
            [System.Text.UTF8Encoding]::new($false)
        )
    } catch {
        # Logging must not interfere with hook execution.
    } finally {
        if ($lockTaken) { $mutex.ReleaseMutex() }
        if ($mutex) { $mutex.Dispose() }
    }
}

function Read-HookStdin {
    param([int]$MaxChars = 65536)

    if (-not [Console]::IsInputRedirected) { return '' }

    $reader = [System.IO.StreamReader]::new(
        [Console]::OpenStandardInput(),
        [System.Text.Encoding]::UTF8,
        $true,
        4096,
        $true
    )
    $builder = [System.Text.StringBuilder]::new()
    $buffer = [char[]]::new(4096)

    while (($count = $reader.Read($buffer, 0, $buffer.Length)) -gt 0) {
        if (($builder.Length + $count) -gt $MaxChars) {
            throw 'Hook input exceeds the permitted size.'
        }
        [void]$builder.Append($buffer, 0, $count)
    }

    return $builder.ToString()
}

function Test-MainAgentStop {
    param(
        [string]$SessionId,
        [string]$TranscriptPath
    )

    if (-not $SessionId -or -not $TranscriptPath) { return $false }
    $transcriptDirectory = Split-Path -Parent $TranscriptPath
    if (-not $transcriptDirectory) { return $false }
    return $SessionId -eq (Split-Path -Leaf $transcriptDirectory)
}
