# wt-session-restore — Simple Guide

A plain-English explanation of what this tool does, how it works, how to use it, and how to test it.

---

## The problem it solves

You keep 5–10 Windows Terminal tabs open — one per project — each sitting in its folder
running something like `claude` or `codex`. Every time your PC restarts, they're all gone. You
have to reopen each tab, `cd` into the right folder, and re-run the command. Every. Single. Time.

**This tool brings those tabs back with one double-click.**

---

## How it works (in plain English)

Think of it as three small helpers:

### 1. The "note-taker" (runs invisibly while you work)

Every time you press **Enter** on a command, a tiny background script jots down two things for
that tab:

- the **folder** you're in, and
- the **command** you just ran.

It saves this as a small note (one file per tab) in a hidden folder:
`C:\Users\<you>\.wt-session-restore\sessions\`. You never see this happen.

```
You type:  cd C:\dev\myproject   ↵
You type:  claude                ↵     ← note-taker records: folder = C:\dev\myproject, command = claude
```

> **Why record on Enter (not after the command finishes)?**
> Because `claude` runs for a long time. If the tool waited until `claude` finished, it would
> never get a chance to record it. By recording the moment you press Enter, it captures `claude`
> the instant you launch it.

### 2. The "auto-saver" (a hidden task, every ~2 minutes)

A scheduled task wakes up every couple of minutes and takes a **snapshot** of the tabs that are
*open right now* — saved as `layout.json`. It runs completely hidden (no window pops up).

Because it only snapshots tabs that are currently open, a tab you **closed on purpose** simply
drops out of the next snapshot — so it won't come back later. And because the snapshot is saved
to disk continuously, it doesn't matter *how* your PC shuts down (clean, forced, or a power cut) —
the last snapshot is already safe.

The first snapshot after a **reboot** is smart: it notices the computer restarted and sets aside
the previous session's snapshot as your **restore point** (`restore.json`) before the new session
starts overwriting things. That's what guarantees your pre-reboot tabs survive.

### 3. The "restorer" (the Desktop shortcut you double-click)

After you log back in, you double-click **Restore Workspace** on your Desktop. It reads your
restore point and opens **one** Windows Terminal window with **one tab per entry** — each back in
its folder and re-running its command.

```
Restore point  ─►  Restore Workspace  ─►  ┌─ Tab: myproject  (running claude) ─┐
                                           ├─ Tab: api        (running claude) ─┤
                                           └─ Tab: docs       (folder only)    ─┘
```

### One smart rule: it skips "junk" commands

If the last thing you ran in a tab was something trivial like `ls`, `cd`, or `git status`, the
tool just **opens the folder** without re-running it (you don't want `ls` replayed). Real commands
like `claude`, `npm run dev`, or `python app.py` *are* replayed. The skip-list lives in
`C:\Users\<you>\.wt-session-restore\denylist.txt` and you can edit it.

---

## How to use it

### One-time setup (already done on this machine)

```powershell
git clone https://github.com/khalid-hasan/wt-session-restore.git
cd wt-session-restore
pwsh -ExecutionPolicy Bypass -File .\src\Install-WTSessionRestore.ps1
```

That wires the note-taker into PowerShell and puts the **Restore Workspace** shortcut on your
Desktop.

### Day to day

You get **two Desktop shortcuts**:

- **Save Workspace** — saves *all* your currently-open tabs as the restore point, right now.
  Click it mid-session whenever you want Restore to bring back this exact set. (It saves every
  open tab — you can't pick a subset.)
- **Restore Workspace** — reopens the last saved set (whether you saved it, or the auto-saver did).

So the workflow is:

1. **Just work normally.** The note-taker and auto-saver handle themselves.
2. Optionally click **Save Workspace** when you want a checkpoint.
3. **After a restart**, double-click **Restore Workspace** — the auto-saver already captured your
   tabs, so you don't even need to have clicked Save.

There's no list to maintain.

> ⚠️ **Two things to know:**
> - Only tabs opened *after* setup are tracked. Tabs you had open before installing won't be
>   remembered until you reopen them once.
> - The snapshot runs every ~2 minutes, so a tab you opened in the last minute or two before a
>   reboot might not make it into the restore point. Long-lived project tabs are always captured.

---

## How to test it (without waiting for a reboot)

You can prove each piece works in about two minutes.

### Test 1 — Is it taking notes?

1. Open a **new** Windows Terminal tab.
2. Run a couple of commands, e.g.:
   ```powershell
   cd C:\Windows
   Get-ChildItem
   ```
3. In **any** terminal, look at the notes:
   ```powershell
   Get-Content "$env:USERPROFILE\.wt-session-restore\sessions\*.json"
   ```
   ✅ **Expected:** you see a record with `"cwd": "C:\\Windows"` and the last command you typed.

### Test 2 — Does the restore work?

This fakes a pre-reboot snapshot and restores it, no reboot needed. (The `bootMs = 1` marks the
snapshot as "from before this boot," so Restore treats it as your restore point. Your real
snapshot regenerates automatically within ~2 minutes, so this is safe to run.)

```powershell
$state = "$env:USERPROFILE\.wt-session-restore"
$layout = [pscustomobject]@{ bootMs = 1; savedAtMs = 1; tabs = @(
    [pscustomobject]@{ cwd = 'C:\Windows';          command = 'Get-ChildItem'; shell = 'pwsh.exe' }
    [pscustomobject]@{ cwd = 'C:\Windows\System32'; command = 'ls';            shell = 'powershell.exe' }
)}
($layout | ConvertTo-Json -Depth 5) | Set-Content "$state\layout.json"
& "$state\Restore-Workspace.ps1"
```

✅ **Expected:** a new Windows Terminal window opens with **two tabs** — one in `C:\Windows`
running `Get-ChildItem`, one in `System32` opened as a plain prompt (because `ls` is on the
skip-list). The console prints `wt-session-restore: opened 2 tab(s).`

### Test 3 — Is the auto-saver running?

```powershell
schtasks /Query /TN "wt-session-restore autosave" /FO LIST | Select-String 'Status|Next Run'
Get-Content "$env:USERPROFILE\.wt-session-restore\layout.json"   # your current open tabs
```

✅ **Expected:** the task shows `Status: Ready`, and `layout.json` lists the tabs you currently
have open.

### Test 4 — The real thing (when you're ready)

Open a few project tabs, run `claude` in them, wait a couple of minutes (so a snapshot is taken),
**restart your PC**, log back in, and double-click **Restore Workspace**. Your tabs should come
back in their folders with `claude` running again.

### Test 5 — Run the automated tests (for developers)

```powershell
cd wt-session-restore
Install-Module Pester -Scope CurrentUser -MinimumVersion 5.5.0 -Force -SkipPublisherCheck
Invoke-Pester -Path .\tests\WTSessionRestore.Tests.ps1 -Output Detailed
```

✅ **Expected:** 19 tests pass.

---

## Good to know

- **It only handles PowerShell tabs in Windows Terminal** — not cmd, WSL, or git-bash tabs.
- **It re-runs the command, not the program's memory.** Re-running `claude` starts a *fresh*
  session. If you'd rather it pick up your last conversation, just make a habit of running
  `claude --continue` — the tool restores whatever you actually typed.
- **It restores tabs, not split panes** inside a tab.
- **Notes are written safely** (temp file + rename), so a sudden shutdown can't corrupt them.

## Uninstall

1. Open your PowerShell profile (`notepad $PROFILE`) and delete the block between
   `# >>> wt-session-restore >>>` and `# <<< wt-session-restore <<<`. Do the same for Windows
   PowerShell 5.1 if you use it.
2. Delete the auto-save task: `schtasks /Delete /TN "wt-session-restore autosave" /F`.
3. Delete the folder `C:\Users\<you>\.wt-session-restore\` and the **Restore Workspace** Desktop
   shortcut.
