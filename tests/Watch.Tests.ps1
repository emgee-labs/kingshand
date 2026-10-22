#Requires -Version 7.0
Set-StrictMode -Version Latest

# bin\Watch.psm1 and bin\Watch.ps1 are the Hand's three watches as short commands. What is pinned
# here is the contract the Hand relies on: every outcome the waits underneath can report comes back
# as its own ONE line naming the outcome and what to do next, nothing is folded into a quieter
# outcome, and a failure to read or to run is named as that failure.
#
# The waits themselves are tested in their own files. Here they are replaced with Mock, and every
# gate reading is built by the real reader from a real TOON document, never assembled by hand.

BeforeAll {
    Import-Module "$PSScriptRoot\..\bin\GateRun.psm1" -Force
    Import-Module "$PSScriptRoot\..\bin\Watch.psm1" -Force
    Import-Module "$PSScriptRoot\..\bin\Crew.psm1" -Force

    $script:WatchScript = "$PSScriptRoot\..\bin\Watch.ps1"

    $script:Running = ConvertFrom-GateRunOutput -Text @'
run:
  id: "01M4WATCHEXAMPLE0000000000"
  branch: feature-x
  status: running
  head: abc1234d
  findings: 0 info
  steps[3]{step,status,findings,duration_ms}:
    intent,completed,0,6
    review,running,0,4200
    test,pending,0,0
'@

    $script:Parked = ConvertFrom-GateRunOutput -Text @'
run:
  id: "01M4WATCHEXAMPLE0000000000"
  branch: feature-x
  status: running
  awaiting_agent: parked 0s
  head: abc1234d
  findings: "2 awaiting"
  steps[3]{step,status,findings,duration_ms}:
    intent,completed,0,6
    review,awaiting_approval,2,406657
    test,pending,0,0
gate:
  step: review
  status: awaiting_approval
  findings[2]{id,severity,file,action,description}:
    w1,warning,bin/Watch.psm1,ask-user,One decision waiting
    w2,info,bin/Watch.ps1,auto-fix,A wording nit
'@

    $script:Passed = ConvertFrom-GateRunOutput -Text @'
run:
  id: "01M4WATCHEXAMPLE0000000000"
  branch: feature-x
  status: completed
  head: abc1234d
  pr: https://github.com/acme/acme-api/pull/7
  findings: 0 info
  steps[3]{step,status,findings,duration_ms}:
    intent,completed,0,6
    review,completed,0,406657
    test,completed,0,337749
outcome: passed
'@

    # A wake in the progress wait's own shape. Every field it reports is here, so a line that
    # forgot one has nothing to fall back on.
    function New-Wake {
        param([string]$Reason = 'settled', [string]$State = 'idle', [bool]$Awaiting = $false,
              [bool]$Readable = $true, [string]$Box = '', [string]$Last = 'Wrote report.md')
        [pscustomobject]@{
            settled = ($Reason -eq 'settled'); state = $State; awaitingInput = $Awaiting
            stalled = ($Reason -eq 'stalled'); reason = $Reason; quietMinutes = 21.5
            waitedMinutes = 45.0; lastActivity = $Last; promptBox = $Box
            signalReadable = $Readable; samples = 3; stallMinutes = 20
        }
    }

    # A gate wait result in Wait-GateRunChange's own shape.
    function New-GateWait {
        param([string]$Reason, $State, [int]$Unreadable = 0)
        [pscustomobject]@{
            changed = ($Reason -in 'parked', 'finished', 'failed', 'changed'); reason = $Reason
            detail = 'x'; changes = @('step review: running -> completed'); changedFields = @('step review')
            parkedOn = if ($Reason -eq 'parked') { 'review' } else { '' }
            outcome = if ($null -ne $State -and $State.outcome) { $State.outcome } else { '' }
            outcomeRecognised = $true; state = $State; baseline = $null; baselineTakenAt = ''
            waitedSeconds = 1800; reads = 4; unreadableReads = $Unreadable
            consecutiveUnreadable = $Unreadable
            lastUnreadable = if ($Unreadable) { 'the daemon did not answer' } else { '' }
            lastUnreadableSignal = ''; timeoutSeconds = 1800; pollSeconds = 15; unreadableTolerance = 3
        }
    }

    function Assert-OneLine {
        param([Parameter(Mandatory)][AllowEmptyString()][string]$Line)
        $Line | Should -Not -BeNullOrEmpty
        $Line.Contains("`n") | Should -BeFalse -Because 'a watch reports in exactly one line'
        $Line | Should -Match 'Next:'
    }
}

Describe 'A worker watch reports every outcome as its own line' {
    It 'names a settled worker and sends the reader to Step 6 rather than calling it finished' {
        $l = Format-WorkerWake -Name 'T-1' -Wake (New-Wake)
        Assert-OneLine $l
        $l | Should -BeLike 'SETTLED T-1 state=idle*'
        $l | Should -BeLike '*not proof it finished*'
        $l | Should -BeLike '*Last seen: Wrote report.md*'
    }

    It 'reports a worker on a prompt as blocked whatever its state word says' {
        $l = Format-WorkerWake -Name 'T-1' -Wake (New-Wake -State 'done' -Awaiting $true)
        Assert-OneLine $l
        $l | Should -BeLike 'BLOCKED T-1*'
        $l | Should -BeLike '*never answer the prompt blind*'
    }

    It 'reports a stall with how long and what it was last seen doing' {
        $l = Format-WorkerWake -Name 'T-1' -Wake (New-Wake -Reason 'stalled' -State 'working')
        Assert-OneLine $l
        $l | Should -BeLike 'STALLED T-1 state=working*21.5 minutes*'
        $l | Should -BeLike '*load rally*'
    }

    It 'reports a stalled worker sitting on a prompt as blocked' {
        $l = Format-WorkerWake -Name 'T-1' -Wake (New-Wake -Reason 'stalled' -Awaiting $true)
        $l | Should -BeLike 'BLOCKED T-1*'
    }

    It 'reports a worker herdr no longer has as gone' {
        $l = Format-WorkerWake -Name 'T-1' -Wake (New-Wake -Reason 'gone')
        Assert-OneLine $l
        $l | Should -BeLike 'GONE T-1*never remove its worktree first*'
    }

    It 'reports the watch failing as the watch failing, not as the worker' {
        $l = Format-WorkerWake -Name 'T-1' -Wake (New-Wake -Reason 'wait-failed')
        Assert-OneLine $l
        $l | Should -BeLike 'WATCH FAILED T-1*unwatched rather than finished*'
    }

    It 'reports a timeout as no outcome' {
        $l = Format-WorkerWake -Name 'T-1' -Wake (New-Wake -Reason 'timeout')
        Assert-OneLine $l
        $l | Should -BeLike 'NO OUTCOME T-1 after 45 minutes*re-arm*'
    }

    It 'says the watch was blind when the screen could not be read' {
        $l = Format-WorkerWake -Name 'T-1' -Wake (New-Wake -Reason 'timeout' -Readable $false)
        $l | Should -BeLike '*watch was blind*'
    }

    It 'quotes text in the input box on every outcome and says never to submit it' {
        foreach ($r in 'settled', 'stalled', 'timeout') {
            $l = Format-WorkerWake -Name 'T-1' -Wake (New-Wake -Reason $r -Box 'yes please')
            $l | Should -BeLike "*'yes please'*never submit or clear it*"
        }
    }

    It 'reads a wake it cannot read as unreadable, never as an outcome' {
        Assert-OneLine (Format-WorkerWake -Name 'T-1' -Wake $null)
        (Format-WorkerWake -Name 'T-1' -Wake $null) | Should -BeLike 'UNREADABLE T-1*'
        (Format-WorkerWake -Name 'T-1' -Wake (New-Wake -Reason 'sideways')) |
            Should -BeLike "UNREADABLE T-1*'sideways'*"
    }

    It 'folds a screen tail with newlines into the one line' {
        $l = Format-WorkerWake -Name 'T-1' -Wake (New-Wake -Last "a`nb`r`nc")
        $l.Contains("`n") | Should -BeFalse
        $l | Should -BeLike '*Last seen: a b c*'
    }
}

Describe 'Watch-Worker' {
    # The default every caller takes is forty-five minutes, above the twenty-minute stall threshold,
    # so the stall branch is reachable without an override - the TimeoutMs failure, kept closed.
    It 'waits forty-five minutes by default and leaves the stall threshold to the wait' {
        Mock -ModuleName Watch Wait-HerdrAgentProgress { New-Wake }
        $null = Watch-Worker -Name 'T-1'
        Should -Invoke -ModuleName Watch Wait-HerdrAgentProgress -Times 1 -ParameterFilter {
            $TimeoutMs -eq 2700000 -and -not $PSBoundParameters.ContainsKey('StallMinutes')
        }
    }

    It 'passes a stall threshold through when one is given' {
        Mock -ModuleName Watch Wait-HerdrAgentProgress { New-Wake }
        $null = Watch-Worker -Name 'T-1' -StallMinutes 30
        Should -Invoke -ModuleName Watch Wait-HerdrAgentProgress -Times 1 -ParameterFilter {
            $StallMinutes -eq 30
        }
    }

    It 'turns a wait that throws into a line naming the failure' {
        Mock -ModuleName Watch Wait-HerdrAgentProgress { throw 'herdr is not on PATH' }
        $l = Watch-Worker -Name 'T-1'
        Assert-OneLine $l
        $l | Should -BeLike 'WATCH FAILED T-1*herdr is not on PATH*'
    }

    It 'carries a warning the wait raised on the end of the line instead of printing it' {
        Mock -ModuleName Watch Wait-HerdrAgentProgress { Write-Warning 'server restarted'; New-Wake }
        $out = @(Watch-Worker -Name 'T-1' 3>&1)
        $out.Count | Should -Be 1
        "$($out[0])" | Should -BeLike '*Warned while waiting: server restarted*'
    }
}

Describe 'A gate watch reports every outcome as its own line' {
    It 'lists a park''s findings by id, severity and action, and sends the reader to them in full' {
        $l = Format-GateWatch -Label 'on feature-x' -Wait (New-GateWait -Reason 'parked' -State $script:Parked)
        Assert-OneLine $l
        $l | Should -BeLike 'PARKED gate on feature-x run 01M4WATCHEXAMPLE0000000000 at its review step*'
        $l | Should -BeLike '*2 finding(s): w1 (warning, ask-user); w2 (info, auto-fix)*'
        $l | Should -BeLike '*decide under petition*'
    }

    It 'names the pull request on a pass' {
        $l = Format-GateWatch -Label 'on feature-x' -Wait (New-GateWait -Reason 'finished' -State $script:Passed)
        Assert-OneLine $l
        $l | Should -BeLike 'PASSED gate*outcome passed, pull request https://github.com/acme/acme-api/pull/7*'
    }

    It 'reports a run that ended without passing as failed, and an unknown word as not passed' {
        $w = New-GateWait -Reason 'failed' -State $script:Running
        $w.outcome = 'exploded'; $w.outcomeRecognised = $false
        $l = Format-GateWatch -Label 'on feature-x' -Wait $w
        Assert-OneLine $l
        $l | Should -BeLike 'FAILED gate*outcome exploded, no pull request recorded*not one this watch knows*'
    }

    It 'reports a run it could not read as unreadable, never as quiet' {
        $l = Format-GateWatch -Label 'on feature-x' -Wait (New-GateWait -Reason 'unreadable' -State $null -Unreadable 3)
        Assert-OneLine $l
        $l | Should -BeLike 'UNREADABLE gate on feature-x*3 times in a row: the daemon did not answer*'
    }

    It 'reports a timeout as no outcome, with where the steps stood and how blind it was' {
        $l = Format-GateWatch -Label 'on feature-x' -Wait (New-GateWait -Reason 'timeout' -State $script:Running -Unreadable 1)
        Assert-OneLine $l
        $l | Should -BeLike 'NO OUTCOME gate on feature-x after 30 minutes*review running*1 of its 4 reads*'
    }

    It 'says a run that timed out parked is parked, and points at its findings rather than another wait' {
        $l = Format-GateWatch -Label 'on feature-x' -Wait (New-GateWait -Reason 'timeout' -State $script:Parked)
        Assert-OneLine $l
        $l | Should -BeLike 'NO OUTCOME gate on feature-x*nothing moved, and it is parked at its review step*petition*'
        $l | Should -Not -BeLike '*neither parked nor ended*'
    }

    It 'reads a wait result it cannot read as unreadable' {
        Format-GateWatch -Label 'on feature-x' -Wait $null | Should -BeLike 'UNREADABLE gate*'
    }
}

Describe 'Watch-GateRun' {
    # The wait returns on any change. A step moving on is not where the Hand is needed, so the watch
    # keeps going - and hands the last reading back in, so a park between two waits is seen.
    It 'waits through a step moving on and stops at the park, handing each reading back in' {
        $script:calls = 0
        Mock -ModuleName Watch Wait-GateRunChange {
            $script:calls++
            if ($script:calls -eq 1) { New-GateWait -Reason 'changed' -State $script:Running }
            else { New-GateWait -Reason 'parked' -State $script:Parked }
        }
        $l = Watch-GateRun -RepoPath 'C:\repos\acme-api' -Branch 'feature-x'
        $l | Should -BeLike 'PARKED gate on feature-x*'
        Should -Invoke -ModuleName Watch Wait-GateRunChange -Times 2
        Should -Invoke -ModuleName Watch Wait-GateRunChange -Times 1 -ParameterFilter {
            $null -ne $FromState -and $FromState.runStatus -eq 'running' -and $Branch -eq 'feature-x'
        }
    }

    It 'turns a wait that throws into a line naming the failure' {
        Mock -ModuleName Watch Wait-GateRunChange { throw 'node is missing' }
        $l = Watch-GateRun -Branch 'feature-x'
        Assert-OneLine $l
        $l | Should -BeLike 'WATCH FAILED gate on feature-x*node is missing*'
    }
}

Describe 'Watch-Delivery' {
    It 'watches the gate when the worker went idle while its run kept going' {
        Mock -ModuleName Watch Wait-HerdrAgentProgress { New-Wake -State 'done' }
        Mock -ModuleName Watch Get-GateRunState { $script:Running }
        Mock -ModuleName Watch Wait-GateRunChange { New-GateWait -Reason 'finished' -State $script:Passed }

        $l = Watch-Delivery -Name 'T-1' -RepoPath 'C:\wt' -Branch 'feature-x'
        Assert-OneLine $l
        $l | Should -BeLike 'IDLE WHILE GATE RUNS T-1*PASSED gate on feature-x*pull/7*'
        Should -Invoke -ModuleName Watch Wait-GateRunChange -Times 1 -ParameterFilter {
            $null -ne $FromState -and $RepoPath -eq 'C:\wt'
        }
    }

    It 'keeps the worker''s own line, input box and all, when it went idle while its run kept going' {
        Mock -ModuleName Watch Wait-HerdrAgentProgress { New-Wake -State 'done' -Box 'half-typed reply' }
        Mock -ModuleName Watch Get-GateRunState { $script:Running }
        Mock -ModuleName Watch Wait-GateRunChange { New-GateWait -Reason 'finished' -State $script:Passed }

        $l = Watch-Delivery -Name 'T-1' -RepoPath 'C:\wt' -Branch 'feature-x'
        Assert-OneLine $l
        $l | Should -BeLike "IDLE WHILE GATE RUNS T-1*PASSED gate*SETTLED T-1*'half-typed reply'*load rally*Last seen: Wrote report.md*"
    }

    It 'reports a gate that was already parked when the worker stopped, with its findings' {
        Mock -ModuleName Watch Wait-HerdrAgentProgress { New-Wake }
        Mock -ModuleName Watch Get-GateRunState { $script:Parked }
        Mock -ModuleName Watch Wait-GateRunChange { throw 'should not wait' }

        $l = Watch-Delivery -Name 'T-1' -RepoPath 'C:\wt' -Branch 'feature-x'
        $l | Should -BeLike 'SETTLED T-1*Its gate: PARKED gate on feature-x*w1 (warning, ask-user)*'
        Should -Invoke -ModuleName Watch Wait-GateRunChange -Times 0
    }

    It 'says so when no gate run is recorded on the branch' {
        Mock -ModuleName Watch Wait-HerdrAgentProgress { New-Wake }
        Mock -ModuleName Watch Get-GateRunState {
            $s = ConvertFrom-GateRunOutput -Text ''; $s.status = 'no-run'; $s }
        (Watch-Delivery -Name 'T-1' -RepoPath 'C:\wt' -Branch 'feature-x') |
            Should -BeLike 'SETTLED T-1*No gate run is recorded on feature-x.'
    }

    It 'says the gate could not be read rather than that there is none' {
        Mock -ModuleName Watch Wait-HerdrAgentProgress { New-Wake }
        Mock -ModuleName Watch Get-GateRunState {
            $s = ConvertFrom-GateRunOutput -Text ''; $s.detail = 'the daemon is down'; $s }
        (Watch-Delivery -Name 'T-1' -RepoPath 'C:\wt' -Branch 'feature-x') |
            Should -BeLike '*gate run on feature-x could not be read: the daemon is down'
    }

    It 'reports a worker that did not settle cleanly as its own outcome and reads no gate' {
        Mock -ModuleName Watch Get-GateRunState { throw 'should not read' }
        foreach ($w in @((New-Wake -Reason 'stalled'), (New-Wake -Awaiting $true), (New-Wake -Reason 'gone'))) {
            Mock -ModuleName Watch Wait-HerdrAgentProgress { $w }.GetNewClosure()
            (Watch-Delivery -Name 'T-1' -RepoPath 'C:\wt' -Branch 'feature-x') |
                Should -Match '^(STALLED|BLOCKED|GONE) T-1'
        }
        Should -Invoke -ModuleName Watch Get-GateRunState -Times 0
    }
}

Describe 'Resolving a worker to watch' {
    It 'reads the worktree and branch from the durable record' {
        $path = Join-Path $TestDrive 'crew-ok.json'
        $s = New-CrewState
        Add-CrewWorker -State $s -WorkerId 'T-1' -Ticket 'T-1' -Kind 'adhoc' -Repo 'acme-api' `
            -Worktree 'C:\wt\T-1' -Branch 'worktree-T-1' -Base 'main' -Brief 'C:\b.md'
        Save-CrewState -State $s -Path $path
        $t = Resolve-WatchTarget -Name 'T-1' -StatePath $path
        $t.ok | Should -BeTrue
        $t.repo | Should -Be 'C:\wt\T-1'
        $t.branch | Should -Be 'worktree-T-1'
    }

    It 'names a worker the record does not have, and guesses no path' {
        $t = Resolve-WatchTarget -Name 'T-404' -StatePath (Join-Path $TestDrive 'none.json')
        $t.ok | Should -BeFalse
        $t.repo | Should -Be ''
        $t.error | Should -BeLike '*has no worker T-404*'
    }

    It 'names a record it cannot read' {
        $path = Join-Path $TestDrive 'crew-bad.json'
        Set-Content -LiteralPath $path -Value '{ "workers": ' -Encoding utf8
        (Resolve-WatchTarget -Name 'T-1' -StatePath $path).error | Should -BeLike '*could not be read*'
    }
}

Describe 'The verb command' {
    It 'answers one line naming why it could not arm, for an id the record does not have' {
        $out = @(& $script:WatchScript gate T-404 -StatePath (Join-Path $TestDrive 'none.json'))
        $out.Count | Should -Be 1
        $out[0] | Should -BeLike 'NOT ARMED gate T-404*has no worker T-404*Next:*'
    }

    It 'answers one line when no worker was named' {
        $out = @(& $script:WatchScript delivery)
        $out.Count | Should -Be 1
        $out[0] | Should -BeLike 'NOT ARMED delivery*'
    }

    It 'refuses a verb it does not have' {
        { & $script:WatchScript sleep T-1 } | Should -Throw
    }
}
