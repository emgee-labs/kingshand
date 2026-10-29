#Requires -Version 7.0
<#
.SYNOPSIS
  The once-per-session digest: this installation's version, toolchain problems, fleet state, what
  a restart killed and has to be re-armed, the queue, whether the weekly dependency check is due on
  a maintainer's installation, whether a newer release exists, where the data index is and how far
  it has drifted, the King's own standing instructions, and the two curated memory files, rendered
  as one block a session can read and trust.
.DESCRIPTION
  This is operational input, not a report. It runs from a SessionStart hook and its whole purpose
  is to make a restart a non-event: everything a fresh session needs to orient itself is printed
  once, so nothing has to be rediscovered by re-reading the same files a second time.

  Deliberately NOT a second `survey`. Survey is an on-demand, curated four-section answer to
  "what needs me", asked for by the user and rendered with judgement. This is a mechanical dump of
  startup facts nobody asked for, read once at session open. Neither calls the other, and nothing
  runs survey on the user's behalf.

  BOUNDED BY THE HARNESS'S INLINE LIMIT, which the constant near the top owns. A digest over it is
  cut to a preview, so this one is built to fit: `instructions.md` whole and first; every AWAY,
  RE-ARM and toolchain line; the projects, workers and queue items with something live or waiting
  on the King, and counts for the rest; and each memory file whole only where Memory.psm1 says the
  room is left, named in one line where it is not. A digest that is over anyway says so on its first
  line. The index section is where the index is and how far it has drifted, never what any indexed
  file says.

  The RE-ARM section is the one that is about what ISN'T there. A background job belongs to the
  session that armed it, so a restart takes the usage pulse and every review-surface poll with it
  while the things they were watching carry on - and both failures are invisible by construction.
  A changed-only pulse that has stopped reads exactly like a pulse with nothing to say, and a
  surface whose poll is gone reads exactly like a King who has not answered yet. Nothing about
  either is visible in the fleet, which is why they are printed rather than left to be remembered.

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
.PARAMETER VersionPath
  the VERSION file at the repo root - this installation's version. One line of the digest.
.PARAMETER LavishStatePath
  lavish-axi's own session store - `state.json` under `LAVISH_AXI_STATE_DIR`, or `~\.lavish-axi`
  where that is unset, which is the tool's own documented pair. Read, never written, and the only
  thing taken out of it is which review surfaces under DataPath are holding feedback nobody has
  collected. The tool has no command that lists its sessions, so this file is the one place that
  answer exists; it is JSON the tool writes to its own schema, which is why reading it is a parse
  of a bounded format rather than a scan of an open-ended one.
.PARAMETER MaintainerPath
  config\maintainer - the machine-local marker saying this installation is a maintainer's. Present,
  the weekly dependency check is asked about; absent, it is never mentioned. Read, never written.
.PARAMETER ReleaseRepoPath
  the checkout whose VERSION, branch and origin remote the new-release notice reads - this
  installation's root.
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
    [string]$VersionPath,
    [string]$LavishStatePath,
    [string]$MaintainerPath,
    [string]$ReleaseRepoPath,
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
if (-not $MaintainerPath)   { $MaintainerPath   = Join-Path $script:Root 'config\maintainer' }
if (-not $ReleaseRepoPath)  { $ReleaseRepoPath  = $script:Root }

# lavish-axi's own store, resolved exactly the way the tool resolves it: LAVISH_AXI_STATE_DIR when
# it is set, and the home directory otherwise. Both are the tool's own documented pair rather than
# a guess, so a machine that moves the store keeps being read correctly.
#
# THIS IS THE THIRD THING IN THIS REPOSITORY TO REACH INTO THE USER PROFILE, and the exception is
# named here as the other two are. The store has no per-project alternative and the tool ships no
# command that lists its sessions, so this file is where "which surfaces are still holding an
# answer" exists at all. It is opened read-only and nothing else in that directory is touched.
#
# Empty rather than guessed at when there is no home to resolve against. A store path invented here
# would be a path that reliably holds nothing, which reads as "no surface is waiting" - the one
# answer this section must never give without having looked.
if (-not $LavishStatePath) {
    $lavishStateDir = $env:LAVISH_AXI_STATE_DIR
    if (-not $lavishStateDir -and $env:USERPROFILE) {
        $lavishStateDir = Join-Path $env:USERPROFILE '.lavish-axi'
    }
    if ($lavishStateDir) { $LavishStatePath = Join-Path $lavishStateDir 'state.json' }
}

$script:Lines    = [System.Collections.Generic.List[string]]::new()
$script:DefaultListCap = 25
$script:ListCap  = $script:DefaultListCap
# Workers are capped tighter than other lists, because each line is long and the ones past the cap
# are the least urgent: the list is sorted live first, then recorded as working, then waiting. A
# live worker is never cut, because Recovery re-arms a watch on every live worker this list names.
$script:WorkerCap = 8

# THE HARNESS'S INLINE LIMIT, AND THE NUMBER THIS WHOLE DIGEST IS BUILT AROUND. Claude Code caps a
# hook's `additionalContext` at 10,000 characters. Over it, the text is saved to a file and the
# session gets the path and a preview of the first 2,000 characters instead - and nothing asks the
# session to open the file. That is from Claude Code's hooks documentation ("A hook's
# additionalContext, systemMessage, and initialUserMessage strings, and its plain stdout, are capped
# at 10,000 characters"), it has no setting to raise it, and it is what happened to every digest
# measured between 2026-10-02 and 2026-10-22: 39.9k to 52.0k characters each, every one cut to a
# preview, and two sessions that never read the saved file ran without the King's instructions.
#
# Measured on the string itself, which is the envelope's `additionalContext` - the JSON around it
# is not counted against the cap, but every character inside it is.
$script:InlineLimit = 10000

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

# Whether one path sits inside another, compared as paths rather than as text. Both sides are
# normalised first, because the session store holds whatever absolute path was passed to the tool
# and this installation's data\ arrives from a parameter - the same directory can be spelled two
# ways and still be the same directory. A path that will not normalise is not inside anything.
function Test-PathUnder {
    param([string]$Path, [string]$Root)
    try {
        if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($Root)) { return $false }
        $p = [System.IO.Path]::GetFullPath($Path)
        $r = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/') +
             [System.IO.Path]::DirectorySeparatorChar
        return $p.StartsWith($r, [System.StringComparison]::OrdinalIgnoreCase)
    } catch {
        return $false
    }
}

# How many prompts are queued on one session - or -1 for a count that could not be read.
#
# THE NEGATIVE IS THE POINT AND IT IS NOT A COUNT. Zero is the tool saying nobody has sent
# anything, which is a settled fact this section is allowed to be quiet about. A field that is
# absent, or holds something that is not a whole number, is the tool not answering - and reading
# that as zero would drop a surface holding the King's own reply out of the digest entirely, with
# nothing said to anybody. The caller lists both and tells them apart in the line it prints.
function Get-QueuedPromptCount {
    param($Row)
    $n = 0
    if ([int]::TryParse((Get-Field $Row 'pending_prompts'), [ref]$n) -and $n -ge 0) { return $n }
    -1
}

# How many artifact failures one session is holding - or -1 for a list that could not be read.
#
# The second half of the tool's own condition, and it is read here for the same reason the first
# half is: `takeFeedback` returns `ended` only where the queued prompts AND the artifact failures
# are both empty, and returns the feedback otherwise. A row with a failure on it and nothing queued
# still has something a single poll would deliver, so it is not "nothing to collect".
#
# Read as defensively as the count above. The tool writes a JSON array; anything else - a field
# that is absent, null, or some other shape - is the tool not answering, which keeps the row.
function Get-ArtifactFailureCount {
    param($Row)
    try {
        if ($null -eq $Row) { return -1 }
        $p = $Row.PSObject.Properties['artifact_failures']
        if (-not $p) { return -1 }
        $v = $p.Value
        if ($null -eq $v -or $v -is [string]) { return -1 }
        if ($v -is [System.Collections.IEnumerable]) { return @($v).Count }
        return -1
    } catch {
        return -1
    }
}

# When the tool last touched one session, as an instant anybody can read the same way.
#
# ConvertFrom-Json turns the store's timestamps into DateTime objects, and stringifying one of
# those renders it in whatever date format the machine is set to - 09/02/2026 is two different days
# depending on who is reading it. Rendered here to a single unambiguous shape instead, and a value
# that is not a time at all is passed through as the tool wrote it rather than reformatted into
# something this cannot stand behind.
function Get-SessionStamp {
    param($Row)
    $v = $null
    try {
        $p = $Row.PSObject.Properties['updated_at']
        if ($p) { $v = $p.Value }
    } catch { }

    if ($v -is [datetime])       { return ([datetimeoffset]$v).ToUniversalTime().ToString('u') }
    if ($v -is [datetimeoffset]) { return $v.ToUniversalTime().ToString('u') }
    $t = "$v".Trim()
    if ($t) { return $t }
    'last touched not given'
}

# One review surface as one line: what is on it, the tool's own status word, when it was last
# touched, and the absolute path a poll takes. Shared by both surface lists, because the two differ
# in what the reader should do next and in nothing about the row itself.
function Format-SurfaceLine {
    param($Row)
    # An unreadable count is said as unreadable. It is listed either way, because the one thing
    # that cannot be concluded from a count nobody could read is that there is nothing there.
    $n      = Get-QueuedPromptCount $Row
    $queued = if ($n -lt 0) { 'queued count unreadable' } else { "$n queued" }

    # Silent when the tool says there are none, because that is the ordinary row and saying "0
    # artifact failures" on every line buries the one that has some.
    $a = Get-ArtifactFailureCount $Row
    $failed = if ($a -lt 0)     { ', artifact failures unreadable' }
              elseif ($a -eq 1) { ', 1 artifact failure' }
              elseif ($a -gt 0) { ", $a artifact failures" }
              else              { '' }

    # The tool's own status word, passed through rather than translated. This digest does not own
    # that vocabulary and must not invent a meaning for it.
    $status = Get-Field $Row 'status' 'status not given'

    # The path is never a fallback. A row reaches a list only by having a file that resolves inside
    # DataPath, so there is always one to print, and a row naming no file at all could not have
    # been matched to this installation in the first place - it is not counted rather than counted
    # without a path.
    "- $queued$failed, status $status, $(Get-SessionStamp $Row) - $(Get-Field $Row 'file')"
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
# 0a. The King's standing instructions, whole and FIRST. What the King stated outranks
#     everything below it, and it is the one file here that is never cut, never
#     summarised and never only named: the pulse's off switch lives in it, and a
#     session that ran without it ran without his word. First, too, because if the
#     digest is ever over the inline limit the preview the harness keeps is its start.
# --------------------------------------------------------------------------------
Add-Line ''
Add-Line 'CONTEXT'
Add-Line ''
Add-Line "----- BEGIN instructions.md ($InstructionsPath) -----"
try {
    if (-not (Test-PathQuiet $InstructionsPath)) {
        # ABSENT is a fact with a meaning, and it is not the same fact as an empty file. The King
        # has stated no standing preferences - and that is never a reason to create one.
        Add-Line 'ABSENT - the King has stated no standing instructions. Read it, never write it.'
    } else {
        $raw = Get-Content -LiteralPath $InstructionsPath -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) {
            Add-Line 'EMPTY - the file exists but holds no content.'
        } else {
            foreach ($line in ($raw -replace "`r`n", "`n").TrimEnd("`n").Split("`n")) { Add-Line $line }
        }
    }
} catch {
    Add-Line ("UNREADABLE - " + (Format-Fault $_.Exception.Message))
}
Add-Line '----- END instructions.md -----'

# --------------------------------------------------------------------------------
# 0b. Version - which release this copy is, in one line.
#
#     A user who cannot say which version they are on cannot say whether a fix
#     they were promised is in it, and `git log` is not an answer anyone should
#     have to give. It is one line rather than a section because that is the whole
#     fact; `bin\Version.psm1` owns the file and what an unreadable one means.
#
#     The module import and the path default both live in here rather than at the
#     top with the others, because this digest must never throw: a missing module
#     costs this one line and nothing else.
# --------------------------------------------------------------------------------
Add-Line ''
try {
    Import-Module (Join-Path $PSScriptRoot 'Version.psm1') -Force -ErrorAction Stop
    if (-not $VersionPath) { $VersionPath = Get-VersionFilePath -Root $script:Root }
    Add-Line ("VERSION: " + (Get-KingshandVersion -Path $VersionPath))
} catch {
    # Unreadable reads as unreadable. A version invented here would be quoted back by the reader
    # as the one they are running.
    Add-Line ("VERSION: unreadable - " + (Format-Fault $_.Exception.Message))
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
# The queue is READ here, ahead of the fleet, because the fleet names every project
# with a decision of the King's held in it; it is PRINTED in its own section below.
#
# tasks-axi answers in TOON, and the answer carries titles and hold reasons that are
# free text somebody wrote, so it is decoded by the TOON reference implementation
# GateRun.psm1 already vendors - never split by hand. What is taken out of it is a
# closed set: the `count` of ready work, and the `held` rows' `id`, `repo` and
# `hold_kind`. A hold of kind `captain` is a decision waiting on the King.
#
# An answer that will not decode is not an empty queue, and is said as unreadable.
# A `held` group that is not there is none held: tasks-axi omits a group it has
# nothing for, as it does on an empty backlog.
# --------------------------------------------------------------------------------
$script:Queue = [pscustomobject]@{ ok = $false; error = ''; ready = 0; held = @(); captain = @() }
try {
    if (-not (Get-Command tasks-axi -ErrorAction SilentlyContinue)) {
        $script:Queue.error = 'tasks-axi is not on PATH, so the backlog was not read.'
    } elseif (-not (Test-PathQuiet $QueueRoot)) {
        $script:Queue.error = "$QueueRoot does not exist, so the backlog was not read."
    } else {
        $previous = Get-Location
        try {
            Set-Location -LiteralPath $QueueRoot
            $queueOut = @(& tasks-axi ready --include-held 2>$null | ForEach-Object { "$_" })
        } finally {
            Set-Location -LiteralPath $previous
        }
        Import-Module (Join-Path $PSScriptRoot 'GateRun.psm1') -Force -ErrorAction Stop
        $decoded = ConvertFrom-ToonText -Text ($queueOut -join "`n")
        if (-not $decoded.ok) {
            $script:Queue.error = ('the backlog answered in a form this digest could not decode (' +
                                   (Format-Fault "$($decoded.error)") + ')')
        } else {
            $doc = $decoded.value | ConvertFrom-Json
            $n = 0
            if (-not [int]::TryParse((Get-Field $doc 'count'), [ref]$n)) {
                $script:Queue.error = 'the backlog answer carried no count of ready work'
            } else {
                $held = @()
                if ($doc.PSObject.Properties['held'] -and $doc.held -isnot [string]) { $held = @($doc.held) }
                $script:Queue.ok      = $true
                $script:Queue.ready   = $n
                $script:Queue.held    = $held
                $script:Queue.captain = @($held | Where-Object { (Get-Field $_ 'hold_kind') -eq 'captain' })
            }
        }
    }
} catch {
    $script:Queue.error = 'could not read the backlog - ' + (Format-Fault $_.Exception.Message)
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
#
# The flag's shape is read in ONE place, `AwayJournal.psm1`, because that module turns its `since:`
# into the away journal's file name. A second reader here would be the copy that drifts, and the
# two disagreeing means a digest naming one away period and a journal holding another.
$afkFlag = Join-Path (Split-Path $StatePath -Parent) '.afk'
try {
    Import-Module (Join-Path $PSScriptRoot 'AwayJournal.psm1') -Force -ErrorAction Stop
    $afk = Get-AwayFlag -FlagPath $afkFlag -DataPath $DataPath
    if ($afk.present) {
        $since = if ($afk.since) { ' (since: ' + $afk.since + ')' } else { '' }
        Add-Line "  AWAY: a regency is in force$since - load ``regency``. The King is not at the machine."
        Add-Line ('        Batch everything that does not need them, answer a worker''s prompt only on a ' +
                  'personal project and inside its brief - on an office project it waits - and a ' +
                  'decision a worker wrote into its report is decided under `petition`.')
        if ($afk.problem) {
            Add-Line ('        NO JOURNAL: ' + (Format-Fault $afk.problem) +
                      ' Nothing can be recorded for this away period until that is fixed.')
        }
    }
} catch {
    # The flag is durable state nothing else surfaces, so a reader that fell over has to say so
    # rather than leave the section silent - silence here reads as a King who is at the machine.
    if (Test-PathQuiet $afkFlag) {
        Add-Line ("  AWAY: a regency flag exists at $afkFlag and could not be read - " +
                  (Format-Fault $_.Exception.Message) + " Load ``regency`` and treat the King as away.")
    }
}

try {
    $snapshotScript = Join-Path $PSScriptRoot 'Get-SurveySnapshot.ps1'
    if (-not (Test-PathQuiet $snapshotScript)) { throw "Get-SurveySnapshot.ps1 is not at $snapshotScript." }

    $snap = & $snapshotScript -RegistryPath $RegistryPath -DataPath $DataPath -StatePath $StatePath

    # ONLY WHAT IS LIVE OR WAITING ON THE KING IS NAMED; EVERYTHING ELSE IS COUNTED. The digest has
    # to arrive whole - the inline limit at the top of this script owns why - and a fleet printed in
    # full was a quarter of everything this digest ever was: 25 projects with their paths, 227
    # worker records of which 161 had landed, and 227 report paths nobody was asked to open.
    # `survey` and Get-CrewStatus still list the rest whenever someone asks.
    #
    # A worker is live or waiting when herdr reads it live, or when its stage is not over - whatever
    # its liveness, so unknown is never read as dead: `dispatched` and `implementing` are recorded as
    # working, which a
    # worker that is not live needs `rally` for, and `gating` and `ready` wait on the King. Only
    # `landed` and `failed` are over. Live ones come first, then the ones recorded as working, then
    # the ones waiting on approval, so the cap below cuts the least urgent.
    $workers  = @($snap.crew.workers)
    $isLive   = { param($w) $w.live -eq $true }
    $isOver   = { param($w) "$($w.stage)" -in @('landed', 'failed') }
    $rank     = { param($w)
        if (& $isLive $w) { 0 } elseif ("$($w.stage)" -in @('dispatched', 'implementing')) { 1 } else { 2 } }
    $active   = @($workers | Where-Object { (& $isLive $_) -or -not (& $isOver $_) } |
                  Sort-Object -Stable { & $rank $_ })

    # Projects: listed where something is live or waiting - a worker above, a hold on a decision of
    # the King's in the queue - or where the entry itself is broken, because a path that is gone or a
    # name the index cannot resolve fails the next brief for it. Name and posture only; the path is
    # in the registry, and muster reads the entry when it dispatches.
    $entries = @($snap.registry.entries)
    if ($entries.Count -eq 0) {
        # Before setup has run, /annex is not a linked skill, so naming it here sends a
        # new reader after a command that does not exist. The first-run banner above already
        # named the one step that works.
        $next = if ($script:NotSetUp) { '"set it up" has run first' } else { 'a project is registered with /annex' }
        if ($snap.registry.present) {
            Add-Line "  Projects: none registered - nothing can be dispatched until $next."
        } else {
            Add-Line "  Projects: no registry at $RegistryPath - nothing can be dispatched until $next."
        }
    } else {
        $busy = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($w in $active) { if ("$($w.repo)") { $null = $busy.Add("$($w.repo)") } }
        foreach ($h in $script:Queue.captain) { if ("$($h.repo)") { $null = $busy.Add("$($h.repo)") } }

        $shown = @($entries | Where-Object {
            $busy.Contains("$($_.name)") -or $busy.Contains("$($_.path)") -or
            -not $_.pathExists -or -not $_.indexable
        })
        $yoloOn = @($entries | Where-Object { "$($_.yolo)" -eq 'on' }).Count
        $merge  = @($entries | Where-Object { "$($_.merge)" -eq 'on' }).Count
        Add-Line ("  Projects: $($entries.Count) registered, $yoloOn proceeding without asking, " +
                  "$merge allowed to merge - $($shown.Count) with something live or waiting:")
        Add-BoundedList -Items @($shown | ForEach-Object {
            $pathNote = if ($_.pathExists) { '' } else { " - PATH MISSING: $($_.path)" }
            # A hand-written name the index cannot resolve fails one brief at a time, always after
            # the brief is on disk, so it is said here rather than discovered there.
            $nameNote = if ($_.indexable) { '' } else { ' - NAME NOT INDEXABLE: rename it, or nothing written for it can be listed' }
            # Standing authority to merge that project's own green pull requests, which on a
            # deploy-on-merge default branch is a live production release. Said only where it is
            # held, so the common case prints exactly as it always has.
            $mergeNote = if ($_.merge -eq 'on') { ' +merge' } else { '' }
            # Night's watch's own merge permission, said only where it is held, like +merge.
            if ((Get-Field $_ 'watchMerge') -eq 'on') { $mergeNote += ' +watch-merge' }
            "- $($_.name) [$($_.rawMode)] yolo $($_.yolo)$mergeNote$pathNote$nameNote"
        })
        if ($shown.Count -lt $entries.Count) {
            Add-Line "    ... and $($entries.Count - $shown.Count) more with nothing live or waiting - the registry lists them."
        }
    }

    # Workers: stage is intent from crew.json, liveness is the join with herdr's agent list.
    # Unknown liveness is printed as unknown, never as dead - only a join that ran can say dead.
    # The agent word appended after the slash is herdr's (idle, working, blocked, done, unknown)
    # corrected by the worker's own screen, and `idle` there means "not mid-turn", never
    # "finished" - a worker reads idle from the moment it starts.
    #
    # A worker parked on a decision the King owes settles cleanly, so it is live and `idle` and
    # prints identically to one still working. crew.json's `waiting_on` pointer is what names the
    # decision it stopped on, so the line carries it: the digest is this session's whole picture of
    # the fleet, and a worker waiting on an answer must not read as a worker making progress.
    #
    # THE LINE SAYS "last parked on" AND NOT "parked on", AND THE WORD IS LOAD-BEARING. The pointer
    # is never cleared, so it keeps naming that key for the rest of the worker's life - including
    # long after the decision was answered and applied. Asserting a live park here would tell the
    # King a decision is waiting on him that he settled hours ago. The QUEUE section below is what
    # says which holds are still open, so the line names the key and leaves the open-or-closed half
    # to the source that owns it.
    if ($workers.Count -eq 0) {
        Add-Line '  Workers: none recorded.'
    } else {
        $over = @($workers | Where-Object { -not (& $isLive $_) -and (& $isOver $_) })
        $landed = @($over | Where-Object { "$($_.stage)" -eq 'landed' }).Count
        $failed = $over.Count - $landed
        Add-Line ("  Workers: $($workers.Count) recorded - $($active.Count) live or not finished, " +
                  "$landed landed and $failed failed, none of them read live. Get-CrewStatus lists them all.")
        $script:ListCap = [Math]::Max($script:WorkerCap, @($active | Where-Object { & $isLive $_ }).Count)
        Add-BoundedList -Items @($active | ForEach-Object {
            $liveText = if ($null -eq $_.live) { 'liveness unknown' } elseif ($_.live) { 'live' } else { 'not live' }
            $agent    = Get-Field $_ 'agentState'
            if ($agent) { $liveText += "/$agent" }
            $rep = if ($_.hasReport) { ', report on disk' } else { '' }
            $held = Get-Field $_ 'waitingOn'
            $park = if ($held) { ", last parked on decision $held" } else { '' }
            # A `fief` session's warm worker is one line naming every id on its branch, in order,
            # where an ordinary worker names its one ticket. A list that could not be read says so
            # rather than printing as a session with nothing on it.
            # The ticket is said only where it differs from the id, which it usually does not.
            $what = if ("$($_.ticket)" -and "$($_.ticket)" -ne "$($_.id)") { "$($_.ticket) " } else { '' }
            if ((Get-Field $_ 'session') -eq 'True') {
                $ids = @(@(try { $_.items } catch { @() }) | Where-Object { $_ })
                $err = Get-Field $_ 'itemsError'
                $on  = Get-Field $_ 'branch'
                $where = if ((Get-Field $_ 'checkout') -eq 'True') { " in the checkout on $on" } elseif ($on) { " on $on" } else { '' }
                $what = if ($err) { "session worker$where, items unreadable ($err) " }
                        else { "session worker$where carrying $($ids -join ', ') " }
            }
            "- $($_.id) $what($($_.repo)) stage $($_.stage), $liveText$park$rep"
        })
        $script:ListCap = $script:DefaultListCap
    }

    # Counted, never listed: a brief nobody dispatched is the King's to raise, and survey names them.
    $undispatched = @($snap.data.undispatched)
    Add-Line ("  Un-dispatched briefs: " + $(if ($undispatched.Count -eq 0) { 'none.' }
                                             else { "$($undispatched.Count) - survey names them." }))

    # A report survives teardown, so a report on disk is readable work even where the worker is
    # long gone. Counted here, and flagged on the worker lines above; reading one is a deliberate
    # act, not something session start does, and every one is at data\<id>\report.md.
    $reports = @(@($workers | Where-Object { $_.hasReport }) + @($undispatched | Where-Object { $_.hasReport }))
    Add-Line ("  Reports available: " + $(if ($reports.Count -eq 0) { 'none.' }
                                          else { "$($reports.Count), each at data\<id>\report.md." }))

    foreach ($d in @($snap.diagnostics)) {
        if ($d) { Add-Line ("  FLEET: " + (Format-Fault "$d")) }
    }
} catch {
    Add-Line ("  FLEET: could not read the fleet - " + (Format-Fault $_.Exception.Message))
}

# --------------------------------------------------------------------------------
# 2b. Re-arm - the background jobs the last session took with it.
#
#     A background job belongs to the session that armed it. A restart kills the
#     usage pulse and every review-surface poll along with the worker waits, and
#     unlike a dead worker neither leaves a mark: the pulse is changed-only, so one
#     that has stopped is indistinguishable from one with nothing to say, and a
#     surface whose poll is gone is indistinguishable from a King who has not
#     answered yet. The King has twice reported the first as "no tokens, no
#     updates", which is what an invisible failure looks like from his side.
#
#     The worker waits are the third of the three and are deliberately NOT repeated
#     here. FLEET above already names every live worker, and CLAUDE.md's Recovery
#     section owns what to do with them - saying it twice is two places to correct.
#
#     NOTHING HERE DECIDES WHETHER THE PULSE SHOULD RUN. The King turns it off by
#     writing a line in his own standing instructions, which this digest prints
#     whole at the top, and the Hand honours it by having read them. A script
#     matching a phrase in free prose somebody wrote by hand is the open-ended
#     scanner the standing criteria forbid, so the command is printed unconditionally
#     and the judgement stays with the reader.
# --------------------------------------------------------------------------------
Add-Line ''
Add-Line 'RE-ARM  (a restart kills every background job the last session armed)'
Add-Line '  Pulse: arm it once, as a harness-tracked background job:'
# Quoted, because this block is printed to be copied and run and an installation root is allowed to
# have a space in it - `C:\Users\John Smith\kingshand` is an ordinary place to keep a clone, and
# unquoted it binds as two arguments and fails on a positional parameter. The failure is the one
# this whole section exists against: the command errors at session open, the pulse is never armed,
# and the silence that follows is indistinguishable from a changed-only pulse with nothing to say.
# A quote inside the path is doubled for the same reason - it is the only other character that
# could end the string early.
Add-Line ("      Import-Module '" + (Join-Path $script:Root 'bin\Usage.psm1').Replace("'", "''") + "'")
Add-Line '      Watch-UsagePulse'
Add-Line '    It runs until the session ends rather than for a set number of ticks, and it speaks'
Add-Line '    only when something has changed - so say in one line that it is on, because a quiet'
Add-Line '    pulse and a dead one look the same from the outside.'
Add-Line '    Whether to arm it at all is yours, from having read instructions.md above. Nothing'
Add-Line '    here reads that file and nothing here decides it.'

# WHICH SURFACES ARE STILL HOLDING AN ANSWER, TAKEN FROM THE TOOL'S OWN STORE.
#
# lavish-axi ships no command that lists its sessions, so its store is the one place this answer
# exists. It is JSON the tool writes to its own schema and it is parsed as JSON, which is what
# keeps this a read of a bounded format rather than a scan of an open-ended one.
#
# SOMETHING UNCOLLECTED IS THE SIGNAL, NOT AN OPEN SESSION, and the difference is the whole design.
# Nothing ends a session once its decision is settled, so `open` accumulates for good - dozens of
# them on this machine, every one of them looking identical to a decision raised this morning.
# A prompt queued and uncollected is the opposite: it is the exact failure this section exists for,
# it is the King's own answer sitting where nobody is listening, and it clears the moment it is
# collected.
#
# THE TOOL'S OWN CONDITION IS MIRRORED RATHER THAN SUMMARISED. `takeFeedback` reports `ended` only
# where the queued prompts and the artifact failures are BOTH empty; with either of them holding
# something it returns that feedback instead, carrying `session_ended` alongside, and the poll
# route calls it at once rather than waiting. So a session that has ended while still holding a
# queued prompt is not a dead end - it is a Send & End whose final answer was never delivered,
# which is precisely the killed poll this whole section exists for. Dropping it on the status word
# alone would discard the one case a single poll still recovers, and send the reader back to ask
# for a decision the King already made.
#
# THE STATUS WORD BELONGS IN THE WORDING, NOT IN THE SELECTION. A row is listed when it is holding
# anything, and which list it lands in says what to do with it: a session still open is polled and
# left armed, and one that has already ended is polled once to collect what is on it and not
# re-armed, which is what `muster`'s `## The review surface` says happens after that return.
# Matched as the exact word and nothing else - a status the store did not give, one spelled any
# other way, one this could not read, all take the ordinary re-arming path, because re-arming a
# surface that did not need it costs a moment and not re-arming one that did costs the answer.
#
# What is NOT here is stated in the section itself rather than left implied: a session that is open
# with nothing queued on it is not named. The store records no field saying a poll was armed, so
# one that was being waited on cannot be told from the dozens nobody ever closed.
try {
    if (-not $LavishStatePath) {
        Add-Line '  Surfaces: no home directory to resolve lavish-axi''s session store against, so no'
        Add-Line '            review surface could be checked.'
    } elseif (-not (Test-PathQuiet $LavishStatePath)) {
        Add-Line "  Surfaces: no session store at $LavishStatePath, so none has been opened on this"
        Add-Line '            machine yet and there is nothing to re-arm.'
    } else {
        $store    = Get-Content -LiteralPath $LavishStatePath -Raw -ErrorAction Stop | ConvertFrom-Json
        $sessions = $null
        if ($store -and $store.PSObject.Properties['sessions']) { $sessions = $store.sessions }

        if ($null -eq $sessions) {
            # The tool did not say, which is not the same as the tool saying there are none. Read
            # as "none" it would answer "nothing is waiting" to a question nobody asked it.
            Add-Line "  Surfaces: the session store at $LavishStatePath named no sessions at all, so"
            Add-Line '            which surfaces are open was not established.'
        } else {
            $rows    = @($sessions.PSObject.Properties | ForEach-Object { $_.Value })
            $mine    = @($rows | Where-Object { Test-PathUnder -Path (Get-Field $_ 'file') -Root $DataPath })
            $holding = @($mine | Where-Object {
                (Get-QueuedPromptCount $_) -ne 0 -or (Get-ArtifactFailureCount $_) -ne 0
            })
            $ended = @($holding | Where-Object { (Get-Field $_ 'status') -ceq 'ended' })
            $live  = @($holding | Where-Object { (Get-Field $_ 'status') -cne 'ended' })

            if ($holding.Count -eq 0) {
                Add-Line "  Surfaces: none of the $($mine.Count) under $DataPath is holding anything nobody"
                Add-Line '            has collected.'
            } else {
                Add-Line "  Surfaces: $($holding.Count) of $($mine.Count) under $DataPath hold something nobody"
                Add-Line '            has collected. `muster`''s `## The review surface` owns what a return'
                Add-Line '            means, and each is named with the absolute path its poll takes.'
            }
            Add-Line '            Not named here: a session still open with nothing queued on it. The store'
            Add-Line '            records no field saying a poll was armed, so one that was being waited on'
            Add-Line '            cannot be told from the dozens nobody ever closed.'

            if ($live.Count -gt 0) {
                Add-Line '    Still open - re-run the poll and leave it armed:'
                Add-BoundedList -Items @($live | ForEach-Object { Format-SurfaceLine $_ }) -Indent '      '
            }
            # Listed, not counted, and this is the row the earlier shape lost. The tool hands the
            # queued feedback over on the next poll whether or not the session has ended, so the
            # path is what the reader needs; what changes is only that nothing is re-armed after.
            if ($ended.Count -gt 0) {
                Add-Line '    Already ended - run the poll once to collect it, then do not re-arm:'
                Add-BoundedList -Items @($ended | ForEach-Object { Format-SurfaceLine $_ }) -Indent '      '
            }
        }
    }
} catch {
    Add-Line ("  Surfaces: the session store at $LavishStatePath could not be read - " +
              (Format-Fault $_.Exception.Message))
}

# --------------------------------------------------------------------------------
# 3. Queue - how much is ready and held, and BY ID every hold on a decision of the
#    King's, from the backlog that belongs to QueueRoot. A hold nobody sees at
#    session open is the invisibility the backlog exists to remove, so those are
#    never cut; everything else is a count, and the command that lists it is named.
# --------------------------------------------------------------------------------
Add-Line ''
Add-Line "QUEUE  (tasks-axi ready --include-held, from $QueueRoot)"
if (-not $script:Queue.ok) {
    Add-Line ("  QUEUE: $($script:Queue.error) Nothing here says what is queued - run " +
              'tasks-axi ready --include-held yourself.')
} else {
    $heldCount = @($script:Queue.held).Count
    $captain   = @($script:Queue.captain)
    Add-Line ("  $($script:Queue.ready) ready, $heldCount held, $($captain.Count) of them on a " +
              'decision of yours. tasks-axi ready --include-held lists them all.')
    if ($captain.Count -gt 0) {
        Add-Line ('  Waiting on your decision: ' +
                  (@($captain | ForEach-Object { Get-Field $_ 'id' '(no id)' }) -join ', '))
    }
}

# --------------------------------------------------------------------------------
# 3b. Dependency check - one line, and only when the weekly check is due, and only
#     on a maintainer's installation.
#
#     Moving a pin is a maintainer's job, so someone who only uses kingshand never
#     hears of it. The marker is config\maintainer, a gitignored file a maintainer
#     creates by hand - nothing infers it from remotes or push rights, which would be
#     a guess. Without it this section asks nothing and prints nothing.
#
#     Nothing schedules the check, so a machine that was off misses nothing: the
#     next session that starts after seven days says so. Update-DependencyPins.ps1
#     owns the record and what due means; this section asks it, and asks the
#     backlog whether the check is already filed, and is silent when either says
#     there is nothing to ask. CLAUDE.md's `## Session start` owns the question the
#     Hand puts to the King.
#
#     A record that cannot be read is said as unreadable and asked about as due,
#     and a backlog that cannot be read is said as unread - asking once too often
#     costs the King a line, while staying quiet on a guess costs him the check.
# --------------------------------------------------------------------------------
# The marker is a file and nothing else: a directory or a path that will not resolve is no marker.
$script:Maintainer = $false
try { $script:Maintainer = [bool](Test-Path -LiteralPath $MaintainerPath -PathType Leaf) } catch { }

# Not asked before setup has run either. On a fresh clone the record is always absent, so the check
# would always read as never run - and the first question a new user heard would be about a weekly
# maintenance step for tools they have not installed yet, ahead of the one step that works.
if ($script:Maintainer -and -not $script:NotSetUp) { try {
    $recordPath = Join-Path (Split-Path $StatePath -Parent) 'dependency-check.json'
    $pinsScript = Join-Path $PSScriptRoot 'Update-DependencyPins.ps1'
    if (-not (Test-PathQuiet $pinsScript)) { throw "Update-DependencyPins.ps1 is not at $pinsScript." }
    $check = & $pinsScript -Due -Root $script:Root -RecordPath $recordPath

    if ($check -and $check.state -ne 'not-due') {
        # The week the check is for, as the backlog id the Hand files it under. ISO weeks, so the
        # same week has the same id on every machine and in every culture.
        $now  = (Get-Date).ToUniversalTime()
        $week = [System.Globalization.ISOWeek]::GetWeekOfYear($now)
        $year = [System.Globalization.ISOWeek]::GetYear($now)
        $id   = 'dep-check-{0}-w{1:00}' -f $year, $week

        # Filed is asked of tasks-axi by kind, and decoded by the TOON decoder that already reads its
        # output elsewhere - `count` is a number the tool states, never something matched out of a
        # line. Queued covers a held item too; tasks-axi lists a hold under its queued state.
        $filed = $null
        $why   = ''
        try {
            if (-not (Get-Command tasks-axi -ErrorAction SilentlyContinue)) { throw 'tasks-axi is not on PATH.' }
            Import-Module (Join-Path $PSScriptRoot 'GateRun.psm1') -Force -ErrorAction Stop
            $open = 0
            foreach ($state in 'queued', 'in_flight') {
                $previous = Get-Location
                try {
                    Set-Location -LiteralPath $QueueRoot
                    $global:LASTEXITCODE = 0
                    $text = (& tasks-axi list --kind dependency-check --state $state 2>&1 | Out-String)
                    $code = $LASTEXITCODE
                } finally {
                    Set-Location -LiteralPath $previous
                }
                if ($code -ne 0) { throw "tasks-axi exited $code." }
                $decoded = ConvertFrom-ToonText -Text $text
                if (-not $decoded.ok) { throw $decoded.error }
                $doc = $decoded.value | ConvertFrom-Json -AsHashtable -ErrorAction Stop
                $n = 0
                if ($doc -isnot [System.Collections.IDictionary] -or -not $doc.Contains('count') -or
                    -not [int]::TryParse("$($doc['count'])", [ref]$n)) {
                    throw 'its answer carried no count.'
                }
                $open += $n
            }
            $filed = $open -gt 0
        } catch {
            $why = Format-Fault $_.Exception.Message
        }

        if ($filed -ne $true) {
            $since = switch ($check.state) {
                'never' { 'has never run on this machine' }
                'due'   { "last ran $($check.days) days ago, on $($check.lastRun.ToString('yyyy-MM-dd'))" }
                default { 'cannot be told from its record, so it is treated as due - ' + (Format-Fault "$($check.detail)") }
            }
            Add-Line ''
            Add-Line "DEPENDENCY_CHECK_DUE: the weekly dependency check $since."
            Add-Line ("  Ask the King: run it now, or file it as $id with " +
                      "--kind dependency-check. CLAUDE.md ``## Session start`` owns the question.")
            if ($null -eq $filed) {
                Add-Line "  Whether it is already filed could not be read - $why"
            }
        }
    }
} catch {
    Add-Line ''
    Add-Line ("DEPENDENCY_CHECK_DUE: whether the weekly dependency check is due could not be read - " +
              (Format-Fault $_.Exception.Message) + " Treat it as due.")
} }

# --------------------------------------------------------------------------------
# 3c. New release - one line, for every installation, when a newer release exists
#     than the one this checkout is on.
#
#     Update.psm1 owns the whole answer: which tag is latest (the same rule /update
#     moves by), the once-a-day cache under state\, and why a checkout off the
#     release branch is told nothing. This section prints its answer and nothing
#     else. CLAUDE.md's `## Session start` owns what the Hand does with the line.
#
#     Silent when current, ahead, off the release branch or with no release cut yet.
#     A check that could not be made says so in one line and never names a version.
#     Not asked before setup has run, because the cache would be the first thing
#     written into a fresh clone.
# --------------------------------------------------------------------------------
if (-not $script:NotSetUp) {
    try {
        Import-Module (Join-Path $PSScriptRoot 'Update.psm1') -Force -ErrorAction Stop
        $notice = Get-ReleaseNotice -Root $ReleaseRepoPath `
                      -CachePath (Join-Path (Split-Path $StatePath -Parent) 'release-check.json')
        if ($notice.state -eq 'newer') {
            Add-Line ''
            Add-Line "UPDATE_AVAILABLE: $($notice.installed) -> $($notice.latest) - run /update"
        } elseif ($notice.state -eq 'unreadable') {
            $asOf = if ($notice.fromCache -and $notice.checkedAt) {
                " (as of $($notice.checkedAt.ToString('yyyy-MM-dd HH:mm')) UTC)"
            } else { '' }
            Add-Line ''
            Add-Line ("UPDATE_CHECK: could not check for a newer release$asOf - " +
                      (Format-Fault "$($notice.detail)"))
        }
    } catch {
        Add-Line ''
        Add-Line ("UPDATE_CHECK: could not check for a newer release - " + (Format-Fault $_.Exception.Message))
    }
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
# 5. Memory - the two curated memory files, printed whole where they fit under the
#    inline limit and named in one line where they do not. They come last because
#    they are the part that can give: instructions.md, every RE-ARM, AWAY and
#    toolchain line, and the fleet's live and waiting work never are.
#
#    Memory.psm1 decides which fit, from the room left once everything else and the
#    closing lines are counted. A file named rather than printed has to be READ IN
#    FULL before acting on anything it might govern - the line says so, because the
#    alternative was what happened with the digest itself: a saved file nothing made
#    anyone open.
# --------------------------------------------------------------------------------
$memoryBlock = [System.Collections.Generic.List[string]]::new()
$closing     = [System.Collections.Generic.List[string]]::new()

# The budget is a signal, not a gate: an overrun says so with the numbers and names the one thing
# that curates it back down. It is a token budget for curation; the character limit is separate.
try {
    Import-Module (Join-Path $PSScriptRoot 'Memory.psm1') -Force -ErrorAction Stop
    $report = Get-MemoryReport -DataPath $DataPath -BudgetPath $BudgetPath
    if ($report.overBudget) {
        $over = $report.total - $report.budget
        $closing.Add("STARTUP_MEMORY_BUDGET: $($report.total) estimated tokens against a budget of " +
                     "$($report.budget), over by $over. Run /chronicle to curate it back down - the " +
                     'budget is a signal, not a gate.')
    } else {
        $closing.Add("  Startup memory: $($report.total) of $($report.budget) estimated tokens.")
    }
} catch {
    $closing.Add("STARTUP_MEMORY_BUDGET: could not be accounted - " + (Format-Fault $_.Exception.Message))
}
$closing.Add('')
if ($script:NotSetUp) {
    $closing.Add('Nothing above is configured yet. The one useful next step is "set it up".')
    $closing.Add('')
}
$closing.Add('Read this digest once and trust it as startup input: it names what is live or waiting and')
$closing.Add('counts the rest. Read what it only named when the work needs it. Liveness comes from herdr.')
$closing.Add('=== END KINGSHAND SESSION START ===')

$memoryHead = @('', 'MEMORY  (printed whole where it fits under the inline limit, named where it does not)')
# Each file printed whole costs its text plus its two delimiter lines and a blank; a file named
# instead costs one line. Room is what is left once everything else, the closing lines and a named
# line for each file are counted - so a plan that names both files still fits.
$pointerMax   = 360
$soFar        = ($script:Lines -join "`n").Length + ($memoryHead -join "`n").Length +
                ($closing -join "`n").Length + 4
$room         = $script:InlineLimit - $soFar - (2 * $pointerMax)
$absentMeans  = @{
    'king.md'      = 'nothing has been recorded about how the King works yet.'
    'learnings.md' = 'no operational learnings have been recorded yet.'
}
try {
    $plan = Get-MemoryDigestPlan -DataPath $DataPath -RoomCharacters $room -PerFileOverhead 200
    foreach ($f in $plan.files) {
        $memoryBlock.Add('')
        if ($f.state -eq 'pointer') {
            $memoryBlock.Add(("----- NOT PRINTED $($f.name) ($($f.path)) - $($f.characters) characters, " +
                              'over the inline limit. Read it in full before acting on anything it ' +
                              'might govern. -----'))
            continue
        }
        $memoryBlock.Add("----- BEGIN $($f.name) ($($f.path)) -----")
        switch ($f.state) {
            # ABSENT is a fact with a meaning, and it is not the same fact as an empty file. One
            # says nothing has been recorded yet; the other says someone recorded nothing.
            'absent'     { $memoryBlock.Add("ABSENT - $($absentMeans[$f.name])") }
            'empty'      { $memoryBlock.Add('EMPTY - the file exists but holds no content.') }
            'unreadable' { $memoryBlock.Add('UNREADABLE - ' + (Format-Fault $f.error)) }
            default      { foreach ($line in $f.text.Split("`n")) { $memoryBlock.Add($line) } }
        }
        $memoryBlock.Add("----- END $($f.name) -----")
    }
} catch {
    $memoryBlock.Add('')
    $memoryBlock.Add('MEMORY: king.md and learnings.md could not be planned - ' +
                     (Format-Fault $_.Exception.Message) + ' Read both in full: ' +
                     (Join-Path $DataPath 'king.md') + ' and ' + (Join-Path $DataPath 'learnings.md') + '.')
}

foreach ($line in $memoryHead)  { Add-Line $line }
foreach ($line in $memoryBlock) { Add-Line $line }
Add-Line ''
foreach ($line in $closing)     { Add-Line $line }

# THE LIMIT, CHECKED ON WHAT IS ABOUT TO BE SENT. Everything above is shaped to fit, and the parts
# that cannot give - the King's instructions, the re-arm list, a long toolchain failure - can still
# carry it over. Where they do, the first line says so, so that the preview the harness keeps is
# the one place that tells the session to read the saved file in full.
$digest = ($script:Lines -join "`n")
if ($digest.Length -gt $script:InlineLimit) {
    $script:Lines.Insert(1, ("OVER THE INLINE LIMIT: this digest is $($digest.Length) characters " +
                             "against the harness's $($script:InlineLimit), so only a preview " +
                             'reaches the session inline. Read the saved file in full before ' +
                             'anything else.'))
    $digest = ($script:Lines -join "`n")
}

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
