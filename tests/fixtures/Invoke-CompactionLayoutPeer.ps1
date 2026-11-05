param(
    [Parameter(Mandatory)][guid]$CoordinationId,
    [Parameter(Mandatory)][guid]$SessionId
)

$ErrorActionPreference = 'Stop'
$parentData = [System.IO.Path]::GetFullPath($env:COPILOT_PLUGIN_DATA)
if ([System.IO.Path]::GetFileName([System.IO.Path]::GetDirectoryName($parentData)) -notmatch '^helpful-hooks-test-[0-9a-f]{32}$') {
    throw 'Run tests\Test-Hooks.ps1. The layout peer requires isolated plugin data.'
}
$env:COPILOT_PLUGIN_DATA = Join-Path $parentData ('peer-' + $SessionId.ToString('N'))
$env:COPILOT_HOME = Join-Path $env:COPILOT_PLUGIN_DATA 'copilot-home'
$directory = Join-Path $env:COPILOT_HOME ('session-state\' + $SessionId.ToString('D'))
[void][System.IO.Directory]::CreateDirectory($directory)
[System.IO.File]::WriteAllText((Join-Path $directory 'workspace.yaml'), 'name: Layout peer session')

. "$PSScriptRoot\..\..\hooks\QuestionAlert.Common.ps1"
function Get-FixtureLayoutScope { return ('fixture-layout-' + $script:CoordinationId.ToString('N')) }
Set-Alias -Name Get-QuestionAlertScope -Value Get-FixtureLayoutScope

$content = New-QuestionAlertContent -Kind compaction -SessionId $SessionId.ToString('D')
$content.WindowStyle = [System.Windows.WindowStyle]::None
$content.AllowsTransparency = $true
$content.Opacity = 0
function New-FixtureContent { return $script:content }
Set-Alias -Name New-QuestionAlertContent -Value New-FixtureContent
$window = New-QuestionAlertWindow -Kind compaction -SessionId $SessionId.ToString('D')
$player = New-QuestionAlertPlayer
$player.IsMuted = $true
function New-FixtureWindow { return $script:window }
function New-FixturePlayer { return $script:player }
Set-Alias -Name New-QuestionAlertWindow -Value New-FixtureWindow
Set-Alias -Name New-QuestionAlertPlayer -Value New-FixturePlayer

$stop = [System.Threading.EventWaitHandle]::new(
    $false, [System.Threading.EventResetMode]::ManualReset,
    ('Local\CopilotHelpfulToolsLayoutPeer-' + $CoordinationId.ToString('N') + '-' + $SessionId.ToString('D'))
)
$timer = [System.Windows.Threading.DispatcherTimer]::new()
$timer.Interval = [TimeSpan]::FromMilliseconds(100)
$timer.Add_Tick({ if ($stop.WaitOne(0)) { $window.Close() } })
try {
    $timer.Start()
    Show-QuestionAlert -Kind compaction -SessionId $SessionId.ToString('D')
    $results = @(Get-Content -LiteralPath (Join-Path $env:COPILOT_PLUGIN_DATA 'hooks.log') | ForEach-Object { $_ | ConvertFrom-Json })
    if ('compaction_alert_displayed' -notin $results.code -or 'did_not_work' -in $results.outcome) {
        throw 'The separate-process compaction alert failed.'
    }
    'PASS compaction layout peer checks'
} finally {
    $timer.Stop()
    $window.Close()
    $player.Close()
    $stop.Dispose()
}
