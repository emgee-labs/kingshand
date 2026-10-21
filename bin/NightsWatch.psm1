#Requires -Version 7.0
Set-StrictMode -Version Latest

# Night's watch: the away mode that works the queue while the King sleeps. The `nights-watch` skill
# owns the mode and the order of a night; this module owns every part of it that a mistake would
# make irreversible or invisible, so that part is a guard rather than a sentence.
#
# EVERYTHING HERE ANSWERS OR REFUSES, AND NOTHING HERE DECIDES ON THE KING'S BEHALF. Each function is
# one question the Hand would otherwise answer from memory at three in the morning: which queued
# items are provably decided, whether a pull request may be merged now, what the usage window says
# to do next, where a gate run's fix commits were saved, and what a restarted worker has to be told.
# A question this cannot settle comes back unsettled and named, never as the convenient answer.
#
# WHAT IS NOT HERE, ON PURPOSE. No loop, no daemon, no process that outlives the call. The King
# declined a supervision host on 2026-09-25, so the watch runs inside the live session and the only
# background work is the harness's own tracked jobs. The one function that blocks for long,
# Wait-WatchReset, is bounded by its own ceiling and is run as one of those jobs.
#
# The tools it asks, rather than parsing anything itself: `tasks-axi ready` for which items are
# unblocked and unheld (its TOON decoded by GateRun.psm1's decoder), `gh pr view --json` for a pull
# request's head and checks, `git` for refs, Usage.psm1's reading for the window, and herdr's screen
# through Herdr.psm1. docs\2026-10-21-nights-watch.md records the design.

# Nested imports WITHOUT -Force - `statute`'s style rules own why.
Import-Module (Join-Path $PSScriptRoot 'Paths.psm1')
Import-Module (Join-Path $PSScriptRoot 'GateRun.psm1')
Import-Module (Join-Path $PSScriptRoot 'Herdr.psm1')
Import-Module (Join-Path $PSScriptRoot 'AwayJournal.psm1')

# The King's 88 percent, 2026-10-21. Earlier notes give 85 and 90; his later word wins.
$script:DefaultThresholdPercent = 88
# N9 is unsettled, so the default is the cautious one: two workers at once. An invocation argument.
$script:DefaultMaxWorkers = 2
# How often the quota may be read. The tool freezes its cached reading when it is overloaded, and a
# frozen reading looks exactly like a fresh one, so this is a floor rather than a target.
$script:CloseReadMinutes = 5
$script:LooseReadMinutes = 7
$script:CloseFromPercent = 80
# How long past the reported reset to sleep. The reset time is not precise to the second.
$script:DefaultMarginMinutes = 5
# The longest sleep a five-hour window can ever need. Anything longer is the weekly window, which
# is days away: the watch stops rather than sleeping across it.
$script:MaxSleepHours = 6
# After the wake, a stale reading is read again every five minutes for up to thirty, and then the
# workers are restarted anyway - the King's word, 2026-10-22.
$script:WakeRereadMinutes    = 5
$script:WakeRereadForMinutes = 30

# The line `muster` Step 7's floor matches, spelled exactly as parley writes it.
$script:ParleyMarker = 'PARLEY DISPATCH - NO REVIEW GATE RAN.'
# The limit dialog Claude Code draws when a window is exhausted. Matched to dismiss it with Escape.
$script:LimitDialogText = 'Stop and wait for limit to reset'

# ---------------------------------------------------------------------------------------------
# The invocation
# ---------------------------------------------------------------------------------------------

# The three things the King can say at /nights-watch, validated once. Every default here is the one
# the run takes when he says nothing, so each is reached by the ordinary invocation.
function New-WatchOptions {
    [CmdletBinding()]
    param(
        [ValidateRange(50, 99)][int]$ThresholdPercent = $script:DefaultThresholdPercent,
        [ValidateRange(1, 8)][int]$MaxWorkers = $script:DefaultMaxWorkers,
        # Turns watch merging off for this run. There is no switch that turns it on: where a project
        # does not declare +watch-merge, nothing said at invocation grants it.
        [switch]$NoMerge
    )
    [pscustomobject]@{
        thresholdPercent = $ThresholdPercent
        maxWorkers       = $MaxWorkers
        merge            = if ($NoMerge) { 'off' } else { 'on' }
    }
}

# Whether one more worker may be started now. Counted from what is live, never from what was meant.
function Test-WatchDispatchSlot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Options,
        [Parameter(Mandatory)][int]$LiveWorkers
    )
    $LiveWorkers -lt $Options.maxWorkers
}

# ---------------------------------------------------------------------------------------------
# The pool
# ---------------------------------------------------------------------------------------------

# The one boundary to `tasks-axi`. Run from the installation root, where the queue lives.
function Invoke-WatchTasksAxi {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $exe = Get-Command 'tasks-axi' -CommandType Application -ErrorAction SilentlyContinue |
           Select-Object -First 1
    if (-not $exe) { return [pscustomobject]@{ ok = $false; text = ''; error = 'tasks-axi is not installed.' } }
    Push-Location (Get-KingshandHome)
    try {
        $out  = & $exe.Source @Arguments 2>&1 | Out-String
        $code = $LASTEXITCODE
        $global:LASTEXITCODE = 0
    } finally { Pop-Location }
    if ($code -ne 0) { return [pscustomobject]@{ ok = $false; text = $out; error = "tasks-axi exited $code." } }
    [pscustomobject]@{ ok = $true; text = $out; error = '' }
}

# The queue's unblocked, unheld items, as tasks-axi itself reports them. tasks-axi owns what
# "blocked" and "held" mean, so it is asked rather than second-guessed: a captain hold is a hold and
# `ready` leaves it out, and so is an unresolved blocker.
#
# .readable  whether the answer was read; $false means there is no pool at all, never an empty one
# .items     id, repo, kind, title per item
# .problem   why it could not be read
function Get-WatchReadyItems {
    [CmdletBinding()]
    param(
        # The TOON `tasks-axi ready` printed. Left off, the tool is run; passed, it is decoded as is.
        [string]$ToonText
    )

    $fail = { param($why) [pscustomobject]@{ readable = $false; items = @(); problem = $why } }

    if (-not $PSBoundParameters.ContainsKey('ToonText')) {
        $r = Invoke-WatchTasksAxi -Arguments @('ready')
        if (-not $r.ok) { return (& $fail "The queue could not be read: $($r.error) $($r.text)".Trim()) }
        $ToonText = $r.text
    }

    $decoded = ConvertFrom-ToonText -Text $ToonText
    if (-not $decoded.ok) { return (& $fail "The queue's answer could not be decoded: $($decoded.error)") }
    try { $doc = $decoded.value | ConvertFrom-Json -AsHashtable -ErrorAction Stop }
    catch { return (& $fail "The queue's answer was not the shape expected: $($_.Exception.Message)") }
    if ($doc -isnot [System.Collections.IDictionary] -or -not $doc.Contains('ready')) {
        return (& $fail "The queue's answer carries no ready list.")
    }

    $rows = @($doc['ready'])
    foreach ($row in $rows) {
        if ($row -isnot [System.Collections.IDictionary] -or -not $row.Contains('id') -or -not "$($row['id'])") {
            return (& $fail 'The queue listed an item with no id, so the pool cannot be trusted.')
        }
    }
    $items = foreach ($row in $rows) {
        [pscustomobject]@{
            id    = "$($row['id'])"
            repo  = if ($row.Contains('repo'))  { "$($row['repo'])" }  else { '' }
            kind  = if ($row.Contains('kind'))  { "$($row['kind'])" }  else { '' }
            title = if ($row.Contains('title')) { "$($row['title'])" } else { '' }
        }
    }
    [pscustomobject]@{ readable = $true; items = @($items); problem = '' }
}

# The items the watch may work: ready, on a registered project, and on one whose posture lets the
# Hand proceed without asking. An item that would need a dispatch gate is not provably decided, so
# it is left out and the reason is said, never reached for.
function Select-WatchPool {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Items,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Projects
    )

    $byName = @{}
    foreach ($p in $Projects) { if ($p -and $p.name) { $byName["$($p.name)"] = $p } }

    $pool     = [System.Collections.Generic.List[object]]::new()
    $excluded = [System.Collections.Generic.List[object]]::new()
    foreach ($it in $Items) {
        $repo = "$($it.repo)"
        $why = $null
        if (-not $repo -or $repo -eq '-') {
            $why = 'it names no project, so nothing says how it may ship'
        } elseif (-not $byName.ContainsKey($repo)) {
            $why = "$repo is not registered, and an unregistered project is never dispatched into"
        } elseif ("$($byName[$repo].yolo)" -ne 'on') {
            $why = "$repo needs the King's approval before a dispatch, so this item is not decided"
        }
        if ($why) { $excluded.Add([pscustomobject]@{ id = $it.id; repo = $repo; reason = $why }) }
        else      { $pool.Add($it) }
    }
    [pscustomobject]@{ pool = @($pool.ToArray()); excluded = @($excluded.ToArray()) }
}

# ---------------------------------------------------------------------------------------------
# The merge
# ---------------------------------------------------------------------------------------------

# The one boundary to `gh`.
function Invoke-WatchGh {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $exe = Get-Command 'gh' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $exe) { return [pscustomobject]@{ ok = $false; text = ''; error = 'gh is not installed.' } }
    $out  = & $exe.Source @Arguments 2>&1 | Out-String
    $code = $LASTEXITCODE
    $global:LASTEXITCODE = 0
    [pscustomobject]@{ ok = ($code -eq 0); text = $out; error = if ($code -ne 0) { "gh exited $code." } else { '' } }
}

# Whether the parley marker is in a file: CLEAN, MARKER, or UNREADABLE. Only CLEAN clears the floor.
function Test-WatchParleyMarker {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return 'UNREADABLE' }
    try { $text = [System.IO.File]::ReadAllText($Path) } catch { return 'UNREADABLE' }
    if ($text.Contains($script:ParleyMarker)) { 'MARKER' } else { 'CLEAN' }
}

# One check off a pull request's rollup: 'green', 'pending', 'red', or 'unreadable'. GitHub reports
# two shapes - a check run with a status and a conclusion, and a commit status with a state - and a
# shape this does not know is unreadable, never green.
function Get-WatchCheckVerdict {
    param([Parameter(Mandatory)]$Check)
    $type = if ($Check.Contains('__typename')) { "$($Check['__typename'])" } else { '' }
    if ($type -eq 'CheckRun') {
        $status = if ($Check.Contains('status')) { "$($Check['status'])" } else { '' }
        $concl  = if ($Check.Contains('conclusion')) { "$($Check['conclusion'])" } else { '' }
        if ($status -ne 'COMPLETED') { return 'pending' }
        if ($concl -in @('SUCCESS', 'NEUTRAL', 'SKIPPED')) { return 'green' }
        return 'red'
    }
    if ($type -eq 'StatusContext') {
        $state = if ($Check.Contains('state')) { "$($Check['state'])" } else { '' }
        if ($state -eq 'SUCCESS') { return 'green' }
        if ($state -in @('PENDING', 'EXPECTED')) { return 'pending' }
        if ($state -in @('FAILURE', 'ERROR')) { return 'red' }
    }
    'unreadable'
}

# Whether night's watch may merge one pull request NOW, and the head the merge must be bound to.
#
# Every floor that can be checked mechanically is checked here, and every one refuses on its own:
# the project's own +watch-merge, this run not having turned merging off, never local-only, the
# parley marker absent from both files, the pull request open and not a draft, a review gate that
# completed where the task resolved to it, and every check green at the live head - with no checks
# at all counting as green only where the repository's CI answer is the settled `no-ci`.
#
# Two floors are NOT here and cannot be: whether the work materially expands its brief, and whether
# it is destructive or security-sensitive. Those are judged by the Hand against the brief before it
# calls this, exactly as `muster` Step 7 has them, and nothing here pretends to check them.
#
# .allowed  $true only when no floor refused
# .reasons  every floor that refused, in words
# .head     the live head commit the checks were read at - the merge is bound to it
function Get-WatchMergeVerdict {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Project,
        [Parameter(Mandatory)]$Options,
        [Parameter(Mandatory)][string]$PullRequest,
        [Parameter(Mandatory)][string]$BriefPath,
        [Parameter(Mandatory)][string]$ReportPath,
        # The task's resolved mode, from muster Step 1.
        [Parameter(Mandatory)][ValidateSet('no-mistakes', 'direct-PR', 'local-only')][string]$Mode,
        # What the review gate did: completed every step through pr with a clean attribution scan,
        # stopped short of that, or was never run for this mode.
        [Parameter(Mandatory)][ValidateSet('complete', 'incomplete', 'not-run')][string]$GateOutcome,
        # The repository's CI answer from Ci.psm1, which decides what an empty rollup means.
        [Parameter(Mandatory)][ValidateSet('has-ci', 'no-ci', 'unknown')][string]$CiStatus,
        # Whether the worker's parked-decision pointer names a hold that is still open.
        [switch]$HoldOpen
    )

    $reasons = [System.Collections.Generic.List[string]]::new()
    $head = ''

    if ("$($Project.watchMerge)" -ne 'on') {
        $reasons.Add("$($Project.name) does not declare +watch-merge, so night's watch does not merge it - +merge alone grants nothing here.")
    }
    if ("$($Options.merge)" -ne 'on') { $reasons.Add('Merging was turned off for this run.') }
    if ($Mode -eq 'local-only' -or "$($Project.mode)" -eq 'local-only') {
        $reasons.Add('A local-only project lands on its branch and is never relocated to a forge merge.')
    }
    if ($Mode -eq 'no-mistakes' -and $GateOutcome -ne 'complete') {
        $reasons.Add('The review gate did not complete every step through pr with a clean attribution scan.')
    }
    if ($HoldOpen) { $reasons.Add('The worker is parked on a decision that is still open, so it is not delivered.') }
    foreach ($f in @($BriefPath, $ReportPath)) {
        $m = Test-WatchParleyMarker -Path $f
        if ($m -eq 'MARKER') { $reasons.Add("$f carries the parley marker: no review gate ran, so nothing established this is safe to merge.") }
        if ($m -eq 'UNREADABLE') { $reasons.Add("$f could not be read, so the parley marker could not be checked.") }
    }
    if ($CiStatus -eq 'unknown') { $reasons.Add('Whether anything reports a check here is unknown, so green was not established.') }

    $view = Invoke-WatchGh -Arguments @('pr', 'view', $PullRequest, '--json', 'headRefOid,state,isDraft,statusCheckRollup')
    $pr = $null
    if ($view.ok) { try { $pr = $view.text | ConvertFrom-Json -AsHashtable -ErrorAction Stop } catch { $pr = $null } }
    if ($pr -isnot [System.Collections.IDictionary]) {
        $reasons.Add("The pull request could not be read ($($view.error)), so its head and checks are unknown.")
    } else {
        $head = if ($pr.Contains('headRefOid')) { "$($pr['headRefOid'])" } else { '' }
        if ($head -notmatch '^[0-9a-f]{40}$') { $reasons.Add('The pull request reported no head commit to bind the merge to.'); $head = '' }
        if (-not $pr.Contains('state') -or "$($pr['state'])" -ne 'OPEN') { $reasons.Add('The pull request is not open.') }
        if ($pr.Contains('isDraft') -and $pr['isDraft'] -eq $true) { $reasons.Add('The pull request is a draft.') }
        $checks = @(if ($pr.Contains('statusCheckRollup') -and $null -ne $pr['statusCheckRollup']) { $pr['statusCheckRollup'] })
        if ($checks.Count -eq 0) {
            if ($CiStatus -ne 'no-ci') { $reasons.Add('The pull request reports no checks, and this repository is not settled as having none.') }
        } else {
            $verdicts = @(foreach ($c in $checks) {
                if ($c -is [System.Collections.IDictionary]) { Get-WatchCheckVerdict -Check $c } else { 'unreadable' }
            })
            if ($verdicts -contains 'red')        { $reasons.Add('A check is red at the live head. Never merge red.') }
            if ($verdicts -contains 'pending')    { $reasons.Add('A check is still pending at the live head, so it is not green yet.') }
            if ($verdicts -contains 'unreadable') { $reasons.Add('A check came back in a shape that could not be read, so it is not counted green.') }
        }
    }

    [pscustomobject]@{
        allowed     = ($reasons.Count -eq 0)
        reasons     = @($reasons.ToArray())
        head        = $head
        pullRequest = $PullRequest
    }
}

# Carries out a verdict. Refuses one that is not allowed, and binds the merge to the head the
# checks were read at, so a commit pushed after the read is never merged unchecked.
function Invoke-WatchMerge {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Verdict,
        # The repository's own strategy, from its rules file. No default: inventing one overrides
        # the repository's choice, and gh with no strategy flag goes interactive.
        [Parameter(Mandatory)][ValidateSet('merge', 'squash', 'rebase')][string]$Strategy
    )
    if (-not $Verdict.allowed) {
        throw ("Night's watch may not merge $($Verdict.pullRequest): " + ($Verdict.reasons -join ' '))
    }
    if (-not $Verdict.head) { throw "There is no head commit to bind the merge of $($Verdict.pullRequest) to." }
    $r = Invoke-WatchGh -Arguments @('pr', 'merge', $Verdict.pullRequest, "--$Strategy", '--match-head-commit', $Verdict.head)
    [pscustomobject]@{ merged = $r.ok; head = $Verdict.head; output = "$($r.text)".Trim(); error = $r.error }
}

# ---------------------------------------------------------------------------------------------
# The usage window
# ---------------------------------------------------------------------------------------------

# What one reading of the usage window tells the watch to do next.
#
# .action  continue | pause | stop-weekly | blind
#            continue     under the threshold; work goes on
#            pause        at or past it on the five-hour window; pause the workers, sleep to wakeAt
#            stop-weekly  at or past it on the weekly window; the reset is days away, so stop
#            blind        no current reading; fails open as vigil says, and the watch records it
# .percent      the figure acted on - a current one, or a floor - or $null
# .wakeAt       for pause: the reset plus the margin, pinned now, ISO
# .nextReadMinutes  when the quota may next be read: 5 at or past 80 percent, 7 below
# .detail       one line for the journal
function Get-WatchUsageStep {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Reading,
        [Parameter(Mandatory)]$Options,
        [int]$MarginMinutes = $script:DefaultMarginMinutes
    )

    $status  = "$($Reading.status)"
    $percent = $null
    if ($status -eq 'has-usage' -and $null -ne $Reading.percent) { $percent = [double]$Reading.percent }
    elseif ($null -ne $Reading.floorPercent) { $percent = [double]$Reading.floorPercent }

    $next = if ($null -ne $percent -and $percent -ge $script:CloseFromPercent) { $script:CloseReadMinutes }
            else { $script:LooseReadMinutes }
    $out = [ordered]@{ action = 'continue'; percent = $percent; wakeAt = ''; nextReadMinutes = $next; detail = "$($Reading.detail)" }

    $atLimit = $null -ne $percent -and $percent -ge $Options.thresholdPercent
    if (-not $atLimit) {
        if ($status -ne 'has-usage' -and $status -ne 'no-usage') { $out.action = 'blind' }
        return [pscustomobject]$out
    }

    if ("$($Reading.window)" -eq 'seven_day') {
        $out.action = 'stop-weekly'
        $out.detail = "The weekly window is at $([Math]::Floor($percent)) percent and resets in days, so the watch stops rather than sleeping. $($Reading.detail)"
        return [pscustomobject]$out
    }

    $out.action = 'pause'
    $wake = Get-WatchWakeTime -ResetsAt "$($Reading.resetsAt)" -MarginMinutes $MarginMinutes
    if (-not $wake.ok) {
        # A pause with no time to wake at is a night nobody wakes from. Stop instead, and say why.
        $out.action = 'stop-weekly'
        $out.detail = "The window is at $([Math]::Floor($percent)) percent and its reset time could not be read ($($wake.problem)), so there is no time to sleep to and the watch stops."
        return [pscustomobject]$out
    }
    $out.wakeAt = $wake.at
    [pscustomobject]$out
}

# The reset time plus the margin, pinned ONCE. A target rebuilt on every loop has fired instantly
# before, so the caller pins this value and the timer only ever compares against it.
function Get-WatchWakeTime {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$ResetsAt,
        [int]$MarginMinutes = $script:DefaultMarginMinutes,
        [datetime]$Now = [datetime]::UtcNow
    )
    $parsed = [datetimeoffset]::MinValue
    if (-not $ResetsAt -or -not [datetimeoffset]::TryParse($ResetsAt, [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) {
        return [pscustomobject]@{ ok = $false; at = ''; problem = "'$ResetsAt' is not a time" }
    }
    $wake = $parsed.UtcDateTime.AddMinutes($MarginMinutes)
    if ($wake -gt $Now.ToUniversalTime().AddHours($script:MaxSleepHours)) {
        return [pscustomobject]@{ ok = $false; at = ''; problem = "it is more than $script:MaxSleepHours hours away" }
    }
    [pscustomobject]@{ ok = $true; at = $wake.ToString('o'); problem = '' }
}

# The one timer across the gap: sleeps until a pinned time and returns. ZERO quota reads, no loop
# that recomputes its target, and a ceiling of its own, so a bad time cannot hold a job for days.
# Run as one harness-tracked background job, never with nohup or as a detached child; if the job
# dies, re-arm it with the same pinned time.
function Wait-WatchReset {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WakeAt,
        [int]$MaxHours = $script:MaxSleepHours
    )
    $target = [datetimeoffset]::Parse($WakeAt, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime
    $wait = $target - [datetime]::UtcNow
    if ($wait.TotalHours -gt $MaxHours) {
        throw "The wake time $WakeAt is more than $MaxHours hours away, so this is not a five-hour window and the watch must stop rather than sleep."
    }
    if ($wait.TotalSeconds -gt 0) { Start-Sleep -Milliseconds ([int64]$wait.TotalMilliseconds) }
    [pscustomobject]@{ woke = $true; at = [datetime]::UtcNow.ToString('o'); pinned = $target.ToString('o') }
}

# The one reading after the wake: has the window actually rolled over? Below the threshold on a
# current reading is yes; anything else is no, and an unreadable window is no rather than yes.
function Test-WatchWindowRolled {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Reading, [Parameter(Mandatory)]$Options)
    "$($Reading.status)" -eq 'has-usage' -and $null -ne $Reading.percent -and
        [double]$Reading.percent -lt $Options.thresholdPercent
}

# What to do with each reading after the timer wakes. The live fetch is rate limited most of the
# time, so the first reading is often stale, and a stale reading is not a reason to leave the
# workers stopped all night.
#
# .action  restart              the window rolled: restart the paused workers
#          pause | stop-weekly  a current reading is still at the limit: re-arm the timer from its
#                               reset time, or stop, exactly as Get-WatchUsageStep says
#          reread               stale or unknown: read again in nextReadMinutes
#          restart-unconfirmed  stale or unknown for the whole bound: restart anyway, and journal it
function Get-WatchWakeStep {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Reading,
        [Parameter(Mandatory)]$Options,
        [Parameter(Mandatory)][datetime]$WokeAt,
        [datetime]$Now = [datetime]::UtcNow,
        [int]$MarginMinutes = $script:DefaultMarginMinutes
    )

    $out = [ordered]@{ action = 'reread'; wakeAt = ''; nextReadMinutes = $script:WakeRereadMinutes; detail = "$($Reading.detail)" }
    if (Test-WatchWindowRolled -Reading $Reading -Options $Options) {
        $out.action = 'restart'
        return [pscustomobject]$out
    }
    if ("$($Reading.status)" -eq 'has-usage' -and $null -ne $Reading.percent) {
        $step = Get-WatchUsageStep -Reading $Reading -Options $Options -MarginMinutes $MarginMinutes
        $out.action = $step.action
        $out.wakeAt = $step.wakeAt
        $out.detail = $step.detail
        return [pscustomobject]$out
    }
    $waited = ($Now.ToUniversalTime() - $WokeAt.ToUniversalTime()).TotalMinutes
    if ($waited -ge $script:WakeRereadForMinutes) {
        $out.action = 'restart-unconfirmed'
        $out.detail = "No current usage reading in the $script:WakeRereadForMinutes minutes after the reset, so the paused workers were restarted without confirming the window rolled. $($Reading.detail)"
    }
    [pscustomobject]$out
}

# ---------------------------------------------------------------------------------------------
# Pause and restart
# ---------------------------------------------------------------------------------------------

# Saves a gate run's head to a named ref in the project repository, FIRST, before any worker is
# stopped. A review gate fixes in its own mirror and only moves the real branch at its push step, so
# a run that dies mid-review leaves its fix commits somewhere the repository cannot see.
#
# The ref is refs/gate/<task>-<stamp>, named for the task AND the moment, so two pauses on one task
# never overwrite each other's rescue - and an existing ref is refused rather than moved.
function Save-WatchGateRescue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$Head,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]*$')][string]$Task,
        # Where no-mistakes keeps its mirrors. Every mirror is asked whether it holds the commit.
        [string]$MirrorRoot = (Join-Path $env:USERPROFILE '.no-mistakes\repos'),
        [datetime]$At = [datetime]::UtcNow
    )
    if ($Head -notmatch '^[0-9a-f]{40}$') { throw "'$Head' is not a full commit id, so there is nothing exact to rescue." }
    $ref = "refs/gate/$Task-$($At.ToUniversalTime().ToString('yyyyMMdd''T''HHmm'))"

    $null = & git -C $RepoPath rev-parse --verify --quiet $ref 2>$null
    $exists = $LASTEXITCODE -eq 0
    $global:LASTEXITCODE = 0
    if ($exists) { throw "$ref already exists in $RepoPath and is not moved - a rescue never overwrites another." }

    $null = & git -C $RepoPath cat-file -e "$Head^{commit}" 2>$null
    $local = $LASTEXITCODE -eq 0
    $global:LASTEXITCODE = 0
    $source = 'repository'
    if (-not $local) {
        $mirror = $null
        if (Test-Path -LiteralPath $MirrorRoot -PathType Container) {
            foreach ($d in @(Get-ChildItem -LiteralPath $MirrorRoot -Directory)) {
                $null = & git -C $d.FullName cat-file -e "$Head^{commit}" 2>$null
                $has = $LASTEXITCODE -eq 0
                $global:LASTEXITCODE = 0
                if ($has) { $mirror = $d.FullName; break }
            }
        }
        if (-not $mirror) { throw "No gate mirror under $MirrorRoot holds $Head, so its fix commits could not be rescued. Nothing was changed." }
        # A raw commit id cannot be fetched, so the ref is made in the mirror first and fetched by name.
        $out = & git -C $mirror update-ref $ref $Head 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { $global:LASTEXITCODE = 0; throw "Could not mark $Head in $mirror ($out)." }
        $out = & git -C $RepoPath fetch --quiet $mirror "+$($ref):$ref" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { $global:LASTEXITCODE = 0; throw "Could not fetch $ref from $mirror ($out)." }
        $source = $mirror
    } else {
        $out = & git -C $RepoPath update-ref $ref $Head 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { $global:LASTEXITCODE = 0; throw "Could not write $ref ($out)." }
    }
    $saved = (& git -C $RepoPath rev-parse $ref 2>$null | Out-String).Trim()
    $global:LASTEXITCODE = 0
    if ($saved -ne $Head) { throw "$ref reads $saved after the rescue, not $Head. Treat nothing as saved." }
    [pscustomobject]@{ ref = $ref; head = $Head; from = $source }
}

# Whether a paused worker's gate run should be resumed or started fresh, from GateRun.psm1's reading
# of the run: a parked or running run survived and is resumed, a failed, cancelled or completed one
# or no run at all starts fresh. An unreadable reading, or a run status this does not know, is
# 'unknown', and a restart prompt is not built on it.
function Get-WatchResumeChoice {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$GateState)
    $status = "$($GateState.status)"
    if ($status -eq 'no-run') { return 'fresh' }
    if ($status -ne 'has-run') { return 'unknown' }
    if ($GateState.isParked -eq $true) { return 'resume' }
    switch ("$($GateState.runStatus)") {
        'running'   { return 'resume' }
        'failed'    { return 'fresh' }
        'cancelled' { return 'fresh' }
        'completed' { return 'fresh' }
        default     { return 'unknown' }
    }
}

# The prompt a worker is restarted with after the window resets. Four things travel, every time,
# because a fresh gate run rediscovers the same findings and a direction not repeated is silently
# undone: where the rescued commits are, resume or fresh, every standing direction in full, and what
# is settled and not to be re-investigated. A part left empty is refused unless it is said to be.
function New-WatchRestartPrompt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$RescueRef,
        [Parameter(Mandatory)][ValidateSet('resume', 'fresh', 'unknown')][string]$Resume,
        [AllowEmptyCollection()][string[]]$Directions = @(),
        [AllowEmptyCollection()][string[]]$Settled = @(),
        # Said, rather than left empty, where there genuinely are none.
        [switch]$NoDirections,
        [switch]$NothingSettled,
        [switch]$NothingRescued
    )
    if ($Resume -eq 'unknown') { throw 'The gate run''s state could not be read, so resume-or-fresh is not settled and no restart prompt is built on a guess.' }
    if (-not $RescueRef -and -not $NothingRescued) { throw 'Name where the rescued commits are, or pass -NothingRescued.' }
    $dirs = @($Directions | Where-Object { $_ -and $_.Trim() })
    $done = @($Settled | Where-Object { $_ -and $_.Trim() })
    if ($dirs.Count -eq 0 -and -not $NoDirections) { throw 'Restate every standing direction in full, or pass -NoDirections - a direction left out is undone by the next run.' }
    if ($done.Count -eq 0 -and -not $NothingSettled) { throw 'Name what is settled and not to be re-investigated, or pass -NothingSettled.' }

    $where = if ($RescueRef) { "Your gate run's commits are saved at $RescueRef, so nothing is lost." }
             else { 'Nothing needed rescuing.' }
    $how = if ($Resume -eq 'resume') { 'Your gate run survived: resume it rather than starting a new one.' }
           else { 'Start a fresh gate run from your branch, with the rescued commits on it.' }
    $d = if ($dirs.Count) { 'Standing directions, every one still in force: ' + ($dirs -join ' ') } else { 'There are no standing directions beyond your brief.' }
    $s = if ($done.Count) { 'Settled, do not re-investigate: ' + ($done -join ' ') } else { 'Nothing is settled beyond your brief.' }
    "You were paused on the usage window, not on anything wrong, and the window has reset. $where $how $d $s Re-read your brief and carry on."
}

# Dismisses Claude Code's usage-limit dialog with Escape, and only that dialog. It is a harness
# prompt about quota, not a decision about the work; any other prompt on the screen is left alone,
# because a blocked worker's question is the King's.
function Clear-WatchLimitDialog {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    $screen = Read-HerdrAgentScreen -Name $Name
    if (-not $screen.ok) {
        return [pscustomobject]@{ dismissed = $false; reason = 'the live screen could not be read' }
    }
    if (-not "$($screen.text)".Contains($script:LimitDialogText)) {
        return [pscustomobject]@{ dismissed = $false; reason = 'no limit dialog on the screen' }
    }
    Send-HerdrKeys -Name $Name -Keys @('escape')
    [pscustomobject]@{ dismissed = $true; reason = 'the usage-limit dialog was dismissed with Escape' }
}

# ---------------------------------------------------------------------------------------------
# The record
# ---------------------------------------------------------------------------------------------

# One journal record, written once. A worker legitimately parked on a decision is not wedged, and a
# re-armed wait that meets it again must not write it again - one parked lane is one record, not a
# stall report every threshold. The same kind, worker and text already in this period's journal is
# the same fact, and nothing is written for it.
function Write-WatchRecordOnce {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('dispatched', 'landed', 'failed', 'blocked', 'decided', 'waiting', 'closed-out', 'note')][string]$Kind,
        [Parameter(Mandatory)][string]$Text,
        [string]$Worker = '',
        [ValidateSet('recorded', 'judgement')][string]$Basis,
        [string]$Evidence,
        [string]$FlagPath,
        [string]$DataPath
    )
    $paths = @{}
    if ($FlagPath) { $paths['FlagPath'] = $FlagPath }
    if ($DataPath) { $paths['DataPath'] = $DataPath }

    $digest = Get-AwayDigest @paths
    if ($digest.readable) {
        foreach ($e in $digest.entries) {
            if ("$($e.kind)" -eq $Kind -and "$($e.text)" -eq $Text -and "$($e.worker)" -eq $Worker) {
                return [pscustomobject]@{ written = $false; reason = 'already recorded' }
            }
        }
    }
    $args_ = @{ Kind = $Kind; Text = $Text } + $paths
    if ($Worker)   { $args_['Worker']   = $Worker }
    if ($Basis)    { $args_['Basis']    = $Basis }
    if ($Evidence) { $args_['Evidence'] = $Evidence }
    $null = Write-AwayJournalEntry @args_
    [pscustomobject]@{ written = $true; reason = '' }
}

Export-ModuleMember -Function New-WatchOptions, Test-WatchDispatchSlot, Get-WatchReadyItems,
                              Select-WatchPool, Get-WatchMergeVerdict, Invoke-WatchMerge,
                              Get-WatchUsageStep, Get-WatchWakeTime, Wait-WatchReset,
                              Test-WatchWindowRolled, Get-WatchWakeStep, Save-WatchGateRescue, Get-WatchResumeChoice,
                              New-WatchRestartPrompt, Clear-WatchLimitDialog, Write-WatchRecordOnce
