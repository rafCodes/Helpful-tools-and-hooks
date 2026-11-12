param(
    [Parameter(Mandatory)][guid]$CoordinationId,
    [guid]$SessionId = '11111111-1111-1111-1111-111111111111',
    [ValidateSet('question', 'compaction', 'failure')][string]$Kind = 'question'
)

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
    ) -IncludeSession:($Kind -ne 'compaction')
    function New-FixtureQuestionAlertCoordination {
        param([string]$NamePrefix, [switch]$IncludeSession)
        $expectedPrefix = switch ($script:Kind) {
            'compaction' { 'Local\CopilotHelpfulToolsCompactionAlert-11111111-1111-1111-1111-111111111111' }
            'failure' { 'Local\CopilotHelpfulToolsExecutionFailureAlert' }
            'question' { '' }
        }
        if ($NamePrefix -cne $expectedPrefix -or $IncludeSession.IsPresent -ne ($script:Kind -ne 'compaction')) {
            throw 'The repeated alert used the wrong coordination scope or session channel.'
        }
        return $script:fixtureCoordination
    }
    function New-FixtureUnexpectedWindow { throw 'A repeated question created another window.' }
    function New-FixtureUnexpectedPlayer { throw 'A repeated question created another sound player.' }
    Set-Alias -Name New-QuestionAlertCoordination -Value New-FixtureQuestionAlertCoordination
    Set-Alias -Name New-QuestionAlertWindow -Value New-FixtureUnexpectedWindow
    Set-Alias -Name New-QuestionAlertPlayer -Value New-FixtureUnexpectedPlayer

    Show-QuestionAlert -Kind $Kind -SessionId $SessionId.ToString('D')
    $results = @(Get-Content -LiteralPath (Join-Path $testLogDir 'hooks.log') | ForEach-Object {
        $_ | ConvertFrom-Json
    })
    $expectedCode = switch ($Kind) {
        'compaction' { 'compaction_alert_reused' }
        'failure' { 'failure_alert_reused' }
        'question' { 'question_alert_reused' }
    }
    if ($results.Count -ne 1 -or $results[0].code -cne $expectedCode -or
        $results[0].outcome -cne 'worked') {
        throw 'The repeated question did not signal the existing alert.'
    }
    "PASS $Kind alert reuse checks"
} finally {
    if ($fixtureCoordination) {
        if ($fixtureCoordination.Session) { $fixtureCoordination.Session.Dispose() }
        $fixtureCoordination.Signal.Dispose()
        $fixtureCoordination.Owner.Dispose()
        $fixtureCoordination.Gate.Dispose()
    }
    $env:COPILOT_PLUGIN_DATA = $previousPluginData
    if (Test-Path -LiteralPath $testLogDir) {
        Remove-Item -LiteralPath $testLogDir -Recurse -Force
    }
}
