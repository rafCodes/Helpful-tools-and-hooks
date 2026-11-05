. "$PSScriptRoot\Compaction.Common.ps1"

try {
    Initialize-HelpfulHooksConfig
    Write-HookResult -Hook 'session-start' -Outcome 'worked' -Code 'configuration_ready'
} catch {
    Write-HookResult -Hook 'session-start' -Outcome 'did_not_work' -Code 'configuration_failed'
}

'{}'
