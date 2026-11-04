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
  applies, because the wrong reason sends the reader after the wrong fix: neither form of the ref
  resolves here, or it names a `worktree-*` branch, which is refused on its name alone. Honouring
  the declaration only in its LOCAL form, on a repository that has an `origin`, is warned about
  too: `origin/dev` comes first because a local `dev` is often behind it, so the base is still the
  declared branch and this is a caution rather than a refusal. A repository with no remote has no
  `origin/dev` to prefer and no warning.

  EACH WARNING SAYS WHAT WAS DECIDED AND WHAT TO DO, AND NOTHING ELSE: the declared name, the ref
  this worker is based on, the one fact that decided it, and the action. Every fact it states is
  one this function established - a ref it probed, or a name it refused. It says nothing about a
  ref it never looked up -
  whether a refused `worktree-*` name exists or whose it is, whether origin has the declared
  branch, how far a local copy is behind, which commits a landing diff will carry - because each
  such sentence was a guess, and the guesses kept turning out false: one said a never-created
  branch "resolves fine", another that it belonged to another worker. Where the right action
  depends on something not asked, such as whether origin has the branch - a network round trip on
  a path that must not hang a dispatch - the action names each answer instead of assuming one.
  Making the declaration resolvable is advice for the next dispatch, never for this worker,
  because nothing done after the worktree is cut moves the base it was cut from; for this worker,
  where the base is not the declared branch, the action is to check what its pull request targets
  before it lands.

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

  Whether the mapping ran past its line is decided by BALANCING its braces, never by forbidding
  them. `pr: {draft: true, opts: {a: 1}}` closes on its own line and declares no branch, and
  refusing it for "does not close on its own line" told the reader the opposite of what happened
  while blocking every dispatch into that repository - the same false refusal as the comment
  above, one shape further in. Only an unbalanced count means the contents are genuinely unknown.
  Nested mappings are then dropped before the keys are read, so a `base_branch` belonging to some
  sub-mapping of `pr:` is a different key with the same name - the rule the indent check already
  applies to that shape written out as a block.

  An unresolvable base is worse than a wrong one. `git log "$base..HEAD"` and
  `git diff "$base...HEAD"` against a ref that does not exist both fail to stderr and write
  NOTHING to stdout, so the landing gate sees a zero-file diff and an empty attribution scan
  and reads both as clean - against commits it never inspected. The old fallback invented the
  literal string `origin/main` on a repository with no remote at all, which is exactly the
  posture `/annex` proposes for a remoteless repo, so that was the common path.

  Every candidate is therefore confirmed with `git rev-parse --verify`, and an `origin/...`
  name is only ever used when that remote-tracking ref actually exists. When nothing resolves
  this throws rather than returning a name that will silently empty the evidence later.

  A CALLER MAY SUPPLY ITS OWN BASE rather than ask for one, and where it does, this function is
  not called at all. Dispatch-Worker.ps1's `-Base` is that caller and its header owns the
  parameter, the reason it exists and what it refuses; nothing here restates any of it. What the
  two share is the rule immediately below: `Test-WorkerBranch` sits at FILE scope rather than
  inside this function so that going around the resolver cannot go around its guard. A second copy
  of that pattern over there would be a second thing to keep in step, and the copy that fell behind
  would be the one deciding whether another worker's branch is allowed to be a base.

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

# A kingshand worker branch, in every spelling git resolves to the same ref: local (`worktree-x`,
# `heads/worktree-x`, `refs/heads/worktree-x`) or remote-tracking (`origin/worktree-x`,
# `remotes/origin/worktree-x`, `refs/remotes/origin/worktree-x`).
# Anchored at the start so a legitimate branch like `feature/worktree-cleanup` is untouched.
#
# THE LONGER FORMS ARE COVERED BECAUSE THE INPUT CHANGED. This used to be asked only of the
# resolver's own candidate list, which can hold nothing but the two short forms, so the two were the
# whole question. It is now asked of an arbitrary caller-supplied string as well, and
# `refs/remotes/origin/worktree-x` is what `git branch -a` prints - which is where somebody naming a
# base copies the name from. Matching only the short forms would let the identical ref through under
# the name it is most likely to be typed with.
#
# At FILE scope, so that dot-sourcing this file gets the guard as well as the resolver. That is what
# lets a caller supplying its own base ask the same question of it without owning a second copy of
# the pattern - the header above says why the copy is the thing to avoid.
function Test-WorkerBranch {
    param([string]$Ref)
    [bool]($Ref -and $Ref -match '^(refs/)?(heads/|(remotes/)?origin/)?worktree-')
}

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

    # Test-WorkerBranch is at file scope above rather than here, so the same rule answers for a
    # caller-supplied base too.

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
                        # Whether the mapping ended on this line is a question of BALANCE, not of
                        # whether it contains braces at all. Forbidding them refused
                        # `pr: {draft: true, opts: {a: 1}}` for "does not close on its own line"
                        # when it closes perfectly well and declares no branch - the message said
                        # the opposite of what happened, and every dispatch into that repository
                        # failed over a line the gate and this reader already agree about.
                        $depth  = 0
                        $sunk   = $false
                        foreach ($ch in $inline.ToCharArray()) {
                            if ($ch -eq '{') { $depth++ }
                            elseif ($ch -eq '}') { $depth--; if ($depth -lt 0) { $sunk = $true } }
                        }
                        if ($depth -eq 0 -and -not $sunk -and $inline.EndsWith('}')) {
                            # Nested mappings are removed innermost-first, so what is matched below
                            # is the mapping's OWN keys. `base_branch` inside a sub-mapping of `pr:`
                            # is a different key with the same name, which is the rule the block
                            # reader's indent check applies to the same shape written out.
                            $body = $inline.Substring(1, $inline.Length - 2)
                            while ($body -match '\{[^{}]*\}') { $body = $body -replace '\{[^{}]*\}', '' }
                            # `pr: {base_branch: dev}`. Refused by name rather than ignored, and
                            # matched as a KEY of the mapping: a value that merely contains the
                            # word declares nothing. `pr: {}` and `pr: {draft: true}` fall through
                            # to the same "no declaration" as any other inline value.
                            if ($body -match '(^|,)\s*["'']?base_branch["'']?\s*:') {
                                throw ("$path declares base_branch inline on the pr key: " +
                                       "$($line.Trim()). This reads only the block form, so an " +
                                       "inline mapping would leave the dispatcher basing workers " +
                                       "somewhere the review gate does not propose them. Write " +
                                       "it as a block instead - pr: on its own line, with " +
                                       "base_branch: <branch> beneath it.")
                            }
                        } else {
                            # The braces do not balance, so the mapping runs past the end of this
                            # line and its keys are on lines this reader skips as children of
                            # nothing - which is how a multi-line `pr: {` / `base_branch: dev` /
                            # `}` came back as no declaration at all. Unknown contents are refused
                            # rather than read as absent ones: the same rule as an unreadable file,
                            # for the same reason.
                            throw ("$path writes pr as a flow mapping this reader cannot finish " +
                                   "reading: $($line.Trim()). Its braces do not balance on this " +
                                   "line, " +
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
            # Each warning says what was decided - the ref this worker is based on and why - and
            # what to do, and nothing else. The header says why it may claim no more than that.
            $said = "$RepoPath declares $declared in pr.base_branch of .no-mistakes.yaml"
            if ($declared -and $c -ne $declared -and $c -ne "origin/$declared") {
                if ($declaredIsWorker) {
                    Write-Warning ("$said, and that name was refused on its name alone - a " +
                                   "worktree-* name is never used as a base - so this worker " +
                                   "is based on $c instead. Check what its pull request " +
                                   "targets before it lands, and correct pr.base_branch.")
                } elseif (Test-OriginRemote) {
                    # Whether origin has the branch is not asked - that is a network round trip
                    # on a path that must not hang a dispatch - so the action covers both answers.
                    Write-Warning ("$said, but neither origin/$declared nor $declared resolves " +
                                   "here, so this worker is based on $c instead. Check what its " +
                                   "pull request targets before it lands. Before the next " +
                                   "dispatch into this repository, fetch $declared if origin " +
                                   "has it, create it if not, or correct pr.base_branch.")
                } else {
                    # No origin, so there is nothing to fetch from and no pull request to target.
                    Write-Warning ("$said, but no $declared branch resolves here and there is " +
                                   "no origin, so this worker is based on $c instead. Create " +
                                   "$declared, or correct pr.base_branch, before the next " +
                                   "dispatch into this repository.")
                }
            } elseif ($declared -and $c -eq $declared -and (Test-OriginRemote)) {
                Write-Warning ("$said, and origin/$declared does not resolve here, so this " +
                               "worker is based on the local $declared. Nothing here compared " +
                               "it with origin. Before the next dispatch into this repository, " +
                               "fetch $declared if origin has it; if not, push it or correct " +
                               "pr.base_branch.")
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
