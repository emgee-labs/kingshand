#Requires -Version 7.0
<#
.SYNOPSIS
  The single bounded gather behind /survey: registry, workers, un-dispatched briefs, reports.
.DESCRIPTION
  Returns structured data. It renders nothing and decides nothing - which bucket a fact belongs
  in is the `survey` skill's job, and acting on it is `muster`'s. This script only reads.

  Bounded on purpose: paths, counts and one-line facts, never file contents and never a walk of
  a project repository. A fleet of twenty workers still fits in one object. Liveness costs one
  `herdr agent list` plus a state correction per LIVE worker, all through Get-CrewStatus.ps1, and
  nothing at all when crew.json holds no workers. The per-worker part is deliberate: herdr's own
  classification cannot be trusted for the blocked case, so the worker's screen is read.

  Never throws. Every section is independently guarded and a failure becomes a string in
  .diagnostics while the remaining sections still populate. A broken snapshot must degrade, not
  explode, because the alternative is a catch-up read that reports nothing at all.

  Liveness is never ours: it comes from herdr, joined with crew.json by Get-CrewStatus.ps1, which
  owns that join. `.crew.workers[].live` is $true or $false when that join ran, and $null when it
  could not - $null means unknown, never dead. `.agentState` is herdr's word for the worker
  (idle, working, blocked, done, unknown) corrected by the worker's own screen, and it is not the
  old supervisor vocabulary: herdr's `idle` means "not mid-turn", which a worker also is in the
  seconds after it starts, so it never means finished on its own.

  `.crew.workers[].waitingOn` is crew.json's `waiting_on` pointer: the tasks-axi hold key the
  worker parked on, or the empty string when it has never parked. It is never cleared, so it says
  which decision that worker stopped on and not whether the decision is still outstanding - that
  is the hold's own state, and this snapshot does not read the queue. Liveness cannot answer
  either half, since a parked worker and a finished one both read `idle`. It is intent, so it
  comes from crew.json and never from herdr.

  An empty registry and an absent crew.json are states, not errors: nothing can be dispatched
  until /annex runs, and nothing is dispatched until `muster` dispatches it.

.PARAMETER RegistryPath
  data\projects.md - the project registry.
.PARAMETER DataPath
  the data\ directory holding data\<id>\brief.md and data\<id>\report.md.
.PARAMETER StatePath
  state\crew.json - worker intent.
.EXAMPLE
  $snap = & $env:KINGSHAND_HOME\bin\Get-SurveySnapshot.ps1
#>
[CmdletBinding()]
param(
    [string]$RegistryPath,
    [string]$DataPath,
    [string]$StatePath
)

Set-StrictMode -Version Latest

# Resolved in the body rather than as parameter defaults: the root comes from Get-KingshandHome,
# which is the one place that decision is made, and a param default cannot call it.
Import-Module (Join-Path $PSScriptRoot 'Paths.psm1') -Force
$script:Root = Get-KingshandHome
if (-not $RegistryPath) { $RegistryPath = Join-Path $script:Root 'data\projects.md' }
if (-not $DataPath)     { $DataPath     = Join-Path $script:Root 'data' }
if (-not $StatePath)    { $StatePath    = Join-Path $script:Root 'state\crew.json' }

$script:Diagnostics = [System.Collections.Generic.List[string]]::new()

# A section reports its own failure rather than propagating it. The message is collapsed and
# truncated because an exception message can be a paragraph and this object is bounded.
function Add-Fault {
    param([Parameter(Mandatory)][string]$Section, [Parameter(Mandatory)][string]$Message)
    $m = ($Message -replace '\s+', ' ').Trim()
    if ($m.Length -gt 200) { $m = $m.Substring(0, 200) + '...' }
    $script:Diagnostics.Add("[$Section] $m")
}

# StrictMode Latest throws on a missing hashtable key or property, and everything below reads
# objects produced by other modules. An absent key is reported as absent, not as a crash.
function Get-Field {
    param($Entry, [Parameter(Mandatory)][string]$Key, [string]$Fallback = '')
    try {
        if ($null -eq $Entry) { return $Fallback }
        if ($Entry -is [hashtable] -or $Entry -is [System.Collections.IDictionary]) {
            if ($Entry.Contains($Key)) {
                $v = $Entry[$Key]
                if ($null -ne $v -and "$v".Length -gt 0) { return "$v" }
            }
            return $Fallback
        }
        $p = $Entry.PSObject.Properties[$Key]
        if ($p -and $null -ne $p.Value -and "$($p.Value)".Length -gt 0) { return "$($p.Value)" }
        return $Fallback
    } catch {
        return $Fallback
    }
}

# Test-Path itself throws on a malformed path, and a registry entry's path is whatever someone
# typed. A path we cannot test is reported as not present, not as a failed snapshot.
function Test-PathQuiet {
    param([string]$Path)
    try {
        if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
        return [bool](Test-Path -LiteralPath $Path)
    } catch {
        return $false
    }
}

function Format-Stamp {
    param([Parameter(Mandatory)][datetime]$When)
    $When.ToString('yyyy-MM-dd HH:mm')
}

# --------------------------------------------------------------------------------
# crew.json is read once. The worker rows need the state, and the un-dispatched scan
# needs the id set; a malformed file must degrade both without taking the snapshot down.
# --------------------------------------------------------------------------------
$crewPresent  = Test-PathQuiet $StatePath
$crewReadable = $false
$crewState    = $null
$crewIds      = @()
# Directories under data\ are named by TICKET, not by worker id - Dispatch-Worker is called with
# -Name <ticket> while the id is minted by the supervisor. Comparing a directory name against
# $crewIds therefore never matches, and every dispatched worker's brief reads as un-dispatched.
# Observed live: four dispatched workers reported as five un-dispatched briefs, which invites a
# duplicate dispatch of work already running. Keep the ticket set for that comparison.
$crewTickets  = @()
try {
    Import-Module (Join-Path $PSScriptRoot 'Crew.psm1') -Force -ErrorAction Stop
    $crewState    = Import-CrewState -Path $StatePath
    $crewIds      = @($crewState.workers.Keys)
    $crewTickets  = @($crewIds | ForEach-Object {
        $t = $crewState.workers[$_]['ticket']
        if ($t) { [string]$t }
    } | Where-Object { $_ })
    $crewReadable = $true
} catch {
    Add-Fault 'crew.json' $_.Exception.Message
}

# --------------------------------------------------------------------------------
# 1. Registry - every registered project, its standing posture, and whether its
#    recorded path is still on disk.
# --------------------------------------------------------------------------------
$registryPresent  = Test-PathQuiet $RegistryPath
$registryReadable = $false
$entries          = @()
if ($registryPresent) {
    try {
        Import-Module (Join-Path $PSScriptRoot 'Projects.psm1') -Force -ErrorAction Stop

        # Deliberately NOT wrapped in @(). Get-AllProjects returns via the leading-comma idiom,
        # so the pipeline hands back the intact entries array as one object; @() would nest it a
        # second time and every entry would read as one unnamed row.
        # A registry typo is a Write-Warning, not an exception, and it silently makes a project
        # stricter - captured here so the digest can say so instead of losing it to the console.
        $regWarn  = $null
        $projects = Get-AllProjects -RegistryPath $RegistryPath -WarningVariable regWarn -WarningAction SilentlyContinue
        foreach ($w in @($regWarn)) { if ($w) { Add-Fault 'registry' "$w" } }

        foreach ($p in @($projects)) {
            $path = Get-Field $p 'path'
            $entries += [pscustomobject]@{
                name    = (Get-Field $p 'name' '(unnamed)')
                # rawMode is the registered annotation; mode is the mechanical resolution, and
                # the two differ only for no-mistakes-prod-only. Route on rawMode.
                rawMode = (Get-Field $p 'rawMode' '(no mode)')
                mode    = (Get-Field $p 'mode' '(no mode)')
                # yolo is the string 'on' or 'off'. Never test it for truthiness - 'off' is a
                # non-empty string and would read as true.
                yolo    = $(if ((Get-Field $p 'yolo') -eq 'on') { 'on' } else { 'off' })
                path    = $path
                # No path line recorded is as missing as a path that is gone.
                pathExists = $(if ($path) { Test-PathQuiet $path } else { $false })
                # A name the index cannot turn into a file name. Get-Field hands back strings, so
                # only an explicit False flags a project: a missing or odd field reads as fine
                # rather than inventing a problem in the digest.
                indexable  = $((Get-Field $p 'indexable' 'True') -ne 'False')
            }
        }
        $registryReadable = $true
    } catch {
        Add-Fault 'registry' $_.Exception.Message
    }
}

# --------------------------------------------------------------------------------
# 2. Workers - crew.json intent joined with live agent state by Get-CrewStatus.ps1,
#    which owns the join, the one `herdr agent list` call, and the screen-corrected state.
# --------------------------------------------------------------------------------
$workers = @()
if ($crewReadable -and $crewIds.Count -gt 0) {
    $rows = $null
    try {
        $statusScript = Join-Path $PSScriptRoot 'Get-CrewStatus.ps1'
        if (-not (Test-PathQuiet $statusScript)) { throw "Get-CrewStatus.ps1 is not at $statusScript." }
        # Invoked in a child scope with strict mode off: it predates this script and reads
        # optional properties off the agent objects, which StrictMode Latest would turn into an
        # exception if it inherited the setting from here.
        $rows = @(& { Set-StrictMode -Off; & $statusScript -StatePath $StatePath })
    } catch {
        Add-Fault 'liveness' $_.Exception.Message
        $rows = $null
    }

    foreach ($id in @($crewIds | Sort-Object)) {
        $w = $null
        try { $w = $crewState.workers[$id] } catch { $w = $null }

        $row = $null
        if ($null -ne $rows) {
            $row = @($rows | Where-Object { (Get-Field $_ 'id') -eq $id }) | Select-Object -First 1
        }

        # $null is unknown liveness, never dead. Only a join that actually ran can say dead.
        $live = $null
        if ($null -ne $row) { $live = ((Get-Field $row 'live') -eq 'True') }

        $reportPath = Join-Path $DataPath (Join-Path $id 'report.md')
        $workers += [pscustomobject]@{
            id          = $id
            ticket      = (Get-Field $w 'ticket' '-')
            repo        = (Get-Field $w 'repo' '-')
            stage       = (Get-Field $w 'stage' '-')
            live        = $live
            agentState  = (Get-Field $row 'agentState')
            agentStatus = (Get-Field $row 'agentStatus')
            briefPath   = (Get-Field $w 'brief')
            # Read from crew.json rather than from the liveness row: this is intent, and a parked
            # worker reads `idle` exactly like a finished one. Which decision, never whether it is
            # still owed - see the header.
            waitingOn   = (Get-Field $w 'waiting_on')
            # report.md survives teardown, so a dead worker with a report is still readable work.
            hasReport   = (Test-PathQuiet $reportPath)
            reportPath  = $reportPath
        }
    }
}

# --------------------------------------------------------------------------------
# 3. Un-dispatched work - a brief written but never dispatched, most often because the
#    dispatch gate stopped it. Silently ignoring these loses the work. Directories
#    beginning with _ are scratch (_dispatch, _context, _coverage), never work ids.
#    When crew.json is unreadable this list may over-report; the diagnostic says so.
# --------------------------------------------------------------------------------
$dataPresent  = Test-PathQuiet $DataPath
$undispatched = @()
if ($dataPresent) {
    try {
        $dirs = @(Get-ChildItem -LiteralPath $DataPath -Directory -ErrorAction Stop |
            Where-Object { -not $_.Name.StartsWith('_') } |
            Sort-Object Name)

        foreach ($d in $dirs) {
            $briefPath = Join-Path $d.FullName 'brief.md'
            if (-not (Test-PathQuiet $briefPath)) { continue }
            # Match on ticket, not id - see the note where $crewTickets is built. A directory is
            # also skipped when its name happens to be an id, so a future rename cannot resurrect
            # the bug silently.
            if ($crewTickets -contains $d.Name) { continue }
            if ($crewIds -contains $d.Name) { continue }

            $modified = ''
            try { $modified = Format-Stamp (Get-Item -LiteralPath $briefPath -ErrorAction Stop).LastWriteTime } catch { $modified = '' }

            $reportPath = Join-Path $d.FullName 'report.md'
            $undispatched += [pscustomobject]@{
                id            = $d.Name
                briefPath     = $briefPath
                briefModified = $modified
                hasReport     = (Test-PathQuiet $reportPath)
                reportPath    = $reportPath
            }
        }
    } catch {
        Add-Fault 'data' $_.Exception.Message
    }
}

# --------------------------------------------------------------------------------
# Emit one object. Nothing above writes to the output stream, so a partially gathered
# snapshot is still returned whole.
# --------------------------------------------------------------------------------
[pscustomobject]@{
    contract    = 'kingshand-survey.v1'
    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    registry    = [pscustomobject]@{
        path     = $RegistryPath
        present  = $registryPresent
        readable = $registryReadable
        count    = @($entries).Count
        empty    = (@($entries).Count -eq 0)
        entries  = @($entries)
    }
    crew        = [pscustomobject]@{
        path     = $StatePath
        present  = $crewPresent
        readable = $crewReadable
        count    = @($workers).Count
        workers  = @($workers)
    }
    data        = [pscustomobject]@{
        path              = $DataPath
        present           = $dataPresent
        undispatchedCount = @($undispatched).Count
        undispatched      = @($undispatched)
    }
    diagnostics = @($script:Diagnostics)
}
