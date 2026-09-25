#Requires -Version 7.0
Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'GateRun.psm1')

# One wait on a gate run: block until the run's state actually changes, and say why it stopped.
#
# THE FAILURE THIS EXISTS TO PREVENT. There was no supported way to wait for a gate run to move, so
# every session hand-wrote one and every hand-written one was a wake condition invented for a state
# machine the session does not own. On 2026-09-25 a run parked with two decisions waiting and sat
# unanswered for TWO HOURS AND TWENTY-SIX MINUTES, because the watch in force was keyed on the
# branch head moving - and a park does not move the head. The same night three more watches over the
# same output fired wrongly: one matched `outcome:` inside the tool's own help text, one reported a
# run settled while its gate was still running in a background shell, and one read a park that was
# already there as the answer to a steer just sent.
#
# Four watches, four different wrong answers, one cause. So this module answers the three questions
# each of them got wrong, once, here:
#
#   WHAT IS THE STATE?        Never read from text. `Get-GateRunState` in bin\GateRun.psm1 is the
#                             only source, and nothing here ever sees the tool's output at all.
#   WHAT COUNTS AS A CHANGE?  A transition away from a baseline taken at the first readable read -
#                             never a condition that happens to hold. A park that was already there
#                             when the wait was armed is not this wait's news.
#   WHAT IF IT CANNOT BE READ? Counted, never baselined, never returned as a change, and never let
#                             to pass for "nothing happened" indefinitely. The paragraph below owns
#                             this in full.
#
# A READING THE TOOL GAVE IS A STATE, HOWEVER EMPTY. A READ THE READER REFUSED IS NOT A STATE AT
# ALL. That is the one rule this module is built on, and it is the reader's own three-state rule
# one layer up, in the sharper form a wait needs because a wait fires repeatedly.
#
#   - `has-run` and `no-run` are both readings. A run with no findings, no active step and no
#     outcome is a state; so is the tool stating there is no run at all. Either can be the baseline
#     and either can be the far end of a transition.
#   - `unreadable` is the reader refusing to guess. It is NOT a state, so it is never the baseline
#     and never an endpoint. If it could be a baseline, the next readable poll would look like a
#     transition and the wait would report a change in the reader's luck as a change in the run.
#   - One unreadable read does not end the wait, stop the clock or touch the baseline. `axi status`
#     asks a local daemon, and a wait armed as a run starts will meet one that is not answering yet;
#     a wait that cannot survive its own first second is not a wait.
#   - `-UnreadableTolerance` consecutive unreadable reads DO end it, naming the read rather than the
#     run. Enough failures in a row mean the read itself is broken - node gone, daemon wedged,
#     binary vanished - and polling a read that cannot work until the timeout learns nothing and
#     then reports a quiet run. A readable read resets the count, because consecutiveness is the
#     whole evidence.
#   - Every result carries `unreadableReads`, `consecutiveUnreadable` and `lastUnreadable`,
#     INCLUDING THE SUCCESSFUL ONES, so a wait that was partly blind says so instead of quietly
#     reporting a clean answer. A caller told `timeout` can see how many of its reads were readable.
#
# Both halves matter and they fail in opposite directions. Treating an unreadable read as "nothing
# changed" is silence, which is the two-hour-twenty-six-minute failure arriving by another door.
# Treating one as a change is a false alarm, and a wait that wakes a caller for nothing gets
# ignored, which is the same silence by a third door.
#
# WHAT THIS DOES NOT DO. It does not drive a run: nothing here approves, responds, aborts or starts
# anything, and it reaches the gate binary only through the reader, which does not either. It does
# not watch a worker - `Wait-HerdrAgentProgress` in bin\Herdr.psm1 watches a process and this
# watches a pipeline, and the two are deliberately separate things with separate failure modes.

# How long the wait blocks before giving up, in seconds. Thirty minutes: long enough to cover a
# review step (fourteen minutes measured on this repository) plus a document step, so an ordinary
# quiet stretch does not end it, and short enough that a caller re-arming learns something the same
# hour.
$script:DefaultTimeoutSeconds = 1800

# How long between reads. `axi status` asks a local daemon and returns in well under a second, so
# this is about not hammering it rather than about cost; fifteen seconds is four reads a minute
# against steps that take minutes.
$script:DefaultPollSeconds = 15

# How many CONSECUTIVE unreadable reads end the wait. Three: one is noise, and three in a row on a
# local daemon is the read being broken rather than unlucky.
$script:DefaultUnreadableTolerance = 3

# A reading that never happened, in the reader's own shape.
#
# Built by ConvertFrom-GateRunOutput so the state shape is stated once and cannot drift from the
# reader's - empty text is the one input guaranteed to come back `unreadable` with every field at
# its absent value, which is exactly what a read that did not happen should look like. No state word
# is ever fabricated here: the caller gets `unreadable` and a signal naming which failure it was.
function New-UnreadableReading {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Signal,
        [Parameter(Mandatory)][string]$Detail
    )

    $reading = ConvertFrom-GateRunOutput -Text ''
    $reading.signal = $Signal
    $reading.detail = $Detail
    $reading
}

# One read of the run, always in the reader's shape, never throwing.
#
# THE READER IS THE ONLY SOURCE and this is the only place it is called, so R-002 is kept by there
# being one call rather than by every path below remembering not to look at text.
#
# A reader that threw, or answered with something that is not a state, is a failed read rather than
# a state - the same fail-closed direction everything else here takes. `Get-GateRunState` documents
# that it does not throw, but a wait is a long-running caller and the cost of being wrong about that
# is the wait dying inside a background job where nobody sees the error.
function Read-GateRunOnce {
    [CmdletBinding()]
    param(
        [string]$RepoPath = '',
        [string]$Run = '',
        [string]$Branch = ''
    )

    $state = $null
    try {
        $state = Get-GateRunState -RepoPath $RepoPath -Run $Run -Branch $Branch
    } catch {
        return New-UnreadableReading -Signal 'reader-failed' `
            -Detail ("What the run is doing could not be read: the reader failed with " +
                     "$($_.Exception.Message).")
    }

    if ($null -eq $state -or
        -not ($state.PSObject.Properties.Name -contains 'status') -or
        -not "$($state.status)") {
        return New-UnreadableReading -Signal 'reader-said-nothing' `
            -Detail ('What the run is doing could not be read: the reader answered with no state ' +
                     'at all.')
    }

    $state
}

# One field off a state object, as text, without assuming the object has it.
#
# A property that is not there reads as '' - the same absence the reader means by an empty field -
# because the signature's job is to compare two readings and a field neither of them carries is not
# a difference between them.
function Get-StateText {
    [CmdletBinding()]
    param($State, [Parameter(Mandatory)][string]$Name)

    if ($null -eq $State) { return '' }
    if (-not ($State.PSObject.Properties.Name -contains $Name)) { return '' }
    $v = $State.$Name
    if ($null -eq $v) { return '' }
    "$v".Trim()
}

# One flag off a state object, as a word, WITHOUT EVER CASTING ITS TEXT.
#
# `[bool]'False'` is `$true` in PowerShell, because the cast asks whether the string is empty and
# not what it says - so reading `isParked` as text and testing it would report every run as parked,
# and reading it the other way round would report every run as not parked. Neither error announces
# itself. The flag is read as a flag, from the property's own TYPE, which is the reader's rule about
# deciding from a value's type rather than from its rendering, one layer up.
#
# Four answers rather than two, for the same reason the reader has three: a key the object does not
# carry is `absent`, and a value that is there in a shape this cannot take is named as that rather
# than folded into `no`. Folding it into `no` is the silent default that left a parked run sitting
# for two hours and twenty-six minutes.
function Get-StateFlagText {
    [CmdletBinding()]
    param($State, [Parameter(Mandatory)][string]$Name)

    if ($null -eq $State) { return 'absent' }
    if (-not ($State.PSObject.Properties.Name -contains $Name)) { return 'absent' }
    $v = $State.$Name
    if ($v -is [bool]) { return $(if ($v) { 'yes' } else { 'no' }) }
    'in a shape this wait cannot take'
}

# WHAT COUNTS AS THE RUN'S STATE, FOR THE PURPOSE OF NOTICING IT CHANGED.
#
# One ordered map of label to text, built from the fields that decide something. Two readings are
# the same state when their signatures match, and what differs between them is what changed - which
# is where the `changes` list on a wait's result comes from, so the answer to "did it change?" and
# the answer to "what changed?" are the same computation rather than two that can disagree.
#
# WHAT IS IN IT: the reader's own status and signal, the run id, the run's status word, the outcome,
# whether it is parked and on what, the `awaiting_agent` wording, the gate and its status, EACH
# STEP'S STATUS UNDER ITS OWN NAME, and the findings.
#
# WHAT IS DELIBERATELY OUT OF IT, each for a reason that has been paid for:
#
#   - `head`. The branch head moving is not the run changing state; it is a side effect of a step
#     doing work, and the step statuses already report that work. Keying on it is exactly the watch
#     that missed a park for two hours and twenty-six minutes, because a park does not move it.
#   - `findingsSummary`. The reader's header calls it what it is: a residual summary string that
#     survives after findings have been declined. A residual count changing is not a state change,
#     and computing anything at all from it is what this family of bugs is made of.
#   - Durations, `active_for`, `last_activity`, `agent_pid`, `takenAt`, `exitCode`, `json`. Every
#     one of them differs on every read. A signature carrying any of them makes each read a change,
#     so the wait returns immediately every time - and a wait that always returns is no wait.
#
# Steps are compared BY NAME rather than as one joined string, so what comes back is
# `step review: running -> awaiting_approval` and not a diff of two long lines. A step whose name is
# empty is keyed by position instead, and a name that repeats keeps both rows, because collapsing
# two steps into one is the silent loss this whole family of readers exists to refuse.
function Get-GateRunSignature {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$State)

    $sig = [ordered]@{}
    $sig['reading']        = Get-StateText -State $State -Name 'status'
    $sig['signal']         = Get-StateText -State $State -Name 'signal'
    $sig['run id']         = Get-StateText -State $State -Name 'runId'
    $sig['run status']     = Get-StateText -State $State -Name 'runStatus'
    $sig['outcome']        = Get-StateText -State $State -Name 'outcome'
    $sig['waiting']        = Get-StateFlagText -State $State -Name 'isParked'
    $sig['waiting on']     = Get-StateText -State $State -Name 'parkedOn'
    $sig['awaiting agent'] = Get-StateText -State $State -Name 'awaitingAgent'
    $sig['gate']           = Get-StateText -State $State -Name 'gate'
    $sig['gate status']    = Get-StateText -State $State -Name 'gateStatus'

    $steps = @()
    if ($null -ne $State -and ($State.PSObject.Properties.Name -contains 'steps')) {
        $steps = @($State.steps)
    }
    for ($i = 0; $i -lt $steps.Count; $i++) {
        $name = Get-StateText -State $steps[$i] -Name 'step'
        $key  = $(if ($name) { "step $name" } else { "step #$($i + 1)" })
        if ($sig.Contains($key)) { $key = "$key #$($i + 1)" }
        $sig[$key] = Get-StateText -State $steps[$i] -Name 'status'
    }

    # The count travels with the ids so a table of findings this reader could not name is still a
    # different state from no findings at all. Sorted, because the order rows arrive in is not a
    # fact about the run and a reordering is not something to wake anybody for.
    $findings = @()
    if ($null -ne $State -and ($State.PSObject.Properties.Name -contains 'findings')) {
        $findings = @($State.findings)
    }
    $ids = @($findings | ForEach-Object {
        $id = Get-StateText -State $_ -Name 'id'
        $(if ($id) { $id } else { '(unnamed)' })
    } | Sort-Object)
    $sig['findings'] = "$($findings.Count): $($ids -join ',')"

    $sig
}

# The difference between two signatures, as one record per field that moved.
#
# .key   the signature's own label for the field
# .text  that difference in words, for a person to read
#
# A field absent from one side reads as '' rather than as a difference in itself, and a value that
# is empty on either side renders as `(none)` - "outcome: (none) -> passed" says what happened and
# "outcome:  -> passed" reads as a typo.
function Compare-GateRunSignature {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$From,
        [Parameter(Mandatory)]$To
    )

    $show = { param([string]$V) if ($V) { $V } else { '(none)' } }
    $keys = @(@($From.Keys) + @($To.Keys) | Select-Object -Unique)

    @(foreach ($key in $keys) {
        $a = $(if ($From.Contains($key)) { "$($From[$key])" } else { '' })
        $b = $(if ($To.Contains($key))   { "$($To[$key])"   } else { '' })
        if ($a -cne $b) {
            [pscustomobject]@{ key = $key; text = "$key`: $(& $show $a) -> $(& $show $b)" }
        }
    })
}

# How long the wait ran, in the units a person would say it in.
function Format-WaitedFor {
    [CmdletBinding()]
    param([Parameter(Mandatory)][double]$Seconds)

    if ($Seconds -lt 90) { return "$([Math]::Round($Seconds, 1)) seconds" }
    "$([Math]::Round($Seconds / 60, 1)) minutes"
}

# The signature fields that are about the run waiting on somebody.
#
# A run that was already parked when the wait was armed and is still parked has not just parked, so
# `parked` is the answer only when one of these moved. Without that, a step transition on an
# already-parked run would come back as `parked` and bury the thing that actually changed - and a
# NEW park on a run that was already parked, which is a second decision waiting, would be the thing
# buried if the test were only "was it parked before".
$script:ParkSignatureKeys = @('waiting', 'waiting on', 'awaiting agent', 'gate', 'gate status',
                              'findings')

# The outcome words this wait knows. An outcome it does not know still ENDS THE WAIT - the run said
# it is over and waiting longer would be waiting forever - but it is reported as not passed and
# named as unrecognised, never quietly taken for a pass. That is the reader's own rule about an
# unrecognised `awaiting_agent`, applied to the field at the other end of the run.
$script:KnownOutcomes = '^(passed|failed|cancelled|aborted)\b'

# What to call the transition that stopped the wait, decided from the state AND from what moved.
#
# .reason             parked | finished | failed | changed
# .outcomeRecognised  whether the outcome word is one this wait knows
function Get-GateRunStopReason {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ChangedKeys
    )

    $parked  = (Get-StateFlagText -State $State -Name 'isParked') -eq 'yes'
    $outcome = Get-StateText -State $State -Name 'outcome'
    $moved   = { param([string[]]$Keys) [bool](@($ChangedKeys | Where-Object { $_ -in $Keys })) }

    if ($parked -and (& $moved $script:ParkSignatureKeys)) {
        return [pscustomobject]@{ reason = 'parked'; outcomeRecognised = $false }
    }
    if ($outcome -and ('outcome' -in $ChangedKeys)) {
        $recognised = [bool]($outcome -match $script:KnownOutcomes)
        $reason     = $(if ($outcome -match '^passed\b') { 'finished' } else { 'failed' })
        return [pscustomobject]@{ reason = $reason; outcomeRecognised = $recognised }
    }
    [pscustomobject]@{ reason = 'changed'; outcomeRecognised = $false }
}

# Blocks until a gate run's state changes, and says why it stopped.
#
# .changed                whether the run's state actually changed. FALSE IS THE ABSENCE OF AN
#                         OUTCOME, never an outcome of its own - a timeout and an unreadable run
#                         are both facts about the wait rather than about the run.
# .reason                 parked | finished | failed | changed | timeout | unreadable
# .detail                 one line naming the evidence, written to be read to a person
# .changes                what moved, one line per field
# .changedFields          the same fields as labels, so nothing has to parse the lines above
# .parkedOn               the step it is parked at, where it is parked and named one
# .outcome                the tool's own outcome word, verbatim, where the run ended
# .outcomeRecognised      whether that word is one this wait knows
# .state                  the last READABLE reading in full, or $null if there never was one
# .baseline               the reading the comparison was made against, or $null
# .baselineTakenAt        when that baseline was read
# .waitedSeconds          how long the wait blocked
# .reads                  how many reads it took
# .unreadableReads        how many of those the reader refused
# .consecutiveUnreadable  how many of those were the last ones in a row
# .lastUnreadable         what the reader said about the last one, or ''
# .lastUnreadableSignal   the reader's own signal for it, or ''
# .timeoutSeconds         the timeout it ran under, after the floor below was applied
# .pollSeconds            the interval it read at
# .unreadableTolerance    how many failed reads in a row it would take
#
# -TimeoutSeconds DEFAULTS TO A COMPUTED FLOOR, NOT TO A CONSTANT, and that is standing criterion 6
# rather than tidiness. A timeout shorter than `(-UnreadableTolerance + 1) * -PollSeconds` makes the
# unreadable branch unreachable for every caller that does not override it: the clock runs out
# before enough consecutive failures can be counted, so a wedged daemon reports a quiet run. That is
# the TimeoutMs failure this repository has already paid for once, where a four-minute default
# against a twenty-minute stall threshold made the stall branch dead code. A caller passing a
# shorter timeout deliberately gets what it asked for - a watch for a change only.
#
# -Branch IS WORTH PASSING AND THE DEFAULT IS NOT SAFE FOR A WAIT. The reader's own guard exists
# because `axi status` with no `--run` returns the most recent run in the REPOSITORY, which is not
# necessarily the one being watched; a watcher armed before its own run had registered once read a
# different, finished run and reported success immediately. Naming the branch turns that into a
# refusal, and a refusal is a `no-run` reading this wait will happily baseline and then notice
# changing the moment the right run appears.
function Wait-GateRunChange {
    [CmdletBinding()]
    param(
        [string]$RepoPath = '',
        [string]$Run = '',
        [string]$Branch = '',
        [int]$TimeoutSeconds = 0,
        [int]$PollSeconds = $script:DefaultPollSeconds,
        [int]$UnreadableTolerance = $script:DefaultUnreadableTolerance
    )

    if ($PollSeconds -lt 1)         { $PollSeconds = 1 }
    if ($UnreadableTolerance -lt 1) { $UnreadableTolerance = 1 }
    if ($TimeoutSeconds -le 0) {
        $TimeoutSeconds = [Math]::Max($script:DefaultTimeoutSeconds,
                                      ($UnreadableTolerance + 1) * $PollSeconds)
    }

    $started  = Get-Date
    $deadline = $started.AddSeconds($TimeoutSeconds)

    $baseline       = $null
    $baselineSig    = $null
    $baselineTaken  = ''
    $state          = $null
    $reads          = 0
    $unreadable     = 0
    $consecutive    = 0
    $lastDetail     = ''
    $lastSignal     = ''

    $report = {
        param($changed, $reason, $detail, $changes, $outcomeRecognised)
        [pscustomobject]@{
            changed               = $changed
            reason                = $reason
            detail                = $detail
            changes               = @($changes | ForEach-Object { $_.text })
            changedFields         = @($changes | ForEach-Object { $_.key })
            parkedOn              = $(if ($reason -eq 'parked') {
                                          Get-StateText -State $state -Name 'parkedOn' } else { '' })
            outcome               = Get-StateText -State $state -Name 'outcome'
            outcomeRecognised     = $outcomeRecognised
            state                 = $state
            baseline              = $baseline
            baselineTakenAt       = $baselineTaken
            waitedSeconds         = [Math]::Round(((Get-Date) - $started).TotalSeconds, 1)
            reads                 = $reads
            unreadableReads       = $unreadable
            consecutiveUnreadable = $consecutive
            lastUnreadable        = $lastDetail
            lastUnreadableSignal  = $lastSignal
            timeoutSeconds        = $TimeoutSeconds
            pollSeconds           = $PollSeconds
            unreadableTolerance   = $UnreadableTolerance
        }
    }

    while ($true) {
        $reading = Read-GateRunOnce -RepoPath $RepoPath -Run $Run -Branch $Branch
        $reads++

        if ($reading.status -eq 'unreadable') {
            # Counted, and nothing else. The baseline is untouched, the clock keeps running, and no
            # change is claimed - an unreadable read is not a state, so there is no transition it
            # could be either end of.
            $unreadable++
            $consecutive++
            $lastDetail = "$($reading.detail)"
            $lastSignal = "$($reading.signal)"

            if ($consecutive -ge $UnreadableTolerance) {
                $blind = $(if ($baselineSig) { '' }
                           else { ' No readable reading was ever taken, so there is no baseline ' +
                                  'and nothing here says anything about the run.' })
                return & $report $false 'unreadable' `
                    ("What the run is doing could not be read $consecutive times in a row, so the " +
                     'wait stopped rather than reporting a run that had not changed.' + $blind +
                     " The last read said: $lastDetail") @() $false
            }
        } else {
            $consecutive = 0
            $state       = $reading
            $signature   = Get-GateRunSignature -State $reading

            if ($null -eq $baselineSig) {
                # THE FIRST READABLE READING IS THE BASELINE AND IS NEVER A RETURN. Whatever it
                # holds was already true when the wait was armed, so it is not news: a park that
                # predated a steer satisfying a watch armed after it is the concrete defect this
                # rule removes.
                $baseline      = $reading
                $baselineSig   = $signature
                $baselineTaken = Get-StateText -State $reading -Name 'takenAt'
            } else {
                $changes = @(Compare-GateRunSignature -From $baselineSig -To $signature)
                if ($changes.Count -gt 0) {
                    $keys = @($changes | ForEach-Object { $_.key })
                    $stop = Get-GateRunStopReason -State $reading -ChangedKeys $keys
                    return & $report $true $stop.reason `
                        (Get-ChangeDetail -State $reading -Stop $stop -Changes $changes `
                                          -Seconds ((Get-Date) - $started).TotalSeconds `
                                          -Unreadable $unreadable) `
                        $changes $stop.outcomeRecognised
                }
            }
        }

        $remainingMs = ($deadline - (Get-Date)).TotalMilliseconds
        if ($remainingMs -le 0) { break }
        Start-Sleep -Milliseconds ([int][Math]::Min($PollSeconds * 1000, $remainingMs))
    }

    # THE TIMEOUT SAYS WHAT IT SAW, NOT THAT THE RUN IS FINE. A wait that spent some of its reads
    # blind cannot honestly report that nothing changed, so it reports how much of the time it could
    # see - which is the difference between "the run is quiet" and "I could not tell".
    $seen = $reads - $unreadable
    $blind = $(if ($unreadable -gt 0) {
                   " $unreadable of its $reads reads could not be read, so it saw $seen of them." }
               else { '' })
    $never = $(if ($baselineSig) { '' }
               else { ' No readable reading was ever taken, so nothing here says anything about ' +
                      'the run.' })
    & $report $false 'timeout' `
        ('The wait ended after ' + (Format-WaitedFor -Seconds ((Get-Date) - $started).TotalSeconds) +
         " without the run's state changing." + $blind + $never +
         ' That is the absence of an outcome, not one.') @() $false
}

# The line a person reads when the wait returns on a change.
#
# Separated from the loop so the wording is in one place, and written from the state rather than
# from a template per reason - the run's own words are quoted and none of them is translated into
# a state word this wait made up.
function Get-ChangeDetail {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)]$Stop,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Changes,
        [Parameter(Mandatory)][double]$Seconds,
        [Parameter(Mandatory)][int]$Unreadable
    )

    $id     = Get-StateText -State $State -Name 'runId'
    $branch = Get-StateText -State $State -Name 'branch'
    $named  = $(if ($id) { "Run $id" } else { 'The run' })
    $on     = $(if ($branch) { " on $branch" } else { '' })
    $after  = " after $(Format-WaitedFor -Seconds $Seconds)"
    $blind  = $(if ($Unreadable -gt 0) {
                    " $Unreadable earlier read(s) could not be read." } else { '' })
    $moved  = ' What moved: ' + (@($Changes | ForEach-Object { $_.text }) -join '; ') + '.'

    switch ($Stop.reason) {
        'parked' {
            $step    = Get-StateText -State $State -Name 'parkedOn'
            $at      = $(if ($step) { "at its $step step" } else { 'at a step it did not name' })
            $findings = @()
            if ($State.PSObject.Properties.Name -contains 'findings') {
                $findings = @($State.findings)
            }
            $listed  = $(if ($findings.Count -gt 0) {
                             " It lists $($findings.Count) finding(s) to decide on." }
                         else { '' })
            "$named$on parked $at$after and is waiting to be answered.$listed$moved$blind"
        }
        'finished' {
            $outcome = Get-StateText -State $State -Name 'outcome'
            "$named$on ended$after with outcome $outcome.$moved$blind"
        }
        'failed' {
            $outcome = Get-StateText -State $State -Name 'outcome'
            $note    = $(if ($Stop.outcomeRecognised) { '' }
                         else { ' That is not a word this wait recognises, so it is reported as ' +
                                'not passed rather than taken for a pass.' })
            "$named$on ended$after with outcome $outcome, which is not passed.$note$moved$blind"
        }
        default {
            "$named$on changed$after.$moved$blind"
        }
    }
}

Export-ModuleMember -Function Get-GateRunSignature, Compare-GateRunSignature, Wait-GateRunChange
