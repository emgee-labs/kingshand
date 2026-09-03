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

  A declaration goes unhonoured for exactly two reasons and the warning names the one that
  applies, because the wrong reason sends the reader after the wrong fix. Either the ref does not
  exist here, and fetching it is the answer - though only where there is an `origin` to fetch from,
  so on a remoteless repository the warning says the branch does not exist and asks for it rather
  than sending the reader after an upstream that is not there either; or it names a `worktree-*`
  branch, which resolves perfectly well and will still never be honoured, so telling that reader to
  fetch it sends them to look for a branch they already have while the real fault - a declaration
  pointing at another worker's branch - goes unsaid.

  Honouring the declaration in its LOCAL form is warned about too. `origin/dev` comes first
  precisely because a local `dev` is often behind it, so falling through to the local copy on a
  repository that has an `origin` means the declared branch was never fetched: the worktree is cut
  from - and the landing diff measured against - whatever that stale copy holds, and every
  upstream commit in the gap is attributed to the worker. The base is still the declared branch,
  so this is a caution and not a refusal, and a repository with no remote at all has no gap to
  warn about.

  Where there IS a remote, though, "fetch it" is a guess dressed as an instruction. A missing
  `origin/dev` means either that origin has `dev` and this clone never fetched it - the gap is
  real and fetching closes it - or that origin has no `dev` at all, the integration branch existing
  only here, where there is no gap and `git fetch origin dev` answers `couldn't find remote ref`.
  Telling them apart needs a network round trip on a path that must not hang a dispatch, so both
  warnings name both states and the action each one takes rather than asserting the likelier one.

  The reader below is deliberately NARROW: a top-level `pr:` block mapping, and a `base_branch:`
  key among its immediate children. It is not a YAML parser and must not grow into one - the
  cautionary tale is in Dispatch-Worker.ps1's header, where reading paths back out of a brief's
  prose cost six review rounds and never ran out of bugs. Two things follow. Anything this reader
  does not recognise as a declaration reads as no declaration, which degrades to the old chain and
  is therefore safe. And the one form that would be BOTH plausible and silently divergent - a
  `base_branch` written inline on the `pr:` key, as a flow mapping the gate honours and this does
  not - is refused by name rather than ignored. An inline `pr:` that names no `base_branch` at all,
  `pr: {}` or `pr: null`, declares nothing for either reader to disagree about, so it reads as no
  declaration rather than blocking every dispatch into that repository.

  That refusal is decided on the VALUE, never on the raw line. The word `base_branch` inside the
  comment on `pr: {} # base_branch is not set here` is not a declaration, and refusing it blocks
  every dispatch into that repository over a line that declares nothing - so the comment is
  stripped first, and what remains is matched as a key of the mapping rather than searched for a
  substring. The mirror of that mistake is a flow mapping running past the end of its line -
  `pr: {`, then `base_branch: dev`, then `}` - whose children this reader skips, because they are
  indented under a key it has already left. That is the silent divergence again, so unknown
  contents are refused like an unreadable file rather than read as absent ones. Neither is YAML
  anyone here writes; both are cheap to be right about and were wrong in opposite directions.

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

    # Whether this repository has an `origin` at all. It decides whether a local ref can be behind
    # a remote one, which is the difference between a stale base and the only base there is.
    function Test-OriginRemote {
        $null = & git -C $RepoPath remote get-url origin 2>$null
        $LASTEXITCODE -eq 0
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
                if ($rest -and -not $rest.StartsWith('#')) {
                    # The comment is stripped before the value is judged, so what follows reads
                    # the declaration and never the prose beside it. Judging the raw line refused
                    # `pr: {} # base_branch is not set here` for a word inside its own comment -
                    # a line that declares nothing, blocking every dispatch into that repository.
                    $inline = ($rest -replace '\s+#.*$', '').Trim()

                    # A flow mapping is the one inline form that is both plausible and silently
                    # divergent, because the gate reads it and this does not. Any other scalar -
                    # `pr: null`, `pr: ~` - names no branch for the two readers to disagree about.
                    if ($inline.StartsWith('{')) {
                        if ($inline -match '^\{(?<body>[^{}]*)\}$') {
                            # `pr: {base_branch: dev}`. Refused by name rather than ignored, and
                            # matched as a KEY of the mapping: a value that merely contains the
                            # word declares nothing. `pr: {}` and `pr: {draft: true}` fall through
                            # to the same "no declaration" as any other inline value.
                            if ($Matches['body'] -match '(^|,)\s*["'']?base_branch["'']?\s*:') {
                                throw ("$path declares base_branch inline on the pr key: " +
                                       "$($line.Trim()). This reads only the block form, so an " +
                                       "inline mapping would leave the dispatcher basing workers " +
                                       "somewhere the review gate does not propose them. Write " +
                                       "it as a block instead - pr: on its own line, with " +
                                       "base_branch: <branch> beneath it.")
                            }
                        } else {
                            # The mapping runs past the end of this line, so its keys are on lines
                            # this reader skips as children of nothing - which is how a multi-line
                            # `pr: {` / `base_branch: dev` / `}` came back as no declaration at
                            # all. Unknown contents are refused rather than read as absent ones:
                            # the same rule as an unreadable file, for the same reason.
                            throw ("$path writes pr as a flow mapping this reader cannot finish " +
                                   "reading: $($line.Trim()). It does not close on its own line, " +
                                   "so whether it declares base_branch is unknown, and reading " +
                                   "it as no declaration would silently base workers somewhere " +
                                   "the review gate does not propose them. Write it as a block " +
                                   "instead - pr: on its own line, with its keys beneath it.")
                        }
                    }
                    $inPr = $false
                    continue
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
                # A quoted scalar ends at its own closing quote, so the value is what sits between
                # the pair and everything after it is discarded - an inline comment, usually,
                # which is why the two cannot be handled in sequence: stripping the comment first
                # never sees the quotes as a pair, and stripping the quotes first never sees the
                # comment. An unquoted scalar has no closing quote and ends at the comment instead.
                if ($val -match '^(?<q>["''])(?<inner>[^"'']*)\k<q>') {
                    $val = $Matches['inner']
                } else {
                    $val = ($val -replace '\s+#.*$', '')
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

    # A declared worker branch is dropped in BOTH forms above, so it never reaches the resolve
    # loop and "neither form resolves" would be a false account of why it was not honoured.
    $declaredIsWorker = [bool]($declared -and (Test-WorkerBranch $declared))

    foreach ($c in $usable) {
        if (Test-GitRef $c) {
            # Said out loud when the repository declared a branch and the ref in hand is neither
            # form of it. The worker is about to be cut from one branch while its pull request is
            # proposed against another, which is the failure this reader was added to close - so
            # it is reported rather than left for whoever reads the landing diff.
            if ($declared -and $c -ne $declared -and $c -ne "origin/$declared") {
                if ($declaredIsWorker) {
                    Write-Warning ("$RepoPath declares $declared as the branch its work " +
                                   "integrates into, but that is a kingshand worker branch and " +
                                   "a worktree-* ref is never a base - it belongs to another " +
                                   "worker, so basing on it would measure this worker's diff " +
                                   "and attribution scan against unlanded work. It resolves " +
                                   "fine and was refused anyway, so fetching it changes " +
                                   "nothing: this worker is based on $c instead, while its pull " +
                                   "request is still proposed against $declared. Correct " +
                                   "pr.base_branch in .no-mistakes.yaml.")
                } elseif (Test-OriginRemote) {
                    # Two states look identical from here without asking the remote, and the
                    # answer to one is not the answer to the other: origin has the branch and
                    # this clone never fetched it, or origin has no such branch at all and
                    # fetching cannot work. Both are named rather than one asserted.
                    Write-Warning ("$RepoPath declares $declared as the branch its work " +
                                   "integrates into, but neither origin/$declared nor " +
                                   "$declared resolves here, so this worker is based on $c " +
                                   "instead - while its pull request is still proposed against " +
                                   "$declared. Fetch $declared before landing if origin has it, " +
                                   "or the landing diff measures the wrong branch. If origin has " +
                                   "no $declared either, create it or correct pr.base_branch in " +
                                   ".no-mistakes.yaml.")
                } else {
                    # No origin, so there is nothing to fetch from and no pull request to
                    # misdirect: the declaration names a branch this repository simply does not
                    # have. "Fetch it" is the one actionable sentence in the message, and here it
                    # sends the reader after an upstream that does not exist.
                    Write-Warning ("$RepoPath declares $declared as the branch its work " +
                                   "integrates into, but no $declared branch exists here and " +
                                   "there is no origin to fetch one from, so this worker is " +
                                   "based on $c instead and the landing diff is measured " +
                                   "against that. Create $declared, or correct pr.base_branch " +
                                   "in .no-mistakes.yaml.")
                }
            } elseif ($declared -and $c -eq $declared -and (Test-OriginRemote)) {
                # The declared branch was honoured, but only as a local ref on a repo that has a
                # remote - so origin/$declared was never fetched and nothing has confirmed the
                # local copy is current. Which of the two states this is cannot be told apart
                # from here: origin may hold the branch, or the integration branch may exist
                # only in this clone, in which case there is no gap and nothing to fetch.
                Write-Warning ("$RepoPath declares $declared as the branch its work integrates " +
                               "into, and only the local $declared resolves - origin/$declared " +
                               "does not, so this worker is based on a local copy nothing has " +
                               "confirmed is up to date. Fetch $declared before landing if " +
                               "origin has it, or every upstream commit the local copy is " +
                               "missing is attributed to this worker. If origin has no " +
                               "$declared at all, fetching cannot work: push the branch, or " +
                               "correct pr.base_branch in .no-mistakes.yaml.")
            }
            # Last, because the probes above are probes too: Test-OriginRemote leaves a non-zero
            # exit code behind on a repository that has no origin, and the caller runs under
            # $ErrorActionPreference = 'Stop'.
            $global:LASTEXITCODE = 0
            return $c
        }
    }

    $global:LASTEXITCODE = 0
    $msg = "Cannot resolve a base ref in ${RepoPath}: none of $($usable -join ', ') " +
           "exists. Refusing to record a base that would make the landing evidence silently empty."
    if ($declared -and $declaredIsWorker) {
        $msg += " $declared is the branch this repository declares its work integrates into, but " +
                "it is a worktree-* branch, so both forms of it were refused rather than tried - " +
                "a worker branch belongs to another worker and is never a base, however well it " +
                "resolves. Correct pr.base_branch in .no-mistakes.yaml."
    } elseif ($declared) {
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
