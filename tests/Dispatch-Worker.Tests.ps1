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
                Home      = $home_
                CallLog   = Join-Path $root 'calls.txt'
            }
        }

        function Invoke-Dispatch {
            param([Parameter(Mandatory)]$Fixture, [Parameter(Mandatory)][string]$Name)
            & $script:DispatchScript -RepoPath $Fixture.Repo -Name $Name -BriefPath $Fixture.BriefPath
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
            $f2 = [pscustomobject]@{
                Repo = $empty; BriefPath = $f.BriefPath; BriefDir = $f.BriefDir
                Home = $f.Home; CallLog = $f.CallLog
            }

            { Invoke-Dispatch -Fixture $f2 -Name 'T-4001' } | Should -Throw '*Cannot resolve a base ref*'
            (Get-CallLines $f2).Count | Should -Be 0
            Test-Path -LiteralPath (Join-Path $empty '.claude\worktrees\T-4001') |
                Should -BeFalse -Because 'nothing is created before the base is known'
        }

        It 'refuses a brief that is not on disk' {
            $f = New-DispatchFixture 'no-brief'
            { & $script:DispatchScript -RepoPath $f.Repo -Name 'T-4002' `
                -BriefPath (Join-Path $f.BriefDir 'missing.md') } | Should -Throw '*Brief not found*'
        }

        # A brief naming a file that is not there is a brief the worker cannot carry out, and
        # finding that out after it is running costs a whole dispatch.
        It 'refuses a Read-first path that is not on disk, before creating anything' {
            Set-AgentStartState
            $f = New-DispatchFixture 'no-readpath'
            { & $script:DispatchScript -RepoPath $f.Repo -Name 'T-4003' -BriefPath $f.BriefPath `
                -ReadPath (Join-Path $f.BriefDir '..\brand.md') } |
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
                -Name 'T-5001' -BriefPath $script:Read.BriefPath -ReadPath $script:SpecFile
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
                -BriefPath $f.BriefPath -ReadPath $beside
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
                -BriefPath $f.BriefPath -ReadPath $one, $two | Out-Null

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
                -BriefPath $f.BriefPath -ReadPath $a, $b } |
                Should -Throw '*two different files called spec.md*'
            Test-Path -LiteralPath (Join-Path $f.Repo '.claude\worktrees\T-5004') | Should -BeFalse
        }

        It 'refuses a directory where a file was meant, before creating anything' {
            Set-AgentStartState
            $f = New-DispatchFixture 'readfirst-dir'
            { & $script:DispatchScript -RepoPath $f.Repo -Name 'T-5005' `
                -BriefPath $f.BriefPath -ReadPath (Split-Path $f.BriefDir -Parent) } |
                Should -Throw '*Name the files the worker must read*'
            Test-Path -LiteralPath (Join-Path $f.Repo '.claude\worktrees\T-5005') | Should -BeFalse
        }
    }

    # The brief line and -ReadPath are written in two different steps, and prose was the only thing
    # tying them together. Omit the parameter and dispatch used to succeed having staged nothing,
    # handing the worker a brief that points at a file which does not exist.
    Context 'a brief whose Read first section and -ReadPath disagree' {
        It 'refuses when the brief names a read-first file that nothing staged' {
            Set-AgentStartState
            $f = New-DispatchFixture 'readfirst-unstaged'
            Set-ReadFirstBrief -Fixture $f -Body @(
                "- ``$($f.BriefDir)\read-first\emgee-brand.md`` - the settled brand. Read it in full.")

            { & $script:DispatchScript -RepoPath $f.Repo -Name 'T-6001' -BriefPath $f.BriefPath } |
                Should -Throw '*emgee-brand.md*'
            Test-Path -LiteralPath (Join-Path $f.Repo '.claude\worktrees\T-6001') |
                Should -BeFalse -Because 'the refusal comes before anything is created'
        }

        It 'refuses when one of two named files was left out of -ReadPath' {
            Set-AgentStartState
            $f = New-DispatchFixture 'readfirst-partial'
            $root = Split-Path $f.BriefDir -Parent
            $one  = Join-Path $root 'brand.md'
            Set-Content -Path $one -Value 'teal' -Encoding utf8
            Set-ReadFirstBrief -Fixture $f -Body @(
                '- `read-first\brand.md` - the brand.'
                '- `read-first\voice.md` - the voice.')

            { & $script:DispatchScript -RepoPath $f.Repo -Name 'T-6002' `
                -BriefPath $f.BriefPath -ReadPath $one } | Should -Throw '*voice.md*'
        }

        # The refusal above says "Nothing was created", and it has to be true. Staging ran before
        # the check, so brand.md was already copied and a directory already existed underneath a
        # message denying both.
        It 'leaves no staged file behind when it refuses' {
            Set-AgentStartState
            $f = New-DispatchFixture 'readfirst-nodebris'
            $one = Join-Path (Split-Path $f.BriefDir -Parent) 'brand.md'
            Set-Content -Path $one -Value 'teal' -Encoding utf8
            Set-ReadFirstBrief -Fixture $f -Body @(
                '- `read-first\brand.md` - the brand.'
                '- `read-first\voice.md` - the voice.')

            { & $script:DispatchScript -RepoPath $f.Repo -Name 'T-6005' `
                -BriefPath $f.BriefPath -ReadPath $one } | Should -Throw '*Nothing was created*'
            Test-Path -LiteralPath (Join-Path $f.BriefDir 'read-first') |
                Should -BeFalse -Because 'a refusal that says nothing was created must have created nothing'
        }

        # The other direction, and the one the first pass left open. muster's "name the copy, not
        # the original" was prose only, so the Hand names the path it actually knows - the original
        # - and passes that same path to -ReadPath. Staging succeeds, the section mentions no
        # read-first\ file at all, and the worker launches holding a path outside its only grant.
        It 'refuses when the brief names the original instead of the staged copy' {
            Set-AgentStartState
            $f = New-DispatchFixture 'readfirst-original'
            $one = Join-Path (Split-Path $f.BriefDir -Parent) 'emgee-brand.md'
            Set-Content -Path $one -Value 'teal, not amber' -Encoding utf8
            Set-ReadFirstBrief -Fixture $f -Body @("- ``$one`` - the settled brand. Read it in full.")

            { & $script:DispatchScript -RepoPath $f.Repo -Name 'T-6006' `
                -BriefPath $f.BriefPath -ReadPath $one } |
                Should -Throw '*emgee-brand.md*names no line for it*'
            Test-Path -LiteralPath (Join-Path $f.Repo '.claude\worktrees\T-6006') | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $f.BriefDir 'read-first') | Should -BeFalse
        }

        # And the variant neither of those two closes: the section names the original, -ReadPath is
        # omitted entirely, and both checks above compare empty sets. No copy was named so nothing
        # was missing, and nothing was staged so nothing was unnamed - dispatch succeeded and the
        # worker launched holding a sibling of the only directory it can read.
        It 'refuses the original path with no -ReadPath at all, before creating anything' {
            Set-AgentStartState
            $f = New-DispatchFixture 'readfirst-original-nostage'
            $one = Join-Path (Split-Path $f.BriefDir -Parent) 'emgee-brand.md'
            Set-Content -Path $one -Value 'teal, not amber' -Encoding utf8
            Set-ReadFirstBrief -Fixture $f -Body @("- ``$one`` - the settled brand. Read it in full.")

            $err = { Invoke-Dispatch -Fixture $f -Name 'T-6009' } | Should -Throw -PassThru
            $err.Exception.Message | Should -BeLike "*$one*"
            $err.Exception.Message |
                Should -BeLike "*$($f.BriefPath)*" -Because 'the operator has to know which brief to edit'
            $err.Exception.Message |
                Should -BeLike '*read-first\emgee-brand.md*' -Because 'the message states the line to write instead'
            Test-Path -LiteralPath (Join-Path $f.Repo '.claude\worktrees\T-6009') | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $f.BriefDir 'read-first') | Should -BeFalse
            (Get-CallLines $f).Count | Should -Be 0
        }

        # Same fault one directory deeper: a settled file in a subdirectory of data\ is no more
        # reachable than one sitting directly in it.
        It 'refuses an unreachable path anywhere under the data root' {
            Set-AgentStartState
            $f = New-DispatchFixture 'readfirst-original-deep'
            $one = Join-Path (Split-Path $f.BriefDir -Parent) 'specs\brand.md'
            New-Item -ItemType Directory -Force -Path (Split-Path $one -Parent) | Out-Null
            Set-Content -Path $one -Value 'teal' -Encoding utf8
            Set-ReadFirstBrief -Fixture $f -Body @("- ``$one`` - the settled brand.")

            { Invoke-Dispatch -Fixture $f -Name 'T-6010' } | Should -Throw '*Nothing was created*'
            Test-Path -LiteralPath (Join-Path $f.Repo '.claude\worktrees\T-6010') | Should -BeFalse
        }

        # The rule is about the tree the grant leaves out, not about absolute paths in general. A
        # brief routinely names files in the repo the worker is about to work in, and refusing those
        # would refuse every ordinary brief.
        It 'accepts a path outside the data root, which the worker can reach' {
            Set-AgentStartState
            $f = New-DispatchFixture 'readfirst-outside-data'
            Set-ReadFirstBrief -Fixture $f -Body @(
                "- ``$($f.Repo)\README.md`` - the repo's own notes, in your worktree.")

            (Invoke-Dispatch -Fixture $f -Name 'T-6011').id | Should -Be 'T-6011'
        }

        # A file sitting beside the brief needs no copy and is inside the grant already.
        It 'accepts a path inside the brief''s own directory' {
            Set-AgentStartState
            $f = New-DispatchFixture 'readfirst-inside-briefdir'
            $beside = Join-Path $f.BriefDir 'notes.md'
            Set-Content -Path $beside -Value 'x' -Encoding utf8
            Set-ReadFirstBrief -Fixture $f -Body @("- ``$beside`` - notes, beside your brief.")

            (Invoke-Dispatch -Fixture $f -Name 'T-6012').id | Should -Be 'T-6012'
        }

        # The form muster's own template teaches. A guard that only saw drive-letter paths let the
        # originating failure straight through the path shape the Hand is most likely to type,
        # because `$env:KINGSHAND_HOME\data\...` holds no letter-colon-separator sequence at all.
        It 'refuses the original written as $env:KINGSHAND_HOME\data\..., before creating anything' {
            Set-AgentStartState
            $f = New-DispatchFixture 'readfirst-envvar-original'
            $one = Join-Path (Split-Path $f.BriefDir -Parent) 'emgee-brand.md'
            Set-Content -Path $one -Value 'teal, not amber' -Encoding utf8
            Set-ReadFirstBrief -Fixture $f -Body @(
                '- `$env:KINGSHAND_HOME\data\emgee-brand.md` - the settled brand. Read it in full.')

            $err = { Invoke-Dispatch -Fixture $f -Name 'T-6013' } | Should -Throw -PassThru
            $err.Exception.Message | Should -BeLike '*emgee-brand.md*'
            $err.Exception.Message |
                Should -BeLike "*$($f.BriefPath)*" -Because 'the operator has to know which brief to edit'
            $err.Exception.Message | Should -BeLike '*read-first\emgee-brand.md*'
            Test-Path -LiteralPath (Join-Path $f.Repo '.claude\worktrees\T-6013') | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $f.BriefDir 'read-first') | Should -BeFalse
            (Get-CallLines $f).Count | Should -Be 0
        }

        # And the form the index itself stores, which is what Step 2 tells the Hand to read: entries
        # are relative to the install root, so the path in front of the Hand is `data\<name>.md`.
        It 'refuses the original written in the index''s own relative form' {
            Set-AgentStartState
            $f = New-DispatchFixture 'readfirst-relative-original'
            $one = Join-Path (Split-Path $f.BriefDir -Parent) 'emgee-brand.md'
            Set-Content -Path $one -Value 'teal, not amber' -Encoding utf8
            Set-ReadFirstBrief -Fixture $f -Body @(
                '- `data\emgee-brand.md` - the settled brand. Read it in full.')

            { Invoke-Dispatch -Fixture $f -Name 'T-6014' } | Should -Throw '*emgee-brand.md*'
            Test-Path -LiteralPath (Join-Path $f.Repo '.claude\worktrees\T-6014') | Should -BeFalse
        }

        # The relative form is the one genuinely ambiguous shape: the same text is an ordinary repo
        # path in any project with a data directory, and refusing those would refuse the briefs that
        # need them. It names a file under kingshand's data root or it does not.
        It 'accepts a relative data path that names no file under the data root' {
            Set-AgentStartState
            $f = New-DispatchFixture 'readfirst-relative-repo'
            Set-ReadFirstBrief -Fixture $f -Body @(
                '- `data/schema.json` - the schema in your worktree. Read it in full.')

            (Invoke-Dispatch -Fixture $f -Name 'T-6015').id | Should -Be 'T-6015'
        }

        # The template shape again, written the way the template actually writes it - env-var form
        # for both the copy and the provenance note. Neither may false-fire.
        It 'accepts the template shape written in env-var form' {
            Set-AgentStartState
            $f = New-DispatchFixture 'readfirst-envvar-template'
            $one = Join-Path (Split-Path $f.BriefDir -Parent) 'brand.md'
            Set-Content -Path $one -Value 'teal' -Encoding utf8
            Set-ReadFirstBrief -Fixture $f -Body @(
                ('- `$env:KINGSHAND_HOME\data\brief\read-first\brand.md` - the settled brand, ' +
                 'copied here from `$env:KINGSHAND_HOME\data\brand.md`. Read it in full.'))

            $r = & $script:DispatchScript -RepoPath $f.Repo -Name 'T-6016' `
                -BriefPath $f.BriefPath -ReadPath $one
            $r.id | Should -Be 'T-6016'
            Test-Path -LiteralPath (Join-Path $f.BriefDir 'read-first\brand.md') | Should -BeTrue
        }

        It 'refuses when the brief has no Read first section at all but a file was staged' {
            Set-AgentStartState
            $f = New-DispatchFixture 'readfirst-nosection'
            $one = Join-Path (Split-Path $f.BriefDir -Parent) 'brand.md'
            Set-Content -Path $one -Value 'teal' -Encoding utf8
            Set-Content -Path $f.BriefPath -Encoding utf8 -Value @('# Brief', '', '## Scope', 'Do it.')

            { & $script:DispatchScript -RepoPath $f.Repo -Name 'T-6007' `
                -BriefPath $f.BriefPath -ReadPath $one } | Should -Throw "*has no '## Read first' section*"
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

        # Briefs are written several at a time from one template, so a Read first block carried
        # over from the brief above keeps the OTHER unit's id. The file name still matches what
        # this dispatch stages, so name-only comparison passed it and the worker opened a path
        # outside the one directory it can read.
        It 'refuses a read-first path carrying another unit of work''s id' {
            Set-AgentStartState
            $f = New-DispatchFixture 'readfirst-foreign-id'
            $one = Join-Path (Split-Path $f.BriefDir -Parent) 'emgee-brand.md'
            Set-Content -Path $one -Value 'teal, not amber' -Encoding utf8
            $other = Join-Path (Split-Path $f.BriefDir -Parent) 'T-1002'
            Set-ReadFirstBrief -Fixture $f -Body @(
                "- ``$other\read-first\emgee-brand.md`` - the settled brand, copied here from ``$one``.")

            { & $script:DispatchScript -RepoPath $f.Repo -Name 'T-7001' `
                -BriefPath $f.BriefPath -ReadPath $one } |
                Should -Throw '*another unit of work''s read-first directory*'
            Test-Path -LiteralPath (Join-Path $f.Repo '.claude\worktrees\T-7001') | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $f.BriefDir 'read-first') | Should -BeFalse
        }

        It 'accepts a read-first path carrying this brief''s own directory' {
            Set-AgentStartState
            $f = New-DispatchFixture 'readfirst-own-id'
            $one = Join-Path (Split-Path $f.BriefDir -Parent) 'brand.md'
            Set-Content -Path $one -Value 'teal' -Encoding utf8
            Set-ReadFirstBrief -Fixture $f -Body @(
                "- ``$($f.BriefDir)\read-first\brand.md`` - the settled brand, copied here from ``$one``.")

            (& $script:DispatchScript -RepoPath $f.Repo -Name 'T-7002' `
                -BriefPath $f.BriefPath -ReadPath $one).id | Should -Be 'T-7002'
        }

        # A bare mention carries no directory at all, which is this brief's own by definition.
        It 'accepts a bare read-first mention with no directory in front of it' {
            Set-AgentStartState
            $f = New-DispatchFixture 'readfirst-bare'
            $one = Join-Path (Split-Path $f.BriefDir -Parent) 'brand.md'
            Set-Content -Path $one -Value 'teal' -Encoding utf8
            Set-ReadFirstBrief -Fixture $f -Body @('- `read-first\brand.md` - the settled brand.')

            (& $script:DispatchScript -RepoPath $f.Repo -Name 'T-7003' `
                -BriefPath $f.BriefPath -ReadPath $one).id | Should -Be 'T-7003'
        }

        # The provenance note in muster's own template repeats the original path in the same line
        # as the copy. A rule of "the section must not name any original" would refuse the shape
        # the template tells the Hand to write.
        It 'accepts the template shape, which names the copy and the original in one line' {
            Set-AgentStartState
            $f = New-DispatchFixture 'readfirst-provenance'
            $one = Join-Path (Split-Path $f.BriefDir -Parent) 'brand.md'
            Set-Content -Path $one -Value 'teal' -Encoding utf8
            Set-ReadFirstBrief -Fixture $f -Leaf 'brand.md' -From $one

            (& $script:DispatchScript -RepoPath $f.Repo -Name 'T-6008' `
                -BriefPath $f.BriefPath -ReadPath $one).id | Should -Be 'T-6008'
        }

        It 'dispatches when every named file was staged' {
            Set-AgentStartState
            $f = New-DispatchFixture 'readfirst-matched'
            $one = Join-Path (Split-Path $f.BriefDir -Parent) 'brand.md'
            Set-Content -Path $one -Value 'teal' -Encoding utf8
            Set-ReadFirstBrief -Fixture $f -Body @(
                "- ``$($f.BriefDir)\read-first\brand.md`` - the settled brand. Read it in full.")

            $r = & $script:DispatchScript -RepoPath $f.Repo -Name 'T-6003' `
                -BriefPath $f.BriefPath -ReadPath $one
            $r.id | Should -Be 'T-6003'
            Test-Path -LiteralPath (Join-Path $f.BriefDir 'read-first\brand.md') | Should -BeTrue
        }

        # The check reads one section, not the whole brief: read-first\ named anywhere else is
        # ordinary prose, and a brief with nothing to read must still dispatch.
        It 'ignores read-first mentioned outside the Read first section' {
            Set-AgentStartState
            $f = New-DispatchFixture 'readfirst-elsewhere'
            Set-Content -Path $f.BriefPath -Encoding utf8 -Value @(
                '# Brief', '', '## Read first', '- Nothing beyond this brief.', ''
                '## Scope', 'Do NOT touch read-first\anything.md')

            (& $script:DispatchScript -RepoPath $f.Repo -Name 'T-6004' -BriefPath $f.BriefPath).id |
                Should -Be 'T-6004'
        }
    }
}
