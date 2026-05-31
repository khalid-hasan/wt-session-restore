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

Describe 'Select-RestorableSessions' {
    BeforeAll {
        # updatedAt is epoch milliseconds (UTC).
        $boot   = [System.DateTimeOffset]::Parse('2026-05-31T12:00:00Z').UtcDateTime
        $preMs  = [System.DateTimeOffset]::Parse('2026-05-31T10:00:00Z').ToUnixTimeMilliseconds()
        $postMs = [System.DateTimeOffset]::Parse('2026-05-31T13:00:00Z').ToUnixTimeMilliseconds()
        $alive  = { param($processId) $processId -eq 999 }
        $sessions = @(
            [pscustomobject]@{ pid = 100; updatedAt = $preMs }   # dead, pre-boot  -> keep
            [pscustomobject]@{ pid = 101; updatedAt = $postMs }  # dead, post-boot -> drop
            [pscustomobject]@{ pid = 999; updatedAt = $preMs }   # alive           -> drop
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

Describe 'Selection survives a JSON round-trip (regression: ConvertFrom-Json date mangling)' {
    It 'still selects a dead, pre-boot session after write + read' {
        $dir = Join-Path $TestDrive 'rt'
        New-Item -ItemType Directory -Path $dir | Out-Null
        $boot   = [System.DateTimeOffset]::Parse('2026-05-31T12:00:00Z').UtcDateTime
        $preMs  = [System.DateTimeOffset]::Parse('2026-05-31T10:00:00Z').ToUnixTimeMilliseconds()
        Write-SessionStateAtomic -Path (Join-Path $dir 's.json') -State ([pscustomobject]@{
            id = 's'; pid = 999999; shell = 'pwsh.exe'; cwd = 'C:\x'; command = 'claude'; updatedAt = $preMs
        })
        $loaded = Read-AllSessions $dir
        $r = Select-RestorableSessions -Sessions $loaded -BootTime $boot -IsPidAlive { param($processId) $false }
        $r.Count | Should -Be 1
        $r[0].command | Should -Be 'claude'
    }
}

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
