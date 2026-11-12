param([switch]$SessionStart, [switch]$DispatchFailure)

$testData = [System.IO.Path]::GetFullPath($env:COPILOT_PLUGIN_DATA)
$testRoot = [System.IO.Path]::GetDirectoryName($testData)
if ([System.IO.Path]::GetFileName($testRoot) -notmatch '^helpful-hooks-test-[0-9a-f]{32}$' -or
    [string]::IsNullOrWhiteSpace($env:COPILOT_HOME) -or
    -not [System.IO.Path]::GetFullPath($env:COPILOT_HOME).StartsWith(
        ($testRoot + '\'), [System.StringComparison]::OrdinalIgnoreCase
    )) {
    throw 'Run tests\Test-Hooks.ps1. The hook fixture requires an isolated COPILOT_HOME and plugin data.'
}

function Start-FixtureCompactionProcess {
    [CmdletBinding()]
    param([string]$FilePath, [string]$ArgumentList, [string]$WindowStyle, [string]$WorkingDirectory)

    $expectedExecutable = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $renderer = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\hooks\Show-Toast.ps1'))
    $expectedPrefix = "-NoProfile -STA -ExecutionPolicy Bypass -File `"$renderer`" -Kind compaction -SessionId "
    if ($FilePath -cne $expectedExecutable -or $WindowStyle -cne 'Hidden' -or
        $WorkingDirectory -cne [Environment]::SystemDirectory -or
        -not $ArgumentList.StartsWith($expectedPrefix, [System.StringComparison]::Ordinal)) {
        throw 'Unexpected compaction process request.'
    }
    $sessionId = $ArgumentList.Substring($expectedPrefix.Length)
    $id = [guid]::Empty
    if (-not [guid]::TryParseExact($sessionId, 'D', [ref]$id) -or $sessionId -cne $id.ToString('D')) {
        throw 'Compaction process arguments contain more than a canonical session ID.'
    }
    if ($DispatchFailure) { throw 'Fixture process launch failure.' }
    [System.IO.File]::WriteAllText(
        (Join-Path $env:COPILOT_PLUGIN_DATA 'dispatch.json'),
        (@{ kind = 'compaction'; sessionId = $sessionId } | ConvertTo-Json -Compress)
    )
}

function Test-FixtureUnexpectedFocusCheck { throw 'Compaction alerts must not check terminal focus.' }
Set-Alias -Name Start-Process -Value Start-FixtureCompactionProcess
Set-Alias -Name Test-TerminalFocused -Value Test-FixtureUnexpectedFocusCheck

if ($SessionStart) {
    & (Join-Path $PSScriptRoot '..\..\hooks\Hook-SessionStart.ps1')
} else {
    & (Join-Path $PSScriptRoot '..\..\hooks\Hook-PreCompact.ps1')
}
