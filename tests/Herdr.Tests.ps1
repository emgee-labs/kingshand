#Requires -Version 7.0
Set-StrictMode -Version Latest

# bin\Herdr.psm1 is exercised here with NO herdr server running and no herdr binary invoked.
# `Invoke-Herdr` is the single boundary between this module and the outside world - every command
# in it goes through that one function - so mocking it is what makes the whole module testable
# without a live server, a live pane, or a live Claude Code worker.
#
# Every case below pins a rule that was learned from an observed failure on this machine against
# herdr 0.8.2 (protocol 20), not from the documentation, and re-measured against herdr 0.9.5
# (protocol 22) - the 0.9.5 captures are at the end. The comments name which failure.

BeforeAll {
    Import-Module "$PSScriptRoot\..\bin\Herdr.psm1" -Force

    # herdr's own rule, copied from its error message rather than paraphrased. Every name this
    # module hands to `agent start` has to satisfy it or the CLI answers invalid_agent_name.
    $script:AgentNamePattern = '^[a-z][a-z0-9_-]{0,31}$'

    $script:TempFixtures = [System.Collections.Generic.List[string]]::new()

    function New-TempFixtureDir {
        param([Parameter(Mandatory)][string]$Prefix)
        $p = Join-Path ([System.IO.Path]::GetTempPath()) ($Prefix + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $p | Out-Null
        $script:TempFixtures.Add($p)
        $p
    }

    # A file called herdr.exe and nothing more. Get-Command resolves an Application by name and
    # extension, never by reading the file, so a stub is enough to prove which candidate the
    # discovery rule picks - and no test here ever executes it.
    function New-StubHerdr {
        param([Parameter(Mandatory)][string]$Directory)
        $exe = Join-Path $Directory 'herdr.exe'
        Set-Content -LiteralPath $exe -Value 'stub' -Encoding utf8
        $exe
    }

    # herdr's own reply shapes. Both results and errors arrive as JSON; `Invoke-Herdr` returns the
    # `result` payload on success and the whole parsed object when -AllowError caught an error, so
    # the mocks below return exactly those two shapes and nothing invented.
    function New-HerdrError {
        param([Parameter(Mandatory)][string]$Code, [string]$Message = 'from the mock')
        [pscustomobject]@{ error = [pscustomobject]@{ code = $Code; message = $Message } }
    }

    function New-HerdrAgentResult {
        param([string]$Name = 'worker', [string]$State = 'idle', [string]$PaneId = 'pane-1')
        [pscustomobject]@{
            agent = [pscustomobject]@{ name = $Name; state = $State; pane_id = $PaneId }
        }
    }

    # Test-HerdrAgentAwaitingInput crosses a different boundary from everything above: it runs the
    # herdr binary directly rather than through Invoke-Herdr, because a screen is text and not
    # JSON. So the binary itself is stubbed - a script that records the argument list it was given
    # and prints whatever screen the test asked for. No server, no pane, no worker.
    #
    # The paths travel in environment variables rather than script variables because the stub is a
    # separate process and the Get-HerdrCommandPath mock runs inside the module.
    #
    # It always exits explicitly, so the exit status a caller reads belongs to the call it just made
    # rather than to whatever ran before it - which is how the real binary behaves and what the
    # failure cases below depend on.
    function Initialize-HerdrScreenStub {
        $dir = New-TempFixtureDir -Prefix 'herdr-screen-'
        $env:KINGSHAND_TEST_HERDR_EXE    = Join-Path $dir 'herdr-stub.ps1'
        $env:KINGSHAND_TEST_HERDR_ARGS   = Join-Path $dir 'args.txt'
        $env:KINGSHAND_TEST_HERDR_SCREEN = Join-Path $dir 'screen.txt'
        $env:KINGSHAND_TEST_HERDR_EXIT   = ''
        Set-Content -LiteralPath $env:KINGSHAND_TEST_HERDR_EXE -Encoding utf8 -Value @'
Add-Content -LiteralPath $env:KINGSHAND_TEST_HERDR_ARGS -Value ($args -join ' ')
if (Test-Path -LiteralPath $env:KINGSHAND_TEST_HERDR_SCREEN) {
    Get-Content -LiteralPath $env:KINGSHAND_TEST_HERDR_SCREEN -Raw
}
$code = 0
if ($env:KINGSHAND_TEST_HERDR_EXIT) { $code = [int]$env:KINGSHAND_TEST_HERDR_EXIT }
exit $code
'@
        $dir
    }

    function Set-HerdrScreen {
        param([string]$Text = '')
        $env:KINGSHAND_TEST_HERDR_EXIT = ''
        Set-Content -LiteralPath $env:KINGSHAND_TEST_HERDR_SCREEN -Value $Text -Encoding utf8
        if (Test-Path -LiteralPath $env:KINGSHAND_TEST_HERDR_ARGS) {
            Remove-Item -LiteralPath $env:KINGSHAND_TEST_HERDR_ARGS -Force
        }
    }

    # herdr failing to read a pane: its own error, on the success path, because the read folds
    # stderr into stdout. The text is deliberately wide - the whole point is that it is not empty
    # and does not look narrow, so nothing about its shape gives it away.
    function Set-HerdrScreenFailure {
        param(
            [string]$Text = '{"error":{"code":"pane_not_found","message":"there is no pane for agent t-9001 any more"}}',
            [int]$ExitCode = 1
        )
        Set-HerdrScreen $Text
        $env:KINGSHAND_TEST_HERDR_EXIT = "$ExitCode"
    }

    function Get-HerdrStubArgs {
        if (-not (Test-Path -LiteralPath $env:KINGSHAND_TEST_HERDR_ARGS)) { return @() }
        @(Get-Content -LiteralPath $env:KINGSHAND_TEST_HERDR_ARGS | Where-Object { $_.Trim() })
    }

    # A worker sitting on an unanswered AskUserQuestion menu, and one whose turn has ended. Plain
    # ASCII on purpose: the real screens are drawn with box characters, but none of the phrases
    # that tell the two apart is one, and a test fixture that depends on file encoding is a test
    # that fails for the wrong reason.
    $script:BlockedScreen = @'
  Which approach should I take?

> 1. Rewrite the parser
  2. Patch the caller
  3. Chat about this instead

  Enter to select, up/down to navigate
'@

    $script:FinishedScreen = @'
> Done. Committed 3 files and wrote report.md.

  [ ]                                             ? for shortcuts
'@

    # An idle worker whose input box holds text nobody sent. This is the harness's own prompt
    # suggestion, rendered into the empty box after a turn ends - not input, and it cannot
    # concatenate, but a bare Enter submits it as though the Hand had written it.
    #
    # The shape is copied off the capture of the worker that produced this, reproduced in
    # docs\2026-09-02-prompt-box-safety.md: a bare U+2500 rule, then the caret at column 0, then
    # another rule. There are no U+2502 side borders on a real screen, and a fixture that invents
    # them is a fixture the detector can be tightened against while never matching a live worker.
    #
    # `u{276F} and `u{00A0} are escaped deliberately. The box line really is `❯` followed by a
    # NO-BREAK space, measured off that capture, and a literal no-break space in a fixture is
    # invisible in every diff it appears in - which is how it gets "tidied" into a plain space and
    # quietly stops testing anything.
    $script:SuggestionScreen = @"
  Done. Committed 3 files and wrote report.md.

────────────────────────────────────────────────────────────────────────────────────────────
`u{276F}`u{00A0}show me the getting started section rendered
────────────────────────────────────────────────────────────────────────────────────────────
    ? for shortcuts
"@

    # The same worker with nothing in the box - the ordinary case, which must not be refused.
    $script:EmptyBoxScreen = @"
  Done. Committed 3 files and wrote report.md.

────────────────────────────────────────────────────────────────────────────────────────────
`u{276F}`u{00A0}
────────────────────────────────────────────────────────────────────────────────────────────
    ? for shortcuts
"@

    # A worker blocked on a numbered option menu, drawn the way Claude Code really draws one: the
    # SAME `❯` cursor as the box, but followed by a PLAIN space rather than a no-break one. That one
    # glyph is all that separates a menu row from box content, and the box detector returns its first
    # match top-down - so a caret-only rule reads '1. Rewrite the parser' as text the Hand must
    # explain, refuses the bare Enter that answers the menu, and leaves the worker unanswerable.
    $script:MenuScreen = @"
  Which approach should I take?

`u{276F} 1. Rewrite the parser
  2. Patch the caller
  3. Chat about this instead

  Enter to select, up/down to navigate
"@

    # The same box shape as SuggestionScreen and EmptyBoxScreen, with whatever line the case needs
    # sitting in the box. The placeholder cases below all differ only in that one line.
    function New-BoxScreen {
        param([string]$Box = '', [string]$Footer = '? for shortcuts')
        $rule = ([string][char]0x2500) * 92
        @"
  Done. Committed 3 files and wrote report.md.

$rule
`u{276F}`u{00A0}$Box
$rule
    $Footer
"@
    }

    # Claude Code's own placeholder text, quoted as the shipped 2.1.200 binary emits it rather than
    # paraphrased. It is dim-styled and drawn into the EMPTY box in exactly the position box content
    # occupies, so a detector working on position alone reads it as text the Hand must explain -
    # which would refuse every send to a worker the harness happened to print a hint at.
    $script:QueuedHintBox = 'Press up to edit queued messages'
    $script:TeammateBox   = "Message @reviewer`u{2026}"
    $script:TryBox        = 'Try "how do I log an error?"'
}

AfterAll {
    foreach ($p in $script:TempFixtures) {
        if (Test-Path -LiteralPath $p) {
            Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    $script:TempFixtures.Clear()

    foreach ($v in 'KINGSHAND_TEST_HERDR_EXE', 'KINGSHAND_TEST_HERDR_ARGS', 'KINGSHAND_TEST_HERDR_SCREEN') {
        Remove-Item "Env:\$v" -ErrorAction SilentlyContinue
    }
}

Describe 'ConvertTo-HerdrAgentName produces a name herdr will accept' {
    # `agent start T-9001` fails outright with invalid_agent_name - herdr rejects rather than
    # normalising, and an uppercase ticket id is the ordinary shape kingshand deals in.

    It 'lowercases <id> to <expected>' -ForEach @(
        @{ id = 'T-9001';   expected = 't-9001' }
        @{ id = 'ABC123';   expected = 'abc123' }
        @{ id = 'Worker_A'; expected = 'worker_a' }
    ) {
        ConvertTo-HerdrAgentName -Name $id | Should -Be $expected
    }

    It 'passes an already-legal name straight through unchanged' {
        ConvertTo-HerdrAgentName -Name 'login-fix' | Should -Be 'login-fix'
    }

    It 'matches herdr''s own pattern for <id>' -ForEach @(
        @{ id = 'T-9001' }
        @{ id = 'ABC123' }
        @{ id = 'login-fix' }
        @{ id = '9lives' }
        @{ id = 'AB/CD:EF' }
        @{ id = '  spaced out  ' }
        @{ id = '---leading-dashes' }
        @{ id = 'trailing-dashes---' }
        @{ id = '2026-08-29-nightly-regression-sweep-for-the-billing-service' }
        @{ id = 'A' }
        @{ id = ("Z" * 64) }
    ) {
        ConvertTo-HerdrAgentName -Name $id | Should -Match $script:AgentNamePattern
    }

    It 'never exceeds the 32 characters herdr allows' {
        $name = ConvertTo-HerdrAgentName -Name ('long-ticket-identifier-' * 5)
        $name.Length | Should -BeLessOrEqual 32
        $name | Should -Match $script:AgentNamePattern
    }

    # Normalisation that merely discards characters is not safe. Two live workers under one herdr
    # name means a prompt meant for one lands in the other, silently, with no error anywhere.
    It 'does not collide 9lives with lives, though a leading digit must be dropped' {
        $a = ConvertTo-HerdrAgentName -Name '9lives'
        $b = ConvertTo-HerdrAgentName -Name 'lives'
        $a | Should -Not -Be $b
        $a | Should -Match $script:AgentNamePattern
        $b | Should -Match $script:AgentNamePattern
    }

    It 'does not collide two over-long ids that share a long prefix' {
        $prefix = 'ticket-for-the-billing-service-regression'   # 40 characters, well past 32
        $a = ConvertTo-HerdrAgentName -Name "$prefix-alpha"
        $b = ConvertTo-HerdrAgentName -Name "$prefix-beta"
        $a | Should -Not -Be $b -Because 'truncating at 32 would map both onto the same herdr agent'
        $a | Should -Match $script:AgentNamePattern
        $b | Should -Match $script:AgentNamePattern
    }

    It 'keeps a whole batch of near-identical ids distinct' {
        # Deliberately no case-only pair here: 'Lives' and 'lives' are the SAME id to herdr once
        # lowercased, and folding them together is the intended behaviour rather than a collision.
        $ids = @(
            '9lives', 'lives', '-lives'
            ('shared-prefix-that-is-far-too-long-for-herdr' + '-one')
            ('shared-prefix-that-is-far-too-long-for-herdr' + '-two')
            ('shared-prefix-that-is-far-too-long-for-herdr' + '-three')
        )
        $names = @($ids | ForEach-Object { ConvertTo-HerdrAgentName -Name $_ })
        @($names | Sort-Object -Unique).Count |
            Should -Be $ids.Count -Because 'two workers sharing one herdr name misroute each other''s prompts'
    }

    It 'is deterministic, so the same id resolves to the same agent every time' {
        $first  = ConvertTo-HerdrAgentName -Name 'T-9001-URGENT-BILLING-REGRESSION-SWEEP'
        $second = ConvertTo-HerdrAgentName -Name 'T-9001-URGENT-BILLING-REGRESSION-SWEEP'
        $first | Should -Be $second -Because 'every later command re-derives the name from the id'
    }

    # There is nothing to salvage here: the pattern demands a leading letter, and inventing one
    # would give two unrelated ids the same made-up stem.
    It 'throws for <id>, which carries no letter at all' -ForEach @(
        @{ id = '9001' }
        @{ id = '---' }
        @{ id = '9-0_1' }
        @{ id = '2026-08-29' }
    ) {
        { ConvertTo-HerdrAgentName -Name $id } | Should -Throw "*no letter in it*"
    }
}

Describe 'Get-HerdrCommandPath prefers a herdr on PATH over the bundled copy' {
    # tools\ is gitignored, so herdr is fetched by the installer rather than vendored. A user who
    # manages their own herdr install must not be forced into a second copy of an 8.4 MB binary,
    # so PATH wins - but a fresh install with nothing on PATH must still find what install.ps1
    # put in tools\herdr\.
    BeforeAll {
        $script:OnPathDir = New-TempFixtureDir -Prefix 'herdr-path-'
        $script:OnPathExe = New-StubHerdr -Directory $script:OnPathDir

        $script:FakeHome  = New-TempFixtureDir -Prefix 'herdr-home-'
        $bundledDir       = Join-Path $script:FakeHome 'tools\herdr'
        New-Item -ItemType Directory -Force -Path $bundledDir | Out-Null
        $script:BundledExe = New-StubHerdr -Directory $bundledDir

        $script:EmptyDir = New-TempFixtureDir -Prefix 'herdr-empty-'
    }

    BeforeEach {
        $script:SavedPath = $env:PATH
        $script:SavedHome = $env:KINGSHAND_HOME
        $env:KINGSHAND_HOME = $script:FakeHome
    }

    AfterEach {
        $env:PATH = $script:SavedPath
        if ($null -eq $script:SavedHome) { Remove-Item Env:\KINGSHAND_HOME -ErrorAction SilentlyContinue }
        else { $env:KINGSHAND_HOME = $script:SavedHome }
    }

    It 'returns the herdr on PATH when there is one' {
        $env:PATH = $script:OnPathDir
        Get-HerdrCommandPath | Should -Be $script:OnPathExe
    }

    It 'falls back to tools\herdr\herdr.exe when PATH has none' {
        $env:PATH = $script:EmptyDir
        Get-HerdrCommandPath | Should -Be $script:BundledExe
    }

    It 'returns nothing at all when neither exists, rather than a path that is not there' {
        $env:PATH = $script:EmptyDir
        $env:KINGSHAND_HOME = $script:EmptyDir
        Get-HerdrCommandPath | Should -BeNullOrEmpty
    }
}

Describe 'Get-HerdrCommandHint tells the reader what to run' {
    # A check that reports "missing" without naming the fix is a check the reader learns to ignore,
    # and this one message is what both install.ps1 and Test-CrewPrereqs.ps1 print.
    It 'names the installer, the switch and the verification' {
        $hint = Get-HerdrCommandHint
        $hint | Should -Match 'install\.ps1 -InstallMissing'
        $hint | Should -Match 'tools\\herdr'
        $hint | Should -Match 'SHA-256'
    }
}

Describe 'Get-HerdrServerState tells a stopped server apart from a status read that failed' {
    # The boolean beside it cannot: Test-HerdrServer answers $false to a server that is genuinely
    # down and to a status call that exited non-zero, printed nothing, or answered a shape it did
    # not recognise. A guard that refuses an action on liveness needs those apart, because "could
    # not tell" read as "nothing is running" is how an update walks over a live worker.
    #
    # The binary is stubbed rather than mocked, the same way the screen readers below are, because
    # this one runs herdr directly to keep its exit code rather than going through Invoke-Herdr.

    BeforeAll { $script:ServerStateDir = Initialize-HerdrScreenStub }
    BeforeEach { Mock -ModuleName Herdr Get-HerdrCommandPath { $env:KINGSHAND_TEST_HERDR_EXE } }

    It 'asks for JSON rather than parsing the prose shape' {
        Set-HerdrScreen '{"server":{"status":"running","running":true,"protocol":20}}'
        $null = Get-HerdrServerState

        $calls = @(Get-HerdrStubArgs)
        $calls.Count | Should -Be 1
        $calls[0] | Should -Match '(^|\s)status(\s|$)'
        $calls[0] | Should -Match '--json' -Because 'a regex over prose stops matching silently when the shape moves'
    }

    It 'reports a running server' {
        Set-HerdrScreen '{"client":{"protocol":20},"server":{"status":"running","running":true}}'

        $s = Get-HerdrServerState
        $s.state | Should -Be 'running'
    }

    It 'reports a stopped server, and carries herdr''s own word for it' {
        Set-HerdrScreen '{"server":{"status":"not running","running":false}}'

        $s = Get-HerdrServerState
        $s.state  | Should -Be 'stopped'
        $s.detail | Should -Match 'not running'
    }

    It 'believes a readable server.running over a non-zero exit, in both directions' -ForEach @(
        @{ running = 'false'; word = 'not running'; expected = 'stopped' }
        @{ running = 'true';  word = 'running';     expected = 'running' }
    ) {
        # 0.8.2 and 0.9.5 both exit 0 for a server that is down, measured on 2026-10-22, but a later
        # herdr may not, so nothing here may rest on the exit code. A reply that parses and says
        # whether the server is running has already answered the question, and reading the exit
        # code first would refuse `/update` on the ordinary machine of a user who has simply never
        # dispatched anything.
        Set-HerdrScreenFailure -Text "{`"server`":{`"status`":`"$word`",`"running`":$running}}" -ExitCode 1

        $s = Get-HerdrServerState
        $s.state  | Should -Be $expected -Because 'the parsed field is the evidence, not the exit status'
        $s.detail | Should -Match 'exited 1' -Because 'a reader still gets to see what herdr exited with'
    }

    It 'reports unknown when the call exited non-zero AND said nothing readable' {
        Set-HerdrScreenFailure -Text '{"error":{"code":"transport","message":"could not reach the server"}}' -ExitCode 1

        $s = Get-HerdrServerState
        $s.state  | Should -Be 'unknown' -Because 'nothing in that reply says whether the server is running'
        $s.detail | Should -Match 'exited 1'
    }

    It 'reports unknown when the reply does not parse at all' {
        Set-HerdrScreen 'herdr: unrecognised option --json'

        $s = Get-HerdrServerState
        $s.state  | Should -Be 'unknown'
        $s.detail | Should -Match 'did not parse as JSON'
    }

    It 'reports unknown when server.running is not a boolean, which is a shape that moved' {
        Set-HerdrScreen '{"server":{"status":"running","running":"yes"}}'

        $s = Get-HerdrServerState
        $s.state | Should -Be 'unknown' -Because 'a non-empty string is truthy, so guessing here would invent a running server'
    }

    It 'reports unknown when the reply carries no server.running at all, renamed by an upgrade' {
        Set-HerdrScreen '{"server":{"protocol":21},"update":{}}'

        $s = Get-HerdrServerState
        $s.state  | Should -Be 'unknown' -Because 'a herdr upgrade that renames the field must not read as stopped'
        $s.detail | Should -Match 'whether the server is running'
    }

    It 'reports unknown when the reply carries no server object' {
        Set-HerdrScreen '{"client":{"protocol":20},"update":{}}'

        $s = Get-HerdrServerState
        $s.state  | Should -Be 'unknown'
        $s.detail | Should -Match 'without a server object'
    }

    It 'reports unknown when the status call printed nothing' {
        Set-HerdrScreen ''

        $s = Get-HerdrServerState
        $s.state  | Should -Be 'unknown'
        $s.detail | Should -Match 'nothing at all'
    }

    It 'reports unknown, and says how to fix it, when there is no herdr to ask' {
        Mock -ModuleName Herdr Get-HerdrCommandPath { $null }

        $s = Get-HerdrServerState
        $s.state  | Should -Be 'unknown'
        $s.detail | Should -Match 'herdr was not found'
    }
}

Describe 'Get-HerdrAgentInventory keeps the failure that Get-HerdrAgents throws away' {
    # Two readers of the same `agent list` on purpose. Get-HerdrAgents answers an unreachable herdr
    # with an empty list, which is what a status view wants; this one says it could not read the
    # list, which is what a guard that refuses an action needs. Collapsing the second into the first
    # is how "could not ask" becomes "nobody is working" - see bin\Update.psm1's liveness guard.

    It 'reports the agents herdr listed' {
        Mock -ModuleName Herdr Invoke-Herdr {
            [pscustomobject]@{ agents = @(
                [pscustomobject]@{ name = 't-9001'; state = 'working' }
                [pscustomobject]@{ name = 't-9002'; state = 'idle' }
            ) }
        }

        $inventory = Get-HerdrAgentInventory
        $inventory.ok    | Should -BeTrue
        $inventory.error | Should -Be ''
        @($inventory.agents).Count | Should -Be 2
        @($inventory.agents | ForEach-Object { $_.name }) | Should -Be @('t-9001', 't-9002')
    }

    It 'reports an empty list as a list that was read, not as a failure' {
        Mock -ModuleName Herdr Invoke-Herdr { [pscustomobject]@{ agents = @() } }

        $inventory = Get-HerdrAgentInventory
        $inventory.ok | Should -BeTrue -Because 'herdr answered, and its answer was that nobody is there'
        @($inventory.agents).Count | Should -Be 0
    }

    It 'reports herdr''s own error rather than an empty list' {
        Mock -ModuleName Herdr Invoke-Herdr { New-HerdrError -Code 'server_unavailable' -Message 'no server' }

        $inventory = Get-HerdrAgentInventory
        $inventory.ok    | Should -BeFalse
        $inventory.error | Should -Match 'server_unavailable'
        $inventory.error | Should -Match 'no server'
        @($inventory.agents).Count | Should -Be 0
    }

    It 'reports a reply that could not be read at all' {
        Mock -ModuleName Herdr Invoke-Herdr { $null }

        $inventory = Get-HerdrAgentInventory
        $inventory.ok    | Should -BeFalse
        $inventory.error | Should -Match 'nothing that could be read'
    }

    It 'reports a reply that carried no agents list' {
        Mock -ModuleName Herdr Invoke-Herdr { [pscustomobject]@{ panes = @() } }

        $inventory = Get-HerdrAgentInventory
        $inventory.ok    | Should -BeFalse -Because 'a reply with no agents in it did not answer the question'
        $inventory.error | Should -Match 'without an agents list'
    }
}

Describe 'Send-HerdrPrompt routes a blocked worker rather than throwing at it' {
    # agent_blocked is a state, not a fault: the worker is sitting on an interactive prompt and
    # cannot take text until it is answered. Throwing would make every caller wrap this in a
    # try/catch and read a routine, recoverable state as a failure.

    # The prompt-box guard reads the worker's live screen, which none of these cases is about, and
    # an unmocked read would run whatever herdr the machine happens to have against whatever server
    # happens to be up. An empty box is the ordinary case, so that is what they get. The guard
    # itself is exercised further down.
    BeforeEach { Mock -ModuleName Herdr Get-HerdrAgentPromptBox { '' } }

    It 'returns a blocked result instead of throwing when herdr answers agent_blocked' {
        Mock -ModuleName Herdr Invoke-Herdr { New-HerdrError -Code 'agent_blocked' -Message 'agent is blocked' }

        $result = $null
        { $script:result = Send-HerdrPrompt -Name 'T-9001' -Text 'do the thing' } |
            Should -Not -Throw -Because 'a blocked worker is a state the caller routes on'
        $script:result.blocked | Should -BeTrue
        $script:result.error   | Should -Be 'agent_blocked'
    }

    It 'throws on <code>, which is a real fault and not a state' -ForEach @(
        @{ code = 'agent_not_found' }
        @{ code = 'invalid_agent_name' }
        @{ code = 'timeout' }
        @{ code = 'pane_not_found' }
    ) {
        Mock -ModuleName Herdr Invoke-Herdr { New-HerdrError -Code $code -Message 'boom' }
        { Send-HerdrPrompt -Name 'T-9001' -Text 'do the thing' } | Should -Throw "*$code*"
    }

    It 'returns the agent on success' {
        Mock -ModuleName Herdr Invoke-Herdr { New-HerdrAgentResult -Name 't-9001' -State 'working' }
        $agent = Send-HerdrPrompt -Name 'T-9001' -Text 'do the thing'
        $agent.name  | Should -Be 't-9001'
        $agent.state | Should -Be 'working'
    }

    It 'sends the normalised agent name, never the kingshand id' {
        Mock -ModuleName Herdr Invoke-Herdr { New-HerdrAgentResult }
        $null = Send-HerdrPrompt -Name 'T-9001' -Text 'do the thing'
        Should -Invoke Invoke-Herdr -ModuleName Herdr -Times 1 -Exactly -ParameterFilter {
            $Arguments[2] -eq 't-9001'
        }
    }

    It 'asks herdr to wait only when -Wait was given' {
        Mock -ModuleName Herdr Invoke-Herdr { New-HerdrAgentResult }
        $null = Send-HerdrPrompt -Name 'T-9001' -Text 'do the thing'
        Should -Invoke Invoke-Herdr -ModuleName Herdr -Times 0 -Exactly -ParameterFilter {
            $Arguments -contains '--wait'
        } -Because 'the caller arms its own wait at dispatch; a stale status is read here on purpose'

        $null = Send-HerdrPrompt -Name 'T-9001' -Text 'do the thing' -Wait
        Should -Invoke Invoke-Herdr -ModuleName Herdr -Times 1 -Exactly -ParameterFilter {
            $Arguments -contains '--wait'
        }
    }
}

Describe 'Send-HerdrKeys sends one key per call and never batches them' {
    # THE GUARD AGAINST A SILENT WRONG ANSWER. `agent send-keys <target> down enter` in a single
    # invocation selects the WRONG option - the Enter is delivered before the TUI has processed the
    # arrow - and it returns success while doing it. A wrong answer with no error is the worst
    # failure shape available, and the only thing standing between kingshand and it is that this
    # function issues one herdr command per key. So the call COUNT is the assertion.

    BeforeEach {
        Mock -ModuleName Herdr Invoke-Herdr { $null }
        # Same reason as above: these cases are about the call count, not about the box, and none
        # of them opens with an Enter. The refusal that does is exercised further down.
        Mock -ModuleName Herdr Get-HerdrAgentPromptBox { '' }
    }

    It 'issues exactly one herdr command per key for a two-key sequence' {
        Send-HerdrKeys -Name 'T-9001' -Keys @('down', 'enter') -DelayMs 0
        Should -Invoke Invoke-Herdr -ModuleName Herdr -Times 2 -Exactly
    }

    It 'issues exactly one herdr command per key for a longer sequence' {
        Send-HerdrKeys -Name 'T-9001' -Keys @('down', 'down', 'down', 'enter') -DelayMs 0
        Should -Invoke Invoke-Herdr -ModuleName Herdr -Times 4 -Exactly
    }

    It 'puts each key in its own invocation, one at a time' {
        Send-HerdrKeys -Name 'T-9001' -Keys @('down', 'enter') -DelayMs 0
        Should -Invoke Invoke-Herdr -ModuleName Herdr -Times 1 -Exactly -ParameterFilter {
            $Arguments.Count -eq 4 -and $Arguments[3] -eq 'down'
        }
        Should -Invoke Invoke-Herdr -ModuleName Herdr -Times 1 -Exactly -ParameterFilter {
            $Arguments.Count -eq 4 -and $Arguments[3] -eq 'enter'
        }
    }

    It 'never puts two keys in one invocation' {
        Send-HerdrKeys -Name 'T-9001' -Keys @('down', 'down', 'enter') -DelayMs 0
        Should -Invoke Invoke-Herdr -ModuleName Herdr -Times 0 -Exactly -ParameterFilter {
            $Arguments.Count -gt 4
        } -Because 'a batched arrow-then-Enter picks the wrong option and reports success'
    }

    It 'refuses an empty key list rather than reporting a keypress it never sent' {
        # -Keys is mandatory, so an empty list is rejected at the parameter binder. A caller that
        # computed no keys is told so, instead of getting a silent success for answering nothing -
        # which is the same class of silent wrong answer the one-key-per-call rule exists for.
        { Send-HerdrKeys -Name 'T-9001' -Keys @() -DelayMs 0 } | Should -Throw
        Should -Invoke Invoke-Herdr -ModuleName Herdr -Times 0 -Exactly
    }
}

# ---------------------------------------------------------------------------------------------
# The prompt box, and the guard that stops the Hand submitting text it never wrote.
#
# A worker's input box can hold a prompt suggestion the harness generated and rendered there after
# a turn ended. It is not input and it cannot concatenate - the first typed character displaces it -
# but a bare Enter ACCEPTS it, so `Send-HerdrKeys -Keys @('enter')` at an idle worker submits a
# model-generated instruction as though the Hand had written it. `rally` step 3 sends exactly that
# call to answer a menu. docs\2026-09-02-prompt-box-safety.md is the record.
#
# Every refusing case below asserts BOTH that it throws AND that nothing reached herdr, so no case
# can pass vacuously: delete the guard and both assertions fail independently.
# ---------------------------------------------------------------------------------------------
Describe 'the send paths refuse to write into a box the caller did not fill' {
    BeforeAll { $script:BoxGuardDir = Initialize-HerdrScreenStub }

    BeforeEach {
        Mock -ModuleName Herdr Get-HerdrCommandPath { $env:KINGSHAND_TEST_HERDR_EXE }
        # Everything that would actually reach herdr, recorded rather than sent. A refusal that
        # threw after submitting would be no guard at all, so the recording is the second half of
        # every case here.
        $script:reached = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName Herdr Invoke-Herdr {
            $script:reached.Add(($Arguments -join ' '))
            New-HerdrAgentResult
        }
    }

    It 'refuses a prompt rather than typing over the box' {
        Set-HerdrScreen $script:SuggestionScreen

        { Send-HerdrPrompt -Name 'T-9001' -Text 'do the thing' } | Should -Throw '*getting started*'
        $script:reached.Count |
            Should -Be 0 -Because 'a refusal that still submitted would be worse than no guard'
    }

    It 'names the worker in the refusal, so the reader knows which box to look at' {
        Set-HerdrScreen $script:SuggestionScreen
        { Send-HerdrPrompt -Name 'T-9001' -Text 'do the thing' } | Should -Throw '*T-9001*'
    }

    # THE GUARD THAT MATTERS. Nothing about a bare Enter looks dangerous, and it is the one call
    # that submits whatever happens to be rendered in the box.
    It 'refuses a bare enter, which would submit whatever is in the box' {
        Set-HerdrScreen $script:SuggestionScreen

        { Send-HerdrKeys -Name 'T-9001' -Keys @('enter') -DelayMs 0 } | Should -Throw '*getting started*'
        $script:reached.Count | Should -Be 0
    }

    # REFUSE, NEVER CLEAR. The box is the only evidence that the event happened at all, and an
    # escape sent to tidy it up destroys exactly what the King needs to see.
    It 'leaves the box alone rather than clearing it' {
        Set-HerdrScreen $script:SuggestionScreen
        { Send-HerdrPrompt -Name 'T-9001' -Text 'do the thing' } | Should -Throw
        $script:reached.Count |
            Should -Be 0 -Because 'clearing the box would destroy the evidence of the event'
    }

    It 'proceeds with a prompt when the caller has accepted the risk' {
        Set-HerdrScreen $script:SuggestionScreen
        $null = Send-HerdrPrompt -Name 'T-9001' -Text 'do the thing' -AllowNonEmptyBox
        ($script:reached -join ' ') | Should -BeLike '*do the thing*'
    }

    It 'proceeds with a bare enter when the caller has accepted the risk' {
        Set-HerdrScreen $script:SuggestionScreen
        Send-HerdrKeys -Name 'T-9001' -Keys @('enter') -DelayMs 0 -AllowNonEmptyBox
        ($script:reached -join ' ') | Should -BeLike '*send-keys t-9001 enter*'
    }

    It 'proceeds with a prompt on an empty box' {
        Set-HerdrScreen $script:EmptyBoxScreen
        $null = Send-HerdrPrompt -Name 'T-9001' -Text 'do the thing'
        ($script:reached -join ' ') | Should -BeLike '*do the thing*'
    }

    It 'proceeds with a bare enter on an empty box' {
        Set-HerdrScreen $script:EmptyBoxScreen
        Send-HerdrKeys -Name 'T-9001' -Keys @('enter') -DelayMs 0
        ($script:reached -join ' ') | Should -BeLike '*send-keys t-9001 enter*'
    }

    # THE OTHER FALSE POSITIVE THAT WOULD STRAND A WORKER. An empty box is not blank on screen: the
    # harness draws its own dim placeholder into it, in the same position box content occupies. The
    # queued-messages hint is the one that bites - it appears the moment a corrective steer is
    # queued at a worker that is still working, which is precisely when `rally` sends the next one,
    # so a wedged worker would become unsteerable on a hint the harness printed itself.
    It 'sends a prompt through the placeholder <case>' -ForEach @(
        @{ case = 'on queued messages'; box = { $script:QueuedHintBox } }
        @{ case = 'for a teammate';     box = { $script:TeammateBox } }
        @{ case = 'on a fresh session'; box = { $script:TryBox } }
    ) {
        Set-HerdrScreen (New-BoxScreen -Box (& $box))
        $null = Send-HerdrPrompt -Name 'T-9001' -Text 'do the thing'
        ($script:reached -join ' ') |
            Should -BeLike '*do the thing*' -Because 'the harness''s own hint is not text the Hand has to explain'
    }

    It 'sends a bare enter through the placeholder <case>' -ForEach @(
        @{ case = 'on queued messages'; box = { $script:QueuedHintBox } }
        @{ case = 'for a teammate';     box = { $script:TeammateBox } }
        @{ case = 'on a fresh session'; box = { $script:TryBox } }
    ) {
        Set-HerdrScreen (New-BoxScreen -Box (& $box))
        Send-HerdrKeys -Name 'T-9001' -Keys @('enter') -DelayMs 0
        ($script:reached -join ' ') | Should -BeLike '*send-keys t-9001 enter*'
    }

    # And the exclusion has to stay narrow, because a generated suggestion sits in an empty box too -
    # its value is empty and an Enter still submits it as though the Hand had written it. Only the
    # three named placeholders are excluded; anything that merely opens like one is still refused.
    It 'still refuses <case>' -ForEach @(
        @{ case = 'a real generated suggestion'
           box  = 'show me the getting started section rendered' }
        @{ case = 'a line that only opens like the queued hint'
           box  = 'Press up to edit queued messages, then land it' }
        @{ case = 'a line that only opens like the teammate placeholder'
           box  = 'Message @reviewer about the failing test' }
        @{ case = 'a line that only opens like the try example'
           box  = 'Try "how do I log an error?" and report back' }
    ) {
        Set-HerdrScreen (New-BoxScreen -Box $box)
        { Send-HerdrPrompt -Name 'T-9001' -Text 'do the thing' } | Should -Throw
        $script:reached.Count |
            Should -Be 0 -Because 'an unlisted string falls back to refusing, which is the safe direction'
    }

    # A worker's own output lines open with a plain `>`. Treating one of those as a prompt box
    # would refuse every send to a perfectly healthy worker, which is the failure that would get
    # the whole guard ripped back out.
    It 'does not mistake the worker''s own output for a prompt box' {
        Set-HerdrScreen $script:FinishedScreen
        $null = Send-HerdrPrompt -Name 'T-9001' -Text 'do the thing'
        ($script:reached -join ' ') | Should -BeLike '*do the thing*'
    }

    # FAIL OPEN, and deliberately the opposite of the stall signal. There the cost of guessing is a
    # false stall report; here it is a corrective steer or a teardown that cannot be delivered to a
    # worker that may be wedged. A narrow pane must not make a worker unsteerable.
    It 'proceeds with a prompt when the screen could not be read at all' {
        Set-HerdrScreenFailure
        $null = Send-HerdrPrompt -Name 'T-9001' -Text 'do the thing'
        ($script:reached -join ' ') |
            Should -BeLike '*do the thing*' -Because 'an unreadable pane must not make a worker unsteerable'
    }

    It 'proceeds with a bare enter when the screen could not be read at all' {
        Set-HerdrScreenFailure
        Send-HerdrKeys -Name 'T-9001' -Keys @('enter') -DelayMs 0
        ($script:reached -join ' ') | Should -BeLike '*send-keys t-9001 enter*'
    }

    # Only the FIRST key is checked. A later Enter is answering the menu the earlier keys have moved
    # through, so `rally` step 3's read-then-arrow-then-Enter sequence still works.
    It 'still answers a menu, where the Enter follows an arrow' {
        Set-HerdrScreen $script:SuggestionScreen
        Send-HerdrKeys -Name 'T-9001' -Keys @('down', 'enter') -DelayMs 0
        ($script:reached -join ' ') | Should -BeLike '*send-keys t-9001 enter*'
    }

    # THE FALSE POSITIVE THAT WOULD STRAND A WORKER. `❯` is the harness's generic pointer, not a box
    # glyph: the highlighted row of a numbered menu carries it too. `rally` step 3 reads the screen
    # back between the arrow and the Enter, so that Enter arrives as the first key of its own call -
    # and if the menu row read as box content the guard would refuse the one route to a headless
    # worker, on exactly the worker that is already blocked. The plain space after the caret is what
    # keeps it apart from the box's no-break one.
    It 'answers a worker blocked on a menu, where the Enter opens the call' {
        Set-HerdrScreen $script:MenuScreen
        Send-HerdrKeys -Name 'T-9001' -Keys @('enter') -DelayMs 0
        ($script:reached -join ' ') |
            Should -BeLike '*send-keys t-9001 enter*' -Because 'a menu cursor is not text the Hand has to explain'
    }

    It 'sends a prompt to a worker blocked on a menu' {
        Set-HerdrScreen $script:MenuScreen
        $null = Send-HerdrPrompt -Name 'T-9001' -Text 'do the thing'
        ($script:reached -join ' ') | Should -BeLike '*do the thing*'
    }

}

# ---------------------------------------------------------------------------------------------
# Stopping a worker. `/exit` is TYPED into the box behind whatever already sits there, and its Enter
# submits the two together as one prompt - so a worker with text in its box would act on that text
# instead of exiting. A non-empty box is refused by name, with nothing sent and nothing cleared.
# ---------------------------------------------------------------------------------------------
Describe 'Stop-HerdrAgent never submits text already in the box' {
    BeforeAll { $script:StopDir = Initialize-HerdrScreenStub }

    BeforeEach {
        Mock -ModuleName Herdr Get-HerdrCommandPath { $env:KINGSHAND_TEST_HERDR_EXE }
        $script:reached = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName Herdr Invoke-Herdr {
            $script:reached.Add(($Arguments -join ' '))
            New-HerdrAgentResult
        }
        # Live on the first read, gone on the next: a worker that took its `/exit`.
        $script:gets = 0
        Mock -ModuleName Herdr Get-HerdrAgent {
            $script:gets++
            if ($script:gets -eq 1) { return [pscustomobject]@{ name = 't-9001'; pane_id = 'p1' } }
            $null
        }
    }

    It 'stops a worker whose box is empty exactly as before' {
        Set-HerdrScreen $script:EmptyBoxScreen

        $stop = Stop-HerdrAgent -Name 'T-9001' -TimeoutSeconds 5
        $stop.stopped      | Should -BeTrue
        $stop.paneReusable | Should -BeTrue
        $stop.paneId       | Should -Be 'p1'
        $stop.refused      | Should -Be ''
        ($script:reached -join ' ') | Should -BeLike '*agent prompt t-9001 /exit*'
    }

    It 'submits nothing when the box holds <case>' -ForEach @(
        @{ case = 'typed text';       box = 'also delete the old branch' }
        @{ case = 'a collapsed paste'; box = '[Pasted text #1 +12 lines]' }
        @{ case = 'a suggestion';     box = 'show me the getting started section rendered' }
    ) {
        Set-HerdrScreen (New-BoxScreen -Box $box)

        $stop = Stop-HerdrAgent -Name 'T-9001' -TimeoutSeconds 5
        $stop.stopped      | Should -BeFalse
        $stop.paneReusable | Should -BeFalse
        $stop.paneId       | Should -Be 'p1'
        $stop.refused      | Should -Be 'prompt-box-not-empty'
        $stop.promptBox    | Should -Be $box
        $script:reached.Count |
            Should -Be 0 -Because '/exit behind that text would submit both as one prompt'
    }

    It 'still dismisses a menu with Escape, then refuses on the box under it' {
        $script:reads = 0
        Mock -ModuleName Herdr Read-HerdrAgentScreen {
            $script:reads++
            $t = if ($script:reads -eq 1) { $script:MenuScreen } else { New-BoxScreen -Box 'half a steer' }
            [pscustomobject]@{ ok = $true; text = $t }
        }

        $stop = Stop-HerdrAgent -Name 'T-9001' -TimeoutSeconds 5
        $stop.refused | Should -Be 'prompt-box-not-empty'
        @($script:reached) | Should -Be @('agent send-keys t-9001 escape') -Because 'Escape cancels a menu and submits nothing'
    }

    # The send paths' own fail-open rule, kept: a pane too narrow to render must not make a worker
    # unstoppable. The box could not be read, so nothing claims it holds anything.
    It 'still stops a worker whose screen could not be read' {
        Set-HerdrScreenFailure

        $stop = Stop-HerdrAgent -Name 'T-9001' -TimeoutSeconds 5
        $stop.stopped | Should -BeTrue
        $stop.refused | Should -Be ''
        ($script:reached -join ' ') | Should -BeLike '*/exit*'
    }
}

# ---------------------------------------------------------------------------------------------
# Confirming a start prompt was taken. `agent prompt` returns once its text and Enter are written,
# and a paste can be left sitting in the box unsent. Every case drives the public function against a
# mocked screen and a mocked herdr record, and counts what reached herdr: the resend is one bare
# Enter at most, never the text again, so nothing here can submit the prompt twice.
# ---------------------------------------------------------------------------------------------
Describe 'Confirm-HerdrPromptTaken confirms a prompt was taken, and never submits it twice' {
    BeforeAll {
        $script:PasteBox = '[Pasted text #1 +3 lines]'

        # Poll by poll: each entry is the box and herdr's state at that poll, the last repeating.
        # $script:entered flips once an Enter reaches herdr, and a script after it takes over.
        function Set-PromptPolls {
            param([object[]]$Before, [object[]]$AfterEnter = @())
            $script:polls      = $Before
            $script:afterEnter = $AfterEnter
            $script:poll       = 0
            $script:entered    = $false
        }
        function Get-CurrentPoll {
            # Assigned by name rather than through an if expression, which unrolls a one-entry list
            # into the hashtable itself.
            $list = $script:polls
            if ($script:entered -and $script:afterEnter.Count) { $list = $script:afterEnter }
            $list[[Math]::Min($script:poll, $list.Count - 1)]
        }
    }

    BeforeEach {
        $script:reached = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName Herdr Invoke-Herdr {
            $script:reached.Add(($Arguments -join ' '))
            if ($Arguments[1] -eq 'send-keys' -and $Arguments[3] -eq 'enter') {
                $script:entered = $true
                $script:poll = 0
            }
            $null
        }
        Mock -ModuleName Herdr Get-HerdrAgent {
            $p = Get-CurrentPoll
            if ($p.state -eq 'gone') { return $null }
            [pscustomobject]@{ name = 't-9001'; pane_id = 'p1'; agent_status = $p.state }
        }
        Mock -ModuleName Herdr Read-HerdrAgentScreen {
            $p = Get-CurrentPoll
            $script:poll++
            if ($p.screen -eq 'unreadable') { return [pscustomobject]@{ ok = $false; text = '' } }
            $t = if ($p.screen -eq 'menu') { $script:MenuScreen } else { New-BoxScreen -Box $p.box }
            [pscustomobject]@{ ok = $true; text = $t }
        }
    }

    It 'confirms a prompt taken at once, on its default wait' {
        Set-PromptPolls -Before @(@{ box = ''; state = 'working' })

        $r = Confirm-HerdrPromptTaken -Name 'T-9001'
        $r.taken   | Should -BeTrue
        $r.outcome | Should -Be 'taken'
        $r.resent  | Should -BeFalse
        $script:reached.Count | Should -Be 0
    }

    It 'waits through a paste that is still going in, without resending' {
        Set-PromptPolls -Before @(
            @{ box = $script:PasteBox; state = 'idle' }
            @{ box = '';               state = 'idle' }
            @{ box = '';               state = 'working' })

        $r = Confirm-HerdrPromptTaken -Name 'T-9001' -TimeoutMs 3000 -PollMs 10
        $r.outcome | Should -Be 'taken'
        $r.resent  | Should -BeFalse
        $script:reached.Count | Should -Be 0
    }

    It 'sends one bare Enter for a prompt left in the box, and confirms it then' {
        Set-PromptPolls -Before @(@{ box = $script:PasteBox; state = 'idle' }) `
                        -AfterEnter @(@{ box = ''; state = 'working' })

        $r = Confirm-HerdrPromptTaken -Name 'T-9001' -TimeoutMs 600 -PollMs 10
        $r.outcome | Should -Be 'taken'
        $r.resent  | Should -BeTrue
        @($script:reached) | Should -Be @('agent send-keys t-9001 enter')
    }

    # THE DOUBLE-SUBMIT GUARD. The text is never sent again and the Enter is never repeated, however
    # long the box keeps the text: a second copy of the prompt would be a second prompt.
    It 'names a prompt still unsent after its one Enter, and sends nothing more' {
        Set-PromptPolls -Before @(@{ box = $script:PasteBox; state = 'idle' })

        $r = Confirm-HerdrPromptTaken -Name 'T-9001' -TimeoutMs 600 -PollMs 10
        $r.taken     | Should -BeFalse
        $r.outcome   | Should -Be 'unsent'
        $r.resent    | Should -BeTrue
        $r.promptBox | Should -Be $script:PasteBox
        @($script:reached) | Should -Be @('agent send-keys t-9001 enter')
        @($script:reached | Where-Object { $_ -like 'agent prompt*' }).Count | Should -Be 0
    }

    It 'resends nothing when the box is empty and the worker never starts' {
        Set-PromptPolls -Before @(@{ box = ''; state = 'idle' })

        $r = Confirm-HerdrPromptTaken -Name 'T-9001' -TimeoutMs 300 -PollMs 10
        $r.outcome | Should -Be 'not-started'
        $script:reached.Count |
            Should -Be 0 -Because 'an empty box may mean the prompt was already submitted'
    }

    It 'never presses Enter at a worker that is working with text in its box' {
        Set-PromptPolls -Before @(@{ box = 'queued behind the turn'; state = 'working' })

        $r = Confirm-HerdrPromptTaken -Name 'T-9001' -TimeoutMs 300 -PollMs 10
        $r.outcome | Should -Be 'unsent'
        $r.resent  | Should -BeFalse
        $script:reached.Count | Should -Be 0
    }

    It 'names a worker blocked on a prompt, and answers nothing' {
        Set-PromptPolls -Before @(@{ screen = 'menu'; state = 'idle' })

        $r = Confirm-HerdrPromptTaken -Name 'T-9001' -TimeoutMs 300 -PollMs 10
        $r.outcome | Should -Be 'blocked'
        $script:reached.Count | Should -Be 0
    }

    It 'says unreadable, rather than taken or unsent, when the screen cannot be read' {
        Set-PromptPolls -Before @(@{ screen = 'unreadable'; state = 'working' })

        $r = Confirm-HerdrPromptTaken -Name 'T-9001' -TimeoutMs 300 -PollMs 10
        $r.outcome   | Should -Be 'unreadable'
        $r.taken     | Should -BeFalse
        $r.promptBox | Should -Be ''
        $script:reached.Count | Should -Be 0
    }

    It 'says gone when herdr no longer knows the worker' {
        Set-PromptPolls -Before @(@{ box = ''; state = 'gone' })

        $r = Confirm-HerdrPromptTaken -Name 'T-9001' -TimeoutMs 300 -PollMs 10
        $r.outcome | Should -Be 'gone'
        $script:reached.Count | Should -Be 0
    }
}

Describe 'Start-HerdrAgent trusts a re-read over the exit status' {
    # `agent start` can exit non-zero and still have registered the agent. A fresh directory stops
    # at Claude Code's folder-trust dialog, herdr correctly reports agent_not_ready, and the agent
    # exists and is blocked the whole time. The fix is to answer or pre-empt the dialog, not to
    # retry the start, so the caller gets that live agent back rather than an exception.

    It 'returns the live agent when agent start failed but the agent is really there' {
        Mock -ModuleName Herdr Invoke-Herdr { New-HerdrError -Code 'agent_not_ready' -Message 'agent did not become ready' }
        Mock -ModuleName Herdr Get-HerdrAgent {
            [pscustomobject]@{ name = 't-9001'; state = 'blocked'; pane_id = 'pane-1' }
        }

        $agent = $null
        { $script:agent = Start-HerdrAgent -Name 'T-9001' -PaneId 'pane-1' } |
            Should -Not -Throw -Because 'the folder-trust case is a blocked agent, not a failed start'
        $script:agent.name  | Should -Be 't-9001'
        $script:agent.state | Should -Be 'blocked'
    }

    It 're-reads rather than trusting the non-zero exit' {
        Mock -ModuleName Herdr Invoke-Herdr { New-HerdrError -Code 'agent_not_ready' }
        Mock -ModuleName Herdr Get-HerdrAgent { [pscustomobject]@{ name = 't-9001'; state = 'blocked' } }
        $null = Start-HerdrAgent -Name 'T-9001' -PaneId 'pane-1'
        Should -Invoke Get-HerdrAgent -ModuleName Herdr -Times 1 -Exactly
    }

    It 'throws when the agent genuinely does not exist' {
        Mock -ModuleName Herdr Invoke-Herdr { New-HerdrError -Code 'pane_not_found' -Message 'no such pane' }
        Mock -ModuleName Herdr Get-HerdrAgent { $null }
        { Start-HerdrAgent -Name 'T-9001' -PaneId 'pane-nope' } | Should -Throw '*pane_not_found*'
    }

    It 'names herdr''s own error code in the refusal, so the reader can act on it' {
        Mock -ModuleName Herdr Invoke-Herdr { New-HerdrError -Code 'invalid_agent_name' -Message 'bad name' }
        Mock -ModuleName Herdr Get-HerdrAgent { $null }
        $err = $null
        try { Start-HerdrAgent -Name 'T-9001' -PaneId 'pane-1' } catch { $err = $_.Exception.Message }
        $err | Should -Not -BeNullOrEmpty
        $err | Should -BeLike '*invalid_agent_name*'
        $err | Should -BeLike '*bad name*'
    }

    It 'returns the agent and never re-reads when the start succeeded' {
        Mock -ModuleName Herdr Invoke-Herdr { New-HerdrAgentResult -Name 't-9001' -State 'idle' }
        Mock -ModuleName Herdr Get-HerdrAgent { throw 'a successful start must not be re-read' }
        $agent = Start-HerdrAgent -Name 'T-9001' -PaneId 'pane-1'
        $agent.state | Should -Be 'idle'
        Should -Invoke Get-HerdrAgent -ModuleName Herdr -Times 0 -Exactly
    }

    # No agent arguments can ever be passed. With `-- <args>` herdr composes
    # `Start-Process -FilePath claude -ArgumentList '...' -NoNewWindow -Wait` inside the pane, and
    # `claude` resolves to a .ps1, so it dies with "%1 is not a valid Win32 application".
    # --permission-mode and --add-dir live in the worktree's settings.local.json instead.
    It 'passes no arguments through to claude' {
        Mock -ModuleName Herdr Invoke-Herdr { New-HerdrAgentResult }
        $null = Start-HerdrAgent -Name 'T-9001' -PaneId 'pane-1'
        Should -Invoke Invoke-Herdr -ModuleName Herdr -Times 0 -Exactly -ParameterFilter {
            $Arguments -contains '--'
        } -Because 'herdr launching claude with arguments dies with "%1 is not a valid Win32 application"'
        Should -Invoke Invoke-Herdr -ModuleName Herdr -Times 0 -Exactly -ParameterFilter {
            $Arguments -contains '--permission-mode' -or $Arguments -contains '--add-dir'
        } -Because 'both grants moved into the worktree settings, and cannot come back here'
    }
}

Describe 'Test-HerdrAgentAwaitingInput reads the live viewport and nothing else' {
    # herdr 0.8.2 with manifest 2026.08.21.1 was measured calling a worker sitting on an unanswered
    # AskUserQuestion menu `idle`, and calling that same still-blocked worker `done` minutes later
    # while a genuinely finished worker read `idle`. The screen is the authority instead.
    #
    # WHICH screen is the whole thing. `recent` and `recent-unwrapped` include scrollback, so a
    # worker that answered a menu an hour ago still carries that text in its history and would read
    # as blocked forever - a wrong answer that never expires. The source argument is therefore
    # asserted on directly, because a change to it would reintroduce that silently.

    BeforeAll { $script:AwaitDir = Initialize-HerdrScreenStub }
    BeforeEach { Mock -ModuleName Herdr Get-HerdrCommandPath { $env:KINGSHAND_TEST_HERDR_EXE } }

    It 'asks herdr for --source visible' {
        Set-HerdrScreen $script:BlockedScreen
        $null = Test-HerdrAgentAwaitingInput -Name 'T-9001'

        $calls = @(Get-HerdrStubArgs)
        $calls.Count | Should -Be 1 -Because 'one screen read per check, and the stub must really have run'
        $calls[0] | Should -BeLike '*agent read t-9001*'
        $calls[0] | Should -BeLike '*--source visible*'
    }

    It 'never asks for recent or recent-unwrapped, which carry scrollback' {
        Set-HerdrScreen $script:BlockedScreen
        $null = Test-HerdrAgentAwaitingInput -Name 'T-9001'

        foreach ($call in @(Get-HerdrStubArgs)) {
            $call.Contains('recent') |
                Should -BeFalse -Because 'scrollback holds a menu the worker already answered, so it reads as blocked forever'
        }
    }

    It 'is true for a screen showing a selection menu' {
        Set-HerdrScreen $script:BlockedScreen
        Test-HerdrAgentAwaitingInput -Name 'T-9001' | Should -BeTrue
    }

    It 'is false for a finished screen' {
        Set-HerdrScreen $script:FinishedScreen
        Test-HerdrAgentAwaitingInput -Name 'T-9001' |
            Should -BeFalse -Because 'a worker that has said its piece is not waiting on anyone'
    }

    It 'is true for a screen carrying <phrase>' -ForEach @(
        @{ phrase = 'Enter to select' }
        @{ phrase = 'Chat about this' }
        @{ phrase = 'Type something' }
        @{ phrase = 'Do you want to' }
        @{ phrase = 'to navigate' }
    ) {
        Set-HerdrScreen "  $phrase  "
        Test-HerdrAgentAwaitingInput -Name 'T-9001' | Should -BeTrue
    }

    It 'is false when the screen comes back with nothing on it' {
        Set-HerdrScreen ''
        Test-HerdrAgentAwaitingInput -Name 'T-9001' |
            Should -BeFalse -Because 'a screen that could not be read is not evidence of a prompt'
    }

    # Text from a read that failed is not the worker's screen, whatever it happens to contain, and
    # this guard classifies on phrases - so it must not classify on text it never successfully read.
    # Every viewport reader here shares that one rule rather than each remembering it.
    It 'classifies nothing from a read that failed, whatever the error text says' {
        Set-HerdrScreenFailure -Text '{"error":{"code":"pane_not_found","message":"nothing to navigate to"}}'
        Test-HerdrAgentAwaitingInput -Name 'T-9001' |
            Should -BeFalse -Because 'herdr''s own error is not the worker''s screen'
    }
}

Describe 'Get-HerdrAgentState corrects herdr with the worker''s own screen' {
    # Both directions were observed on this machine and both are dangerous, so both are pinned. A
    # blocked worker reading `idle` gets treated as finished; the same worker reading `done` gets
    # treated as finished with more confidence.

    BeforeAll { $script:StateDir = Initialize-HerdrScreenStub }
    BeforeEach { Mock -ModuleName Herdr Get-HerdrCommandPath { $env:KINGSHAND_TEST_HERDR_EXE } }

    It 'returns blocked when the screen shows a prompt and herdr says <herdrState>' -ForEach @(
        @{ herdrState = 'idle' }
        @{ herdrState = 'done' }
    ) {
        Mock -ModuleName Herdr Get-HerdrAgent {
            [pscustomobject]@{ name = 't-9001'; agent_status = $herdrState; pane_id = 'pane-1' }
        }
        Set-HerdrScreen $script:BlockedScreen

        Get-HerdrAgentState -Name 'T-9001' |
            Should -Be 'blocked' -Because "herdr called a worker on an open menu $herdrState"
    }

    It 'passes herdr''s own word through when the screen shows no prompt, for <herdrState>' -ForEach @(
        @{ herdrState = 'idle' }
        @{ herdrState = 'working' }
        @{ herdrState = 'done' }
    ) {
        Mock -ModuleName Herdr Get-HerdrAgent {
            [pscustomobject]@{ name = 't-9001'; agent_status = $herdrState; pane_id = 'pane-1' }
        }
        Set-HerdrScreen $script:FinishedScreen

        Get-HerdrAgentState -Name 'T-9001' | Should -Be $herdrState
    }

    It 'returns nothing, and reads no screen, for a worker herdr has never heard of' {
        Mock -ModuleName Herdr Get-HerdrAgent { $null }
        Set-HerdrScreen $script:BlockedScreen

        Get-HerdrAgentState -Name 'T-9001' | Should -BeNullOrEmpty
        @(Get-HerdrStubArgs).Count |
            Should -Be 0 -Because 'a worker that does not exist has no screen, and the read costs a subprocess'
    }
}

Describe 'Wait-HerdrAgentSettled reports not settled rather than inventing an outcome' {
    BeforeAll { $script:SettledDir = Initialize-HerdrScreenStub }
    BeforeEach { Mock -ModuleName Herdr Get-HerdrCommandPath { $env:KINGSHAND_TEST_HERDR_EXE } }

    # A timeout and a herdr error both arrive as $null from the wait, and neither says anything
    # about the worker - it may be alive and mid-turn. Turning that into a state is how a running
    # worker gets reported as finished, so the absence of an outcome is reported as an absence.
    It 'reports settled false with no state when the wait comes back empty' {
        Mock -ModuleName Herdr Wait-HerdrAgent { $null }
        Set-HerdrScreen $script:BlockedScreen

        $r = Wait-HerdrAgentSettled -Name 'T-9001' -TimeoutMs 10
        $r.settled       | Should -BeFalse
        $r.state         | Should -BeNullOrEmpty -Because 'not settled is not a state'
        $r.awaitingInput | Should -BeFalse
        @(Get-HerdrStubArgs).Count |
            Should -Be 0 -Because 'nothing settled, so there is no outcome to check a screen against'
    }

    It 'reports blocked for a settled worker still on a prompt, though herdr said <herdrState>' -ForEach @(
        @{ herdrState = 'idle' }
        @{ herdrState = 'done' }
    ) {
        Mock -ModuleName Herdr Wait-HerdrAgent {
            [pscustomobject]@{ name = 't-9001'; agent_status = $herdrState; pane_id = 'pane-1' }
        }
        Set-HerdrScreen $script:BlockedScreen

        $r = Wait-HerdrAgentSettled -Name 'T-9001' -TimeoutMs 10
        $r.settled       | Should -BeTrue
        $r.awaitingInput | Should -BeTrue
        $r.state         | Should -Be 'blocked'
    }

    It 'reports the herdr state for a settled worker whose screen is clean' {
        Mock -ModuleName Herdr Wait-HerdrAgent {
            [pscustomobject]@{ name = 't-9001'; agent_status = 'idle'; pane_id = 'pane-1' }
        }
        Set-HerdrScreen $script:FinishedScreen

        $r = Wait-HerdrAgentSettled -Name 'T-9001' -TimeoutMs 10
        $r.settled       | Should -BeTrue
        $r.awaitingInput | Should -BeFalse
        $r.state         | Should -Be 'idle'
    }
}


# ---------------------------------------------------------------------------------------------
# Progress, which is a different question from liveness.
#
# Both failure directions were observed here on 2026-08-31 and 2026-09-01. A worker that handed its
# work to a background pipeline and returned to its prompt read `done` within seconds, so the wait
# fired and reported a completion that had not happened. The same night, a worker whose work was
# genuinely finished read `working` because stray text was sitting in its input box. Neither state
# word says anything about whether the work is advancing, which is what the Hand actually waits on.
#
# The whole watcher rests on one property: a screen that is only repainting its own timer must
# fingerprint the same twice. Without that, a worker frozen for an hour looks like steady progress
# and nothing here would ever fire. That is the first case below, and it is the one to keep.
# ---------------------------------------------------------------------------------------------
Describe 'Get-HerdrAgentProgressSignal ignores what Claude Code repaints on its own' {
    BeforeAll {
        $script:ProgressDir = Initialize-HerdrScreenStub

        # The same worker, mid-tool-call, eleven minutes apart. Every difference between these two
        # screens is Claude Code redrawing its own status line: the spinner glyph, the elapsed
        # timer, the token counter. Nothing about the work has moved.
        $script:BusyEarly = @'
> Waiting for checks to report
  Bash(no-mistakes axi status)
  * Herding... (esc to interrupt * 1m 23s * 1.2k tokens)
'@
        $script:BusyLater = @'
> Waiting for checks to report
  Bash(no-mistakes axi status)
  * Herding... (esc to interrupt * 12m 4s * 3.1k tokens)
'@
        # A different tool call. This is work advancing, and it must read as a change.
        $script:BusyMoved = @'
> Opening the pull request
  Bash(gh pr create)
  * Herding... (esc to interrupt * 1m 23s * 1.2k tokens)
'@
    }

    BeforeEach { Mock -ModuleName Herdr Get-HerdrCommandPath { $env:KINGSHAND_TEST_HERDR_EXE } }

    It 'asks herdr for --source visible, never the scrollback' {
        Set-HerdrScreen $script:BusyEarly
        $null = Get-HerdrAgentProgressSignal -Name 'T-9001'

        $calls = @(Get-HerdrStubArgs)
        $calls.Count | Should -Be 1 -Because 'one screen read per sample, and the stub must really have run'
        $calls[0] | Should -BeLike '*--source visible*'
        $calls[0].Contains('recent') |
            Should -BeFalse -Because 'scrollback never changes, so a signal taken over it looks static on a healthy worker'
    }

    # THE CASE THE WHOLE WATCHER RESTS ON. Delete the normalisation and this fails, and with it the
    # detector silently reports every frozen worker as making progress.
    It 'gives the same signal for a screen that only repainted its timer and token count' {
        Set-HerdrScreen $script:BusyEarly
        $early = Get-HerdrAgentProgressSignal -Name 'T-9001'
        Set-HerdrScreen $script:BusyLater
        $later = Get-HerdrAgentProgressSignal -Name 'T-9001'

        $early.readable | Should -BeTrue
        $later.signal   | Should -Be $early.signal -Because 'an elapsed timer moving is not the work moving'
    }

    It 'gives a different signal when the worker is actually doing something else' {
        Set-HerdrScreen $script:BusyEarly
        $before = Get-HerdrAgentProgressSignal -Name 'T-9001'
        Set-HerdrScreen $script:BusyMoved
        $after  = Get-HerdrAgentProgressSignal -Name 'T-9001'

        $after.signal | Should -Not -Be $before.signal
    }

    # The guard against over-normalising. Stripping digits wholesale would be the easy way to kill
    # the timer, and it would also kill every counter a worker prints - so a job that is genuinely
    # grinding through files would be reported stalled. A false alarm reaching the King is worse
    # than a silent one, so the bias is deliberately toward missing a stall.
    It 'treats a counter moving as progress, because only timers and token counts are volatile' {
        Set-HerdrScreen "  Formatting 142/300 files"
        $before = Get-HerdrAgentProgressSignal -Name 'T-9001'
        Set-HerdrScreen "  Formatting 143/300 files"
        $after  = Get-HerdrAgentProgressSignal -Name 'T-9001'

        $after.signal | Should -Not -Be $before.signal
    }

    It 'ignores trailing whitespace and blank lines, which a terminal repaints freely' {
        Set-HerdrScreen "> Reading the brief`n`n  Bash(git status)   "
        $a = Get-HerdrAgentProgressSignal -Name 'T-9001'
        Set-HerdrScreen "> Reading the brief`n  Bash(git status)"
        $b = Get-HerdrAgentProgressSignal -Name 'T-9001'

        $b.signal | Should -Be $a.signal
    }

    # Fail closed. A screen that could not be read is not evidence of anything, and a caller that
    # reads it as "unchanged" reports a healthy worker as stalled. This is the same width defect
    # that blinded the blocked-worker guard, arriving at a different function.
    It 'reports a screen it could not read as unreadable rather than as unchanged' {
        Set-HerdrScreen ''
        $r = Get-HerdrAgentProgressSignal -Name 'T-9001'
        $r.readable | Should -BeFalse
        $r.signal   | Should -BeNullOrEmpty -Because 'no screen is not a fingerprint of an idle screen'
    }

    It 'carries the last few lines, so an escalation can say what the worker was last seen doing' {
        Set-HerdrScreen $script:BusyEarly
        (Get-HerdrAgentProgressSignal -Name 'T-9001').lastActivity |
            Should -BeLike '*no-mistakes axi status*' -Because 'evidence a person can act on is the deliverable'
    }

    # The read folds stderr into stdout, so herdr's own failure arrives looking like a screen: not
    # empty, not narrow, and identical on every sample. Fingerprinted as one it produces a stall
    # twenty minutes later whose evidence is an error message dressed up as what the worker was last
    # seen doing.
    It 'reports a read herdr failed as unreadable, not as a screen that never changed' {
        Set-HerdrScreenFailure
        $r = Get-HerdrAgentProgressSignal -Name 'T-9001'

        $r.readable     | Should -BeFalse -Because 'a read that failed is not a screen'
        $r.signal       | Should -BeNullOrEmpty
        $r.lastActivity | Should -BeNullOrEmpty -Because 'an error payload is not what the worker was last doing'
    }

    It 'reports an error envelope as unreadable even when the command exited zero' {
        Set-HerdrScreen '{"error":{"code":"agent_not_found","message":"no agent named t-9001 in this workspace"}}'
        (Get-HerdrAgentProgressSignal -Name 'T-9001').readable |
            Should -BeFalse -Because 'herdr answers its failures as JSON, whatever it exits with'
    }

    # All three sightings of an unexplained prompt box were found by chance, on a worker nobody was
    # inspecting. This is the sample that already reads the viewport every minute on every watched
    # worker, so reporting the box costs one regex over text already in memory. Delete the field and
    # every reader of it throws under Set-StrictMode -Version Latest rather than quietly seeing
    # $null, which is why these cannot pass vacuously.
    It 'reports what is sitting in the prompt box' {
        Set-HerdrScreen $script:SuggestionScreen
        (Get-HerdrAgentProgressSignal -Name 'T-9001').promptBox |
            Should -Be 'show me the getting started section rendered'
    }

    It 'reports an empty box as empty' {
        Set-HerdrScreen $script:EmptyBoxScreen
        (Get-HerdrAgentProgressSignal -Name 'T-9001').promptBox |
            Should -Be '' -Because 'an empty box is the ordinary state and must not read as content'
    }

    # A blocked worker's menu row is not box content, and reporting one as such would put a wrong
    # value on every settled, stalled, gone and timeout report the Hand reads - with no error to say
    # so, and the Hand then escalating a menu option as text nobody can account for.
    It 'reports no box for a worker sitting on a menu' {
        Set-HerdrScreen $script:MenuScreen
        (Get-HerdrAgentProgressSignal -Name 'T-9001').promptBox |
            Should -Be '' -Because 'the caret on a menu row is a selection cursor, not a prompt box'
    }

    # Same again for the harness's own placeholder, which is drawn into an empty box in the same
    # position box content occupies. Reporting one as content puts a wrong value on every report the
    # Hand reads, with no error to say so, and sends it escalating a hint the harness printed itself.
    It 'reports no box for the placeholder <case>' -ForEach @(
        @{ case = 'on queued messages'; box = { $script:QueuedHintBox } }
        @{ case = 'for a teammate';     box = { $script:TeammateBox } }
        @{ case = 'on a fresh session'; box = { $script:TryBox } }
    ) {
        Set-HerdrScreen (New-BoxScreen -Box (& $box))
        (Get-HerdrAgentProgressSignal -Name 'T-9001').promptBox |
            Should -Be '' -Because 'a placeholder means the box is empty, not that it holds text'
    }

    It 'reports no box at all when the screen could not be read' {
        Set-HerdrScreenFailure
        $r = Get-HerdrAgentProgressSignal -Name 'T-9001'
        $r.readable  | Should -BeFalse
        $r.promptBox | Should -Be '' -Because 'herdr''s own error text is not a worker''s prompt box'
    }

    # The box is not a state. A worker with text in its box has not asked anybody anything, and
    # folding this into the blocked guard would make every finished worker read `blocked`.
    It 'does not turn a box with text in it into an interactive prompt' {
        Set-HerdrScreen $script:SuggestionScreen
        Test-HerdrAgentAwaitingInput -Name 'T-9001' |
            Should -BeFalse -Because 'a rendered suggestion is not a question anyone is waiting on'
    }

    It 'reads the box off a screen only once, with no second herdr call' {
        Set-HerdrScreen $script:SuggestionScreen
        $null = Get-HerdrAgentProgressSignal -Name 'T-9001'
        @(Get-HerdrStubArgs).Count |
            Should -Be 1 -Because 'the box comes off text already in memory, not off a second read'
    }

    # A long paste is drawn collapsed in the box, with Claude Code's hint on the footer line under
    # it. Both shapes are copied off a live worker sampled while a long prompt went in: first the
    # collapsed paste sitting unsent, then - a fraction of a second later, with herdr still reading
    # the worker idle - an empty box with the hint still showing. The second is the screen a watch
    # woke on and called settled on 2026-10-23.
    It 'reports a collapsed paste as text in the box, and the hint under it' {
        Set-HerdrScreen (New-BoxScreen -Box '[Pasted text #1 +12 lines]' -Footer 'paste again to expand')
        $r = Get-HerdrAgentProgressSignal -Name 'T-9001'
        $r.promptBox    | Should -Be '[Pasted text #1 +12 lines]'
        $r.pastePending | Should -BeTrue
    }

    It 'reports the hint under an empty box, where the paste has gone in but the turn has not started' {
        Set-HerdrScreen (New-BoxScreen -Footer 'paste again to expand')
        $r = Get-HerdrAgentProgressSignal -Name 'T-9001'
        $r.promptBox    | Should -Be ''
        $r.pastePending | Should -BeTrue -Because 'the hint is the only sign a paste just went in'
    }

    It 'reports no paste for an ordinary empty box' {
        Set-HerdrScreen $script:EmptyBoxScreen
        (Get-HerdrAgentProgressSignal -Name 'T-9001').pastePending | Should -BeFalse
    }

    # The words in a worker's own output above the box are not the footer - this very change put
    # them on a worker's screen while it was being written.
    It 'does not take the hint''s words in the worker''s output above the box as the hint' {
        $screen = (New-BoxScreen) -replace 'Done\. Committed 3 files and wrote report\.md\.',
                                           'paste again to expand'
        Set-HerdrScreen $screen
        (Get-HerdrAgentProgressSignal -Name 'T-9001').pastePending | Should -BeFalse
    }

    It 'reports no paste when the screen could not be read' {
        Set-HerdrScreenFailure -Text 'paste again to expand'
        $r = Get-HerdrAgentProgressSignal -Name 'T-9001'
        $r.readable     | Should -BeFalse
        $r.pastePending | Should -BeFalse -Because 'a failed read is not a screen, so it shows no hint'
    }

    # The footer under the box while a worker that ended its turn still has background shells of its
    # own running, copied off a live worker: herdr read it `done`, and this was the only sign it
    # would carry on.
    It 'reads the count of the worker''s own background shells off the footer under the box' {
        Set-HerdrScreen (New-BoxScreen -Footer "`u{23F8} manual mode on `u{00B7} 2 shells `u{00B7} `u{2193} to manage")
        (Get-HerdrAgentProgressSignal -Name 'T-9001').backgroundShells | Should -Be 2
        Set-HerdrScreen (New-BoxScreen -Footer "`u{23F8} manual mode on `u{00B7} 1 shell `u{00B7} esc to interrupt")
        (Get-HerdrAgentProgressSignal -Name 'T-9001').backgroundShells | Should -Be 1
    }

    It 'reads no background shells off an ordinary footer' {
        Set-HerdrScreen $script:EmptyBoxScreen
        (Get-HerdrAgentProgressSignal -Name 'T-9001').backgroundShells | Should -Be 0
    }

    It 'does not take a shell count in the worker''s output above the box as the footer' {
        $screen = (New-BoxScreen) -replace 'Done\. Committed 3 files and wrote report\.md\.',
                                           "mode on `u{00B7} 3 shells"
        Set-HerdrScreen $screen
        (Get-HerdrAgentProgressSignal -Name 'T-9001').backgroundShells | Should -Be 0
    }

    It 'reports no count at all, not zero, when the screen could not be read' {
        Set-HerdrScreenFailure
        $r = Get-HerdrAgentProgressSignal -Name 'T-9001'
        ($null -eq $r.backgroundShells) |
            Should -BeTrue -Because 'an unread footer is not a footer saying none'
    }
}

Describe 'Test-HerdrAgentReadable never confirms a pane out of herdr''s own error text' {
    # This is the cross-check `rally` sends the Hand to when a stall is reported, so it is the one
    # answer that must not agree with a false stall.

    BeforeAll { $script:ReadableDir = Initialize-HerdrScreenStub }
    BeforeEach { Mock -ModuleName Herdr Get-HerdrCommandPath { $env:KINGSHAND_TEST_HERDR_EXE } }

    It 'is true for a pane wide enough to render the phrases the guard matches' {
        Set-HerdrScreen "  Which approach should I take, given the parser rewrite?`n  Enter to select, up/down to navigate"
        Test-HerdrAgentReadable -Name 'T-9001' | Should -BeTrue
    }

    It 'is false for a pane too narrow to render them' {
        Set-HerdrScreen "a`nb`nc"
        Test-HerdrAgentReadable -Name 'T-9001' | Should -BeFalse
    }

    It 'is false when the read itself failed, however wide the error text is' {
        Set-HerdrScreenFailure
        Test-HerdrAgentReadable -Name 'T-9001' |
            Should -BeFalse -Because 'wide error text is not evidence that the pane can be read'
    }
}

Describe 'Wait-HerdrAgentProgress notices a worker that stopped advancing, and never acts on it' {
    # `Wait-HerdrAgentSettled` asks whether a worker stopped. This asks whether it is getting
    # anywhere, and the two answers differ exactly when it matters: a worker parked on a wait that
    # can never end is alive, busy by every state word herdr has, and finished with nothing.

    BeforeEach {
        Mock -ModuleName Herdr Get-HerdrAgent { [pscustomobject]@{ name = 't-9001'; agent_status = 'working'; pane_id = 'p1' } }
        Mock -ModuleName Herdr Test-HerdrServer { $true }
        Mock -ModuleName Herdr Test-HerdrAgentAwaitingInput { $false }
        Mock -ModuleName Herdr Get-HerdrAgentProgressSignal {
            [pscustomobject]@{
                readable = $true; signal = 'aaaa'; promptBox = ''; pastePending = $false
                lastActivity = 'Bash(no-mistakes axi status) | waiting for checks'
            }
        }
        # The real wait blocks inside herdr for the whole slice. A mock that returns instantly would
        # be a different function, and would spin this loop instead of pacing it.
        Mock -ModuleName Herdr Wait-HerdrAgent { Start-Sleep -Milliseconds $TimeoutMs; $null }
    }

    It 'returns the settled result the moment the worker stops, exactly as the guarded wake does' {
        Mock -ModuleName Herdr Wait-HerdrAgent {
            [pscustomobject]@{ name = 't-9001'; agent_status = 'idle'; pane_id = 'p1' }
        }
        $r = Wait-HerdrAgentProgress -Name 'T-9001' -TimeoutMs 5000 -SampleSeconds 1

        $r.settled       | Should -BeTrue
        $r.state         | Should -Be 'idle'
        $r.stalled       | Should -BeFalse
        $r.reason        | Should -Be 'settled'
        $r.awaitingInput | Should -BeFalse
    }

    # A state word cannot tell a worker that finished from one that handed its work to a background
    # pipeline and went quiet - both read `done` - so the wake carries the screen the worker stopped
    # on and lets a person read it. Reporting the screen from before the wait would be worse than
    # reporting none: it is evidence about a moment nobody is asking about.
    It 'carries the final screen out with a settled wake, not the one from before the wait' {
        Mock -ModuleName Herdr Wait-HerdrAgent {
            [pscustomobject]@{ name = 't-9001'; agent_status = 'idle'; pane_id = 'p1' }
        }
        $script:sample = 0
        Mock -ModuleName Herdr Get-HerdrAgentProgressSignal {
            $script:sample++
            [pscustomobject]@{
                readable = $true; signal = "s$script:sample"; promptBox = ''; pastePending = $false
                lastActivity = "screen $script:sample"
            }
        }

        $r = Wait-HerdrAgentProgress -Name 'T-9001' -TimeoutMs 5000 -SampleSeconds 1
        $r.settled      | Should -BeTrue
        $r.lastActivity | Should -Be 'screen 2' -Because 'the wake reports what the worker was doing when it stopped'
    }

    # The wake the Hand already handles is where an unexplained box has to surface, because nothing
    # else looks. Carried on every report this makes - settled, stalled, gone and timeout - and
    # sampled at the same moment as lastActivity.
    It 'carries the prompt box out of the wait' {
        Mock -ModuleName Herdr Wait-HerdrAgent {
            [pscustomobject]@{ name = 't-9001'; agent_status = 'idle'; pane_id = 'p1' }
        }
        Mock -ModuleName Herdr Get-HerdrAgentProgressSignal {
            [pscustomobject]@{
                readable = $true; signal = 'aaaa'; lastActivity = 'Done'
                promptBox = 'show me the getting started section rendered'; pastePending = $false
            }
        }

        $r = Wait-HerdrAgentProgress -Name 'T-9001' -TimeoutMs 5000 -SampleSeconds 1
        @($r.PSObject.Properties.Name) | Should -Contain 'promptBox'
        $r.promptBox | Should -Be 'show me the getting started section rendered'
    }

    It 'carries a paste that only just went in out of a settled wake, read off the final screen' {
        Mock -ModuleName Herdr Wait-HerdrAgent {
            [pscustomobject]@{ name = 't-9001'; agent_status = 'done'; pane_id = 'p1' }
        }
        $script:sample = 0
        Mock -ModuleName Herdr Get-HerdrAgentProgressSignal {
            $script:sample++
            [pscustomobject]@{
                readable = $true; signal = "s$script:sample"; promptBox = ''; lastActivity = 'x'
                pastePending = ($script:sample -gt 1)
            }
        }

        $r = Wait-HerdrAgentProgress -Name 'T-9001' -TimeoutMs 5000 -SampleSeconds 1
        $r.reason       | Should -Be 'settled'
        $r.pastePending | Should -BeTrue -Because 'the wake reports the screen the worker stopped on'
    }

    It 'carries the prompt box out of a stall report too' {
        $r = Wait-HerdrAgentProgress -Name 'T-9001' -TimeoutMs 4000 -SampleSeconds 1 -StallMinutes 0
        $r.stalled | Should -BeTrue
        @($r.PSObject.Properties.Name) |
            Should -Contain 'promptBox' -Because 'a stalled worker is exactly the one worth reading the box on'
    }

    It 'says the watch was blind when the screen a settled worker stopped on could not be read' {
        Mock -ModuleName Herdr Wait-HerdrAgent {
            [pscustomobject]@{ name = 't-9001'; agent_status = 'done'; pane_id = 'p1' }
        }
        Mock -ModuleName Herdr Get-HerdrAgentProgressSignal {
            [pscustomobject]@{ readable = $false; signal = ''; lastActivity = ''; promptBox = ''; pastePending = $false }
        }

        $r = Wait-HerdrAgentProgress -Name 'T-9001' -TimeoutMs 5000 -SampleSeconds 1
        $r.settled        | Should -BeTrue
        $r.signalReadable | Should -BeFalse -Because 'a completion nobody could see is not a completion anybody checked'
        $r.lastActivity   | Should -BeNullOrEmpty
    }

    It 'still lets the screen outrank the state word for a settled worker on a prompt' {
        Mock -ModuleName Herdr Wait-HerdrAgent {
            [pscustomobject]@{ name = 't-9001'; agent_status = 'done'; pane_id = 'p1' }
        }
        Mock -ModuleName Herdr Test-HerdrAgentAwaitingInput { $true }

        $r = Wait-HerdrAgentProgress -Name 'T-9001' -TimeoutMs 5000 -SampleSeconds 1
        $r.state         | Should -Be 'blocked' -Because 'herdr called a worker on an open menu done'
        $r.awaitingInput | Should -BeTrue
    }

    It 'reports a stall with the evidence needed to act on it' {
        $r = Wait-HerdrAgentProgress -Name 'T-9001' -TimeoutMs 4000 -SampleSeconds 1 -StallMinutes 0

        $r.stalled      | Should -BeTrue
        $r.reason       | Should -Be 'stalled'
        $r.settled      | Should -BeFalse -Because 'a stalled worker has not finished anything'
        $r.lastActivity | Should -BeLike '*waiting for checks*' -Because 'which step and what it was last doing is the whole report'
        $r.stallMinutes | Should -Be 0 -Because 'the threshold it fired on has to be in the evidence'
        $r.quietMinutes | Should -Not -BeNullOrEmpty
    }

    It 'does not report a stall while the screen keeps changing' {
        $script:tick = 0
        Mock -ModuleName Herdr Get-HerdrAgentProgressSignal {
            $script:tick++
            [pscustomobject]@{ readable = $true; signal = "s$script:tick"; lastActivity = 'still going'; promptBox = ''; pastePending = $false }
        }

        $r = Wait-HerdrAgentProgress -Name 'T-9001' -TimeoutMs 2000 -SampleSeconds 1 -StallMinutes 0
        $r.stalled | Should -BeFalse -Because 'the threshold counts unchanged time, not elapsed time'
        $r.reason  | Should -Be 'timeout'
    }

    # Fail closed, again. An unreadable screen must never become a stall: the watcher says it could
    # not see, and the Hand is told that rather than told the worker is stuck.
    It 'never claims a stall from a screen it could not read' {
        Mock -ModuleName Herdr Get-HerdrAgentProgressSignal {
            [pscustomobject]@{ readable = $false; signal = ''; lastActivity = ''; promptBox = ''; pastePending = $false }
        }

        $r = Wait-HerdrAgentProgress -Name 'T-9001' -TimeoutMs 2000 -SampleSeconds 1 -StallMinutes 0
        $r.stalled        | Should -BeFalse -Because 'a screen that could not be read is not a still one'
        $r.signalReadable | Should -BeFalse -Because 'the caller has to know the watch was blind'
        $r.reason         | Should -Be 'timeout'
    }

    It 'says a worker herdr has never heard of is gone, rather than waiting on a dead process' {
        Mock -ModuleName Herdr Get-HerdrAgent { $null }

        $r = Wait-HerdrAgentProgress -Name 'T-9001' -TimeoutMs 4000 -SampleSeconds 1
        $r.reason  | Should -Be 'gone'
        $r.settled | Should -BeFalse
        $r.stalled | Should -BeFalse -Because 'a worker that is not there did not stall, it disappeared'
    }

    # `Get-HerdrAgent` answers with nothing for "no such agent" AND for "herdr could not answer", so
    # a single transient error looks exactly like a worker that has disappeared. Ending the watch on
    # one empty read leaves a live worker unwatched and sends the Hand to reconcile a worktree that
    # is still being written to.
    It 'confirms an unanswered read before deciding a worker is gone' {
        $script:reads = 0
        Mock -ModuleName Herdr Get-HerdrAgent {
            $script:reads++
            if ($script:reads -eq 1) { return $null }
            [pscustomobject]@{ name = 't-9001'; agent_status = 'working'; pane_id = 'p1' }
        }

        $r = Wait-HerdrAgentProgress -Name 'T-9001' -TimeoutMs 2000 -SampleSeconds 1 -StallMinutes 120
        $r.reason | Should -Be 'timeout' -Because 'one unanswered read is not a worker that has gone'
        $script:reads | Should -BeGreaterThan 1 -Because 'the read is retried rather than trusted once'
    }

    # A server that is down answers nothing for every worker, exactly as it does for one it never
    # registered, and it takes far longer to come back than the confirm pause waits. Calling that
    # `gone` sends the Hand to reconcile a worktree that may still be being written to; the watch is
    # what broke, and `wait-failed` is the reason that says so.
    It 'says the watch failed, rather than that the worker vanished, when herdr is not answering' {
        Mock -ModuleName Herdr Get-HerdrAgent { $null }
        Mock -ModuleName Herdr Test-HerdrServer { $false }

        $r = Wait-HerdrAgentProgress -Name 'T-9001' -TimeoutMs 4000 -SampleSeconds 1
        $r.reason  | Should -Be 'wait-failed'
        $r.settled | Should -BeFalse
        $r.stalled | Should -BeFalse
    }

    # A worker sitting on a dialog the screen guard did not match looks exactly like a stalled one.
    # Reporting that as `working` sends the Hand hunting for a stuck step when what is needed is the
    # user's answer, so the state is read on this path like it is on every other wake.
    It 'reads the state on a stall rather than asserting the worker is working' {
        Mock -ModuleName Herdr Test-HerdrAgentAwaitingInput { $true }

        $r = Wait-HerdrAgentProgress -Name 'T-9001' -TimeoutMs 4000 -SampleSeconds 1 -StallMinutes 0
        $r.stalled       | Should -BeTrue
        $r.state         | Should -Be 'blocked' -Because 'the screen outranks the state word here too'
        $r.awaitingInput | Should -BeTrue -Because 'a fabricated $false would hide the question being asked'
    }

    # The two defaults were mutually exclusive: herdr's own four-minute timeout against twenty
    # minutes of silence means the stall branch can never be reached by a caller that takes both.
    It 'never watches for less time than the stall threshold it was given' {
        $script:askedFor = 0
        Mock -ModuleName Herdr Wait-HerdrAgent {
            $script:askedFor = $TimeoutMs
            [pscustomobject]@{ name = 't-9001'; agent_status = 'idle'; pane_id = 'p1' }
        }

        $null = Wait-HerdrAgentProgress -Name 'T-9001' -StallMinutes 20 -SampleSeconds 3600
        $script:askedFor |
            Should -BeGreaterThan (20 * 60000) -Because 'a watch that ends first can never reach the threshold'
    }

    # A wait built on somebody else's timeout becomes a spin the moment that timeout stops being
    # honoured, and a spin is silent. The iteration bound is what stops it, so it is asserted by
    # count rather than by hope.
    It 'gives up instead of spinning when the underlying wait stops consuming its slice' {
        Mock -ModuleName Herdr Wait-HerdrAgent { $null }

        $started = Get-Date
        $r = Wait-HerdrAgentProgress -Name 'T-9001' -TimeoutMs 600000 -SampleSeconds 60
        ((Get-Date) - $started).TotalSeconds |
            Should -BeLessThan 30 -Because 'ten minutes of instant failures must not be waited out'
        $r.reason  | Should -Be 'wait-failed'
        $r.stalled | Should -BeFalse
    }

    It 'reports not settled without inventing a state when the whole wait times out' {
        $r = Wait-HerdrAgentProgress -Name 'T-9001' -TimeoutMs 2000 -SampleSeconds 1 -StallMinutes 120
        $r.settled | Should -BeFalse
        $r.state   | Should -BeNullOrEmpty -Because 'not settled is the absence of an outcome, never an outcome of its own'
        $r.stalled | Should -BeFalse
    }

    # Reporting is the deliverable. `rally` owns what happens to a stalled worker, and a wrong
    # automatic action on one is worse than a late human one - so this must never steer, answer,
    # or stop anything.
    It 'never steers, answers or stops the worker it is watching' {
        Mock -ModuleName Herdr Send-HerdrPrompt { throw 'the watcher must not steer' }
        Mock -ModuleName Herdr Send-HerdrKeys   { throw 'the watcher must not answer a prompt' }
        Mock -ModuleName Herdr Stop-HerdrAgent  { throw 'the watcher must not stop a worker' }

        $null = Wait-HerdrAgentProgress -Name 'T-9001' -TimeoutMs 2000 -SampleSeconds 1 -StallMinutes 0
        Should -Invoke Send-HerdrPrompt -ModuleName Herdr -Times 0 -Exactly
        Should -Invoke Send-HerdrKeys   -ModuleName Herdr -Times 0 -Exactly
        Should -Invoke Stop-HerdrAgent  -ModuleName Herdr -Times 0 -Exactly
    }
}

Describe 'the settled wake is unchanged by the progress wait beside it' {
    # The brief for the progress watcher was explicit that this function keeps its behaviour: other
    # callers depend on it and its guarded screen read is correct for what it does. Pinned here so
    # that a later edit to the pair has to notice.
    It 'still answers with exactly the three fields it always had' {
        Mock -ModuleName Herdr Wait-HerdrAgent {
            [pscustomobject]@{ name = 't-9001'; agent_status = 'idle'; pane_id = 'p1' }
        }
        Mock -ModuleName Herdr Test-HerdrAgentAwaitingInput { $false }

        $r = Wait-HerdrAgentSettled -Name 'T-9001' -TimeoutMs 10
        @($r.PSObject.Properties.Name) | Should -Be @('settled', 'state', 'awaitingInput')
    }
}

# ---------------------------------------------------------------------------------------------
# Pane creation. This is the one that cost the most to learn.
#
# Width is load-bearing and nothing about it is obvious. Every way of telling a stuck worker from a
# busy one - kingshand's screen guard and herdr's own manifest rules alike - is a pattern match over
# the RENDERED terminal, and neither can match a UI that never renders. Dispatch used to split an
# existing pane per worker; each split halves the survivors, so two real workers came out 6 and 3
# columns wide, one character per line, and both detection paths went blind at once. The five-hour
# hang the whole layer exists to prevent was live again and undetectable.
#
# Measured after the fix: four workspaces created in a row were 93-94 columns each with no
# degradation, and a real dispatch into one produced a worker that both herdr and the guard
# classified correctly when it blocked.
#
# Closing siblings does not heal a wrecked layout - the rectangles update, the terminals do not
# reflow - so there is no recovery except a fresh server. That makes this a rule about what is
# never done, which is what the test asserts.
# ---------------------------------------------------------------------------------------------
Describe 'New-HerdrPane never splits, because a split pane is an unreadable pane' {

    It 'creates its own workspace' {
        Mock -ModuleName Herdr Invoke-Herdr { @{ root_pane = @{ pane_id = 'w7:p1' } } }
        InModuleScope Herdr { New-HerdrPane -Cwd 'C:\repo' } | Should -Be 'w7:p1'
    }

    It 'never calls pane split, whatever panes already exist' {
        $script:seen = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName Herdr Invoke-Herdr {
            $script:seen.Add(($Arguments -join ' '))
            @{ root_pane = @{ pane_id = 'w7:p1' } }
        }
        InModuleScope Herdr { $null = New-HerdrPane -Cwd 'C:\repo' }

        @($script:seen | Where-Object { $_ -like 'pane split*' }).Count |
            Should -Be 0 -Because 'each split halves the terminal, and a narrow terminal cannot be read at all'
        @($script:seen | Where-Object { $_ -like 'workspace create*' }).Count |
            Should -Be 1 -Because 'one workspace per worker is what keeps every worker readable'
    }

    It 'scrubs the inherited child-session marker on the pane it creates' {
        $script:seen2 = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName Herdr Invoke-Herdr {
            $script:seen2.Add(($Arguments -join ' '))
            @{ root_pane = @{ pane_id = 'w7:p1' } }
        }
        InModuleScope Herdr { $null = New-HerdrPane -Cwd 'C:\repo' }
        ($script:seen2 -join ' ') | Should -Match 'CLAUDE_CODE_CHILD_SESSION='
    }

    # The real fix rather than a defence against it. A worker has no human at its prompt, so a
    # suggestion of what that human should type next has no purpose and only creates the hazard the
    # send-path guards exist for. The environment check is the first branch of the harness's own
    # resolver, so it wins over everything else that could turn the feature back on.
    It 'starts a worker pane with the prompt-suggestion feature switched off' {
        $script:seen3 = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName Herdr Invoke-Herdr {
            $script:seen3.Add(($Arguments -join ' '))
            @{ root_pane = @{ pane_id = 'w7:p1' } }
        }
        InModuleScope Herdr { $null = New-HerdrPane -Cwd 'C:\repo' }
        ($script:seen3 -join ' ') |
            Should -Match 'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=0' `
            -Because 'a worker with no human at its prompt has no use for a suggested prompt'
    }
}

# ---------------------------------------------------------------------------------------------
# herdr 0.9.5 (protocol 22), captured live on 2026-10-22 against a separate test server.
#
# Every screen and reply below was read off a real herdr 0.9.5 with a real worker in it, then had
# its machine paths replaced by generic ones. docs\2026-10-22-herdr-0-9-5.md records the
# measurement; these pin the parses that run against it, through the public functions.
# ---------------------------------------------------------------------------------------------
Describe 'herdr 0.9.5 replies parse the way 0.8.2 replies did' {
    BeforeAll {
        $script:V095Dir = Initialize-HerdrScreenStub
        $rule = ([string][char]0x2500) * 119

        # A worker blocked on a two-option question. The highlighted option is drawn with the caret
        # and a PLAIN space; the free-text option now carries a trailing full stop.
        $script:V095Question = @"
`u{276F} Use the question tool to ask me one question: which colour do I prefer, with the options Red
  and Blue. Do nothing else.
$rule
 `u{2610} Colour

Which colour do you prefer?

`u{276F} 1. Red
     You prefer red.
  2. Blue
     You prefer blue.
  3. Type something.
$rule
  4. Chat about this

Enter to select `u{00B7} `u{2191}/`u{2193} to navigate `u{00B7} Esc to cancel
"@

        # The folder-trust dialog a fresh directory stops on, at full width.
        $script:V095Trust = @"
 Accessing workspace:

 C:\repos\acme-api

 Quick safety check: Is this a project you created or one you trust?

 `u{276F} No, exit
   Yes, I trust this folder

 Enter to confirm `u{00B7} Esc to cancel
"@

        # The same dialog in a 12-column pane. Every phrase the guard looks for is broken across
        # lines, and herdr itself called this worker idle.
        $script:V095NarrowTrust = @"
 `u{276F} No,
   exit
   Yes, I
   trust
   this
   folder

 Enter
 to
 confirm
 `u{00B7} Esc
 to
 cancel
"@

        # An idle worker with text typed into its box: the caret and a NO-BREAK space, unchanged.
        $script:V095StrayBox = @"
`u{25CF} finished

`u{273B} Baked for 1s `u{00B7} done 5:24 AM
$rule
`u{276F}`u{00A0}stray words in the box
$rule
  `u{23F5}`u{23F5} auto mode on (shift+tab to cycle)
"@

        # A working worker, nine and then forty seconds in. Only the timer and token count moved.
        $script:V095WorkingEarly = @"
`u{276F} Write a short story directly in your reply.

`u{273B} Hashing`u{2026} (9s `u{00B7} `u{2193} 584 tokens)
$rule
`u{276F}`u{00A0}
$rule
  `u{23F5}`u{23F5} auto mode on (shift+tab to cycle) `u{00B7} esc to interrupt
"@
        $script:V095WorkingLater = $script:V095WorkingEarly.Replace('9s', '40s').Replace('584 tokens', '2.1k tokens')

        # The agent record. 0.9.5 adds completion_seq and launch_pending beside the fields this
        # module reads; none of the old ones moved.
        $script:V095AgentGet = '{"id":"cli:agent:get","result":{"agent":{"agent":"claude","agent_status":"done","completion_seq":10,"cwd":"C:\\repos\\acme-api","focused":false,"interactive_ready":true,"name":"t-9001","pane_id":"w2:p1","revision":0,"state_change_seq":10,"tab_id":"w2:t1","terminal_id":"term_0001","workspace_id":"w2"},"type":"agent_info"}}'

        $script:V095NotFound = '{"error":{"code":"agent_not_found","message":"agent target t-9001 not found"},"id":"cli:agent:get"}'

        $script:V095StatusRunning  = '{"client":{"version":"0.9.5","protocol":22},"server":{"status":"running","running":true,"version":"0.9.5","protocol":22,"compatible":true,"endpoint_compatible":true}}'
        $script:V095StatusMixed    = '{"client":{"version":"0.9.5","protocol":22},"server":{"status":"running","running":true,"version":"0.8.2","protocol":20,"compatible":false,"endpoint_compatible":null,"restart_needed":true}}'
        $script:V095StatusStopped  = '{"client":{"version":"0.9.5","protocol":22},"server":{"status":"not_running","running":false,"version":null,"protocol":null,"compatible":null}}'
    }

    BeforeEach { Mock -ModuleName Herdr Get-HerdrCommandPath { $env:KINGSHAND_TEST_HERDR_EXE } }

    Context 'the screen' {
        It 'reads a worker on a question menu as blocked, and its box as empty' {
            Set-HerdrScreen $script:V095Question
            Test-HerdrAgentAwaitingInput -Name 'T-9001' | Should -BeTrue
            Get-HerdrAgentPromptBox -Name 'T-9001' |
                Should -Be '' -Because 'the highlighted option is drawn with a plain space after the caret'
        }

        It 'reads the folder-trust dialog as blocked' {
            Set-HerdrScreen $script:V095Trust
            Test-HerdrAgentAwaitingInput -Name 'T-9001' | Should -BeTrue
        }

        It 'reads a 12-column pane as unreadable rather than as a healthy idle worker' {
            Set-HerdrScreen $script:V095NarrowTrust
            Test-HerdrAgentReadable -Name 'T-9001' | Should -BeFalse
            Test-HerdrAgentAwaitingInput -Name 'T-9001' |
                Should -BeFalse -Because 'the phrases are broken across lines, which is why readability is asked separately'
        }

        It 'quotes text typed into the box' {
            Set-HerdrScreen $script:V095StrayBox
            Get-HerdrAgentPromptBox -Name 'T-9001' | Should -Be 'stray words in the box'
        }

        It 'gives one signal for a working screen whose timer and token count moved' {
            Set-HerdrScreen $script:V095WorkingEarly
            $early = Get-HerdrAgentProgressSignal -Name 'T-9001'
            Set-HerdrScreen $script:V095WorkingLater
            $later = Get-HerdrAgentProgressSignal -Name 'T-9001'

            $early.readable | Should -BeTrue
            $later.signal   | Should -Be $early.signal
            $early.promptBox | Should -Be ''
        }
    }

    Context 'the agent record' {
        It 'returns the agent from a 0.9.5 reply with its new fields beside the old ones' {
            Set-HerdrScreen $script:V095AgentGet
            $a = Get-HerdrAgent -Name 'T-9001'
            $a.pane_id      | Should -Be 'w2:p1'
            $a.agent_status | Should -Be 'done'
        }

        It 'answers an unknown agent with nothing, as before' {
            Set-HerdrScreenFailure -Text $script:V095NotFound -ExitCode 1
            Get-HerdrAgent -Name 'T-9001' | Should -BeNullOrEmpty
        }
    }

    Context 'the server' {
        It 'reports a running server on the same version as compatible' {
            Set-HerdrScreen $script:V095StatusRunning
            $s = Get-HerdrServerState
            $s.state      | Should -Be 'running'
            $s.compatible | Should -BeTrue
        }

        It 'reports a running server on another version as running and not compatible' {
            Set-HerdrScreen $script:V095StatusMixed
            $s = Get-HerdrServerState
            $s.state      | Should -Be 'running'
            $s.compatible | Should -BeFalse
            $s.detail     | Should -Match 'different herdr version'
        }

        It 'reports a stopped server, which 0.9.5 answers with exit 0, with no compatibility claim' {
            Set-HerdrScreen $script:V095StatusStopped
            $s = Get-HerdrServerState
            $s.state      | Should -Be 'stopped'
            $s.compatible | Should -BeNullOrEmpty
        }

        It 'makes no compatibility claim when the reply does not say' {
            Set-HerdrScreen '{"server":{"status":"running","running":true}}'
            (Get-HerdrServerState).compatible | Should -BeNullOrEmpty
        }
    }
}

# ---------------------------------------------------------------------------------------------
# A binary and a server on different herdr versions. Measured both ways between 0.8.2 and 0.9.5:
# every command answers protocol_mismatch while every pane keeps running. Each case forces that
# reply and proves the reader throws it rather than reading it as a worker that is not there.
# ---------------------------------------------------------------------------------------------
Describe 'a herdr binary on a different version from its server fails loudly' {
    BeforeAll {
        $script:MismatchDir = Initialize-HerdrScreenStub

        # Both directions, as each binary words it.
        $script:MismatchNewer = '{"id":"cli:agent:get","error":{"code":"protocol_mismatch","message":"client protocol 22 is newer than server protocol 20; restart the Herdr server before using this command. Stop the old server to use the new version.\nStopping exits pane processes."}}'
        $script:MismatchOlder = '{"id":"cli:agent:get","error":{"code":"protocol_mismatch","message":"client protocol 20 is older than server protocol 22; upgrade the Herdr client before using this command"}}'
    }
    BeforeEach { Mock -ModuleName Herdr Get-HerdrCommandPath { $env:KINGSHAND_TEST_HERDR_EXE } }

    It 'throws from <name>, whichever side is older' -ForEach @(
        @{ name = 'Get-HerdrAgent';          call = { Get-HerdrAgent -Name 'T-9001' } }
        @{ name = 'Get-HerdrAgents';         call = { Get-HerdrAgents } }
        @{ name = 'Get-HerdrAgentInventory'; call = { Get-HerdrAgentInventory } }
        @{ name = 'Get-HerdrAgentState';     call = { Get-HerdrAgentState -Name 'T-9001' } }
        @{ name = 'Read-HerdrAgentScreen';   call = { Read-HerdrAgentScreen -Name 'T-9001' } }
        @{ name = 'Read-HerdrAgent';         call = { Read-HerdrAgent -Name 'T-9001' } }
        @{ name = 'Wait-HerdrAgent';         call = { Wait-HerdrAgent -Name 'T-9001' -TimeoutMs 10 } }
        @{ name = 'Stop-HerdrAgent';         call = { Stop-HerdrAgent -Name 'T-9001' -TimeoutSeconds 1 } }
    ) {
        foreach ($reply in @($script:MismatchNewer, $script:MismatchOlder)) {
            Set-HerdrScreenFailure -Text $reply -ExitCode 1
            { & $call } | Should -Throw '*protocol_mismatch*'
        }
    }

    It 'throws even where the caller asked for herdr''s errors back' {
        Set-HerdrScreenFailure -Text $script:MismatchNewer -ExitCode 1
        { Invoke-Herdr -AllowError -Arguments @('agent', 'list') } |
            Should -Throw '*different versions*'
    }

    It 'never reports a live worker stopped' {
        Set-HerdrScreenFailure -Text $script:MismatchNewer -ExitCode 1
        $r = $null
        try { $r = Stop-HerdrAgent -Name 'T-9001' -TimeoutSeconds 1 } catch { }
        $r | Should -BeNullOrEmpty -Because 'a teardown told "stopped" removes the worktree of a worker still running'
    }

    It 'still hands back every other error under -AllowError' {
        Set-HerdrScreenFailure -Text '{"error":{"code":"agent_not_found","message":"gone"}}' -ExitCode 1
        $r = Invoke-Herdr -AllowError -Arguments @('agent', 'get', 't-9001')
        $r.error.code | Should -Be 'agent_not_found'
    }
}

Describe 'Get-HerdrVersion reads which herdr this binary is' {
    BeforeAll { $script:VersionDir = Initialize-HerdrScreenStub }
    BeforeEach { Mock -ModuleName Herdr Get-HerdrCommandPath { $env:KINGSHAND_TEST_HERDR_EXE } }

    It 'reads the client version and protocol, with no server needed' {
        Set-HerdrScreen '{"client":{"version":"0.9.5","channel":"stable","protocol":22},"server":{"status":"not_running","running":false}}'
        $v = Get-HerdrVersion
        $v.version  | Should -Be '0.9.5'
        $v.protocol | Should -Be 22
        $v.detail   | Should -Be ''
    }

    It 'reads a reply with no client version as unreadable, never as a version' {
        Set-HerdrScreen 'herdr: unrecognised option --json'
        $v = Get-HerdrVersion
        $v.version | Should -BeNullOrEmpty
        $v.path    | Should -Not -BeNullOrEmpty -Because 'a herdr answered, so it is installed'
        $v.detail  | Should -Match 'no client version'
    }

    It 'answers no herdr with no path, and the hint' {
        Mock -ModuleName Herdr Get-HerdrCommandPath { $null }
        $v = Get-HerdrVersion
        $v.path   | Should -BeNullOrEmpty
        $v.detail | Should -Match 'herdr was not found'
    }
}
