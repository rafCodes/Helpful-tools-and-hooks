param([switch]$Focused)

if ($Focused) {
    function Test-FixtureTerminalFocused { return $true }
} else {
    function Test-FixtureTerminalFocused { return $false }
}

function Start-FixtureToastProcess {
    [CmdletBinding()]
    param(
        [string]$FilePath,
        [string]$ArgumentList,
        [string]$WindowStyle
    )

    $expectedExecutable = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $renderer = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\hooks\Show-Toast.ps1'))
    $expectedArguments = "-NoProfile -ExecutionPolicy Bypass -File `"$renderer`" -Kind "
    if ($FilePath -cne $expectedExecutable -or $WindowStyle -cne 'Hidden') {
        throw 'Unexpected notification process request.'
    }

    if ($ArgumentList -ceq ($expectedArguments + 'question')) {
        $kind = 'question'
    } elseif ($ArgumentList -ceq ($expectedArguments + 'permission')) {
        $kind = 'permission'
    } else {
        throw 'Unexpected notification process arguments.'
    }

    [void][System.IO.Directory]::CreateDirectory($env:COPILOT_PLUGIN_DATA)
    [System.IO.File]::AppendAllText(
        (Join-Path $env:COPILOT_PLUGIN_DATA 'dispatch.txt'),
        ($kind + [Environment]::NewLine)
    )
}

# Aliases override the side-effect functions even after the handler loads its helpers.
# The handler and helpers must keep these calls unqualified for this fixture to intercept them.
Set-Alias -Name Test-TerminalFocused -Value Test-FixtureTerminalFocused
Set-Alias -Name Start-Process -Value Start-FixtureToastProcess

& (Join-Path $PSScriptRoot '..\..\hooks\Show-FocusToast.ps1')
