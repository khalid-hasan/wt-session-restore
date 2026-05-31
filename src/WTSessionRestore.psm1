# WTSessionRestore — pure logic + IO helpers for capturing/restoring terminal tabs.

function Get-CommandFirstToken {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Command)

    $trimmed = $Command.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) { return '' }

    if ($trimmed -match '^\s*"([^"]+)"') {
        $first = $Matches[1]
    } else {
        $first = ($trimmed -split '\s+')[0]
    }

    $leaf = [System.IO.Path]::GetFileName($first)
    if ([string]::IsNullOrEmpty($leaf)) { $leaf = $first }
    $noExt = [System.IO.Path]::GetFileNameWithoutExtension($leaf)
    if ([string]::IsNullOrEmpty($noExt)) { $noExt = $leaf }

    return $noExt.ToLowerInvariant()
}

function Resolve-RestoreAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Command,
        [string[]]$DenyList = @()
    )

    $token = Get-CommandFirstToken $Command
    $deny  = @($DenyList | ForEach-Object { $_.ToLowerInvariant() })

    $folderOnly = [pscustomobject]@{ Replay = $false; Command = $null }
    $replay     = [pscustomobject]@{ Replay = $true;  Command = $Command.Trim() }

    if ([string]::IsNullOrEmpty($token)) { return $folderOnly }
    if ($deny -contains $token)          { return $folderOnly }

    if ($token -eq 'git') {
        $parts = ($Command.Trim() -split '\s+')
        $sub = if ($parts.Count -ge 2) { $parts[1].ToLowerInvariant() } else { '' }
        $trivialGit = @('status', 'log', 'diff', 'branch', 'show', 'stash')
        if ($trivialGit -contains $sub) { return $folderOnly }
    }

    return $replay
}

function Select-RestorableSessions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Sessions,
        [Parameter(Mandatory)][datetime]$BootTime,
        [Parameter(Mandatory)][scriptblock]$IsPidAlive
    )

    # updatedAt is epoch milliseconds (UTC). Integer comparison avoids the
    # timezone/Kind ambiguity that ConvertFrom-Json introduces with date strings.
    $bootMs = [System.DateTimeOffset]::new($BootTime.ToUniversalTime()).ToUnixTimeMilliseconds()
    $result = foreach ($s in $Sessions) {
        if ([bool](& $IsPidAlive $s.pid)) { continue }
        if ([int64]$s.updatedAt -lt $bootMs) { $s }
    }
    @($result)
}

function Build-WtArgumentList {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Sessions,
        [string[]]$DenyList = @()
    )

    $wtArgs = [System.Collections.Generic.List[string]]::new()
    $first = $true
    foreach ($s in $Sessions) {
        if (-not $first) { $wtArgs.Add(';') }
        $first = $false

        $title  = Split-Path -Path $s.cwd -Leaf
        $action = Resolve-RestoreAction -Command $s.command -DenyList $DenyList

        $wtArgs.Add('new-tab')
        $wtArgs.Add('--title'); $wtArgs.Add($title)
        $wtArgs.Add('-d');      $wtArgs.Add($s.cwd)
        $wtArgs.Add($s.shell)
        $wtArgs.Add('-NoExit')
        if ($action.Replay -and $action.Command) {
            $wtArgs.Add('-Command'); $wtArgs.Add($action.Command)
        }
    }
    return $wtArgs.ToArray()
}

function Read-AllSessions {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SessionsDir)

    if (-not (Test-Path -LiteralPath $SessionsDir)) { return @() }

    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($file in Get-ChildItem -LiteralPath $SessionsDir -Filter '*.json' -File) {
        try {
            $obj = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
            $obj | Add-Member -NotePropertyName SourceFile -NotePropertyValue $file.FullName -Force
            $out.Add($obj)
        } catch {
            Write-Warning "wt-session-restore: skipping malformed session file: $($file.FullName)"
        }
    }
    @($out)
}

function Write-SessionStateAtomic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object]$State
    )
    $tmp = "$Path.tmp"
    ($State | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

Export-ModuleMember -Function Get-CommandFirstToken, Resolve-RestoreAction, Select-RestorableSessions, Build-WtArgumentList, Read-AllSessions, Write-SessionStateAtomic
