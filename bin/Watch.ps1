#Requires -Version 7.0
<#
.SYNOPSIS
  The Hand's watches as one short command each, printing nothing while it waits and exactly one
  line when it ends: the outcome, and what to do next.
.DESCRIPTION
  Four verbs, each the whole of a watch the Hand used to write out by hand:

    worker   <id>   a worker, until it needs the Hand - Watch-Worker
    gate     <id>   the gate run on that worker's branch, until it parks or ends - Watch-GateRun
    delivery <id>   both: the worker, then the gate it started if it went idle while that runs -
                    Watch-Delivery
    report   <id>   data\<id>\report.md, until the worker writes it - Watch-Report

  bin\Watch.psm1 owns every outcome and the wording of every line; this script only resolves the
  id and prints what the module returns. The worker's worktree and branch come from the durable
  record, state\crew.json, so the command stays one id long. -RepoPath and -Branch name them
  directly instead, for a gate whose worker is not recorded.

  Run it as ONE harness-tracked background job per watch. Its completion is what wakes the Hand,
  and its one line is the whole report.

  Never throws and never prints more than one line. A record it cannot read, an id it cannot find
  or a watch that throws all come back as a line naming that failure.
.EXAMPLE
  & $env:KINGSHAND_HOME\bin\Watch.ps1 worker T-1001
.EXAMPLE
  & $env:KINGSHAND_HOME\bin\Watch.ps1 delivery T-1001
.EXAMPLE
  & $env:KINGSHAND_HOME\bin\Watch.ps1 gate -RepoPath C:\repos\acme-api -Branch feature-x
.EXAMPLE
  & $env:KINGSHAND_HOME\bin\Watch.ps1 report T-1001
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)][ValidateSet('worker', 'gate', 'delivery', 'report')]
    [string]$Verb,
    [Parameter(Position = 1)][string]$Id = '',
    [string]$RepoPath = '',
    [string]$Branch = '',
    # 0 takes the module's own default, which is what every ordinary arm does.
    [int]$TimeoutMinutes = 0,
    [int]$StallMinutes = 0,
    [string]$StatePath = ''
)

Set-StrictMode -Version Latest

try {
    Import-Module (Join-Path $PSScriptRoot 'Watch.psm1') -Force -ErrorAction Stop

    $timing = @{}
    if ($TimeoutMinutes -gt 0) { $timing.TimeoutMinutes = $TimeoutMinutes }
    $stall = @{}
    if ($StallMinutes -gt 0) { $stall.StallMinutes = $StallMinutes }

    $line = switch ($Verb) {
        'worker' {
            if (-not $Id) { 'NOT ARMED worker - no worker id was given. Next: name the worker.' ; break }
            Watch-Worker -Name $Id @timing @stall
        }
        'report' {
            if (-not $Id) { 'NOT ARMED report - no worker id was given. Next: name the worker.' ; break }
            Watch-Report -Name $Id @timing
        }
        default {
            $repo = $RepoPath; $br = $Branch
            if (-not ($repo -and $br)) {
                if (-not $Id) {
                    "NOT ARMED $Verb - neither a worker id nor -RepoPath and -Branch were given. " +
                    'Next: name the worker.'
                    break
                }
                $where = @{ Name = $Id }
                if ($StatePath) { $where.StatePath = $StatePath }
                $t = Resolve-WatchTarget @where
                if (-not $t.ok) {
                    "NOT ARMED $Verb $Id - $($t.error), so there is no worktree or branch to " +
                    'watch. Next: check the id, or pass -RepoPath and -Branch.'
                    break
                }
                if (-not $repo) { $repo = $t.repo }
                if (-not $br)   { $br = $t.branch }
            }
            if ($Verb -eq 'gate') {
                Watch-GateRun -RepoPath $repo -Branch $br @timing
            } elseif (-not $Id) {
                'NOT ARMED delivery - a delivery watch needs the worker id as well. Next: name the worker.'
            } else {
                Watch-Delivery -Name $Id -RepoPath $repo -Branch $br @timing @stall
            }
        }
    }
    (@($line) -join ' ') -replace '\s+', ' '
} catch {
    "WATCH FAILED $Verb $Id - $(($_.Exception.Message -replace '\s+', ' ').Trim()) Next: re-arm " +
    'this watch; whatever it was watching is unwatched, not finished.'
}
