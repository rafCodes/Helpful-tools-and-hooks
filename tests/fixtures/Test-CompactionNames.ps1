$ErrorActionPreference = 'Stop'
$testData = [System.IO.Path]::GetFullPath($env:COPILOT_PLUGIN_DATA)
$testRoot = [System.IO.Path]::GetDirectoryName($testData)
if ([System.IO.Path]::GetFileName($testRoot) -notmatch '^helpful-hooks-test-[0-9a-f]{32}$' -or
    -not (Test-Path -LiteralPath $testData -PathType Container)) {
    throw 'Run tests\Test-Hooks.ps1. The name fixture requires isolated plugin data.'
}
$env:COPILOT_HOME = Join-Path $testData 'copilot-home'
. "$PSScriptRoot\..\..\hooks\Compaction.Common.ps1"

$sessionId = '11111111-1111-1111-1111-111111111111'
$sessionDirectory = Join-Path $env:COPILOT_HOME "session-state\$sessionId"
[void][System.IO.Directory]::CreateDirectory($sessionDirectory)
$metadataPath = Join-Path $sessionDirectory 'workspace.yaml'
$unicodeName = 'Session ' + [char]0x00E9 + [char]0x4E2D + [char]::ConvertFromUtf32(0x1F642)
$nameCases = @(
    @{ Scalar = 'Compaction test canary'; Expected = 'Compaction test canary' },
    @{ Scalar = "'Build ''quotes'' & <markup>'"; Expected = "Build 'quotes' & <markup>" },
    @{ Scalar = '"Build \"quoted\" C:\\work <tags> $()"'; Expected = 'Build "quoted" C:\work <tags> $()' },
    @{ Scalar = '"2024-01-01T10:00:00"'; Expected = '2024-01-01T10:00:00' },
    @{ Scalar = ($unicodeName | ConvertTo-Json -Compress); Expected = $unicodeName },
    @{ Scalar = 'Plain name # metadata comment'; Expected = 'Plain name' },
    @{ Scalar = '"null"'; Expected = 'null' },
    @{ Scalar = 'null'; Expected = $null },
    @{ Scalar = 'null # metadata comment'; Expected = $null },
    @{ Scalar = '~'; Expected = $null },
    @{ Scalar = "First line`n  continuation"; Expected = $null },
    @{ Scalar = "First name`nname: Second name"; Expected = $null },
    @{ Scalar = '|'; Expected = $null },
    @{ Scalar = '""'; Expected = $null },
    @{ Scalar = '"First\u0085second"'; Expected = $null },
    @{ Scalar = '"First\u2028second"'; Expected = $null },
    @{ Scalar = '"First\u2029second"'; Expected = $null },
    @{ Scalar = '"First\u202esecond"'; Expected = $null },
    @{ Scalar = '"First\u2066second"'; Expected = $null },
    @{ Scalar = ('x' * 513); Expected = $null },
    @{ Scalar = (' ' * 32768); Expected = $null }
)
foreach ($case in $nameCases) {
    [System.IO.File]::WriteAllText(
        $metadataPath, "id: $sessionId`nname: $($case.Scalar)`n", [System.Text.UTF8Encoding]::new($false)
    )
    $failed = $false
    $name = $null
    try { $name = Get-CompactionSessionName -SessionId $sessionId } catch { $failed = $true }
    if (($null -eq $case.Expected -and -not $failed) -or
        ($null -ne $case.Expected -and ($failed -or $name -cne $case.Expected))) {
        throw 'The production session name parser rejected valid text or accepted unsupported metadata.'
    }
}
[System.IO.File]::WriteAllText($metadataPath, ('x' * 65537))
$rejected = $false
try { $null = Get-CompactionSessionName -SessionId $sessionId } catch { $rejected = $true }
if (-not $rejected) { throw 'The session metadata size limit was not enforced.' }

$previousHome = $env:COPILOT_HOME
try {
    foreach ($invalidHome in @('relative-home', 'C:relative-home', '\\server\share', '\\.\pipe\copilot')) {
        $env:COPILOT_HOME = $invalidHome
        $rejected = $false
        try { $null = Get-HelpfulHooksHome } catch { $rejected = $true }
        if (-not $rejected) { throw 'An invalid or non-local COPILOT_HOME was accepted.' }
    }
} finally {
    $env:COPILOT_HOME = $previousHome
}
if ((ConvertTo-CompactionSessionId -SessionId ("`n" + $sessionId.ToUpperInvariant() + "`n")) -cne $sessionId) {
    throw 'Session ID canonicalization failed.'
}
'PASS compaction name checks'
