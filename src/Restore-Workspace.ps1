# Restore-Workspace.ps1 — run by the Desktop shortcut. Reopens the tabs from the most
# recent autosaved snapshot taken before the current boot.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'

$stateDir    = Join-Path $env:USERPROFILE '.wt-session-restore'
$sessionsDir = Join-Path $stateDir 'sessions'
$layoutFile  = Join-Path $stateDir 'layout.json'
$restoreFile = Join-Path $stateDir 'restore.json'
$denyFile    = Join-Path $stateDir 'denylist.txt'

Import-Module (Join-Path $stateDir 'WTSessionRestore.psm1') -Force

function Read-Layout([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json } catch { return $null }
}

$currentBootMs = Get-BootTimeUtcMs
$layout  = Read-Layout $layoutFile
$restore = Read-Layout $restoreFile

# Pick the snapshot that represents the workspace from before this boot:
#  1. layout.json still holds the previous session (autosave hasn't transitioned yet)
#  2. restore.json (the promoted pre-reboot snapshot)
#  3. layout.json from this same boot (no reboot — e.g. testing / same-session recovery)
if ($layout -and [int64]$layout.bootMs -ne $currentBootMs) {
    $chosen = $layout
} elseif ($restore) {
    $chosen = $restore
} else {
    $chosen = $layout
}

$tabs = if ($chosen) { @($chosen.tabs) } else { @() }
if ($tabs.Count -eq 0) {
    Write-Host 'wt-session-restore: nothing to restore (no saved workspace yet).'
    Start-Sleep -Seconds 2
    return
}

# Only reopen tabs that aren't already open, so closing some tabs and restoring fills the
# gaps instead of duplicating the tabs you still have open.
$open = Select-OpenSessions -Sessions (Read-AllSessions $sessionsDir) -IsPidAlive {
    param($processId) $null -ne (Get-Process -Id $processId -ErrorAction SilentlyContinue)
}
$toOpen = Select-MissingTabs -Saved $tabs -Open $open
if ($toOpen.Count -eq 0) {
    Write-Host 'wt-session-restore: nothing to restore — all saved tabs are already open.'
    Start-Sleep -Seconds 2
    return
}

$denyList = @()
if (Test-Path -LiteralPath $denyFile) {
    $denyList = Get-Content -LiteralPath $denyFile |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and -not $_.StartsWith('#') }
}

$wt = (Get-Command wt.exe -ErrorAction SilentlyContinue).Source
if (-not $wt) { throw "wt-session-restore: wt.exe (Windows Terminal) was not found on PATH." }

$wtArgs = ConvertTo-WtArgumentList -Sessions $toOpen -DenyList $denyList
Start-Process -FilePath $wt -ArgumentList $wtArgs
Write-Host ("wt-session-restore: opened {0} of {1} saved tab(s) ({2} already open)." -f $toOpen.Count, $tabs.Count, ($tabs.Count - $toOpen.Count))
