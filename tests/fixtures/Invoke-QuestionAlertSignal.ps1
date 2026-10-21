param([Parameter(Mandatory)][guid]$CoordinationId)

$ErrorActionPreference = 'Stop'
$previousPluginData = $env:COPILOT_PLUGIN_DATA
$testLogDir = Join-Path ([System.IO.Path]::GetTempPath()) ("helpful-question-signal-{0}" -f [guid]::NewGuid().ToString('N'))
$fixtureCoordination = $null

try {
    [void][System.IO.Directory]::CreateDirectory($testLogDir)
    $env:COPILOT_PLUGIN_DATA = $testLogDir
    . "$PSScriptRoot\..\..\hooks\QuestionAlert.Common.ps1"
    $fixtureCoordination = New-QuestionAlertCoordination -NamePrefix (
        'Local\CopilotHelpfulToolsQuestionAlertTest-' + $CoordinationId.ToString('N')
    )
    function New-FixtureQuestionAlertCoordination { return $script:fixtureCoordination }
    function New-FixtureUnexpectedWindow { throw 'A repeated question created another window.' }
    function New-FixtureUnexpectedPlayer { throw 'A repeated question created another sound player.' }
    Set-Alias -Name New-QuestionAlertCoordination -Value New-FixtureQuestionAlertCoordination
    Set-Alias -Name New-QuestionAlertWindow -Value New-FixtureUnexpectedWindow
    Set-Alias -Name New-QuestionAlertPlayer -Value New-FixtureUnexpectedPlayer

    Show-QuestionAlert
    $results = @(Get-Content -LiteralPath (Join-Path $testLogDir 'hooks.log') | ForEach-Object {
        $_ | ConvertFrom-Json
    })
    if ($results.Count -ne 1 -or $results[0].code -cne 'question_alert_reused' -or
        $results[0].outcome -cne 'worked') {
        throw 'The repeated question did not signal the existing alert.'
    }
    'PASS question alert reuse checks'
} finally {
    if ($fixtureCoordination) {
        $fixtureCoordination.Signal.Dispose()
        $fixtureCoordination.Owner.Dispose()
        $fixtureCoordination.Gate.Dispose()
    }
    $env:COPILOT_PLUGIN_DATA = $previousPluginData
    if (Test-Path -LiteralPath $testLogDir) {
        Remove-Item -LiteralPath $testLogDir -Recurse -Force
    }
}
