# Save-Workspace.ps1
#   (no args)        run by the scheduled task every ~2 min: rolling autosave for reboot recovery.
#   -AsRestorePoint  run by the "Save Workspace" Desktop button: checkpoint the current tabs NOW
#                    as the set that Restore will reopen.
[CmdletBinding()]
param([switch]$AsRestorePoint)
$ErrorActionPreference = 'Stop'

$stateDir    = Join-Path $env:USERPROFILE '.wt-session-restore'
$sessionsDir = Join-Path $stateDir 'sessions'
$layoutFile  = Join-Path $stateDir 'layout.json'
$restoreFile = Join-Path $stateDir 'restore.json'

Import-Module (Join-Path $stateDir 'WTSessionRestore.psm1') -Force

$bootMs = Get-BootTimeUtcMs
$open = Select-OpenSessions -Sessions (Read-AllSessions $sessionsDir) -IsPidAlive {
    param($processId) $null -ne (Get-Process -Id $processId -ErrorAction SilentlyContinue)
}
$snapshot = [pscustomobject]@{
    bootMs    = $bootMs
    savedAtMs = [System.DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    tabs      = @($open)
}

if ($AsRestorePoint) {
    # Manual checkpoint: this IS the set Restore will reopen. Write it as the restore point
    # and keep layout.json in sync so the next autosave doesn't immediately diverge.
    Write-SessionStateAtomic -Path $restoreFile -State $snapshot
    Write-SessionStateAtomic -Path $layoutFile  -State $snapshot
    Write-Host ("wt-session-restore: saved workspace ({0} tab(s))." -f @($open).Count)
    Start-Sleep -Seconds 2   # leave the confirmation on screen briefly
    return
}

# Autosave: if the existing layout is from a previous boot, it's the pre-shutdown workspace —
# promote it to the restore point before this session overwrites layout.json.
if (Test-Path -LiteralPath $layoutFile) {
    try {
        $existing = Get-Content -LiteralPath $layoutFile -Raw | ConvertFrom-Json
        if ([int64]$existing.bootMs -ne $bootMs -and @($existing.tabs).Count -gt 0) {
            Copy-Item -LiteralPath $layoutFile -Destination $restoreFile -Force
        }
    } catch { }
}
Write-SessionStateAtomic -Path $layoutFile -State $snapshot
