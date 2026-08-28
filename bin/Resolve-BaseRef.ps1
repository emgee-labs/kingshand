#Requires -Version 7.0
<#
.SYNOPSIS
  Defines Resolve-BaseRef: the ref a dispatched worker's branch is diffed against at landing.
.DESCRIPTION
  Dot-source this file to get the function. It lives apart from Dispatch-Worker.ps1 so the
  base-resolution rule can be tested against throwaway repositories without spawning a worker.

  An unresolvable base is worse than a wrong one. `git log "$base..HEAD"` and
  `git diff "$base...HEAD"` against a ref that does not exist both fail to stderr and write
  NOTHING to stdout, so the landing gate sees a zero-file diff and an empty attribution scan
  and reads both as clean - against commits it never inspected. The old fallback invented the
  literal string `origin/main` on a repository with no remote at all, which is exactly the
  posture `/import-project` proposes for a remoteless repo, so that was the common path.

  Every candidate is therefore confirmed with `git rev-parse --verify`, and an `origin/...`
  name is only ever used when that remote-tracking ref actually exists. When nothing resolves
  this throws rather than returning a name that will silently empty the evidence later.

  A resolvable base can still be the wrong base. Kingshand's own worker branches are named
  `worktree-<name>` by `claude --bg --worktree`, and `origin/HEAD` transiently pointed at one
  while several workers were dispatched: two of them were recorded with
  `base: origin/worktree-acme-low-med-email`, a branch belonging to a different worker and two
  commits ahead of the real default. Their landing diff and attribution scan would have been
  measured against another worker's unlanded work rather than against the default branch. A
  `worktree-*` ref, local or remote-tracking, is therefore rejected outright here, and if no
  non-worker default can be resolved this throws for the same reason it throws when nothing
  resolves at all - a contaminated base is not better than no base.
#>

function Resolve-BaseRef {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoPath)

    # Every git call below is a PROBE: a non-zero exit is the answer, not a failure. The
    # dispatcher runs under $ErrorActionPreference = 'Stop', and where native command errors are
    # mapped onto that preference the first missing ref would terminate the whole dispatch with
    # "Program git.exe ended with non-zero exit code: 1". Scoped to this function only, so the
    # caller's own git calls keep whatever behaviour it chose.
    $PSNativeCommandUseErrorActionPreference = $false

    function Test-GitRef {
        param([string]$Ref)
        if (-not $Ref) { return $false }
        $null = & git -C $RepoPath rev-parse --verify --quiet "$Ref^{commit}" 2>$null
        $LASTEXITCODE -eq 0
    }

    # A kingshand worker branch, local (`worktree-x`) or remote-tracking (`origin/worktree-x`).
    # Anchored at the start so a legitimate branch like `feature/worktree-cleanup` is untouched.
    function Test-WorkerBranch {
        param([string]$Ref)
        [bool]($Ref -and $Ref -match '^(origin/)?worktree-')
    }

    $candidates = [System.Collections.Generic.List[string]]::new()

    # 1. The remote default branch, when the repo records one. This is what Claude Code
    #    actually branches the worktree from, so it stays first.
    $originHead = & git -C $RepoPath symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>$null
    if ($originHead) { $candidates.Add($originHead.Trim()) }

    $head = & git -C $RepoPath rev-parse --abbrev-ref HEAD 2>$null
    if ($head) {
        $head = $head.Trim()
        if ($head -and $head -ne 'HEAD') {
            # 2. The remote-tracking ref for the checked-out branch - offered only as a
            #    candidate, never asserted: it is dropped below unless rev-parse confirms it.
            $candidates.Add("origin/$head")
            # 3. The repo's LOCAL default branch. On a remoteless repo this is the answer.
            $candidates.Add($head)
        }
    }

    foreach ($c in @('origin/main', 'origin/master', 'main', 'master')) { $candidates.Add($c) }

    # A worker branch is never a base, however well it resolves. Rejected before the resolve
    # loop so that `origin/HEAD` pointing at one falls through to the real default branch rather
    # than winning on position.
    $rejected = @($candidates | Where-Object { Test-WorkerBranch $_ })
    $usable   = @($candidates | Where-Object { -not (Test-WorkerBranch $_) })

    foreach ($c in $usable) {
        if (Test-GitRef $c) {
            $global:LASTEXITCODE = 0
            return $c
        }
    }

    $global:LASTEXITCODE = 0
    $msg = "Cannot resolve a base ref in ${RepoPath}: none of $($usable -join ', ') " +
           "exists. Refusing to record a base that would make the landing evidence silently empty."
    if ($rejected.Count -gt 0) {
        $msg += " Rejected the worker branch(es) $($rejected -join ', '): a worktree-* branch " +
                "belongs to another worker, so basing on it would measure this worker's diff and " +
                "attribution scan against unlanded work instead of the default branch."
    }
    throw $msg
}
