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
            [switch]$FailingPrereqs,
            [switch]$NoVersionFile
        )
        $root = Join-Path $TestDrive $Name
        New-Item -ItemType Directory -Force -Path $root | Out-Null

        # A version nothing else on this machine has, so a digest that read the live installation's
        # VERSION instead of the fixture's would be obvious rather than plausible.
        if (-not $NoVersionFile) {
            Set-Content -Path (Join-Path $root 'VERSION') -Value '9.9.9' -Encoding utf8
        }
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
            Version      = Join-Path $root 'VERSION'
            Prereq       = $prereq
            # Absent unless a case writes one, which is the ordinary state on a machine where no
            # review surface has ever been opened. Passed explicitly by Get-Digest for the same
            # reason every other path is: unset, it would resolve to the live store belonging to
            # whoever is running the suite, and their own open surfaces would decide these cases.
            LavishState  = Join-Path $root 'lavish\state.json'
        }
    }

    # One session row in lavish-axi's own shape. Only the fields the digest reads are written, and
    # each is omittable, because the cases below need to drive an absent one as well as a present.
    function New-LavishStore {
        param(
            [Parameter(Mandatory)]$Fixture,
            [Parameter(Mandatory)][AllowEmptyCollection()][array]$Sessions,
            [switch]$NoSessionsField,
            [string]$RawText
        )
        New-Item -ItemType Directory -Force -Path (Split-Path $Fixture.LavishState -Parent) | Out-Null
        if ($PSBoundParameters.ContainsKey('RawText')) {
            Set-Content -LiteralPath $Fixture.LavishState -Value $RawText -Encoding utf8
            return $Fixture.LavishState
        }

        $map = [ordered]@{}
        $i = 0
        foreach ($s in $Sessions) {
            $map["key$i"] = $s
            $i++
        }
        $store = if ($NoSessionsField) { [ordered]@{ version = 1 } } else { [ordered]@{ sessions = $map } }
        $store | ConvertTo-Json -Depth 6 |
            Set-Content -LiteralPath $Fixture.LavishState -Encoding utf8
        $Fixture.LavishState
    }

    function New-LavishSession {
        param([string]$File, $Pending, [string]$Status = 'open', [string]$Updated = '2026-09-16T11:34:32Z')
        $row = [ordered]@{ file = $File; status = $Status; updated_at = $Updated }
        if ($PSBoundParameters.ContainsKey('Pending')) { $row['pending_prompts'] = $Pending }
        $row
    }

    # Every path is passed explicitly, including Instructions and Version. An omitted parameter
    # falls back to Get-KingshandHome, which would read the live instructions.md belonging to
    # whoever is running the suite - their own standing preferences, printed into test output - and
    # the live VERSION, which would make the version line pass whatever the fixture holds.
    function Get-Digest {
        param([Parameter(Mandatory)]$Fixture, [switch]$Json, [switch]$ResolveLavishStatePath)
        $lavish = @{}
        if (-not $ResolveLavishStatePath) { $lavish['LavishStatePath'] = $Fixture.LavishState }
        & $script:DigestScript `
            -DataPath         $Fixture.Data `
            -StatePath        $Fixture.State `
            -RegistryPath     $Fixture.Registry `
            -BudgetPath       $Fixture.Budget `
            -InstructionsPath $Fixture.Instructions `
            -VersionPath      $Fixture.Version `
            -PrereqScript     $Fixture.Prereq `
            -QueueRoot        $Fixture.Root `
            @lavish `
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

# regency's rule used to be "record it, never answer it". This change deliberately overrides it: a
# decision a worker wrote into its report may be answered in the King's stead on `petition`'s
# reversibility test. The digest is the Hand's first input in exactly that scenario, and CLAUDE.md
# tells it to trust the digest rather than re-read the fleet behind it - so a digest still carrying
# the old prohibition reinstates the overridden rule before `regency` is ever loaded, and a worker
# parked on a reversible decision sits until morning.
Describe 'the away block routes a parked decision instead of forbidding an answer' {
    BeforeAll {
        $script:Away = New-Fixture 'away'
        Set-Content -Path (Join-Path $script:Away.Root 'state\.afk') -Encoding utf8 `
            -Value @('since: 2026-09-04T08:33:19.8396570Z')
        $script:AwayText = Get-Digest $script:Away
    }

    It 'reports the regency and points at the skill carrying the test rather than restating it' {
        $script:AwayText.Contains('AWAY: a regency is in force') | Should -BeTrue
        $script:AwayText.Contains('load `regency`') |
            Should -BeTrue -Because 'the digest points at the skill that owns the reversibility test'
        $script:AwayText.Contains('reversib') |
            Should -BeFalse -Because 'petition owns that test and the digest never restates it'
    }

    It 'does not tell the Hand never to answer a worker''s question' {
        $script:AwayText |
            Should -Not -Match "never answer a worker's question" `
            -Because 'that is the rule this change overrides, and the digest is read before regency'
    }

    It 'keeps the blocked-prompt floor and routes a report''s decision to petition' {
        $script:AwayText.Contains('never answer a prompt a worker is blocked on') |
            Should -BeTrue -Because 'the floor on an interactive prompt is untouched by the override'
        $script:AwayText.Contains('decided under `petition`') |
            Should -BeTrue -Because 'a decision written into a report is decided, not left parked'
    }

    It 'stays two lines rather than growing into a paragraph' {
        $lines = @($script:AwayText -split "`r?`n")
        $i = [array]::FindIndex($lines, [Predicate[string]] { $args[0] -match 'AWAY: a regency is in force' })
        $i | Should -Not -Be -1 -Because 'the away flag has to surface at all'
        $lines[$i + 1] | Should -Match 'Batch everything that does not need them'
        $lines[$i + 2] |
            Should -Not -Match 'petition|blocked on' -Because 'the block is two lines, not a paragraph'
    }

    It 'says nothing about a regency when the flag is absent' {
        $bare = Get-Digest (New-Fixture 'no-away')
        $bare.Contains('AWAY:') |
            Should -BeFalse -Because 'the block is the flag''s consequence, not a permanent heading'
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

# The digest is this session's whole picture of the fleet, and CLAUDE.md tells the Hand to trust it
# rather than re-read the fleet behind it. A worker parked on a decision the King owes has settled,
# so it is live and idle and prints identically to one still working - crew.json's pointer is the
# only thing that separates them, and dropping it from the line puts the guess back on the surface
# the field was added to take it off.
Describe 'a worker parked on a decision is not printed as a worker still working' {
    BeforeAll {
        $script:Parked = New-Fixture 'parked'
        @{
            workers = @{
                'w-parked'  = @{ ticket = 'T-1001'; kind = 'ticket'; repo = 'acme-web'; stage = 'implementing'
                                 waiting_on = 'T-1001-shorter-hero-copy' }
                'w-running' = @{ ticket = 'T-1002'; kind = 'ticket'; repo = 'acme-api'; stage = 'implementing' }
            }
        } | ConvertTo-Json -Depth 10 | Set-Content -Path $script:Parked.State -Encoding utf8
        $script:ParkedText = Get-Digest $script:Parked
    }

    It 'names the decision the parked worker stopped on, on its own line' {
        $line = @($script:ParkedText -split "`r?`n" | Where-Object { $_ -match '^\s*- w-parked ' })[0]
        $line | Should -Not -BeNullOrEmpty -Because 'a recorded worker is always listed'
        $line.Contains('last parked on decision T-1001-shorter-hero-copy') |
            Should -BeTrue -Because 'the pointer is the only thing that separates it from a worker making progress'
    }

    # The pointer is never cleared, so it names that key for the rest of the worker's life. A line
    # that asserted a live park would tell the King a decision is waiting on him that he answered
    # hours ago - on the surface CLAUDE.md tells the Hand to trust without re-reading the fleet.
    It 'says the park is the last one rather than asserting it is still open' {
        $line = @($script:ParkedText -split "`r?`n" | Where-Object { $_ -match '^\s*- w-parked ' })[0]
        $line -match ',\s*parked on decision' |
            Should -BeFalse -Because 'a worker answered hours ago still carries this key'
    }

    It 'adds nothing to the line of a worker that has never parked' {
        $line = @($script:ParkedText -split "`r?`n" | Where-Object { $_ -match '^\s*- w-running ' })[0]
        $line | Should -Not -BeNullOrEmpty
        $line.Contains('parked on decision') |
            Should -BeFalse -Because 'a null pointer is never parked, not parked on nothing'
    }

    It 'still renders without throwing, which is the whole contract of this script' {
        { Get-Digest $script:Parked } | Should -Not -Throw
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

    # The permission is standing authority to merge to a branch that may deploy on merge, and the
    # digest is the King's whole picture of the fleet at session open. Without this an entry
    # carrying it printed byte-identical to one that did not.
    It 'says so on an entry carrying the merge permission, and stays silent on one that does not' {
        $f = New-Fixture 'registry-merge'
        foreach ($n in @('alpha', 'beta')) {
            New-Item -ItemType Directory -Force -Path (Join-Path $f.Root "repos\$n") | Out-Null
        }
        Add-RegistryEntry $f '- alpha [no-mistakes +yolo +merge] - alpha repo (added 2026-01-01)' (Join-Path $f.Root 'repos\alpha')
        Add-RegistryEntry $f '- beta [no-mistakes +yolo] - beta repo (added 2026-01-02)' (Join-Path $f.Root 'repos\beta')
        $text = Get-Digest $f
        $text.Contains('- alpha [no-mistakes] yolo on +merge') | Should -BeTrue
        $text.Contains('- beta [no-mistakes] yolo on -') |
            Should -BeTrue -Because 'a project without the permission prints exactly as it always has'
        $text.Contains('- beta [no-mistakes] yolo on +merge') | Should -BeFalse
    }

    # An annotation the parser could not read in full never yields the permission, so the digest
    # must not announce one either - this is the surface the King would trust it from.
    It 'does not announce merge on an entry whose annotation could not be read in full' {
        $f = New-Fixture 'registry-merge-unreadable'
        New-Item -ItemType Directory -Force -Path (Join-Path $f.Root 'repos\alpha') | Out-Null
        Add-RegistryEntry $f '- alpha [no-mistakes garbage +merge] - alpha repo (added 2026-01-01)' (Join-Path $f.Root 'repos\alpha')
        (Get-Digest $f).Contains('+merge') | Should -BeFalse
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

    # The registry is maintained by hand as well as by /annex, and a name the index cannot turn into
    # a file name fails one brief at a time, always after the brief is on disk. Said here instead,
    # and said without taking the digest down: reading the registry may not throw.
    It 'flags a hand-written project name the index cannot resolve, without failing the digest' {
        $f = New-Fixture 'registry-unindexable'
        New-Item -ItemType Directory -Force -Path (Join-Path $f.Root 'repos\web') | Out-Null
        Add-RegistryEntry $f '- @acme/web [local-only] - a hand-written entry (added 2026-01-01)' (Join-Path $f.Root 'repos\web')

        $text = Get-Digest $f
        $text.Contains('Projects: 1 registered') |
            Should -BeTrue -Because 'the entry is flagged, not dropped - the user did register it'
        $text.Contains('NAME NOT INDEXABLE') |
            Should -BeTrue -Because 'the mismatch has to be visible before a brief is written for it'
        $text.Contains('@acme/web') | Should -BeTrue
    }

    It 'leaves a slug-shaped name unflagged' {
        $script:RegText.Contains('NAME NOT INDEXABLE') |
            Should -BeFalse -Because 'every fixture name here is one the index can resolve'
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

    # Exactly one problem is the ordinary shape, and it was the broken one: assigning from an `if`
    # unrolled the single-element array to a bare string, so the guard below it threw under strict
    # mode. The problem line was printed and then the section reported itself unable to run - a
    # check that HAD run, and had found precisely one thing.
    It 'does not report itself unable to run when it ran and found one problem' {
        $broken = New-Fixture 'prereq-single' -FailingPrereqs
        $text   = Get-Digest $broken
        $text.Contains('could not run the toolchain check') |
            Should -BeFalse -Because 'the check ran; saying otherwise discards its verdict'
        $text.Contains('named nothing') |
            Should -BeFalse -Because 'it named exactly one thing'
    }

    It 'prints every problem when the check finds more than one' {
        $f = New-Fixture 'prereq-many' -FailingPrereqs
        Set-Content -Path $f.Prereq -Encoding utf8 -Value @(
            'Write-Host "FAILED:"'
            'Write-Host "  - lavish-axi not found. Run: npm install -g lavish-axi"'
            'Write-Host "  - herdr not found. Run: npm install -g herdr"'
            'exit 1'
        )
        $text = Get-Digest $f
        $text.Contains('PREREQS: lavish-axi not found') | Should -BeTrue
        $text.Contains('PREREQS: herdr not found')      | Should -BeTrue
        $text.Contains('could not run the toolchain check') | Should -BeFalse
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

Describe 'the index reaches the session as a location and two counts, never as content' {
    # A settled brand spec sat in data\ while the site it described shipped with none of it. The
    # digest is where a fresh session learns the index exists at all, so what it must carry is where
    # to look and how far the index has drifted from what is on disk - and what it must NOT carry is
    # any of the files, because paying for them at every session open is how a bounded digest stops
    # being bounded.
    BeforeAll {
        function Add-IndexedFile {
            param(
                [Parameter(Mandatory)]$Fixture,
                [Parameter(Mandatory)][string]$Relative,
                [Parameter(Mandatory)][string]$Summary,
                [string]$Project,
                [string]$Body = 'body'
            )
            Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'bin\Index.psm1') -Force
            Write-DataFile -Path $Relative -Content $Body -Summary $Summary -Project $Project -DataPath $Fixture.Data | Out-Null
        }
    }

    It 'says nothing at all on an installation with no index and nothing to index' {
        $f = New-Fixture 'index-fresh'
        (Get-Digest $f).Contains('INDEX') |
            Should -BeFalse -Because 'a fresh installation is a state, not a fault, and an empty section is not news'
    }

    It 'names where the index lives and how much it covers' {
        $f = New-Fixture 'index-present'
        Add-IndexedFile -Fixture $f -Relative 'data\brand.md' -Summary 'settled brand: logo, favicon, tagline' -Project 'emgeelabs-site'
        $text = Get-Digest $f
        $text.Contains("INDEX  ($($f.Data)\index.md, and index\<project>.md per project)") |
            Should -BeTrue -Because 'a session that cannot find the index cannot read it'
        $text.Contains('1 file listed across 1 index - read the one for a project before writing a brief against it.') |
            Should -BeTrue
    }

    It 'reports drift as a count, and never as a list of files' {
        $f = New-Fixture 'index-drift'
        Add-IndexedFile -Fixture $f -Relative 'data\brand.md' -Summary 'settled brand' -Project 'emgeelabs-site'
        Set-Content -Path (Join-Path $f.Data 'nobody-listed-me.md') -Value 'x' -Encoding utf8
        Set-Content -Path (Join-Path $f.Data 'nor-me.md')           -Value 'x' -Encoding utf8
        $text = Get-Digest $f

        $text.Contains('UNINDEXED: 2 files are listed nowhere. Index each as you touch it.') |
            Should -BeTrue -Because 'the count is what makes the gap visible without paying for a list'
        $text.Contains('nobody-listed-me.md') |
            Should -BeFalse -Because 'a digest that grows with the drift is the bulk this section avoids'
    }

    It 'reports an indexed file that has gone as stale' {
        $f = New-Fixture 'index-stale'
        Add-IndexedFile -Fixture $f -Relative 'data\gone.md' -Summary 'deleted since' -Project 'acme'
        Remove-Item -LiteralPath (Join-Path $f.Data 'gone.md') -Force
        (Get-Digest $f).Contains('STALE: 1 indexed file is no longer on disk.') | Should -BeTrue
    }

    It 'prints no line from any indexed file, only its count' {
        $f = New-Fixture 'index-not-content'
        Add-IndexedFile -Fixture $f -Relative 'data\brand.md' -Summary 'settled brand' `
            -Project 'emgeelabs-site' -Body 'the accent is deep teal and amber was rejected'
        $text = Get-Digest $f
        $text.Contains('amber was rejected') |
            Should -BeFalse -Because 'the file is read at brief-writing time, not paid for at every session open'
        $text.Contains('settled brand') |
            Should -BeFalse -Because 'even the one-line summaries are the index''s job, not the digest''s'
    }

    It 'is not accounted against the startup-memory budget' {
        # 900 bytes of index against a budget of 10 tokens. An index that counted would report an
        # overrun, and an overrun tells the Hand to run /chronicle - a curation pass over files this
        # is not one of.
        $f = New-Fixture 'index-unbudgeted'
        Set-Content -Path $f.Budget -Value '10' -NoNewline -Encoding utf8
        Add-IndexedFile -Fixture $f -Relative 'data\big.md' -Summary ('x' * 150) -Project 'acme' -Body ('y' * 900)
        $text = Get-Digest $f
        $text.Contains('STARTUP_MEMORY_BUDGET:') |
            Should -BeFalse -Because 'the budget measures the two curated memory files and nothing else'
        $text.Contains('  Startup memory: 0 of 10 estimated tokens.') | Should -BeTrue
    }

    It 'degrades with a diagnostic rather than throwing when the index location is malformed' {
        $f = New-Fixture 'index-malformed'
        New-Item -ItemType Directory -Force -Path (Join-Path $f.Data 'index.md') | Out-Null
        Set-Content -Path (Join-Path $f.Data 'orphan.md') -Value 'x' -Encoding utf8
        { Get-Digest $f } | Should -Not -Throw
        $text = Get-Digest $f
        $text.Contains('No index exists yet.') |
            Should -BeTrue -Because 'a malformed location is an ordinary state, not an error'
        $text.Contains('UNINDEXED: 1 file is listed nowhere.') | Should -BeTrue
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

# A user who cannot say which version they are on cannot say whether a fix they were promised is
# in it. The line is one line by design, and an unreadable VERSION file reads as unreadable: a
# number invented here is a number the reader would quote back as the version they are running.
Describe 'the digest says which version this installation is' {
    It 'prints the version on one VERSION: line' {
        $text = Get-Digest (New-Fixture 'version')
        $text.Contains('VERSION: 9.9.9') |
            Should -BeTrue -Because 'the version comes from the file, not from anywhere else'
        @($text -split "`n" | Where-Object { $_ -match '^VERSION:' }).Count |
            Should -Be 1 -Because 'it is one line of a bounded digest, not a section'
    }

    It 'says unreadable, and no version at all, when the file is not there' {
        $text = Get-Digest (New-Fixture 'noversion' -NoVersionFile)
        $text.Contains('VERSION: unreadable') | Should -BeTrue
        $text.Contains('There is no VERSION file at') |
            Should -BeTrue -Because 'the reason belongs on the line, so the reader can act on it'
        $text | Should -Not -Match 'VERSION: \d' -Because 'a fabricated version would be trusted'
    }

    It 'still renders every other section when the version cannot be read' {
        $f = New-Fixture 'noversion-rest' -NoVersionFile
        { Get-Digest $f } | Should -Not -Throw
        foreach ($section in @('FLEET', 'QUEUE', 'CONTEXT')) {
            (Get-Digest $f).Contains($section) |
                Should -BeTrue -Because "one unreadable file must cost one line, not the digest: $section"
        }
    }
}

# --------------------------------------------------------------------------------------------
# RE-ARM. A background job belongs to the session that armed it, so a restart takes the usage
# pulse and every review-surface poll with it. Both failures are silent by construction: a
# changed-only pulse that has stopped produces the same output as one with nothing to say -
# nothing - and a surface whose poll is gone looks exactly like a King who has not answered yet.
# Neither is visible in the fleet, which is why the digest has to carry them.
# --------------------------------------------------------------------------------------------
Describe 'the digest says how to re-arm the usage pulse' {
    BeforeAll { $script:Pulse = Get-Digest (New-Fixture 're-arm-pulse') }

    It 'carries a runnable arming command rather than a reminder to remember one' {
        $script:Pulse.Contains('RE-ARM') | Should -BeTrue
        $script:Pulse | Should -Match 'Import-Module .*bin\\Usage\.psm1'
        $script:Pulse.Contains('Watch-UsagePulse') |
            Should -BeTrue -Because 'the Hand copies the block, so it has to be runnable'
    }

    # R-002. Three ticks at the default cadence is thirty minutes against a session lasting hours,
    # and the silence after the last tick is the same silence a working pulse produces - so a
    # finite count reinstates the bug on a delay rather than fixing it.
    It 'arms it for the whole session rather than for a set number of ticks' {
        $script:Pulse | Should -Match 'It runs until the session ends rather than for a set number of ticks'
        $script:Pulse | Should -Not -Match 'Watch-UsagePulse\s+-Count' `
            -Because 'a count is a promise to go quiet at a moment nobody will notice'
    }

    # R-006, bounded. One line at arming time, because silence is the pulse working and a reader
    # who never saw it start cannot tell that from a pulse that never did.
    It 'asks for one line saying the pulse is on' {
        $script:Pulse | Should -Match 'say in one line that it is on'
        $script:Pulse | Should -Match 'a quiet\s+pulse and a dead one look the same from the outside'
    }

    # R-005, and it is the reason this is a printed command rather than a decision. instructions.md
    # is open-ended prose somebody wrote by hand; nothing in bin\ may match a phrase out of it, so
    # the digest prints the command unconditionally and the Hand decides from having read the file.
    It 'prints the command unchanged when the King has switched the pulse off' {
        $f = New-Fixture 're-arm-off'
        Set-Content -Path $f.Instructions -Encoding utf8 `
            -Value @('# Standing instructions', '', '- No usage pulse. Keep it off.')
        $text = Get-Digest $f

        $text.Contains('Watch-UsagePulse') |
            Should -BeTrue -Because 'nothing in bin\ reads that file, so nothing in bin\ can act on it'
        $text | Should -Match 'Whether to arm it at all is yours'
        $text.Contains('No usage pulse. Keep it off.') |
            Should -BeTrue -Because 'the Hand decides it from the file, which is printed whole'
    }
}

# The other half, and the one the King loses something to. lavish-axi ships no command that lists
# its sessions, so its own store is the one place the answer exists. Queued feedback is the signal
# rather than an open session: nothing ends a session when its decision is settled, so `open`
# accumulates for good, while a queued prompt is his answer sitting where nobody is listening.
Describe 'the digest names review surfaces holding feedback nobody collected' {
    It 'names a surface with queued feedback, with the path a poll needs' {
        $f = New-Fixture 'surface-queued'
        New-LavishStore -Fixture $f -Sessions @(
            (New-LavishSession -File (Join-Path $f.Data 'kh-thing\gate.html') -Pending 2 -Status 'feedback')
        ) | Out-Null
        $text = Get-Digest $f

        $text | Should -Match '1 of 1 .* hold feedback nobody has'
        $text.Contains('2 queued, status feedback') | Should -BeTrue
        $text.Contains((Join-Path $f.Data 'kh-thing\gate.html')) |
            Should -BeTrue -Because 'the poll takes an absolute path and nothing else has told the Hand it'
        $text | Should -Match '`muster`''s `## The review surface` owns what a return means'
    }

    # muster's `## The review surface`: a return whose session has ended is the one with nothing to
    # re-arm. Its final feedback was delivered once and polling stops after it, so naming it under
    # "re-run the poll on each" sends the reply into a closed session nobody reads and gets the same
    # ended result straight back. Not dropped in silence either - on this machine two of these have
    # sat holding a message since early September, and a row quietly removed is evidence lost.
    It 'keeps an ended session out of the re-poll list and still says it is holding something' {
        $f = New-Fixture 'surface-ended'
        $gone = Join-Path $f.Data 'kh-ended\gate.html'
        New-LavishStore -Fixture $f -Sessions @(
            (New-LavishSession -File $gone -Pending 1 -Status 'ended')
        ) | Out-Null
        $text = Get-Digest $f

        $text.Contains($gone) |
            Should -BeFalse -Because 'polling an ended session re-arms nothing, which is muster''s rule'
        $text | Should -Not -Match 'Re-run the poll on each named'
        $text | Should -Match '1 more ended holding feedback nobody collected'
        $text | Should -Match 'polling an\s+ended session re-arms nothing'
        $text | Should -Match 'goes\s+in chat instead' `
            -Because 'the decision is still open and now has no surface to decide it on'
    }

    # The other side of the same split, on one store, so the counts are shown telling them apart
    # rather than each branch being shown alone.
    It 'still names an open surface beside an ended one and counts the ended one separately' {
        $f = New-Fixture 'surface-ended-and-open'
        $live = Join-Path $f.Data 'kh-live\gate.html'
        $gone = Join-Path $f.Data 'kh-gone\gate.html'
        New-LavishStore -Fixture $f -Sessions @(
            (New-LavishSession -File $live -Pending 1 -Status 'open'),
            (New-LavishSession -File $gone -Pending 1 -Status 'ended')
        ) | Out-Null
        $text = Get-Digest $f

        $text | Should -Match '1 of 2 .* hold feedback nobody has'
        $text.Contains($live) | Should -BeTrue
        $text.Contains($gone) | Should -BeFalse
        $text | Should -Match '1 more ended holding feedback nobody collected'
    }

    # The direction the doubt is resolved in, and it is deliberate: polling a surface that did not
    # need it costs a moment, dropping one that did costs the King's answer. So only the tool's own
    # exact word is treated as ended - a status it did not give, and one spelled any other way,
    # both stay on the list.
    It 'keeps a surface whose status is missing or is not exactly ended on the list' {
        $f = New-Fixture 'surface-not-ended'
        $none  = Join-Path $f.Data 'kh-nostatus\gate.html'
        $cased = Join-Path $f.Data 'kh-cased\gate.html'
        $row = New-LavishSession -File $none -Pending 1
        $row.Remove('status')
        New-LavishStore -Fixture $f -Sessions @(
            $row,
            (New-LavishSession -File $cased -Pending 1 -Status 'Ended')
        ) | Out-Null
        $text = Get-Digest $f

        $text | Should -Match '2 of 2 .* hold feedback nobody has'
        $text.Contains($none) |
            Should -BeTrue -Because 'a status the store did not give is not the store saying ended'
        $text.Contains($cased) |
            Should -BeTrue -Because 'the exact word is the match, and anything else is not it'
        $text | Should -Not -Match 'more ended holding feedback'
    }

    # The store belongs to lavish-axi. The digest reads it for one fact and must leave it exactly
    # as it found it - a hook that corrupted another tool's own record before the session had even
    # started would be a failure nobody could trace back here. Observed from the file rather than
    # argued from the source: same bytes, same modification time, and the surface named proves the
    # run actually opened it.
    It 'leaves the session store exactly as it found it' {
        $f = New-Fixture 'surface-readonly'
        $gate = Join-Path $f.Data 'kh-ro\gate.html'
        New-LavishStore -Fixture $f -Sessions @(
            (New-LavishSession -File $gate -Pending 1 -Status 'feedback')
        ) | Out-Null

        $stat = {
            $i = Get-Item -LiteralPath $f.LavishState
            "$((Get-FileHash -LiteralPath $f.LavishState -Algorithm SHA256).Hash)|$($i.LastWriteTimeUtc.Ticks)|$($i.Length)"
        }
        $before = & $stat
        $text = Get-Digest $f
        $after = & $stat

        $text.Contains($gate) |
            Should -BeTrue -Because 'a store the run never opened would be unchanged for the wrong reason'
        $after | Should -Be $before -Because 'the digest reads another tool''s record and never writes it'
    }

    # An open session is not evidence anyone is waiting. Counting them keeps the digest honest
    # about what it looked at without turning dozens of settled decisions into a to-do list.
    It 'counts a surface with nothing queued rather than naming it' {
        $f = New-Fixture 'surface-quiet'
        $quiet = Join-Path $f.Data 'kh-quiet\gate.html'
        New-LavishStore -Fixture $f -Sessions @(
            (New-LavishSession -File $quiet -Pending 0 -Status 'open')
        ) | Out-Null
        $text = Get-Digest $f

        $text | Should -Match 'none of the 1 .* is holding feedback nobody'
        $text | Should -Match 'nothing\s+ends one when its decision is settled'
        $text.Contains($quiet) |
            Should -BeFalse -Because 'a settled decision named at every session start is noise, not work'
    }

    It 'leaves alone a session whose file is outside this installation''s data directory' {
        $f = New-Fixture 'surface-elsewhere'
        New-LavishStore -Fixture $f -Sessions @(
            (New-LavishSession -File (Join-Path $TestDrive 'somewhere-else\gate.html') -Pending 4)
        ) | Out-Null
        $text = Get-Digest $f

        $text | Should -Match 'none of the 0 '
        $text.Contains('4 queued') |
            Should -BeFalse -Because 'another tool''s review surfaces are not this fleet''s work'
    }

    # Criterion 7, and the failure it is for: zero means nobody sent anything, which is a settled
    # fact this section may be quiet about. A field that is absent or is not a whole number is the
    # tool not answering, and reading that as zero drops the King's own reply out of the digest.
    It 'lists a surface whose queued count could not be read, and says so' {
        $f = New-Fixture 'surface-unreadable-count'
        $a = Join-Path $f.Data 'kh-a\gate.html'
        $b = Join-Path $f.Data 'kh-b\gate.html'
        New-LavishStore -Fixture $f -Sessions @(
            (New-LavishSession -File $a -Status 'open'),
            (New-LavishSession -File $b -Pending 'lots' -Status 'open')
        ) | Out-Null
        $text = Get-Digest $f

        $text | Should -Match '2 of 2 .* hold feedback nobody has'
        @($text -split "`n" | Where-Object { $_.Contains('queued count unreadable') }).Count |
            Should -Be 2 -Because 'an absent count and an unparseable one are both the tool not answering'
        $text.Contains($a) | Should -BeTrue
        $text.Contains($b) | Should -BeTrue
    }

    It 'says the status the tool gave it, and says so plainly when it gave none' {
        $f = New-Fixture 'surface-no-status'
        $row = New-LavishSession -File (Join-Path $f.Data 'kh-c\gate.html') -Pending 1
        $row.Remove('status')
        New-LavishStore -Fixture $f -Sessions @($row) | Out-Null

        (Get-Digest $f).Contains('1 queued, status status not given') |
            Should -BeTrue -Because 'the digest does not own that vocabulary and never invents a word for it'
    }

    It 'says so when the tool gave no time, rather than printing a made-up one' {
        $f = New-Fixture 'surface-no-stamp'
        $row = New-LavishSession -File (Join-Path $f.Data 'kh-e\gate.html') -Pending 1
        $row.Remove('updated_at')
        New-LavishStore -Fixture $f -Sessions @($row) | Out-Null

        (Get-Digest $f).Contains('status open, last touched not given') |
            Should -BeTrue -Because 'a time nobody gave is not a time to fill in'
    }

    It 'does not count a session that names no file as one of this installation''s' {
        $f = New-Fixture 'surface-no-file'
        $row = New-LavishSession -File (Join-Path $f.Data 'kh-f\gate.html') -Pending 1
        $row['file'] = ''
        New-LavishStore -Fixture $f -Sessions @($row) | Out-Null
        $text = Get-Digest $f

        $text | Should -Match 'none of the 0 ' `
            -Because 'a session with no path cannot be shown to be ours, and a poll could not take it'
        $text.Contains('1 queued') | Should -BeFalse
    }

    It 'renders the timestamp one unambiguous way rather than in the machine''s date format' {
        $f = New-Fixture 'surface-stamp'
        New-LavishStore -Fixture $f -Sessions @(
            (New-LavishSession -File (Join-Path $f.Data 'kh-d\gate.html') -Pending 1 `
                               -Updated '2026-09-16T11:34:32.101Z')
        ) | Out-Null

        (Get-Digest $f).Contains('2026-09-16 11:34:32Z') |
            Should -BeTrue -Because '09/16/2026 is two different days depending on who reads it'
    }

    It 'stays bounded when a machine has more surfaces than the digest may print' {
        $f = New-Fixture 'surface-many'
        New-LavishStore -Fixture $f -Sessions @(
            0..29 | ForEach-Object {
                New-LavishSession -File (Join-Path $f.Data "kh-$_\gate.html") -Pending 1
            }
        ) | Out-Null
        $text = Get-Digest $f

        $text | Should -Match '30 of 30 .* hold feedback nobody has'
        $text.Contains('... and 5 more') |
            Should -BeTrue -Because 'the tail is counted rather than printed, as every other list here is'
    }
}

# Every one of these is an answer the digest must not give confidently. "No surface is waiting" is
# the one sentence a broken reader would produce by accident, and it is indistinguishable from the
# truth - so each failure says what could not be read instead.
Describe 'a session store that cannot be read says so rather than saying nothing is waiting' {
    It 'says no store exists rather than that nothing is waiting' {
        $f = New-Fixture 'store-absent'
        $text = Get-Digest $f
        $text.Contains('no session store at') | Should -BeTrue
        $text | Should -Match 'there is nothing to re-arm'
        $text | Should -Not -Match 'hold feedback nobody has'
    }

    It 'names the failure when the store is not the JSON it reads' {
        $f = New-Fixture 'store-garbage'
        New-LavishStore -Fixture $f -Sessions @() -RawText 'this is not json {{{' | Out-Null
        $text = Get-Digest $f

        $text | Should -Match 'could not be read'
        $text | Should -Not -Match 'none of the \d+ ' `
            -Because 'a store nobody could parse is not a store saying nothing is waiting'
    }

    It 'tells a store that named no sessions from a store that said there are none' {
        $f = New-Fixture 'store-no-field'
        New-LavishStore -Fixture $f -Sessions @() -NoSessionsField | Out-Null
        $text = Get-Digest $f

        $text | Should -Match 'named no sessions at all'
        $text | Should -Match 'which surfaces are open was not established'

        $g = New-Fixture 'store-empty-map'
        New-LavishStore -Fixture $g -Sessions @() | Out-Null
        (Get-Digest $g) | Should -Match 'none of the 0 ' `
            -Because 'an empty map is the tool affirmatively saying there are none'
    }

    It 'renders every other section when the store cannot be read' {
        $f = New-Fixture 'store-garbage-rest'
        New-LavishStore -Fixture $f -Sessions @() -RawText '[[[' | Out-Null
        { Get-Digest $f } | Should -Not -Throw
        foreach ($section in @('FLEET', 'RE-ARM', 'QUEUE', 'CONTEXT')) {
            (Get-Digest $f).Contains($section) |
                Should -BeTrue -Because "one unreadable file must cost one line, not the digest: $section"
        }
    }
}

# The default nobody passes is the one the hook uses, so it is the one that has to work. Both
# branches of it are the tool's own documented pair - its override variable first, the home
# directory second - and neither is exercised by any other case, because every other case passes
# the path explicitly to keep the suite off the live store.
Describe 'the store path resolves the way lavish-axi resolves it' {
    BeforeAll {
        $script:SavedStateDir = $env:LAVISH_AXI_STATE_DIR
        $script:SavedProfile  = $env:USERPROFILE
    }
    AfterAll {
        $env:LAVISH_AXI_STATE_DIR = $script:SavedStateDir
        $env:USERPROFILE          = $script:SavedProfile
    }

    It 'takes LAVISH_AXI_STATE_DIR when it is set' {
        $f = New-Fixture 'resolve-statedir'
        New-LavishStore -Fixture $f -Sessions @(
            (New-LavishSession -File (Join-Path $f.Data 'kh-env\gate.html') -Pending 1)
        ) | Out-Null

        $env:LAVISH_AXI_STATE_DIR = Split-Path $f.LavishState -Parent
        $env:USERPROFILE          = Join-Path $TestDrive 'no-such-profile'
        (Get-Digest $f -ResolveLavishStatePath).Contains((Join-Path $f.Data 'kh-env\gate.html')) |
            Should -BeTrue -Because 'the tool honours that variable, so this has to honour it too'
    }

    It 'falls back to the home directory when it is not' {
        $f = New-Fixture 'resolve-profile'
        $fakeHome = Join-Path $f.Root 'profile'
        New-Item -ItemType Directory -Force -Path (Join-Path $fakeHome '.lavish-axi') | Out-Null
        ([ordered]@{ sessions = [ordered]@{ k = (New-LavishSession `
            -File (Join-Path $f.Data 'kh-home\gate.html') -Pending 1) } } | ConvertTo-Json -Depth 6) |
            Set-Content -LiteralPath (Join-Path $fakeHome '.lavish-axi\state.json') -Encoding utf8

        Remove-Item Env:\LAVISH_AXI_STATE_DIR -ErrorAction SilentlyContinue
        $env:USERPROFILE = $fakeHome
        (Get-Digest $f -ResolveLavishStatePath).Contains((Join-Path $f.Data 'kh-home\gate.html')) |
            Should -BeTrue -Because 'that is where the tool keeps it when nothing overrides the location'
    }

    It 'says there is nowhere to look rather than inventing a path' {
        $f = New-Fixture 'resolve-nothing'
        Remove-Item Env:\LAVISH_AXI_STATE_DIR -ErrorAction SilentlyContinue
        $env:USERPROFILE = ''
        $text = Get-Digest $f -ResolveLavishStatePath

        $text | Should -Match 'no home directory to resolve lavish-axi''s session store against'
        $text | Should -Not -Match 'none of the \d+ ' `
            -Because 'a path invented here holds nothing, which reads as nothing being waited on'
    }
}
