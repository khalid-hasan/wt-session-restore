# Save-Workspace.ps1 — run by a scheduled task at logon + every couple of minutes.
# Snapshots the currently-open PowerShell tabs into layout.json. Across a reboot it
# promotes the previous session's layout into restore.json exactly once, so a fresh
# session's autosaves can never clobber the workspace you want to restore.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'

$stateDir    = Join-Path $env:USERPROFILE '.wt-session-restore'
$sessionsDir = Join-Path $stateDir 'sessions'
$layoutFile  = Join-Path $stateDir 'layout.json'
$restoreFile = Join-Path $stateDir 'restore.json'

Import-Module (Join-Path $stateDir 'WTSessionRestore.psm1') -Force

$bootMs = Get-BootTimeUtcMs

# Boot transition: if the existing layout is from a previous boot, it represents the
# workspace as it was just before shutdown — preserve it as the restore point before
# this session starts overwriting layout.json.
if (Test-Path -LiteralPath $layoutFile) {
    try {
        $existing = Get-Content -LiteralPath $layoutFile -Raw | ConvertFrom-Json
        if ([int64]$existing.bootMs -ne $bootMs -and @($existing.tabs).Count -gt 0) {
            Copy-Item -LiteralPath $layoutFile -Destination $restoreFile -Force
        }
    } catch { }
}

# Snapshot the tabs that are open right now.
$open = Select-OpenSessions -Sessions (Read-AllSessions $sessionsDir) -IsPidAlive {
    param($processId) $null -ne (Get-Process -Id $processId -ErrorAction SilentlyContinue)
}

$layout = [pscustomobject]@{
    bootMs    = $bootMs
    savedAtMs = [System.DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    tabs      = @($open)
}
Write-SessionStateAtomic -Path $layoutFile -State $layout
