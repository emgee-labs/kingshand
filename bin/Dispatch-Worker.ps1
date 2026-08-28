#Requires -Version 7.0
<#
.SYNOPSIS
  Spawns one background worker in its own git worktree and returns its supervisor-assigned id.
.DESCRIPTION
  The worker id cannot be chosen: --session-id is ignored when dispatching with --bg --worktree,
  so the supervisor assigns its own. We identify the new worker by diffing
  `claude agents --json` before and after the spawn.

  `claude` on Windows resolves to a .ps1 that Start-Process cannot launch ("%1 is not a valid
  Win32 application"), so we invoke the .cmd shim instead. Which shim, and where it lives, is
  resolved at run time by `Paths.psm1` - it used to be one machine's npm prefix written out in
  full, which is a path no other machine has.

  The brief is passed BY PATH, never by value. Start-Process flattens -ArgumentList into a
  single command line, and a multi-line string does not survive that: a 1,733-character brief
  arrived at the worker as its 57-character first line, with every requirement silently
  dropped. The worker only recovered because it went looking for brief.md on disk. So the
  prompt is now a one-line instruction naming the brief, and --add-dir grants read access to
  the brief's directory, which lives outside the repo.
.EXAMPLE
  $r = .\Dispatch-Worker.ps1 -RepoPath C:\repos\foo -Name T-1001 -BriefPath $env:KINGSHAND_HOME\data\T-1001\brief.md
  $r.id, $r.worktree, $r.branch
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepoPath,
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$BriefPath,
    [int]$TimeoutSeconds = 90
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $RepoPath))  { throw "Repo path not found: $RepoPath" }
if (-not (Test-Path $BriefPath)) { throw "Brief not found: $BriefPath" }

Import-Module (Join-Path $PSScriptRoot 'Paths.psm1') -Force
$claudeCmd = Get-ClaudeCommandPath
if (-not $claudeCmd) { throw (Get-ClaudeCommandHint) }

$BriefPath = (Resolve-Path $BriefPath).Path
$briefDir  = Split-Path $BriefPath -Parent

# The worktree branches from the REMOTE default branch when the repo has one, not the local
# branch. Local main is often behind origin/main, and diffing the worker's branch against local
# main then attributes the upstream commits in that gap to the worker - including other people's
# Co-Authored-By trailers, which trips the attribution check on a colleague's commit. Record the
# real base at dispatch.
#
# Resolved BEFORE the spawn on purpose: Resolve-BaseRef refuses rather than inventing a ref, and
# a refusal after Start-Process would leave an orphaned worker running in the repo.
. (Join-Path $PSScriptRoot 'Resolve-BaseRef.ps1')
$base = Resolve-BaseRef -RepoPath $RepoPath

# One line, so nothing can be lost to command-line flattening. The worker reads the rest.
$prompt = "Read the file $BriefPath in full - it is your brief and the complete statement of " +
          "your task - then carry it out exactly as written. Treat every requirement, exclusion " +
          "and Done-means item in it as binding. If you cannot read that file, stop immediately " +
          "and report that instead of guessing at the task."

function Get-BackgroundIds {
    $raw = & claude agents --json 2>$null
    if (-not $raw) { return @() }
    , @(($raw | ConvertFrom-Json) | Where-Object { $_.kind -eq 'background' } | ForEach-Object { $_.id })
}

$before = Get-BackgroundIds

Push-Location $RepoPath
try {
    # Argument ORDER is load-bearing. --add-dir is variadic (<directories...>), so it keeps
    # consuming positionals: with the prompt after it, the prompt is parsed as another directory
    # and the worker starts at an empty prompt, idle, having been told nothing. Keep a
    # non-variadic flag between --add-dir and the prompt so the directory list is terminated.
    $null = Start-Process -FilePath $claudeCmd -ArgumentList @(
        '--bg', '--worktree', $Name,
        '--add-dir', "`"$briefDir`"",
        '--permission-mode', 'bypassPermissions',
        "`"$prompt`""
    ) -NoNewWindow -PassThru
} finally {
    Pop-Location
}

# Poll for the new id rather than sleeping a fixed amount - spawn time varies with repo size.
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$newId = $null
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 2
    $after = Get-BackgroundIds
    $diff = @($after | Where-Object { $_ -notin $before })
    if ($diff.Count -ge 1) { $newId = $diff[0]; break }
}

if (-not $newId) {
    throw "Worker did not appear in 'claude agents --json' within $TimeoutSeconds seconds."
}

# The worktree path is derived, not read from `agents --json`.
#
# `cwd` is racy: for the first several seconds after dispatch it still reports the repo root,
# and only later flips to the worktree. Reading it here returned the repo path and would have
# put the wrong path into crew.json, so every later `git -C <worktree>` would silently operate
# on the main checkout instead. Claude Code always creates worktrees at this exact location,
# so deriving it is both correct and immune to timing.
$worktree = Join-Path (Join-Path (Join-Path $RepoPath '.claude') 'worktrees') $Name

[hashtable]@{
    id       = $newId
    worktree = $worktree
    branch   = "worktree-$Name"
    base     = $base
}
