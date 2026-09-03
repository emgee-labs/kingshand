# Browser verification exists to replace an assertion that a change looks right with a record of
# what was seen. So the failure that matters is not a bug in a browser - it is this layer handing
# back something that reads as a pass when nothing was exercised. Every test below forces one of
# those: no tools, half the tools, no outcome, an outcome word nobody defined, a pass with no
# evidence behind it, and no checks at all.

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $script:Root 'bin\BrowserVerify.psm1') -Force

    $script:AllTools = Get-BrowserRequiredTools
}

Describe 'the browser tools are reported present only when they are all present' {
    It 'reports available with the full set' {
        $status = Get-BrowserToolStatus -Loaded $script:AllTools
        $status.available | Should -BeTrue
        @($status.missing).Count | Should -Be 0
        $status.reason | Should -Match 'verification can run'
    }

    It 'accepts the namespaced names the tools actually load under' {
        $namespaced = @($script:AllTools | ForEach-Object { "mcp__claude-in-chrome__$_" })
        (Get-BrowserToolStatus -Loaded $namespaced).available |
            Should -BeTrue -Because 'the agent may report either the short or the namespaced name'
    }

    # The headline failure. The server connected and disconnected twice inside one conversation,
    # so this is an ordinary Tuesday rather than an edge case.
    It 'fails closed when nothing loaded, and says verification did not happen' {
        $status = Get-BrowserToolStatus -Loaded @()
        $status.available | Should -BeFalse
        $status.reason | Should -Match 'Browser verification did not happen'
        $status.reason | Should -Match 'This is not a pass'
        @($status.missing).Count | Should -Be @($script:AllTools).Count
    }

    It 'fails closed when the parameter is omitted entirely' {
        (Get-BrowserToolStatus).available |
            Should -BeFalse -Because 'no evidence that anything loaded is not evidence that it did'
    }

    # A browser that can navigate but cannot read a console produces no evidence, so a partial
    # load is refused rather than quietly narrowing what the run can claim.
    It 'fails closed on a partial load, naming what is missing' {
        $partial = @($script:AllTools | Where-Object { $_ -ne 'read_console_messages' })
        $status  = Get-BrowserToolStatus -Loaded $partial
        $status.available | Should -BeFalse
        $status.missing   | Should -Contain 'read_console_messages'
        $status.reason    | Should -Match 'read_console_messages did not load'
        $status.reason    | Should -Match 'This is not a pass'
    }

    It 'ignores tools nobody asked for' {
        $status = Get-BrowserToolStatus -Loaded (@($script:AllTools) + 'gif_creator')
        $status.available | Should -BeTrue
    }

    # The default required set is what every caller gets, because the skill's command passes
    # -Loaded and nothing else. Exercised here without -Required for exactly that reason.
    It 'uses the module''s own required set when none is given' {
        $status = Get-BrowserToolStatus -Loaded @('navigate')
        @($status.required) | Should -Be @($script:AllTools)
        $status.available   | Should -BeFalse
    }

    It 'honours a narrower required set when one is given' {
        (Get-BrowserToolStatus -Loaded @('navigate') -Required @('navigate')).available |
            Should -BeTrue
    }

    It 'requires the tools the evidence is actually built from' {
        @($script:AllTools) | Should -Contain 'read_console_messages'
        @($script:AllTools) | Should -Contain 'read_network_requests'
        @($script:AllTools) | Should -Not -Contain 'gif_creator' -Because 'text evidence, not images'
    }
}

Describe 'a login is found where it lives, and never invented' {
    BeforeAll {
        $script:ProcessVar = 'KH_BROWSER_VERIFY_TEST_PROCESS'
        $script:AbsentVar  = 'KH_BROWSER_VERIFY_TEST_ABSENT'
    }

    AfterEach {
        [Environment]::SetEnvironmentVariable($script:ProcessVar, $null)
    }

    It 'reads the process environment and says so' {
        [Environment]::SetEnvironmentVariable($script:ProcessVar, 'a-secret')
        $c = Get-BrowserCredentialStatus -Variable $script:ProcessVar
        $c.found  | Should -BeTrue
        $c.source | Should -Be 'process'
        $c.value  | Should -Be 'a-secret'
    }

    # The whole reason this function exists rather than a bare $env: read. A worker is started by
    # a server that has been up for days, so it holds that server's environment and not the
    # machine's - and the summary saying so is the only tell an operator gets.
    It 'never puts the value in the line that goes into the report' {
        [Environment]::SetEnvironmentVariable($script:ProcessVar, 'a-secret')
        $c = Get-BrowserCredentialStatus -Variable $script:ProcessVar
        $c.summary | Should -Not -Match 'a-secret'
        $c.reason  | Should -Not -Match 'a-secret'
        $c.summary | Should -Match $script:ProcessVar
    }

    It 'fails closed when the variable is set nowhere' {
        $c = Get-BrowserCredentialStatus -Variable $script:AbsentVar
        $c.found  | Should -BeFalse
        $c.source | Should -Be 'none'
        $c.value  | Should -BeNullOrEmpty
        $c.reason | Should -Match 'is not set'
        $c.reason | Should -Match 'nothing was signed in to'
    }

    It 'names the variable and the stale-environment fix when it cannot find one' {
        $c = Get-BrowserCredentialStatus -Variable $script:AbsentVar
        $c.reason | Should -Match $script:AbsentVar
        $c.reason | Should -Match 'restart the worker server'
        $c.reason | Should -Match 'Never put the value in a brief, a report or any file'
    }

    It 'treats an empty variable as absent rather than as a login' {
        [Environment]::SetEnvironmentVariable($script:ProcessVar, '')
        (Get-BrowserCredentialStatus -Variable $script:ProcessVar).found |
            Should -BeFalse -Because 'an empty password is not a password'
    }
}

Describe 'every declared check gets an outcome, and a pass has to be earned' {
    It 'passes a run where every check was verified with something observed' {
        $r = Get-BrowserVerificationRecord -Check @(
            @{ id = 'C-001'; check = 'the page loads'; outcome = 'verified'; observed = 'no console errors' }
            @{ id = 'C-002'; check = 'the list renders'; outcome = 'verified'; observed = '12 rows in the DOM' }
        )
        $r.verdict  | Should -Be 'verified'
        $r.verified | Should -BeTrue
        $r.counts.verified | Should -Be 2
    }

    It 'reports one item per declared check' {
        $r = Get-BrowserVerificationRecord -Check @(
            @{ id = 'C-001'; check = 'one'; outcome = 'verified'; observed = 'seen' }
            @{ id = 'C-002'; check = 'two'; outcome = 'failed';   observed = 'a 500 from the API' }
            @{ id = 'C-003'; check = 'three'; outcome = 'not checked'; reason = 'needs a login' }
        )
        @($r.items).Count | Should -Be 3
        @($r.items).check | Should -Be @('one', 'two', 'three')
    }

    It 'fails the whole run when any single check failed' {
        $r = Get-BrowserVerificationRecord -Check @(
            @{ id = 'C-001'; check = 'one'; outcome = 'verified'; observed = 'seen' }
            @{ id = 'C-002'; check = 'two'; outcome = 'failed';   observed = 'a 500 from the API' }
        )
        $r.verdict  | Should -Be 'failed'
        $r.verified | Should -BeFalse
    }

    # Standing criterion 7 from the other side: an item that could not be checked is reported,
    # never skipped, and it stops the run reading as a pass.
    It 'keeps a not-checked item in the record and denies the run a pass' {
        $r = Get-BrowserVerificationRecord -Check @(
            @{ id = 'C-001'; check = 'one'; outcome = 'verified'; observed = 'seen' }
            @{ id = 'C-002'; check = 'two'; outcome = 'not checked'; reason = 'the export needs a login' }
        )
        $r.verdict | Should -Be 'not verified'
        @($r.items | Where-Object { $_.outcome -eq 'not checked' }).Count | Should -Be 1
        ($r.items | Where-Object { $_.id -eq 'C-002' }).reason | Should -Be 'the export needs a login'
    }

    It 'turns a check with no outcome into not checked rather than dropping it' {
        $r = Get-BrowserVerificationRecord -Check @(
            @{ id = 'C-001'; check = 'nobody recorded anything against this' }
        )
        @($r.items).Count     | Should -Be 1
        $r.items[0].outcome   | Should -Be 'not checked'
        $r.items[0].reason    | Should -Match 'No outcome was recorded'
        $r.verdict            | Should -Be 'not verified'
    }

    # An unreadable input reads as unreadable, never as a state word.
    It 'refuses an outcome word nobody defined, and never reads it as a pass' {
        $r = Get-BrowserVerificationRecord -Check @(
            @{ id = 'C-001'; check = 'one'; outcome = 'passed'; observed = 'looked fine' }
        )
        $r.items[0].outcome | Should -Be 'not checked'
        $r.items[0].reason  | Should -Match "'passed' is not one of"
        $r.verdict          | Should -Be 'not verified'
    }

    It 'refuses a verified with nothing observed' {
        $r = Get-BrowserVerificationRecord -Check @(
            @{ id = 'C-001'; check = 'one'; outcome = 'verified' }
        )
        $r.items[0].outcome | Should -Be 'not checked'
        $r.items[0].reason  | Should -Match 'no evidence for it'
        $r.verdict          | Should -Be 'not verified'
    }

    It 'keeps a failed check that recorded what was seen instead' {
        $r = Get-BrowserVerificationRecord -Check @(
            @{ id = 'C-001'; check = 'one'; outcome = 'failed'; observed = 'TypeError at app.js:42' }
        )
        $r.items[0].outcome  | Should -Be 'failed'
        $r.items[0].observed | Should -Be 'TypeError at app.js:42'
    }

    It 'does not read an empty run as a pass' {
        $r = Get-BrowserVerificationRecord -Check @()
        @($r.items).Count | Should -Be 0
        $r.verdict        | Should -Be 'not verified'
        $r.verified       | Should -BeFalse
        $r.summary        | Should -Match 'no checks were declared'
    }

    It 'does not read a missing check list as a pass either' {
        $r = Get-BrowserVerificationRecord
        @($r.items).Count | Should -Be 0
        $r.verdict        | Should -Be 'not verified'
    }

    # The browser-absent path end to end: the reason from Get-BrowserToolStatus carried into the
    # record, where it lands on every check and none of them can come back verified.
    It 'marks every check not checked when the browser was unavailable' {
        $status = Get-BrowserToolStatus -Loaded @()
        $r = Get-BrowserVerificationRecord -Unavailable $status.reason -Check @(
            @{ id = 'C-001'; check = 'one'; outcome = 'verified'; observed = 'seen' }
            @{ id = 'C-002'; check = 'two'; outcome = 'verified'; observed = 'seen' }
        )
        $r.verdict  | Should -Be 'not verified'
        $r.verified | Should -BeFalse
        $r.counts.verified | Should -Be 0
        foreach ($i in $r.items) {
            $i.outcome | Should -Be 'not checked'
            $i.reason  | Should -Match 'Browser verification did not happen'
        }
    }

    It 'summarises the run in words a report can carry' {
        $r = Get-BrowserVerificationRecord -Check @(
            @{ id = 'C-001'; check = 'one'; outcome = 'verified'; observed = 'seen' }
            @{ id = 'C-002'; check = 'two'; outcome = 'failed'; observed = 'a 500' }
            @{ id = 'C-003'; check = 'three'; outcome = 'not checked'; reason = 'needs a login' }
        )
        $r.summary | Should -Match '^failed - 3 checks: 1 verified, 1 failed, 1 not checked\.$'
    }
}
