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

function Select-OpenSessions {
    # Project the currently-alive sessions down to the fields a tab needs to be
    # reopened. This is the set an autosave snapshots as "what is open right now".
    [CmdletBinding()]
    param(
        [AllowNull()][object[]]$Sessions = @(),
        [Parameter(Mandatory)][scriptblock]$IsPidAlive
    )

    $result = foreach ($s in $Sessions) {
        if (-not [bool](& $IsPidAlive $s.pid)) { continue }
        [pscustomobject]@{ cwd = $s.cwd; command = $s.command; shell = $s.shell }
    }
    @($result)
}

function Get-BootTimeUtcMs {
    # Epoch-ms of the last system boot. MUST be stable across calls within a boot, or the
    # autosave's boot-transition check fires constantly and clobbers restore.json. The OS
    # boot timestamp is exact and fixed per boot; the uptime-derived value jitters by a few
    # ms per call, so it's only a rounded fallback. Only Save-Workspace (background, every
    # ~2 min) and Restore (on demand) call this, so the ~1.4s CIM cost doesn't matter — the
    # interactive tracker never calls it.
    [CmdletBinding()]
    param()
    try {
        $boot = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime
        return [int64][System.DateTimeOffset]::new($boot.ToUniversalTime()).ToUnixTimeMilliseconds()
    } catch {
        $raw = [System.DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - [System.Environment]::TickCount64
        return [int64]([math]::Round($raw / 10000.0) * 10000)   # round to 10s so calls agree
    }
}

function ConvertTo-WtArgumentList {
    [CmdletBinding()]
    param(
        [AllowNull()][object[]]$Sessions = @(),
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

function Select-MissingTabs {
    # Multiset difference: of the saved tabs, return only those NOT already open, so Restore
    # never duplicates a tab you still have open. Matches on (cwd, command), case-insensitive,
    # by count — so two identical tabs with one still open reopens exactly one.
    [CmdletBinding()]
    param(
        [AllowNull()][object[]]$Saved = @(),
        [AllowNull()][object[]]$Open  = @()
    )
    $keyOf = { param($t) ("{0}`n{1}" -f $t.cwd, $t.command).ToLowerInvariant() }

    $openCounts = @{}
    foreach ($o in $Open) {
        $k = & $keyOf $o
        if ($openCounts.ContainsKey($k)) { $openCounts[$k]++ } else { $openCounts[$k] = 1 }
    }
    $missing = foreach ($s in $Saved) {
        $k = & $keyOf $s
        if ($openCounts.ContainsKey($k) -and $openCounts[$k] -gt 0) {
            $openCounts[$k]--   # already open — consume one and skip
        } else {
            $s
        }
    }
    @($missing)
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

Export-ModuleMember -Function Get-CommandFirstToken, Resolve-RestoreAction, Select-OpenSessions, Select-MissingTabs, ConvertTo-WtArgumentList, Read-AllSessions, Write-SessionStateAtomic, Get-BootTimeUtcMs
