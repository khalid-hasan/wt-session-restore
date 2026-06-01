# tracker.ps1 — dot-sourced from the PowerShell profile by wt-session-restore.
# Records this tab's folder + last-launched command so it can be restored after a reboot.

Import-Module (Join-Path $PSScriptRoot 'WTSessionRestore.psm1') -Force -ErrorAction SilentlyContinue

$script:WTSRStateDir    = Join-Path $env:USERPROFILE '.wt-session-restore'
$script:WTSRSessionsDir = Join-Path $script:WTSRStateDir 'sessions'
$script:WTSRSessionId   = [guid]::NewGuid().ToString('N')
$script:WTSRSessionFile = Join-Path $script:WTSRSessionsDir ("{0}.json" -f $script:WTSRSessionId)
$script:WTSRShellPath   = (Get-Process -Id $PID).Path

if (-not (Test-Path -LiteralPath $script:WTSRSessionsDir)) {
    New-Item -ItemType Directory -Path $script:WTSRSessionsDir -Force | Out-Null
}

# Reap dead session files. The session files are just live scratch state — the
# autosave snapshots only ALIVE sessions, so any dead-PID file is no longer needed.
# (The restorable workspace lives in layout.json / restore.json, not here.)
try {
    foreach ($s in (Read-AllSessions $script:WTSRSessionsDir)) {
        if ($null -eq (Get-Process -Id $s.pid -ErrorAction SilentlyContinue)) {
            Remove-Item -LiteralPath $s.SourceFile -Force -ErrorAction SilentlyContinue
        }
    }
} catch { }

function Save-WTSRState {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Command)
    try {
        $state = [pscustomobject]@{
            id        = $script:WTSRSessionId
            pid       = $PID
            shell     = $script:WTSRShellPath
            cwd       = (Get-Location).Path
            command   = $Command
            updatedAt = [System.DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        }
        Write-SessionStateAtomic -Path $script:WTSRSessionFile -State $state
    } catch { }
}

# Capture the command line at Enter-time (before it runs) so long-running
# processes like `claude` are recorded. ValidateAndAcceptLine preserves
# multiline editing; intermediate partial captures get overwritten by the final one.
if (Get-Module PSReadLine) {
    Set-PSReadLineKeyHandler -Key Enter -ScriptBlock {
        param($key, $arg)
        $line = $null; $cursor = $null
        [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)
        if (-not [string]::IsNullOrWhiteSpace($line)) { Save-WTSRState -Command $line.Trim() }
        [Microsoft.PowerShell.PSConsoleReadLine]::ValidateAndAcceptLine()
    }
}

# Seed a folder-only record so a tab that never runs a command still restores its folder.
Save-WTSRState -Command ''

# Best-effort cleanup of our own file on graceful exit. Unreliable across shutdowns,
# but it no longer matters: restore reads the autosaved snapshot, not surviving files.
Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
    Remove-Item -LiteralPath $script:WTSRSessionFile -Force -ErrorAction SilentlyContinue
} | Out-Null
