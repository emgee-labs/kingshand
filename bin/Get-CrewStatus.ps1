#Requires -Version 7.0
<#
.SYNOPSIS
  Joins crew.json (our intent) with `claude agents --json` (live truth).
.DESCRIPTION
  Where the two disagree, agents --json wins for liveness and crew.json wins for intent.
  A worker present in crew.json but absent from agents --json has ended - live is false.
#>
[CmdletBinding()]
param([string]$StatePath)

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot\Paths.psm1" -Force
Import-Module "$PSScriptRoot\Crew.psm1" -Force

# Resolved in the body rather than as a parameter default: the root comes from Get-KingshandHome,
# which is the one place that decision is made, and a param default cannot call it.
if (-not $StatePath) { $StatePath = Join-Path (Get-KingshandHome) 'state\crew.json' }

$state = Import-CrewState -Path $StatePath

$agents = @()
$raw = & claude agents --json 2>$null
if ($raw) { $agents = @($raw | ConvertFrom-Json) }

foreach ($id in $state.workers.Keys) {
    $w = $state.workers[$id]
    $a = $agents | Where-Object { $_.id -eq $id } | Select-Object -First 1
    [PSCustomObject]@{
        id          = $id
        ticket      = $w.ticket
        repo        = $w.repo
        stage       = $w.stage
        live        = [bool]$a
        agentState  = if ($a) { $a.state }  else { '' }
        agentStatus = if ($a) { $a.status } else { '' }
    }
}
