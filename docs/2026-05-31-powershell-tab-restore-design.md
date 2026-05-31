# PowerShell Tab Restore — Design

**Date:** 2026-05-31
**Status:** Approved for planning

## Problem

After a PC restart, the user must manually reopen 5–10 Windows Terminal tabs, `cd`
into each project folder, and re-run the startup command (typically `claude` or
`codex`) before resuming work. This is repetitive and time-consuming. The user wants
a one-click restore of those tabs — each in its folder and re-running its last
command — with **zero ongoing maintenance**.

## Goals

- Restore each tab's **working directory** and **re-run its last command** after a reboot.
- **Zero daily effort**: state is captured automatically as the user works; no manifest to hand-edit.
- **Manual trigger**: a Desktop shortcut the user double-clicks when ready to start.
- Works on Windows 11 with Windows Terminal 1.24 and PowerShell (both 7 / `pwsh` and Windows PowerShell 5.1).

## Non-Goals

- Restoring non-PowerShell tabs (cmd, WSL, git-bash).
- Restoring split panes within a tab (tabs only).
- Restoring a program's internal state (e.g. an in-progress `claude` conversation).
  Restore re-runs the **command**, not the process memory.
- Auto-launch on login (explicitly chosen manual trigger; can be added later by
  dropping the shortcut in the Startup folder).

## Decisions (from brainstorming)

| Question | Decision |
|---|---|
| Restore scope | Folder **and** re-run the command |
| Which command | Whatever the **last command launched** in that tab was |
| Trigger | Manual — Desktop shortcut |
| Maintenance | Auto-capture, no hand-edited manifest |
| `claude`/`codex` resume | Re-run **as-is** (no auto `--continue` rewrite) |
| Trivial commands (`ls`, `git status`, …) | **Open folder only**, don't replay |
| Trivial-command detection | **Deny-list** of navigation/inspection commands; replay everything else |

## Architecture

Three components:

### 1. Tracker (`tracker.ps1`)
Dot-sourced from the user's PowerShell profile(s). Responsibilities:

- **On session start:** generate a session id (GUID), record the shell exe path
  (`pwsh.exe` vs `powershell.exe`) and PID. Reap stale crash files (see below).
- **On every Enter keypress:** via a PSReadLine `Enter` key handler, capture the
  command line being submitted **and** the current `$PWD`, then write/update the
  session's JSON file *before* the command executes. This is what lets a
  long-running `claude` be captured — the record is written the instant `claude`
  is launched, not after it exits.
- **On clean exit:** an `PowerShell.Exiting` engine event handler deletes the
  session's own file. Hard shutdowns/reboots skip this, so the file survives —
  which is exactly the signal that the tab was open at shutdown.

> **Note on usage pattern:** The user almost never closes terminals manually;
> shutdowns/restarts are forced and the OS auto-closes everything. This is the
> **expected, normal path** for this tool — forced shutdown skips the clean-exit
> handler, so session files survive and become the restore set. The clean-exit
> deletion only matters on the rare occasions a tab is closed by hand.

- **Atomic writes:** because a forced shutdown could land mid-write, every session
  file update is written to a temp file and then atomically renamed over the target,
  so a session file is never left half-written / corrupted.

### 2. Restore launcher (`Restore-Workspace.ps1`)
Run by the Desktop shortcut. Responsibilities:

- Read all session files that represent "open at shutdown" (see selection logic).
- For each: decide whether to replay the command (deny-list check) or open the
  folder at a clean prompt.
- Build a single `wt.exe` command with one `new-tab` per session, using the
  recorded shell exe, `-d <cwd>`, and `pwsh/powershell -NoExit -Command "<cmd>"`
  when replaying.
- Launch it, then **archive** the consumed session files so they aren't restored
  again on the next run.

### 3. Installer (`Install-TerminalRestore.ps1`)
Run once. Responsibilities:

- Create the state directory and the deny-list config (with sensible defaults).
- Idempotently append a single dot-source line to **both** `$PROFILE` files
  (PowerShell 7 and Windows PowerShell 5.1), guarded by a marker comment so
  re-running doesn't duplicate it.
- Create the "Restore Workspace" shortcut on the Desktop.
- Print next steps.

## Data model

State directory: `%USERPROFILE%\.wt-session-restore\`

```
.wt-session-restore\
  sessions\           # one file per live shell session
    <guid>.json
  archive\            # consumed-by-restore files (kept for one cycle / debugging)
  denylist.txt        # editable; one trivial command (first token) per line
  tracker.ps1
  Restore-Workspace.ps1
```

Session file shape (`sessions\<guid>.json`):

```json
{
  "id": "f3c1...",
  "pid": 12345,
  "shell": "C:\\Program Files\\PowerShell\\7\\pwsh.exe",
  "cwd": "C:\\dev\\proj1",
  "command": "claude",
  "updatedAt": 1780239305473
}
```

> **`updatedAt` is epoch milliseconds (UTC integer), not an ISO string.** `ConvertFrom-Json`
> auto-converts ISO-8601 date strings to `DateTime` and drops the UTC marker, corrupting
> timezone-sensitive comparisons (discovered as a 2.5h skew in UTC−2:30). An integer survives
> the JSON round-trip unambiguously and is compared with plain integer math.

## Selection logic (which files to restore)

Goal: restore tabs open at shutdown; ignore tabs that crashed mid-session today and
ignore tabs that are currently live.

Using `bootTime = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime`:

- **Restore launcher restores** files where the PID is **not alive** AND
  `updatedAt < bootTime`. (Dead + last touched before this boot = it was open in
  the previous session and never cleaned up → restore it.)
- **Tracker reaps on startup** files where the PID is **not alive** AND
  `updatedAt >= bootTime`. (Dead + touched this session = crashed this session →
  not restore-worthy, clean it up.)
- Files whose PID **is** alive are left untouched (currently open).

This boot-time guard lets the user open a terminal manually before clicking Restore
without losing the snapshot, while still preventing unbounded file growth.

## Command replay rules

For each restored session, take the first token of `command` (lowercased,
path-stripped, e.g. `git status` → `git`):

- If the first token is in the deny-list → **open folder only**
  (`shell -NoExit -Command "Set-Location <cwd>"`).
- Special case: `git` is replayed *unless* the full command matches a trivial git
  subcommand (`status`, `log`, `diff`, `branch`) — those open folder only.
- Otherwise → **replay** the full command via `-NoExit -Command`.

Default deny-list: `ls dir gci cd sl pwd cls clear cat type echo where which ll`.
Editable in `denylist.txt`.

## `wt` command construction

```
wt.exe new-tab --title "proj1" -d "C:\dev\proj1" pwsh.exe -NoExit -Command "claude" `
  `; new-tab --title "proj2" -d "C:\dev\proj2" powershell.exe -NoExit -Command "Set-Location 'C:\dev\proj2'"
```

- Tab title = leaf folder name.
- Subsequent tabs joined with the literal `;` separator (escaped for the shell that
  invokes `wt`).
- Paths and commands quoted to survive spaces (e.g. `C:\Users\Khalid Hasan`).

## Error handling

- **No session files / empty state:** launcher prints "Nothing to restore" and exits 0.
- **`wt.exe` not found:** launcher raises with a clear message and the resolved
  path it tried.
- **Malformed session JSON:** skip that file with a warning naming the file; continue
  with the rest. Never abort the whole restore for one bad file.
- **Profile already instrumented:** installer detects the marker and skips re-append.
- Tracker hooks are wrapped so a failure to write state **never** breaks the user's
  interactive prompt (capture is best-effort; a failed write is swallowed with an
  optional debug log, the command still runs).

## Testing strategy

The interactive hooks can't be unit-tested directly, so the logic is split into pure,
testable functions (a small module) with thin interactive wrappers:

- `Select-RestorableSessions` — given a list of session objects + a boot time + a
  PID-liveness function, returns the subset to restore. (Pester: dead/pre-boot →
  restored; dead/post-boot → not; alive → not.)
- `Resolve-RestoreAction` — given a command + deny-list, returns
  `{ replay: bool, command }`. (Pester: `claude`→replay; `ls`→folder-only;
  `git status`→folder-only; `git push`→replay; quoted paths preserved.)
- `Build-WtArguments` — given restorable sessions, returns the exact `wt` arg array.
  (Pester: tab count, titles, `-d` quoting, separator, shell exe selection.)
- JSON read/write round-trip and malformed-file skipping.

Manual smoke test: install, open two tabs in two folders, run `claude` in one and
`ls` in the other, simulate the "open at shutdown" state by hand-stamping `updatedAt`
before boot time, run the launcher, verify one tab replays `claude` and the other
opens the folder only.

## Open risks / accepted trade-offs

- Captures the last *typed* command only. If the user exits `claude`, types `ls`, then
  reboots, the tab restores as folder-only — acceptable per the trivial-command rule.
- Keystrokes typed *inside* `claude` go to `claude`'s stdin, not PSReadLine, so they
  don't overwrite the captured `claude` command. (Verified reasoning, validated in
  smoke test.)
- All restored tabs land in **one** Terminal window. Multi-window grouping is a
  possible later enhancement (would require recording the window id per session).
