#Requires -Version 7.0
Set-StrictMode -Version Latest

# bin\Herdr.psm1 is exercised here with NO herdr server running and no herdr binary invoked.
# `Invoke-Herdr` is the single boundary between this module and the outside world - every command
# in it goes through that one function - so mocking it is what makes the whole module testable
# without a live server, a live pane, or a live Claude Code worker.
#
# Every case below pins a rule that was learned from an observed failure on this machine against
# herdr 0.8.2 (protocol 20), not from the documentation. The comments name which failure.

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

Describe 'Send-HerdrPrompt routes a blocked worker rather than throwing at it' {
    # agent_blocked is a state, not a fault: the worker is sitting on an interactive prompt and
    # cannot take text until it is answered. Throwing would make every caller wrap this in a
    # try/catch and read a routine, recoverable state as a failure.

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

    BeforeEach { Mock -ModuleName Herdr Invoke-Herdr { $null } }

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
            [pscustomobject]@{ readable = $true; signal = 'aaaa'; lastActivity = 'Bash(no-mistakes axi status) | waiting for checks' }
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
            [pscustomobject]@{ readable = $true; signal = "s$script:tick"; lastActivity = 'still going' }
        }

        $r = Wait-HerdrAgentProgress -Name 'T-9001' -TimeoutMs 2000 -SampleSeconds 1 -StallMinutes 0
        $r.stalled | Should -BeFalse -Because 'the threshold counts unchanged time, not elapsed time'
        $r.reason  | Should -Be 'timeout'
    }

    # Fail closed, again. An unreadable screen must never become a stall: the watcher says it could
    # not see, and the Hand is told that rather than told the worker is stuck.
    It 'never claims a stall from a screen it could not read' {
        Mock -ModuleName Herdr Get-HerdrAgentProgressSignal {
            [pscustomobject]@{ readable = $false; signal = ''; lastActivity = '' }
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
}
