<#
    Toggle-Tts.ps1 — flips enabled.txt for the text-to-speech skill.

    Usage:
        .\Toggle-Tts.ps1                 # flip current state
        .\Toggle-Tts.ps1 -State on       # force on
        .\Toggle-Tts.ps1 -State off      # force off
        .\Toggle-Tts.ps1 -Status         # just print current state
#>
[CmdletBinding()]
param(
    [ValidateSet('on', 'off')]
    [string]$State,
    [switch]$Status
)

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$flagFile = Join-Path $scriptDir "..\..\hooks\text-to-speech\enabled.txt"
$flagFile = [System.IO.Path]::GetFullPath($flagFile)

function Read-Flag {
    $raw = (Get-Content $flagFile -Raw -ErrorAction SilentlyContinue)
    if ($null -eq $raw) { return $false }
    # Strip UTF-8 BOM if present
    if ($raw.Length -gt 0 -and $raw[0] -eq [char]0xFEFF) { $raw = $raw.Substring(1) }
    return ($raw.Trim().ToLower() -eq 'true')
}

function Write-Flag([bool]$enabled) {
    $value = if ($enabled) { 'true' } else { 'false' }
    [System.IO.File]::WriteAllText($flagFile, $value, [System.Text.UTF8Encoding]::new($false))
}

$current = Read-Flag

if ($Status) {
    Write-Host "TTS is currently $(if ($current) {'enabled'} else {'disabled'})"
    return
}

if (-not (Test-Path -LiteralPath $flagFile)) {
    [System.IO.File]::WriteAllText($flagFile, "false", [System.Text.UTF8Encoding]::new($false))
}

if ($State) {
    $new = ($State -eq 'on')
} else {
    $new = -not $current
}

Write-Flag $new
Write-Host "TTS $(if ($new) {'enabled'} else {'disabled'}) ($flagFile)"
