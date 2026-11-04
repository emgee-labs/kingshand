#Requires -Version 7.0
Set-StrictMode -Version Latest

# crew.json data model.
#
# This module owns intent only: which worker is doing which ticket, in which repo, at which
# stage. Liveness is never stored here - it comes from herdr, which is the only thing that
# actually knows whether a process exists. Get-CrewStatus.ps1 owns that join.
#
# The worker id stored here is kingshand's own, and it is the name dispatch chose rather than one
# a supervisor minted. herdr never sees it in this form: ConvertTo-HerdrAgentName normalises it to
# herdr's much narrower `^[a-z][a-z0-9_-]{0,31}$`, and that mapping lives in Herdr.psm1 so this
# file keeps exactly one id.
#
# Add-CrewWorker, Set-CrewStage and Set-CrewWaitingOn deliberately return nothing. A
# hashtable is a reference type, so mutation is visible to the caller without a return value.
# Returning the state would emit it to the pipeline at every call site and flood both test output
# and the Hand's console with hashtable dumps.
#
# `waiting_on` is a pointer, not a stage, and the distinction is the whole reason it exists.
# The stages are a lifecycle - a worker is at exactly one of them and moves forward. Waiting
# for a decision is a condition that can happen at any of them and then resolves back to wherever
# the worker already was, so a stage for it would destroy the one fact most needed afterwards:
# what the worker was doing before it parked. This field holds the tasks-axi hold key carrying
# that decision. The `decree` skill owns the hold's own lifecycle and how its key is composed;
# this module only records which key a worker parked on, so no session has to reconstruct it.
#
# `paused` is the one stage off that forward line. Suspend-Worker in bin\Teardown.psm1 sets it once
# a worker is stopped with its copy kept, so a later session reads it as paused rather than dead,
# and a relaunch moves it back to `dispatched` with Set-CrewRelaunch. A pause does not resolve back
# to where the worker was - a relaunch starts over - so nothing is lost by it being a stage, and the
# stage it left is written into its pause record.
#
# THERE IS NO CLEARING VERB, AND THAT IS THE DESIGN RATHER THAN AN OMISSION. Once a worker parks,
# the field keeps naming that hold for the rest of the worker's life. Clearing it on the way back
# out would give one null two opposite meanings - a worker that never parked, and a worker that
# parked, was answered and carried on - and the first must be read for a question nobody has
# registered yet while the second is a finished delivery. Read as one, either the question is
# lost or already-delivered work is refused and re-asked. So the field has two values and no
# third: a null means no park has been recorded on this record - never that there is nothing to
# answer, because only a Hand who has read the report ever writes it - and whether a set pointer's
# decision is still outstanding is the hold's own state, read from the queue under that key.
# Parking a second time replaces the key rather than clearing it.
#
# docs\2026-09-04-parked-decision-route.md is the design record behind both paragraphs above.
#
# ONE WORKER, SEVERAL ITEMS, AND ONLY FOR A SESSION WORKER. Every other record maps one worker to one
# ticket and reads exactly as it always has: no key is added to it, here or on import. A worker the
# `fief` skill keeps warm for a run of fixes on one branch is recorded with -Session, and its record
# carries `items` - every ticket or fix id riding that branch, in the order they joined it, each
# with its kind. `ticket` stays the first item, so anything that reads one ticket per worker still
# reads a true one. The list is durable, so it survives a restart, and it is the one source for the
# commit and pull request titles, which name every id. Get-CrewItems reads either shape.
#
# A worker in the project's own checkout, with no worktree, carries `checkout` and the path of the
# permission-file record dispatch wrote, which is what its cleanup reads back.
#
# `pane_id` is the herdr pane dispatch started the worker in, absent on records from before it was
# kept, and `torn_down_at` says its cleanup finished. bin\Teardown.psm1 reads the first and writes
# the second.

$script:ValidStages = @('dispatched', 'implementing', 'gating', 'ready', 'landed', 'failed', 'paused')
$script:ValidKinds  = @('ticket', 'adhoc')

# tasks-axi ids are slug-shaped - letters, digits, '.', '_' and '-', with no spaces - and the first
# character must be a letter or a digit. A key that cannot be one is a key no hold was ever filed
# under, so it is refused here rather than stored and discovered to match nothing later.
#
# The leading class is narrower than the rest on purpose, because the tool's own validator is:
# ID_CHARS is `[A-Za-z0-9][A-Za-z0-9._-]*` in tasks-axi's markdown-grammar.js, anchored into ID_RE
# and enforced by validateId. A key like '-1001-hero-copy' - a work id whose first character was
# lost - would pass a uniform class and then resolve to nothing, which is the same
# matches-no-hold failure the whitespace case below describes.
#
# Anchored \A..\z rather than ^..$ on purpose. In .NET, `$` also matches immediately before a
# single trailing newline, so an `^...$` guard accepts "T-1001-hero-copy`n" - which is exactly
# the key-that-matches-no-hold this guard exists to refuse, and a trailing newline is what a
# pasted or here-string value arrives with. \z matches the end of the string and nothing else.
$script:HoldKeyPattern = '\A[A-Za-z0-9][A-Za-z0-9._-]*\z'

function New-CrewState {
    [CmdletBinding()]
    param()
    @{ workers = @{} }
}

function Add-CrewWorker {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$WorkerId,
        [Parameter(Mandatory)][string]$Ticket,
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$Worktree,
        [Parameter(Mandatory)][string]$Branch,
        [Parameter(Mandatory)][string]$Brief,
        # The ref the worktree actually branched from, as reported by Dispatch-Worker. Usually
        # origin/<default>, which is NOT the same as the local default branch when the local one
        # is behind. Every diff, log and attribution check at the landing gate must use this.
        [string]$Base = 'origin/main',
        # A `fief` session's warm worker, which carries a list of items rather than one ticket.
        # Off for every ordinary dispatch, so its records keep their shape.
        [switch]$Session,
        # Dispatched with -InCheckout, into the project's own checkout. SettingsRecord is the path
        # Dispatch-Worker returned as settingsRecord, and it is required here because cleanup
        # cannot put the King's settings file back without it.
        [switch]$InCheckout,
        [string]$SettingsRecord = '',
        # The herdr pane the worker was started in, as Dispatch-Worker returned it in paneId. Kept so
        # cleanup can close that pane after the worker has exited, when herdr no longer has an agent
        # to find it through. Left off, nothing is recorded and cleanup finds the pane by its cwd.
        [string]$PaneId = ''
    )

    if ($Kind -notin $script:ValidKinds) {
        throw "Invalid kind '$Kind'. Must be one of: $($script:ValidKinds -join ', ')"
    }
    # A second dispatch under an id already recorded is a re-dispatch, and Set-CrewRelaunch owns
    # how one is recorded - so the refusal names it rather than leaving the Hand at a dead end.
    if ($State.workers.ContainsKey($WorkerId)) {
        throw ("Duplicate worker id '$WorkerId'. It is already recorded, so this is a re-dispatch: " +
               "re-record it with Set-CrewRelaunch, passing -BranchCut from the dispatch result's " +
               "branchCut, which keeps the recorded base unless that dispatch cut a new branch.")
    }
    if ($InCheckout -and -not $SettingsRecord.Trim()) {
        throw ("A checkout worker needs -SettingsRecord - the record Dispatch-Worker returned as " +
               "settingsRecord - or nothing can put the checkout's settings file back at cleanup.")
    }
    if ($SettingsRecord.Trim() -and -not $InCheckout) {
        throw "-SettingsRecord is for a checkout worker; pass -InCheckout as well, or leave it off."
    }
    if ($Session -and $Ticket -notmatch $script:HoldKeyPattern) {
        throw ("Invalid item id '$Ticket'. Must be slug-shaped: letters, digits, '.', '_' or '-', " +
               "and the first character must be a letter or a digit.")
    }

    $State.workers[$WorkerId] = @{
        ticket        = $Ticket
        kind          = $Kind
        repo          = $Repo
        worktree      = $Worktree
        branch        = $Branch
        base          = $Base
        brief         = $Brief
        stage         = 'dispatched'
        dispatched_at = (Get-Date).ToUniversalTime().ToString('o')
        landed        = $false
        waiting_on    = $null
    }
    if ($Session) {
        $State.workers[$WorkerId].session = $true
        $State.workers[$WorkerId].items   = @(@{ id = $Ticket; kind = $Kind })
    }
    if ($InCheckout) {
        $State.workers[$WorkerId].checkout        = $true
        $State.workers[$WorkerId].settings_record = $SettingsRecord.Trim()
    }
    if ($PaneId.Trim()) { $State.workers[$WorkerId].pane_id = $PaneId.Trim() }
}

# Records that a worker's cleanup finished: its pane, workspace and copy are gone. The stage is left
# where it was - cleanup runs at `ready` or at `landed`, and both still say truly how far the work
# got - so this is a field beside the stage rather than a seventh stage every reader would have to
# learn. bin\Teardown.psm1 is the one writer.
function Set-CrewTornDown {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$WorkerId
    )

    if (-not $State.workers.ContainsKey($WorkerId)) { throw "Worker '$WorkerId' not found." }
    $State.workers[$WorkerId].torn_down_at = (Get-Date).ToUniversalTime().ToString('o')
}

# One more ticket or fix joining a session worker's branch, appended in order. Refused on a worker
# that is not a session worker - an ordinary record maps one worker to one ticket and gaining a list
# would change what every reader of it sees - and refused for an id already on the branch, because
# a title naming one id twice is a title nobody can trust.
function Add-CrewItem {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$WorkerId,
        [Parameter(Mandatory)][string]$Item,
        [Parameter(Mandatory)][string]$Kind
    )

    if (-not $State.workers.ContainsKey($WorkerId)) { throw "Worker '$WorkerId' not found." }
    if ($Kind -notin $script:ValidKinds) {
        throw "Invalid kind '$Kind'. Must be one of: $($script:ValidKinds -join ', ')"
    }
    if ($Item -notmatch $script:HoldKeyPattern) {
        throw ("Invalid item id '$Item'. Must be slug-shaped: letters, digits, '.', '_' or '-', " +
               "and the first character must be a letter or a digit.")
    }
    $rec = $State.workers[$WorkerId]
    if (-not ($rec.ContainsKey('session') -and $rec.session -eq $true)) {
        throw ("Worker '$WorkerId' is not a session worker, so it carries one ticket and nothing " +
               "joins it. Dispatch the new work on its own, or record the session worker with -Session.")
    }
    # Assigned rather than wrapped: Get-CrewItems returns its list through the leading-comma idiom.
    $items = Get-CrewItems -State $State -WorkerId $WorkerId
    if (@($items | Where-Object { $_.id -eq $Item }).Count -gt 0) {
        throw "Item '$Item' is already on worker '$WorkerId''s branch."
    }
    $rec.items = @(@($rec.items) + @(@{ id = $Item; kind = $Kind }))
}

# Every item a worker carries, in order, as objects with `id` and `kind`. An ordinary record answers
# with its one ticket, so a caller never has to know which shape it is holding. A session record
# whose list cannot be read as that is refused by name: a title or a status line built from a guess
# would name work that is not on the branch, or leave out work that is.
function Get-CrewItems {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$WorkerId
    )

    if (-not $State.workers.ContainsKey($WorkerId)) { throw "Worker '$WorkerId' not found." }
    $rec = $State.workers[$WorkerId]
    if (-not ($rec -is [System.Collections.IDictionary] -and $rec.Contains('items'))) {
        return , @([pscustomobject]@{ id = "$($rec.ticket)"; kind = "$($rec.kind)" })
    }
    $out = foreach ($it in @($rec.items)) {
        if (-not ($it -is [System.Collections.IDictionary]) -or -not $it.Contains('id') -or
            -not $it.Contains('kind') -or "$($it.id)" -notmatch $script:HoldKeyPattern -or
            "$($it.kind)" -notin $script:ValidKinds) {
            throw ("Worker '$WorkerId' records an item list that cannot be read: every entry must " +
                   "carry an id and a kind of $($script:ValidKinds -join ' or ').")
        }
        [pscustomobject]@{ id = "$($it.id)"; kind = "$($it.kind)" }
    }
    if (@($out).Count -eq 0) {
        throw "Worker '$WorkerId' records an empty item list, so nothing says what rides its branch."
    }
    , @($out)
}

# Re-records an existing worker after a relaunch or any other re-dispatch under the same id: where
# it now runs, on which branch, in which pane, and the new permission-file record for a checkout
# worker. Its items, its waiting_on and everything else it carried are kept - a re-dispatch is the
# same work, and Add-CrewWorker refuses the id as a duplicate and points here.
#
# THE RECORDED BASE MUST STAY THE REF THE BRANCH WAS CUT FROM, because the landing gate diffs
# against it. Dispatch-Worker resolves a base on every dispatch, but cuts a branch from it only when
# the branch does not exist yet; a re-dispatch that finds the branch - its worktree still registered,
# or the branch outliving it - checks it out where the earlier dispatch cut it. So the recorded base
# is replaced only when -BranchCut says this dispatch cut the branch, and then by the -Base it was
# cut from. Otherwise it is kept, and any -Base passed is not recorded: it was resolved fresh and
# the branch was not cut from it, so recording it would let the landing diff carry commits nobody
# in this work wrote. Keeping is the default because a relaunch reuses its branch, so a caller that
# says nothing gets the true answer.
function Set-CrewRelaunch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$WorkerId,
        [Parameter(Mandatory)][string]$Worktree,
        [Parameter(Mandatory)][string]$Branch,
        # The ref the branch was cut from. Recorded only with -BranchCut $true, which requires it.
        [string]$Base = '',
        # Dispatch-Worker's branchCut: whether that dispatch cut the branch from -Base.
        [bool]$BranchCut = $false,
        [string]$SettingsRecord = '',
        # The pane the re-dispatch started the worker in, as Dispatch-Worker returned it. Left off,
        # the pane already recorded is kept.
        [string]$PaneId = ''
    )

    if (-not $State.workers.ContainsKey($WorkerId)) { throw "Worker '$WorkerId' not found." }
    $rec = $State.workers[$WorkerId]
    $checkout = $rec.ContainsKey('checkout') -and $rec.checkout -eq $true
    if ($checkout -and -not $SettingsRecord.Trim()) {
        throw ("Worker '$WorkerId' runs in the checkout, so its relaunch needs -SettingsRecord - " +
               "the record Dispatch-Worker returned as settingsRecord.")
    }
    if ($SettingsRecord.Trim() -and -not $checkout) {
        throw "Worker '$WorkerId' is not a checkout worker, so -SettingsRecord has nothing to replace."
    }
    if ($BranchCut -and -not $Base.Trim()) {
        throw ("-BranchCut says this dispatch cut a new branch for worker '$WorkerId', so it needs " +
               "-Base - the ref the branch was cut from, the dispatch result's base. Nothing was " +
               "changed.")
    }

    $rec.worktree      = $Worktree
    $rec.branch        = $Branch
    if ($BranchCut) { $rec.base = $Base.Trim() }
    $rec.stage         = 'dispatched'
    $rec.dispatched_at = (Get-Date).ToUniversalTime().ToString('o')
    if ($checkout) { $rec.settings_record = $SettingsRecord.Trim() }
    if ($PaneId.Trim()) { $rec.pane_id = $PaneId.Trim() }
}

function Set-CrewWaitingOn {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$WorkerId,
        # The tasks-axi hold key the worker parked on. Setting it a second time replaces the
        # first: a worker parked twice is waiting on its newest decision, not on both.
        [Parameter(Mandatory)][string]$HoldKey
    )

    if (-not $State.workers.ContainsKey($WorkerId)) {
        throw "Worker '$WorkerId' not found."
    }
    if ($HoldKey -notmatch $script:HoldKeyPattern) {
        throw ("Invalid hold key '$HoldKey'. Must be slug-shaped: letters, digits, '.', '_' or " +
               "'-', and the first character must be a letter or a digit.")
    }

    $State.workers[$WorkerId].waiting_on = $HoldKey
}

function Set-CrewStage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$WorkerId,
        [Parameter(Mandatory)][string]$Stage
    )

    if ($Stage -notin $script:ValidStages) {
        throw "Invalid stage '$Stage'. Must be one of: $($script:ValidStages -join ', ')"
    }
    if (-not $State.workers.ContainsKey($WorkerId)) {
        throw "Worker '$WorkerId' not found."
    }

    $State.workers[$WorkerId].stage = $Stage
    if ($Stage -eq 'landed') { $State.workers[$WorkerId].landed = $true }
}

function Get-CrewWorker {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$WorkerId
    )
    if ($State.workers.ContainsKey($WorkerId)) { $State.workers[$WorkerId] } else { $null }
}

function Get-CrewByStage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$Stage
    )
    $out = foreach ($id in $State.workers.Keys) {
        if ($State.workers[$id].stage -eq $Stage) {
            $w = $State.workers[$id].Clone()
            $w['id'] = $id
            $w
        }
    }
    # The leading comma is load-bearing. PowerShell unwraps a single-element array on return,
    # so `@($out)` alone would hand back the bare hashtable and .Count would report its key
    # count instead of 1. Wrapping in an outer array survives the unwrap.
    , @($out)
}

function Save-CrewState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$Path
    )
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $State | ConvertTo-Json -Depth 10 | Set-Content -Path $Path -Encoding utf8
}

function Import-CrewState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path $Path)) { return New-CrewState }

    $raw = Get-Content -Path $Path -Raw | ConvertFrom-Json -AsHashtable
    if (-not $raw.ContainsKey('workers') -or $null -eq $raw.workers) { $raw.workers = @{} }

    # Every record carries waiting_on whether or not it was written with one. A file saved before
    # the field existed would otherwise give a reader a third case - absent, as distinct from set
    # and null - and a third case is the thing this field was added to stop existing. Normalising
    # on the way in leaves exactly two.
    foreach ($id in @($raw.workers.Keys)) {
        $rec = $raw.workers[$id]
        if ($rec -is [hashtable] -and -not $rec.ContainsKey('waiting_on')) { $rec.waiting_on = $null }
    }

    $raw
}

Export-ModuleMember -Function New-CrewState, Add-CrewWorker, Set-CrewStage, Set-CrewWaitingOn,
                              Get-CrewWorker, Get-CrewByStage, Save-CrewState, Import-CrewState,
                              Add-CrewItem, Get-CrewItems, Set-CrewRelaunch, Set-CrewTornDown
