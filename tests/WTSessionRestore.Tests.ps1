BeforeAll {
    Import-Module "$PSScriptRoot\..\src\WTSessionRestore.psm1" -Force
}

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

Describe 'Resolve-RestoreAction' {
    BeforeAll { $deny = @('ls', 'dir', 'cd', 'pwd') }

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

Describe 'Select-OpenSessions' {
    BeforeAll {
        $alive = { param($processId) $processId -eq 999 }
        $sessions = @(
            [pscustomobject]@{ pid = 100; cwd = 'C:\a'; command = 'claude'; shell = 'pwsh.exe' }   # dead  -> drop
            [pscustomobject]@{ pid = 999; cwd = 'C:\b'; command = 'codex';  shell = 'pwsh.exe' }    # alive -> keep
        )
    }
    It 'keeps only alive sessions, projected to cwd/command/shell' {
        $r = Select-OpenSessions -Sessions $sessions -IsPidAlive $alive
        $r.Count | Should -Be 1
        $r[0].cwd | Should -Be 'C:\b'
        $r[0].command | Should -Be 'codex'
        $r[0].shell | Should -Be 'pwsh.exe'
        ($r[0].PSObject.Properties.Name -contains 'pid') | Should -BeFalse
    }
    It 'returns empty for empty input' {
        (Select-OpenSessions -Sessions @() -IsPidAlive $alive).Count | Should -Be 0
    }
}

Describe 'Select-MissingTabs' {
    BeforeAll {
        $saved = @(
            [pscustomobject]@{ cwd = 'C:\a'; command = 'claude'; shell = 'pwsh.exe' }
            [pscustomobject]@{ cwd = 'C:\b'; command = 'claude'; shell = 'pwsh.exe' }
            [pscustomobject]@{ cwd = 'C:\b'; command = 'claude'; shell = 'pwsh.exe' }   # two of C:\b
        )
    }
    It 'reopens only the tabs not currently open (close 1 of several)' {
        $open = @(
            [pscustomobject]@{ cwd = 'C:\a'; command = 'claude' }
            [pscustomobject]@{ cwd = 'C:\b'; command = 'claude' }   # one of the two C:\b still open
        )
        $r = Select-MissingTabs -Saved $saved -Open $open
        $r.Count | Should -Be 1
        $r[0].cwd | Should -Be 'C:\b'
    }
    It 'reopens nothing when everything is already open' {
        (Select-MissingTabs -Saved $saved -Open $saved).Count | Should -Be 0
    }
    It 'reopens all saved tabs when nothing is open (reboot case)' {
        (Select-MissingTabs -Saved $saved -Open @()).Count | Should -Be 3
    }
    It 'matches paths case-insensitively' {
        $saved2 = @([pscustomobject]@{ cwd = 'C:\Dev'; command = 'claude' })
        $open2  = @([pscustomobject]@{ cwd = 'c:\dev'; command = 'claude' })
        (Select-MissingTabs -Saved $saved2 -Open $open2).Count | Should -Be 0
    }
}

Describe 'Snapshot survives a JSON round-trip (layout -> wt args)' {
    It 'reopens a saved single-tab layout correctly after write + read' {
        $dir = Join-Path $TestDrive 'rt'
        New-Item -ItemType Directory -Path $dir | Out-Null
        $layoutPath = Join-Path $dir 'layout.json'
        $layout = [pscustomobject]@{
            bootMs = 123; savedAtMs = 456
            tabs   = @([pscustomobject]@{ cwd = 'C:\proj'; command = 'claude'; shell = 'pwsh.exe' })
        }
        Write-SessionStateAtomic -Path $layoutPath -State $layout
        $loaded = Get-Content $layoutPath -Raw | ConvertFrom-Json
        $wtArgs = ConvertTo-WtArgumentList -Sessions @($loaded.tabs) -DenyList @()
        ($wtArgs -join '|') | Should -Be 'new-tab|--title|proj|-d|C:\proj|pwsh.exe|-NoExit|-Command|claude'
    }
}

Describe 'ConvertTo-WtArgumentList' {
    BeforeAll {
        $sessions = @(
            [pscustomobject]@{ cwd = 'C:\dev\proj1'; command = 'claude'; shell = 'pwsh.exe' }
            [pscustomobject]@{ cwd = 'C:\dev\proj2'; command = 'ls';     shell = 'powershell.exe' }
        )
        $deny = @('ls')
    }
    It 'builds the expected wt argument array' {
        $r = ConvertTo-WtArgumentList -Sessions $sessions -DenyList $deny
        ($r -join '|') | Should -Be 'new-tab|--title|proj1|-d|C:\dev\proj1|pwsh.exe|-NoExit|-Command|claude|;|new-tab|--title|proj2|-d|C:\dev\proj2|powershell.exe|-NoExit'
    }
}

Describe 'Get-BootTimeUtcMs' {
    It 'returns a positive epoch-ms value in the past' {
        $boot = Get-BootTimeUtcMs
        $boot | Should -BeOfType [long]
        $boot | Should -BeGreaterThan 0
        $boot | Should -BeLessThan ([System.DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
    }
    It 'is stable across calls (no jitter — boot-transition detection depends on this)' {
        $a = Get-BootTimeUtcMs
        Start-Sleep -Milliseconds 60
        $b = Get-BootTimeUtcMs
        $a | Should -Be $b
    }
}

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
