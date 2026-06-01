[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'

$srcDir      = $PSScriptRoot
$stateDir    = Join-Path $env:USERPROFILE '.wt-session-restore'
$sessionsDir = Join-Path $stateDir 'sessions'

New-Item -ItemType Directory -Path $sessionsDir -Force | Out-Null

foreach ($f in 'WTSessionRestore.psm1', 'tracker.ps1', 'Restore-Workspace.ps1', 'Save-Workspace.ps1') {
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

# "Save Workspace" shortcut — manual checkpoint of the current tabs (visible, shows a confirmation).
$saveLnk    = Join-Path $desktop 'Save Workspace.lnk'
$saveScript = Join-Path $stateDir 'Save-Workspace.ps1'
$scSave = $wsh.CreateShortcut($saveLnk)
$scSave.TargetPath       = $pwshPath
$scSave.Arguments        = "-NoProfile -ExecutionPolicy Bypass -File `"$saveScript`" -AsRestorePoint"
$scSave.WorkingDirectory = $stateDir
$scSave.IconLocation     = "$pwshPath,0"
$scSave.Description       = 'Save the current PowerShell tabs as the restore point'
$scSave.Save()
Write-Host "Created shortcut: $saveLnk"

# Autosave scheduled task: snapshot open tabs every 2 minutes while logged on.
# Registered with schtasks.exe (per-user, no admin). Launched via a tiny VBScript so
# pwsh runs fully hidden — no console window flashing every couple of minutes.
$vbs        = Join-Path $stateDir 'run-hidden.vbs'
$taskName   = 'wt-session-restore autosave'

@"
Set sh = CreateObject("WScript.Shell")
cmd = """" & "$pwshPath" & """" & " -NoProfile -ExecutionPolicy Bypass -File " & """" & "$saveScript" & """"
sh.Run cmd, 0, False
"@ | Set-Content -LiteralPath $vbs -Encoding ASCII

$tr = 'wscript.exe "{0}"' -f $vbs
schtasks /Create /TN $taskName /TR $tr /SC MINUTE /MO 2 /F | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Host "Registered autosave task: '$taskName' (every 2 min, hidden)"
    schtasks /Run /TN $taskName | Out-Null   # take an immediate baseline snapshot
} else {
    Write-Warning "Could not register the autosave task (schtasks exit $LASTEXITCODE). Run the installer from a normal (non-sandboxed) PowerShell."
}

Write-Host ''
Write-Host 'Install complete. Open NEW terminal tabs to begin tracking. Two Desktop shortcuts:'
Write-Host '  - "Save Workspace"    : checkpoint your current tabs now (so Restore brings back this set).'
Write-Host '  - "Restore Workspace" : reopen the last saved set. After a reboot it uses the autosave.'
Write-Host 'Your tabs are also auto-saved every 2 minutes, so a reboot is covered even without Save.'
