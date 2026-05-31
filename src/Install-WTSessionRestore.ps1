[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'

$srcDir      = $PSScriptRoot
$stateDir    = Join-Path $env:USERPROFILE '.wt-session-restore'
$sessionsDir = Join-Path $stateDir 'sessions'

New-Item -ItemType Directory -Path $sessionsDir -Force | Out-Null

foreach ($f in 'WTSessionRestore.psm1', 'tracker.ps1', 'Restore-Workspace.ps1') {
    Copy-Item -LiteralPath (Join-Path $srcDir $f) -Destination $stateDir -Force
}

$denyFile = Join-Path $stateDir 'denylist.txt'
if (-not (Test-Path -LiteralPath $denyFile)) {
@'
# wt-session-restore: if a command's first token matches a line here it is "trivial"
# and the tab is opened in its folder WITHOUT replaying the command. One token per line.
ls
dir
gci
cd
sl
pwd
cls
clear
cat
type
echo
where
which
ll
'@ | Set-Content -LiteralPath $denyFile -Encoding UTF8
}

$docs = [Environment]::GetFolderPath('MyDocuments')
$profiles = @(
    (Join-Path $docs 'PowerShell\Microsoft.PowerShell_profile.ps1'),        # PowerShell 7
    (Join-Path $docs 'WindowsPowerShell\Microsoft.PowerShell_profile.ps1')  # Windows PowerShell 5.1
)
$trackerPath = Join-Path $stateDir 'tracker.ps1'
$marker = '# >>> wt-session-restore >>>'
$block = @"
$marker
. '$trackerPath'
# <<< wt-session-restore <<<
"@

foreach ($profilePath in $profiles) {
    $dir = Split-Path -Parent $profilePath
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $existing = if (Test-Path -LiteralPath $profilePath) { Get-Content -LiteralPath $profilePath -Raw } else { '' }
    if ($existing -match [regex]::Escape($marker)) {
        Write-Host "Already wired: $profilePath"
    } else {
        Add-Content -LiteralPath $profilePath -Value "`r`n$block`r`n" -Encoding UTF8
        Write-Host "Wired tracker into: $profilePath"
    }
}

$desktop  = [Environment]::GetFolderPath('Desktop')
$lnkPath  = Join-Path $desktop 'Restore Workspace.lnk'
$launcher = Join-Path $stateDir 'Restore-Workspace.ps1'
$pwshPath = (Get-Process -Id $PID).Path
$wsh = New-Object -ComObject WScript.Shell
$sc  = $wsh.CreateShortcut($lnkPath)
$sc.TargetPath       = $pwshPath
$sc.Arguments        = "-NoProfile -ExecutionPolicy Bypass -File `"$launcher`""
$sc.WorkingDirectory = $stateDir
$sc.IconLocation     = "$pwshPath,0"
$sc.Description       = 'Restore PowerShell workspace tabs'
$sc.Save()
Write-Host "Created shortcut: $lnkPath"

Write-Host ''
Write-Host 'Install complete. Open NEW terminal tabs to begin tracking.'
Write-Host 'After a reboot, double-click "Restore Workspace" on your Desktop BEFORE opening terminals manually.'
