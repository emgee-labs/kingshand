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
# Add-CrewWorker and Set-CrewStage deliberately return nothing. A hashtable is a reference
# type, so mutation is visible to the caller without a return value. Returning the state would
# emit it to the pipeline at every call site and flood both test output and the Hand's
# console with hashtable dumps.

$script:ValidStages = @('dispatched', 'implementing', 'gating', 'ready', 'landed', 'failed')
$script:ValidKinds  = @('ticket', 'adhoc')

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
    }
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
    $raw
}

Export-ModuleMember -Function New-CrewState, Add-CrewWorker, Set-CrewStage,
                              Get-CrewWorker, Get-CrewByStage, Save-CrewState, Import-CrewState
