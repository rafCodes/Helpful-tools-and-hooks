. "$PSScriptRoot\HookLog.Common.ps1"

function Get-HelpfulHooksHome {
    $copilotHome = $env:COPILOT_HOME
    if ([string]::IsNullOrWhiteSpace($copilotHome)) {
        $copilotHome = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.copilot'
    }
    if ($copilotHome -notmatch '^[A-Za-z]:\\') {
        throw 'COPILOT_HOME must be an absolute local drive path.'
    }
    return [System.IO.Path]::GetFullPath($copilotHome)
}

function Read-HelpfulHooksFile {
    param([Parameter(Mandatory)][string]$Path)

    $file = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($file.PSIsContainer -or ($file.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        throw 'The hook data file must be a regular file.'
    }
    $reader = [System.IO.StreamReader]::new($Path, [System.Text.Encoding]::UTF8, $true)
    try {
        $buffer = [char[]]::new(65537)
        $count = $reader.ReadBlock($buffer, 0, $buffer.Length)
        if ($count -eq $buffer.Length) { throw 'The hook data file exceeds the permitted size.' }
        return [string]::new($buffer, 0, $count)
    } finally {
        $reader.Dispose()
    }
}

function Initialize-HelpfulHooksConfig {
    $copilotHome = Get-HelpfulHooksHome
    $configPath = Join-Path $copilotHome 'helpful-tools-and-hooks.json'
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        [void][System.IO.Directory]::CreateDirectory($copilotHome)
        $temporaryPath = Join-Path $copilotHome ('.helpful-tools-and-hooks-' + [guid]::NewGuid().ToString('N') + '.tmp')
        try {
            [System.IO.File]::WriteAllText(
                $temporaryPath,
                ('{"compactionToastEnabled":false}' + [Environment]::NewLine),
                [System.Text.UTF8Encoding]::new($false)
            )
            try {
                # Publish a complete file without replacing another session's config.
                [System.IO.File]::Move($temporaryPath, $configPath)
            } catch [System.IO.IOException] {
                if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { throw }
            }
        } finally {
            if ([System.IO.File]::Exists($temporaryPath)) { [System.IO.File]::Delete($temporaryPath) }
        }
    }

    $null = Get-HelpfulHooksConfig
}

function Get-HelpfulHooksConfig {
    $configPath = Join-Path (Get-HelpfulHooksHome) 'helpful-tools-and-hooks.json'
    $raw = (Read-HelpfulHooksFile -Path $configPath).Trim()
    if (-not $raw.StartsWith('{')) { throw 'The hook configuration must be a JSON object.' }
    $config = ConvertFrom-Json -InputObject $raw -ErrorAction Stop
    if ($config.compactionToastEnabled -isnot [bool]) {
        throw 'compactionToastEnabled must be a JSON boolean.'
    }
    return $config
}

function ConvertTo-CompactionSessionId {
    param([Parameter(Mandatory)][string]$SessionId)

    $id = [guid]::Empty
    if (-not [guid]::TryParseExact($SessionId, 'D', [ref]$id)) { throw 'Invalid session ID.' }
    return $id.ToString('D')
}

function Get-CompactionSessionName {
    param([Parameter(Mandatory)][string]$SessionId)

    $SessionId = ConvertTo-CompactionSessionId -SessionId $SessionId
    $sessionDirectory = Join-Path (Join-Path (Get-HelpfulHooksHome) 'session-state') $SessionId
    if ((Get-Item -LiteralPath $sessionDirectory -ErrorAction Stop).Attributes -band
        [System.IO.FileAttributes]::ReparsePoint) {
        throw 'The session directory must not be a link.'
    }
    $metadata = Read-HelpfulHooksFile -Path (Join-Path $sessionDirectory 'workspace.yaml')
    $lines = $metadata -split '\r?\n'
    $nameIndex = -1
    for ($i = 0; $i -lt $lines.Length; $i++) {
        if ($lines[$i].StartsWith('name:', [System.StringComparison]::Ordinal) -and
            ($lines[$i].Length -eq 5 -or $lines[$i][5] -in @([char]32, [char]9))) {
            if ($nameIndex -ne -1) { throw 'The session metadata must contain one name.' }
            $nameIndex = $i
        }
    }
    if ($nameIndex -eq -1) { throw 'The session metadata must contain one name.' }
    for ($i = $nameIndex + 1; $i -lt $lines.Length; $i++) {
        if ([string]::IsNullOrWhiteSpace($lines[$i]) -or $lines[$i] -match '^[ \t]*#') { continue }
        if ($lines[$i][0] -in @([char]32, [char]9)) { throw 'Multiline session names are not supported.' }
        break
    }

    $scalar = $lines[$nameIndex].Substring(5).Trim([char[]]@([char]32, [char]9))
    if ($scalar.Length -gt 4096) { throw 'The encoded session name exceeds the permitted size.' }
    if ($scalar.StartsWith('"')) {
        if ($scalar -notmatch '^"(?:[^"\\\p{Cc}]|\\(?:["\\/bfnrt]|u[0-9a-fA-F]{4}))*"$') {
            throw 'The quoted session name must be a JSON-compatible string.'
        }
        Add-Type -AssemblyName System.Runtime.Serialization -ErrorAction Stop
        $stream = [System.IO.MemoryStream]::new([System.Text.Encoding]::UTF8.GetBytes($scalar))
        try {
            $serializer = [System.Runtime.Serialization.Json.DataContractJsonSerializer]::new([string])
            $name = $serializer.ReadObject($stream)
        } finally {
            $stream.Dispose()
        }
    } elseif ($scalar.StartsWith("'")) {
        if ($scalar -notmatch "^'(?:[^']|'')*'$") { throw 'Invalid quoted session name.' }
        $name = $scalar.Substring(1, $scalar.Length - 2).Replace("''", "'")
    } else {
        if ($scalar -match '^[|>!&*\[{}#]') {
            throw 'The session name must be an inline text scalar.'
        }
        for ($i = 1; $i -lt $scalar.Length; $i++) {
            if ($scalar[$i] -eq '#' -and $scalar[$i - 1] -in @([char]32, [char]9)) {
                $scalar = $scalar.Substring(0, $i)
                break
            }
        }
        $name = $scalar.TrimEnd([char[]]@([char]32, [char]9))
        if ($name -cmatch '^(?:null|Null|NULL|~|true|True|TRUE|false|False|FALSE)$') {
            throw 'The session name must be an inline text scalar.'
        }
    }
    if ($name -isnot [string] -or [string]::IsNullOrWhiteSpace($name) -or
        $name.Length -gt 512 -or $name -match '[\p{Cc}\p{Zl}\p{Zp}\u061C\u200E\u200F\u202A-\u202E\u2066-\u2069]') {
        throw 'The session name must contain 1 to 512 characters without control, line-break, or bidirectional formatting characters.'
    }
    return $name
}
