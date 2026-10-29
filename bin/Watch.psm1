#Requires -Version 7.0
Set-StrictMode -Version Latest

# NOT -Force - a module never forces a nested import. The rule and the failure it prevents are in
# the `statute` skill's style rules.
Import-Module (Join-Path $PSScriptRoot 'Paths.psm1')
Import-Module (Join-Path $PSScriptRoot 'Herdr.psm1')
Import-Module (Join-Path $PSScriptRoot 'GateRun.psm1')
Import-Module (Join-Path $PSScriptRoot 'GateRunWait.psm1')
Import-Module (Join-Path $PSScriptRoot 'Crew.psm1')

# The Hand's four watches, each ending in ONE LINE that names the outcome and what to do next.
#
# THE FAILURE THIS EXISTS TO PREVENT IS COST, NOT CORRECTNESS. The waits underneath are right -
# `Wait-HerdrAgentProgress` in Herdr.psm1 and `Wait-GateRunChange` in GateRunWait.psm1 each own
# their own question - but every session armed them by hand: about 340 worker-wait arms and 1,230
# gate commands in fourteen days, each one several hundred characters of inline script carried in
# the Hand's own context, then an acknowledgement, a notification and an output-file read on top.
# All of it was paid for again on every later call. A verb with a one-line answer is the same watch
# at a fraction of the context.
#
# SO EACH WATCH HERE RETURNS EXACTLY ONE STRING, and nothing else reaches the caller. A wait's
# warnings are redirected into its result rather than printed, and a warning that was raised is
# carried on the end of the line rather than dropped, so the line stays the whole report without
# anything going silent.
#
# EVERY OUTCOME THE WAITS CAN REPORT HAS ITS OWN LINE, and none is folded into another: a worker
# blocked, stalled, gone, settled, settled over text it never took, idle on its own background
# shells until the clock ran out, its watch failing or timing out, a screen the watch could not
# read, text in its input box; a gate run parked with its findings, passed, failed, unreadable or
# quiet until the clock ran out; a worker gone idle while the gate it started keeps running; and a
# report written, not written, or unreadable. A line that cannot be composed is never replaced by a
# quieter one - an unreadable input reads as unreadable, never as a state word.
#
# Nothing here acts on what it sees. No prompt is answered, no key is sent, no run is driven: a
# watch reports, and `muster`, `rally` and `petition` own what happens next.

# How long one watch blocks before it reports that nothing happened. Forty-five minutes is what
# muster's hand-written worker wait used, and it is above the twenty-minute stall threshold, so the
# stall branch stays reachable for every caller that takes this default.
$script:DefaultTimeoutMinutes = 45

# How often a worker idle on its own background shells is looked at again, and how often a report
# watch looks at the file. Herdr's own sample interval is a minute; a report is cheap to stat.
$script:ShellSampleSeconds  = 60
$script:ReportSampleSeconds = 15

# How long a worker still idle when its last shell has gone is given to start the turn that shell's
# finish brings, before the wait that follows may read it settled.
$script:ShellDrainConfirmSeconds = 10

# How many reads of a report in a row may fail before the watch says it cannot read it. One is not
# enough: the worker's own write holds the file for a moment, and that is not a fault.
$script:ReportUnreadableTolerance = 3

# A line can only be one line. A screen tail or a tool's message can carry newlines, and a second
# line in the output is the shape this module exists to remove.
function ConvertTo-WatchText {
    [CmdletBinding()]
    param([AllowEmptyString()][AllowNull()][string]$Text)
    if ($null -eq $Text) { return '' }
    ($Text -replace '\s+', ' ').Trim()
}

# The warnings a wait raised while it ran, as one clause, or ''.
function Format-WatchWarnings {
    [CmdletBinding()]
    param([AllowNull()][object[]]$Warnings)
    $all = @($Warnings | Where-Object { $_ } | ForEach-Object { ConvertTo-WatchText "$_" })
    if ($all.Count -eq 0) { return '' }
    " Warned while waiting: $($all -join ' / ')"
}

# Runs one wait with its warning stream folded into the result rather than printed, so nothing
# reaches the caller but the line. Redirected rather than suppressed with -WarningAction, which a
# command is free not to honour: what is redirected is every warning, whoever wrote it.
#
# .value     the wait's own answer - the last thing it returned that was not a warning
# .warnings  every warning it raised
function Invoke-WatchQuietly {
    [CmdletBinding()]
    param([Parameter(Mandatory)][scriptblock]$Script)
    $out = @(& $Script 3>&1)
    $isWarning = { param($x) $x -is [System.Management.Automation.WarningRecord] }
    $values = @($out | Where-Object { -not (& $isWarning $_) })
    [pscustomobject]@{
        value    = if ($values.Count -gt 0) { $values[-1] } else { $null }
        warnings = @($out | Where-Object { & $isWarning $_ })
    }
}

# One field off an object, without assuming the object has it.
function Get-WatchField {
    [CmdletBinding()]
    param($Object, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }
    if ($Object.PSObject.Properties.Name -contains $Name) { return $Object.$Name }
    $null
}

# Whether a settled wake is a turn ending over text the worker has not taken: anything in its input
# box, or the hint that a paste went in seconds ago. Either way the turn that ended is not the one
# for that text, so it is never reported as settled. Only whether the box is empty is asked here -
# nothing reads what the text says.
function Test-WorkerWakeUnsent {
    param($Wake)
    [bool](ConvertTo-WatchText "$(Get-WatchField $Wake 'promptBox')") -or
        (Get-WatchField $Wake 'pastePending') -eq $true
}

# Whether a settled wake is a turn ending while the worker's own background shells still run - the
# footer count Get-HerdrBackgroundShellCount reads. The worker parks on them and carries on when
# they finish, so the turn ending is not a finish. An unread count is $null and is not this.
function Test-WorkerWakeOnShell {
    param($Wake)
    if ("$(Get-WatchField $Wake 'reason')" -ne 'settled') { return $false }
    if ((Get-WatchField $Wake 'awaitingInput') -eq $true) { return $false }
    if ("$(Get-WatchField $Wake 'state')" -eq 'blocked') { return $false }
    if (Test-WorkerWakeUnsent $Wake) { return $false }
    $shells = Get-WatchField $Wake 'backgroundShells'
    $null -ne $shells -and [int]$shells -gt 0
}

# One worker wake as one line. Exported so every outcome can be driven with the wake forced.
#
# The order of the checks is the order of what outranks what: a prompt on the screen outranks every
# state word, and a box with text in it is reported on every outcome rather than only one, because
# it is never the worker's output and a bare Enter would submit it. On a settle it outranks the
# settle itself: a worker whose box still holds text, or a paste that only just went in, has not
# finished - on 2026-10-23 one was reported settled seconds before it started work on the prompt.
# Background shells of its own still running come next, for the same reason: on 2026-10-28 a worker
# parked on its own test run was reported settled with its report.md still a placeholder.
function Format-WorkerWake {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowNull()]$Wake
    )

    if ($null -eq (Get-WatchField $Wake 'reason')) {
        return ("UNREADABLE $Name - the worker wait returned nothing this watch could read, so " +
                'nothing is known about the worker. Next: check Test-HerdrServer and re-arm this ' +
                'watch; do not report the worker as fine.')
    }

    $last     = ConvertTo-WatchText "$(Get-WatchField $Wake 'lastActivity')"
    $box      = ConvertTo-WatchText "$(Get-WatchField $Wake 'promptBox')"
    $readable = (Get-WatchField $Wake 'signalReadable') -eq $true
    $awaiting = (Get-WatchField $Wake 'awaitingInput') -eq $true
    $state    = "$(Get-WatchField $Wake 'state')"
    $tail     = if ($last) { " Last seen: $last" } else { '' }
    $boxNote  = if ($box) {
        " Its input box holds text nothing here sent: '$box' - never submit or clear it; quote it " +
        'to the King and load rally.'
    } else { '' }
    $blind    = if (-not $readable) {
        ' Its screen could not be read, so the watch was blind - check Test-HerdrAgentReadable ' +
        'and say you cannot see it rather than calling it healthy.'
    } else { '' }

    switch ("$($Wake.reason)") {
        'settled' {
            if ($awaiting -or $state -eq 'blocked') {
                return ("BLOCKED $Name - it is sitting on an interactive prompt it cannot pass. " +
                        'Next: tell the King now what it is asking and load rally; never answer ' +
                        "the prompt blind.$boxNote$tail")
            }
            if ($box) {
                return ("UNSENT $Name state=$state - its input box holds text that was never " +
                        "submitted: '$box'. That is not the worker's output, and a turn " +
                        'ending with it there is not a finish. Next: re-arm this watch once; ' +
                        'if the same text is still there, quote it to the King and load ' +
                        "rally - never submit or clear it.$blind$tail")
            }
            if ((Get-WatchField $Wake 'pastePending') -eq $true) {
                return ("UNSENT $Name state=$state - a paste went into its input box seconds " +
                        "ago ('paste again to expand' is showing), so this turn ending is not " +
                        'evidence it worked on that text - it may not have started. Next: ' +
                        "re-arm this watch; never submit or clear the box.$blind$tail")
            }
            $shells = Get-WatchField $Wake 'backgroundShells'
            if ($null -ne $shells -and [int]$shells -gt 0) {
                return ("WAITING ON SHELL $Name state=$state - its turn ended with $shells " +
                        'background shell(s) of its own still running, and it carries on when ' +
                        'they finish, so this is not a finish. Next: re-arm this watch, which ' +
                        "waits through them, or arm ``Watch.ps1 report $Name`` to wait for its " +
                        "report.md.$tail")
            }
            return ("SETTLED $Name state=$state - its turn ended, which is not proof it finished. " +
                    'Next: muster Step 6 - read its record and report.md before calling it ' +
                    "delivered.$blind$tail")
        }
        'stalled' {
            $quiet = Get-WatchField $Wake 'quietMinutes'
            if ($awaiting) {
                return ("BLOCKED $Name - nothing on its screen moved for $quiet minutes and it is " +
                        'sitting on a prompt. Next: tell the King what it is asking and load ' +
                        "rally; never answer the prompt blind.$boxNote$tail")
            }
            return ("STALLED $Name state=$state - nothing on its screen has moved for $quiet " +
                    'minutes. Next: tell the King what it stopped on and load rally; do not act ' +
                    "on the stall alone.$boxNote$tail")
        }
        'gone' {
            return ("GONE $Name - herdr has no such worker any more, confirmed twice with the " +
                    'server answering. Next: load rally and reconcile; never remove its worktree ' +
                    'first.')
        }
        'wait-failed' {
            return ("WATCH FAILED $Name - the wait stopped working (herdr answered instantly or " +
                    'not at all), so the worker is unwatched rather than finished. Next: check ' +
                    'Test-HerdrServer, re-arm this watch, and say you lost sight of it.')
        }
        'timeout' {
            $waited = Get-WatchField $Wake 'waitedMinutes'
            return ("NO OUTCOME $Name after $waited minutes - it did not settle and did not " +
                    "stall, which says nothing either way. Next: re-arm this watch.$boxNote$blind$tail")
        }
        default {
            return ("UNREADABLE $Name - the worker wait ended for a reason this watch does not " +
                    "know ('$($Wake.reason)'). Next: read the worker with Get-HerdrAgentState and " +
                    're-arm; do not treat it as an outcome.')
        }
    }
}

# The progress wait, run quietly, as one line or as a line naming why it could not run.
function Invoke-WorkerWait {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][int]$TimeoutMs,
        [Parameter(Mandatory)][int]$StallMinutes
    )

    $splat = @{ Name = $Name; TimeoutMs = $TimeoutMs }
    if ($StallMinutes -gt 0) { $splat.StallMinutes = $StallMinutes }
    try {
        $r = Invoke-WatchQuietly { Wait-HerdrAgentProgress @splat }
    } catch {
        return [pscustomobject]@{
            wake = $null
            line = ("WATCH FAILED $Name - the worker wait threw: " +
                    "$(ConvertTo-WatchText $_.Exception.Message) Next: check Test-HerdrServer " +
                    'and re-arm this watch; the worker is unwatched, not finished.')
        }
    }
    [pscustomobject]@{
        wake = $r.value
        line = (Format-WorkerWake -Name $Name -Wake $r.value) + (Format-WatchWarnings $r.warnings)
    }
}

# Blocks while a worker that ended its turn still has background shells of its own running, until
# they are done, its turn starts again, or the deadline. 'resumed' or 'deadline'. A count read at 0
# on a worker still idle is held a moment longer, because the turn the finish brings starts just
# after the shell exits, and a wait that read the worker before then would call it settled.
#
# It samples rather than waits on herdr, because herdr's wait returns at once on a worker that reads
# `done`, which is exactly what this worker reads - so it sleeps between samples and never spins.
# Anything it cannot read ends the hold rather than extending it: the progress wait that follows
# reads the worker afresh and owns gone, blind and every other outcome.
function Wait-WorkerShells {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][datetime]$Deadline)

    while ((Get-Date) -lt $Deadline) {
        $left = [int][Math]::Ceiling(($Deadline - (Get-Date)).TotalSeconds)
        Start-Sleep -Seconds ([Math]::Max(1, [Math]::Min($script:ShellSampleSeconds, $left)))
        try {
            $agent = Get-HerdrAgent -Name $Name
            if (-not $agent) { return 'resumed' }
            if ("$(Get-WatchField $agent 'agent_status')" -notin @('idle', 'done')) { return 'resumed' }
            $sig = Get-HerdrAgentProgressSignal -Name $Name
        } catch { return 'resumed' }
        if ((Get-WatchField $sig 'readable') -ne $true) { return 'resumed' }
        $shells = Get-WatchField $sig 'backgroundShells'
        if ($null -eq $shells) { return 'resumed' }
        if ([int]$shells -lt 1) {
            Start-Sleep -Seconds $script:ShellDrainConfirmSeconds
            return 'resumed'
        }
    }
    'deadline'
}

# The worker wait, waited through any turn that ends on the worker's own background shells, as one
# line. -OnShell is asked first on each such turn, and a true answer reports it at once instead -
# the delivery watch's way of handing a worker idle on its own gate run to the gate watch.
function Invoke-WorkerWatch {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][int]$TimeoutMinutes,
        [Parameter(Mandatory)][int]$StallMinutes,
        [scriptblock]$OnShell = $null
    )

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $ms = $TimeoutMinutes * 60000
    while ($true) {
        $worker = Invoke-WorkerWait -Name $Name -TimeoutMs $ms -StallMinutes $StallMinutes
        if (-not (Test-WorkerWakeOnShell $worker.wake)) { return $worker }
        if ($null -ne $OnShell -and (& $OnShell $worker.wake)) { return $worker }
        if ((Wait-WorkerShells -Name $Name -Deadline $deadline) -eq 'deadline') { return $worker }
        $ms = [int][Math]::Max(1000, ($deadline - (Get-Date)).TotalMilliseconds)
    }
}

# A worker, until it needs the Hand. One line.
#
# A turn that ends on background shells of the worker's own is waited through rather than reported,
# because the worker carries on when they finish. WAITING ON SHELL reaches the caller only when the
# clock runs out with them still running.
function Watch-Worker {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [int]$TimeoutMinutes = $script:DefaultTimeoutMinutes,
        # 0 is the wait's own threshold, which every caller takes unless the work is quiet for
        # longer - muster says never under fifteen.
        [int]$StallMinutes = 0
    )

    (Invoke-WorkerWatch -Name $Name -TimeoutMinutes $TimeoutMinutes -StallMinutes $StallMinutes).line
}

# One gate wait's result as one line. Exported so every outcome can be driven with the wait forced.
#
# A park names its findings by id, severity and action, because the decision has to be made from
# them - and the line still sends the reader to the full reading, because a one-line summary is
# never where a decision is made.
function Format-GateWatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][AllowNull()]$Wait,
        [string]$ReadCommand = 'Get-GateRunState'
    )

    if ($null -eq (Get-WatchField $Wait 'reason')) {
        return ("UNREADABLE gate $Label - the gate wait returned nothing this watch could read. " +
                'Next: re-arm this watch; do not read it as a quiet run.')
    }

    $state  = Get-WatchField $Wait 'state'
    $run    = "$(Get-WatchField $state 'runId')"
    $named  = if ($run) { "run $run" } else { 'the run' }
    $pr     = "$(Get-WatchField $state 'pr')"
    $prSay  = if ($pr) { "pull request $pr" } else { 'no pull request recorded' }
    $unread = [int](Get-WatchField $Wait 'unreadableReads')
    $blind  = if ($unread -gt 0) {
        " $unread of its $(Get-WatchField $Wait 'reads') reads could not be read."
    } else { '' }

    switch ("$($Wait.reason)") {
        'parked' {
            $on = "$(Get-WatchField $Wait 'parkedOn')"
            $at = if ($on) { "at its $on step" } else { 'at a step it did not name' }
            $findings = @(Get-WatchField $state 'findings' | Where-Object { $null -ne $_ })
            $list = @($findings | ForEach-Object {
                $id = "$(Get-WatchField $_ 'id')"
                if (-not $id) { $id = '(unnamed)' }
                $bits = @("$(Get-WatchField $_ 'severity')", "$(Get-WatchField $_ 'action')") |
                        Where-Object { $_ }
                if ($bits) { "$id ($($bits -join ', '))" } else { $id }
            })
            $what = if ($findings.Count -gt 0) {
                "$($findings.Count) finding(s): $($list -join '; ')"
            } else { 'no findings listed' }
            return ("PARKED gate $Label $named $at with $what. Next: read them in full with " +
                    "$ReadCommand and decide under petition; an ask-user finding is the " +
                    "King's.$blind")
        }
        'finished' {
            return ("PASSED gate $Label $named ended with outcome $($Wait.outcome), $prSay. Next: " +
                    "muster Step 6 - read report.md, then the landing gate.$blind")
        }
        'failed' {
            $note = if ((Get-WatchField $Wait 'outcomeRecognised') -eq $true) { '' } else {
                ' That outcome word is not one this watch knows, so it is reported as not passed.'
            }
            return ("FAILED gate $Label $named ended with outcome $($Wait.outcome), $prSay.$note " +
                    "Next: read report.md and the run's state, and tell the King the concrete " +
                    "failure.$blind")
        }
        'unreadable' {
            $last = ConvertTo-WatchText "$(Get-WatchField $Wait 'lastUnreadable')"
            return ("UNREADABLE gate $Label - what the run is doing could not be read " +
                    "$(Get-WatchField $Wait 'consecutiveUnreadable') times in a row: $last " +
                    'Next: check the no-mistakes daemon and re-arm; do not read it as a quiet run.')
        }
        'timeout' {
            $steps = @(Get-WatchField $state 'steps' | Where-Object { $null -ne $_ } |
                       ForEach-Object {
                           $s = "$(Get-WatchField $_ 'step')"
                           if ($s) { "$s $(Get-WatchField $_ 'status')" }
                       })
            $where = if ($steps.Count -gt 0) { " Steps: $($steps -join ', ')." } else { '' }
            $never = if ($null -eq $state) { ' No readable reading was ever taken.' } else { '' }
            $mins  = [Math]::Round([double](Get-WatchField $Wait 'waitedSeconds') / 60, 1)
            $unit  = if ($mins -eq 1) { 'minute' } else { 'minutes' }
            if ((Get-WatchField $state 'isParked') -eq $true) {
                $on = "$(Get-WatchField $state 'parkedOn')"
                $at = if ($on) { " at its $on step" } else { '' }
                return ("NO OUTCOME gate $Label after $mins $unit - nothing moved, and it is " +
                        "parked$at.$where$blind Next: read its findings with $ReadCommand and " +
                        'decide under petition; re-arming would only wait on it again.')
            }
            return ("NO OUTCOME gate $Label after $mins $unit - it neither parked nor ended." +
                    "$where$never$blind Next: re-arm this watch.")
        }
        default {
            $moved = @(Get-WatchField $Wait 'changes') -join '; '
            return ("CHANGED gate $Label $named - it moved without parking or ending: $moved. " +
                    "Next: re-arm this watch.$blind")
        }
    }
}

# A reading that is already where a watch would stop - parked or ended - in the gate wait's own
# shape, so it is reported now rather than waited on. $null for a run still going. -AllowParked
# off leaves a park to the wait, for a watch armed after a steer that should move it.
function ConvertTo-GateStopWait {
    param($State, [bool]$AllowParked = $true)

    $parked  = $AllowParked -and (Get-WatchField $State 'isParked') -eq $true
    $outcome = "$(Get-WatchField $State 'outcome')"
    if (-not $parked -and -not $outcome) { return $null }
    # The reasons are the gate wait's own words for the same states.
    $reason = if ($parked) { 'parked' }
              elseif ($outcome -match '^passed\b') { 'finished' }
              else { 'failed' }
    [pscustomobject]@{
        reason            = $reason
        state             = $State
        parkedOn          = if ($parked) { "$(Get-WatchField $State 'parkedOn')" } else { '' }
        outcome           = $outcome
        outcomeRecognised = [bool]($outcome -match '^(passed|failed|cancelled|aborted)\b')
        unreadableReads   = 0
        reads             = 1
        changes           = @()
    }
}

# A gate run, until it parks or ends. One line.
#
# Armed afresh, it reads the run once first: the wait takes its first reading as the baseline, so a
# run that had already ended would never change and the watch would wait out its clock and say to
# re-arm. An ended run is reported at once. A parked one is still waited on, because a watch armed
# after a steer is waiting for that park to move.
#
# The wait underneath returns on ANY change, including a step moving on. This keeps waiting through
# those - handing each reading back in with -FromState, so a park that lands between two waits is
# seen rather than taken as the next wait's baseline - and stops only on a park, an end, a read it
# cannot take, or the clock.
function Watch-GateRun {
    [CmdletBinding()]
    param(
        [string]$RepoPath = '',
        [string]$Branch = '',
        [string]$Run = '',
        [int]$TimeoutMinutes = $script:DefaultTimeoutMinutes,
        $FromState = $null
    )

    $label    = if ($Branch) { "on $Branch" } else { 'in this repository' }
    $read     = "Get-GateRunState -RepoPath '$RepoPath' -Branch '$Branch'"
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $from     = $FromState
    $warned   = [System.Collections.Generic.List[object]]::new()

    if ($null -eq $from) {
        $first = $null
        try { $first = Get-GateRunState -RepoPath $RepoPath -Run $Run -Branch $Branch }
        catch { $first = $null }
        if ("$(Get-WatchField $first 'status')" -eq 'has-run') {
            $ended = ConvertTo-GateStopWait -State $first -AllowParked $false
            if ($null -ne $ended) { return Format-GateWatch -Label $label -Wait $ended -ReadCommand $read }
        }
    }

    while ($true) {
        $left = [int][Math]::Ceiling(($deadline - (Get-Date)).TotalSeconds)
        if ($left -lt 1) { $left = 1 }
        try {
            $r = Invoke-WatchQuietly {
                Wait-GateRunChange -RepoPath $RepoPath -Branch $Branch -Run $Run `
                    -TimeoutSeconds $left -FromState $from
            }
        } catch {
            return ("WATCH FAILED gate $label - the gate wait threw: " +
                    "$(ConvertTo-WatchText $_.Exception.Message) Next: re-arm this watch; do " +
                    'not read it as a quiet run.')
        }
        $w = $r.value
        foreach ($x in @($r.warnings)) { $warned.Add($x) }

        if ("$(Get-WatchField $w 'reason')" -eq 'changed' -and (Get-Date) -lt $deadline) {
            $from = Get-WatchField $w 'state'
            continue
        }
        return (Format-GateWatch -Label $label -Wait $w -ReadCommand $read) +
               (Format-WatchWarnings $warned.ToArray())
    }
}

# Where a recorded worker's work lives: its directory and branch, from the durable record.
#
# .ok      whether both were read
# .repo    the worktree, or the checkout for a session worker
# .branch  its branch
# .error   one line naming what could not be read, or ''
#
# A record that is not there, or carries neither field, is a failure that says so - never a guess
# at a path, because a gate read in the wrong directory answers about somebody else's run.
function Resolve-WatchTarget {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$StatePath = (Join-Path (Get-KingshandHome) 'state\crew.json')
    )

    $fail = { param($why) [pscustomobject]@{ ok = $false; repo = ''; branch = ''; error = $why } }
    $s = $null
    try { $s = Import-CrewState -Path $StatePath }
    catch {
        return & $fail ("the durable record at $StatePath could not be read " +
                        "($(ConvertTo-WatchText $_.Exception.Message))")
    }
    $rec = Get-CrewWorker -State $s -WorkerId $Name
    if ($null -eq $rec) { return & $fail "the durable record at $StatePath has no worker $Name" }
    $repo   = "$(Get-WatchField $rec 'worktree')"
    $branch = "$(Get-WatchField $rec 'branch')"
    if (-not $repo -or -not $branch) {
        return & $fail "worker $Name's record names no worktree or no branch"
    }
    [pscustomobject]@{ ok = $true; repo = $repo; branch = $branch; error = '' }
}

# A worker AND the gate run it starts, as one watch. One line.
#
# Watching the worker alone reported a worker that handed its run to a background shell and went
# back to its prompt as settled within seconds, with the gate still running and nobody watching it.
# So when the worker settles, the gate on its branch is read once: a run still going is watched to
# its park or its end, and the line says the worker went idle while it ran. A settle over unsent
# text is reported as unsent at once, with the gate's state read once and named on the same line but
# never waited on. Anything else that is not a clean settle - blocked, stalled, gone, a failed or
# timed-out watch - is reported as the worker's own outcome, because the gate is not the question then.
# A turn ending on the worker's own background shells is waited through, unless a gate run on its
# branch is still going - then the gate is watched, exactly as for any other idle worker.
function Watch-Delivery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$Branch,
        [int]$TimeoutMinutes = $script:DefaultTimeoutMinutes,
        [int]$StallMinutes = 0
    )

    # A worker idle on its own background shells is waited through, as Watch-Worker does - unless
    # what it is idle on is a gate run on its branch, which is the gate watch's job below.
    $gateRunning = {
        param($w)
        $g = $null
        try { $g = Get-GateRunState -RepoPath $RepoPath -Branch $Branch } catch { $g = $null }
        "$(Get-WatchField $g 'status')" -eq 'has-run' -and $null -eq (ConvertTo-GateStopWait -State $g)
    }
    $worker = Invoke-WorkerWatch -Name $Name -TimeoutMinutes $TimeoutMinutes `
                  -StallMinutes $StallMinutes -OnShell $gateRunning
    $wake   = $worker.wake
    $ended  = "$(Get-WatchField $wake 'reason')" -eq 'settled' -and
              (Get-WatchField $wake 'awaitingInput') -ne $true -and
              "$(Get-WatchField $wake 'state')" -ne 'blocked'
    if (-not $ended) { return $worker.line }
    $unsent = Test-WorkerWakeUnsent $wake

    $gate = $null
    try { $gate = Get-GateRunState -RepoPath $RepoPath -Branch $Branch }
    catch { $gate = $null }
    $status = "$(Get-WatchField $gate 'status')"
    if ($status -notin @('has-run', 'no-run')) {
        $why = ConvertTo-WatchText "$(Get-WatchField $gate 'detail')"
        if (-not $why) { $why = 'the reader answered nothing' }
        return "$($worker.line) Its gate run on $Branch could not be read: $why"
    }
    if ($status -eq 'no-run') { return "$($worker.line) No gate run is recorded on $Branch." }

    $read = "Get-GateRunState -RepoPath '$RepoPath' -Branch '$Branch'"
    $stub = ConvertTo-GateStopWait -State $gate
    if ($null -ne $stub) {
        return "$($worker.line) Its gate: " +
               (Format-GateWatch -Label "on $Branch" -Wait $stub -ReadCommand $read)
    }
    if ($unsent) {
        return ("$($worker.line) Its gate run on $Branch is still running - arm " +
                "``Watch.ps1 gate $Name`` to watch it.")
    }

    $gateLine = Watch-GateRun -RepoPath $RepoPath -Branch $Branch -TimeoutMinutes $TimeoutMinutes `
                    -FromState $gate
    "IDLE WHILE GATE RUNS $Name - its turn ended while the gate run it started on $Branch kept " +
    "going, so the gate was watched instead. $gateLine The worker: $($worker.line)"
}

# One look at a report file, as a closed answer: whether it is there, and if so a stamp of its
# write time and length that changes when it is written. Nothing reads what it says.
#
# .status  'absent', 'present' or 'unreadable'
# .stamp   comparable only between two reads of the same path; '' unless present
# .error   why it could not be read, or ''
#
# 'unreadable' is anything but a clean answer - a directory at the path, a stat that failed for any
# reason other than the file not being there, or a file that cannot be opened for reading.
function Get-ReportStamp {
    param([Parameter(Mandatory)][string]$Path)

    $say = { param($s, $t, $e) [pscustomobject]@{ status = $s; stamp = $t; error = $e } }
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    } catch [System.Management.Automation.ItemNotFoundException] {
        return & $say 'absent' '' ''
    } catch {
        return & $say 'unreadable' '' (ConvertTo-WatchText $_.Exception.Message)
    }
    if ($item.PSIsContainer) { return & $say 'unreadable' '' 'it is a directory, not a file' }
    try {
        $fs = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
        $fs.Dispose()
    } catch {
        $e = $_.Exception
        if ($null -ne $e.InnerException) { $e = $e.InnerException }
        return & $say 'unreadable' '' (ConvertTo-WatchText $e.Message)
    }
    & $say 'present' "$($item.LastWriteTimeUtc.Ticks):$($item.Length)" ''
}

# A worker's report.md, until the worker writes it. One line.
#
# "Written" is a closed check and never a reading of the report: the file is there and its write
# time or length differs from the first reading this watch took - so a placeholder dispatch left
# there does not count, and the worker's own write does. A report already final when the watch is
# armed never changes, so this answers NO REPORT and says the file is there to read.
#
# A read that fails is tolerated a few times in a row, because the worker's write holds the file
# for a moment; past that the watch says it cannot read it rather than that it was not written.
function Watch-Report {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [int]$TimeoutMinutes = $script:DefaultTimeoutMinutes,
        [string]$DataPath = (Join-Path (Get-KingshandHome) 'data')
    )

    # The id becomes one path segment under data\, so it must be one: a separator or `..` would
    # watch some other file and report it as this worker's.
    if ($Name -in @('.', '..') -or $Name.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0) {
        return ("NOT ARMED report $Name - that is not a worker id this watch can turn into a path " +
                'under data. Next: name the worker by its id.')
    }

    $path     = Join-Path (Join-Path $DataPath $Name) 'report.md'
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $base     = $null
    $last     = $null
    $unread   = 0

    while ($true) {
        $r = Get-ReportStamp -Path $path
        if ($r.status -eq 'unreadable') {
            $unread++
            if ($unread -ge $script:ReportUnreadableTolerance) {
                return ("UNREADABLE report $Name - $path could not be read $unread times in a row: " +
                        "$($r.error) Next: check the file and re-arm this watch; do not read it " +
                        'as unwritten.')
            }
        } else {
            $unread = 0
            $last   = $r
            $key    = "$($r.status):$($r.stamp)"
            if ($null -eq $base) { $base = $key }
            elseif ($r.status -eq 'present' -and $key -ne $base) {
                return ("REPORT WRITTEN $Name - $path was written after this watch started. Next: " +
                        'read it, then muster Step 6; a written report is not proof the worker ' +
                        'finished.')
            }
        }

        $left = ($deadline - (Get-Date)).TotalSeconds
        if ($left -le 0) {
            $where = if ($null -eq $last) { 'no read of it ever succeeded' }
                     elseif ($last.status -eq 'absent') { 'it does not exist' }
                     else { 'it is there, unchanged since the watch started' }
            return ("NO REPORT $Name after $TimeoutMinutes minutes - $path was not written in " +
                    "that time; $where. Next: re-arm this watch, or arm ``Watch.ps1 worker " +
                    "$Name`` to see what the worker is doing.")
        }
        Start-Sleep -Seconds ([int][Math]::Max(1, [Math]::Min($script:ReportSampleSeconds,
                                                              [Math]::Ceiling($left))))
    }
}

Export-ModuleMember -Function Format-WorkerWake, Format-GateWatch, Watch-Worker, Watch-GateRun,
                              Watch-Delivery, Resolve-WatchTarget, Watch-Report
