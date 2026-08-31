#Requires -Version 7.0
<#
.SYNOPSIS
  The once-per-session digest: toolchain problems, fleet state, the queue, where the data index is
  and how far it has drifted, the King's own standing instructions, and the two curated memory
  files, rendered as one block a session can read and trust.
.DESCRIPTION
  This is operational input, not a report. It runs from a SessionStart hook and its whole purpose
  is to make a restart a non-event: everything a fresh session needs to orient itself is printed
  once, so nothing has to be rediscovered by re-reading the same files a second time.

  Deliberately NOT a second `survey`. Survey is an on-demand, curated four-section answer to
  "what needs me", asked for by the user and rendered with judgement. This is a mechanical dump of
  startup facts nobody asked for, read once at session open. Neither calls the other, and nothing
  runs survey on the user's behalf.

  Bounded on purpose. The fleet, queue and index sections are counts and one-liners; only
  `instructions.md` and the two memory files are printed in full, and only the two memory files are
  accounted against the startup-memory budget. A digest that grew with the fleet would be the
  session-start bulk this deliberately avoids - the registry line is name, posture and path, never
  the detail that belongs elsewhere, and the index section is where the index is and how far it has
  drifted, never what any indexed file says.

  `instructions.md` is the King's own standing instructions, written by hand and never edited by
  the Hand. It is deliberately NOT one of the memory files: `king.md` and `learnings.md` are what
  the Hand learned and `chronicle` prunes them, while `instructions.md` is what the King stated and
  nothing rewrites it. It is not counted against the memory budget for the same reason - a budget
  is pressure to curate, and there is nothing here the Hand is allowed to curate.

  Never throws. Every section is independently guarded, and a section that fails prints one
  diagnostic line in its own place while the rest still renders. This runs on a hook: a broken
  digest must never be the reason a session cannot start.

  Absence is meaningful, never an error. An absent `king.md` means nothing has been recorded about
  how the King works yet, and an absent `instructions.md` means the King has stated no standing
  preferences. Each prints an explicit ABSENT marker that is never confused with a file that
  exists and holds nothing. An empty registry means nothing can be dispatched until
  `/annex` runs. Each of those is a state the digest states plainly.

  Reuses `Get-SurveySnapshot.ps1` for fleet state, `Index.psm1` for the index and its drift, and
  `Memory.psm1` for the budget rather than reading any of them a second way. There is one fleet
  reader, one index reader and one estimator, and this is a caller of all three.

.PARAMETER DataPath
  the data\ directory holding king.md, learnings.md, data\<id>\, and the index.
.PARAMETER StatePath
  state\crew.json - worker intent.
.PARAMETER RegistryPath
  data\projects.md - the project registry.
.PARAMETER BudgetPath
  config\startup-memory-budget - the one validated startup-memory budget, absent meaning default.
.PARAMETER InstructionsPath
  instructions.md at the repo root - the King's own standing instructions. Read, never written.
.PARAMETER PrereqScript
  the toolchain check. Detect-only: a clean run prints nothing at all.
.PARAMETER QueueRoot
  the directory tasks-axi is run from, which is what selects the backlog it reads.
.PARAMETER Json
  wrap the digest in the SessionStart hook envelope. Without it, plain text for a human.
.EXAMPLE
  & $env:KINGSHAND_HOME\bin\Get-SessionStart.ps1
.EXAMPLE
  & $env:KINGSHAND_HOME\bin\Get-SessionStart.ps1 -Json
#>
[CmdletBinding()]
param(
    [string]$DataPath,
    [string]$StatePath,
    [string]$RegistryPath,
    [string]$BudgetPath,
    [string]$InstructionsPath,
    [string]$PrereqScript = (Join-Path $PSScriptRoot 'Test-CrewPrereqs.ps1'),
    [string]$QueueRoot,
    [switch]$Json
)

Set-StrictMode -Version Latest

# Resolved in the body rather than as parameter defaults: the root comes from Get-KingshandHome,
# which is the one place that decision is made, and a param default cannot call it.
Import-Module (Join-Path $PSScriptRoot 'Paths.psm1') -Force
$script:Root = Get-KingshandHome
if (-not $DataPath)         { $DataPath         = Join-Path $script:Root 'data' }
if (-not $StatePath)        { $StatePath        = Join-Path $script:Root 'state\crew.json' }
if (-not $RegistryPath)     { $RegistryPath     = Join-Path $script:Root 'data\projects.md' }
if (-not $BudgetPath)       { $BudgetPath       = Join-Path $script:Root 'config\startup-memory-budget' }
if (-not $InstructionsPath) { $InstructionsPath = Join-Path $script:Root 'instructions.md' }
if (-not $QueueRoot)        { $QueueRoot        = $script:Root }

$script:Lines    = [System.Collections.Generic.List[string]]::new()
$script:ListCap  = 25

function Add-Line {
    param([string]$Text = '')
    $script:Lines.Add($Text)
}

# An exception message can be a paragraph, and a diagnostic line in a bounded digest cannot be.
function Format-Fault {
    param([Parameter(Mandatory)][string]$Message)
    $m = ($Message -replace '\s+', ' ').Trim()
    if ($m.Length -gt 200) { $m = $m.Substring(0, 200) + '...' }
    $m
}

# Test-Path throws on a malformed path, and several paths here are whatever someone typed into a
# registry or passed as a parameter. A path we cannot test is absent, not a failed digest.
function Test-PathQuiet {
    param([string]$Path)
    try {
        if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
        return [bool](Test-Path -LiteralPath $Path)
    } catch {
        return $false
    }
}

# StrictMode Latest turns a missing property into an exception, and everything below reads objects
# built by other scripts. An absent field reads as its fallback instead.
function Get-Field {
    param($Entry, [Parameter(Mandatory)][string]$Key, [string]$Fallback = '')
    try {
        if ($null -eq $Entry) { return $Fallback }
        $p = $Entry.PSObject.Properties[$Key]
        if ($p -and $null -ne $p.Value -and "$($p.Value)".Length -gt 0) { return "$($p.Value)" }
        return $Fallback
    } catch {
        return $Fallback
    }
}

# A list in this digest is a set of one-liners, and a fleet of forty must not turn session start
# into a wall. The tail is counted rather than printed.
function Add-BoundedList {
    param([string[]]$Items, [string]$Indent = '    ')
    $all = @($Items)
    $shown = if ($all.Count -gt $script:ListCap) { $all[0..($script:ListCap - 1)] } else { $all }
    foreach ($item in $shown) { Add-Line ($Indent + $item) }
    if ($all.Count -gt $script:ListCap) {
        Add-Line ($Indent + "... and $($all.Count - $script:ListCap) more")
    }
}

Add-Line ("=== KINGSHAND SESSION START - " + (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm') + " UTC ===")

# --------------------------------------------------------------------------------
# 0. First run. The SessionStart hook ships inside the repository, so this digest
#    fires on a fresh clone before anything is installed. The skills load from
#    .claude\skills\ and are readable straight away, but the toolchain, the
#    registry and the local directories they all depend on are not there yet, so
#    every instruction below it would fail on a missing prerequisite. Say so here
#    instead, and stop: pointing a new reader at /annex before setup has run sends
#    them after something that cannot work. install.ps1 creates data\, so its
#    absence is the signal.
# --------------------------------------------------------------------------------
# KINGSHAND_HOME wins over a script's own location, deliberately - see bin\Paths.psm1. That is
# right for the ordinary case and wrong in exactly one: a second clone, whose install.ps1 finds the
# variable already pointing at the first and leaves it alone. That copy then runs its own code
# against the other installation's registry, workers and queue, and every path below names a
# directory the reader did not expect. Silent is the problem, not the precedence.
$configuredHome = $env:KINGSHAND_HOME
$derivedHome    = Split-Path $PSScriptRoot -Parent
if (-not [string]::IsNullOrWhiteSpace($configuredHome) -and
    $configuredHome.TrimEnd('\', '/') -ne $derivedHome.TrimEnd('\', '/')) {
    Add-Line ''
    Add-Line 'HOME MISMATCH'
    Add-Line "  This copy lives at $derivedHome"
    Add-Line "  but KINGSHAND_HOME points at $configuredHome, so everything below is read from there."
    Add-Line '  Two installations are cross-wired. Run install.ps1 -Force here to claim it, or clear'
    Add-Line '  the variable to let each copy use its own.'
}

$script:NotSetUp = -not (Test-PathQuiet $DataPath)
if ($script:NotSetUp) {
    Add-Line ''
    Add-Line 'NOT SET UP YET'
    Add-Line '  This looks like a fresh clone - nothing is installed and no work is registered.'
    Add-Line '  Tell the Hand "set it up". It checks the toolchain, installs what is missing,'
    Add-Line '  and configures this machine. Nothing else here works until it has run.'
    Add-Line '  Say that before anything else, and do not send the reader to a skill whose'
    Add-Line '  prerequisites and configuration are not in place yet.'
}

# --------------------------------------------------------------------------------
# 1. Prereqs - detect only, and silent when the toolchain is clean. A routine
#    confirmation at session start is noise that trains the reader to skip the
#    section, so only an actionable problem is allowed to print here at all.
# --------------------------------------------------------------------------------
try {
    if (-not (Test-PathQuiet $PrereqScript)) {
        Add-Line ''
        Add-Line "PREREQS: the toolchain check is not at $PrereqScript, so nothing was verified."
    } else {
        # Strict mode is switched off for the child: the check predates this script, and a strict
        # setting inherited from here would turn one of its optional reads into a failure that
        # looks like a missing tool. Every stream is captured so its Write-Host lines become data
        # rather than console output, which matters because -Json must emit JSON and nothing else.
        # Cleared first because $LASTEXITCODE is global and may not exist yet, or may still hold
        # some earlier command's result - either of which would make a clean toolchain read as
        # broken under strict mode.
        $global:LASTEXITCODE = 0
        $captured = @(& { Set-StrictMode -Off; & $PrereqScript *>&1 })
        $code     = $LASTEXITCODE

        if ($code -ne 0) {
            $text     = @($captured | ForEach-Object { "$_" })
            $failedAt = -1
            for ($i = 0; $i -lt $text.Count; $i++) {
                if ($text[$i].Trim() -eq 'FAILED:') { $failedAt = $i; break }
            }

            # The check prints its problems under a FAILED: header. If that shape ever changes,
            # fall back to everything that is not an OK confirmation rather than printing nothing.
            #
            # The outer @() is load-bearing. Assigning from an `if` unrolls its branch, so exactly
            # one problem arrived here as a bare string and `$problems.Count` below threw under
            # strict mode - which cost the whole section, reporting "could not run the toolchain
            # check" for a check that had run and found precisely one thing.
            $problems = @(if ($failedAt -ge 0 -and $failedAt -lt $text.Count - 1) {
                @($text[($failedAt + 1)..($text.Count - 1)] | Where-Object { $_.Trim() })
            } else {
                @($text | Where-Object { $_.Trim() -and $_ -notmatch '^\s*OK\s' -and $_ -notmatch '^\s+OK\s' })
            })

            Add-Line ''
            foreach ($p in $problems) { Add-Line ("PREREQS: " + ($p -replace '^\s*-\s*', '').Trim()) }
            if ($problems.Count -eq 0) {
                Add-Line "PREREQS: the toolchain check reported a failure but named nothing; run it by hand."
            }
        }
    }
} catch {
    Add-Line ''
    Add-Line ("PREREQS: could not run the toolchain check - " + (Format-Fault $_.Exception.Message))
}

# --------------------------------------------------------------------------------
# 2. Fleet - one call to the existing bounded reader. This section never opens a
#    brief, a report or a project; it says what exists and where, and stops.
# --------------------------------------------------------------------------------
Add-Line ''
Add-Line 'FLEET'

# The away flag first, because it changes how everything under it should be read.
#
# A regency is durable on purpose - it has to survive a restart, since the whole point is that
# nobody is at the machine to re-enter it. But durable state nothing surfaces is a trap: the flag
# would sit on disk while a fresh session behaved as though the King were present, narrating at an
# empty chair and treating a blocked worker as somebody else's problem. So it is the first line of
# the fleet, not a footnote.
$afkFlag = Join-Path (Split-Path $StatePath -Parent) '.afk'
if (Test-PathQuiet $afkFlag) {
    $since = ''
    try {
        $line = @(Get-Content -LiteralPath $afkFlag -ErrorAction Stop | Where-Object { $_ -match '^since:' }) |
                Select-Object -First 1
        if ($line) { $since = ' (' + $line.Trim() + ')' }
    } catch { }
    Add-Line "  AWAY: a regency is in force$since - load ``regency``. The King is not at the machine."
    Add-Line '        Batch everything that does not need them, and never answer a worker''s question for them.'
}

try {
    $snapshotScript = Join-Path $PSScriptRoot 'Get-SurveySnapshot.ps1'
    if (-not (Test-PathQuiet $snapshotScript)) { throw "Get-SurveySnapshot.ps1 is not at $snapshotScript." }

    $snap = & $snapshotScript -RegistryPath $RegistryPath -DataPath $DataPath -StatePath $StatePath

    # Registry: name, posture, path. Nothing else - the tagging and shorthand detail that belongs
    # to a project lives with that project, and putting it here is the session-start bulk this
    # digest exists to avoid.
    $entries = @($snap.registry.entries)
    if ($entries.Count -eq 0) {
        # Before setup has run, /annex is not a linked skill, so naming it here sends a
        # new reader after a command that does not exist. The first-run banner above already
        # named the one step that works.
        $next = if ($script:NotSetUp) { 'set it up first' } else { 'a project is registered with /annex' }
        if ($snap.registry.present) {
            Add-Line "  Projects: none registered - nothing can be dispatched until $next."
        } else {
            Add-Line "  Projects: no registry at $RegistryPath - nothing can be dispatched until $next."
        }
    } else {
        Add-Line "  Projects: $($entries.Count) registered"
        Add-BoundedList -Items @($entries | ForEach-Object {
            $pathNote = if ($_.pathExists) { $_.path } else { "$($_.path) - PATH MISSING" }
            "- $($_.name) [$($_.rawMode)] yolo $($_.yolo) - $pathNote"
        })
    }

    # Workers: stage is intent from crew.json, liveness is the join with herdr's agent list.
    # Unknown liveness is printed as unknown, never as dead - only a join that ran can say dead.
    # The agent word appended after the slash is herdr's (idle, working, blocked, done, unknown)
    # corrected by the worker's own screen, and `idle` there means "not mid-turn", never
    # "finished" - a worker reads idle from the moment it starts.
    $workers = @($snap.crew.workers)
    if ($workers.Count -eq 0) {
        Add-Line '  Workers: none recorded.'
    } else {
        Add-Line "  Workers: $($workers.Count) recorded"
        Add-BoundedList -Items @($workers | ForEach-Object {
            $liveText = if ($null -eq $_.live) { 'liveness unknown' } elseif ($_.live) { 'live' } else { 'not live' }
            $agent    = Get-Field $_ 'agentState'
            if ($agent) { $liveText += "/$agent" }
            $rep = if ($_.hasReport) { ', report on disk' } else { '' }
            "- $($_.id) $($_.ticket) ($($_.repo)) stage $($_.stage), $liveText$rep"
        })
    }

    $undispatched = @($snap.data.undispatched)
    if ($undispatched.Count -eq 0) {
        Add-Line '  Un-dispatched briefs: none.'
    } else {
        Add-Line "  Un-dispatched briefs: $($undispatched.Count)"
        Add-BoundedList -Items @($undispatched | ForEach-Object {
            $when = Get-Field $_ 'briefModified'
            if ($when) { "- $($_.id) - brief written $when" } else { "- $($_.id)" }
        })
    }

    # A report survives teardown, so a report on disk is readable work even where the worker is
    # long gone. Paths only: reading one is a deliberate act, not something session start does.
    $reports = @(@($workers | Where-Object { $_.hasReport }) + @($undispatched | Where-Object { $_.hasReport }))
    if ($reports.Count -eq 0) {
        Add-Line '  Reports available: none.'
    } else {
        Add-Line "  Reports available: $($reports.Count)"
        Add-BoundedList -Items @($reports | ForEach-Object { "- $($_.id): $($_.reportPath)" })
    }

    foreach ($d in @($snap.diagnostics)) {
        if ($d) { Add-Line ("  FLEET: " + (Format-Fault "$d")) }
    }
} catch {
    Add-Line ("  FLEET: could not read the fleet - " + (Format-Fault $_.Exception.Message))
}

# --------------------------------------------------------------------------------
# 3. Queue - what is queued and what is held, from the backlog that belongs to
#    QueueRoot. Held work is included because a hold nobody sees at session open is
#    the invisibility the backlog exists to remove.
# --------------------------------------------------------------------------------
Add-Line ''
Add-Line "QUEUE  (tasks-axi ready --include-held, from $QueueRoot)"
try {
    if (-not (Get-Command tasks-axi -ErrorAction SilentlyContinue)) {
        Add-Line '  QUEUE: tasks-axi is not on PATH, so the backlog was not read.'
    } elseif (-not (Test-PathQuiet $QueueRoot)) {
        Add-Line "  QUEUE: $QueueRoot does not exist, so the backlog was not read."
    } else {
        $previous = Get-Location
        try {
            Set-Location -LiteralPath $QueueRoot
            $queueOut = @(& tasks-axi ready --include-held 2>&1 | ForEach-Object { "$_" })
        } finally {
            Set-Location -LiteralPath $previous
        }

        $queueOut = @($queueOut | Where-Object { $_.Trim() })
        if ($queueOut.Count -eq 0) {
            Add-Line '  QUEUE: the backlog reader returned nothing.'
        } else {
            Add-BoundedList -Items $queueOut -Indent '  '
        }
    }
} catch {
    Add-Line ("  QUEUE: could not read the backlog - " + (Format-Fault $_.Exception.Message))
}

# --------------------------------------------------------------------------------
# 4. Index - where the data index is, how much it covers, and how far it has drifted
#    from what is actually on disk. Names and counts only, never contents: the index
#    is itself a table of contents, and a session that needs one of the files opens
#    it at brief-writing time rather than paying for it here.
#
#    Drift is the load-bearing number. A settled brand spec sat in data\ and the site
#    shipped without it, because nothing made anyone read the file - "this file is
#    listed nowhere" is a fact a machine can notice, where "somebody should have
#    realised this mattered" never was.
#
#    Silent when there is no index and nothing to index, exactly as the toolchain
#    check is when it is clean. That is a fresh installation, not a fault.
# --------------------------------------------------------------------------------
try {
    Import-Module (Join-Path $PSScriptRoot 'Index.psm1') -Force -ErrorAction Stop
    $drift = Get-IndexDrift -DataPath $DataPath

    $indexCount     = @($drift.indexes).Count
    $unindexedCount = @($drift.unindexed).Count
    $missingCount   = @($drift.missing).Count

    if ($indexCount -gt 0 -or $unindexedCount -gt 0) {
        Add-Line ''
        Add-Line "INDEX  ($DataPath\index.md, and index\<project>.md per project)"
        if ($indexCount -gt 0) {
            $files   = if ($drift.indexed -eq 1) { 'file' }  else { 'files' }
            $indexes = if ($indexCount -eq 1)    { 'index' } else { 'indexes' }
            Add-Line ("  $($drift.indexed) $files listed across $indexCount $indexes - read the one " +
                      'for a project before writing a brief against it.')
        } else {
            Add-Line '  No index exists yet.'
        }
        if ($unindexedCount -gt 0) {
            $files = if ($unindexedCount -eq 1) { 'file is' } else { 'files are' }
            Add-Line "  UNINDEXED: $unindexedCount $files listed nowhere. Index each as you touch it."
        }
        if ($missingCount -gt 0) {
            $files = if ($missingCount -eq 1) { 'file is' } else { 'files are' }
            Add-Line ("  STALE: $missingCount indexed $files no longer on disk. Clear with " +
                      'Remove-IndexEntry -Missing -All.')
        }
    }
} catch {
    Add-Line ''
    Add-Line ("INDEX: could not be read - " + (Format-Fault $_.Exception.Message))
}

# --------------------------------------------------------------------------------
# 5. Context - the King's standing instructions and the two curated memory files, in
#    full and clearly delimited. This is the part that makes a restart a non-event,
#    so it is the one place the digest prints file bodies rather than facts about
#    them. instructions.md comes first on purpose: what the King stated outranks what
#    the Hand inferred, and reading it after the inferences invites the reverse.
# --------------------------------------------------------------------------------
Add-Line ''
Add-Line 'CONTEXT'

function Add-ContextFile {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$AbsentMeans
    )
    Add-Line ''
    Add-Line "----- BEGIN $Name ($Path) -----"
    try {
        if (-not (Test-PathQuiet $Path)) {
            # ABSENT is a fact with a meaning, and it is not the same fact as an empty file. One
            # says nothing has been recorded yet; the other says someone recorded nothing.
            Add-Line "ABSENT - $AbsentMeans"
        } else {
            $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
            if ([string]::IsNullOrWhiteSpace($raw)) {
                Add-Line 'EMPTY - the file exists but holds no content.'
            } else {
                foreach ($line in ($raw -replace "`r`n", "`n").TrimEnd("`n").Split("`n")) { Add-Line $line }
            }
        }
    } catch {
        Add-Line ("UNREADABLE - " + (Format-Fault $_.Exception.Message))
    }
    Add-Line "----- END $Name -----"
}

# The King's own words, and the only file here the Hand may not rewrite. Its absence is a state
# like any other - the King has stated no standing preferences - and never a reason to create one.
Add-ContextFile -Name 'instructions.md' -Path $InstructionsPath `
    -AbsentMeans 'the King has stated no standing instructions. Read it, never write it.'
Add-ContextFile -Name 'king.md' -Path (Join-Path $DataPath 'king.md') `
    -AbsentMeans 'nothing has been recorded about how the King works yet.'
Add-ContextFile -Name 'learnings.md' -Path (Join-Path $DataPath 'learnings.md') `
    -AbsentMeans 'no operational learnings have been recorded yet.'

# The budget is a signal, not a gate: the files above are printed whatever the total comes to, and
# an overrun says so with the numbers and names the one thing that curates it back down.
Add-Line ''
try {
    Import-Module (Join-Path $PSScriptRoot 'Memory.psm1') -Force -ErrorAction Stop
    $report = Get-MemoryReport -DataPath $DataPath -BudgetPath $BudgetPath
    if ($report.overBudget) {
        $over = $report.total - $report.budget
        Add-Line ("STARTUP_MEMORY_BUDGET: $($report.total) estimated tokens against a budget of " +
                  "$($report.budget), over by $over. Run /chronicle to curate it back down. Both files " +
                  "are printed above regardless - the budget is a signal, not a gate.")
    } else {
        Add-Line "  Startup memory: $($report.total) of $($report.budget) estimated tokens."
    }
} catch {
    Add-Line ("STARTUP_MEMORY_BUDGET: could not be accounted - " + (Format-Fault $_.Exception.Message))
}

Add-Line ''
if ($script:NotSetUp) {
    Add-Line 'Nothing above is configured yet. The one useful next step is "set it up".'
    Add-Line ''
}
Add-Line 'Read this digest once and trust it as this session''s startup input.'
Add-Line 'Do not separately re-read the registry, the queue, the fleet or the context files it just'
Add-Line 'printed unless one of them was reported absent or corrupt, or a targeted piece of work must'
Add-Line 'inspect before writing. The digest is orientation and durable record; liveness still comes'
Add-Line 'from herdr, read when it matters rather than assumed from a line printed at session open.'
Add-Line '=== END KINGSHAND SESSION START ==='

$digest = ($script:Lines -join "`n")

if ($Json) {
    # The SessionStart hook envelope: the digest reaches the session as additional context rather
    # than as console output nobody reads.
    [pscustomobject]@{
        hookSpecificOutput = [pscustomobject]@{
            hookEventName     = 'SessionStart'
            additionalContext = $digest
        }
    } | ConvertTo-Json -Depth 5 -Compress
} else {
    $digest
}
