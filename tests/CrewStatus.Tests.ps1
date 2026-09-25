# Get-CrewStatus.ps1 is the one join between what kingshand intended (crew.json) and what is
# actually running (herdr). Two things are worth more than any single field here.
#
# The first is the state vocabulary. `claude agents --json` said `done` when a worker had finished;
# herdr says `idle` whenever a worker is not mid-turn, which a worker also is for the seconds
# between `agent start` and its brief arriving. Anything that reads herdr's `idle` as the old
# `done` reports every worker finished the moment it starts, and the Hand tears down live work.
#
# The second is the join key. crew.json keeps kingshand's id; herdr only ever knows the normalised
# name ConvertTo-HerdrAgentName derives from it, and for an id that is not a clean pass-through the
# two differ by a hash suffix. Joining on the raw id would silently report every such worker dead.
#
# The third is that herdr's word for a stopped worker cannot be trusted. Measured on this machine,
# herdr 0.8.2 called a worker sitting on an unanswered menu `idle`, then called that same still
# blocked worker `done` while a genuinely finished one read `idle`. So `agentState` here is herdr's
# state corrected by the worker's live screen, through Get-HerdrAgentState, and the cases below
# pin both directions of that inversion.
#
# herdr is stubbed by a shim on PATH rather than by mocking a function, so the real Herdr.psm1
# argument list, JSON parsing and error handling are all exercised. Get-HerdrCommandPath honours a
# herdr on PATH ahead of the bundled one, which is what makes this possible.

BeforeAll {
    $script:StatusScript = Join-Path (Split-Path $PSScriptRoot -Parent) 'bin\Get-CrewStatus.ps1'
    Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'bin\Herdr.psm1') -Force

    $script:ShimDir   = Join-Path $TestDrive 'herdr-shim'
    $script:CallLog   = Join-Path $script:ShimDir 'calls.txt'
    $script:Response  = Join-Path $script:ShimDir 'response.json'
    $script:SavedPath = $env:PATH

    New-Item -ItemType Directory -Force -Path $script:ShimDir | Out-Null

    # The shim records every argument list so a test can assert how many calls were made, then
    # answers per command: `agent get <name>` and `agent read <name>` are per-worker and get their
    # own files, everything else gets response.json. A .cmd specifically: it has to resolve as an
    # Application, which is the only command type Get-HerdrCommandPath accepts.
    Set-Content -Path (Join-Path $script:ShimDir 'herdr.cmd') -Encoding ascii -Value @(
        '@echo off',
        '>>"%KINGSHAND_TEST_HERDR_CALLS%" echo %*',
        'if /I "%~2"=="get" goto agentget',
        'if /I "%~2"=="read" goto agentread',
        'type "%KINGSHAND_TEST_HERDR_RESPONSE%"',
        'goto :eof',
        ':agentget',
        'if exist "%KINGSHAND_TEST_HERDR_DIR%\get-%~3.json" type "%KINGSHAND_TEST_HERDR_DIR%\get-%~3.json"',
        'if not exist "%KINGSHAND_TEST_HERDR_DIR%\get-%~3.json" type "%KINGSHAND_TEST_HERDR_DIR%\notfound.json"',
        'goto :eof',
        ':agentread',
        'if exist "%KINGSHAND_TEST_HERDR_DIR%\screen-%~3.txt" type "%KINGSHAND_TEST_HERDR_DIR%\screen-%~3.txt"'
    )

    $env:KINGSHAND_TEST_HERDR_CALLS    = $script:CallLog
    $env:KINGSHAND_TEST_HERDR_RESPONSE = $script:Response
    $env:KINGSHAND_TEST_HERDR_DIR      = $script:ShimDir
    $env:PATH = $script:ShimDir + [IO.Path]::PathSeparator + $env:PATH

    @{ id = 'cli:agent:get'; error = @{ code = 'agent_not_found'; message = 'no such agent' } } |
        ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $script:ShimDir 'notfound.json') -Encoding utf8

    # A worker on an unanswered AskUserQuestion menu, and one whose turn has ended. Plain ASCII:
    # the real screens are drawn with box characters, but none of the phrases that tell the two
    # apart is one of them.
    $script:BlockedScreen = @'
> 1. Rewrite the parser
  2. Chat about this instead

  Enter to select, up/down to navigate
'@

    $script:FinishedScreen = '> Done. Wrote report.md and committed 3 files.'

    # $Agents is a list of hashtables shaped like herdr's AgentInfo - the fields this join reads
    # are name, agent_status and title. $Screens maps an agent name to what its live viewport
    # shows; anything unnamed shows a finished screen, which corrects nothing.
    function Set-HerdrAgents {
        param([object[]]$Agents = @(), [hashtable]$Screens = @{})
        @{ id = 'cli:agent:list'; result = @{ agents = @($Agents) } } |
            ConvertTo-Json -Depth 8 | Set-Content -Path $script:Response -Encoding utf8

        Get-ChildItem -LiteralPath $script:ShimDir -Filter 'get-*.json' -ErrorAction SilentlyContinue |
            Remove-Item -Force
        Get-ChildItem -LiteralPath $script:ShimDir -Filter 'screen-*.txt' -ErrorAction SilentlyContinue |
            Remove-Item -Force

        foreach ($a in @($Agents)) {
            @{ id = 'cli:agent:get'; result = @{ agent = $a } } | ConvertTo-Json -Depth 8 |
                Set-Content -Path (Join-Path $script:ShimDir "get-$($a.name).json") -Encoding utf8
            $screen = if ($Screens.ContainsKey($a.name)) { $Screens[$a.name] } else { $script:FinishedScreen }
            Set-Content -Path (Join-Path $script:ShimDir "screen-$($a.name).txt") -Value $screen -Encoding utf8
        }

        if (Test-Path -LiteralPath $script:CallLog) { Remove-Item -LiteralPath $script:CallLog -Force }
    }

    function Get-HerdrCallCount {
        if (-not (Test-Path -LiteralPath $script:CallLog)) { return 0 }
        @(Get-Content -LiteralPath $script:CallLog | Where-Object { $_.Trim() }).Count
    }

    function New-CrewFile {
        param([Parameter(Mandatory)][hashtable]$Workers, [Parameter(Mandatory)][string]$Name)
        $path = Join-Path $TestDrive "$Name.json"
        @{ workers = $Workers } | ConvertTo-Json -Depth 8 | Set-Content -Path $path -Encoding utf8
        $path
    }

    function Get-Status {
        param([Parameter(Mandatory)][string]$StatePath)
        @(& $script:StatusScript -StatePath $StatePath)
    }
}

AfterAll {
    $env:PATH = $script:SavedPath
    Remove-Item Env:\KINGSHAND_TEST_HERDR_CALLS    -ErrorAction SilentlyContinue
    Remove-Item Env:\KINGSHAND_TEST_HERDR_RESPONSE -ErrorAction SilentlyContinue
    Remove-Item Env:\KINGSHAND_TEST_HERDR_DIR      -ErrorAction SilentlyContinue
}

Describe 'the shim really is what herdr resolves to' {
    It 'puts the test double ahead of the bundled binary' {
        (Get-HerdrCommandPath) | Should -Be (Join-Path $script:ShimDir 'herdr.cmd') `
            -Because 'every case below is meaningless if the real herdr answered instead'
    }
}

Describe 'crew.json is joined with herdr on the normalised agent name' {
    It 'reports a worker herdr knows as live' {
        Set-HerdrAgents @(@{ name = 't-1001'; agent_status = 'working'; title = 'Editing src' })
        $state = New-CrewFile -Name 'live' -Workers @{
            'T-1001' = @{ ticket = 'T-1001'; kind = 'ticket'; repo = 'acme-web'; stage = 'implementing' }
        }

        $row = Get-Status $state | Where-Object { $_.id -eq 'T-1001' }
        $row.live       | Should -BeTrue -Because 'crew.json keeps T-1001 while herdr only ever knew t-1001'
        $row.agentState | Should -Be 'working'
    }

    It 'matches an id that normalisation had to rewrite, not just a clean pass-through' {
        # `9lives` cannot be a herdr name - it must start with a letter - so ConvertTo-HerdrAgentName
        # strips the digit and appends a digest of the original id to keep it collision-proof.
        # Joining on the raw id would report this worker dead while it was running.
        $herdrName = ConvertTo-HerdrAgentName -Name '9lives'
        $herdrName | Should -Not -Be '9lives' -Because 'this case only tests anything if the two differ'

        Set-HerdrAgents @(@{ name = $herdrName; agent_status = 'working'; title = '' })
        $state = New-CrewFile -Name 'normalised' -Workers @{
            '9lives' = @{ ticket = 'T-9'; kind = 'ticket'; repo = 'acme-api'; stage = 'dispatched' }
        }

        (Get-Status $state)[0].live | Should -BeTrue
    }

    It 'reports a worker herdr has never heard of as not live' {
        Set-HerdrAgents @(@{ name = 't-1001'; agent_status = 'working'; title = '' })
        $state = New-CrewFile -Name 'gone' -Workers @{
            'T-1002' = @{ ticket = 'T-1002'; kind = 'ticket'; repo = 'acme-api'; stage = 'ready' }
        }

        $row = Get-Status $state | Where-Object { $_.id -eq 'T-1002' }
        $row.live        | Should -BeFalse
        $row.agentState  | Should -Be ''
        $row.agentStatus | Should -Be ''
    }

    It 'reports a pre-herdr worker id as not live rather than failing the whole join' {
        # A supervisor-minted id from the `claude --bg` era was never a herdr name and never will
        # be. It must read as ended, and it must not stop the workers beside it being reported.
        Set-HerdrAgents @(@{ name = 't-1001'; agent_status = 'idle'; title = '' })
        $state = New-CrewFile -Name 'legacy' -Workers @{
            'b0f00ff5' = @{ ticket = 'acme-old'; kind = 'adhoc';  repo = 'acme-web'; stage = 'ready' }
            'T-1001'   = @{ ticket = 'T-1001';   kind = 'ticket'; repo = 'acme-web'; stage = 'implementing' }
        }

        $rows = Get-Status $state
        $rows.Count | Should -Be 2
        ($rows | Where-Object { $_.id -eq 'b0f00ff5' }).live | Should -BeFalse
        ($rows | Where-Object { $_.id -eq 'T-1001'   }).live | Should -BeTrue
    }
}

Describe 'herdr''s state words are reported as herdr''s, never as the old vocabulary' {
    # This is the mapping the whole port turns on. herdr's `idle` is "not mid-turn", which includes
    # a worker that has only just started and has not been given its brief yet. The old
    # `claude agents --json` used `done` for a worker that had finished. Translating one to the
    # other reports every worker finished the moment it starts.
    It 'carries idle through as idle, and never renames it to done or finished' {
        Set-HerdrAgents @(@{ name = 't-1001'; agent_status = 'idle'; title = '' })
        $state = New-CrewFile -Name 'idle' -Workers @{
            'T-1001' = @{ ticket = 'T-1001'; kind = 'ticket'; repo = 'acme-web'; stage = 'dispatched' }
        }

        $row = (Get-Status $state)[0]
        $row.live       | Should -BeTrue -Because 'idle is a live worker sitting at its prompt'
        $row.agentState | Should -Be 'idle'
        $row.agentState | Should -Not -Be 'done'
        $row.agentState | Should -Not -Be 'finished'
    }

    It 'carries each of herdr''s five states through unchanged' {
        foreach ($s in @('idle', 'working', 'blocked', 'done', 'unknown')) {
            Set-HerdrAgents @(@{ name = 't-1001'; agent_status = $s; title = '' })
            $state = New-CrewFile -Name "state-$s" -Workers @{
                'T-1001' = @{ ticket = 'T-1001'; kind = 'ticket'; repo = 'acme-web'; stage = 'implementing' }
            }
            (Get-Status $state)[0].agentState | Should -Be $s
        }
    }

    It 'surfaces blocked, because a blocked worker is waiting on a person' {
        Set-HerdrAgents @(@{ name = 't-1001'; agent_status = 'blocked'; title = 'Do you trust this folder?' })
        $state = New-CrewFile -Name 'blocked' -Workers @{
            'T-1001' = @{ ticket = 'T-1001'; kind = 'ticket'; repo = 'acme-web'; stage = 'dispatched' }
        }

        $row = (Get-Status $state)[0]
        $row.live        | Should -BeTrue
        $row.agentState  | Should -Be 'blocked'
        $row.agentStatus | Should -Be 'Do you trust this folder?'
    }
}

Describe 'a worker sitting on a prompt reports blocked, whatever herdr calls it' {
    # The measured failure, in both the directions it was measured in. herdr called a worker on an
    # unanswered menu `idle`, matched by live_prompt_box while every blocked rule failed, and
    # minutes later called that same still-blocked worker `done`. Since a wait with no -Until
    # returns on idle, done or blocked, either word wakes the Hand claiming completion - so a
    # worker waiting on a person is reported as finished, its worktree torn down, and work nobody
    # did reported as delivered.

    It 'corrects <herdrState> to blocked when the live screen shows a menu' -ForEach @(
        @{ herdrState = 'idle' }
        @{ herdrState = 'done' }
    ) {
        Set-HerdrAgents -Agents @(@{ name = 't-1001'; agent_status = $herdrState; title = 'Which approach?' }) `
                        -Screens @{ 't-1001' = $script:BlockedScreen }
        $state = New-CrewFile -Name "corrected-$herdrState" -Workers @{
            'T-1001' = @{ ticket = 'T-1001'; kind = 'ticket'; repo = 'acme-web'; stage = 'implementing' }
        }

        $row = (Get-Status $state)[0]
        $row.live       | Should -BeTrue
        $row.agentState | Should -Be 'blocked' -Because "herdr called a worker on an open menu $herdrState"
    }

    It 'leaves a genuinely finished worker at the word herdr gave it' {
        Set-HerdrAgents -Agents @(@{ name = 't-1001'; agent_status = 'idle'; title = '' }) `
                        -Screens @{ 't-1001' = $script:FinishedScreen }
        $state = New-CrewFile -Name 'uncorrected' -Workers @{
            'T-1001' = @{ ticket = 'T-1001'; kind = 'ticket'; repo = 'acme-web'; stage = 'implementing' }
        }

        (Get-Status $state)[0].agentState |
            Should -Be 'idle' -Because 'the correction only fires on a screen that is actually showing a prompt'
    }

    It 'reads the live viewport and never the scrollback' {
        # `recent` and `recent-unwrapped` include history, so a worker that answered a menu earlier
        # would read as blocked for the rest of its life.
        Set-HerdrAgents @(@{ name = 't-1001'; agent_status = 'working'; title = '' })
        $state = New-CrewFile -Name 'viewport' -Workers @{
            'T-1001' = @{ ticket = 'T-1001'; kind = 'ticket'; repo = 'acme-web'; stage = 'implementing' }
        }
        $null = Get-Status $state

        $reads = @(Get-Content -LiteralPath $script:CallLog | Where-Object { $_ -like '*agent read*' })
        $reads.Count | Should -Be 1
        $reads[0]    | Should -BeLike '*--source visible*'
        $reads[0].Contains('recent') | Should -BeFalse
    }
}

Describe 'the output shape other code and the skills format on' {
    It 'emits exactly the eight documented properties, under their existing names' {
        Set-HerdrAgents @(@{ name = 't-1001'; agent_status = 'working'; title = 'Running tests' })
        $state = New-CrewFile -Name 'shape' -Workers @{
            'T-1001' = @{ ticket = 'T-1001'; kind = 'ticket'; repo = 'acme-web'; stage = 'gating' }
        }

        $row = (Get-Status $state)[0]
        @($row.PSObject.Properties.Name) |
            Should -Be @('id', 'ticket', 'repo', 'stage', 'live', 'agentState', 'agentStatus', 'waitingOn')
        $row.ticket | Should -Be 'T-1001'
        $row.repo   | Should -Be 'acme-web'
        $row.stage  | Should -Be 'gating'
        $row.live   | Should -BeOfType [bool]
    }

    # A worker parked on the King's own decision has settled, so herdr reports it `idle` exactly
    # like a finished one. Without the pointer on the row there is nothing here that can tell them
    # apart, and every caller describes a worker waiting on an answer as still working.
    It 'carries the pointer through, so a parked worker is not reported as a working one' {
        Set-HerdrAgents @(@{ name = 't-1001'; agent_status = 'idle'; title = 'done for now' },
                          @{ name = 't-1002'; agent_status = 'idle'; title = 'done for now' })
        $state = New-CrewFile -Name 'parked' -Workers @{
            'T-1001' = @{ ticket = 'T-1001'; kind = 'ticket'; repo = 'acme-web'; stage = 'implementing'
                          waiting_on = 'T-1001-shorter-hero-copy' }
            'T-1002' = @{ ticket = 'T-1002'; kind = 'ticket'; repo = 'acme-web'; stage = 'implementing' }
        }

        $rows = Get-Status $state
        $parked   = $rows | Where-Object { $_.id -eq 'T-1001' }
        $finished = $rows | Where-Object { $_.id -eq 'T-1002' }

        $parked.waitingOn   | Should -Be 'T-1001-shorter-hero-copy'
        $finished.waitingOn | Should -Be '' -Because 'a record saved before the field existed is null, never absent'
        $parked.agentState  | Should -Be $finished.agentState -Because 'liveness cannot tell the two apart'
    }

    It 'keeps crew.json as the authority for intent even while herdr is the authority for liveness' {
        # herdr knows nothing about tickets, repos or stages, so a live agent must never overwrite
        # them - the two sources answer different questions.
        Set-HerdrAgents @(@{ name = 't-1001'; agent_status = 'idle'; title = 'anything at all' })
        $state = New-CrewFile -Name 'intent' -Workers @{
            'T-1001' = @{ ticket = 'T-1001'; kind = 'ticket'; repo = 'acme-web'; stage = 'ready' }
        }

        $row = (Get-Status $state)[0]
        $row.stage  | Should -Be 'ready'
        $row.repo   | Should -Be 'acme-web'
    }
}

Describe 'liveness costs one call plus a corrected state per live worker' {
    # The presence call is still one for the whole fleet. What the screen correction adds is
    # bounded by the LIVE workers only, which is the point: a dead or pre-herdr worker has no
    # screen to read, so a crew.json full of finished work costs nothing extra. The correction is
    # worth what it does cost, because the alternative is reporting a worker that is waiting on a
    # person as finished.
    It 'makes one list call, and none at all for the two workers herdr does not know' {
        Set-HerdrAgents @(
            @{ name = 't-1001'; agent_status = 'working'; title = '' },
            @{ name = 't-1002'; agent_status = 'idle';    title = '' }
        )
        $state = New-CrewFile -Name 'fleet' -Workers @{
            'T-1001' = @{ ticket = 'T-1001'; kind = 'ticket'; repo = 'r'; stage = 'implementing' }
            'T-1002' = @{ ticket = 'T-1002'; kind = 'ticket'; repo = 'r'; stage = 'ready' }
            'T-1003' = @{ ticket = 'T-1003'; kind = 'ticket'; repo = 'r'; stage = 'landed' }
            'T-1004' = @{ ticket = 'T-1004'; kind = 'ticket'; repo = 'r'; stage = 'failed' }
        }

        (Get-Status $state).Count | Should -Be 4

        $calls = @(Get-Content -LiteralPath $script:CallLog | Where-Object { $_.Trim() })
        @($calls | Where-Object { $_ -like '*agent list*' }).Count |
            Should -Be 1 -Because 'presence is still one call for the whole fleet'
        @($calls | Where-Object { $_ -like '*agent read*' }).Count |
            Should -Be 2 -Because 'only the two live workers have a screen worth reading'
        Get-HerdrCallCount | Should -Be 5
    }

    It 'makes no call at all when crew.json holds no workers' {
        Set-HerdrAgents @()
        $state = New-CrewFile -Name 'nobody' -Workers @{}

        (Get-Status $state).Count | Should -Be 0
        Get-HerdrCallCount | Should -Be 0 -Because 'nothing to join means nothing to ask herdr about'
    }

    It 'makes no call at all when crew.json does not exist' {
        Set-HerdrAgents @()
        (Get-Status (Join-Path $TestDrive 'no-such-crew.json')).Count | Should -Be 0
        Get-HerdrCallCount | Should -Be 0
    }
}

Describe 'a herdr that cannot answer reports no live workers rather than inventing them' {
    It 'reads a server that is not running as no live agents' {
        # herdr's panes die with its server, so server_not_running really does mean no worker is
        # alive. It is an ordinary answer, not a fault, and it must not take the join down.
        @{ id = 'cli:agent:list'; error = @{ code = 'server_not_running'; message = 'no herdr server is running' } } |
            ConvertTo-Json -Depth 6 | Set-Content -Path $script:Response -Encoding utf8

        $state = New-CrewFile -Name 'noserver' -Workers @{
            'T-1001' = @{ ticket = 'T-1001'; kind = 'ticket'; repo = 'acme-web'; stage = 'implementing' }
        }

        { Get-Status $state } | Should -Not -Throw
        $rows = Get-Status $state
        $rows.Count       | Should -Be 1
        $rows[0].live     | Should -BeFalse
        $rows[0].stage    | Should -Be 'implementing' -Because 'intent survives a liveness answer of none'
    }
}
