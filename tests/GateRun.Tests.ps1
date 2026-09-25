#Requires -Version 7.0
Set-StrictMode -Version Latest

# bin\GateRun.psm1 is exercised here against captured gate output. Nothing below starts a run,
# drives one, or needs a daemon - the reader's whole job is turning one document into state, so the
# document is the input and the state is the assertion.
#
# THE FIXTURES ARE REAL WHEREVER A REAL ONE EXISTS. The completed run, the cancelled run carrying a
# residual finding count, and the "run not found" error are all verbatim captures from
# `no-mistakes axi status` on this repository. The parked run and the gate response are built from
# the field names the gate's own shipped documentation gives, and both were round-tripped through
# the reference TOON implementation before being pinned here, so neither is a guess about the
# format.
#
# THREE TRAPS HAVE THEIR OWN CASES AND EACH ONE FORCES THE FAILURE, because each has already
# produced a wrong answer in a real session:
#
#   1. `findings: "1 awaiting"` persists as a residual count after findings are declined, so it
#      never means anything is waiting. The fixture for this is a real cancelled run that still
#      says it.
#   2. `Select-Object -Unique` over a step regex merges `steps[]` and `active_steps[]` into a
#      composite that reads like a step list and is not one. The fixture carries both lists with
#      one step name in each, which is exactly the input that merges.
#   3. The `help[]` block contains `outcome:`, `approve` and `push`, so a pattern applied to the
#      whole output matches help rather than state. The fixture's help text contains all three.
#
# TWO MORE HAVE THEIR OWN CASES FOR THE SAME REASON, and both are about a field that is present
# rather than one that is missing:
#
#   4. `gate:` arrives as an object on the live tool and as a scalar step name in the shipped
#      documentation. Reading only the documented shape lost the step, the park's target and every
#      finding on a real response carrying six. Both shapes are pinned, side by side.
#   5. An `awaiting_agent` wording this reader has not seen is still the tool saying the run is
#      waiting. Reading it as not waiting is the failure that left a parked run sitting for two
#      hours and twenty-six minutes, and the fixture forces exactly that value.
#
# And the rule underneath all of them: an output that cannot be read reads as unreadable, never as
# a state word and never as an empty run. Every failure path below is forced rather than described.

BeforeAll {
    Import-Module "$PSScriptRoot\..\bin\GateRun.psm1" -Force

    # A real capture. Nine steps, every one terminal, a skipped `ci`, and a passed outcome.
    $script:CompletedRun = @'
run:
  id: "01M3B8FPAF2P3Y52THCFCX4TX6"
  branch: worktree-kh-away-journal
  status: completed
  head: 9845e8fa
  pr: "https://github.com/emgee-labs/kingshand/pull/34"
  findings: 1 info
  steps[9]{step,status,findings,duration_ms}:
    intent,completed,0,6
    rebase,completed,0,2190
    review,completed,1,856679
    test,completed,0,337749
    document,completed,0,721774
    lint,completed,0,80
    push,completed,0,4133
    pr,completed,0,56578
    ci,skipped,0,0
outcome: passed
'@

    # A real capture, and the whole of trap 1 in one document: `findings: "1 awaiting, 1 auto-fix"`
    # on a run that was cancelled, with every step terminal and nothing waiting on anybody.
    $script:CancelledRunWithResidualCount = @'
run:
  id: "01M25A5FXZWXZFJN36203BXB9Z"
  branch: worktree-kh-family-rules
  status: cancelled
  head: ae00e1cf
  pr: "https://github.com/emgee-labs/kingshand/pull/30"
  findings: "1 awaiting, 1 auto-fix"
  steps[9]{step,status,findings,duration_ms}:
    intent,completed,0,11
    rebase,completed,0,2700
    review,completed,2,4599191
    test,completed,0,499921
    document,completed,0,744241
    lint,completed,0,112
    push,completed,0,5240
    pr,completed,0,70625
    ci,failed,0,49560
outcome: cancelled
error: "cancelled: aborted by user"
'@

    # A real capture: what the tool prints for a run id it does not have. Exit code 1, and a
    # perfectly readable document.
    $script:RunNotFound = @'
error: "run \"NOPE-NOT-A-RUN\" not found"
'@

    # Trap 2 in one document: a `steps[]` list and an `active_steps[]` list that share the step
    # name `review`. Merging or deduplicating the two is what produced a composite step list.
    $script:ParkedRun = @'
run:
  id: 01M4PARKEDEXAMPLE0000000000
  branch: feature-x
  status: running
  awaiting_agent: parked 12m
  head: abc1234d
  findings: 3 awaiting
  steps[5]{step,status,findings,duration_ms}:
    intent,completed,0,7
    rebase,completed,0,2100
    review,awaiting,3,742000
    test,pending,0,0
    push,pending,0,0
  active_steps[1]{step,active_for,last_activity,agent_pid,round}:
    review,12m30s,quiet 11m,48122,fix 2
'@

    # Trap 3 in one document, and the escaping argument beside it. The `help[6]` list contains
    # `outcome:`, `approve` and `push`; the second finding's description carries a comma, a colon,
    # an escaped double quote and escaped backslashes, which is TOON's own escape set and not
    # CSV's - the reason this module decodes rather than splitting.
    $script:GateResponse = @'
gate: review
note: "Review auto-fix is disabled by default (auto_fix.review: 0), so blocking and ask-user review findings park for your decision."
findings[2]{id,severity,file,line,action,description}:
  r1,warning,internal/pipeline/executor.go,"",auto-fix,Error from os.Remove is ignored
  r2,error,cmd/main.go,"",ask-user,"The new --force flag bypasses the confirm prompt, which changes behaviour: \"are you sure?\" never appears, and the path C:\\tmp\\x is undocumented."
help[6]: Run `no-mistakes axi respond --action approve` to accept this step and continue,Run `no-mistakes axi respond --action fix --findings <ids>` to have the pipeline fix the selected findings,Run `no-mistakes axi respond --action skip` to skip this step,Run `no-mistakes axi logs --step review --full` to read the full step log,"A long-running call is working, not stalled. Read every return; on a `gate:`, respond; loop until an `outcome:`.",Commit post-pipeline follow-up work on top of the existing branch so every pipeline fix commit remains present. Never push by hand.
'@

    # The exact description the fixture above encodes, so the assertion compares against the value
    # rather than against whatever the reader happened to produce.
    $script:NastyDescription =
        'The new --force flag bypasses the confirm prompt, which changes behaviour: ' +
        '"are you sure?" never appears, and the path C:\tmp\x is undocumented.'

    # A real capture from no-mistakes v1.57.0, and the shape the shipped documentation does not
    # show: `gate:` is an object carrying its own step, status, risk, note and findings table, on a
    # document that also has a run. Reading `gate:` as a scalar step name left the step empty and
    # looked for the findings at the top level, where there are none - so this response, which
    # carries six findings to decide on, read as none at all. Every id, severity, file and action
    # below is verbatim; only the descriptions are shortened.
    $script:GateObjectResponse = @'
run:
  id: "01M3BE8203JPV572AVT9832923"
  branch: worktree-kh-gate-state-read-helper
  status: running
  awaiting_agent: parked 0s
  head: 6dae221c
  findings: "3 awaiting, 2 auto-fix, 1 info"
  steps[9]{step,status,findings,duration_ms}:
    intent,completed,0,6
    rebase,completed,0,2419
    review,awaiting_approval,6,406657
    test,pending,0,0
    document,pending,0,0
    lint,pending,0,0
    push,pending,0,0
    pr,pending,0,0
    ci,pending,0,0
gate:
  step: review
  status: awaiting_approval
  risk: medium
  note: "Review auto-fix is disabled by default (auto_fix.review: 0), so blocking and ask-user review findings park for your decision rather than being silently self-fixed."
  findings[6]{id,severity,file,action,description}:
    gr-argv-space,warning,bin/GateRun.psm1,auto-fix,Two filesystem paths reach node as one joined string
    gr-claudemd-row,warning,CLAUDE.md,ask-user,The Tooling table carries no row for this module
    gr-design-note,warning,bin/GateRun.psm1,ask-user,No dated design note accompanies this change
    gr-awaiting-unrecognised,info,bin/GateRun.psm1,ask-user,An unrecognised awaiting_agent value reads as not parked
    gr-temp-count-flaky,info,tests/GateRun.Tests.ps1,auto-fix,The temp count covers the whole shared directory
    gr-branch-guard-gate,info,bin/GateRun.psm1,no-op,The branch guard fires on a run answer only
help[2]: Run `no-mistakes axi respond --action approve` to accept this step and continue,Run `no-mistakes axi logs --step review --full` to read the full step log
'@

    # A run carrying an `awaiting_agent` wording this reader has not seen. The tool is stating that
    # the run is waiting on the agent; what it is waiting for is not a form this recognises.
    $script:UnrecognisedAwaitingRun = @'
run:
  id: 01M4UNRECOGNISED000000000000
  branch: feature-x
  status: running
  awaiting_agent: awaiting review decision
  head: abc1234d
  steps[2]{step,status,findings,duration_ms}:
    intent,completed,0,7
    review,awaiting,3,742000
'@

    # A run whose `awaiting_agent` carries an object rather than a word. The tool is stating that
    # the run is waiting; the text reader makes '' of an object, which is what an absent key also
    # makes, so a reader testing the value reports this waiting run as not waiting.
    $script:AwaitingObjectRun = @'
run:
  id: 01M4AWAITINGOBJECT000000000
  branch: feature-x
  status: running
  awaiting_agent:
    since: 12m
    reason: review
  head: abc1234d
'@

    # `steps[2]: intent,review` - a valid TOON list of two strings where a table of rows belongs.
    $script:ScalarStepsRun = @'
run:
  id: 01M4SCALARSTEPS00000000000
  branch: feature-x
  status: running
  steps[2]: intent,review
'@

    # The same shape in the other list, with a real `steps` table beside it so the guard is shown
    # to be per table rather than a whole-run refusal.
    $script:ScalarActiveStepsRun = @'
run:
  id: 01M4SCALARACTIVE0000000000
  branch: feature-x
  status: running
  steps[2]{step,status,findings,duration_ms}:
    intent,completed,0,7
    review,running,0,4200
  active_steps[2]: review,test
'@

    # A run whose `steps[]` header declares nine rows and carries one. This is what a truncated
    # capture looks like, and reading it as a one-step run is the failure strict decoding prevents.
    $script:TruncatedRun = @'
run:
  id: "01M3TRUNCATED00000000000000"
  branch: feature-x
  status: running
  steps[9]{step,status,findings,duration_ms}:
    intent,completed,0,6
'@

    $script:NodePath = (Get-Command 'node' -CommandType Application |
                        Where-Object { $_.Source -like '*.exe' } |
                        Select-Object -First 1).Source

    # Two stand-ins for the gate binary, because the launch branches cannot be forced any other
    # way: one that never answers, and one that prints back the arguments it was actually handed.
    # They live under a directory whose name holds a space, so every launch through them also
    # exercises the quoting the arguments depend on.
    $script:ShimRoot = Join-Path ([System.IO.Path]::GetTempPath()) `
                                 ("gate shims $([guid]::NewGuid().ToString('N'))")
    New-Item -ItemType Directory -Path $script:ShimRoot -Force | Out-Null

    $script:SlowShim = Join-Path $script:ShimRoot 'axi slow.cmd'
    Set-Content -LiteralPath $script:SlowShim -Encoding ascii `
        -Value @('@echo off', 'ping -n 31 127.0.0.1 >nul')

    # `axi status --run <value>` puts the run id in the fourth argument, so `%~4` is the value as
    # the binary really received it. A joined command line splits it and this prints the fragment.
    $script:ArgvEchoShim = Join-Path $script:ShimRoot 'axi echo.cmd'
    Set-Content -LiteralPath $script:ArgvEchoShim -Encoding ascii `
        -Value @('@echo off', 'echo error: "the run asked for was [%~4]"')

    # Two shapes the launcher returns, and nothing invented: the binary ran, or it did not.
    function New-AxiRan {
        param([string]$Value = '', [int]$ExitCode = 0, [string]$ErrorText = '')
        [pscustomobject]@{
            ok = $true; value = $Value; errorText = $ErrorText; exitCode = $ExitCode; error = ''
        }
    }
    function New-AxiFailed {
        param([string]$Error = 'no-mistakes was not found.')
        [pscustomobject]@{
            ok = $false; value = ''; errorText = ''; exitCode = $null; error = $Error
        }
    }
}

AfterAll {
    Remove-Item -LiteralPath $script:ShimRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Reading a completed run' {
    It 'reports the run, its branch, its head and its pull request from the fields that carry them' {
        $s = ConvertFrom-GateRunOutput -Text $script:CompletedRun

        $s.status    | Should -Be 'has-run'
        $s.runId     | Should -Be '01M3B8FPAF2P3Y52THCFCX4TX6'
        $s.branch    | Should -Be 'worktree-kh-away-journal'
        $s.head      | Should -Be '9845e8fa'
        $s.pr        | Should -Be 'https://github.com/emgee-labs/kingshand/pull/34'
        $s.runStatus | Should -Be 'completed'
        $s.outcome   | Should -Be 'passed'
    }

    It 'gives every step its own status rather than one status for the run' {
        $s = ConvertFrom-GateRunOutput -Text $script:CompletedRun

        $s.steps.Count | Should -Be 9
        ($s.steps | Where-Object { $_.step -eq 'ci' }).status     | Should -Be 'skipped'
        ($s.steps | Where-Object { $_.step -eq 'review' }).status | Should -Be 'completed'
        ($s.steps | Where-Object { $_.step -eq 'push' }).status   | Should -Be 'completed'
    }

    It 'keeps a step duration of zero as zero rather than losing it' {
        # The skipped `ci` step really did take no time. Reading that as "not reported" would make
        # a step nobody ran indistinguishable from one whose duration could not be read.
        $ci = (ConvertFrom-GateRunOutput -Text $script:CompletedRun).steps |
              Where-Object { $_.step -eq 'ci' }

        $ci.durationMs | Should -Be 0
        $ci.durationMs | Should -Not -BeNullOrEmpty -Because '0 is a reading, and $null would not be'
    }

    It 'reports a finished run as not parked' {
        (ConvertFrom-GateRunOutput -Text $script:CompletedRun).isParked | Should -BeFalse
    }
}

Describe 'Trap 1 - a residual finding count never means something is waiting' {
    # Forced with the document that produced the wrong answer: a cancelled run whose summary still
    # says "1 awaiting".

    It 'carries the residual summary through without turning it into a waiting run' {
        $s = ConvertFrom-GateRunOutput -Text $script:CancelledRunWithResidualCount

        $s.findingsSummary | Should -Be '1 awaiting, 1 auto-fix' -Because 'the tool did say it'
        $s.isParked        | Should -BeFalse -Because 'nothing is waiting on a cancelled run'
        $s.parkedOn        | Should -BeNullOrEmpty
        $s.runStatus       | Should -Be 'cancelled'
        $s.outcome         | Should -Be 'cancelled'
    }

    It 'lists no findings to decide on, however many the summary counts' {
        # `run.findings` is a summary string, not a findings table. Reading a findings list out of
        # it is the same inference in a different costume.
        (ConvertFrom-GateRunOutput -Text $script:CancelledRunWithResidualCount).findings.Count |
            Should -Be 0
    }

    It 'never says the run is waiting anywhere in the line a person reads' {
        $detail = (ConvertFrom-GateRunOutput -Text $script:CancelledRunWithResidualCount).detail

        $detail | Should -Not -Match 'parked'
        $detail | Should -Not -Match 'waiting'
    }

    It 'reports a parked run as parked from the field that says so, not from its count' {
        # The same residual-looking summary - "3 awaiting" - on a run that genuinely is parked.
        # What changes the answer is `awaiting_agent`, and only that.
        $s = ConvertFrom-GateRunOutput -Text $script:ParkedRun

        $s.findingsSummary | Should -Be '3 awaiting'
        $s.awaitingAgent   | Should -Be 'parked 12m'
        $s.isParked        | Should -BeTrue
    }
}

Describe 'Trap 2 - steps and active steps stay two lists' {
    # Forced with the document that merges: both lists present, sharing the step name `review`.

    It 'keeps each list at its own length' {
        $s = ConvertFrom-GateRunOutput -Text $script:ParkedRun

        $s.steps.Count       | Should -Be 5
        $s.activeSteps.Count | Should -Be 1
    }

    It 'leaves the step list with exactly one row per pipeline step' {
        $s = ConvertFrom-GateRunOutput -Text $script:ParkedRun

        @($s.steps | Where-Object { $_.step -eq 'review' }).Count |
            Should -Be 1 -Because 'a merged list would carry review twice'
        @($s.steps).step | Should -Be @('intent', 'rebase', 'review', 'test', 'push')
    }

    It 'gives the two lists their own columns rather than one composite shape' {
        $s = ConvertFrom-GateRunOutput -Text $script:ParkedRun
        $step   = $s.steps       | Where-Object { $_.step -eq 'review' }
        $active = $s.activeSteps | Select-Object -First 1

        $step.status       | Should -Be 'awaiting'
        $step.durationMs   | Should -Be 742000
        $active.step       | Should -Be 'review'
        $active.activeFor  | Should -Be '12m30s'
        $active.round      | Should -Be 'fix 2'
        $active.agentPid   | Should -Be 48122

        $step.PSObject.Properties.Name   | Should -Not -Contain 'round'
        $active.PSObject.Properties.Name | Should -Not -Contain 'durationMs'
    }

    It 'reports no active steps on a run that has none, rather than one blank one' {
        # The completed run carries no `active_steps` block at all. An absent list that arrives as
        # a single empty row is a step that does not exist, and a caller would act on it.
        (ConvertFrom-GateRunOutput -Text $script:CompletedRun).activeSteps.Count | Should -Be 0
    }
}

Describe 'Trap 3 - the help block never becomes state' {
    # Forced with a document whose help text contains every word a naive match looks for.

    It 'reports no outcome for a document that only mentions one in its help text' {
        $s = ConvertFrom-GateRunOutput -Text $script:GateResponse

        # The words really are in the document, or this case would prove nothing.
        ($s.help -join ' ') | Should -Match 'outcome:'
        ($s.help -join ' ') | Should -Match 'approve'
        ($s.help -join ' ') | Should -Match 'push'

        $s.outcome | Should -BeNullOrEmpty -Because 'this run has not ended'
    }

    It 'keeps the help lines as help rather than as steps or findings' {
        $s = ConvertFrom-GateRunOutput -Text $script:GateResponse

        $s.help.Count  | Should -Be 6
        $s.steps.Count | Should -Be 0
        # Two findings, from the findings table - not six, from the help list.
        $s.findings.Count | Should -Be 2
    }

    It 'does not take a run status from help text that names one' {
        (ConvertFrom-GateRunOutput -Text $script:GateResponse).runStatus | Should -BeNullOrEmpty
    }
}

Describe 'Reading a gate response' {
    It 'names the step the pipeline is parked at' {
        $s = ConvertFrom-GateRunOutput -Text $script:GateResponse

        $s.gate     | Should -Be 'review'
        $s.isParked | Should -BeTrue
        $s.parkedOn | Should -Be 'review'
    }

    It 'reports each finding with its own id, severity and action' {
        $f = (ConvertFrom-GateRunOutput -Text $script:GateResponse).findings

        $f.Count      | Should -Be 2
        $f[0].id      | Should -Be 'r1'
        $f[0].severity| Should -Be 'warning'
        $f[0].action  | Should -Be 'auto-fix'
        $f[1].id      | Should -Be 'r2'
        $f[1].severity| Should -Be 'error'
        $f[1].action  | Should -Be 'ask-user'
    }

    It 'returns a description carrying commas, colons, quotes and backslashes exactly as written' {
        # This is the case that decides the whole design. TOON escapes a quote as \" and a
        # backslash as \\, which is not CSV's doubled quote, so a hand-rolled split would cut this
        # description at its first comma and mangle the rest.
        $f = (ConvertFrom-GateRunOutput -Text $script:GateResponse).findings

        $f[1].description | Should -BeExactly $script:NastyDescription
    }

    It 'says plainly that a gate response carries no run object' {
        $s = ConvertFrom-GateRunOutput -Text $script:GateResponse

        $s.status | Should -Be 'no-run'
        $s.signal | Should -Be 'gate-response'
        $s.runId  | Should -BeNullOrEmpty
        $s.detail | Should -Match 'parked at its review step'
    }
}

Describe 'Reading a gate that arrives as an object rather than a step name' {
    # Forced with the capture that broke the documented reading. This is the live tool's shape and
    # the documentation's shape is the other one, so both cases have to pass together.

    It 'names the step from the gate object rather than coming back empty' {
        $s = ConvertFrom-GateRunOutput -Text $script:GateObjectResponse

        $s.gate     | Should -Be 'review'
        $s.parkedOn | Should -Be 'review'
        $s.isParked | Should -BeTrue
    }

    It 'finds every finding inside the gate object, where a top-level look finds none' {
        $f = (ConvertFrom-GateRunOutput -Text $script:GateObjectResponse).findings

        $f.Count | Should -Be 6 -Because 'the response really does carry six to decide on'
        @($f).id | Should -Be @('gr-argv-space', 'gr-claudemd-row', 'gr-design-note',
                                'gr-awaiting-unrecognised', 'gr-temp-count-flaky',
                                'gr-branch-guard-gate')
        @($f).action | Should -Be @('auto-fix', 'ask-user', 'ask-user',
                                    'ask-user', 'auto-fix', 'no-op')
    }

    It 'carries the gate''s own status, risk and note' {
        $s = ConvertFrom-GateRunOutput -Text $script:GateObjectResponse

        $s.gateStatus | Should -Be 'awaiting_approval'
        $s.gateRisk   | Should -Be 'medium'
        $s.gateNote   | Should -Match 'Review auto-fix is disabled by default'
    }

    It 'reports the run beside the gate rather than losing one to the other' {
        $s = ConvertFrom-GateRunOutput -Text $script:GateObjectResponse

        $s.status     | Should -Be 'has-run'
        $s.runId      | Should -Be '01M3BE8203JPV572AVT9832923'
        $s.branch     | Should -Be 'worktree-kh-gate-state-read-helper'
        $s.steps.Count| Should -Be 9
        ($s.steps | Where-Object { $_.step -eq 'review' }).status | Should -Be 'awaiting_approval'
        $s.detail     | Should -Match 'parked at its review step'
    }

    It 'still reads the documented scalar shape, which is not dropped for the live one' {
        # Both shapes, side by side in one case, because a version may emit either and fixing the
        # live one by replacing the documented one would only move the failure.
        (ConvertFrom-GateRunOutput -Text $script:GateResponse).parkedOn       | Should -Be 'review'
        (ConvertFrom-GateRunOutput -Text $script:GateObjectResponse).parkedOn | Should -Be 'review'
    }

    It 'reads a gate key in a shape it does not recognise as a gate all the same' {
        # The third shape, forced. `gate:` has already changed shape once, so a reader that
        # decides the park from whichever shapes it happens to handle will one day meet one it
        # does not and report no gate at all - which is what a list does here. The key being
        # there is the tool saying the pipeline is waiting, whatever its value turned out to be.
        $s = ConvertFrom-GateRunOutput -Text "gate[2]: review,test`n"

        $s.isParked | Should -BeTrue -Because 'the tool did say there was a gate'
        $s.parkedOn | Should -BeNullOrEmpty -Because 'nothing readable named a step'
        $s.signal   | Should -Be 'gate-response'
        $s.detail   | Should -Match 'a list of 2 item'
        $s.detail   | Should -Match 'does not recognise'
    }

    It 'names an empty gate value rather than letting it read as no gate' {
        $s = ConvertFrom-GateRunOutput -Text "gate: `"`"`n"

        $s.isParked | Should -BeTrue
        $s.signal   | Should -Be 'gate-response'
        $s.detail   | Should -Match 'an empty string'
    }

    It 'says the gate shape was unrecognised on a run answer too, not only on a gate response' {
        # The same document with a run beside it takes the other detail branch entirely, and the
        # unrecognised shape has to be named on both or it is silent on whichever one is missed.
        $s = ConvertFrom-GateRunOutput -Text (
            "run:`n  id: 01M4GATESHAPE0000000000000`n  branch: feature-x`n" +
            "  status: running`ngate[2]: review,test`n")

        $s.status   | Should -Be 'has-run'
        $s.isParked | Should -BeTrue
        $s.detail   | Should -Match 'a list of 2 item'
        $s.detail   | Should -Match 'does not recognise'
    }

    It 'says a run field it could not take is not the tool reporting no run' {
        # `run:` holding something that is not an object. Answering "answered without reporting a
        # run" would be a wrong word about the one thing the caller asked after.
        $s = ConvertFrom-GateRunOutput -Text "run[2]: one,two`n"

        $s.status | Should -Be 'no-run'
        $s.detail | Should -Match 'could not take'
        $s.detail | Should -Match 'run field'
        $s.detail | Should -Not -Match 'without reporting a run'
    }

    It 'reads a gate object that names no step as a gate all the same' {
        # The park comes from the gate being there, not from its step name being readable. A gate
        # whose step this could not read is still the tool saying the pipeline is waiting.
        $s = ConvertFrom-GateRunOutput -Text "gate:`n  status: awaiting_approval`n"

        $s.isParked | Should -BeTrue
        $s.gate     | Should -BeNullOrEmpty -Because 'the output did not name a step'
        $s.signal   | Should -Be 'gate-response'
        $s.detail   | Should -Match 'did not name'
    }
}

Describe 'An awaiting_agent value this reader does not recognise still means waiting' {
    # The failure this whole module exists for, in the one direction that looks safe: a watch
    # condition that could not see a park reported none, and a parked run sat for two hours and
    # twenty-six minutes. A wording the reader has not seen must never read as not waiting.

    It 'reports the run as parked from the presence of the field, not from its wording' {
        $s = ConvertFrom-GateRunOutput -Text $script:UnrecognisedAwaitingRun

        $s.isParked      | Should -BeTrue
        $s.awaitingAgent | Should -Be 'awaiting review decision' -Because 'the raw value is kept'
    }

    It 'names the tool''s own word and says it was not recognised' {
        $detail = (ConvertFrom-GateRunOutput -Text $script:UnrecognisedAwaitingRun).detail

        $detail | Should -Match 'waiting'
        $detail | Should -Match 'awaiting review decision'
        $detail | Should -Match 'does not recognise'
    }

    It 'invents no state word for it' {
        $s = ConvertFrom-GateRunOutput -Text $script:UnrecognisedAwaitingRun

        $s.status    | Should -Be 'has-run'
        $s.parkedOn  | Should -BeNullOrEmpty -Because 'nothing in this output names a gate step'
        $s.outcome   | Should -BeNullOrEmpty
        $s.detail    | Should -Not -Match 'parked'
    }

    It 'leaves the recognised parked wording reading as an ordinary park' {
        $s = ConvertFrom-GateRunOutput -Text $script:ParkedRun

        $s.isParked | Should -BeTrue
        $s.detail   | Should -Match 'It is parked'
        $s.detail   | Should -Not -Match 'does not recognise'
    }

    It 'leaves a run carrying no awaiting_agent at all reading as not waiting' {
        $s = ConvertFrom-GateRunOutput -Text $script:CompletedRun

        $s.isParked | Should -BeFalse
        $s.detail   | Should -Not -Match 'waiting'
    }

    It 'reads an awaiting_agent carrying an object as waiting, not as absent' {
        # The same rule as the gate key, in the sibling field, forced with the shape that broke
        # it: an object comes back from the text reader as the identical '' an absent key does,
        # so a reader testing the value reports a waiting run as not waiting and says nothing.
        $s = ConvertFrom-GateRunOutput -Text $script:AwaitingObjectRun

        $s.isParked | Should -BeTrue -Because 'the tool did say the run was waiting on the agent'
        $s.status   | Should -Be 'has-run'
        $s.detail   | Should -Match 'awaiting_agent'
        $s.detail   | Should -Match 'an object'
        $s.detail   | Should -Match 'does not recognise'
    }
}

Describe 'A declared table whose entries are not rows never becomes state' {
    # `steps[2]: intent,review` is valid TOON - a list of two strings, not two rows of fields.
    # Read row by row it yields steps whose every column is empty, which is a run described in a
    # shape nobody sent. Both lists are forced, because a guard on one is a guard on one.

    It 'reports no steps and says the steps table could not be read' {
        $s = ConvertFrom-GateRunOutput -Text $script:ScalarStepsRun

        $s.steps.Count | Should -Be 0 -Because 'two blank steps would be a run nobody reported'
        $s.status      | Should -Be 'has-run'
        $s.detail      | Should -Match 'steps table'
        $s.detail      | Should -Match 'does not recognise'
    }

    It 'reports no active steps and says the active_steps table could not be read' {
        $s = ConvertFrom-GateRunOutput -Text $script:ScalarActiveStepsRun

        $s.activeSteps.Count | Should -Be 0
        $s.steps.Count       | Should -Be 2 -Because 'the real table beside it still reads'
        $s.detail            | Should -Match 'active_steps table'
        $s.detail            | Should -Match 'does not recognise'
    }

    It 'still reads a table whose entries really are rows' {
        $s = ConvertFrom-GateRunOutput -Text $script:CompletedRun

        $s.steps.Count | Should -Be 9
        $s.detail      | Should -Not -Match 'does not recognise'
    }
}

Describe 'Reading an answer that reports no run' {
    It 'reports no run and carries the tool''s own message verbatim' {
        $s = ConvertFrom-GateRunOutput -Text $script:RunNotFound -ExitCode 1

        $s.status | Should -Be 'no-run'
        $s.signal | Should -Be 'no-run-reported'
        $s.error  | Should -Be 'run "NOPE-NOT-A-RUN" not found'
        $s.detail | Should -Match 'not found'
    }

    It 'invents no state word for it' {
        $s = ConvertFrom-GateRunOutput -Text $script:RunNotFound -ExitCode 1

        $s.runStatus | Should -BeNullOrEmpty
        $s.outcome   | Should -BeNullOrEmpty
        $s.isParked  | Should -BeFalse
        $s.steps.Count | Should -Be 0
    }
}

Describe 'An output that cannot be read returns no state' {
    It 'reads silence as unreadable rather than as an empty run' {
        $s = ConvertFrom-GateRunOutput -Text ''

        $s.status  | Should -Be 'unreadable'
        $s.signal  | Should -Be 'no-output'
        $s.detail  | Should -Match 'Silence is not an empty run'
        $s.runId   | Should -BeNullOrEmpty
        $s.outcome | Should -BeNullOrEmpty
    }

    It 'reads text that is not TOON as unreadable and names the failure' {
        $s = ConvertFrom-GateRunOutput -Text "panic: runtime error`n`tgoroutine 1 [running]:`n  : :"

        $s.status | Should -Be 'unreadable'
        $s.signal | Should -Be 'undecodable-output'
        $s.detail | Should -Not -BeNullOrEmpty
        $s.steps.Count | Should -Be 0
    }

    It 'refuses a truncated table rather than reporting the rows that arrived' {
        # The header declares nine steps and one is present. Strict decoding is what turns that
        # into a refusal; a reader that took what it found would report a run one step into its
        # pipeline, which is a different run from the one that exists.
        $s = ConvertFrom-GateRunOutput -Text $script:TruncatedRun

        $s.status      | Should -Be 'unreadable'
        $s.signal      | Should -Be 'undecodable-output'
        $s.steps.Count | Should -Be 0
        $s.runId       | Should -BeNullOrEmpty -Because 'no part of an unreadable document is state'
    }

    It 'refuses a document that decodes but is not a gate response' {
        # TOON decodes a lone primitive. It is readable text that says nothing this recognises,
        # and reporting it as a run with every field empty is the empty run this refuses.
        $s = ConvertFrom-GateRunOutput -Text 'hello'

        $s.status | Should -Be 'unreadable'
        $s.signal | Should -Be 'not-a-gate-response'
    }

    It 'says node is missing rather than guessing at the output' {
        Mock -ModuleName GateRun Get-NodeCommandPath { $null }

        $s = ConvertFrom-GateRunOutput -Text $script:CompletedRun

        $s.status | Should -Be 'unreadable'
        $s.signal | Should -Be 'undecodable-output'
        $s.detail | Should -Match 'node was not found'
        $s.runId  | Should -BeNullOrEmpty
    }

    It 'says the decoder is missing rather than guessing at the output' {
        Mock -ModuleName GateRun Get-ToonDecoderPath { $null }

        $s = ConvertFrom-GateRunOutput -Text $script:CompletedRun

        $s.status | Should -Be 'unreadable'
        $s.signal | Should -Be 'undecodable-output'
        $s.detail | Should -Match 'decoder was not found'
    }
}

Describe 'Asking the gate itself' {
    It 'reports the run when the binary answers with one' {
        Mock -ModuleName GateRun Invoke-NoMistakesAxi { New-AxiRan -Value $script:CompletedRun }

        $s = Get-GateRunState

        $s.status | Should -Be 'has-run'
        $s.runId  | Should -Be '01M3B8FPAF2P3Y52THCFCX4TX6'
    }

    It 'asks about the active run by default and about one run when named' {
        # Both parameter defaults are fired here: no -Run means the tool's own default of the
        # active or most recent run, and no -RepoPath means the current directory.
        $script:SeenArguments = $null
        $script:SeenRepoPath  = 'unset'
        Mock -ModuleName GateRun Invoke-NoMistakesAxi {
            $script:SeenArguments = $Arguments
            $script:SeenRepoPath  = $RepoPath
            New-AxiRan -Value $script:CompletedRun
        }

        $null = Get-GateRunState
        $script:SeenArguments | Should -Be @('axi', 'status')
        $script:SeenRepoPath  | Should -Be ''

        $null = Get-GateRunState -Run '01M3B8FPAF2P3Y52THCFCX4TX6'
        $script:SeenArguments | Should -Be @('axi', 'status', '--run', '01M3B8FPAF2P3Y52THCFCX4TX6')
    }

    It 'never passes a flag that would drive the run' {
        $script:SeenArguments = $null
        Mock -ModuleName GateRun Invoke-NoMistakesAxi {
            $script:SeenArguments = $Arguments
            New-AxiRan -Value $script:CompletedRun
        }

        $null = Get-GateRunState -Run 'anything'

        foreach ($forbidden in @('run', 'respond', 'abort', 'sync', '--yes', '--action')) {
            $script:SeenArguments | Should -Not -Contain $forbidden
        }
    }

    It 'reads the run from a non-zero exit rather than refusing on the exit code' {
        # The tool exits 1 on a failed or cancelled outcome and still prints the whole run.
        # Refusing on the code would throw away the state it was asked for.
        Mock -ModuleName GateRun Invoke-NoMistakesAxi {
            New-AxiRan -Value $script:CancelledRunWithResidualCount -ExitCode 1
        }

        $s = Get-GateRunState

        $s.status    | Should -Be 'has-run'
        $s.runStatus | Should -Be 'cancelled'
        $s.exitCode  | Should -Be 1
    }

    It 'returns no state at all when the binary could not be run' {
        Mock -ModuleName GateRun Invoke-NoMistakesAxi { New-AxiFailed -Error 'no-mistakes was not found.' }

        $s = Get-GateRunState

        $s.status      | Should -Be 'unreadable'
        $s.signal      | Should -Be 'lookup-failed'
        $s.detail      | Should -Match 'no-mistakes was not found'
        $s.runId       | Should -BeNullOrEmpty
        $s.runStatus   | Should -BeNullOrEmpty
        $s.outcome     | Should -BeNullOrEmpty
        $s.isParked    | Should -BeFalse
        $s.steps.Count | Should -Be 0
    }

    It 'says what the tool put on stderr when there was no state to read' {
        Mock -ModuleName GateRun Invoke-NoMistakesAxi {
            New-AxiRan -Value '' -ExitCode 2 -ErrorText 'unknown flag: --nope'
        }

        $s = Get-GateRunState

        $s.status | Should -Be 'unreadable'
        $s.detail | Should -Match 'unknown flag: --nope'
    }

    It 'refuses a run on another branch rather than reporting it as this branch''s state' {
        # The trap this guard exists for, forced: asking with no run id returns the most recent run
        # in the repository. docs\2026-09-01-stall-detection.md records a watcher started before
        # its own run had registered reading a different, already completed run and reporting
        # success immediately - which is exactly this fixture, a passed run on another branch.
        Mock -ModuleName GateRun Invoke-NoMistakesAxi { New-AxiRan -Value $script:CompletedRun }

        $s = Get-GateRunState -Branch 'feature-x'

        $s.status  | Should -Be 'no-run'
        $s.signal  | Should -Be 'wrong-branch'
        $s.detail  | Should -Match 'worktree-kh-away-journal'
        $s.detail  | Should -Match 'feature-x'
        $s.outcome | Should -BeNullOrEmpty -Because 'the other run''s passed outcome is not this branch''s'
        $s.runId   | Should -BeNullOrEmpty
        $s.steps.Count | Should -Be 0
    }

    It 'returns the run when the branch asked for is the one that answered' {
        Mock -ModuleName GateRun Invoke-NoMistakesAxi { New-AxiRan -Value $script:CompletedRun }

        $s = Get-GateRunState -Branch 'worktree-kh-away-journal'

        $s.status  | Should -Be 'has-run'
        $s.outcome | Should -Be 'passed'
    }

    It 'checks no branch when none is asked for' {
        # The parameter's default, fired by the ordinary call path: a caller standing in a
        # repository asking what is going on at all gets whatever the tool reports.
        Mock -ModuleName GateRun Invoke-NoMistakesAxi { New-AxiRan -Value $script:CompletedRun }

        (Get-GateRunState).status | Should -Be 'has-run'
    }

    It 'keeps stderr out of a reading that succeeded' {
        # The tool prints an update notice on stderr on every single call. Folding that into a
        # good reading would put a version notice in front of a person asking about their run.
        Mock -ModuleName GateRun Invoke-NoMistakesAxi {
            New-AxiRan -Value $script:CompletedRun -ErrorText 'A new version of no-mistakes is available'
        }

        (Get-GateRunState).detail | Should -Not -Match 'new version'
    }
}

Describe 'The boundary to the binary' {
    # Driven through Get-GateRunState, which is the only way into this module. The helper that
    # actually launches the binary is not exported - it takes free-form arguments, and exporting
    # it would make the module's no-drive claim true only of the path the module itself takes -
    # so these force each of its failures from outside rather than by reaching past the exports.

    It 'reports a missing binary rather than throwing' {
        Mock -ModuleName GateRun Get-NoMistakesCommandPath { $null }

        $s = Get-GateRunState

        $s.status | Should -Be 'unreadable'
        $s.signal | Should -Be 'lookup-failed'
        $s.detail | Should -Match 'no-mistakes was not found'
        $s.runId  | Should -BeNullOrEmpty
    }

    It 'reports a repository path that is not there rather than asking about somewhere else' {
        # A real binary is found, so the refusal is the missing directory and not the missing
        # tool - which is the branch in question.
        Mock -ModuleName GateRun Get-NoMistakesCommandPath { $script:NodePath }
        $missing = Join-Path ([System.IO.Path]::GetTempPath()) `
                             ('gate-run-' + [guid]::NewGuid().ToString('N'))

        $s = Get-GateRunState -RepoPath $missing

        $s.status | Should -Be 'unreadable'
        $s.signal | Should -Be 'lookup-failed'
        $s.detail | Should -Match 'no directory at'
    }

    It 'stops a binary that does not answer and says so' {
        # Forced with a real process that will not return inside the timeout. This is the branch
        # the default timeout guards, and the only way to fire it is to make something hang.
        Mock -ModuleName GateRun Get-NoMistakesCommandPath { $script:SlowShim }

        $s = Get-GateRunState -TimeoutSeconds 2

        $s.status  | Should -Be 'unreadable'
        $s.signal  | Should -Be 'lookup-failed'
        $s.detail  | Should -Match 'did not answer within 2 seconds'
        $s.runId   | Should -BeNullOrEmpty
        $s.isParked| Should -BeFalse
    }

    It 'does not export the helper that could drive a run' {
        # The module's header claims no flag that responds, approves, aborts or starts anything is
        # ever passed. That claim is only enforceable if the free-form launcher is unreachable, so
        # the export list is the thing under test: reaching it would be the way to drive the gate.
        $reachable = @(Get-Command -Module GateRun | ForEach-Object { $_.Name })

        $reachable | Should -Not -Contain 'Invoke-NoMistakesAxi'
        $reachable | Should -Not -Contain 'Start-CapturedProcess'
        $reachable | Should -Contain 'Get-GateRunState' -Because 'reading is what it is for'
    }
}

Describe 'Naming a shape and an exit code without inventing either' {
    It 'gives a non-empty string an honest label rather than calling it empty' {
        # The shape namer is reached inside the module only where the text reader already came
        # back empty, so a wrong label for other values would never show there - and would still
        # be a wrong word coming out of a module whose product is never saying one.
        Get-ToonShapeName -Value 'review' | Should -Be 'text'
        Get-ToonShapeName -Value '   '    | Should -Be 'an empty string'
        Get-ToonShapeName -Value ''       | Should -Be 'an empty string'
        Get-ToonShapeName -Value $null    | Should -Be 'nothing at all'
    }

    It 'keeps a negative exit code rather than reading it as none reported' {
        # A crashed child on Windows exits negative - an access violation arrives as
        # -1073741819 - so a numeric sentinel for "not supplied" would record a real reading as
        # $null, which is what every other field here means by "the output did not say".
        $s = ConvertFrom-GateRunOutput -Text $script:CompletedRun -ExitCode -1073741819

        $s.exitCode | Should -Be -1073741819
        $s.exitCode | Should -Not -BeNullOrEmpty
    }

    It 'reports no exit code at all when none was supplied' {
        (ConvertFrom-GateRunOutput -Text $script:CompletedRun).exitCode | Should -BeNullOrEmpty
    }
}

Describe 'Decoding one document' {
    It 'hands back JSON for a document the reference implementation accepts' {
        $r = ConvertFrom-ToonText -Text $script:CompletedRun

        $r.ok | Should -BeTrue
        ($r.value | ConvertFrom-Json).run.id | Should -Be '01M3B8FPAF2P3Y52THCFCX4TX6'
    }

    It 'carries the decoded JSON on the state so a caller never has to read TOON either' {
        $s = ConvertFrom-GateRunOutput -Text $script:CompletedRun

        $s.json | Should -Not -BeNullOrEmpty
        ($s.json | ConvertFrom-Json).outcome | Should -Be 'passed'
    }

    It 'fails rather than returning half a document' {
        $r = ConvertFrom-ToonText -Text $script:TruncatedRun

        $r.ok    | Should -BeFalse
        $r.value | Should -BeNullOrEmpty
        $r.error | Should -Not -BeNullOrEmpty
    }
}

Describe 'Launching a child process with paths that hold a space' {
    # Every path this module launches with comes from %TEMP% or from beside the module itself, and
    # both hold a space the moment an account name or an install directory does - `C:\Users\Ann
    # Lee\AppData\Local\Temp\` is an ordinary Windows profile. Joining the arguments into one
    # string splits each of those in half, and every decode on that machine fails for good.

    BeforeAll {
        $script:SpacedRoot = Join-Path ([System.IO.Path]::GetTempPath()) `
                                       ("gate run $([guid]::NewGuid().ToString('N'))")
        $script:SpacedAssets = Join-Path $script:SpacedRoot 'toon decoder'
        $script:SpacedTemp   = Join-Path $script:SpacedRoot 'temp dir'
        New-Item -ItemType Directory -Path $script:SpacedAssets -Force | Out-Null
        New-Item -ItemType Directory -Path $script:SpacedTemp   -Force | Out-Null
        foreach ($f in @('decode.mjs', 'toon.mjs')) {
            Copy-Item -LiteralPath "$PSScriptRoot\..\bin\assets\toon\$f" `
                      -Destination $script:SpacedAssets
        }
        $script:SpacedDecoder = Join-Path $script:SpacedAssets 'decode.mjs'
    }

    AfterAll {
        Remove-Item -LiteralPath $script:SpacedRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'decodes when the decoder and the document both sit under a path with a space' {
        Mock -ModuleName GateRun Get-ToonDecoderPath { $script:SpacedDecoder }

        $oldTmp  = $env:TMP
        $oldTemp = $env:TEMP
        try {
            # GetTempFileName follows these, so the document this writes lands under a directory
            # whose name has a space in it - which is the whole point of the case.
            $env:TMP  = $script:SpacedTemp
            $env:TEMP = $script:SpacedTemp

            $s = ConvertFrom-GateRunOutput -Text $script:CompletedRun
        } finally {
            $env:TMP  = $oldTmp
            $env:TEMP = $oldTemp
        }

        $s.status | Should -Be 'has-run'
        $s.runId  | Should -Be '01M3B8FPAF2P3Y52THCFCX4TX6'
        $s.detail | Should -Not -Match 'could not be decoded'
    }

    It 'keeps a run id holding a space as one argument to the binary' {
        # The same joining on the other launch, where it splits a `--run` value rather than a
        # path. The stand-in binary prints back the run id it was really handed, so a joined
        # command line shows up as the first fragment of the value rather than the whole of it.
        Mock -ModuleName GateRun Get-NoMistakesCommandPath { $script:ArgvEchoShim }

        $s = Get-GateRunState -Run 'a run with spaces'

        $s.error | Should -Be 'the run asked for was [a run with spaces]' `
            -Because 'a joined command line would arrive split at each space'
    }
}

Describe 'What this module writes' {
    It 'leaves nothing behind in the temp directory' {
        # This reader writes no durable file anywhere - it has no state to keep. The only path it
        # opens at all is a unique temp file the operating system creates for it, and it is
        # deleted on every path out, including the failing ones.
        #
        # The temp directory is a private one for the duration rather than the shared one.
        # Counting files in the shared directory goes red whenever any other process on the
        # machine happens to write one while this runs, which is a failure about somebody else's
        # work - and a private directory lets this assert nothing at all is left, rather than
        # merely that the total did not grow.
        $private = Join-Path ([System.IO.Path]::GetTempPath()) `
                             ('gate-run-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $private -Force | Out-Null

        $oldTmp  = $env:TMP
        $oldTemp = $env:TEMP
        try {
            $env:TMP  = $private
            $env:TEMP = $private

            $null = ConvertFrom-GateRunOutput -Text $script:CompletedRun
            $null = ConvertFrom-GateRunOutput -Text $script:TruncatedRun
            $null = ConvertFrom-GateRunOutput -Text 'hello'

            @(Get-ChildItem -LiteralPath $private -Force -Recurse).Count | Should -Be 0
        } finally {
            $env:TMP  = $oldTmp
            $env:TEMP = $oldTemp
            Remove-Item -LiteralPath $private -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
