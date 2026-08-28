# Get-SessionStart.ps1 runs from a SessionStart hook, which means two things this suite exists to
# hold. It must never throw, because a digest that explodes is a session that will not start; and
# it must state absence plainly, because a fresh session's whole picture of the fleet comes from
# this one block and a silently omitted fact reads as a fact that is not there.
#
# Every case runs against its own throwaway root under TestDrive, with a fake toolchain check and a
# fake budget file. The live $env:KINGSHAND_HOME\data\ and $env:KINGSHAND_HOME\state\ are never read and
# never written by this suite.

BeforeAll {
    $script:DigestScript = Join-Path (Split-Path $PSScriptRoot -Parent) 'bin\Get-SessionStart.ps1'

    function New-Fixture {
        param(
            [Parameter(Mandatory)][string]$Name,
            [switch]$NoDataDirectory,
            [switch]$FailingPrereqs
        )
        $root = Join-Path $TestDrive $Name
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        if (-not $NoDataDirectory) {
            New-Item -ItemType Directory -Force -Path (Join-Path $root 'data') | Out-Null
        }
        New-Item -ItemType Directory -Force -Path (Join-Path $root 'state')  | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $root 'config') | Out-Null

        # A real toolchain check reads this machine, so its verdict would vary between machines and
        # between days. Both shapes are faked here so each case chooses the verdict it is testing.
        $prereq = Join-Path $root 'prereq.ps1'
        if ($FailingPrereqs) {
            Set-Content -Path $prereq -Encoding utf8 -Value @(
                'Write-Host "Checking crew prerequisites"'
                'Write-Host "  OK  git            C:\git.exe"'
                'Write-Host ""'
                'Write-Host "FAILED:"'
                'Write-Host "  - lavish-axi not found. Run: npm install -g lavish-axi"'
                'exit 1'
            )
        } else {
            Set-Content -Path $prereq -Encoding utf8 -Value @(
                'Write-Host "Checking crew prerequisites"'
                'Write-Host "  OK  git            C:\git.exe"'
                'Write-Host ""'
                'Write-Host "All prerequisites satisfied."'
                'exit 0'
            )
        }

        [pscustomobject]@{
            Root         = $root
            Data         = Join-Path $root 'data'
            State        = Join-Path $root 'state\crew.json'
            Registry     = Join-Path $root 'data\projects.md'
            Budget       = Join-Path $root 'config\startup-memory-budget'
            Instructions = Join-Path $root 'instructions.md'
            Prereq       = $prereq
        }
    }

    # Every path is passed explicitly, including Instructions. An omitted parameter falls back to
    # Get-KingshandHome, which would read the live instructions.md belonging to whoever is running
    # the suite - their own standing preferences, printed into test output.
    function Get-Digest {
        param([Parameter(Mandatory)]$Fixture, [switch]$Json)
        & $script:DigestScript `
            -DataPath         $Fixture.Data `
            -StatePath        $Fixture.State `
            -RegistryPath     $Fixture.Registry `
            -BudgetPath       $Fixture.Budget `
            -InstructionsPath $Fixture.Instructions `
            -PrereqScript     $Fixture.Prereq `
            -QueueRoot        $Fixture.Root `
            -Json:$Json
    }

    # Same shape the registry parser expects: one entry line, with its indented path: line
    # immediately after it.
    function Add-RegistryEntry {
        param(
            [Parameter(Mandatory)]$Fixture,
            [Parameter(Mandatory)][string]$Line,
            [Parameter(Mandatory)][string]$Path
        )
        if (-not (Test-Path $Fixture.Registry)) {
            Set-Content -Path $Fixture.Registry -Value '# Projects' -Encoding utf8
        }
        Add-Content -Path $Fixture.Registry -Encoding utf8 -Value @('', $Line, "      path: $Path")
    }
}

Describe 'a session with nothing recorded still gets a digest' {
    BeforeAll {
        $script:Bare     = New-Fixture 'bare'
        $script:BareText = Get-Digest $script:Bare
    }

    It 'renders without throwing when the registry, crew and context files are all absent' {
        { Get-Digest $script:Bare } | Should -Not -Throw
    }

    It 'renders every section even though each one is empty' {
        foreach ($section in @('=== KINGSHAND SESSION START', 'FLEET', 'QUEUE', 'CONTEXT')) {
            $script:BareText.Contains($section) |
                Should -BeTrue -Because "a section that renders only when populated is a delta, not a digest: $section"
        }
    }

    It 'says an empty registry means nothing can be dispatched yet' {
        $script:BareText.Contains('nothing can be dispatched until a project is registered with /annex') |
            Should -BeTrue -Because 'an empty registry is a state with a consequence, and the consequence is the useful part'
    }

    It 'says there are no workers rather than omitting the line' {
        $script:BareText.Contains('Workers: none recorded.') | Should -BeTrue
    }

    It 'does not throw when the data directory itself does not exist' {
        $missing = New-Fixture 'no-data' -NoDataDirectory
        { Get-Digest $missing } | Should -Not -Throw
        (Get-Digest $missing).Contains('ABSENT') | Should -BeTrue
    }
}

# The SessionStart hook ships inside the repository, so this digest fires on a fresh clone before
# anything is installed. The skills load from .claude\skills\ and are readable at once, but the
# toolchain and local directories every one of them depends on are not there yet. A digest that
# says "run /annex" to someone who has not set up yet sends them after something that cannot work.
# install.ps1 creates data\, so its absence is the signal.
# KINGSHAND_HOME wins over a script's own location, which is right for the ordinary case and wrong
# for exactly one: a second clone, whose install.ps1 finds the variable already claimed by the
# first and leaves it alone. That copy then runs its own code against the other installation's
# data, and the digest names directories the reader never chose. The precedence is deliberate; the
# silence was the defect.
Describe 'two cross-wired installations are named rather than left to confuse' {
    AfterEach { Remove-Item Env:\KINGSHAND_HOME -ErrorAction SilentlyContinue }

    It 'says so when KINGSHAND_HOME points somewhere other than this copy' {
        $env:KINGSHAND_HOME = Join-Path $TestDrive 'some-other-install'
        $text = Get-Digest (New-Fixture 'cross-wired')
        $text.Contains('HOME MISMATCH') | Should -BeTrue
        $text.Contains('Two cross-wired') | Should -BeFalse -Because 'the heading is the marker, not the prose'
        $text.Contains('so everything below is read from there') | Should -BeTrue
    }

    It 'names both paths, so the reader can tell which copy is which' {
        $other = Join-Path $TestDrive 'some-other-install'
        $env:KINGSHAND_HOME = $other
        $text = Get-Digest (New-Fixture 'cross-wired-paths')
        $text.Contains($other) | Should -BeTrue
        $text.Contains('Run install.ps1 -Force here to claim it') | Should -BeTrue
    }

    It 'stays silent when the variable agrees with this copy' {
        $env:KINGSHAND_HOME = Split-Path (Split-Path $script:DigestScript -Parent) -Parent
        (Get-Digest (New-Fixture 'home-agrees')).Contains('HOME MISMATCH') |
            Should -BeFalse -Because 'the ordinary case is a variable that matches, and it must not warn'
    }

    It 'stays silent when the variable is unset' {
        Remove-Item Env:\KINGSHAND_HOME -ErrorAction SilentlyContinue
        (Get-Digest (New-Fixture 'home-unset')).Contains('HOME MISMATCH') |
            Should -BeFalse -Because 'unset is the ordinary state of a fresh clone, never an error'
    }
}

Describe 'a fresh clone is told to set up, and is not sent after a skill that cannot work yet' {
    BeforeAll {
        $script:Fresh     = New-Fixture 'fresh-clone' -NoDataDirectory
        $script:FreshText = Get-Digest $script:Fresh
    }

    It 'leads with a first-run banner' {
        $script:FreshText.Contains('NOT SET UP YET') | Should -BeTrue
        $script:FreshText.Contains('This looks like a fresh clone') | Should -BeTrue
    }

    It 'names the one thing that works, in the words the setup skill answers to' {
        $script:FreshText.Contains('Tell the Hand "set it up".') | Should -BeTrue
        $script:FreshText.Contains('The one useful next step is "set it up".') | Should -BeTrue
    }

    It 'does not name /annex while it is still unreachable' {
        $script:FreshText.Contains('/annex') |
            Should -BeFalse -Because 'the registry and toolchain it needs are created by install.ps1, which has not run'
        $script:FreshText.Contains('set it up first') | Should -BeTrue
    }

    It 'still renders every other section rather than stopping at the banner' {
        foreach ($section in @('FLEET', 'QUEUE', 'CONTEXT')) {
            $script:FreshText.Contains($section) |
                Should -BeTrue -Because 'the banner is a heading, not an early return'
        }
    }

    It 'drops the banner once the installation exists' {
        $installed = New-Fixture 'already-installed'
        $text = Get-Digest $installed
        $text.Contains('NOT SET UP YET') | Should -BeFalse
        $text.Contains('/annex') |
            Should -BeTrue -Because 'once the installation exists, naming the real next step is correct again'
    }
}

Describe 'the registry is named project by project, with its posture' {
    BeforeAll {
        $script:Reg = New-Fixture 'registry'
        foreach ($n in @('alpha', 'beta', 'gamma')) {
            New-Item -ItemType Directory -Force -Path (Join-Path $script:Reg.Root "repos\$n") | Out-Null
        }
        Add-RegistryEntry $script:Reg '- alpha [direct-PR] - alpha repo (added 2026-01-01)' (Join-Path $script:Reg.Root 'repos\alpha')
        Add-RegistryEntry $script:Reg '- beta [no-mistakes +yolo] - beta repo (added 2026-01-02)' (Join-Path $script:Reg.Root 'repos\beta')
        Add-RegistryEntry $script:Reg '- gamma [local-only] - gamma repo (added 2026-01-03)' (Join-Path $script:Reg.Root 'repos\gamma')
        $script:RegText = Get-Digest $script:Reg
    }

    It 'counts the registered projects' {
        $script:RegText.Contains('Projects: 3 registered') | Should -BeTrue
    }

    It 'names <name> with its posture and yolo standing' -ForEach @(
        @{ name = 'alpha'; line = '- alpha [direct-PR] yolo off' }
        @{ name = 'beta';  line = '- beta [no-mistakes] yolo on' }
        @{ name = 'gamma'; line = '- gamma [local-only] yolo off' }
    ) {
        $script:RegText.Contains($line) |
            Should -BeTrue -Because "the registry line is name, posture and path, and $name must carry all three"
    }

    It 'records each project''s path rather than the detail that belongs to the project' {
        $script:RegText.Contains((Join-Path $script:Reg.Root 'repos\alpha')) | Should -BeTrue
        $script:RegText.Contains('PATH MISSING') |
            Should -BeFalse -Because 'every fixture path was created on disk'
    }

    It 'flags a registered project whose path is gone' {
        $f = New-Fixture 'registry-gone'
        Add-RegistryEntry $f '- vanished [local-only] - deleted repo (added 2026-01-01)' (Join-Path $f.Root 'repos\vanished')
        (Get-Digest $f).Contains('PATH MISSING') |
            Should -BeTrue -Because 'a posture that points nowhere cannot be dispatched into'
    }
}

Describe 'an absent context file is a fact, not an omission' {
    BeforeAll {
        $script:Ctx     = New-Fixture 'context-absent'
        $script:CtxText = Get-Digest $script:Ctx
    }

    It 'delimits king.md and marks it ABSENT' {
        $script:CtxText.Contains('----- BEGIN king.md') | Should -BeTrue
        $script:CtxText.Contains('ABSENT - nothing has been recorded about how the King works yet.') |
            Should -BeTrue -Because 'absent means no preferences recorded, and the digest must say which'
        $script:CtxText.Contains('----- END king.md -----') | Should -BeTrue
    }

    It 'delimits learnings.md and marks it ABSENT too' {
        $script:CtxText.Contains('----- BEGIN learnings.md') | Should -BeTrue
        $script:CtxText.Contains('ABSENT - no operational learnings have been recorded yet.') | Should -BeTrue
        $script:CtxText.Contains('----- END learnings.md -----') | Should -BeTrue
    }

    It 'delimits instructions.md and marks it ABSENT, exactly as it does a memory file' {
        # The King having stated nothing is an ordinary state. Treating it as an error, or as a
        # prompt to create the file, is how a tool ends up writing into the one file it may not.
        $script:CtxText.Contains('----- BEGIN instructions.md') | Should -BeTrue
        $script:CtxText.Contains('ABSENT - the King has stated no standing instructions. Read it, never write it.') |
            Should -BeTrue -Because 'absence here is a state the digest states plainly, not an omission'
        $script:CtxText.Contains('----- END instructions.md -----') | Should -BeTrue
    }

    It 'never invents a placeholder body for any of the three files' {
        $script:CtxText.Contains('EMPTY -') |
            Should -BeFalse -Because 'none of the three exists, so none is empty-but-present'
    }
}

Describe 'the King''s stated instructions reach the session verbatim' {
    It 'prints instructions.md in full, before either memory file' {
        $f = New-Fixture 'instructions-present'
        Set-Content -Path $f.Instructions -Encoding utf8 -Value @(
            '# Standing instructions'
            '- Lead with the answer, then the evidence.'
            '- Never open a pull request against an unregistered repository.'
        )
        $text = Get-Digest $f

        $text.Contains('- Lead with the answer, then the evidence.') |
            Should -BeTrue -Because 'a standing instruction the session never sees is not standing at all'
        $text.Contains('- Never open a pull request against an unregistered repository.') | Should -BeTrue

        # Ordering is load-bearing: what the King stated is read before what the Hand inferred.
        $text.IndexOf('----- BEGIN instructions.md') |
            Should -BeLessThan ($text.IndexOf('----- BEGIN king.md')) `
            -Because 'the stated word is read before the inferred one, never after it'
    }

    It 'is not counted against the startup-memory budget' {
        # 900 bytes of instructions against a budget of 10 tokens. If instructions.md were
        # accounted, this would report an overrun - and an overrun tells the Hand to run /chronicle,
        # which is a curation pass over a file nothing is allowed to curate.
        $f = New-Fixture 'instructions-unbudgeted'
        Set-Content -Path $f.Budget -Value '10' -NoNewline -Encoding utf8
        Set-Content -Path $f.Instructions -NoNewline -Encoding utf8 -Value ('x' * 900)
        $text = Get-Digest $f

        $text.Contains('STARTUP_MEMORY_BUDGET:') |
            Should -BeFalse -Because 'the budget measures what chronicle may prune, and chronicle may not prune this file'
        $text.Contains('  Startup memory: 0 of 10 estimated tokens.') |
            Should -BeTrue -Because 'with both memory files absent the accounted total is zero'
    }

    It 'reports an unreadable instructions.md rather than failing the digest' {
        $f = New-Fixture 'instructions-directory'
        New-Item -ItemType Directory -Force -Path $f.Instructions | Out-Null
        { Get-Digest $f } | Should -Not -Throw
        (Get-Digest $f).Contains('----- BEGIN instructions.md') | Should -BeTrue
    }
}

Describe 'an empty file and an absent file are different facts' {
    BeforeAll {
        $script:Mixed = New-Fixture 'context-empty'
        Set-Content -Path (Join-Path $script:Mixed.Data 'king.md') -Value '' -NoNewline -Encoding utf8
        $script:MixedText = Get-Digest $script:Mixed
    }

    It 'calls the present-but-empty file EMPTY, never ABSENT' {
        $script:MixedText.Contains('EMPTY - the file exists but holds no content.') |
            Should -BeTrue -Because 'someone recorded nothing is not the same as nothing has been recorded'
    }

    It 'still calls the file that is not there ABSENT' {
        $script:MixedText.Contains('ABSENT - no operational learnings have been recorded yet.') | Should -BeTrue
    }

    It 'prints a present file''s body between its own delimiters' {
        $f = New-Fixture 'context-body'
        Set-Content -Path (Join-Path $f.Data 'learnings.md') -Encoding utf8 -Value @(
            '# Learnings'
            '- 2026-08-28: lavish on 4387 is WSL and answers silently.'
        )
        $text = Get-Digest $f
        $text.Contains('- 2026-08-28: lavish on 4387 is WSL and answers silently.') |
            Should -BeTrue -Because 'the two context files are the one thing the digest prints in full'
        $text.Contains('ABSENT - nothing has been recorded about how the King works yet.') | Should -BeTrue
    }
}

Describe 'the startup-memory budget is reported with its numbers' {
    BeforeAll {
        # 120 ASCII bytes against a budget of 10 tokens: ceil(120 / 3) is 40, so the overrun is 30
        # and every number in the diagnostic is known in advance rather than read back out of it.
        $script:Over = New-Fixture 'budget-over'
        Set-Content -Path $script:Over.Budget -Value '10' -NoNewline -Encoding utf8
        Set-Content -Path (Join-Path $script:Over.Data 'king.md') -NoNewline -Encoding utf8 -Value ('x' * 120)
        $script:OverText = Get-Digest $script:Over
    }

    It 'names the total, the budget and the overrun' {
        $script:OverText.Contains('STARTUP_MEMORY_BUDGET: 40 estimated tokens against a budget of 10, over by 30') |
            Should -BeTrue -Because 'a budget diagnostic without its numbers cannot be acted on'
    }

    It 'names /chronicle as the way to curate it down' {
        $script:OverText.Contains('/chronicle') |
            Should -BeTrue -Because 'the diagnostic must name the one thing that fixes it'
    }

    It 'prints the file anyway, because the budget is a signal and not a gate' {
        $script:OverText.Contains('xxxxxxxxxx') | Should -BeTrue
        $script:OverText.Contains('the budget is a signal, not a gate') | Should -BeTrue
    }

    It 'reports the ordinary total when the two files are within budget' {
        $under = New-Fixture 'budget-under'
        Set-Content -Path $under.Budget -Value '7500' -NoNewline -Encoding utf8
        $text = Get-Digest $under
        $text.Contains('Startup memory: 0 of 7500 estimated tokens.') | Should -BeTrue
        $text.Contains('STARTUP_MEMORY_BUDGET:') |
            Should -BeFalse -Because 'a diagnostic that prints when nothing is wrong trains the reader to skip it'
    }

    It 'degrades with a diagnostic rather than throwing on a malformed budget file' {
        $bad = New-Fixture 'budget-malformed'
        Set-Content -Path $bad.Budget -Value 'seven thousand' -NoNewline -Encoding utf8
        { Get-Digest $bad } | Should -Not -Throw
        (Get-Digest $bad).Contains('STARTUP_MEMORY_BUDGET: could not be accounted') | Should -BeTrue
    }
}

Describe 'a broken section loses only itself' {
    BeforeAll {
        $script:Broken = New-Fixture 'malformed-crew'
        New-Item -ItemType Directory -Force -Path (Join-Path $script:Broken.Root 'repos\alpha') | Out-Null
        Add-RegistryEntry $script:Broken '- alpha [direct-PR] - alpha repo (added 2026-01-01)' (Join-Path $script:Broken.Root 'repos\alpha')
        Set-Content -Path $script:Broken.State -Value '{ "workers": ' -Encoding utf8
        $script:BrokenText = Get-Digest $script:Broken
    }

    It 'does not throw on a malformed crew.json' {
        { Get-Digest $script:Broken } | Should -Not -Throw
    }

    It 'prints a diagnostic naming what it lost' {
        $script:BrokenText.Contains('FLEET:') |
            Should -BeTrue -Because 'a section that fails silently is worse than one that fails loudly'
        $script:BrokenText.Contains('crew.json') |
            Should -BeTrue -Because 'the diagnostic must name the source, or nobody can act on it'
    }

    It 'still renders the registry the broken file never touched' {
        $script:BrokenText.Contains('Projects: 1 registered') | Should -BeTrue
        $script:BrokenText.Contains('- alpha [direct-PR]')    | Should -BeTrue
    }

    It 'still renders the context section' {
        $script:BrokenText.Contains('----- BEGIN king.md') | Should -BeTrue
    }
}

Describe 'the toolchain check is detect-only and silent when it is clean' {
    It 'prints nothing at all when every prerequisite is satisfied' {
        $clean = New-Fixture 'prereq-clean'
        $text  = Get-Digest $clean
        $text.Contains('PREREQS:') |
            Should -BeFalse -Because 'a routine confirmation at session start trains the reader to skip the section'
        $text.Contains('All prerequisites satisfied.') |
            Should -BeFalse -Because 'the check runs, but its clean output is not the digest''s output'
    }

    It 'prints the actionable problem, and only that' {
        $broken = New-Fixture 'prereq-failing' -FailingPrereqs
        $text   = Get-Digest $broken
        $text.Contains('PREREQS: lavish-axi not found. Run: npm install -g lavish-axi') |
            Should -BeTrue -Because 'an actionable problem must reach the session with what fixes it'
        $text.Contains('OK  git') |
            Should -BeFalse -Because 'a passing check is not news'
    }

    It 'says so rather than throwing when the check itself is missing' {
        $f = New-Fixture 'prereq-missing'
        Remove-Item -LiteralPath $f.Prereq -Force
        { Get-Digest $f } | Should -Not -Throw
        (Get-Digest $f).Contains('PREREQS: the toolchain check is not at') |
            Should -BeTrue -Because 'nothing verified is a different fact from everything verified'
    }
}

Describe 'the hook envelope carries the digest as parseable JSON' {
    BeforeAll {
        $script:JsonFixture = New-Fixture 'json'
        $script:JsonRaw     = Get-Digest $script:JsonFixture -Json
    }

    It 'emits one JSON document and nothing else' {
        @($script:JsonRaw).Count | Should -Be 1
        { $script:JsonRaw | ConvertFrom-Json } | Should -Not -Throw
    }

    It 'names the SessionStart hook event' {
        $obj = $script:JsonRaw | ConvertFrom-Json
        $obj.hookSpecificOutput.hookEventName | Should -Be 'SessionStart'
    }

    It 'carries the whole digest as additionalContext' {
        $obj = $script:JsonRaw | ConvertFrom-Json
        $obj.hookSpecificOutput.additionalContext.Contains('=== KINGSHAND SESSION START') | Should -BeTrue
        $obj.hookSpecificOutput.additionalContext.Contains('CONTEXT')                     | Should -BeTrue
        $obj.hookSpecificOutput.additionalContext.Contains('ABSENT')                      | Should -BeTrue
    }

    It 'carries the same text the plain-text mode renders' {
        $plain = Get-Digest $script:JsonFixture
        $obj   = $script:JsonRaw | ConvertFrom-Json
        # The timestamp line differs between two runs a minute apart, so the comparison starts
        # below it; everything after that is the same digest in both modes.
        $strip = { param($t) ($t -split "`n" | Select-Object -Skip 1) -join "`n" }
        (& $strip $obj.hookSpecificOutput.additionalContext) | Should -Be (& $strip $plain)
    }
}

# The prose side of this feature - CLAUDE.md's Session start section and its read-once rule - is
# asserted in tests\Docs.Tests.ps1, which owns every assertion about CLAUDE.md's wording.

Describe 'the digest reads the fleet without changing it' {
    It 'writes nothing under the fixture it was pointed at' {
        $f = New-Fixture 'readonly'
        New-Item -ItemType Directory -Force -Path (Join-Path $f.Root 'repos\alpha') | Out-Null
        Add-RegistryEntry $f '- alpha [direct-PR] - alpha repo (added 2026-01-01)' (Join-Path $f.Root 'repos\alpha')
        Set-Content -Path (Join-Path $f.Data 'king.md') -Value '# preferences' -Encoding utf8
        Set-Content -Path $f.State -Value (@{ workers = @{} } | ConvertTo-Json) -Encoding utf8

        $inventory = {
            Get-ChildItem -Path $f.Root -Recurse -File -Force | Sort-Object FullName |
                ForEach-Object { "$($_.FullName)|$((Get-FileHash $_.FullName -Algorithm SHA256).Hash)" }
        }
        $before = @(& $inventory)
        Get-Digest $f | Out-Null
        $after = @(& $inventory)

        $after | Should -Be $before -Because 'a digest that mutates what it reports is not a digest'
    }
}
