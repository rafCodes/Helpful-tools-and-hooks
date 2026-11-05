# preCompact runs before manual or automatic compaction. It does not confirm completion.
. "$PSScriptRoot\Compaction.Common.ps1"

try {
    $config = Get-HelpfulHooksConfig
} catch {
    Write-HookResult -Hook 'pre-compact' -Outcome 'did_not_work' -Code 'configuration_failed'
    '{}'
    exit 0
}

if (-not $config.compactionToastEnabled) {
    Write-HookResult -Hook 'pre-compact' -Outcome 'worked' -Code 'compaction_disabled'
    '{}'
    exit 0
}

try {
    $raw = Read-HookStdin
    if (-not $raw) { throw 'Invalid input.' }
    $payload = ConvertFrom-Json -InputObject $raw -AsHashtable -NoEnumerate -ErrorAction Stop
    if ($payload -isnot [System.Collections.IDictionary] -or
        $payload['sessionId'] -isnot [string] -or
        $payload['trigger'] -isnot [string] -or
        $payload['trigger'] -cnotin @('manual', 'auto') -or
        $payload['transcriptPath'] -isnot [string]) {
        throw 'Invalid compaction payload.'
    }
    $sessionId = ConvertTo-CompactionSessionId -SessionId $payload['sessionId']
    $expectedTranscript = Join-Path (Join-Path (Get-HelpfulHooksHome) 'session-state') ($sessionId + '\events.jsonl')
    if (-not [System.IO.Path]::GetFullPath($payload['transcriptPath']).Equals(
        $expectedTranscript, [System.StringComparison]::OrdinalIgnoreCase
    )) {
        throw 'The transcript must belong to the named session.'
    }
} catch {
    Write-HookResult -Hook 'pre-compact' -Outcome 'did_not_work' -Code 'invalid_input'
    '{}'
    exit 0
}

. "$PSScriptRoot\FocusToast.Common.ps1"
[void](Start-FocusToast -Kind compaction -SessionId $sessionId)

'{}'
