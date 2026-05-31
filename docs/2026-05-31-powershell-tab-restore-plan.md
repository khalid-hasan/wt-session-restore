# PowerShell Tab Restore Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One-click restore of Windows Terminal PowerShell tabs (folder + last command) after a forced reboot, with zero ongoing maintenance.

**Architecture:** A profile-loaded *tracker* records each tab's folder + the command launched at Enter-time into an atomically-written per-session JSON file; files survive forced shutdowns. A Desktop-shortcut *launcher* reads the leftover files after reboot and rebuilds the tabs via `wt.exe`. An *installer* wires the tracker into both PowerShell profiles and creates the shortcut. All decision logic lives in pure, Pester-tested functions in a module; the interactive/IO scripts are thin wrappers.

**Tech Stack:** PowerShell 7 (`pwsh`) + Windows PowerShell 5.1, PSReadLine 2.3.6, Windows Terminal `wt.exe`, Pester 5 (tests).

> **Commit policy:** This user's global rule is "commit only when asked." Per-task commit steps are written below for completeness; when executing for this user, treat each commit as ask-first rather than automatic. `git init` in Task 1 is likewise optional.

---

## File Structure

```
wt-session-restore\
  src\
    WTSessionRestore.psm1        # pure logic + IO helpers (all unit-tested)
    tracker.ps1                 # dot-sourced by profile; interactive wrappers
    Restore-Workspace.ps1       # launcher run by the Desktop shortcut
    Install-WTSessionRestore.ps1 # one-time installer
  tests\
    WTSessionRestore.Tests.ps1   # Pester 5 tests for the module
  docs\
    2026-05-31-powershell-tab-restore-design.md
    2026-05-31-powershell-tab-restore-plan.md
```

**Runtime state** (created by installer, not in repo): `%USERPROFILE%\.wt-session-restore\` containing `sessions\`, `archive\`, `denylist.txt`, and copies of the three runtime scripts/module.

**Module responsibilities** (`WTSessionRestore.psm1`):
- `Get-CommandFirstToken` — normalize a command to its leading token (lowercased, path/ext stripped).
- `Resolve-RestoreAction` — decide replay-vs-folder-only for a command given the deny-list.
- `Select-RestorableSessions` — pick "open at shutdown" sessions (dead PID + pre-boot timestamp).
- `Build-WtArgumentList` — turn restorable sessions into the exact `wt.exe` argument array.
- `Read-AllSessions` — load all session JSON files, skip malformed, attach `SourceFile`.
- `Write-SessionStateAtomic` — write a session file via temp-then-rename.

All commands run from the project root `C:\Users\Khalid Hasan\wt-session-restore` unless stated otherwise.

---

## Task 1: Project scaffold, Pester 5, empty module

**Files:**
- Create: `src/WTSessionRestore.psm1`
- Create: `tests/WTSessionRestore.Tests.ps1`

- [ ] **Step 1: Create folders and (optionally) init git**

```powershell
New-Item -ItemType Directory -Path src,tests -Force | Out-Null
# Optional, ask-first for this user:
# git init; "src/`ntests/`n!docs/" | Out-Null
```

- [ ] **Step 2: Install Pester 5 (CurrentUser scope)**

Run:
```powershell
Install-Module Pester -Scope CurrentUser -MinimumVersion 5.5.0 -Force -SkipPublisherCheck
```
Expected: completes with no error. Verify:
```powershell
pwsh -NoProfile -Command "(Get-Module -ListAvailable Pester | Sort-Object Version -Desc | Select -First 1).Version"
```
Expected: `5.x.x`.

- [ ] **Step 3: Create the empty module with exports**

`src/WTSessionRestore.psm1`:
```powershell
# WTSessionRestore — pure logic + IO helpers for capturing/restoring terminal tabs.

Export-ModuleMember -Function @()
```

- [ ] **Step 4: Create the test file skeleton**

`tests/WTSessionRestore.Tests.ps1`:
```powershell
BeforeAll {
    Import-Module "$PSScriptRoot\..\src\WTSessionRestore.psm1" -Force
}
```

- [ ] **Step 5: Run the (empty) suite to confirm tooling works**

Run:
```powershell
pwsh -NoProfile -Command "Import-Module Pester -MinimumVersion 5.0; Invoke-Pester -Path tests\WTSessionRestore.Tests.ps1 -Output Detailed"
```
Expected: `Tests Passed: 0, Failed: 0` (no errors loading the module).

- [ ] **Step 6: Commit** (ask-first for this user)

```powershell
git add src tests docs
git commit -m "chore: scaffold wt-session-restore module and tests"
```

---

## Task 2: `Get-CommandFirstToken`

**Files:**
- Modify: `src/WTSessionRestore.psm1`
- Test: `tests/WTSessionRestore.Tests.ps1`

- [ ] **Step 1: Write the failing tests**

Append to `tests/WTSessionRestore.Tests.ps1`:
```powershell
Describe 'Get-CommandFirstToken' {
    It 'returns the command itself when simple' {
        Get-CommandFirstToken 'claude' | Should -Be 'claude'
    }
    It 'returns first token and trims whitespace' {
        Get-CommandFirstToken '  npm run dev ' | Should -Be 'npm'
    }
    It 'strips directory and extension for an unquoted path' {
        Get-CommandFirstToken 'C:\tools\mytool.exe --flag' | Should -Be 'mytool'
    }
    It 'handles a quoted path containing spaces' {
        Get-CommandFirstToken '"C:\Program Files\nodejs\node.exe" app.js' | Should -Be 'node'
    }
    It 'returns empty string for blank input' {
        Get-CommandFirstToken '   ' | Should -Be ''
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run:
```powershell
pwsh -NoProfile -Command "Import-Module Pester -MinimumVersion 5.0; Invoke-Pester -Path tests\WTSessionRestore.Tests.ps1 -Output Detailed"
```
Expected: FAIL — `The term 'Get-CommandFirstToken' is not recognized`.

- [ ] **Step 3: Implement**

In `src/WTSessionRestore.psm1`, add above the `Export-ModuleMember` line:
```powershell
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
```
Update the export line to:
```powershell
Export-ModuleMember -Function Get-CommandFirstToken
```

- [ ] **Step 4: Run to verify pass**

Run:
```powershell
pwsh -NoProfile -Command "Import-Module Pester -MinimumVersion 5.0; Invoke-Pester -Path tests\WTSessionRestore.Tests.ps1 -Output Detailed"
```
Expected: 5 passed.

- [ ] **Step 5: Commit** (ask-first)

```powershell
git add src tests
git commit -m "feat: add Get-CommandFirstToken"
```

---

## Task 3: `Resolve-RestoreAction`

**Files:**
- Modify: `src/WTSessionRestore.psm1`
- Test: `tests/WTSessionRestore.Tests.ps1`

- [ ] **Step 1: Write the failing tests**

Append to `tests/WTSessionRestore.Tests.ps1`:
```powershell
Describe 'Resolve-RestoreAction' {
    BeforeAll { $deny = @('ls','dir','cd','pwd') }

    It 'replays a real command as-is' {
        $r = Resolve-RestoreAction -Command 'claude' -DenyList $deny
        $r.Replay | Should -BeTrue
        $r.Command | Should -Be 'claude'
    }
    It 'opens folder only for a denied command' {
        (Resolve-RestoreAction -Command 'ls -la' -DenyList $deny).Replay | Should -BeFalse
    }
    It 'opens folder only for trivial git subcommands' {
        (Resolve-RestoreAction -Command 'git status' -DenyList $deny).Replay | Should -BeFalse
    }
    It 'replays non-trivial git commands' {
        $r = Resolve-RestoreAction -Command 'git push origin main' -DenyList $deny
        $r.Replay | Should -BeTrue
        $r.Command | Should -Be 'git push origin main'
    }
    It 'opens folder only for empty command' {
        (Resolve-RestoreAction -Command '' -DenyList $deny).Replay | Should -BeFalse
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run:
```powershell
pwsh -NoProfile -Command "Import-Module Pester -MinimumVersion 5.0; Invoke-Pester -Path tests\WTSessionRestore.Tests.ps1 -Output Detailed"
```
Expected: FAIL — `'Resolve-RestoreAction' is not recognized`.

- [ ] **Step 3: Implement**

In `src/WTSessionRestore.psm1`, add above the export line:
```powershell
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
        $trivialGit = @('status','log','diff','branch','show','stash')
        if ($trivialGit -contains $sub) { return $folderOnly }
    }

    return $replay
}
```
Update the export line to:
```powershell
Export-ModuleMember -Function Get-CommandFirstToken, Resolve-RestoreAction
```

- [ ] **Step 4: Run to verify pass**

Run:
```powershell
pwsh -NoProfile -Command "Import-Module Pester -MinimumVersion 5.0; Invoke-Pester -Path tests\WTSessionRestore.Tests.ps1 -Output Detailed"
```
Expected: 10 passed.

- [ ] **Step 5: Commit** (ask-first)

```powershell
git add src tests
git commit -m "feat: add Resolve-RestoreAction with deny-list and git special-case"
```

---

## Task 4: `Select-RestorableSessions`

**Files:**
- Modify: `src/WTSessionRestore.psm1`
- Test: `tests/WTSessionRestore.Tests.ps1`

- [ ] **Step 1: Write the failing tests**

Append to `tests/WTSessionRestore.Tests.ps1`:
```powershell
Describe 'Select-RestorableSessions' {
    BeforeAll {
        $boot  = [datetime]::Parse('2026-05-31T12:00:00Z', $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
        $alive = { param($processId) $processId -eq 999 }
        $sessions = @(
            [pscustomobject]@{ pid = 100; updatedAt = '2026-05-31T10:00:00Z' }  # dead, pre-boot  -> keep
            [pscustomobject]@{ pid = 101; updatedAt = '2026-05-31T13:00:00Z' }  # dead, post-boot -> drop
            [pscustomobject]@{ pid = 999; updatedAt = '2026-05-31T09:00:00Z' }  # alive           -> drop
        )
    }
    It 'keeps only dead, pre-boot sessions' {
        $r = Select-RestorableSessions -Sessions $sessions -BootTime $boot -IsPidAlive $alive
        $r.Count | Should -Be 1
        $r[0].pid | Should -Be 100
    }
    It 'returns empty for empty input' {
        (Select-RestorableSessions -Sessions @() -BootTime $boot -IsPidAlive $alive).Count | Should -Be 0
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run:
```powershell
pwsh -NoProfile -Command "Import-Module Pester -MinimumVersion 5.0; Invoke-Pester -Path tests\WTSessionRestore.Tests.ps1 -Output Detailed"
```
Expected: FAIL — `'Select-RestorableSessions' is not recognized`.

- [ ] **Step 3: Implement**

In `src/WTSessionRestore.psm1`, add above the export line:
```powershell
function Select-RestorableSessions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Sessions,
        [Parameter(Mandatory)][datetime]$BootTime,
        [Parameter(Mandatory)][scriptblock]$IsPidAlive
    )

    $bootUtc = $BootTime.ToUniversalTime()
    $result = foreach ($s in $Sessions) {
        if ([bool](& $IsPidAlive $s.pid)) { continue }
        $updated = [datetime]::Parse($s.updatedAt, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
        if ($updated.ToUniversalTime() -lt $bootUtc) { $s }
    }
    @($result)
}
```
Update the export line to:
```powershell
Export-ModuleMember -Function Get-CommandFirstToken, Resolve-RestoreAction, Select-RestorableSessions
```

- [ ] **Step 4: Run to verify pass**

Run:
```powershell
pwsh -NoProfile -Command "Import-Module Pester -MinimumVersion 5.0; Invoke-Pester -Path tests\WTSessionRestore.Tests.ps1 -Output Detailed"
```
Expected: 12 passed.

- [ ] **Step 5: Commit** (ask-first)

```powershell
git add src tests
git commit -m "feat: add Select-RestorableSessions boot-time selection"
```

---

## Task 5: `Build-WtArgumentList`

**Files:**
- Modify: `src/WTSessionRestore.psm1`
- Test: `tests/WTSessionRestore.Tests.ps1`

- [ ] **Step 1: Write the failing test**

Append to `tests/WTSessionRestore.Tests.ps1`:
```powershell
Describe 'Build-WtArgumentList' {
    BeforeAll {
        $sessions = @(
            [pscustomobject]@{ cwd = 'C:\dev\proj1'; command = 'claude'; shell = 'pwsh.exe' }
            [pscustomobject]@{ cwd = 'C:\dev\proj2'; command = 'ls';     shell = 'powershell.exe' }
        )
        $deny = @('ls')
    }
    It 'builds the expected wt argument array' {
        $r = Build-WtArgumentList -Sessions $sessions -DenyList $deny
        ($r -join '|') | Should -Be 'new-tab|--title|proj1|-d|C:\dev\proj1|pwsh.exe|-NoExit|-Command|claude|;|new-tab|--title|proj2|-d|C:\dev\proj2|powershell.exe|-NoExit'
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run:
```powershell
pwsh -NoProfile -Command "Import-Module Pester -MinimumVersion 5.0; Invoke-Pester -Path tests\WTSessionRestore.Tests.ps1 -Output Detailed"
```
Expected: FAIL — `'Build-WtArgumentList' is not recognized`.

- [ ] **Step 3: Implement**

In `src/WTSessionRestore.psm1`, add above the export line:
```powershell
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
```
Update the export line to:
```powershell
Export-ModuleMember -Function Get-CommandFirstToken, Resolve-RestoreAction, Select-RestorableSessions, Build-WtArgumentList
```

- [ ] **Step 4: Run to verify pass**

Run:
```powershell
pwsh -NoProfile -Command "Import-Module Pester -MinimumVersion 5.0; Invoke-Pester -Path tests\WTSessionRestore.Tests.ps1 -Output Detailed"
```
Expected: 13 passed.

- [ ] **Step 5: Commit** (ask-first)

```powershell
git add src tests
git commit -m "feat: add Build-WtArgumentList"
```

---

## Task 6: `Read-AllSessions` and `Write-SessionStateAtomic`

**Files:**
- Modify: `src/WTSessionRestore.psm1`
- Test: `tests/WTSessionRestore.Tests.ps1`

- [ ] **Step 1: Write the failing tests**

Append to `tests/WTSessionRestore.Tests.ps1`:
```powershell
Describe 'Read-AllSessions' {
    BeforeAll {
        $dir = Join-Path $TestDrive 'sessions'
        New-Item -ItemType Directory -Path $dir | Out-Null
        '{"id":"a","pid":1}' | Set-Content (Join-Path $dir 'a.json')
        '{"id":"b","pid":2}' | Set-Content (Join-Path $dir 'b.json')
        'not json {'         | Set-Content (Join-Path $dir 'bad.json')
    }
    It 'returns valid sessions and skips malformed' {
        (Read-AllSessions $dir).Count | Should -Be 2
    }
    It 'attaches a SourceFile property' {
        (Read-AllSessions $dir)[0].SourceFile | Should -Not -BeNullOrEmpty
    }
    It 'returns empty for a missing directory' {
        (Read-AllSessions (Join-Path $TestDrive 'nope')).Count | Should -Be 0
    }
}

Describe 'Write-SessionStateAtomic' {
    It 'writes json and leaves no temp file behind' {
        $path = Join-Path $TestDrive 'out.json'
        Write-SessionStateAtomic -Path $path -State ([pscustomobject]@{ id = 'x'; cwd = 'C:\a' })
        (Test-Path "$path.tmp") | Should -BeFalse
        (Get-Content $path -Raw | ConvertFrom-Json).cwd | Should -Be 'C:\a'
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run:
```powershell
pwsh -NoProfile -Command "Import-Module Pester -MinimumVersion 5.0; Invoke-Pester -Path tests\WTSessionRestore.Tests.ps1 -Output Detailed"
```
Expected: FAIL — `'Read-AllSessions' is not recognized` (and the Write describe fails too).

- [ ] **Step 3: Implement**

In `src/WTSessionRestore.psm1`, add above the export line:
```powershell
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
```
Update the export line to:
```powershell
Export-ModuleMember -Function Get-CommandFirstToken, Resolve-RestoreAction, Select-RestorableSessions, Build-WtArgumentList, Read-AllSessions, Write-SessionStateAtomic
```

- [ ] **Step 4: Run to verify pass**

Run:
```powershell
pwsh -NoProfile -Command "Import-Module Pester -MinimumVersion 5.0; Invoke-Pester -Path tests\WTSessionRestore.Tests.ps1 -Output Detailed"
```
Expected: 17 passed. (A yellow WARNING about the malformed file is expected and fine.)

- [ ] **Step 5: Commit** (ask-first)

```powershell
git add src tests
git commit -m "feat: add Read-AllSessions and Write-SessionStateAtomic"
```

---

## Task 7: `tracker.ps1` (interactive capture)

No unit tests (interactive PSReadLine wrapper); verified manually. Keep it a thin shell over the tested module.

**Files:**
- Create: `src/tracker.ps1`

- [ ] **Step 1: Write the tracker**

`src/tracker.ps1`:
```powershell
# tracker.ps1 — dot-sourced from the PowerShell profile by wt-session-restore.
# Records this tab's folder + last-launched command so it can be restored after a reboot.

Import-Module (Join-Path $PSScriptRoot 'WTSessionRestore.psm1') -Force -ErrorAction SilentlyContinue

$script:TRStateDir    = Join-Path $env:USERPROFILE '.wt-session-restore'
$script:TRSessionsDir = Join-Path $script:TRStateDir 'sessions'
$script:TRSessionId   = [guid]::NewGuid().ToString('N')
$script:TRSessionFile = Join-Path $script:TRSessionsDir ("{0}.json" -f $script:TRSessionId)
$script:TRShellPath   = (Get-Process -Id $PID).Path

if (-not (Test-Path -LiteralPath $script:TRSessionsDir)) {
    New-Item -ItemType Directory -Path $script:TRSessionsDir -Force | Out-Null
}

# Reap crash leftovers from THIS boot only (dead pid + touched after boot).
# Pre-boot dead files are the restore set and are left for Restore-Workspace.ps1.
try {
    $bootUtc = ((Get-CimInstance Win32_OperatingSystem).LastBootUpTime).ToUniversalTime()
    foreach ($s in (Read-AllSessions $script:TRSessionsDir)) {
        if ($null -ne (Get-Process -Id $s.pid -ErrorAction SilentlyContinue)) { continue }
        $updated = [datetime]::Parse($s.updatedAt, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
        if ($updated.ToUniversalTime() -ge $bootUtc) {
            Remove-Item -LiteralPath $s.SourceFile -Force -ErrorAction SilentlyContinue
        }
    }
} catch { }

function Save-TRState {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Command)
    try {
        $state = [pscustomobject]@{
            id        = $script:TRSessionId
            pid       = $PID
            shell     = $script:TRShellPath
            cwd       = (Get-Location).Path
            command   = $Command
            updatedAt = [datetime]::UtcNow.ToString('o')
        }
        Write-SessionStateAtomic -Path $script:TRSessionFile -State $state
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
        if (-not [string]::IsNullOrWhiteSpace($line)) { Save-TRState -Command $line.Trim() }
        [Microsoft.PowerShell.PSConsoleReadLine]::ValidateAndAcceptLine()
    }
}

# Seed a folder-only record so a tab that never runs a command still restores its folder.
Save-TRState -Command ''

# Delete our own file on graceful exit (rare here; forced shutdowns intentionally skip this).
Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
    Remove-Item -LiteralPath $script:TRSessionFile -Force -ErrorAction SilentlyContinue
} | Out-Null
```

- [ ] **Step 2: Manual smoke test (capture)**

Run, simulating an installed layout, in a real interactive terminal:
```powershell
# From project root, set up a throwaway state dir copy:
$state = Join-Path $env:USERPROFILE '.wt-session-restore'
New-Item -ItemType Directory -Path $state -Force | Out-Null
Copy-Item src\WTSessionRestore.psm1, src\tracker.ps1 $state -Force
. (Join-Path $state 'tracker.ps1')
Set-Location C:\Windows
claude --version   # or any command; just type something and press Enter
Get-ChildItem (Join-Path $state 'sessions') | ForEach-Object { Get-Content $_.FullName }
```
Expected: a JSON file whose `cwd` is `C:\Windows` and whose `command` is the last line you typed (e.g. `claude --version`). Confirm pressing Enter on a normal command still works (the prompt is not broken) and that a multi-line paste still accepts correctly.

- [ ] **Step 3: Commit** (ask-first)

```powershell
git add src/tracker.ps1
git commit -m "feat: add interactive tracker (Enter-time command capture)"
```

---

## Task 8: `Restore-Workspace.ps1` (launcher)

No unit tests (process/IO orchestration over tested functions); verified manually.

**Files:**
- Create: `src/Restore-Workspace.ps1`

- [ ] **Step 1: Write the launcher**

`src/Restore-Workspace.ps1`:
```powershell
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

$bootTime   = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
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

$wtArgs = Build-WtArgumentList -Sessions $restorable -DenyList $denyList
Start-Process -FilePath $wt -ArgumentList $wtArgs

if (-not (Test-Path -LiteralPath $archiveDir)) { New-Item -ItemType Directory -Path $archiveDir -Force | Out-Null }
foreach ($s in $restorable) {
    if ($s.SourceFile -and (Test-Path -LiteralPath $s.SourceFile)) {
        Move-Item -LiteralPath $s.SourceFile -Destination $archiveDir -Force
    }
}
Write-Host ("wt-session-restore: opened {0} tab(s)." -f $restorable.Count)
```

- [ ] **Step 2: Manual smoke test (restore)**

Craft two fake "open at shutdown" sessions (dead PIDs + pre-boot timestamp) and run the launcher:
```powershell
$state = Join-Path $env:USERPROFILE '.wt-session-restore'
$sessions = Join-Path $state 'sessions'
Copy-Item src\WTSessionRestore.psm1, src\Restore-Workspace.ps1 $state -Force
New-Item -ItemType Directory -Path $sessions -Force | Out-Null
Get-ChildItem $sessions -Filter *.json | Remove-Item -Force   # clean slate
$preBoot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.AddMinutes(-5).ToUniversalTime().ToString('o')
[pscustomobject]@{ id='t1'; pid=999999; shell='pwsh.exe';        cwd='C:\Windows';        command='Get-ChildItem'; updatedAt=$preBoot } | ConvertTo-Json | Set-Content (Join-Path $sessions 't1.json')
[pscustomobject]@{ id='t2'; pid=999998; shell='powershell.exe';  cwd='C:\Windows\System32'; command='ls';          updatedAt=$preBoot } | ConvertTo-Json | Set-Content (Join-Path $sessions 't2.json')
# Ensure denylist exists with 'ls' (installer normally creates it):
'ls' | Set-Content (Join-Path $state 'denylist.txt')
& (Join-Path $state 'Restore-Workspace.ps1')
```
Expected: a new Windows Terminal window opens with **two tabs** — tab 1 titled `Windows` running `Get-ChildItem`, tab 2 titled `System32` opened at that folder with **no** command (because `ls` is denied). The two `*.json` files have moved into `.wt-session-restore\archive`. Console prints `opened 2 tab(s).`

If the second tab tries to run `ls` anyway, re-check the deny-list file path; if the `;` separator is mis-handled by `wt`, confirm `Build-WtArgumentList` emitted `;` as its own array element (`($wtArgs -join '|')`).

- [ ] **Step 3: Commit** (ask-first)

```powershell
git add src/Restore-Workspace.ps1
git commit -m "feat: add Restore-Workspace launcher"
```

---

## Task 9: `Install-WTSessionRestore.ps1` + end-to-end verification

No unit tests (system installer); verified by running it and doing a full cycle.

**Files:**
- Create: `src/Install-WTSessionRestore.ps1`

- [ ] **Step 1: Write the installer**

`src/Install-WTSessionRestore.ps1`:
```powershell
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
```

- [ ] **Step 2: Run the installer**

Run (interactive terminal):
```powershell
pwsh -ExecutionPolicy Bypass -File src\Install-WTSessionRestore.ps1
```
Expected output: "Wired tracker into:" for both profile paths (or "Already wired"), "Created shortcut:", and the completion message. Verify:
```powershell
Test-Path "$env:USERPROFILE\.wt-session-restore\tracker.ps1"
Test-Path ([IO.Path]::Combine([Environment]::GetFolderPath('Desktop'),'Restore Workspace.lnk'))
```
Expected: both `True`.

- [ ] **Step 3: Verify execution policy allows the profile to load**

Run:
```powershell
Get-ExecutionPolicy -Scope CurrentUser
```
If it returns `Restricted` or `Undefined`, set:
```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```
Expected: profile scripts (and thus the tracker) will load in new sessions.

- [ ] **Step 4: End-to-end manual test (no reboot needed)**

1. Open **two new** Windows Terminal tabs (so the tracker loads via profile).
2. In tab A: `cd C:\Windows; claude --version` (or any non-trivial command).
3. In tab B: `cd C:\Windows\System32; ls`.
4. Confirm capture:
   ```powershell
   Get-ChildItem "$env:USERPROFILE\.wt-session-restore\sessions" | ForEach-Object { Get-Content $_.FullName }
   ```
   Expected: two records with the right `cwd` and `command`, both with `pid` of live shells.
5. Simulate "open at shutdown" by back-dating both records before boot time (their PIDs are still alive, so the launcher would normally skip them — for the test, also fake the PID to a dead one):
   ```powershell
   $sessions = "$env:USERPROFILE\.wt-session-restore\sessions"
   $preBoot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.AddMinutes(-5).ToUniversalTime().ToString('o')
   Get-ChildItem $sessions -Filter *.json | ForEach-Object {
       $o = Get-Content $_.FullName -Raw | ConvertFrom-Json
       $o.pid = 999990; $o.updatedAt = $preBoot
       $o | ConvertTo-Json | Set-Content $_.FullName
   }
   ```
6. Double-click the **Restore Workspace** shortcut on the Desktop.
   Expected: a new Terminal window with two tabs — one replaying `claude --version`, one opened at `System32` with no command. Session files moved to `archive\`.

- [ ] **Step 5: Real reboot test**

Open a few project tabs, run `claude` in them, then **restart the PC normally** (forced/auto shutdown — your usual habit). After login, double-click **Restore Workspace** before opening any terminal manually. Expected: your tabs return in their folders with `claude` running again.

- [ ] **Step 6: Commit** (ask-first)

```powershell
git add src/Install-WTSessionRestore.ps1
git commit -m "feat: add installer and Desktop shortcut"
```

---

## Final verification checklist

- [ ] `pwsh -NoProfile -Command "Import-Module Pester -MinimumVersion 5.0; Invoke-Pester -Path tests\WTSessionRestore.Tests.ps1 -Output Detailed"` → all green (17 tests).
- [ ] Capture works: running a command writes/updates exactly one session JSON for that tab with correct `cwd`/`command`.
- [ ] Trivial commands (`ls`, `git status`) restore folder-only; real commands replay.
- [ ] Launcher opens one window with all restorable tabs and archives consumed files.
- [ ] Re-running the launcher with an empty `sessions\` prints "nothing to restore" and does not error.
- [ ] Installer is idempotent (second run prints "Already wired").
