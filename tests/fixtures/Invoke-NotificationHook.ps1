param([switch]$Focused, [switch]$FocusFailure, [switch]$DispatchFailure, [switch]$ErrorOccurred)

if ($ErrorOccurred) {
    function Test-FixtureTerminalFocused { throw 'Failure alerts must not check terminal focus.' }
} elseif ($FocusFailure) {
    function Test-FixtureTerminalFocused { throw 'Fixture focus check failure.' }
} elseif ($Focused) {
    function Test-FixtureTerminalFocused { return $true }
} else {
    function Test-FixtureTerminalFocused { return $false }
}

function Start-FixtureToastProcess {
    [CmdletBinding()]
    param(
        [string]$FilePath,
        [string]$ArgumentList,
        [string]$WorkingDirectory,
        [string]$WindowStyle
    )

    $expectedExecutable = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $renderer = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\hooks\Show-Toast.ps1'))
    $expectedArguments = "-NoProfile -STA -ExecutionPolicy Bypass -File `"$renderer`" -Kind "
    if ($FilePath -cne $expectedExecutable -or $WindowStyle -cne 'Hidden' -or
        $WorkingDirectory -cne [Environment]::SystemDirectory) {
        throw 'Unexpected notification process request.'
    }
    $identityKind = if ($ErrorOccurred) { 'failure' } else { 'question' }
    $identityPrefix = $expectedArguments + $identityKind + ' -SessionId '
    if ($ArgumentList.StartsWith($identityPrefix, [System.StringComparison]::Ordinal)) {
        $kind = $identityKind
        $sessionId = $ArgumentList.Substring($identityPrefix.Length)
        $id = [guid]::Empty
        if (-not [guid]::TryParseExact($sessionId, 'D', [ref]$id) -or $sessionId -cne $id.ToString('D')) {
            throw 'Alert process arguments must contain only one canonical session ID.'
        }
        $dispatch = "$kind|$sessionId"
    } elseif ($ArgumentList -ceq ($expectedArguments + 'permission')) {
        $kind = 'permission'
        $dispatch = $kind
    } else {
        throw 'Unexpected notification process arguments.'
    }
    if ($DispatchFailure) { throw 'Fixture process launch failure.' }

    [void][System.IO.Directory]::CreateDirectory($env:COPILOT_PLUGIN_DATA)
    [System.IO.File]::AppendAllText(
        (Join-Path $env:COPILOT_PLUGIN_DATA 'dispatch.txt'),
        ($dispatch + [Environment]::NewLine)
    )
}

# Aliases override the side-effect functions even after the handler loads its helpers.
# The handler and helpers must keep these calls unqualified for this fixture to intercept them.
Set-Alias -Name Test-TerminalFocused -Value Test-FixtureTerminalFocused
Set-Alias -Name Start-Process -Value Start-FixtureToastProcess

if ($ErrorOccurred) {
    & (Join-Path $PSScriptRoot '..\..\hooks\Hook-ErrorOccurred.ps1')
} else {
    & (Join-Path $PSScriptRoot '..\..\hooks\Show-FocusToast.ps1')
}
