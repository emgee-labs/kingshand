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
# Add-CrewWorker, Set-CrewStage and the two waiting_on functions deliberately return nothing. A
# hashtable is a reference type, so mutation is visible to the caller without a return value.
# Returning the state would emit it to the pipeline at every call site and flood both test output
# and the Hand's console with hashtable dumps.
#
# `waiting_on` is a pointer, not a stage, and the distinction is the whole reason it exists.
# The six stages are a lifecycle - a worker is at exactly one of them and moves forward. Waiting
# for a decision is a condition that can happen at any of them and then resolves back to wherever
# the worker already was, so a seventh stage would destroy the one fact most needed afterwards:
# what the worker was doing before it parked. This field holds the tasks-axi hold key carrying
# that decision, and its presence is the state. There is nothing else to read and nothing to
# enumerate. The `decree` skill owns the hold's own lifecycle and how its key is composed; this
# module only records which key a worker is waiting on, so no session has to reconstruct it.

$script:ValidStages = @('dispatched', 'implementing', 'gating', 'ready', 'landed', 'failed')
$script:ValidKinds  = @('ticket', 'adhoc')

# tasks-axi ids are slug-shaped - letters, digits, '.', '_' and '-', with no spaces. A key that
# cannot be one is a key no hold was ever filed under, so it is refused here rather than stored
# and discovered to match nothing later.
#
# Anchored \A..\z rather than ^..$ on purpose. In .NET, `$` also matches immediately before a
# single trailing newline, so `^[A-Za-z0-9._-]+$` accepts "T-1001-hero-copy`n" - which is exactly
# the key-that-matches-no-hold this guard exists to refuse, and a trailing newline is what a
# pasted or here-string value arrives with. \z matches the end of the string and nothing else.
$script:HoldKeyPattern = '\A[A-Za-z0-9._-]+\z'

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
        [string]$Base = 'origin/main'
    )

    if ($Kind -notin $script:ValidKinds) {
        throw "Invalid kind '$Kind'. Must be one of: $($script:ValidKinds -join ', ')"
    }
    if ($State.workers.ContainsKey($WorkerId)) {
        throw "Duplicate worker id '$WorkerId'."
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
}

function Set-CrewWaitingOn {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$WorkerId,
        # The tasks-axi hold key the worker is parked on. Setting it a second time replaces the
        # first: a worker parked twice is waiting on its newest decision, not on both.
        [Parameter(Mandatory)][string]$HoldKey
    )

    if (-not $State.workers.ContainsKey($WorkerId)) {
        throw "Worker '$WorkerId' not found."
    }
    if ($HoldKey -notmatch $script:HoldKeyPattern) {
        throw "Invalid hold key '$HoldKey'. Must be slug-shaped: letters, digits, '.', '_' or '-'."
    }

    $State.workers[$WorkerId].waiting_on = $HoldKey
}

function Clear-CrewWaitingOn {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$WorkerId
    )

    if (-not $State.workers.ContainsKey($WorkerId)) {
        throw "Worker '$WorkerId' not found."
    }

    $State.workers[$WorkerId].waiting_on = $null
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

Export-ModuleMember -Function New-CrewState, Add-CrewWorker, Set-CrewStage,
                              Set-CrewWaitingOn, Clear-CrewWaitingOn,
                              Get-CrewWorker, Get-CrewByStage, Save-CrewState, Import-CrewState
