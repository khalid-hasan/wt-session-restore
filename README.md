# wt-session-restore

Restore your Windows Terminal **PowerShell tabs** — each in its working folder and re-running
its last command — after a reboot. Built for people who keep 5–10 terminals open across
different projects (e.g. `claude` / `codex` sessions) and lose them all on every restart.

It captures state automatically as you work (zero maintenance) and restores it with one
double-click. It's designed around **forced/auto shutdowns** — the common case where you don't
close anything and let the OS shut everything down.

> 📖 New here? Read the **[plain-English guide](docs/GUIDE.md)** — how it works, how to use it,
> and how to test it in two minutes.

## How it works

1. A **tracker** is loaded by your PowerShell profile. On every Enter keypress it records the
   tab's folder + the command you just launched into a small per-session JSON file (written
   atomically). Recording happens at **Enter-time** (before the command runs), so a long-running
   process like `claude` is captured the instant you launch it — not after it exits.
2. A **background task** snapshots your currently-open tabs every ~2 minutes into `layout.json`.
   It runs hidden (via a small VBScript wrapper) so nothing flashes on screen.
3. The first snapshot after a **reboot** notices the boot changed and copies the previous
   session's snapshot to `restore.json` — *before* the new session starts overwriting
   `layout.json`. That's what makes the restore point survive intact.
4. You double-click **Restore Workspace**. It reads the last pre-reboot snapshot and opens one
   Windows Terminal window with one tab per entry — each `cd`'d into its folder and re-running
   its last command.

Because restore reads an autosaved snapshot (not whatever files happen to survive a shutdown),
it doesn't depend on how Windows terminates your shells, and tabs you closed on purpose drop out
of the next snapshot so they don't come back.

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
- registers a per-user **autosave** scheduled task (every 2 min, hidden — no admin needed),
- creates **Save Workspace** and **Restore Workspace** shortcuts on your Desktop.

Open new terminal tabs to begin tracking. If new shells don't track, ensure your execution
policy allows profile scripts: `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`.

## Usage

Two Desktop shortcuts:

- **Save Workspace** — checkpoint *all* your currently-open tabs right now, so **Restore Workspace**
  brings back this exact set. Use it mid-session. It saves every open tab — there's no per-tab
  selection.
- **Restore Workspace** — reopen the last saved set (your manual save, or the automatic one).
  It only opens tabs that **aren't already open**, so if you accidentally close a few and hit
  Restore, it reopens just those — no duplicates of the tabs you still have.

You don't have to remember to Save: your open tabs are also **auto-saved every ~2 minutes**, so
after a reboot just double-click **Restore Workspace**.

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
- Delete the scheduled task: `schtasks /Delete /TN "wt-session-restore autosave" /F`.
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
