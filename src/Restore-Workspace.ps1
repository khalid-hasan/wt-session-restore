[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'

$stateDir    = Join-Path $env:USERPROFILE '.wt-session-restore'
$sessionsDir = Join-Path $stateDir 'sessions'
$archiveDir  = Join-Path $stateDir 'archive'
$denyFile    = Join-Path $stateDir 'denylist.txt'

Import-Module (Join-Path $stateDir 'WTSessionRestore.psm1') -Force

$denyList = @()
if (Test-Path -LiteralPath $denyFile) {
    $denyList = Get-Content -LiteralPath $denyFile |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and -not $_.StartsWith('#') }
}

$bootTime   = [System.DateTimeOffset]::FromUnixTimeMilliseconds((Get-BootTimeUtcMs)).UtcDateTime
$sessions   = Read-AllSessions $sessionsDir
$restorable = Select-RestorableSessions -Sessions $sessions -BootTime $bootTime -IsPidAlive {
    param($processId) $null -ne (Get-Process -Id $processId -ErrorAction SilentlyContinue)
}

if (-not $restorable -or $restorable.Count -eq 0) {
    Write-Host 'wt-session-restore: nothing to restore.'
    Start-Sleep -Seconds 2
    return
}

$wt = (Get-Command wt.exe -ErrorAction SilentlyContinue).Source
if (-not $wt) { throw "wt-session-restore: wt.exe (Windows Terminal) was not found on PATH." }

$wtArgs = ConvertTo-WtArgumentList -Sessions $restorable -DenyList $denyList
Start-Process -FilePath $wt -ArgumentList $wtArgs

if (-not (Test-Path -LiteralPath $archiveDir)) { New-Item -ItemType Directory -Path $archiveDir -Force | Out-Null }
foreach ($s in $restorable) {
    if ($s.SourceFile -and (Test-Path -LiteralPath $s.SourceFile)) {
        Move-Item -LiteralPath $s.SourceFile -Destination $archiveDir -Force
    }
}
Write-Host ("wt-session-restore: opened {0} tab(s)." -f $restorable.Count)
