#Requires -Version 7.0
Set-StrictMode -Version Latest

# Self-update: move this installation to the latest tagged release, re-run the installer, and say
# what moved. The `/update` skill is the only caller, and `Invoke-KingshandUpdate` is the only
# entry point it needs.
#
# TO A TAG, NEVER TO A BRANCH HEAD. That is the whole design. A tag is a release somebody decided
# to cut; a branch head is whatever happened to be pushed last, which on this repository is a
# worker's merge that may be minutes old and mid-series. Updating to a tag also makes an update
# independent of which branch is default, so a project that moves its default branch or changes
# what pull requests target does not change what `/update` does.
#
# The highest version tag wins, and reachability is deliberately NOT checked. A tag cut somewhere
# that cannot fast-forward onto the release branch is refused a few lines further down by
# `git merge --ff-only`, which is the honest outcome; filtering it out instead would silently pick
# an OLDER release and report that as the latest, which is the one failure here nobody would spot.
#
# A PRE-RELEASE TAG IS NOT A RELEASE `/update` WILL MOVE ANYBODY TO. `v1.0.0-rc1` and
# `v1.0.0+build3` are not releases here, only `v1.0.0` is; `$script:ReleaseTagPattern` below owns
# the reason.
#
# FOUR REFUSALS, and none of them is an edge case. A dirty tree, a live worker, a checkout on the
# wrong branch and a repository with no releases yet each stop the update where it stands and name
# themselves. Nothing here forces, stashes, resets, merges non-linearly or deletes anything: the
# only write is a fast-forward, and a fast-forward that cannot happen does not happen.
#
# The user's own state is never involved. `data\`, `state\`, `config\`, `tools\` and
# `instructions.md` are gitignored, so no fetch or fast-forward can reach them, and this module
# adds no machinery to protect what git already ignores.
#
# NOT -Force on either import - a module never forces a nested import. The rule and the failure it
# prevents are in the `statute` skill's style rules.
Import-Module (Join-Path $PSScriptRoot 'Version.psm1')
Import-Module (Join-Path $PSScriptRoot 'Herdr.psm1')

# The branch releases are tagged on. `main` here, with the integration branch merged into it
# roughly weekly and the tag cut on that merge - `docs\2026-09-03-versioning-and-update.md` owns
# the procedure. Stated once as the default for every function below that needs it.
$script:DefaultReleaseBranch = 'main'

# A release tag: `v` and three numbers, and nothing after them. The glob is what git filters on and
# the anchored pattern is what actually decides, so a tag like `v2-backup` or `vendor-drop` is not
# mistaken for a release.
#
# A PRE-RELEASE IS DELIBERATELY NOT A RELEASE. `v1.0.0-rc1` and `v1.0.0+build3` are refused by this
# pattern, so `/update` never moves anybody to one. That is not tidiness: git's own `-v:refname`
# ordering ranks `v1.0.0-rc1` ABOVE `v1.0.0` unless `versionsort.suffix` is configured, so admitting
# a suffix would make the release candidate outrank the release it preceded and `/update` would
# report an rc as the latest release and fast-forward to its older commit - a wrong value with no
# error anywhere. Narrowing the pattern fixes that here, rather than depending on a git setting on
# every reader's machine. The VERSION file pattern in `bin\Version.psm1` stays wider on purpose: a
# copy may legitimately be running 1.0.0-rc.1, it just is not something `/update` moves anybody to.
$script:ReleaseTagGlob    = 'v*'
$script:ReleaseTagPattern = '^v\d+\.\d+\.\d+$'

# How many dirty paths a refusal names before it stops listing. Enough to recognise the work,
# short enough to stay one readable line.
$script:DirtyPathsShown = 5

function Get-ReleaseBranchName {
    [CmdletBinding()]
    param()

    $script:DefaultReleaseBranch
}

# The names of every worker herdr currently has, or a throw when herdr could not be asked.
#
# LIVENESS COMES FROM HERDR, NEVER FROM `state\crew.json`. CLAUDE.md states that precedence and
# the reason: crew.json records what was intended and herdr records what is actually running, so a
# guard that must not update `bin\` and the skills underneath a working worker needs the second
# one. A worker recorded as torn down but still alive is exactly the case this catches.
#
# ONLY ONE STATE MEANS "NOBODY IS WORKING", AND EVERY OTHER FAILURE THROWS:
#
#   no herdr at all       - liveness is UNKNOWN. Throws, so the update refuses. An installation
#                           with no herdr may still have been dispatching from a herdr that was
#                           uninstalled or moved out from under it, and this cannot tell.
#   server state unknown  - the status read failed. Throws. This is the one that looks safe and
#                           is not: a herdr upgrade that changes the reply, a non-zero exit or a
#                           transient error all arrive here, and every one of them would read as
#                           an empty fleet if it were allowed to fall through.
#   server stopped        - no live workers, as a FACT rather than a guess. A herdr pane dies with
#                           its server, so a server that is not running has no worker in it;
#                           `bin\Get-CrewStatus.ps1` states the same thing.
#   server running        - ask, and throw if the answer could not be read.
#
# So both reads go through the three-answer reader rather than the two-answer one.
# `Get-HerdrServerState` distinguishes a stopped server from a status read that failed, where
# `Test-HerdrServer` cannot; `Get-HerdrAgentInventory` keeps herdr's own error where
# `Get-HerdrAgents` deliberately answers an unreachable herdr with an empty list. Either boolean
# would read as "nobody is working" and let the update fast-forward `bin\` and the skills out from
# under a live worker. `bin\Herdr.psm1` owns the command line for all of them.
function Get-LiveWorkerNames {
    [CmdletBinding()]
    param()

    if (-not (Get-HerdrCommandPath)) { throw (Get-HerdrCommandHint) }

    $server = Get-HerdrServerState
    if ($server.state -eq 'unknown') {
        throw "whether herdr's server is running could not be read - $($server.detail)"
    }
    if ($server.state -eq 'stopped') { return @() }

    $inventory = Get-HerdrAgentInventory
    if (-not $inventory.ok) { throw $inventory.error }

    @($inventory.agents |
      Where-Object { $_ -and $_.PSObject.Properties.Name -contains 'name' -and $_.name } |
      ForEach-Object { "$($_.name)" })
}

# The tracked paths git reports as modified, staged, deleted or untracked. Empty means clean.
function Get-DirtyPaths {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoPath)

    $PSNativeCommandUseErrorActionPreference = $false

    $out = @(& git -C $RepoPath status --porcelain 2>&1)
    $code = $LASTEXITCODE
    $global:LASTEXITCODE = 0
    if ($code -ne 0) { throw "git could not read the state of $RepoPath - $(($out | Out-String).Trim())" }

    @($out | ForEach-Object { "$_".Trim() } | Where-Object { $_ } |
      ForEach-Object { ($_ -split '\s+', 2)[-1] })
}

# The checked-out branch, an empty string on a detached HEAD, or a throw when git could not answer.
#
# THREE ANSWERS, NOT TWO. A detached HEAD is a state git reported - it replies with the literal
# `HEAD` - and the caller names it as one. A git that exited non-zero reported nothing at all, and
# folding that into the same empty string made the refusal say "on a detached HEAD" about a
# checkout whose branch was never established. Both still refuse, so this is about the refusal
# telling the truth rather than about what it allows.
function Get-CheckedOutBranch {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoPath)

    $PSNativeCommandUseErrorActionPreference = $false

    $raw  = @(& git -C $RepoPath rev-parse --abbrev-ref HEAD 2>&1)
    $code = $LASTEXITCODE
    $global:LASTEXITCODE = 0
    $out = ($raw | Out-String).Trim()
    if ($code -ne 0) {
        throw ("The branch checked out at $RepoPath could not be read - " +
               "$(($out -replace '\s+', ' ').Trim())")
    }
    if ($out -eq 'HEAD') { return '' }
    $out
}

# The highest version release tag in the repository, or a throw naming the reason there is none.
#
# THE NO-RELEASES PATH IS THE COMMON PATH, not an edge case: this repository had zero tags when
# `/update` was written, and the first release is cut by hand afterwards. So it refuses by name -
# no release has been tagged - and never falls back to a branch, a commit or an invented version.
function Get-LatestReleaseTag {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoPath)

    $PSNativeCommandUseErrorActionPreference = $false

    # -v:refname is git's own version ordering, so v0.10.0 sorts above v0.9.0 where a plain string
    # sort puts it below.
    $out = @(& git -C $RepoPath tag --list $script:ReleaseTagGlob --sort=-v:refname 2>&1)
    $code = $LASTEXITCODE
    $global:LASTEXITCODE = 0
    if ($code -ne 0) { throw "git could not list the tags in $RepoPath - $(($out | Out-String).Trim())" }

    $tags = @($out | ForEach-Object { "$_".Trim() } | Where-Object { $_ -match $script:ReleaseTagPattern })
    if ($tags.Count -eq 0) {
        throw ('No release has been tagged in this repository yet, so there is nothing to update ' +
               'to. A release is a tag like v0.1.0 on the release branch; until one is cut, ' +
               'nothing here moves.')
    }
    $tags[0]
}

# One commit's short hash, or a throw. Used for the from and to a report names.
function Resolve-CommitId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$Ref
    )

    $PSNativeCommandUseErrorActionPreference = $false

    $out = (& git -C $RepoPath rev-parse --verify --quiet "$Ref^{commit}" 2>$null | Out-String).Trim()
    $global:LASTEXITCODE = 0
    if (-not $out) { throw "$Ref does not name a commit in $RepoPath." }
    $out
}

# What changed between two refs: the commit subjects, in the order git lists them.
#
# ONE-LINERS, NOT A CHANGELOG. Commit subjects are already written as single lines by the pipeline
# that produced them, so this needs no new discipline from anybody and no parser from anybody
# either. A hand-written parser for an open-ended text format is the most expensive mistake this
# repository has made - about sixteen review rounds across two tasks - and a changelog file would
# be exactly that shape again.
function Get-ReleaseChanges {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$From,
        [Parameter(Mandatory)][string]$To
    )

    $PSNativeCommandUseErrorActionPreference = $false

    # --no-merges, because a merge subject names the branch it merged and says nothing about what
    # the release contains. --no-pager so this never blocks waiting for a pager to be dismissed.
    $out = @(& git -C $RepoPath --no-pager log --no-merges --format='%s' "$From..$To" 2>&1)
    $code = $LASTEXITCODE
    $global:LASTEXITCODE = 0
    if ($code -ne 0) {
        throw "git could not list the commits between $From and $To - $(($out | Out-String).Trim())"
    }

    @($out | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
}

# Must a live session read its instructions again? `CLAUDE.md`, `bin\` and `.claude\skills\` are
# the instruction surface: if one of them advanced, the session is acting on instructions that no
# longer match the files on disk, and the honest fix is to read them again.
#
# This answers "should you re-read", not "did those files change", which is why a diff that could
# not be read answers yes. Re-reading when nothing moved costs a few seconds; not re-reading when
# something did means acting on instructions that are gone.
#
# Taken from firstmate's `updatefirstmate`, which prints the same yes/no as an action line. Its
# other half - nudging a fleet of sub-agents to re-read - has no equivalent here, because an
# update refuses outright while any worker is live.
function Test-RereadNeeded {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$From,
        [Parameter(Mandatory)][string]$To
    )

    $PSNativeCommandUseErrorActionPreference = $false

    $out = @(& git -C $RepoPath --no-pager diff --name-only "$From..$To" 2>&1)
    $code = $LASTEXITCODE
    $global:LASTEXITCODE = 0
    if ($code -ne 0) { return $true }   # Cannot tell, so say re-read - see the header.

    [bool](@($out | Where-Object {
        $p = "$_".Trim() -replace '\\', '/'
        $p -eq 'CLAUDE.md' -or $p.StartsWith('bin/') -or $p.StartsWith('.claude/skills/')
    }).Count)
}

# Runs one update and reports what it did, as data rather than as printed text.
#
# .status       updated | already-current | refused
# .ok           the run did what it promised: updated cleanly, or was already current
# .reason       the named failure, on a refusal and only there
# .fromVersion  the version this installation was on
# .toVersion    the version it is on now, read from the file after the fast-forward
# .tag          the release tag that was updated to
# .changes      the commit subjects between the two commits
# .installOk    whether the re-run of install.ps1 exited clean; $null when it was not reached
# .rereadNeeded whether CLAUDE.md, bin\ or a skill moved, so a live session must read them again
#
# A refusal is returned rather than thrown, because every one of the four is an ordinary answer a
# caller has to report to a person - and the caller is a skill, which reads a result far better
# than it reads an exception. The low-level reads above throw, and each throw is caught here and
# turned into a named refusal.
function Invoke-KingshandUpdate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [string]$ReleaseBranch = $script:DefaultReleaseBranch,
        [string]$InstallScript,
        [string]$Remote = 'origin'
    )

    $PSNativeCommandUseErrorActionPreference = $false

    # Resolved in the body rather than as a parameter default so it follows -Root, which is the
    # installation being updated. The `/update` skill passes neither and gets both from here.
    if (-not $InstallScript) { $InstallScript = Join-Path $Root 'install.ps1' }

    $result = [ordered]@{
        root         = $Root
        status       = 'refused'
        ok           = $false
        reason       = ''
        fromVersion  = ''
        toVersion    = ''
        tag          = ''
        fromCommit   = ''
        toCommit     = ''
        changes      = @()
        installOk    = $null
        installError = ''
        rereadNeeded = $false
    }
    $refuse = {
        param([string]$Reason)
        $result.status = 'refused'
        $result.ok     = $false
        $result.reason = $Reason
        [pscustomobject]$result
    }

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        return & $refuse "There is no directory at $Root, so there is no installation to update."
    }
    $null = & git -C $Root rev-parse --is-inside-work-tree 2>$null
    $inRepo = $LASTEXITCODE -eq 0
    $global:LASTEXITCODE = 0
    if (-not $inRepo) {
        return & $refuse "$Root is not a git repository, so it cannot be fast-forwarded to a release."
    }

    # The version comes first, because a run that cannot say where it started cannot report a move.
    try {
        $result.fromVersion = Get-KingshandVersion -Path (Get-VersionFilePath -Root $Root)
    } catch {
        return & $refuse $_.Exception.Message
    }

    # Guard 1 - a dirty tree. Someone's unsaved work, and a fast-forward over it would either
    # refuse halfway or carry it into a release it does not belong to.
    try {
        $dirty = @(Get-DirtyPaths -RepoPath $Root)
    } catch {
        return & $refuse $_.Exception.Message
    }
    if ($dirty.Count -gt 0) {
        $shown = if ($dirty.Count -gt $script:DirtyPathsShown) {
            ($dirty[0..($script:DirtyPathsShown - 1)] -join ', ') + ", and $($dirty.Count - $script:DirtyPathsShown) more"
        } else {
            $dirty -join ', '
        }
        return & $refuse ("The working tree at $Root has uncommitted changes ($shown), so nothing " +
                          'was updated. Commit or put them aside first - this never stashes or ' +
                          'discards anything.')
    }

    # Guard 2 - a live worker. Moving bin\ and the skills under a worker mid-task breaks it, and
    # liveness is herdr's answer rather than crew.json's.
    try {
        $live = @(Get-LiveWorkerNames)
    } catch {
        return & $refuse ('Whether any worker is live could not be established, so nothing was ' +
                          "updated - $($_.Exception.Message)")
    }
    if ($live.Count -gt 0) {
        return & $refuse ("$($live.Count) worker(s) are live ($($live -join ', ')), so nothing was " +
                          'updated. An update moves bin\ and the skills underneath them mid-task. ' +
                          'Wait for them to finish, or stop them first.')
    }

    # Guard 3 - the wrong branch. Releases are tagged on the release branch, so an update from
    # anywhere else would be a merge into work that is not a release.
    try {
        $branch = Get-CheckedOutBranch -RepoPath $Root
    } catch {
        return & $refuse ("$($_.Exception.Message), so nothing was updated.")
    }
    if ($branch -ne $ReleaseBranch) {
        $where = if ($branch) { "on $branch" } else { 'on a detached HEAD' }
        return & $refuse ("$Root is $where, not on the release branch $ReleaseBranch, so nothing " +
                          'was updated. Releases are tagged there, and switching branches is your ' +
                          'call rather than an update''s.')
    }

    # The installer is checked before anything moves. A fast-forward that lands and then finds no
    # install.ps1 leaves a half-done update, which is worse than a refusal that changed nothing.
    if (-not (Test-Path -LiteralPath $InstallScript -PathType Leaf)) {
        return & $refuse ("There is no installer at $InstallScript, so nothing was updated. An " +
                          'update re-runs it, and an update that cannot would leave the ' +
                          'installation half-moved.')
    }

    # The releases have to come from the remote, so a fetch that did not happen is a refusal: the
    # newest tag on disk is not the newest release, and reporting it as one would be a lie a user
    # cannot see through.
    $remoteUrl = (& git -C $Root remote get-url $Remote 2>$null | Out-String).Trim()
    $global:LASTEXITCODE = 0
    if (-not $remoteUrl) {
        return & $refuse ("This installation has no $Remote remote, so there is nowhere to fetch " +
                          'releases from and nothing was updated.')
    }
    $fetchOut = @(& git -C $Root fetch --tags $Remote 2>&1)
    $fetchCode = $LASTEXITCODE
    $global:LASTEXITCODE = 0
    if ($fetchCode -ne 0) {
        return & $refuse ("Could not fetch releases from $Remote ($remoteUrl), so nothing was " +
                          "updated - $((($fetchOut | Out-String) -replace '\s+', ' ').Trim())")
    }

    # Guard 4 - no releases. The common path on a repository whose first tag has not been cut.
    try {
        $result.tag = Get-LatestReleaseTag -RepoPath $Root
    } catch {
        return & $refuse $_.Exception.Message
    }

    try {
        $result.fromCommit = Resolve-CommitId -RepoPath $Root -Ref 'HEAD'
        $target            = Resolve-CommitId -RepoPath $Root -Ref $result.tag
    } catch {
        return & $refuse $_.Exception.Message
    }

    # Already holding the release, including the case where the newest tag is older than this
    # checkout. Nothing moves, nothing is claimed to have moved, and no downgrade is possible.
    $null = & git -C $Root merge-base --is-ancestor $target 'HEAD' 2>$null
    $contained = $LASTEXITCODE -eq 0
    $global:LASTEXITCODE = 0
    if ($contained) {
        $result.status    = 'already-current'
        $result.ok        = $true
        $result.toVersion = $result.fromVersion
        $result.toCommit  = $result.fromCommit
        return [pscustomobject]$result
    }

    # Read the target's version BEFORE moving: a tag cut before the VERSION file existed cannot
    # say what it would move to, and a refusal that changed nothing beats a move nobody can report.
    try {
        $null = Get-KingshandVersionAtRef -RepoPath $Root -Ref $result.tag
    } catch {
        return & $refuse ("$($result.tag) is the latest release but nothing was updated - " +
                          $_.Exception.Message)
    }

    try {
        $result.changes = @(Get-ReleaseChanges -RepoPath $Root -From $result.fromCommit -To $target)
    } catch {
        return & $refuse $_.Exception.Message
    }

    # FAST-FORWARD ONLY. Never --no-ff, never a rebase, never a reset: an installation that has
    # diverged from the release branch holds work nobody here may discard, so it is refused with
    # git's own reason and left exactly as it was.
    $mergeOut = @(& git -C $Root merge --ff-only $result.tag 2>&1)
    $mergeCode = $LASTEXITCODE
    $global:LASTEXITCODE = 0
    if ($mergeCode -ne 0) {
        return & $refuse ("$Root cannot be fast-forwarded to $($result.tag), so nothing was " +
                          'updated - it has commits of its own that the release does not. ' +
                          "git said: $((($mergeOut | Out-String) -replace '\s+', ' ').Trim())")
    }

    # What is on disk now is the answer, read the same way the digest reads it. A move that landed
    # somewhere other than the tag is reported rather than assumed away.
    try {
        $result.toCommit   = Resolve-CommitId -RepoPath $Root -Ref 'HEAD'
        $result.toVersion  = Get-KingshandVersion -Path (Get-VersionFilePath -Root $Root)
    } catch {
        return & $refuse ("$Root was fast-forwarded to $($result.tag) but the result could not be " +
                          "read - $($_.Exception.Message)")
    }

    $result.rereadNeeded = Test-RereadNeeded -RepoPath $Root `
                               -From $result.fromCommit -To $result.toCommit
    $result.status = 'updated'

    # install.ps1 is idempotent and is called, never reimplemented. Its output is captured so a
    # caller reports the outcome rather than leaking a wall of installer text.
    #
    # $LASTEXITCODE is cleared first because it is global and holds whatever the last native
    # command left there. A script that returns without calling `exit` would otherwise be read as
    # having failed with some earlier command's status.
    try {
        $global:LASTEXITCODE = 0
        $installOut = @(& $InstallScript *>&1)
        $installCode = $LASTEXITCODE
        $global:LASTEXITCODE = 0
        $result.installOk = ($installCode -eq 0)
        if (-not $result.installOk) {
            $result.installError = "$InstallScript exited $installCode - " +
                                   (((($installOut | Out-String) -replace '\s+', ' ').Trim()))
        }
    } catch {
        $result.installOk    = $false
        $result.installError = "$InstallScript failed - $($_.Exception.Message)"
    }

    # The fast-forward landed either way. `ok` is false when the installer did not run clean,
    # because the installation moved and its configuration may not have followed.
    $result.ok = [bool]$result.installOk
    [pscustomobject]$result
}

Export-ModuleMember -Function Get-ReleaseBranchName, Get-LiveWorkerNames, Get-DirtyPaths,
                              Get-CheckedOutBranch, Get-LatestReleaseTag, Resolve-CommitId,
                              Get-ReleaseChanges, Test-RereadNeeded, Invoke-KingshandUpdate
