. "$PSScriptRoot\FocusToast.Common.ps1"

try {
    $raw = Read-HookStdin
    if (-not $raw) { throw 'Invalid input.' }
    $payload = ConvertFrom-Json -InputObject $raw -AsHashtable -NoEnumerate -ErrorAction Stop
    if ($payload -isnot [System.Collections.IDictionary] -or
        $payload['sessionId'] -isnot [string] -or
        $payload['recoverable'] -isnot [bool] -or
        $payload['errorContext'] -isnot [string] -or
        $payload['errorContext'] -cnotin @('model_call', 'tool_execution', 'system', 'user_input') -or
        $payload['error'] -isnot [System.Collections.IDictionary] -or
        $payload['error']['message'] -isnot [string] -or
        $payload['error']['name'] -isnot [string]) {
        throw 'Invalid error payload.'
    }
    $sessionId = ConvertTo-CompactionSessionId -SessionId $payload['sessionId']
} catch {
    Write-HookResult -Hook 'error-occurred' -Outcome 'did_not_work' -Code 'invalid_input'
    '{}'
    exit 0
}

if ($payload['recoverable']) {
    Write-HookResult -Hook 'error-occurred' -Outcome 'worked' -Code 'recoverable_error_ignored'
} elseif ($payload['errorContext'] -cin @('tool_execution', 'user_input')) {
    Write-HookResult -Hook 'error-occurred' -Outcome 'worked' -Code 'non_session_error_ignored'
} else {
    [void](Start-FocusToast -Kind failure -SessionId $sessionId)
}

'{}'
