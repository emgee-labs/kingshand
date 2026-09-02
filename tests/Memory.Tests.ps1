# Every case here runs against a throwaway fixture tree under $TestDrive. Nothing in this file
# reads or writes $env:KINGSHAND_HOME\data - the live king.md and learnings.md are the user's own
# memory, and a test that measured them would fail the moment they were curated.

BeforeAll {
    Import-Module "$PSScriptRoot\..\bin\Memory.psm1" -Force

    # Written as raw UTF-8 bytes rather than through Set-Content, so no encoding default, no BOM
    # and no appended newline can move the byte count the estimate is asserted against.
    function New-FixtureFile {
        param(
            [Parameter(Mandatory)][string]$Path,
            [Parameter(Mandatory)][AllowEmptyString()][string]$Content
        )
        $dir = Split-Path -Parent $Path
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        [System.IO.File]::WriteAllBytes($Path, [System.Text.Encoding]::UTF8.GetBytes($Content))
        $Path
    }
}

Describe 'Measure-MemoryFile estimates ceil(UTF-8 bytes / 3)' {
    It 'divides exactly when the byte count is a multiple of three' {
        $p = New-FixtureFile -Path (Join-Path $TestDrive 'exact.md') -Content 'abcdef'
        $m = Measure-MemoryFile -Path $p
        $m.bytes  | Should -Be 6
        $m.tokens | Should -Be 2
    }

    It 'rounds up rather than down for <content>' -ForEach @(
        @{ content = 'a';    bytes = 1; tokens = 1 }
        @{ content = 'ab';   bytes = 2; tokens = 1 }
        @{ content = 'abcd'; bytes = 4; tokens = 2 }
        @{ content = 'abcde'; bytes = 5; tokens = 2 }
    ) {
        $p = New-FixtureFile -Path (Join-Path $TestDrive 'round.md') -Content $content
        $m = Measure-MemoryFile -Path $p
        $m.bytes  | Should -Be $bytes
        $m.tokens | Should -Be $tokens
    }

    It 'counts UTF-8 bytes, not characters, for multi-byte content' {
        # 'e' + U+00E9 (2 bytes) + U+20AC (3 bytes) + U+1F6A2 (4 bytes) = 10 bytes from 5 chars.
        $content = "e$([char]0x00E9)$([char]0x20AC)$([char]::ConvertFromUtf32(0x1F6A2))"
        $p = New-FixtureFile -Path (Join-Path $TestDrive 'multibyte.md') -Content $content
        $m = Measure-MemoryFile -Path $p
        $m.bytes  | Should -Be ([System.Text.Encoding]::UTF8.GetByteCount($content))
        $m.bytes  | Should -Be 10
        $m.tokens | Should -Be 4
    }

    It 'matches the formula for a realistic multi-byte memory file' {
        $content = ("- The user prefers plain '-' over the long dash, always. " * 40) +
                   ("- Budget headroom: $([char]0x2265) 500 estimated tokens. " * 10)
        $p = New-FixtureFile -Path (Join-Path $TestDrive 'realistic.md') -Content $content
        $expectedBytes = [System.Text.Encoding]::UTF8.GetByteCount($content)
        $m = Measure-MemoryFile -Path $p
        $m.bytes  | Should -Be $expectedBytes
        $m.tokens | Should -Be ([long][Math]::Ceiling($expectedBytes / 3.0))
    }

    It 'measures an empty present file as zero, still marked present' {
        $p = New-FixtureFile -Path (Join-Path $TestDrive 'empty.md') -Content ''
        $m = Measure-MemoryFile -Path $p
        $m.present | Should -BeTrue
        $m.bytes   | Should -Be 0
        $m.tokens  | Should -Be 0
    }

    It 'reports an absent file as absent and zero, without throwing' {
        $p = Join-Path $TestDrive 'never-written.md'
        $m = $null
        { $script:m = Measure-MemoryFile -Path $p } | Should -Not -Throw
        $script:m.present | Should -BeFalse
        $script:m.bytes   | Should -Be 0
        $script:m.tokens  | Should -Be 0
        $script:m.name    | Should -Be 'never-written.md'
    }
}

Describe 'Get-MemoryBudget' {
    BeforeEach {
        $script:ConfigDir  = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        $script:BudgetPath = Join-Path $script:ConfigDir 'startup-memory-budget'
        New-Item -ItemType Directory -Force -Path $script:ConfigDir | Out-Null
    }

    It 'defaults to 7500 when the budget file is absent' {
        Get-MemoryBudget -BudgetPath $script:BudgetPath | Should -Be 7500
    }

    It 'reads a plain value with a trailing newline' {
        New-FixtureFile -Path $script:BudgetPath -Content "9000`n" | Out-Null
        Get-MemoryBudget -BudgetPath $script:BudgetPath | Should -Be 9000
    }

    It 'reads a value with no trailing newline at all' {
        New-FixtureFile -Path $script:BudgetPath -Content '12000' | Out-Null
        Get-MemoryBudget -BudgetPath $script:BudgetPath | Should -Be 12000
    }

    It 'reads a CRLF-terminated value the same way' {
        New-FixtureFile -Path $script:BudgetPath -Content "7500`r`n" | Out-Null
        Get-MemoryBudget -BudgetPath $script:BudgetPath | Should -Be 7500
    }

    # A malformed setting must never be read as the default. Silently falling back to 7500 would
    # let memory grow past a limit the user believed they had set, with nothing reporting it.
    It 'refuses a <case> budget file rather than defaulting' -ForEach @(
        @{ case = 'empty';            content = '' }
        @{ case = 'whitespace-only';  content = "   `n" }
        @{ case = 'negative';         content = "-5`n" }
        @{ case = 'zero';             content = "0`n" }
        @{ case = 'non-numeric';      content = "lots`n" }
        @{ case = 'trailing-text';    content = "7500 tokens`n" }
        @{ case = 'leading-space';    content = " 7500`n" }
        @{ case = 'leading-zero';     content = "07500`n" }
        @{ case = 'decimal';          content = "7500.0`n" }
        @{ case = 'multi-line';       content = "7500`n7500`n" }
        @{ case = 'value-then-comment'; content = "7500`n# raised on 2026-08-28`n" }
    ) {
        New-FixtureFile -Path $script:BudgetPath -Content $content | Out-Null
        { Get-MemoryBudget -BudgetPath $script:BudgetPath } | Should -Throw
    }

    It 'names the file and the required shape so the error is actionable' {
        New-FixtureFile -Path $script:BudgetPath -Content "lots`n" | Out-Null
        $err = $null
        try { Get-MemoryBudget -BudgetPath $script:BudgetPath } catch { $err = $_.Exception.Message }
        $err | Should -Not -BeNullOrEmpty
        $err.Contains($script:BudgetPath) | Should -BeTrue -Because 'the user must be told which file to fix'
        $err | Should -Match 'positive whole number'
        $err | Should -Match '7500'
    }

    It 'says a multi-line file has more than one line' {
        New-FixtureFile -Path $script:BudgetPath -Content "7500`n7500`n" | Out-Null
        { Get-MemoryBudget -BudgetPath $script:BudgetPath } | Should -Throw '*more than one line*'
    }
}

Describe 'Get-MemoryReport accounts for both memory files' {
    BeforeEach {
        $script:Case       = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        $script:DataDir    = Join-Path $script:Case 'data'
        $script:BudgetPath = Join-Path $script:Case 'config\startup-memory-budget'
        New-Item -ItemType Directory -Force -Path $script:DataDir | Out-Null
    }

    It 'reports both files, the total, the budget, and that it is within it' {
        New-FixtureFile -Path (Join-Path $script:DataDir 'king.md')   -Content ('a' * 300) | Out-Null
        New-FixtureFile -Path (Join-Path $script:DataDir 'learnings.md') -Content ('b' * 600) | Out-Null

        $r = Get-MemoryReport -DataPath $script:DataDir -BudgetPath $script:BudgetPath
        $r.files.Count | Should -Be 2
        $r.budget      | Should -Be 7500
        $r.total       | Should -Be 300
        $r.overBudget  | Should -BeFalse

        $Hand   = $r.files | Where-Object { $_.name -eq 'king.md' }
        $learnings = $r.files | Where-Object { $_.name -eq 'learnings.md' }
        $Hand.tokens   | Should -Be 100
        $learnings.tokens | Should -Be 200
        $r.total | Should -Be ($Hand.tokens + $learnings.tokens)
    }

    It 'accounts for both files even when only <present> is on disk' -ForEach @(
        @{ present = 'king.md';   absent = 'learnings.md' }
        @{ present = 'learnings.md'; absent = 'king.md' }
    ) {
        New-FixtureFile -Path (Join-Path $script:DataDir $present) -Content ('c' * 90) | Out-Null

        $r = $null
        { $script:r = Get-MemoryReport -DataPath $script:DataDir -BudgetPath $script:BudgetPath } |
            Should -Not -Throw -Because 'an absent memory file is normal, not an error'
        $script:r.files.Count | Should -Be 2
        $script:r.total       | Should -Be 30
        ($script:r.files | Where-Object { $_.name -eq $present }).present | Should -BeTrue
        ($script:r.files | Where-Object { $_.name -eq $absent }).present  | Should -BeFalse
    }

    It 'reports zero for a kingshand that has chronicled nothing yet' {
        $r = $null
        { $script:r = Get-MemoryReport -DataPath $script:DataDir -BudgetPath $script:BudgetPath } |
            Should -Not -Throw -Because 'absence is meaningful, not an error'
        $script:r.files.Count | Should -Be 2
        $script:r.total       | Should -Be 0
        $script:r.overBudget  | Should -BeFalse
        foreach ($f in $script:r.files) { $f.present | Should -BeFalse }
    }

    It 'reports zero even when the data directory itself does not exist' {
        $r = Get-MemoryReport -DataPath (Join-Path $script:Case 'no-such-data') -BudgetPath $script:BudgetPath
        $r.total      | Should -Be 0
        $r.overBudget | Should -BeFalse
    }

    It 'flags an over-budget total against a configured budget' {
        New-FixtureFile -Path $script:BudgetPath -Content "100`n" | Out-Null
        New-FixtureFile -Path (Join-Path $script:DataDir 'king.md')   -Content ('a' * 300) | Out-Null
        New-FixtureFile -Path (Join-Path $script:DataDir 'learnings.md') -Content ('b' * 30)  | Out-Null

        $r = Get-MemoryReport -DataPath $script:DataDir -BudgetPath $script:BudgetPath
        $r.budget     | Should -Be 100
        $r.total      | Should -Be 110
        $r.overBudget | Should -BeTrue
    }

    It 'treats a total exactly on the budget as within it' {
        New-FixtureFile -Path $script:BudgetPath -Content "100`n" | Out-Null
        New-FixtureFile -Path (Join-Path $script:DataDir 'king.md') -Content ('a' * 300) | Out-Null

        $r = Get-MemoryReport -DataPath $script:DataDir -BudgetPath $script:BudgetPath
        $r.total      | Should -Be 100
        $r.overBudget | Should -BeFalse
    }

    It 'raises the budget error rather than reporting a total it cannot judge' {
        New-FixtureFile -Path $script:BudgetPath -Content "lots`n" | Out-Null
        New-FixtureFile -Path (Join-Path $script:DataDir 'king.md') -Content ('a' * 300) | Out-Null
        { Get-MemoryReport -DataPath $script:DataDir -BudgetPath $script:BudgetPath } | Should -Throw
    }

    It 'names its estimator as an approximation rather than a tokenizer' {
        $r = Get-MemoryReport -DataPath $script:DataDir -BudgetPath $script:BudgetPath
        $r.estimator | Should -Match 'ceil\(UTF-8 bytes / 3\)'
        $r.estimator | Should -Match 'not a tokenizer'
    }
}

# A forced nested import removes Paths.psm1 before re-importing it, so a script that had already
# imported it lost Get-KingshandHome the moment this module loaded, and died on its next path
# lookup with an error from a module it never touched. Get-SessionStart.ps1 imports Paths first and
# Memory second, which is exactly that order; this is the same invariant for the Memory -> Paths
# edge. One child process, in the order that breaks.
Describe 'importing Memory does not unload Paths from the caller' {
    BeforeAll {
        $root   = Split-Path $PSScriptRoot -Parent
        $driver = Join-Path ([IO.Path]::GetTempPath()) ("memoryimport-" + [guid]::NewGuid().ToString('N') + '.ps1')
        Set-Content -LiteralPath $driver -Encoding utf8 -Value @"
Import-Module '$root\bin\Paths.psm1' -Force
Import-Module '$root\bin\Memory.psm1' -Force
Write-Host "PATHS_BOUND=`$([bool](Get-Command Get-KingshandHome -ErrorAction SilentlyContinue))"
Write-Host "MEMORY_BOUND=`$([bool](Get-Command Get-MemoryReport -ErrorAction SilentlyContinue))"
"@
        try {
            $script:MemoryImportOut = & (Get-Process -Id $PID).Path -NoProfile -File $driver 2>&1 | Out-String
        } finally {
            Remove-Item -LiteralPath $driver -Force -ErrorAction SilentlyContinue
        }
    }

    It 'keeps Get-KingshandHome bound in the session that imported Paths first' {
        $script:MemoryImportOut | Should -BeLike '*PATHS_BOUND=True*'
    }

    It 'still binds its own exports' {
        $script:MemoryImportOut | Should -BeLike '*MEMORY_BOUND=True*'
    }
}
