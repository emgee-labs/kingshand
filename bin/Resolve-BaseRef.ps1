#Requires -Version 7.0
<#
.SYNOPSIS
  Defines Resolve-BaseRef: the ref a dispatched worker's branch is cut from and diffed against.
.DESCRIPTION
  Dot-source this file to get the function. It lives apart from Dispatch-Worker.ps1 so the
  base-resolution rule can be tested against throwaway repositories without spawning a worker.

  What this returns is BOTH the branch point and the landing base. Dispatch-Worker.ps1 hands the
  same string to `git worktree add -b <branch> <path> <base>` and to the crew record, so the two
  cannot disagree. That was not always true, and this header used to say so the other way round -
  that `origin/HEAD` "is what Claude Code actually branches the worktree from". It was, while
  `claude --bg --worktree` created the worktree and chose its own branch point; kingshand creates
  the worktree itself now, so the choice is made here and recording it is not a guess about it.

  THE DEFAULT BRANCH IS NOT THE INTEGRATION BRANCH. A repository can land a fresh clone on `main`
  while every pull request targets `dev` and every worker branches from `dev`. `origin/HEAD` only
  ever names the first of those, so a repository that separates them and is resolved from
  `origin/HEAD` gets its workers cut from a tree missing everything on the integration branch,
  proposing their work against a branch they were never based on.

  So a DECLARED integration branch is read first, from `pr.base_branch` in `.no-mistakes.yaml` at
  the repo root. That is the same key the review gate reads when it opens the pull request, so one
  declaration serves both and there is no second place to keep in step. It also ships with a
  clone, which a local ref like `origin/HEAD` does not. A repository that declares nothing is
  resolved by the candidate chain below exactly as it was before any of this existed, which is
  most of them.

  The declared branch is a candidate and nothing more. It is confirmed with `git rev-parse
  --verify` like every other, rejected outright if it names a `worktree-*` branch like every
  other, and skipped when it does not resolve - never trusted because somebody declared it. It is
  skipped with a warning rather than in silence, because a declaration the dispatcher cannot honour
  is precisely the disagreement with the gate this whole mechanism exists to prevent.

  The reader below is deliberately NARROW: a top-level `pr:` block mapping, and a `base_branch:`
  key among its immediate children. It is not a YAML parser and must not grow into one - the
  cautionary tale is in Dispatch-Worker.ps1's header, where reading paths back out of a brief's
  prose cost six review rounds and never ran out of bugs. Two things follow. Anything this reader
  does not recognise as a declaration reads as no declaration, which degrades to the old chain and
  is therefore safe. And the one form that would be BOTH plausible and silently divergent - `pr:`
  written inline, as a flow mapping the gate honours and this does not - is refused by name rather
  than ignored.

  An unresolvable base is worse than a wrong one. `git log "$base..HEAD"` and
  `git diff "$base...HEAD"` against a ref that does not exist both fail to stderr and write
  NOTHING to stdout, so the landing gate sees a zero-file diff and an empty attribution scan
  and reads both as clean - against commits it never inspected. The old fallback invented the
  literal string `origin/main` on a repository with no remote at all, which is exactly the
  posture `/annex` proposes for a remoteless repo, so that was the common path.

  Every candidate is therefore confirmed with `git rev-parse --verify`, and an `origin/...`
  name is only ever used when that remote-tracking ref actually exists. When nothing resolves
  this throws rather than returning a name that will silently empty the evidence later.

  A resolvable base can still be the wrong base. Kingshand's own worker branches are named
  `worktree-<name>` by Dispatch-Worker.ps1, and `origin/HEAD` transiently pointed at one
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

    # Set inside the function rather than at file scope. This file is DOT-SOURCED, so a
    # file-scope Set-StrictMode would follow the dot into whatever sourced it - the dispatcher,
    # or the Pester file - and change the strictness of code that never asked for it.
    Set-StrictMode -Version Latest

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

    # The repository's own declaration of where its work integrates, or '' when it makes none.
    # Absence is a state and the common one: it returns '' and the caller resolves as before.
    # A file that is there and cannot be read is NOT that state - it is a file whose contents
    # nobody knows - so it throws instead of reading as "declares nothing".
    function Get-DeclaredIntegrationBranch {
        $path = Join-Path $RepoPath '.no-mistakes.yaml'
        if (-not (Test-Path -LiteralPath $path)) { return '' }
        if (Test-Path -LiteralPath $path -PathType Container) {
            throw ("$path is a directory. It is where a repository declares the branch its work " +
                   "integrates into, so a directory there means nobody can read that " +
                   "declaration, and this refuses rather than reading it as a repository that " +
                   "declares nothing.")
        }

        try { $lines = @(Get-Content -LiteralPath $path -ErrorAction Stop) }
        catch {
            throw ("Cannot read $path ($($_.Exception.Message)). It declares the branch this " +
                   "repository's work integrates into, and an unreadable declaration is not the " +
                   "same as no declaration - basing a worker on the default branch instead would " +
                   "cut it from a tree its pull request is not proposed against.")
        }

        $inPr     = $false
        $prIndent = -1
        foreach ($line in $lines) {
            if (-not $line.Trim() -or $line -match '^\s*#') { continue }

            # A top-level key: no leading whitespace, and a colon somewhere after the name.
            if ($line -match '^(?<key>[^\s#][^:]*):(?<rest>.*)$') {
                $key  = $Matches['key'].Trim()
                $rest = $Matches['rest'].Trim()
                if ($key -ne 'pr') { $inPr = $false; continue }
                # `pr: {base_branch: dev}` and `pr: dev` are forms the gate reads and this does
                # not. Ignoring them would put the dispatcher and the gate on different branches
                # with nothing said about it, so they are refused by name.
                if ($rest -and -not $rest.StartsWith('#')) {
                    throw ("$path writes the pr key with a value on the same line: " +
                           "$($line.Trim()). This reads only the block form, so an inline " +
                           "mapping would leave the dispatcher basing workers somewhere the " +
                           "review gate does not propose them. Write it as a block instead - " +
                           "pr: on its own line, with base_branch: <branch> beneath it.")
                }
                $inPr     = $true
                $prIndent = -1
                continue
            }

            if (-not $inPr) { continue }

            # Indented, so it is a child of `pr:`. The FIRST child fixes the indentation of that
            # level, and only that level is read: `base_branch` nested deeper belongs to some
            # sub-mapping of `pr:` and is a different key with the same name.
            $indent = $line.Length - $line.TrimStart().Length
            if ($prIndent -lt 0) { $prIndent = $indent }
            if ($indent -ne $prIndent) { continue }

            if ($line -match '^\s+base_branch\s*:(?<val>.*)$') {
                $val = $Matches['val'].Trim()
                # An unquoted scalar ends at a comment. A quoted one does not, so the quotes are
                # stripped after, and only as a matched pair.
                if ($val -notmatch '^["'']') { $val = ($val -replace '\s+#.*$', '').Trim() }
                if ($val.Length -ge 2 -and
                    ($val[0] -eq '"' -or $val[0] -eq "'") -and $val[-1] -eq $val[0]) {
                    $val = $val.Substring(1, $val.Length - 2)
                }
                # `base_branch:` with nothing after it declares nothing, which is how the gate
                # itself reads an empty value.
                return $val.Trim()
            }
        }

        ''
    }

    $declared = Get-DeclaredIntegrationBranch

    $candidates = [System.Collections.Generic.List[string]]::new()

    # 0. The declared integration branch, when the repository declares one. Remote-tracking form
    #    first for the same reason candidate 2 comes before candidate 3: local `dev` is often
    #    behind `origin/dev`, and diffing the worker's branch against the local copy attributes
    #    every upstream commit in that gap to the worker.
    if ($declared) {
        $candidates.Add("origin/$declared")
        $candidates.Add($declared)
    }

    # 1. The remote default branch, when the repo records one. It is what a fresh clone lands on,
    #    which is the right answer for every repository that has not separated the two.
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

    # A worker branch is never a base, however well it resolves, and a declared one is no
    # exception. Rejected before the resolve loop so that `origin/HEAD` pointing at one falls
    # through to the real default branch rather than winning on position.
    $rejected = @($candidates | Where-Object { Test-WorkerBranch $_ })
    $usable   = @($candidates | Where-Object { -not (Test-WorkerBranch $_) })

    foreach ($c in $usable) {
        if (Test-GitRef $c) {
            $global:LASTEXITCODE = 0
            # Said out loud when the repository declared a branch and the ref in hand is neither
            # form of it. The worker is about to be cut from one branch while its pull request is
            # proposed against another, which is the failure this reader was added to close - so
            # it is reported rather than left for whoever reads the landing diff.
            if ($declared -and $c -ne $declared -and $c -ne "origin/$declared") {
                Write-Warning ("$RepoPath declares $declared as the branch its work integrates " +
                               "into, but neither origin/$declared nor $declared resolves here, " +
                               "so this worker is based on $c instead - while its pull request " +
                               "is still proposed against $declared. Fetch $declared before " +
                               "landing, or the landing diff measures the wrong branch.")
            }
            return $c
        }
    }

    $global:LASTEXITCODE = 0
    $msg = "Cannot resolve a base ref in ${RepoPath}: none of $($usable -join ', ') " +
           "exists. Refusing to record a base that would make the landing evidence silently empty."
    if ($declared) {
        $msg += " $declared is the branch this repository declares its work integrates into, and " +
                "it was tried first in both forms - a declaration is a candidate here, not a " +
                "guarantee that the ref exists."
    }
    if ($rejected.Count -gt 0) {
        $msg += " Rejected the worker branch(es) $($rejected -join ', '): a worktree-* branch " +
                "belongs to another worker, so basing on it would measure this worker's diff and " +
                "attribution scan against unlanded work instead of the default branch."
    }
    throw $msg
}
