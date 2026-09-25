#Requires -Version 7.0
Set-StrictMode -Version Latest

# bin\GateRunWait.psm1 is exercised here against readings the real reader produced from real TOON.
# Nothing below starts a run, drives one or needs a daemon: the wait's whole job is turning a
# sequence of readings into one answer, so the sequence is the input and the answer is the
# assertion.
#
# EVERY READING IS BUILT BY `ConvertFrom-GateRunOutput` FROM A DOCUMENT, never hand-assembled. A
# wait tested against hand-made objects would be tested against this test file's idea of what the
# reader returns, which is exactly the kind of guess the reader was written to remove - and the
# reader has already been wrong about its own output's shape once.
#
# THE FOUR FAILURES THIS WAIT EXISTS FOR EACH HAVE THEIR OWN CASE, and every one is forced rather
# than described:
#
#   1. A watch keyed on the branch head moving missed a park for two hours and twenty-six minutes,
#      because a park does not move the head. Two readings that differ only in the head are pinned
#      as the same state.
#   2. A park that was already there when a watch was armed satisfied that watch, so a steer read as
#      answered instantly. A wait armed on a parked run is pinned to time out rather than return.
#   3. A wait keyed on a condition rather than a transition reports whatever happens to be true. The
#      baseline is taken from the first READABLE reading and never from a refused one, so a reader
#      that recovers does not look like a run that moved.
#   4. An unreadable read is neither a change nor nothing happening. One is survived, three in a row
#      end the wait naming the read rather than the run, and both boundaries have their own case.

BeforeAll {
    Import-Module "$PSScriptRoot\..\bin\GateRun.psm1" -Force
    Import-Module "$PSScriptRoot\..\bin\GateRunWait.psm1" -Force

    # A run mid-pipeline: review running, test not started, nothing waiting on anybody.
    $script:RunningToon = @'
run:
  id: "01M4WAITEXAMPLE00000000000"
  branch: feature-x
  status: running
  head: abc1234d
  findings: 0 info
  steps[3]{step,status,findings,duration_ms}:
    intent,completed,0,6
    review,running,0,4200
    test,pending,0,0
'@

    # The same run one step further on. Nothing is waiting and nothing has ended: this is progress,
    # which is a change and is not an outcome.
    $script:ReviewMovedToon = @'
run:
  id: "01M4WAITEXAMPLE00000000000"
  branch: feature-x
  status: running
  head: abc1234d
  findings: 0 info
  steps[3]{step,status,findings,duration_ms}:
    intent,completed,0,6
    review,completed,0,406657
    test,running,0,900
'@

    # The same run with a DIFFERENT HEAD and different step durations, and nothing else moved. This
    # is failure 1 in one document: a watch keyed on the head wakes here, and there is nothing to
    # wake for - the gate committed a fix and carried on.
    $script:HeadMovedToon = @'
run:
  id: "01M4WAITEXAMPLE00000000000"
  branch: feature-x
  status: running
  head: 99ff0011
  findings: 0 info
  steps[3]{step,status,findings,duration_ms}:
    intent,completed,0,9
    review,running,0,51200
    test,pending,0,0
'@

    # The same run with a different residual finding SUMMARY and nothing else. The reader's own
    # header calls that string residual; a wait that woke on it would wake on a count that survives
    # findings being declined.
    $script:SummaryMovedToon = @'
run:
  id: "01M4WAITEXAMPLE00000000000"
  branch: feature-x
  status: running
  head: abc1234d
  findings: "3 awaiting, 2 auto-fix"
  steps[3]{step,status,findings,duration_ms}:
    intent,completed,0,6
    review,running,0,4200
    test,pending,0,0
'@

    # The same run, parked. `awaiting_agent` and a `gate:` object are the two places the tool states
    # it, and this carries both, which is what the live tool emits.
    $script:ParkedToon = @'
run:
  id: "01M4WAITEXAMPLE00000000000"
  branch: feature-x
  status: running
  awaiting_agent: parked 0s
  head: abc1234d
  findings: "1 awaiting"
  steps[3]{step,status,findings,duration_ms}:
    intent,completed,0,6
    review,awaiting_approval,1,406657
    test,pending,0,0
gate:
  step: review
  status: awaiting_approval
  findings[1]{id,severity,file,action,description}:
    w1,warning,bin/GateRunWait.psm1,ask-user,One decision waiting
'@

    # Parked again, on a second decision. The run was already parked when this arrived, so a wait
    # that only asked "was it parked before?" would report this as ordinary progress and bury a
    # decision somebody is waiting on.
    $script:ParkedAgainToon = @'
run:
  id: "01M4WAITEXAMPLE00000000000"
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
    w1,warning,bin/GateRunWait.psm1,ask-user,One decision waiting
    w2,error,bin/GateRunWait.psm1,ask-user,A second decision waiting
'@

    # Still parked on the same decision, with one step's status moved. The park has not changed, so
    # the park is not the news, and calling this `parked` would tell a caller a decision arrived
    # when none did.
    $script:ParkedStepMovedToon = @'
run:
  id: "01M4WAITEXAMPLE00000000000"
  branch: feature-x
  status: running
  awaiting_agent: parked 0s
  head: abc1234d
  findings: "1 awaiting"
  steps[3]{step,status,findings,duration_ms}:
    intent,completed,0,6
    review,awaiting_approval,1,406657
    test,skipped,0,0
gate:
  step: review
  status: awaiting_approval
  findings[1]{id,severity,file,action,description}:
    w1,warning,bin/GateRunWait.psm1,ask-user,One decision waiting
'@

    # The run, over and passed.
    $script:PassedToon = @'
run:
  id: "01M4WAITEXAMPLE00000000000"
  branch: feature-x
  status: completed
  head: abc1234d
  findings: 0 info
  steps[3]{step,status,findings,duration_ms}:
    intent,completed,0,6
    review,completed,0,406657
    test,completed,0,337749
outcome: passed
'@

    # The run, over and not passed. `cancelled` is the tool's own word for a run somebody stopped,
    # and it is carried verbatim rather than translated.
    $script:CancelledToon = @'
run:
  id: "01M4WAITEXAMPLE00000000000"
  branch: feature-x
  status: cancelled
  head: abc1234d
  findings: 0 info
  steps[3]{step,status,findings,duration_ms}:
    intent,completed,0,6
    review,completed,0,406657
    test,failed,0,337749
outcome: cancelled
error: "cancelled: aborted by user"
'@

    # An outcome word this wait has never seen. It still ends the run - waiting longer would be
    # waiting forever - and it is never taken for a pass.
    $script:OddOutcomeToon = @'
run:
  id: "01M4WAITEXAMPLE00000000000"
  branch: feature-x
  status: completed
  head: abc1234d
  steps[1]{step,status,findings,duration_ms}:
    intent,completed,0,6
outcome: quarantined
'@

    # What the tool prints when there is no run to report. A READING, not a refusal: the baseline a
    # wait armed before its own run registered starts from.
    $script:NoRunToon = @'
error: "run \"NOPE-NOT-A-RUN\" not found"
'@

    # Two steps sharing a name. Keyed by name alone the second overwrites the first, and a run whose
    # pipeline has two `review` steps reads as one - the same silent collapse the reader refuses one
    # layer down.
    $script:DuplicateStepToon = @'
run:
  id: "01M4WAITDUPLICATE000000000"
  branch: feature-x
  status: running
  steps[2]{step,status,findings,duration_ms}:
    review,completed,0,6
    review,running,0,4200
'@

    # Decoded once here rather than per case: each of these is a node process, and what is being
    # tested below is the wait rather than the decoder.
    $script:Running         = ConvertFrom-GateRunOutput -Text $script:RunningToon
    $script:ReviewMoved     = ConvertFrom-GateRunOutput -Text $script:ReviewMovedToon
    $script:HeadMoved       = ConvertFrom-GateRunOutput -Text $script:HeadMovedToon
    $script:SummaryMoved    = ConvertFrom-GateRunOutput -Text $script:SummaryMovedToon
    $script:Parked          = ConvertFrom-GateRunOutput -Text $script:ParkedToon
    $script:ParkedAgain     = ConvertFrom-GateRunOutput -Text $script:ParkedAgainToon
    $script:ParkedStepMoved = ConvertFrom-GateRunOutput -Text $script:ParkedStepMovedToon
    $script:Passed          = ConvertFrom-GateRunOutput -Text $script:PassedToon
    $script:Cancelled       = ConvertFrom-GateRunOutput -Text $script:CancelledToon
    $script:OddOutcome      = ConvertFrom-GateRunOutput -Text $script:OddOutcomeToon
    $script:NoRun           = ConvertFrom-GateRunOutput -Text $script:NoRunToon
    $script:DuplicateStep   = ConvertFrom-GateRunOutput -Text $script:DuplicateStepToon

    # The reader's own refusal, built by the reader. Empty text is the one input guaranteed to come
    # back `unreadable` with every field absent, so this is what a failed read really looks like
    # rather than what this file imagines one looks like.
    $script:Unreadable = ConvertFrom-GateRunOutput -Text ''

    # The readings one wait will be given, in order. The last one repeats once the queue runs out,
    # which is what a real run does: it sits in whatever state it reached.
    function Set-ReadQueue {
        param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Readings)
        $script:Queue   = @($Readings)
        $script:QueueAt = 0
    }
}

Describe 'What counts as the run changing' {
    It 'names each step by its own name rather than as one joined line' {
        $sig = Get-GateRunSignature -State $script:Running

        $sig['step intent'] | Should -Be 'completed'
        $sig['step review'] | Should -Be 'running'
        $sig['step test']   | Should -Be 'pending'
    }

    It 'reads the park flag as a flag, not as its own text' {
        # `[bool]'False'` is $true, so a wait that rendered this field and cast the result would
        # report every run as parked - and one that tested the text the other way round would
        # report every run as not parked. Neither mistake announces itself.
        (Get-GateRunSignature -State $script:Parked)['waiting']  | Should -Be 'yes'
        (Get-GateRunSignature -State $script:Running)['waiting'] | Should -Be 'no'
    }

    It 'takes a head that moved as the same state' {
        # FAILURE 1, FORCED. These two readings differ in the branch head and in three step
        # durations. A watch keyed on the head wakes here; a park does not move the head, so that
        # watch also sleeps through the thing it was armed for.
        $script:HeadMoved.head | Should -Not -Be $script:Running.head -Because 'the fixture must
            actually differ, or this proves nothing'

        $diff = @(Compare-GateRunSignature -From (Get-GateRunSignature -State $script:Running) `
                                           -To   (Get-GateRunSignature -State $script:HeadMoved))
        $diff.Count | Should -Be 0
    }

    It 'takes a residual finding summary that moved as the same state' {
        $script:SummaryMoved.findingsSummary | Should -Not -Be $script:Running.findingsSummary

        $diff = @(Compare-GateRunSignature -From (Get-GateRunSignature -State $script:Running) `
                                           -To   (Get-GateRunSignature -State $script:SummaryMoved))
        $diff.Count | Should -Be 0
    }

    It 'keeps two steps that share a name rather than collapsing them into one' {
        $sig = Get-GateRunSignature -State $script:DuplicateStep

        @($sig.Keys | Where-Object { $_ -like 'step *' }).Count | Should -Be 2
        $sig['step review']    | Should -Be 'completed'
        $sig['step review #2'] | Should -Be 'running'
    }

    It 'says which field moved and what it moved from' {
        $diff = @(Compare-GateRunSignature -From (Get-GateRunSignature -State $script:Running) `
                                           -To   (Get-GateRunSignature -State $script:ReviewMoved))

        @($diff | ForEach-Object { $_.key }) | Should -Contain 'step review'
        @($diff | ForEach-Object { $_.text }) |
            Should -Contain 'step review: running -> completed'
    }

    It 'renders an empty side as (none) rather than as a gap' {
        $diff = @(Compare-GateRunSignature -From (Get-GateRunSignature -State $script:Running) `
                                           -To   (Get-GateRunSignature -State $script:Passed))

        @($diff | ForEach-Object { $_.text }) | Should -Contain 'outcome: (none) -> passed'
    }
}

Describe 'Waiting for a change' {
    BeforeEach {
        Mock -ModuleName GateRunWait Get-GateRunState {
            $i = [Math]::Min($script:QueueAt, $script:Queue.Count - 1)
            $script:QueueAt++
            $script:Queue[$i]
        }
    }

    It 'returns when the run parks, and says what it parked on' {
        Mock -ModuleName GateRunWait Start-Sleep { }
        Set-ReadQueue @($script:Running, $script:Running, $script:Parked)

        $w = Wait-GateRunChange -PollSeconds 1

        $w.changed  | Should -BeTrue
        $w.reason   | Should -Be 'parked'
        $w.parkedOn | Should -Be 'review'
        $w.detail   | Should -Match 'parked at its review step'
        $w.detail   | Should -Match '1 finding'
    }

    It 'does not return a park that was already there when it was armed' {
        # FAILURE 2, FORCED, and the load-bearing case in this file. Every reading here is the same
        # parked run. A wait keyed on the CONDITION "is it parked?" returns instantly and reports a
        # decision as having just arrived; this one has to sit until its clock runs out.
        Set-ReadQueue @($script:Parked)

        $w = Wait-GateRunChange -TimeoutSeconds 1 -PollSeconds 1

        $w.changed | Should -BeFalse
        $w.reason  | Should -Be 'timeout'
        $w.reads   | Should -BeGreaterThan 1 -Because 'it must actually have read again'
        $w.changes.Count | Should -Be 0
    }

    It 'returns when the run finishes, carrying the tool''s own outcome word' {
        Mock -ModuleName GateRunWait Start-Sleep { }
        Set-ReadQueue @($script:Running, $script:Passed)

        $w = Wait-GateRunChange -PollSeconds 1

        $w.changed           | Should -BeTrue
        $w.reason            | Should -Be 'finished'
        $w.outcome           | Should -Be 'passed'
        $w.outcomeRecognised | Should -BeTrue
    }

    It 'reports a run that ended without passing as failed, not as finished' {
        Mock -ModuleName GateRunWait Start-Sleep { }
        Set-ReadQueue @($script:Running, $script:Cancelled)

        $w = Wait-GateRunChange -PollSeconds 1

        $w.reason            | Should -Be 'failed'
        $w.outcome           | Should -Be 'cancelled'
        $w.outcomeRecognised | Should -BeTrue
        $w.detail            | Should -Match 'which is not passed'
    }

    It 'ends the wait on an outcome word it does not know, and says it does not know it' {
        # The run said it is over. Waiting for a word this happens to recognise would be waiting
        # forever, and calling an unknown word a pass would be the fabrication everything here
        # refuses - so it ends, reports not passed, and names the word verbatim.
        Mock -ModuleName GateRunWait Start-Sleep { }
        Set-ReadQueue @($script:Running, $script:OddOutcome)

        $w = Wait-GateRunChange -PollSeconds 1

        $w.reason            | Should -Be 'failed'
        $w.outcome           | Should -Be 'quarantined'
        $w.outcomeRecognised | Should -BeFalse
        $w.detail            | Should -Match 'not a word this wait recognises'
    }

    It 'reports a step moving as progress rather than as an end' {
        Mock -ModuleName GateRunWait Start-Sleep { }
        Set-ReadQueue @($script:Running, $script:ReviewMoved)

        $w = Wait-GateRunChange -PollSeconds 1

        $w.changed       | Should -BeTrue
        $w.reason        | Should -Be 'changed'
        $w.changedFields | Should -Contain 'step review'
        $w.outcome       | Should -BeNullOrEmpty
        $w.parkedOn      | Should -BeNullOrEmpty
    }

    It 'notices the run it is waiting for appearing at all' {
        # The tool saying there is no run is a READING, so it baselines from it and wakes when the
        # run registers. A watcher that could not baseline "no run" is the one that read somebody
        # else's finished run and reported success immediately.
        Mock -ModuleName GateRunWait Start-Sleep { }
        Set-ReadQueue @($script:NoRun, $script:Running)

        $w = Wait-GateRunChange -PollSeconds 1

        $w.changed        | Should -BeTrue
        $w.changedFields  | Should -Contain 'run id'
        $w.baseline.status | Should -Be 'no-run'
        $w.state.status    | Should -Be 'has-run'
    }

    It 'returns a second decision on a run that was already parked' {
        # Parked before and parked after, so "was it parked?" has not changed - but a new finding is
        # waiting on somebody, and burying that under `changed` is the same silence in miniature.
        Mock -ModuleName GateRunWait Start-Sleep { }
        Set-ReadQueue @($script:Parked, $script:ParkedAgain)

        $w = Wait-GateRunChange -PollSeconds 1

        $w.reason        | Should -Be 'parked'
        $w.changedFields | Should -Contain 'findings'
        $w.detail        | Should -Match '2 finding'
    }

    It 'does not call an unchanged park a new park when only a step moved' {
        Mock -ModuleName GateRunWait Start-Sleep { }
        Set-ReadQueue @($script:Parked, $script:ParkedStepMoved)

        $w = Wait-GateRunChange -PollSeconds 1

        $w.reason        | Should -Be 'changed'
        $w.changedFields | Should -Contain 'step test'
        $w.changedFields | Should -Not -Contain 'findings'
    }
}

Describe 'When the run cannot be read' {
    BeforeEach {
        Mock -ModuleName GateRunWait Get-GateRunState {
            $i = [Math]::Min($script:QueueAt, $script:Queue.Count - 1)
            $script:QueueAt++
            $script:Queue[$i]
        }
    }

    It 'survives one read it could not take' {
        # One failed read is noise. Ending the wait here is the false alarm that gets a wait
        # ignored, and an ignored wait is the silence it was built to remove arriving by another
        # door.
        Mock -ModuleName GateRunWait Start-Sleep { }
        Set-ReadQueue @($script:Running, $script:Unreadable, $script:Parked)

        $w = Wait-GateRunChange -PollSeconds 1

        $w.reason                | Should -Be 'parked'
        $w.unreadableReads       | Should -Be 1
        $w.consecutiveUnreadable | Should -Be 0
    }

    It 'stops after three failed reads in a row and names the read, not the run' {
        Mock -ModuleName GateRunWait Start-Sleep { }
        Set-ReadQueue @($script:Running, $script:Unreadable)

        $w = Wait-GateRunChange -PollSeconds 1

        $w.changed               | Should -BeFalse
        $w.reason                | Should -Be 'unreadable'
        $w.consecutiveUnreadable | Should -Be 3
        $w.unreadableTolerance   | Should -Be 3
        $w.detail                | Should -Match '3 times in a row'
        $w.detail                | Should -Match 'Silence is not an empty run'
    }

    It 'never takes a failed read as the baseline' {
        # THE THIRD WRONG ANSWER, FORCED. If a refusal could be a baseline, the next readable read
        # is a transition from `unreadable` to `has-run` - and the wait reports a change in the
        # reader's luck as a change in the run. Two identical readable readings follow one refusal
        # here, and nothing changed.
        Set-ReadQueue @($script:Unreadable, $script:Running)

        $w = Wait-GateRunChange -TimeoutSeconds 2 -PollSeconds 1

        $w.changed          | Should -BeFalse
        $w.reason           | Should -Be 'timeout'
        $w.unreadableReads  | Should -Be 1
        $w.baseline.status  | Should -Be 'has-run'
    }

    It 'counts consecutively, so a read that worked clears the count' {
        Mock -ModuleName GateRunWait Start-Sleep { }
        Set-ReadQueue @($script:Running, $script:Unreadable, $script:Unreadable,
                        $script:Running, $script:Unreadable, $script:Unreadable,
                        $script:Parked)

        $w = Wait-GateRunChange -PollSeconds 1

        $w.reason          | Should -Be 'parked'
        $w.unreadableReads | Should -Be 4 -Because 'four reads failed and none of them three in a row'
    }

    It 'says plainly that it never read anything when nothing was ever readable' {
        Mock -ModuleName GateRunWait Start-Sleep { }
        Set-ReadQueue @($script:Unreadable)

        $w = Wait-GateRunChange -PollSeconds 1

        $w.reason   | Should -Be 'unreadable'
        $w.state    | Should -BeNullOrEmpty
        $w.baseline | Should -BeNullOrEmpty
        $w.detail   | Should -Match 'No readable reading was ever taken'
    }

    It 'takes a reader that threw as a failed read rather than dying inside the wait' {
        Mock -ModuleName GateRunWait Start-Sleep { }
        Mock -ModuleName GateRunWait Get-GateRunState { throw 'the daemon closed the connection' }

        $w = Wait-GateRunChange -PollSeconds 1

        $w.changed              | Should -BeFalse
        $w.reason               | Should -Be 'unreadable'
        $w.lastUnreadableSignal | Should -Be 'reader-failed'
        $w.lastUnreadable       | Should -Match 'the daemon closed the connection'
    }

    It 'takes a reader that answered with nothing as a failed read, never as a state' {
        Mock -ModuleName GateRunWait Start-Sleep { }
        Mock -ModuleName GateRunWait Get-GateRunState { $null }

        $w = Wait-GateRunChange -PollSeconds 1

        $w.reason               | Should -Be 'unreadable'
        $w.lastUnreadableSignal | Should -Be 'reader-said-nothing'
        $w.state                | Should -BeNullOrEmpty
    }

    It 'says how much of the time it was blind when it runs out of clock' {
        # A wait that spent reads blind cannot honestly report that nothing changed. The difference
        # between "the run is quiet" and "I could not always tell" is the whole of R-004.
        Set-ReadQueue @($script:Running, $script:Unreadable, $script:Running)

        $w = Wait-GateRunChange -TimeoutSeconds 2 -PollSeconds 1

        $w.reason          | Should -Be 'timeout'
        $w.unreadableReads | Should -Be 1
        $w.detail          | Should -Match 'could not be read'
    }
}

Describe 'A timeout is the absence of an outcome' {
    BeforeEach {
        Mock -ModuleName GateRunWait Get-GateRunState {
            $i = [Math]::Min($script:QueueAt, $script:Queue.Count - 1)
            $script:QueueAt++
            $script:Queue[$i]
        }
    }

    It 'reports a timeout as no change rather than as a state of its own' {
        Set-ReadQueue @($script:Running)

        $w = Wait-GateRunChange -TimeoutSeconds 1 -PollSeconds 1

        $w.changed       | Should -BeFalse
        $w.reason        | Should -Be 'timeout'
        $w.outcome       | Should -BeNullOrEmpty
        $w.parkedOn      | Should -BeNullOrEmpty
        $w.changes.Count | Should -Be 0
        $w.detail        | Should -Match 'absence of an outcome'
        $w.state.runId   | Should -Be '01M4WAITEXAMPLE00000000000' -Because 'the last readable
            reading is still worth handing back'
    }
}

Describe 'Reading the run, and only through the reader' {
    It 'asks the reader for the active run in the current directory by default' {
        Mock -ModuleName GateRunWait Start-Sleep { }
        $script:SeenRepoPath = 'unset'
        $script:SeenRun      = 'unset'
        $script:SeenBranch   = 'unset'
        Mock -ModuleName GateRunWait Get-GateRunState {
            $script:SeenRepoPath = $RepoPath
            $script:SeenRun      = $Run
            $script:SeenBranch   = $Branch
            $i = [Math]::Min($script:QueueAt, $script:Queue.Count - 1)
            $script:QueueAt++
            $script:Queue[$i]
        }
        Set-ReadQueue @($script:Running, $script:Passed)

        $null = Wait-GateRunChange -PollSeconds 1

        # All three defaults fired, and each one is the reader's own default asked for by name.
        $script:SeenRepoPath | Should -Be ''
        $script:SeenRun      | Should -Be ''
        $script:SeenBranch   | Should -Be ''
    }

    It 'passes the run and the branch it was given straight through' {
        Mock -ModuleName GateRunWait Start-Sleep { }
        $script:SeenRepoPath = 'unset'
        $script:SeenRun      = 'unset'
        $script:SeenBranch   = 'unset'
        Mock -ModuleName GateRunWait Get-GateRunState {
            $script:SeenRepoPath = $RepoPath
            $script:SeenRun      = $Run
            $script:SeenBranch   = $Branch
            $i = [Math]::Min($script:QueueAt, $script:Queue.Count - 1)
            $script:QueueAt++
            $script:Queue[$i]
        }
        Set-ReadQueue @($script:Running, $script:Passed)

        $null = Wait-GateRunChange -RepoPath 'C:\repos\acme-api' -Run '01ABC' `
                                   -Branch 'some-feature' -PollSeconds 1

        $script:SeenRepoPath | Should -Be 'C:\repos\acme-api'
        $script:SeenRun      | Should -Be '01ABC'
        $script:SeenBranch   | Should -Be 'some-feature'
    }
}

Describe 'The settings it ran under' {
    BeforeEach {
        Mock -ModuleName GateRunWait Start-Sleep { }
        Mock -ModuleName GateRunWait Get-GateRunState {
            $i = [Math]::Min($script:QueueAt, $script:Queue.Count - 1)
            $script:QueueAt++
            $script:Queue[$i]
        }
        Set-ReadQueue @($script:Running, $script:Passed)
    }

    It 'waits thirty minutes at a fifteen-second poll with a tolerance of three, by default' {
        # Every default fired by one ordinary call, and reported on the result rather than left for
        # a caller to guess at.
        $w = Wait-GateRunChange

        $w.timeoutSeconds      | Should -Be 1800
        $w.pollSeconds         | Should -Be 15
        $w.unreadableTolerance | Should -Be 3
    }

    It 'keeps the default timeout above the point where a failed read could never be counted' {
        # STANDING CRITERION 6, and the failure it names verbatim. Three consecutive failed reads at
        # the default poll need 60 seconds of clock; the default timeout is 1800, so the branch is
        # reachable for a caller that overrides nothing.
        $w = Wait-GateRunChange

        $w.timeoutSeconds |
            Should -BeGreaterThan (($w.unreadableTolerance + 1) * $w.pollSeconds)
    }

    It 'lifts a computed timeout that a long poll would otherwise make useless' {
        # A ten-minute poll and a tolerance of three needs 40 minutes to reach the unreadable
        # branch, which a flat 30-minute default would cut off - so the default is a floor rather
        # than a constant.
        $w = Wait-GateRunChange -PollSeconds 600

        $w.timeoutSeconds | Should -Be 2400
    }

    It 'takes a poll interval and a tolerance below one as one' {
        $w = Wait-GateRunChange -PollSeconds 0 -UnreadableTolerance 0

        $w.pollSeconds         | Should -Be 1
        $w.unreadableTolerance | Should -Be 1
    }
}

Describe 'What the result carries' {
    BeforeEach {
        Mock -ModuleName GateRunWait Start-Sleep { }
        Mock -ModuleName GateRunWait Get-GateRunState {
            $i = [Math]::Min($script:QueueAt, $script:Queue.Count - 1)
            $script:QueueAt++
            $script:Queue[$i]
        }
    }

    It 'carries the state it stopped in, what moved, and how long it waited' {
        Set-ReadQueue @($script:Running, $script:Parked)

        $w = Wait-GateRunChange -PollSeconds 1

        $w.state.runId        | Should -Be '01M4WAITEXAMPLE00000000000'
        $w.state.findings[0].id | Should -Be 'w1'
        $w.baseline.runStatus | Should -Be 'running'
        $w.changes.Count      | Should -BeGreaterThan 0
        $w.changedFields      | Should -Contain 'waiting'
        $w.waitedSeconds      | Should -BeGreaterOrEqual 0
        $w.reads              | Should -Be 2
        $w.baselineTakenAt    | Should -Not -BeNullOrEmpty
    }
}
