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

Think of it as two small helpers:

### 1. The "note-taker" (runs invisibly while you work)

Every time you press **Enter** on a command, a tiny background script jots down two things for
that tab:

- the **folder** you're in, and
- the **command** you just ran.

It saves this as a small note (one file per tab) in a hidden folder:
`C:\Users\<you>\.wt-session-restore\sessions\`.

You never see this happen. It adds no steps to your day.

```
You type:  cd C:\dev\myproject   ↵
You type:  claude                ↵     ← note-taker records: folder = C:\dev\myproject, command = claude
```

> **Why record on Enter (not after the command finishes)?**
> Because `claude` runs for a long time. If the tool waited until `claude` finished, it would
> never get a chance to record it. By recording the moment you press Enter, it captures `claude`
> the instant you launch it.

When you **close a tab normally**, that tab's note is deleted (it's not open anymore, so there's
nothing to restore). But when your PC is **force-restarted / auto shut down** (your usual habit),
the notes are *not* deleted — they survive. So after a reboot, the leftover notes are exactly the
tabs that were open when the machine went down.

### 2. The "restorer" (the Desktop shortcut you double-click)

After you log back in, you double-click **Restore Workspace** on your Desktop. It:

1. reads all the leftover notes,
2. opens **one** Windows Terminal window with **one tab per note**,
3. puts each tab back in its folder and re-runs its command,
4. tidies up the notes it just used.

```
Leftover notes  ─►  Restore Workspace  ─►  ┌─ Tab: myproject  (running claude) ─┐
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

1. **Just work normally.** Open tabs, `cd` into projects, run `claude` / `codex` / whatever.
   The note-taker handles itself.
2. **After a restart**, double-click **Restore Workspace** on your Desktop —
   **before** you start opening terminals by hand.

That's the whole workflow. There's no list to maintain and nothing to remember except the
double-click.

> ⚠️ **One catch:** only tabs opened *after* setup are tracked. Tabs you already had open before
> installing won't be remembered until you reopen them once.

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

This fakes "two tabs that were open at shutdown" and restores them, no reboot needed.

```powershell
$state    = "$env:USERPROFILE\.wt-session-restore"
$sessions = "$state\sessions"

# Clear any real notes so we test cleanly (skip this if you have live tabs you care about):
Get-ChildItem $sessions -Filter *.json -ErrorAction SilentlyContinue | Remove-Item -Force

# A timestamp from just before the last boot, so they count as "open at shutdown":
$preBoot = ([System.DateTimeOffset]((Get-CimInstance Win32_OperatingSystem).LastBootUpTime.AddMinutes(-5))).ToUnixTimeMilliseconds()

[pscustomobject]@{ id='demo1'; pid=999999; shell='pwsh.exe'; cwd='C:\Windows'; command='Get-ChildItem'; updatedAt=$preBoot } |
    ConvertTo-Json | Set-Content "$sessions\demo1.json"
[pscustomobject]@{ id='demo2'; pid=999998; shell='pwsh.exe'; cwd='C:\Windows\System32'; command='ls'; updatedAt=$preBoot } |
    ConvertTo-Json | Set-Content "$sessions\demo2.json"

# Run the restorer:
& "$state\Restore-Workspace.ps1"
```

✅ **Expected:** a new Windows Terminal window opens with **two tabs** — one in `C:\Windows`
running `Get-ChildItem`, one in `System32` opened as a plain prompt (because `ls` is on the
skip-list). The console prints `wt-session-restore: opened 2 tab(s).`

### Test 3 — The real thing (when you're ready)

Open a few project tabs, run `claude` in them, **restart your PC normally**, log back in, and
double-click **Restore Workspace**. Your tabs should come back in their folders with `claude`
running again.

### Test 4 — Run the automated tests (for developers)

```powershell
cd wt-session-restore
Install-Module Pester -Scope CurrentUser -MinimumVersion 5.5.0 -Force -SkipPublisherCheck
Invoke-Pester -Path .\tests\WTSessionRestore.Tests.ps1 -Output Detailed
```

✅ **Expected:** 18 tests pass.

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
2. Delete the folder `C:\Users\<you>\.wt-session-restore\` and the **Restore Workspace** Desktop
   shortcut.
