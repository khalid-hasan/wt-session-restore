# wt-session-restore

Restore your Windows Terminal **PowerShell tabs** — each in its working folder and re-running
its last command — after a reboot. Built for people who keep 5–10 terminals open across
different projects (e.g. `claude` / `codex` sessions) and lose them all on every restart.

It captures state automatically as you work (zero maintenance) and restores it with one
double-click. It's designed around **forced/auto shutdowns** — the common case where you don't
close anything and let the OS shut everything down.

## How it works

1. A **tracker** is loaded by your PowerShell profile. On every Enter keypress it records the
   tab's folder + the command you just launched into a small per-session JSON file (written
   atomically, so a forced shutdown can't corrupt it).
2. On a clean tab-close the tracker deletes its own file. A forced shutdown skips that, so the
   leftover files are exactly the tabs that were open when the machine went down.
3. After reboot you double-click **Restore Workspace**. It reads the leftover files and opens
   one Windows Terminal window with one tab per session — each `cd`'d into its folder and
   re-running its last command.

Recording happens at **Enter-time** (before the command runs), so a long-running process like
`claude` is captured the instant you launch it — not after it exits.

## Requirements

- Windows 10/11 with [Windows Terminal](https://aka.ms/terminal) (`wt.exe` on PATH)
- PowerShell 7 (`pwsh`) and/or Windows PowerShell 5.1
- PSReadLine 2.x (ships with both)

## Install

```powershell
git clone https://github.com/khalid-hasan/wt-session-restore.git
cd wt-session-restore
pwsh -ExecutionPolicy Bypass -File .\src\Install-WTSessionRestore.ps1
```

The installer:
- copies the runtime files to `%USERPROFILE%\.wt-session-restore\`,
- wires the tracker into both PowerShell profiles (idempotent),
- creates a **Restore Workspace** shortcut on your Desktop.

Open new terminal tabs to begin tracking. If new shells don't track, ensure your execution
policy allows profile scripts: `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`.

## Usage

Just work normally. After a reboot, double-click **Restore Workspace** *before* opening
terminals manually.

### Commands that are / aren't replayed

Trivial navigation/inspection commands aren't replayed (the tab just opens in its folder).
The list lives in `%USERPROFILE%\.wt-session-restore\denylist.txt` (one command token per
line) and is editable. `git status`/`log`/`diff`/`branch`/`show`/`stash` are treated as
trivial; other `git` commands replay.

## Scope & limitations

- Covers **PowerShell tabs in Windows Terminal** only — not cmd, WSL, or git-bash.
- Restores the **command**, not a program's internal state. Re-running `claude` starts a fresh
  session; type `claude --continue` if you want it to resume (the tool restores exactly what
  you last ran).
- Restores **tabs**, not split panes within a tab.
- All restored tabs open in one window.

## Uninstall

- Remove the `# >>> wt-session-restore >>>` … `# <<< wt-session-restore <<<` block from your
  PowerShell profile(s) (`$PROFILE`).
- Delete `%USERPROFILE%\.wt-session-restore\` and the Desktop shortcut.

## Development

```powershell
Install-Module Pester -Scope CurrentUser -MinimumVersion 5.5.0 -Force -SkipPublisherCheck
Invoke-Pester -Path .\tests\WTSessionRestore.Tests.ps1 -Output Detailed
```

All decision logic lives in pure, tested functions in `src/WTSessionRestore.psm1`; the
interactive tracker, launcher, and installer are thin wrappers. See `docs/` for the design and
implementation plan.

## License

MIT — see [LICENSE](LICENSE).
