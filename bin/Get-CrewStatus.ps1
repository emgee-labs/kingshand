#Requires -Version 7.0
<#
.SYNOPSIS
  Joins crew.json (our intent) with herdr's agent list (live truth).
.DESCRIPTION
  Where the two disagree, herdr wins for liveness and crew.json wins for intent. A worker present
  in crew.json but absent from herdr has ended - live is false.

  crew.json stores the kingshand id; herdr only ever knows the normalised name that
  ConvertTo-HerdrAgentName derives from it, so the join is made on the normalised form. A worker
  recorded before the herdr port carries a supervisor-minted id that was never a herdr name, and it
  correctly reads as not live.

  AGENT STATE IS HERDR'S VOCABULARY, NOT THE OLD ONE, and the two do not line up. `claude agents
  --json` reported `done` for a worker that had finished. herdr reports one of idle, working,
  blocked, done or unknown, and its `idle` is the state a worker sits in whenever it is not
  mid-turn - which includes the seconds between `agent start` and the brief being submitted. So
  `idle` is NOT a completion signal: read as the old `done`, every worker would look finished the
  moment it started. Completion under herdr is an event, not a state you can sample. The words are
  therefore kept as herdr's own rather than translated into a vocabulary that no longer means what
  it used to.

  `agentState` IS CORRECTED BY THE WORKER'S SCREEN, not copied from herdr's answer. herdr 0.8.2
  with manifest 2026.08.21.1 was measured on this machine reporting `idle` for a worker sitting on
  an unanswered AskUserQuestion menu, and `done` for that same still-blocked worker minutes later
  while a genuinely finished worker reported `idle` - the two states inverted. So this reads
  Get-HerdrAgentState, which is the one place that correction lives, and a worker whose screen
  shows a prompt reports `blocked` whatever herdr calls it.
#>
[CmdletBinding()]
param([string]$StatePath)

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot\Paths.psm1" -Force
Import-Module "$PSScriptRoot\Crew.psm1" -Force
Import-Module "$PSScriptRoot\Herdr.psm1" -Force

# Resolved in the body rather than as a parameter default: the root comes from Get-KingshandHome,
# which is the one place that decision is made, and a param default cannot call it.
if (-not $StatePath) { $StatePath = Join-Path (Get-KingshandHome) 'state\crew.json' }

$state = Import-CrewState -Path $StatePath

# ONE presence call for the whole join, and none at all when there are no workers to join it to.
# This is what says which workers herdr knows about; what state each one is really in is corrected
# per live worker below.
$agents = @()
if ($state.workers.Count -gt 0) {
    # Get-HerdrAgents already swallows herdr's own errors and returns an empty list, so a server
    # that is not running reads as no live agents - which is the truth: herdr's panes die with it.
    # A herdr that is not installed at all still throws, and that is deliberate: reporting every
    # worker as dead because the tool is missing would be a confident lie.
    #
    # Deliberately NOT wrapped in @(). Get-HerdrAgents returns via the leading-comma idiom, so the
    # pipeline hands back the intact agents array as one object; @() would nest it a second time
    # and every worker would then fail to match an agent that is right there.
    $agents = Get-HerdrAgents
}

foreach ($id in $state.workers.Keys) {
    $w = $state.workers[$id]

    # An id with no letter in it cannot name a herdr agent at all, so normalisation refuses. That
    # is a worker herdr can never have known - it reads as not live, and it must not take the rest
    # of the fleet's status down with it.
    $herdrName = $null
    try { $herdrName = ConvertTo-HerdrAgentName -Name $id } catch { $herdrName = $null }

    $a = $null
    if ($herdrName) {
        $a = $agents |
             Where-Object { $_.PSObject.Properties.Name -contains 'name' -and $_.name -eq $herdrName } |
             Select-Object -First 1
    }

    # The corrected state, read only for a worker herdr actually knows. It costs an extra
    # `agent get` and a live screen read PER LIVE WORKER, and that is worth paying: the row this
    # produces is what `muster` and `survey` route on, and the failure it prevents is the Hand
    # being told a worker waiting on a human has finished - then tearing down its worktree and
    # reporting work nobody did. A worker herdr has never heard of has no screen to read and
    # cannot be sitting on a prompt, so a dead or pre-herdr worker adds no calls at all.
    $liveState = ''
    if ($a) {
        # Never `$a.agent_status`. Get-HerdrAgentState is the one owner of the correction, and a
        # second reader of the raw word is how one of them silently goes back to being wrong.
        $corrected = Get-HerdrAgentState -Name $id
        # $null means the agent went away between the list call and this read. That is unknown,
        # not finished, so it reports nothing rather than the stale word being corrected.
        if ($corrected) { $liveState = "$corrected" }
    }

    [PSCustomObject]@{
        id          = $id
        ticket      = $w.ticket
        repo        = $w.repo
        stage       = $w.stage
        live        = [bool]$a
        # herdr's state word corrected by the worker's screen - see the header.
        agentState  = $liveState
        # The nearest thing herdr has to the old free-text status line. Its agent record carries a
        # state and a title and nothing else; the worker's actual words come from Read-HerdrAgent.
        agentStatus = if ($a -and $a.title) { "$($a.title)" } else { '' }
    }
}
