#Requires -Version 7.0
Set-StrictMode -Version Latest

# bin\Watch.psm1 and bin\Watch.ps1 are the Hand's four watches as short commands. What is pinned
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
              [bool]$Readable = $true, [string]$Box = '', [string]$Last = 'Wrote report.md',
              [bool]$Paste = $false, $Shells = 0)
        [pscustomobject]@{
            settled = ($Reason -eq 'settled'); state = $State; awaitingInput = $Awaiting
            stalled = ($Reason -eq 'stalled'); reason = $Reason; quietMinutes = 21.5
            waitedMinutes = 45.0; lastActivity = $Last; promptBox = $Box; pastePending = $Paste
            backgroundShells = $Shells; signalReadable = $Readable; samples = 3; stallMinutes = 20
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

    It 'reports a settle over text in the box as unsent, never as settled' {
        $l = Format-WorkerWake -Name 'T-1' -Wake (New-Wake -State 'done' -Box '[Pasted text #1 +12 lines]')
        Assert-OneLine $l
        $l | Should -BeLike "UNSENT T-1 state=done*'[[]Pasted text #1 +12 lines]'*not the worker's output*"
        $l | Should -BeLike '*re-arm this watch once*never submit or clear it*'
        $l | Should -Not -BeLike '*SETTLED*'
    }

    It 'reports a settle just after a paste went in as unsent, never as settled' {
        $l = Format-WorkerWake -Name 'T-1' -Wake (New-Wake -State 'done' -Paste $true)
        Assert-OneLine $l
        $l | Should -BeLike "UNSENT T-1 state=done*a paste went into its input box seconds ago*re-arm*"
        $l | Should -Not -BeLike '*SETTLED*'
    }

    It 'still reports a worker on a prompt as blocked when its box holds text' {
        (Format-WorkerWake -Name 'T-1' -Wake (New-Wake -Awaiting $true -Box 'x' -Paste $true)) |
            Should -BeLike 'BLOCKED T-1*'
    }

    It 'reports a settle with the worker''s own background shells running as waiting on them' {
        $l = Format-WorkerWake -Name 'T-1' -Wake (New-Wake -State 'done' -Shells 2)
        Assert-OneLine $l
        $l | Should -BeLike 'WAITING ON SHELL T-1 state=done*2 background shell(s)*not a finish*'
        $l | Should -Not -BeLike '*SETTLED*'
    }

    It 'reports a worker on a prompt as blocked even with a shell running' {
        (Format-WorkerWake -Name 'T-1' -Wake (New-Wake -Awaiting $true -Shells 1)) |
            Should -BeLike 'BLOCKED T-1*'
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

Describe 'A worker watch never reports settled over text the worker has not taken' {
    # End to end below the watch: the real progress wait and the real box reader, with only herdr's
    # answers replaced - the worker stopping, and the screen it stopped on. The screens are the
    # shapes sampled off a live worker while a long prompt went in.
    BeforeAll {
        $script:Rule = ([string][char]0x2500) * 92
        function New-Screen {
            param([string]$Box = '', [string]$Footer = '? for shortcuts')
            "  Done. Wrote report.md.`n`n$script:Rule`n`u{276F}`u{00A0}$Box`n$script:Rule`n    $Footer"
        }
    }

    BeforeEach {
        Mock -ModuleName Herdr Wait-HerdrAgent {
            [pscustomobject]@{ name = 't-1'; agent_status = 'done'; pane_id = 'p1' }
        }
    }

    It 'settles over an empty box' {
        $s = New-Screen
        Mock -ModuleName Herdr Read-HerdrAgentScreen { [pscustomobject]@{ ok = $true; text = $s } }.GetNewClosure()
        $l = Watch-Worker -Name 'T-1' -TimeoutMinutes 1
        Assert-OneLine $l
        $l | Should -BeLike 'SETTLED T-1 state=done*'
    }

    It 'does not settle over typed text in the box' {
        $s = New-Screen -Box 'half-typed reply'
        Mock -ModuleName Herdr Read-HerdrAgentScreen { [pscustomobject]@{ ok = $true; text = $s } }.GetNewClosure()
        $l = Watch-Worker -Name 'T-1' -TimeoutMinutes 1
        Assert-OneLine $l
        $l | Should -BeLike "UNSENT T-1*'half-typed reply'*"
    }

    It 'does not settle over a collapsed paste in the box' {
        $s = New-Screen -Box '[Pasted text #1 +12 lines]' -Footer 'paste again to expand'
        Mock -ModuleName Herdr Read-HerdrAgentScreen { [pscustomobject]@{ ok = $true; text = $s } }.GetNewClosure()
        $l = Watch-Worker -Name 'T-1' -TimeoutMinutes 1
        Assert-OneLine $l
        $l | Should -BeLike "UNSENT T-1*'[[]Pasted text #1 +12 lines]'*"
    }

    # The screen the watch woke on and called settled on 2026-10-23: the paste had just gone in,
    # the box had emptied, and the worker started on it seconds later.
    It 'does not settle in the moment after a paste went in, before the turn started' {
        $s = New-Screen -Footer 'paste again to expand'
        Mock -ModuleName Herdr Read-HerdrAgentScreen { [pscustomobject]@{ ok = $true; text = $s } }.GetNewClosure()
        $l = Watch-Worker -Name 'T-1' -TimeoutMinutes 1
        Assert-OneLine $l
        $l | Should -BeLike 'UNSENT T-1*a paste went into its input box seconds ago*'
    }

    It 'says it was blind rather than guessing at the box when the screen could not be read' {
        Mock -ModuleName Herdr Read-HerdrAgentScreen { [pscustomobject]@{ ok = $false; text = '' } }
        $l = Watch-Worker -Name 'T-1' -TimeoutMinutes 1
        $l | Should -BeLike '*watch was blind*'
        $l | Should -Not -BeLike 'UNSENT*'
    }
}

Describe 'A worker watch never reports settled while the worker waits on its own background shell' {
    # The real progress wait and the real footer reader again, with herdr's answers replaced. The
    # footer is the one copied off a live worker that had ended its turn with two shells running:
    # herdr read it `done` while its test run went on.
    BeforeAll {
        $script:Rule = ([string][char]0x2500) * 92
        function New-Screen {
            param([string]$Footer = '? for shortcuts')
            "  Running the suite in the background.`n`n$script:Rule`n`u{276F}`u{00A0}`n$script:Rule`n    $Footer"
        }
        $script:ShellFooter = "`u{23F8} manual mode on `u{00B7} 2 shells `u{00B7} `u{2193} to manage"
    }

    BeforeEach {
        Mock -ModuleName Herdr Wait-HerdrAgent {
            [pscustomobject]@{ name = 't-1'; agent_status = 'done'; pane_id = 'p1' }
        }
        Mock -ModuleName Watch Get-HerdrAgent {
            [pscustomobject]@{ name = 't-1'; agent_status = 'done'; pane_id = 'p1' }
        }
        Mock -ModuleName Watch Start-Sleep { }
    }

    It 'waits through the shell rather than settling, and settles once it has finished' {
        # The first wait's three reads show the shells - its first look, the prompt check and the
        # screen it stopped on - and the worker's own run is over by the next.
        $reads = [ref]0
        $busy = New-Screen -Footer $script:ShellFooter
        $done = New-Screen
        Mock -ModuleName Herdr Read-HerdrAgentScreen {
            $reads.Value++
            $t = if ($reads.Value -le 3) { $busy } else { $done }
            [pscustomobject]@{ ok = $true; text = $t }
        }.GetNewClosure()
        Mock -ModuleName Watch Get-HerdrAgentProgressSignal {
            [pscustomobject]@{ readable = $true; backgroundShells = 0 }
        }

        $l = Watch-Worker -Name 'T-1' -TimeoutMinutes 5
        Assert-OneLine $l
        $l | Should -BeLike 'SETTLED T-1 state=done*'
        Should -Invoke -ModuleName Watch Start-Sleep -Times 1 -Exactly
        Should -Invoke -ModuleName Herdr Wait-HerdrAgent -Times 2 -Exactly
    }

    It 'reports a worker still on its shell when the clock runs out as waiting on it, never settled' {
        $s = New-Screen -Footer $script:ShellFooter
        Mock -ModuleName Herdr Read-HerdrAgentScreen { [pscustomobject]@{ ok = $true; text = $s } }.GetNewClosure()
        $script:clock = Get-Date
        Mock -ModuleName Watch Get-Date { $script:clock = $script:clock.AddMinutes(1); $script:clock }

        $l = Watch-Worker -Name 'T-1' -TimeoutMinutes 5
        Assert-OneLine $l
        $l | Should -BeLike 'WAITING ON SHELL T-1 state=done*2 background shell(s)*Watch.ps1 report T-1*'
        $l | Should -Not -BeLike '*SETTLED*'
        Should -Invoke -ModuleName Watch Start-Sleep -Times 1
    }

    It 'settles as before, with no wait, when no shell of its own is running' {
        $s = New-Screen
        Mock -ModuleName Herdr Read-HerdrAgentScreen { [pscustomobject]@{ ok = $true; text = $s } }.GetNewClosure()
        $l = Watch-Worker -Name 'T-1' -TimeoutMinutes 1
        $l | Should -BeLike 'SETTLED T-1 state=done*'
        Should -Invoke -ModuleName Watch Start-Sleep -Times 0 -Exactly
    }

    It 'stops waiting through the shell the moment the worker''s turn starts again' {
        $script:waits = 0
        Mock -ModuleName Watch Wait-HerdrAgentProgress {
            $script:waits++
            if ($script:waits -eq 1) { New-Wake -State 'done' -Shells 1 } else { New-Wake -Reason 'stalled' }
        }
        Mock -ModuleName Watch Get-HerdrAgent { [pscustomobject]@{ agent_status = 'working' } }
        $l = Watch-Worker -Name 'T-1' -TimeoutMinutes 5
        $l | Should -BeLike 'STALLED T-1*'
        Should -Invoke -ModuleName Watch Start-Sleep -Times 1 -Exactly
    }

    It 'stops waiting through the shell when the screen cannot be read, rather than guessing' {
        $script:waits = 0
        Mock -ModuleName Watch Wait-HerdrAgentProgress {
            $script:waits++
            if ($script:waits -eq 1) { New-Wake -State 'done' -Shells 1 }
            else { New-Wake -State 'done' -Readable $false -Shells $null }
        }
        Mock -ModuleName Watch Get-HerdrAgentProgressSignal { [pscustomobject]@{ readable = $false } }
        $l = Watch-Worker -Name 'T-1' -TimeoutMinutes 5
        $l | Should -BeLike '*watch was blind*'
        Should -Invoke -ModuleName Watch Start-Sleep -Times 1 -Exactly
    }
}

Describe 'A report watch' {
    BeforeEach {
        $script:data = Join-Path $TestDrive "data-$([guid]::NewGuid().ToString('N'))"
        $script:report = Join-Path (Join-Path $script:data 'T-1') 'report.md'
        $null = New-Item -ItemType Directory -Force -Path (Split-Path $script:report)
        $script:clock = Get-Date
        Mock -ModuleName Watch Get-Date { $script:clock = $script:clock.AddMinutes(1); $script:clock }
    }

    It 'fires when the worker writes over the placeholder that was there when it started' {
        Set-Content -LiteralPath $script:report -Value 'placeholder' -Encoding utf8
        $p = $script:report
        Mock -ModuleName Watch Start-Sleep {
            Set-Content -LiteralPath $p -Value '# Findings, written by the worker' -Encoding utf8
        }.GetNewClosure()
        $l = Watch-Report -Name 'T-1' -DataPath $script:data
        Assert-OneLine $l
        $l | Should -BeLike "REPORT WRITTEN T-1 - *report.md was written after this watch started*"
    }

    It 'fires when the file did not exist when it started and then does' {
        $p = $script:report
        Mock -ModuleName Watch Start-Sleep { Set-Content -LiteralPath $p -Value 'x' -Encoding utf8 }.GetNewClosure()
        (Watch-Report -Name 'T-1' -DataPath $script:data) | Should -BeLike 'REPORT WRITTEN T-1*'
    }

    It 'times out with its own outcome when the placeholder is never written over' {
        Set-Content -LiteralPath $script:report -Value 'placeholder' -Encoding utf8
        Mock -ModuleName Watch Start-Sleep { }
        $l = Watch-Report -Name 'T-1' -DataPath $script:data -TimeoutMinutes 5
        Assert-OneLine $l
        $l | Should -BeLike 'NO REPORT T-1 after 5 minutes*it is there, unchanged since the watch started*'
    }

    It 'says the file does not exist when it times out on a report never created' {
        Mock -ModuleName Watch Start-Sleep { }
        (Watch-Report -Name 'T-1' -DataPath $script:data -TimeoutMinutes 5) |
            Should -BeLike 'NO REPORT T-1*it does not exist*'
    }

    It 'says it cannot read a path that is not a file, never that it is unwritten' {
        $null = New-Item -ItemType Directory -Force -Path $script:report
        Mock -ModuleName Watch Start-Sleep { }
        $l = Watch-Report -Name 'T-1' -DataPath $script:data
        Assert-OneLine $l
        $l | Should -BeLike 'UNREADABLE report T-1*could not be read 3 times in a row: it is a directory*'
    }

    It 'says it cannot read a file it cannot open, once that has lasted past a write' {
        Set-Content -LiteralPath $script:report -Value 'placeholder' -Encoding utf8
        Mock -ModuleName Watch Start-Sleep { }
        $lock = [System.IO.File]::Open($script:report, 'Open', 'ReadWrite', 'None')
        try {
            $l = Watch-Report -Name 'T-1' -DataPath $script:data
        } finally { $lock.Dispose() }
        $l | Should -BeLike 'UNREADABLE report T-1*3 times in a row*'
    }

    It 'rides out a read that fails once while the worker is writing' {
        Set-Content -LiteralPath $script:report -Value 'placeholder' -Encoding utf8
        $p = $script:report
        $script:sleeps = 0
        $script:lock = $null
        Mock -ModuleName Watch Start-Sleep {
            $script:sleeps++
            if ($script:sleeps -eq 1) { $script:lock = [System.IO.File]::Open($p, 'Open', 'ReadWrite', 'None') }
            else {
                $script:lock.Dispose()
                Set-Content -LiteralPath $p -Value 'the real report' -Encoding utf8
            }
        }.GetNewClosure()
        try { $l = Watch-Report -Name 'T-1' -DataPath $script:data }
        finally { if ($script:lock) { $script:lock.Dispose() } }
        $l | Should -BeLike 'REPORT WRITTEN T-1*'
    }

    It 'reads data under this installation by default' {
        $home2 = Join-Path $TestDrive "home-$([guid]::NewGuid().ToString('N'))"
        $p = Join-Path $home2 'data\T-1\report.md'
        $null = New-Item -ItemType Directory -Force -Path (Split-Path $p)
        Mock -ModuleName Watch Start-Sleep { Set-Content -LiteralPath $p -Value 'x' -Encoding utf8 }.GetNewClosure()
        $saved = $env:KINGSHAND_HOME
        try {
            $env:KINGSHAND_HOME = $home2
            $l = Watch-Report -Name 'T-1'
        } finally { $env:KINGSHAND_HOME = $saved }
        $l | Should -BeLike "REPORT WRITTEN T-1 - $p *"
    }

    It 'refuses an id that is not one path segment, and reads nothing' {
        Mock -ModuleName Watch Start-Sleep { throw 'should not wait' }
        foreach ($id in '..', '..\T-1', 'a/b') {
            $l = Watch-Report -Name $id -DataPath $script:data
            Assert-OneLine $l
            $l | Should -BeLike "NOT ARMED report*"
        }
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
    BeforeEach { Mock -ModuleName Watch Get-GateRunState { $script:Running } }

    # The wait takes its first reading as the baseline, so a run that had already ended when the
    # watch was armed would never change and the watch would wait out its clock and say "re-arm".
    It 'reports a run that had already ended at once rather than waiting on it' {
        Mock -ModuleName Watch Get-GateRunState { $script:Passed }
        Mock -ModuleName Watch Wait-GateRunChange { throw 'should not wait' }
        $l = Watch-GateRun -RepoPath 'C:\repos\acme-api' -Branch 'feature-x'
        Assert-OneLine $l
        $l | Should -BeLike 'PASSED gate on feature-x*outcome passed*pull/7*'
        Should -Invoke -ModuleName Watch Wait-GateRunChange -Times 0
    }

    It 'reports a run that had already failed at once' {
        Mock -ModuleName Watch Get-GateRunState {
            $s = $script:Passed.PSObject.Copy(); $s.outcome = 'failed'; $s }
        Mock -ModuleName Watch Wait-GateRunChange { throw 'should not wait' }
        $l = Watch-GateRun -Branch 'feature-x'
        $l | Should -BeLike 'FAILED gate on feature-x*outcome failed*'
    }

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

    # A worker idle on its own background shell that is the gate run is the case this watch is for,
    # so it is handed to the gate watch rather than waited through.
    It 'watches the gate, not the shell, when the worker is idle on a shell while its run goes on' {
        Mock -ModuleName Watch Start-Sleep { throw 'should not wait through the shell' }
        Mock -ModuleName Watch Wait-HerdrAgentProgress { New-Wake -State 'done' -Shells 1 }
        Mock -ModuleName Watch Get-GateRunState { $script:Running }
        Mock -ModuleName Watch Wait-GateRunChange { New-GateWait -Reason 'finished' -State $script:Passed }

        $l = Watch-Delivery -Name 'T-1' -RepoPath 'C:\wt' -Branch 'feature-x'
        Assert-OneLine $l
        $l | Should -BeLike 'IDLE WHILE GATE RUNS T-1*PASSED gate on feature-x*The worker: WAITING ON SHELL T-1*'
    }

    It 'waits through a shell of the worker''s own when no gate run is going' {
        $script:waits = 0
        Mock -ModuleName Watch Wait-HerdrAgentProgress {
            $script:waits++
            if ($script:waits -eq 1) { New-Wake -State 'done' -Shells 1 } else { New-Wake -State 'done' }
        }
        Mock -ModuleName Watch Start-Sleep { }
        Mock -ModuleName Watch Get-HerdrAgent { [pscustomobject]@{ agent_status = 'done' } }
        Mock -ModuleName Watch Get-HerdrAgentProgressSignal { [pscustomobject]@{ readable = $true; backgroundShells = 0 } }
        Mock -ModuleName Watch Get-GateRunState {
            $s = ConvertFrom-GateRunOutput -Text ''; $s.status = 'no-run'; $s }

        $l = Watch-Delivery -Name 'T-1' -RepoPath 'C:\wt' -Branch 'feature-x'
        $l | Should -BeLike 'SETTLED T-1*No gate run is recorded on feature-x.'
        Should -Invoke -ModuleName Watch Start-Sleep -Times 1 -Exactly
    }

    # Text in the box means the turn that ended is not the one for that text, so the worker has not
    # settled - but a gate it started is still named, read once and never waited on.
    It 'reports a worker that stopped over text in its box as unsent, naming its running gate' {
        Mock -ModuleName Watch Get-GateRunState { $script:Running }
        Mock -ModuleName Watch Wait-GateRunChange { throw 'should not wait' }
        foreach ($w in @((New-Wake -State 'done' -Box 'half-typed reply'),
                         (New-Wake -State 'done' -Paste $true))) {
            Mock -ModuleName Watch Wait-HerdrAgentProgress { $w }.GetNewClosure()
            $l = Watch-Delivery -Name 'T-1' -RepoPath 'C:\wt' -Branch 'feature-x'
            Assert-OneLine $l
            $l | Should -BeLike 'UNSENT T-1*gate run on feature-x is still running*Watch.ps1 gate T-1*'
            $l | Should -Not -BeLike '*SETTLED*'
        }
        Should -Invoke -ModuleName Watch Wait-GateRunChange -Times 0
    }

    It 'reports a worker that stopped over text in its box as unsent when no gate run is recorded' {
        Mock -ModuleName Watch Wait-HerdrAgentProgress { New-Wake -State 'done' -Box 'half-typed reply' }
        Mock -ModuleName Watch Get-GateRunState {
            $s = ConvertFrom-GateRunOutput -Text ''; $s.status = 'no-run'; $s }
        $l = Watch-Delivery -Name 'T-1' -RepoPath 'C:\wt' -Branch 'feature-x'
        Assert-OneLine $l
        $l | Should -BeLike 'UNSENT T-1*No gate run is recorded on feature-x.'
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

    It 'answers one line when the report verb is given no worker, or an id that is not one' {
        @(& $script:WatchScript report) | Should -BeLike 'NOT ARMED report - no worker id*'
        $out = @(& $script:WatchScript report 'a/b')
        $out.Count | Should -Be 1
        $out[0] | Should -BeLike 'NOT ARMED report a/b*Next:*'
    }

    It 'refuses a verb it does not have' {
        { & $script:WatchScript sleep T-1 } | Should -Throw
    }
}
