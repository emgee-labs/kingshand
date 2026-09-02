BeforeAll {
    # Dot-sourced, not dispatched. The base-resolution rule lives in its own file precisely so
    # it can be exercised against throwaway repositories without spawning a real worker into
    # one. The dispatch block at the bottom of this file does run Dispatch-Worker.ps1, but only
    # against a herdr that is a shim on PATH - nothing there ever launches Claude Code.
    . "$PSScriptRoot\..\bin\Resolve-BaseRef.ps1"

    $script:TempFixtures = [System.Collections.Generic.List[string]]::new()

    function New-TempFixturePath {
        param([Parameter(Mandatory)][string]$Prefix)
        $p = Join-Path ([System.IO.Path]::GetTempPath()) ($Prefix + [guid]::NewGuid().ToString('N'))
        $script:TempFixtures.Add($p)
        $p
    }

    function New-TempRepo {
        param([string]$Branch = 'main', [switch]$WithOrigin, [switch]$Empty)
        $d = New-TempFixturePath -Prefix 'baseref-'
        git init -b $Branch $d -q
        git -C $d config user.name  'Test'
        git -C $d config user.email 'test@example.invalid'
        if (-not $Empty) {
            Set-Content -Path (Join-Path $d 'base.txt') -Value 'base' -Encoding utf8
            git -C $d add -A
            git -C $d commit -q -m 'Initial commit'
        }
        if ($WithOrigin) {
            $bare = "$d-remote.git"
            $script:TempFixtures.Add($bare)
            git init --bare -b $Branch $bare -q
            git -C $d remote add origin $bare
            if (-not $Empty) { git -C $d push -q origin $Branch 2>&1 | Out-Null }
        }
        $d
    }

    function Test-RefResolves {
        param([string]$RepoPath, [string]$Ref)
        $null = & git -C $RepoPath rev-parse --verify --quiet "$Ref^{commit}" 2>$null
        $LASTEXITCODE -eq 0
    }
}

AfterAll {
    foreach ($p in $script:TempFixtures) {
        if (Test-Path -LiteralPath $p) {
            Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    $script:TempFixtures.Clear()
}

Describe 'Resolve-BaseRef - remoteless repository' {
    BeforeAll { $script:repo = New-TempRepo }

    It 'returns a ref that actually resolves' {
        $base = Resolve-BaseRef -RepoPath $script:repo
        Test-RefResolves -RepoPath $script:repo -Ref $base | Should -BeTrue
    }

    It 'returns the local default branch rather than an invented origin/ name' {
        $base = Resolve-BaseRef -RepoPath $script:repo
        $base | Should -Be 'main'
        $base | Should -Not -BeLike 'origin/*'
    }

    It 'returns the local default branch when it is not called main' {
        $trunk = New-TempRepo -Branch 'trunk'
        $base  = Resolve-BaseRef -RepoPath $trunk
        $base  | Should -Be 'trunk'
        Test-RefResolves -RepoPath $trunk -Ref $base | Should -BeTrue
    }
}

Describe 'Resolve-BaseRef - the evidence it makes possible' {
    # The regression this whole fix exists for: with an unresolvable base, `git log` and
    # `git diff` write fatal: to stderr and NOTHING to stdout, so the landing gate reads an
    # empty diff and an empty attribution scan as a clean pass. These assert the evidence is
    # really gathered, not merely that a string was returned.
    BeforeAll {
        # A remoteless repo with a branch standing in for the worker's, carrying the exact
        # trailer rule 3 forbids.
        $script:repo = New-TempRepo
        # Resolved first, in the same order dispatch does it: from the repo, before the
        # worker's branch exists.
        $script:base = Resolve-BaseRef -RepoPath $script:repo
        git -C $script:repo checkout -q -b 'worktree-probe'
        Set-Content -Path (Join-Path $script:repo 'thing.txt') -Value 'thing' -Encoding utf8
        git -C $script:repo add -A
        git -C $script:repo commit -q -m "Add thing`n`nCo-Authored-By: Claude <noreply@anthropic.com>"
    }

    It 'lets the attribution scan see a Co-Authored-By trailer it must catch' {
        $bodies = @(& git -C $script:repo --no-pager log --format='%B' "$($script:base)..HEAD" 2>$null)
        $hits = @($bodies | Select-String -Pattern 'claude|assistant|co-authored' -CaseSensitive:$false)
        $hits.Count | Should -BeGreaterThan 0
    }

    It 'produces a non-empty diff against the base' {
        $stat = @(& git -C $script:repo --no-pager diff --stat "$($script:base)...HEAD" 2>$null)
        $stat.Count | Should -BeGreaterThan 0
    }
}

Describe 'Resolve-BaseRef - repository with a remote' {
    It 'prefers origin/HEAD when the repo records one' {
        $repo = New-TempRepo -WithOrigin
        git -C $repo remote set-head origin -a 2>&1 | Out-Null
        $base = Resolve-BaseRef -RepoPath $repo
        $base | Should -Be 'origin/main'
        Test-RefResolves -RepoPath $repo -Ref $base | Should -BeTrue
    }

    It 'returns a resolving ref when there is a remote but no origin/HEAD' {
        $repo = New-TempRepo -WithOrigin
        git -C $repo symbolic-ref --delete refs/remotes/origin/HEAD 2>&1 | Out-Null
        $base = Resolve-BaseRef -RepoPath $repo
        Test-RefResolves -RepoPath $repo -Ref $base | Should -BeTrue
    }
}

Describe 'Resolve-BaseRef - a worker branch is never a base' {
    # Kingshand's workers branch as `worktree-<name>` - dispatch names them, and it is the one
    # place that name is chosen. `origin/HEAD` transiently pointed at one
    # during a multi-worker dispatch, and two workers were recorded with another worker's branch
    # as their base - so their landing diff and attribution scan would have measured against that
    # worker's unlanded commits rather than against the default branch.

    It 'falls back to the default when origin/HEAD points at a worktree- branch' {
        $repo = New-TempRepo -WithOrigin
        git -C $repo checkout -q -b 'worktree-other'
        Set-Content -Path (Join-Path $repo 'other.txt') -Value 'other' -Encoding utf8
        git -C $repo add -A
        git -C $repo commit -q -m 'Another worker commit'
        git -C $repo push -q origin 'worktree-other' 2>&1 | Out-Null
        git -C $repo checkout -q 'main'
        git -C $repo symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/worktree-other

        # The contaminated ref really does resolve - rejecting it is a rule, not a side effect
        # of it being missing.
        Test-RefResolves -RepoPath $repo -Ref 'origin/worktree-other' | Should -BeTrue

        $base = Resolve-BaseRef -RepoPath $repo
        $base | Should -Be 'origin/main'
        $base | Should -Not -BeLike '*worktree-*'
    }

    It 'falls back to the default when the local checkout is on a worktree- branch' {
        $repo = New-TempRepo
        git -C $repo checkout -q -b 'worktree-local'
        Set-Content -Path (Join-Path $repo 'local.txt') -Value 'local' -Encoding utf8
        git -C $repo add -A
        git -C $repo commit -q -m 'Worker commit'

        Test-RefResolves -RepoPath $repo -Ref 'worktree-local' | Should -BeTrue

        $base = Resolve-BaseRef -RepoPath $repo
        $base | Should -Be 'main'
        $base | Should -Not -BeLike '*worktree-*'
    }

    It 'leaves a branch that merely contains worktree- alone' {
        $repo = New-TempRepo -Branch 'feature/worktree-cleanup'
        $base = Resolve-BaseRef -RepoPath $repo
        $base | Should -Be 'feature/worktree-cleanup'
        Test-RefResolves -RepoPath $repo -Ref $base | Should -BeTrue
    }
}

Describe 'Resolve-BaseRef - refusal' {
    It 'throws rather than returning an unresolvable name when nothing resolves' {
        $empty = New-TempRepo -Empty
        { Resolve-BaseRef -RepoPath $empty } | Should -Throw '*Cannot resolve a base ref*'
    }

    It 'throws rather than returning a worker branch when that is the only branch' {
        $repo = New-TempRepo -Branch 'worktree-only'
        Test-RefResolves -RepoPath $repo -Ref 'worktree-only' | Should -BeTrue
        { Resolve-BaseRef -RepoPath $repo } | Should -Throw '*Cannot resolve a base ref*'
    }

    It 'names the rejected worker branch in the refusal' {
        $repo = New-TempRepo -Branch 'worktree-only'
        $err = $null
        try { Resolve-BaseRef -RepoPath $repo } catch { $err = $_.Exception.Message }
        $err | Should -Not -BeNullOrEmpty
        $err | Should -BeLike '*Rejected the worker branch*worktree-only*'
    }
}

# ---------------------------------------------------------------------------------------------
# Dispatch itself. kingshand creates the worktree now - `claude --bg --worktree` used to - so the
# part that can go wrong quietly is git, not the spawn. herdr is replaced by a shim on PATH, which
# Get-HerdrCommandPath honours ahead of the bundled binary, so every case below drives the real
# Dispatch-Worker.ps1 end to end without a single Claude Code process starting.
#
# $env:USERPROFILE is redirected too. Grant-ClaudeFolderTrust writes ~\.claude.json, and a test
# suite that edited the person running it's real Claude Code project list would be indefensible.
# ---------------------------------------------------------------------------------------------
Describe 'Dispatch-Worker - the worktree it creates and the id it chooses' {
    BeforeAll {
        # The registry and the index the dispatch gate reads. Every case below drives them through
        # their own modules rather than writing their file formats by hand, and always inside the
        # fixture's data root - the live $env:KINGSHAND_HOME\data\ is never read or written here.
        Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'bin\Index.psm1')    -Force
        Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'bin\Projects.psm1') -Force

        $script:DispatchScript = "$PSScriptRoot\..\bin\Dispatch-Worker.ps1"
        $script:SavedPath      = $env:PATH
        $script:SavedProfile   = $env:USERPROFILE

        $script:ShimDir = New-TempFixturePath -Prefix 'herdr-shim-'
        New-Item -ItemType Directory -Force -Path $script:ShimDir | Out-Null

        # One canned answer per `herdr <verb> <noun>`, so a single shim serves the whole dispatch
        # sequence: status, pane list, pane split, agent start, agent prompt.
        Set-Content -Path (Join-Path $script:ShimDir 'herdr.cmd') -Encoding ascii -Value @(
            '@echo off',
            '>>"%KINGSHAND_TEST_HERDR_CALLS%" echo %*',
            'if "%1"=="status" goto :status',
            'type "%KINGSHAND_TEST_HERDR_DIR%\%1-%2.json"',
            'exit /b 0',
            ':status',
            'type "%KINGSHAND_TEST_HERDR_DIR%\status.txt"',
            'exit /b 0'
        )

        # Test-HerdrServer matches on this shape, so a running server needs no real one.
        Set-Content -Encoding ascii -Path (Join-Path $script:ShimDir 'status.txt') -Value @(
            'client:', '  version: 0.8.2', '', 'server:', '  status: running', '  socket: none'
        )

        function Set-HerdrReply {
            param([Parameter(Mandatory)][string]$Verb, [Parameter(Mandatory)]$Result)
            @{ id = "cli:$Verb"; result = $Result } | ConvertTo-Json -Depth 8 |
                Set-Content -Path (Join-Path $script:ShimDir "$Verb.json") -Encoding utf8
        }

        # Dispatch reads the started worker's state through Get-HerdrAgentState, never the raw
        # agent_status, so the shim has to answer `agent get` AND `agent read` as well. The screen
        # is what decides: herdr misreports a worker sitting on a prompt, so a blocked case that
        # only set agent_status would prove nothing about the check dispatch actually performs.
        #
        # The blocked screen uses the FOLDER-TRUST dialog's wording rather than a question menu,
        # because that is the prompt a fresh worktree really stops on, and its footer says "Enter
        # to confirm" where the menus say "Enter to select" - a guard that only knew the menu
        # wording would sail straight past the one dialog dispatch exists to catch.
        function Set-AgentStartState {
            param([string]$State = 'idle')
            Set-HerdrReply -Verb 'agent-start'  -Result @{ agent = @{ name = 'x'; pane_id = 'p2'; agent_status = $State } }
            Set-HerdrReply -Verb 'agent-prompt' -Result @{ agent = @{ name = 'x'; pane_id = 'p2'; agent_status = 'idle' } }
            Set-HerdrReply -Verb 'agent-get'    -Result @{ agent = @{ name = 'x'; pane_id = 'p2'; agent_status = $State } }

            $screen = if ($State -eq 'blocked') {
                @(' Quick safety check: Is this a project you created or one you trust?',
                  '',
                  ' > 1. Yes, I trust this folder',
                  '   2. No, exit',
                  '',
                  ' Enter to confirm - Esc to cancel')
            } else {
                # Deliberately a realistic terminal width. Dispatch now checks that the guard can
                # actually read this worker's screen, and a fixture narrower than the guard's
                # threshold would make every ordinary dispatch warn that it had gone blind.
                @('* Claude Code v2.1.220 - Opus - E:\repo',
                  '',
                  '> ',
                  '  bypass permissions on (shift+tab to cycle) - left arrow for agents')
            }
            Set-Content -Path (Join-Path $script:ShimDir 'agent-read.json') -Encoding utf8 -Value $screen
        }

        # Every worker gets its OWN workspace now, never a split of an existing pane. Splitting
        # halves the terminal width each time, and two real workers came out 6 and 3 columns wide -
        # too narrow to render the prompt text the screen guard matches, which left both the guard
        # and herdr's own detection blind. pane-split is still answered so a test that reaches for
        # it fails on its assertion rather than on a missing fixture.
        Set-HerdrReply -Verb 'workspace-create' -Result @{ root_pane = @{ pane_id = 'p2' } }
        Set-HerdrReply -Verb 'pane-list'        -Result @{ panes = @(@{ pane_id = 'p1' }) }
        Set-HerdrReply -Verb 'pane-split'       -Result @{ pane = @{ pane_id = 'p2' } }
        Set-AgentStartState

        $env:KINGSHAND_TEST_HERDR_DIR = $script:ShimDir
        $env:PATH = $script:ShimDir + [IO.Path]::PathSeparator + $env:PATH

        # Every dispatch gets a fresh brief, call log and fake home, so no case can read another's.
        function New-DispatchFixture {
            param([Parameter(Mandatory)][string]$Name)
            $root = New-TempFixturePath -Prefix "dispatch-$Name-"
            # data\<id>\, the real layout: the guard resolves `$env:KINGSHAND_HOME\data\...` and the
            # index's bare `data\<name>.md` against the brief's own data root, so a fixture whose
            # data root is not called data would exercise neither form.
            $briefDir = Join-Path $root 'data\brief'
            $home_    = Join-Path $root 'home'
            New-Item -ItemType Directory -Force -Path $briefDir | Out-Null
            New-Item -ItemType Directory -Force -Path $home_    | Out-Null
            # The Read first section is in the default fixture because dispatch requires it of
            # every brief, and a fixture without one would exercise a brief muster cannot write.
            # Cases that need it absent overwrite this file themselves.
            Set-Content -Path (Join-Path $briefDir 'brief.md') -Encoding utf8 -Value @(
                '# Brief', '', '## Read first', '- Nothing beyond this brief.', ''
                '## Scope', 'Do the thing, and the SECRET-BODY-MARKER must never travel by value.'
            )
            # A config with a projects object, so the trust grant has somewhere real to land.
            '{ "projects": { "C:/somewhere-else": { "hasTrustDialogAccepted": true } } }' |
                Set-Content -Path (Join-Path $home_ '.claude.json') -Encoding utf8

            $env:USERPROFILE = $home_
            $env:KINGSHAND_TEST_HERDR_CALLS = Join-Path $root 'calls.txt'

            [pscustomobject]@{
                Repo      = New-TempRepo
                BriefPath = Join-Path $briefDir 'brief.md'
                BriefDir  = $briefDir
                DataPath  = Join-Path $root 'data'
                Home      = $home_
                CallLog   = Join-Path $root 'calls.txt'
            }
        }

        # -DataPath points the index gate at this fixture's own data root, where its registry and
        # its index live. Passed on every dispatch below, not only the gate's own cases: a suite
        # whose default reached the real installation's data\ would pass or fail on whatever that
        # machine happens to have registered.
        function Invoke-Dispatch {
            param([Parameter(Mandatory)]$Fixture, [Parameter(Mandatory)][string]$Name)
            & $script:DispatchScript -RepoPath $Fixture.Repo -Name $Name `
                -BriefPath $Fixture.BriefPath -DataPath $Fixture.DataPath
        }

        # A registered project for the fixture's repo, and optionally an index holding one entry.
        # Registering without -WithIndex is the unindexed case: a project the gate resolves and then
        # has nothing to check for.
        function Register-FixtureProject {
            param(
                [Parameter(Mandatory)]$Fixture,
                [string]$Project = 'acme-web',
                [switch]$WithIndex
            )
            Add-ProjectEntry -Name $Project -Path $Fixture.Repo -Mode 'local-only' `
                -Description 'the fixture repo' `
                -RegistryPath (Join-Path $Fixture.DataPath 'projects.md')
            if ($WithIndex) {
                Add-IndexEntry -Project $Project -Path 'data\brand.md' `
                    -Summary 'settled brand: logo, favicon, tagline, palettes' `
                    -DataPath $Fixture.DataPath | Out-Null
            }
            $Project
        }

        # One entry in the ROOT index, data\index.md, which no project owns. That is where the
        # settled files this gate exists to protect actually land - chronicle, annex and survey all
        # write data\<topic>.md with no project - so a fixture that only ever wrote a project index
        # would never exercise the index the real installation has.
        function Add-FixtureRootEntry {
            param([Parameter(Mandatory)]$Fixture, [string]$Leaf = 'brand.md')
            Add-IndexEntry -Path "data\$Leaf" `
                -Summary 'settled brand: logo, favicon, tagline, palettes' `
                -DataPath $Fixture.DataPath | Out-Null
        }

        function Get-CallLines {
            param([Parameter(Mandatory)]$Fixture)
            if (-not (Test-Path -LiteralPath $Fixture.CallLog)) { return @() }
            @(Get-Content -LiteralPath $Fixture.CallLog | Where-Object { $_.Trim() })
        }

        # A brief with a real `Read first` section, in the shape muster's template writes: the copy
        # named as read-first\<leaf>, with the original repeated in the same line as provenance.
        # Any fixture that stages a file has to name it, because dispatch now refuses a staged copy
        # the brief says nothing about.
        function Set-ReadFirstBrief {
            param(
                [Parameter(Mandatory)]$Fixture,
                [string[]]$Leaf   = @(),
                [string[]]$Body,
                [string]$From     = 'C:\somewhere\original.md'
            )
            if (-not $PSBoundParameters.ContainsKey('Body')) {
                $Body = if ($Leaf.Count -eq 0) { @('- Nothing beyond this brief.') } else {
                    foreach ($l in $Leaf) {
                        "- ``$($Fixture.BriefDir)\read-first\$l`` - what it settles, copied here from ``$From``."
                    }
                }
            }
            Set-Content -Path $Fixture.BriefPath -Encoding utf8 -Value (@(
                '# Brief', '', '## Read first') + $Body + @(
                '', '## Scope', 'Do the thing, and the SECRET-BODY-MARKER must never travel by value.'))
        }
    }

    AfterAll {
        $env:PATH        = $script:SavedPath
        $env:USERPROFILE = $script:SavedProfile
        Remove-Item Env:\KINGSHAND_TEST_HERDR_DIR   -ErrorAction SilentlyContinue
        Remove-Item Env:\KINGSHAND_TEST_HERDR_CALLS -ErrorAction SilentlyContinue
    }

    Context 'a first dispatch' {
        BeforeAll {
            Set-AgentStartState
            $script:First       = New-DispatchFixture 'first'
            $script:FirstResult = Invoke-Dispatch -Fixture $script:First -Name 'T-1001'
        }

        # The location is not an implementation detail. `.gitignore` covers .claude/worktrees/,
        # crew.json rows already recorded there, and the skills spell it out - moving it would
        # commit a worker's checkout into the repo it is working on.
        It 'puts the worktree exactly where claude --bg --worktree put it' {
            $expected = Join-Path $script:First.Repo '.claude\worktrees\T-1001'
            $script:FirstResult.worktree | Should -Be $expected
            Test-Path -LiteralPath (Join-Path $expected '.git') | Should -BeTrue
        }

        It 'branches it as worktree- plus the name, from the resolved base' {
            $script:FirstResult.branch | Should -Be 'worktree-T-1001'
            $script:FirstResult.base   | Should -Be 'main'
            $head = (& git -C $script:FirstResult.worktree rev-parse --abbrev-ref HEAD).Trim()
            $head | Should -Be 'worktree-T-1001'
        }

        # The whole point of the port: the id is chosen, so there is no before/after diff to lose
        # a worker in and no window in which a dispatch has no id to record.
        It 'returns the chosen name as the id rather than one discovered afterwards' {
            $script:FirstResult.id | Should -Be 'T-1001'
        }

        # Four crew.json fields plus one dispatch-time observation, and nothing else. `readable`
        # is deliberately not crew state: it says whether the guard could see this worker's screen
        # at the moment it started, which the caller has to know because "no prompt found" and
        # "could not look" are different answers and only one means the worker is healthy.
        It 'returns the four fields crew.json is built from, plus the readability answer' {
            @($script:FirstResult.Keys | Sort-Object) |
                Should -Be @('base', 'branch', 'id', 'readable', 'worktree')
        }

        It 'reports the worker as readable when its terminal is wide enough for the guard' {
            $script:FirstResult.readable |
                Should -BeTrue -Because 'the fixture screen is a realistic width, so the guard can see it'
        }

        # herdr cannot pass arguments to claude on Windows at all, so both grants have to be on
        # disk before the agent starts or the worker stops at the first permission prompt.
        It 'writes the two grants into the worktree before starting anything' {
            $settings = Join-Path $script:FirstResult.worktree '.claude\settings.local.json'
            Test-Path -LiteralPath $settings | Should -BeTrue
            $json = Get-Content -LiteralPath $settings -Raw | ConvertFrom-Json
            $json.permissions.defaultMode | Should -Be 'bypassPermissions'
            @($json.permissions.additionalDirectories) | Should -Contain $script:First.BriefDir
        }

        It 'records folder trust for the worktree, so the agent never meets the dialog' {
            $config = Get-Content -LiteralPath (Join-Path $script:First.Home '.claude.json') -Raw |
                      ConvertFrom-Json
            $key = ($script:FirstResult.worktree -replace '\\', '/')
            @($config.projects.PSObject.Properties.Name) | Should -Contain $key
        }

        It 'passes the brief by path and never by value' {
            $prompt = @(Get-CallLines $script:First | Where-Object { $_ -like 'agent prompt*' })
            $prompt.Count | Should -Be 1
            $prompt[0] | Should -BeLike "*$($script:First.BriefPath)*"
            $prompt[0] | Should -Not -BeLike '*SECRET-BODY-MARKER*' `
                -Because 'a brief that travels by value is a brief that can be truncated in transit'
        }

        # `agent start <name> ... -- <args>` is broken on Windows for claude: herdr launches it
        # through Start-Process against a .ps1 and it dies with "%1 is not a valid Win32
        # application". No agent arguments can ever be passed, which is why the grants are on disk.
        It 'starts the agent with no claude arguments at all' {
            $start = @(Get-CallLines $script:First | Where-Object { $_ -like 'agent start*' })
            $start.Count | Should -Be 1
            $start[0] | Should -Not -BeLike '* -- *'
            $start[0] | Should -Not -BeLike '*bypassPermissions*'
            $start[0] | Should -Not -BeLike '*--add-dir*'
        }
    }

    Context 're-dispatching the same ticket' {
        # `git worktree add -b` cannot be told twice, and a raw "fatal: a branch named
        # worktree-T-2001 already exists" is not something the Hand can route on. Sending a worker
        # back to the same ticket is ordinary, so each of the three states it can find is decided
        # deliberately.
        It 'reuses the checkout that is already there rather than failing on the branch' {
            Set-AgentStartState
            $f = New-DispatchFixture 'again'
            $one = Invoke-Dispatch -Fixture $f -Name 'T-2001'
            Set-Content -Path (Join-Path $one.worktree 'work-in-progress.txt') -Value 'kept' -Encoding utf8

            $two = Invoke-Dispatch -Fixture $f -Name 'T-2001'
            $two.worktree | Should -Be $one.worktree
            $two.branch   | Should -Be $one.branch
            Test-Path -LiteralPath (Join-Path $one.worktree 'work-in-progress.txt') |
                Should -BeTrue -Because 'unlanded work is never discarded to get a clean add'
        }

        It 'checks the branch out again when the branch outlived its worktree' {
            Set-AgentStartState
            $f = New-DispatchFixture 'branch-survived'
            $one = Invoke-Dispatch -Fixture $f -Name 'T-2002'
            & git -C $f.Repo worktree remove --force $one.worktree 2>&1 | Out-Null
            (& git -C $f.Repo rev-parse --verify --quiet 'refs/heads/worktree-T-2002') |
                Should -Not -BeNullOrEmpty -Because 'the branch is the work, and removal kept it'

            $two = Invoke-Dispatch -Fixture $f -Name 'T-2002'
            (& git -C $two.worktree rev-parse --abbrev-ref HEAD).Trim() | Should -Be 'worktree-T-2002'
        }

        # A directory deleted by hand leaves a record under .git\worktrees, and `git worktree add`
        # then refuses with "already exists" about a directory nobody can see.
        It 'prunes a stale worktree record instead of refusing over a directory that is gone' {
            Set-AgentStartState
            $f = New-DispatchFixture 'stale-record'
            $one = Invoke-Dispatch -Fixture $f -Name 'T-2003'
            Remove-Item -LiteralPath $one.worktree -Recurse -Force

            { Invoke-Dispatch -Fixture $f -Name 'T-2003' } | Should -Not -Throw
            Test-Path -LiteralPath (Join-Path $one.worktree '.git') | Should -BeTrue
        }

        It 'refuses when something git does not own is sitting at the worktree path' {
            Set-AgentStartState
            $f = New-DispatchFixture 'foreign-dir'
            $path = Join-Path $f.Repo '.claude\worktrees\T-2004'
            New-Item -ItemType Directory -Force -Path $path | Out-Null
            Set-Content -Path (Join-Path $path 'someones-notes.txt') -Value 'not ours' -Encoding utf8

            { Invoke-Dispatch -Fixture $f -Name 'T-2004' } |
                Should -Throw '*git does not own it*'
        }
    }

    Context 'a worker that comes back blocked' {
        # herdr reports agent_not_ready while the agent exists and sits on an interactive prompt,
        # so Start-HerdrAgent hands back the live record instead of throwing. Sending keys at a
        # prompt nobody has read answers whichever option happens to be highlighted, and a batched
        # arrow+enter is delivered out of order and picks the wrong one while returning success.
        It 'reports the block and sends no keys at it' {
            Set-AgentStartState -State 'blocked'
            $f = New-DispatchFixture 'blocked'

            { Invoke-Dispatch -Fixture $f -Name 'T-3001' } | Should -Throw '*blocked on an interactive prompt*'

            $lines = Get-CallLines $f
            @($lines | Where-Object { $_ -like 'agent send-keys*' }).Count |
                Should -Be 0 -Because 'nothing here answers a security prompt it has not read'
            @($lines | Where-Object { $_ -like 'agent prompt*' }).Count |
                Should -Be 0 -Because 'a blocked agent cannot take the brief, so it is not submitted'
        }

        It 'leaves the worktree and branch in place, and names them' {
            Set-AgentStartState -State 'blocked'
            $f = New-DispatchFixture 'blocked-evidence'
            $err = $null
            try { Invoke-Dispatch -Fixture $f -Name 'T-3002' } catch { $err = $_.Exception.Message }

            $expected = Join-Path $f.Repo '.claude\worktrees\T-3002'
            $err | Should -BeLike "*$expected*"
            $err | Should -BeLike '*worktree-T-3002*'
            Test-Path -LiteralPath (Join-Path $expected '.git') | Should -BeTrue
        }

        AfterAll { Set-AgentStartState }
    }

    Context 'refusing before anything is spawned' {
        # Resolve-BaseRef refuses rather than inventing a ref, and it is called first for exactly
        # this reason: a refusal after the spawn would leave an agent running with nothing recorded.
        It 'makes no herdr call at all when the base cannot be resolved' {
            Set-AgentStartState
            $f = New-DispatchFixture 'no-base'
            $empty = New-TempRepo -Empty
            # DataPath is carried over with the rest. Without it this dispatch reads the real
            # installation's data\ - a live registry and a live root index deciding whether a unit
            # test refuses, which is the one thing every case here is built to avoid.
            $f2 = [pscustomobject]@{
                Repo = $empty; BriefPath = $f.BriefPath; BriefDir = $f.BriefDir
                DataPath = $f.DataPath; Home = $f.Home; CallLog = $f.CallLog
            }

            { Invoke-Dispatch -Fixture $f2 -Name 'T-4001' } | Should -Throw '*Cannot resolve a base ref*'
            (Get-CallLines $f2).Count | Should -Be 0
            Test-Path -LiteralPath (Join-Path $empty '.claude\worktrees\T-4001') |
                Should -BeFalse -Because 'nothing is created before the base is known'
        }

        It 'refuses a brief that is not on disk' {
            $f = New-DispatchFixture 'no-brief'
            { & $script:DispatchScript -RepoPath $f.Repo -Name 'T-4002' -DataPath $f.DataPath `
                -BriefPath (Join-Path $f.BriefDir 'missing.md') } | Should -Throw '*Brief not found*'
        }

        # A brief naming a file that is not there is a brief the worker cannot carry out, and
        # finding that out after it is running costs a whole dispatch.
        It 'refuses a Read-first path that is not on disk, before creating anything' {
            Set-AgentStartState
            $f = New-DispatchFixture 'no-readpath'
            { & $script:DispatchScript -RepoPath $f.Repo -Name 'T-4003' -BriefPath $f.BriefPath `
                -DataPath $f.DataPath -ReadPath (Join-Path $f.BriefDir '..\brand.md') } |
                Should -Throw '*under Read first and it does not exist*'
            Test-Path -LiteralPath (Join-Path $f.Repo '.claude\worktrees\T-4003') |
                Should -BeFalse -Because 'nothing is created before every named file is known to be there'
        }
    }

    # The settled spec the whole index exists to deliver lives at data\<name>.md, a SIBLING of the
    # brief's own data\<id>\ directory. With only the brief's grant the worker is told to read a
    # file it cannot open, which is the original failure with one extra hop.
    #
    # The fixture puts the spec DIRECTLY under the data root on purpose. An earlier fixture used a
    # subdirectory, which meant the invariant below held for the fixture and was violated by the
    # documented case: granting the containing directory of data\<name>.md grants the data root.
    Context 'a brief that names files to read first' {
        BeforeAll {
            Set-AgentStartState
            $script:Read     = New-DispatchFixture 'readfirst'
            $script:DataRoot = Split-Path $script:Read.BriefDir -Parent
            $script:SpecFile = Join-Path $script:DataRoot 'brand.md'
            Set-Content -Path $script:SpecFile -Value 'teal, not amber' -Encoding utf8
            Set-ReadFirstBrief -Fixture $script:Read -Leaf 'brand.md' -From $script:SpecFile

            $script:ReadResult = & $script:DispatchScript -RepoPath $script:Read.Repo `
                -Name 'T-5001' -BriefPath $script:Read.BriefPath -DataPath $script:Read.DataPath `
                -ReadPath $script:SpecFile
            $script:ReadGrants = @((Get-Content -LiteralPath `
                (Join-Path $script:ReadResult.worktree '.claude\settings.local.json') -Raw |
                ConvertFrom-Json).permissions.additionalDirectories)
            $script:Staged = Join-Path $script:Read.BriefDir 'read-first\brand.md'
        }

        It 'puts each named file where the worker can actually reach it' {
            Test-Path -LiteralPath $script:Staged | Should -BeTrue
            (Get-Content -LiteralPath $script:Staged -Raw).Trim() | Should -Be 'teal, not amber'
        }

        It 'keeps the file name, so the path the brief already named is the path that appears' {
            Split-Path $script:Staged -Leaf | Should -Be (Split-Path $script:SpecFile -Leaf)
        }

        # The grant list is what bypassPermissions applies to, so an entry here is read AND write.
        It 'grants the brief''s own directory and nothing else at all' {
            $script:ReadGrants | Should -Be @($script:Read.BriefDir)
        }

        It 'never grants the data root, whatever the brief names' {
            $script:ReadGrants | Should -Not -Contain $script:DataRoot `
                -Because 'that is every other worker''s brief and report, king.md, learnings.md, backlog.md and projects.md, writable'
        }

        It 'leaves the original where it was' {
            Test-Path -LiteralPath $script:SpecFile | Should -BeTrue
            (Get-Content -LiteralPath $script:SpecFile -Raw).Trim() | Should -Be 'teal, not amber'
        }

        It 'adds no grant when a named file already sits beside the brief itself' {
            Set-AgentStartState
            $f = New-DispatchFixture 'readfirst-same'
            $beside = Join-Path $f.BriefDir 'notes.md'
            Set-Content -Path $beside -Value 'x' -Encoding utf8
            Set-ReadFirstBrief -Fixture $f -Leaf 'notes.md' -From $beside
            $r = & $script:DispatchScript -RepoPath $f.Repo -Name 'T-5002' `
                -BriefPath $f.BriefPath -DataPath $f.DataPath -ReadPath $beside
            $grants = @((Get-Content -LiteralPath `
                (Join-Path $r.worktree '.claude\settings.local.json') -Raw |
                ConvertFrom-Json).permissions.additionalDirectories)
            $grants | Should -Be @($f.BriefDir)
        }

        It 'carries every file the brief named, not just the first' {
            Set-AgentStartState
            $f = New-DispatchFixture 'readfirst-many'
            $root = Split-Path $f.BriefDir -Parent
            $one  = Join-Path $root 'brand.md'
            $two  = Join-Path $root 'voice.md'
            Set-Content -Path $one -Value 'teal' -Encoding utf8
            Set-Content -Path $two -Value 'plain words' -Encoding utf8
            Set-ReadFirstBrief -Fixture $f -Leaf 'brand.md', 'voice.md'

            & $script:DispatchScript -RepoPath $f.Repo -Name 'T-5003' `
                -BriefPath $f.BriefPath -DataPath $f.DataPath -ReadPath $one, $two | Out-Null

            (Get-Content -LiteralPath (Join-Path $f.BriefDir 'read-first\brand.md') -Raw).Trim() |
                Should -Be 'teal'
            (Get-Content -LiteralPath (Join-Path $f.BriefDir 'read-first\voice.md') -Raw).Trim() |
                Should -Be 'plain words'
        }

        # One would land on top of the other and the worker would read whichever was copied last,
        # with nothing to say the other was ever named.
        It 'refuses two different files sharing one name, before creating anything' {
            Set-AgentStartState
            $f = New-DispatchFixture 'readfirst-clash'
            $root = Split-Path $f.BriefDir -Parent
            $a = Join-Path $root 'a\spec.md'
            $b = Join-Path $root 'b\spec.md'
            foreach ($p in @($a, $b)) {
                New-Item -ItemType Directory -Force -Path (Split-Path $p -Parent) | Out-Null
                Set-Content -Path $p -Value 'x' -Encoding utf8
            }
            { & $script:DispatchScript -RepoPath $f.Repo -Name 'T-5004' `
                -BriefPath $f.BriefPath -DataPath $f.DataPath -ReadPath $a, $b } |
                Should -Throw '*two different files called spec.md*'
            Test-Path -LiteralPath (Join-Path $f.Repo '.claude\worktrees\T-5004') | Should -BeFalse
        }

        It 'refuses a directory where a file was meant, before creating anything' {
            Set-AgentStartState
            $f = New-DispatchFixture 'readfirst-dir'
            { & $script:DispatchScript -RepoPath $f.Repo -Name 'T-5005' `
                -BriefPath $f.BriefPath -DataPath $f.DataPath `
                -ReadPath (Split-Path $f.BriefDir -Parent) } |
                Should -Throw '*Name the files the worker must read*'
            Test-Path -LiteralPath (Join-Path $f.Repo '.claude\worktrees\T-5005') | Should -BeFalse
        }
    }

    # Five refusals, and not one of them reads a path out of the brief's prose. An earlier version
    # parsed the `Read first` section and compared that set against -ReadPath in both directions.
    # The intent was right and the mechanism had no last bug: six consecutive review rounds each
    # closed one path shape and exposed the next, and two of them refused correct briefs over paths
    # nobody had written. The Hand writes the brief AND calls the dispatcher, so it supplies the
    # list; what remains is checked where the path is known exactly, plus the one check about the
    # section that never needed a path at all - that it is there.
    Context 'the Read first section the dispatcher requires' {
        # The refusals all say "Nothing was created", and that has to be true. An earlier ordering
        # staged first, so a file was already copied and a directory already existed underneath a
        # message denying both.
        It 'leaves no staged file behind when it refuses' {
            Set-AgentStartState
            $f = New-DispatchFixture 'readfirst-nodebris'
            $one = Join-Path (Split-Path $f.BriefDir -Parent) 'brand.md'
            Set-Content -Path $one -Value 'teal' -Encoding utf8
            Set-Content -Path $f.BriefPath -Encoding utf8 -Value @('# Brief', '', '## Scope', 'Do it.')

            { & $script:DispatchScript -RepoPath $f.Repo -Name 'T-6005' `
                -BriefPath $f.BriefPath -DataPath $f.DataPath -ReadPath $one } |
                Should -Throw '*Nothing was created*'
            Test-Path -LiteralPath (Join-Path $f.BriefDir 'read-first') |
                Should -BeFalse -Because 'a refusal that says nothing was created must have created nothing'
        }

        # The whole point of passing the list structurally: whatever shape a path is written in
        # down there, nothing reads it. Every one of these lines refused a dispatch at some round of
        # the parser's life - the original path, the env-var form the template teaches, the relative
        # form the index stores, a file name with a space in it, and prose that says `read-first\`
        # without naming a file after it. The brief is the WORKER's instruction; -ReadPath is the
        # dispatcher's.
        It 'dispatches whatever path shapes the section is written in, because nothing reads them' {
            Set-AgentStartState
            $f = New-DispatchFixture 'readfirst-shapes'
            $one = Join-Path (Split-Path $f.BriefDir -Parent) 'brand.md'
            Set-Content -Path $one -Value 'teal' -Encoding utf8
            Set-ReadFirstBrief -Fixture $f -Body @(
                "- ``$one`` - the settled brand, written as the original absolute path."
                '- `$env:KINGSHAND_HOME\data\emgee-brand.md` - the form the template teaches.'
                '- `data\emgee-brand.md` - the form the index stores.'
                '- `data\T-1002\read-first\brand spec.md` - another unit''s copy, with a space in it.'
                '- The copy lives under read-first\ in this directory.')

            $r = & $script:DispatchScript -RepoPath $f.Repo -Name 'T-6001' `
                -BriefPath $f.BriefPath -DataPath $f.DataPath -ReadPath $one
            $r.id | Should -Be 'T-6001'
            Test-Path -LiteralPath (Join-Path $f.BriefDir 'read-first\brand.md') | Should -BeTrue
        }

        # A spaced name was refused at -ReadPath only so the prose parser never had to guess where
        # such a path ended. With no parser there is nothing to guess, and staging carries the file
        # perfectly well.
        It 'stages a file whose name contains a space' {
            Set-AgentStartState
            $f = New-DispatchFixture 'readfirst-spaced-name'
            $one = Join-Path (Split-Path $f.BriefDir -Parent) 'brand spec.md'
            Set-Content -Path $one -Value 'teal' -Encoding utf8
            Set-ReadFirstBrief -Fixture $f -Leaf 'brand spec.md' -From $one

            (& $script:DispatchScript -RepoPath $f.Repo -Name 'T-6017' `
                -BriefPath $f.BriefPath -DataPath $f.DataPath -ReadPath $one).id | Should -Be 'T-6017'
            (Get-Content -LiteralPath (Join-Path $f.BriefDir 'read-first\brand spec.md') -Raw).Trim() |
                Should -Be 'teal'
        }

        # A fenced block is quoted example text. A brief for a task on muster's own template quotes
        # that template, and the quoted heading was read as this brief's own section.
        It 'does not accept a Read first heading that only appears inside a fenced block' {
            Set-AgentStartState
            $f = New-DispatchFixture 'readfirst-fenced-heading'
            Set-Content -Path $f.BriefPath -Encoding utf8 -Value @(
                '# Brief', '', '## Requirements', 'The template muster writes is:', '', '```markdown'
                '## Read first'
                '- `$env:KINGSHAND_HOME\data\<id>\read-first\<filename>` - what it settles.'
                '```', '', 'Keep that slot.')

            { Invoke-Dispatch -Fixture $f -Name 'T-6021' } |
                Should -Throw "*has no '## Read first' section*"
        }

        # The two reports an inquest follow-up needs really are both called report.md, so the advice
        # has to be one the caller can act on rather than a rename that breaks the convention every
        # index entry pointing at them uses.
        It 'advises a route that exists when two staged files share one name' {
            Set-AgentStartState
            $f = New-DispatchFixture 'readfirst-clash-advice'
            $root = Split-Path $f.BriefDir -Parent
            $a = Join-Path $root 'T-1000\report.md'
            $b = Join-Path $root 'T-1001\report.md'
            foreach ($p in @($a, $b)) {
                New-Item -ItemType Directory -Force -Path (Split-Path $p -Parent) | Out-Null
                Set-Content -Path $p -Value 'found it' -Encoding utf8
            }

            $err = { & $script:DispatchScript -RepoPath $f.Repo -Name 'T-6020' `
                -BriefPath $f.BriefPath -DataPath $f.DataPath -ReadPath $a, $b } | Should -Throw -PassThru
            $err.Exception.Message | Should -BeLike '*Pass only the one this task needs*'
            $err.Exception.Message | Should -BeLike '*copy one under a distinct name*'
            $err.Exception.Message |
                Should -Not -BeLike '*Rename one*' -Because 'renaming a durable report.md is not a route'
        }

        It 'refuses when the brief has no Read first section at all but a file was staged' {
            Set-AgentStartState
            $f = New-DispatchFixture 'readfirst-nosection'
            $one = Join-Path (Split-Path $f.BriefDir -Parent) 'brand.md'
            Set-Content -Path $one -Value 'teal' -Encoding utf8
            Set-Content -Path $f.BriefPath -Encoding utf8 -Value @('# Brief', '', '## Scope', 'Do it.')

            { & $script:DispatchScript -RepoPath $f.Repo -Name 'T-6007' `
                -BriefPath $f.BriefPath -DataPath $f.DataPath -ReadPath $one } |
                Should -Throw "*has no '## Read first' section*"
        }

        # Every other check compares two sets, and both are empty when the section was never
        # written and -ReadPath was never passed. So the case the whole mechanism exists to
        # prevent - a brief naming no settled file at all - was the one case that passed every
        # guard, and the worker launched knowing nothing about the file that was already decided.
        It 'refuses a brief with no Read first section even when no file was staged' {
            Set-AgentStartState
            $f = New-DispatchFixture 'readfirst-missing-slot'
            Set-Content -Path $f.BriefPath -Encoding utf8 -Value @(
                '# Brief', '', '## Goal', 'Ship the marketing site.', '', '## Scope', 'Repo: whatever')

            { Invoke-Dispatch -Fixture $f -Name 'T-7101' } |
                Should -Throw "*has no '## Read first' section*"
            Test-Path -LiteralPath (Join-Path $f.Repo '.claude\worktrees\T-7101') |
                Should -BeFalse -Because 'the refusal comes before anything is created'
            (Get-CallLines $f).Count |
                Should -Be 0 -Because 'no worker is spawned for a brief that names nothing to read'
        }

        # An empty section and an absent one are different facts, and only the first is a decision
        # somebody made. A brief with genuinely nothing to read must still dispatch.
        It 'dispatches a brief whose section says there is nothing to read' {
            Set-AgentStartState
            $f = New-DispatchFixture 'readfirst-nothing-beyond'
            Set-ReadFirstBrief -Fixture $f

            (Invoke-Dispatch -Fixture $f -Name 'T-7102').id | Should -Be 'T-7102'
        }

        # The shape muster's template actually writes: the copy named as read-first\<leaf>, with the
        # original repeated in the same line as provenance. This is the ordinary dispatch, and it
        # has to stay ordinary.
        It 'dispatches the template shape, which names the copy and the original in one line' {
            Set-AgentStartState
            $f = New-DispatchFixture 'readfirst-provenance'
            $one = Join-Path (Split-Path $f.BriefDir -Parent) 'brand.md'
            Set-Content -Path $one -Value 'teal' -Encoding utf8
            Set-ReadFirstBrief -Fixture $f -Leaf 'brand.md' -From $one

            $r = & $script:DispatchScript -RepoPath $f.Repo -Name 'T-6008' `
                -BriefPath $f.BriefPath -DataPath $f.DataPath -ReadPath $one
            $r.id | Should -Be 'T-6008'
            Test-Path -LiteralPath (Join-Path $f.BriefDir 'read-first\brand.md') | Should -BeTrue
        }
    }

    # The section being there says a slot was filled in. It does not say the index behind it was
    # ever opened, and an index of pointers nobody is obliged to follow is the settled-spec failure
    # at a larger scale - worse, because it looks solved. So a dispatch anything is indexed for
    # cannot go out without one of two deliberate acts: a file passed to -ReadPath, or a line saying
    # the index was checked and nothing in it applies.
    #
    # BOTH indexes count. The root data\index.md is where the settled files this gate protects
    # actually land, and it is not project-scoped, so it gates an unregistered repo as well; the
    # project's own index gates on top of it once the registry resolves one.
    #
    # None of this reads a path out of the brief. The staged count comes from -ReadPath, "lists
    # something" is Index.psm1's answer, and the escape is one stated sentence.
    Context 'the index behind that section' {
        It 'refuses an indexed project when the brief neither names a file nor says it was checked' {
            Set-AgentStartState
            $f = New-DispatchFixture 'index-silent'
            Register-FixtureProject -Fixture $f -WithIndex | Out-Null
            Set-ReadFirstBrief -Fixture $f -Body @('- Nothing beyond this brief.')

            { Invoke-Dispatch -Fixture $f -Name 'T-8001' } |
                Should -Throw '*neither names a file from them to read*'
        }

        # A refusal that says nothing was created has to have created nothing, and this one comes
        # before the staging copy, the worktree and the spawn alike.
        It 'creates nothing at all when it refuses over the index' {
            Set-AgentStartState
            $f = New-DispatchFixture 'index-nodebris'
            Register-FixtureProject -Fixture $f -WithIndex | Out-Null
            Set-ReadFirstBrief -Fixture $f -Body @('- Nothing beyond this brief.')

            { Invoke-Dispatch -Fixture $f -Name 'T-8002' } | Should -Throw '*Nothing was created*'
            Test-Path -LiteralPath (Join-Path $f.Repo '.claude\worktrees\T-8002') | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $f.BriefDir 'read-first') | Should -BeFalse
            (Get-CallLines $f).Count |
                Should -Be 0 -Because 'no worker is spawned for a brief that ignored the index'
        }

        # The refusal is the Hand's instruction sheet: which project, where its index is, and both
        # ways past it. A refusal that only says no is one the reader has to go and research.
        It 'names the project, its index and both ways past it' {
            Set-AgentStartState
            $f = New-DispatchFixture 'index-message'
            Register-FixtureProject -Fixture $f -Project 'acme-web' -WithIndex | Out-Null
            Set-ReadFirstBrief -Fixture $f -Body @('- Nothing beyond this brief.')

            $err = { Invoke-Dispatch -Fixture $f -Name 'T-8003' } | Should -Throw -PassThru
            $msg = $err.Exception.Message
            $msg | Should -BeLike '*acme-web*'
            $msg.Contains((Join-Path $f.DataPath 'index\acme-web.md')) |
                Should -BeTrue -Because 'the Hand has to be told where to look'
            $msg | Should -BeLike '*-ReadPath*'
            $msg | Should -BeLike '*checked and nothing in it applies*'
        }

        It 'dispatches an indexed project when a file is passed to -ReadPath' {
            Set-AgentStartState
            $f = New-DispatchFixture 'index-readpath'
            Register-FixtureProject -Fixture $f -WithIndex | Out-Null
            $one = Join-Path $f.DataPath 'brand.md'
            Set-Content -Path $one -Value 'teal, not amber' -Encoding utf8
            Set-ReadFirstBrief -Fixture $f -Leaf 'brand.md' -From $one

            $r = & $script:DispatchScript -RepoPath $f.Repo -Name 'T-8004' `
                -BriefPath $f.BriefPath -DataPath $f.DataPath -ReadPath $one
            $r.id | Should -Be 'T-8004'
            Test-Path -LiteralPath (Join-Path $f.BriefDir 'read-first\brand.md') | Should -BeTrue
        }

        # muster hands data\done-<project>.md to -ReadPath on every brief for a project that has
        # one, so counting it here would retire this refusal the moment the first criteria file is
        # written - the gate would be open for exactly the projects furthest along. The evidence it
        # asks for is that the Hand went through the index for THIS task, and a path passed by rote
        # on every dispatch is none.
        It 'refuses an indexed project whose only -ReadPath is the standing-criteria file' {
            Set-AgentStartState
            $f = New-DispatchFixture 'index-criteria-only'
            $name = Register-FixtureProject -Fixture $f -WithIndex
            $criteria = Join-Path $f.DataPath "done-$name.md"
            Set-Content -Path $criteria -Value '- Every new prose rule is pinned by a test.' -Encoding utf8
            Set-ReadFirstBrief -Fixture $f -Leaf "done-$name.md" -From $criteria

            { & $script:DispatchScript -RepoPath $f.Repo -Name 'T-8021' `
                -BriefPath $f.BriefPath -DataPath $f.DataPath -ReadPath $criteria } |
                Should -Throw '*neither names a file from them to read*'
        }

        # And the refusal says which path it discounted, because otherwise the Hand reads a message
        # denying it named any file while looking at the one it just passed.
        It 'names the standing-criteria file it discounted' {
            Set-AgentStartState
            $f = New-DispatchFixture 'index-criteria-message'
            $name = Register-FixtureProject -Fixture $f -WithIndex
            $criteria = Join-Path $f.DataPath "done-$name.md"
            Set-Content -Path $criteria -Value '- Every new prose rule is pinned by a test.' -Encoding utf8
            Set-ReadFirstBrief -Fixture $f -Leaf "done-$name.md" -From $criteria

            $msg = ''
            try {
                & $script:DispatchScript -RepoPath $f.Repo -Name 'T-8022' `
                    -BriefPath $f.BriefPath -DataPath $f.DataPath -ReadPath $criteria
            } catch { $msg = $_.Exception.Message }
            $msg | Should -BeLike "*$criteria*"
            $msg | Should -BeLike '*every brief for this project passes*'
        }

        # The refusal is the Hand's instruction sheet, so the line it recommends has to be one the
        # Hand is allowed to write. In this branch the section already hands the worker the criteria
        # copy, and the literal line would say there is nothing beyond the brief in the same breath -
        # the contradiction muster rules out. So this branch recommends muster's paraphrase, and
        # the test above proves the gate takes it.
        It 'recommends the paraphrase rather than the contradicting literal line' {
            Set-AgentStartState
            $f = New-DispatchFixture 'index-criteria-recommends'
            $name = Register-FixtureProject -Fixture $f -WithIndex
            $criteria = Join-Path $f.DataPath "done-$name.md"
            Set-Content -Path $criteria -Value '- Every new prose rule is pinned by a test.' -Encoding utf8
            Set-ReadFirstBrief -Fixture $f -Leaf "done-$name.md" -From $criteria

            $msg = ''
            try {
                & $script:DispatchScript -RepoPath $f.Repo -Name 'T-8025' `
                    -BriefPath $f.BriefPath -DataPath $f.DataPath -ReadPath $criteria
            } catch { $msg = $_.Exception.Message }
            $msg | Should -BeLike ('*The index was checked; nothing in it applies to this task ' +
                                   'beyond the standing criteria above.*')
            $msg | Should -Not -BeLike '*Nothing beyond this brief - the index was checked*'
        }

        # And the ordinary case keeps the literal line, which is true there: the section names no
        # file at all, so nothing in it contradicts saying there is nothing beyond the brief.
        It 'still recommends the literal line where no path was passed at all' {
            Set-AgentStartState
            $f = New-DispatchFixture 'index-no-path-recommends'
            Register-FixtureProject -Fixture $f -WithIndex | Out-Null
            Set-ReadFirstBrief -Fixture $f -Body @('- Nothing beyond this brief.')

            $msg = ''
            try {
                & $script:DispatchScript -RepoPath $f.Repo -Name 'T-8026' `
                    -BriefPath $f.BriefPath -DataPath $f.DataPath
            } catch { $msg = $_.Exception.Message }
            $msg | Should -BeLike '*Nothing beyond this brief - the index was checked and nothing in it applies.*'
        }

        # The way past the discount that muster actually tells the Hand to write. The literal line
        # the refusal quotes would say there is nothing beyond the brief while the bullet above it
        # hands the worker a file, so muster names this paraphrase instead - and a paraphrase is
        # only usable if the gate really takes it, which is what this runs.
        It 'accepts the paraphrase muster gives for the criteria-only case' {
            Set-AgentStartState
            $f = New-DispatchFixture 'index-criteria-paraphrase'
            $name = Register-FixtureProject -Fixture $f -WithIndex
            $criteria = Join-Path $f.DataPath "done-$name.md"
            Set-Content -Path $criteria -Value '- Every new prose rule is pinned by a test.' -Encoding utf8
            Set-ReadFirstBrief -Fixture $f -Body @(
                "- ``$($f.BriefDir)\read-first\done-$name.md`` - the standing criteria, copied here from ``$criteria``.",
                '- The index was checked; nothing in it applies to this task beyond the standing criteria above.')

            $r = & $script:DispatchScript -RepoPath $f.Repo -Name 'T-8024' `
                -BriefPath $f.BriefPath -DataPath $f.DataPath -ReadPath $criteria
            $r.id | Should -Be 'T-8024'
            Test-Path -LiteralPath (Join-Path $f.BriefDir "read-first\done-$name.md") | Should -BeTrue
        }

        # The discount is exactly one file. Any other path the Hand chose is the engagement this
        # gate asks for, and it still opens the gate when the criteria file rides along beside it.
        It 'dispatches when another file is passed alongside the standing-criteria file' {
            Set-AgentStartState
            $f = New-DispatchFixture 'index-criteria-plus'
            $name = Register-FixtureProject -Fixture $f -WithIndex
            $criteria = Join-Path $f.DataPath "done-$name.md"
            Set-Content -Path $criteria -Value '- Every new prose rule is pinned by a test.' -Encoding utf8
            $brand = Join-Path $f.DataPath 'brand.md'
            Set-Content -Path $brand -Value 'teal, not amber' -Encoding utf8
            Set-ReadFirstBrief -Fixture $f -Leaf @("done-$name.md", 'brand.md') -From $brand

            $r = & $script:DispatchScript -RepoPath $f.Repo -Name 'T-8023' `
                -BriefPath $f.BriefPath -DataPath $f.DataPath -ReadPath @($criteria, $brand)
            $r.id | Should -Be 'T-8023'
            Test-Path -LiteralPath (Join-Path $f.BriefDir 'read-first\brand.md') | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $f.BriefDir "read-first\done-$name.md") | Should -BeTrue
        }

        # The discount has to survive a relative -DataPath, because the two ways of rooting one
        # disagree: GetFullPath uses the PROCESS working directory, which Set-Location does not
        # move, while Index.psm1 reads its indexes from POWERSHELL's location. Rooted the first way
        # the composed done-<project>.md named a file in a directory nobody was looking at, no
        # -ReadPath matched it, and the dispatch went through on a path passed by rote with no index
        # consulted - silently, which is the exact failure the discount exists to catch.
        It 'discounts the standing-criteria file when the data directory is named relatively' {
            Set-AgentStartState
            $f = New-DispatchFixture 'index-criteria-relative'
            $name = Register-FixtureProject -Fixture $f -WithIndex
            $criteria = Join-Path $f.DataPath "done-$name.md"
            Set-Content -Path $criteria -Value '- Every new prose rule is pinned by a test.' -Encoding utf8
            Set-ReadFirstBrief -Fixture $f -Leaf "done-$name.md" -From $criteria

            $savedCwd = [System.Environment]::CurrentDirectory
            Push-Location (Split-Path $f.DataPath -Parent)
            try {
                # The divergence stated outright rather than left to whatever the test host's
                # working directory happens to be.
                [System.Environment]::CurrentDirectory = $f.Home
                { & $script:DispatchScript -RepoPath $f.Repo -Name 'T-8027' `
                    -BriefPath $f.BriefPath -DataPath 'data' -ReadPath $criteria } |
                    Should -Throw '*neither names a file from them to read*'
            } finally {
                [System.Environment]::CurrentDirectory = $savedCwd
                Pop-Location
            }
        }

        It 'dispatches an indexed project when the section says the index was checked' {
            Set-AgentStartState
            $f = New-DispatchFixture 'index-stated'
            Register-FixtureProject -Fixture $f -WithIndex | Out-Null
            Set-ReadFirstBrief -Fixture $f -Body @(
                '- Nothing beyond this brief - the index was checked and nothing in it applies.')

            (Invoke-Dispatch -Fixture $f -Name 'T-8005').id | Should -Be 'T-8005'
        }

        # A project with no index has nothing to consult, so it dispatches exactly as it did before
        # any of this existed. The gate is about an index that exists and went unread.
        It 'dispatches a registered project that has no index at all' {
            Set-AgentStartState
            $f = New-DispatchFixture 'index-none'
            Register-FixtureProject -Fixture $f | Out-Null
            Set-ReadFirstBrief -Fixture $f -Body @('- Nothing beyond this brief.')

            (Invoke-Dispatch -Fixture $f -Name 'T-8006').id | Should -Be 'T-8006'
        }

        # The distinction the whole gate rests on: a line that says the index was checked is a
        # decision somebody made, where a slot filled in with the template's own words says only
        # that the slot was filled in, and an empty one says nothing at all.
        It 'refuses an indexed project whose section is empty' {
            Set-AgentStartState
            $f = New-DispatchFixture 'index-empty-section'
            Register-FixtureProject -Fixture $f -WithIndex | Out-Null
            Set-Content -Path $f.BriefPath -Encoding utf8 -Value @(
                '# Brief', '', '## Read first', '', '## Scope', 'Do the thing.')

            { Invoke-Dispatch -Fixture $f -Name 'T-8007' } |
                Should -Throw '*neither names a file from them to read*'
        }

        # A quoted template cannot make a statement on this brief's behalf, for the same reason a
        # quoted heading does not satisfy the heading check.
        It 'does not accept the stated line from inside a fenced block' {
            Set-AgentStartState
            $f = New-DispatchFixture 'index-fenced-line'
            Register-FixtureProject -Fixture $f -WithIndex | Out-Null
            Set-Content -Path $f.BriefPath -Encoding utf8 -Value @(
                '# Brief', '', '## Read first', '- Nothing beyond this brief.', '',
                'The line muster writes when there is nothing to read is:', '', '```markdown',
                '- Nothing beyond this brief - the index was checked and nothing in it applies.',
                '```', '', '## Scope', 'Do the thing.')

            { Invoke-Dispatch -Fixture $f -Name 'T-8008' } |
                Should -Throw '*neither names a file from them to read*'
        }

        # The refusal that was already there is not weakened by the one added beside it. A brief
        # with no heading fails for every project, indexed or not, and it fails as that brief rather
        # than as an index complaint - the two say different things and both have to keep saying it.
        It 'still refuses a brief with no Read first heading when the project is indexed' {
            Set-AgentStartState
            $f = New-DispatchFixture 'index-noheading'
            Register-FixtureProject -Fixture $f -WithIndex | Out-Null
            Set-Content -Path $f.BriefPath -Encoding utf8 -Value @('# Brief', '', '## Scope', 'Do it.')

            { Invoke-Dispatch -Fixture $f -Name 'T-8009' } |
                Should -Throw "*has no '## Read first' section*"
        }

        It 'still refuses a brief with no Read first heading when nothing is indexed' {
            Set-AgentStartState
            $f = New-DispatchFixture 'index-noheading-unindexed'
            Set-Content -Path $f.BriefPath -Encoding utf8 -Value @('# Brief', '', '## Scope', 'Do it.')

            { Invoke-Dispatch -Fixture $f -Name 'T-8010' } |
                Should -Throw "*has no '## Read first' section*"
        }

        # An unregistered repo resolves to no project, so no PROJECT index applies to it - and
        # another project's index is that project's, not this dispatch's. The gate resolves the
        # project from the registry rather than taking it as an argument, precisely so a forgotten
        # argument cannot switch it off, but an unregistered repo is a posture question the Hand
        # answers, not something this script infers.
        It 'dispatches a repo no registry lists when only another project is indexed' {
            Set-AgentStartState
            $f = New-DispatchFixture 'index-unregistered'
            Register-FixtureProject -Fixture $f -Project 'someone-else' -WithIndex | Out-Null
            $f.Repo = New-TempRepo
            Set-ReadFirstBrief -Fixture $f -Body @('- Nothing beyond this brief.')

            (Invoke-Dispatch -Fixture $f -Name 'T-8011').id | Should -Be 'T-8011'
        }

        # The root index is not project-scoped, and it is where the settled files actually sit. A
        # gate that consulted only data\index\<project>.md could not fire at all on an installation
        # whose data\index\ directory does not even exist - the inert version of the failure it was
        # written for, and the reason an unregistered repo is gated here too.
        It 'refuses a repo no registry lists when the root index lists something' {
            Set-AgentStartState
            $f = New-DispatchFixture 'index-root-unregistered'
            Add-FixtureRootEntry -Fixture $f
            Set-ReadFirstBrief -Fixture $f -Body @('- Nothing beyond this brief.')

            $err = { Invoke-Dispatch -Fixture $f -Name 'T-8012' } | Should -Throw -PassThru
            $err.Exception.Message.Contains((Join-Path $f.DataPath 'index.md')) |
                Should -BeTrue -Because 'the index that triggered the refusal is the one to open'
            Test-Path -LiteralPath (Join-Path $f.Repo '.claude\worktrees\T-8012') | Should -BeFalse
        }

        It 'dispatches a repo the root index gates once the section says it was checked' {
            Set-AgentStartState
            $f = New-DispatchFixture 'index-root-stated'
            Add-FixtureRootEntry -Fixture $f
            Set-ReadFirstBrief -Fixture $f -Body @(
                '- Nothing beyond this brief - the index was checked and nothing in it applies.')

            (Invoke-Dispatch -Fixture $f -Name 'T-8013').id | Should -Be 'T-8013'
        }

        # Every index that triggered the refusal is named with its path, because the Hand has to
        # open each one. Naming only the first would leave the other unread on the next attempt.
        It 'names both indexes when both list something' {
            Set-AgentStartState
            $f = New-DispatchFixture 'index-both'
            Register-FixtureProject -Fixture $f -Project 'acme-web' -WithIndex | Out-Null
            Add-FixtureRootEntry -Fixture $f -Leaf 'learnings.md'
            Set-ReadFirstBrief -Fixture $f -Body @('- Nothing beyond this brief.')

            $err = { Invoke-Dispatch -Fixture $f -Name 'T-8014' } | Should -Throw -PassThru
            $msg = $err.Exception.Message
            $msg.Contains((Join-Path $f.DataPath 'index.md'))            | Should -BeTrue
            $msg.Contains((Join-Path $f.DataPath 'index\acme-web.md'))   | Should -BeTrue
        }

        # The one case where "no index to check" is actually true, and the only one that leaves a
        # dispatch untouched.
        It 'dispatches untouched when nothing is indexed anywhere' {
            Set-AgentStartState
            $f = New-DispatchFixture 'index-nothing-anywhere'
            Register-FixtureProject -Fixture $f | Out-Null
            Set-ReadFirstBrief -Fixture $f -Body @('- Nothing beyond this brief.')

            Test-Path -LiteralPath (Join-Path $f.DataPath 'index.md')   | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $f.DataPath 'index')      | Should -BeFalse
            (Invoke-Dispatch -Fixture $f -Name 'T-8015').id | Should -Be 'T-8015'
        }

        # The registry is maintained by hand as well as by /annex, so a `path:` line with no value
        # gets through the parser as a single space - truthy, and an argument GetFullPath throws on.
        # Resolution used to be wrapped whole, so that one line abandoned every project at once and
        # turned the gate off in silence: a fail-open with no signal, in the check that exists to
        # stop one. The bad entry is registered FIRST, so the project below it is what proves the
        # loop carried on.
        It 'still gates a project listed after a registry entry whose path is unusable' {
            Set-AgentStartState
            $f = New-DispatchFixture 'index-badpath'
            Add-ProjectEntry -Name 'hand-edited' -Path ' ' -Mode 'local-only' `
                -Description 'a path: line with no value' `
                -RegistryPath (Join-Path $f.DataPath 'projects.md')
            Register-FixtureProject -Fixture $f -Project 'acme-web' -WithIndex | Out-Null
            Set-ReadFirstBrief -Fixture $f -Body @('- Nothing beyond this brief.')

            { Invoke-Dispatch -Fixture $f -Name 'T-8016' -WarningAction SilentlyContinue } |
                Should -Throw '*acme-web*'
        }

        # The escape hatch is a statement, not a coincidence of vocabulary. A brief for a
        # search-index task writes "index" and "nothing" in one ordinary sentence about scope and
        # has said nothing at all about consulting anything - so the line has to name what was DONE
        # to the index as well, or the gate switches itself off on the very class of task most
        # likely to use the word, silently and with no error.
        It 'refuses a line that merely mentions an index and the word nothing' {
            Set-AgentStartState
            $f = New-DispatchFixture 'index-loose-words'
            Register-FixtureProject -Fixture $f -WithIndex | Out-Null
            Set-ReadFirstBrief -Fixture $f -Body @(
                '- The search index rebuild is out of scope; change nothing about it.')

            { Invoke-Dispatch -Fixture $f -Name 'T-8018' } |
                Should -Throw '*neither names a file from them to read*'
        }

        # Tightened, not narrowed to one sentence. The Hand states the decision in its own words as
        # long as the words say the index was opened and turned up nothing.
        It 'accepts a line that says in other words that the index was read' {
            Set-AgentStartState
            $f = New-DispatchFixture 'index-paraphrase'
            Register-FixtureProject -Fixture $f -WithIndex | Out-Null
            Set-ReadFirstBrief -Fixture $f -Body @(
                '- I read the index and none of it touches this task.')

            (Invoke-Dispatch -Fixture $f -Name 'T-8019').id | Should -Be 'T-8019'
        }

        # `index` inside a hyphenated compound is a different noun, not a mention of the index. The
        # word boundary in `\bindex\b` sits at the hyphen, so this sentence - an ordinary scope note
        # on a search-index task, with `read` supplied by the section's own title - satisfied all
        # three conditions and dispatched without the index ever being opened.
        It 'refuses a line whose only index is inside a hyphenated compound' {
            Set-AgentStartState
            $f = New-DispatchFixture 'index-hyphenated'
            Register-FixtureProject -Fixture $f -WithIndex | Out-Null
            Set-ReadFirstBrief -Fixture $f -Body @(
                '- Nothing in the search-index module changes; read only the API layer.')

            { Invoke-Dispatch -Fixture $f -Name 'T-8020' } |
                Should -Throw '*neither names a file from them to read*'
        }

        # The plural is what the Hand actually writes, because muster sends it to two indexes.
        It 'accepts a line that says both indexes were checked' {
            Set-AgentStartState
            $f = New-DispatchFixture 'index-plural'
            Register-FixtureProject -Fixture $f -WithIndex | Out-Null
            Add-FixtureRootEntry -Fixture $f
            Set-ReadFirstBrief -Fixture $f -Body @(
                '- Nothing beyond this brief - both indexes were checked and none apply.')

            (Invoke-Dispatch -Fixture $f -Name 'T-8021').id | Should -Be 'T-8021'
        }

        It 'accepts a line that says the index was reviewed' {
            Set-AgentStartState
            $f = New-DispatchFixture 'index-reviewed'
            Register-FixtureProject -Fixture $f -WithIndex | Out-Null
            Set-ReadFirstBrief -Fixture $f -Body @(
                '- Nothing beyond this brief - the index was reviewed and nothing in it applies.')

            (Invoke-Dispatch -Fixture $f -Name 'T-8022').id | Should -Be 'T-8022'
        }

        It 'warns rather than skipping a registry entry it cannot use in silence' {
            Set-AgentStartState
            $f = New-DispatchFixture 'index-badpath-warn'
            Add-ProjectEntry -Name 'hand-edited' -Path ' ' -Mode 'local-only' `
                -Description 'a path: line with no value' `
                -RegistryPath (Join-Path $f.DataPath 'projects.md')
            Register-FixtureProject -Fixture $f | Out-Null
            Set-ReadFirstBrief -Fixture $f -Body @('- Nothing beyond this brief.')

            $r = & $script:DispatchScript -RepoPath $f.Repo -Name 'T-8017' `
                -BriefPath $f.BriefPath -DataPath $f.DataPath `
                -WarningVariable warned -WarningAction SilentlyContinue
            $r.id | Should -Be 'T-8017'
            (@($warned) -join ' ') | Should -BeLike '*hand-edited*'
        }
    }
}
