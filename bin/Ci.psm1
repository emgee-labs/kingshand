#Requires -Version 7.0
Set-StrictMode -Version Latest

# Can anything report a check on this repository's pull requests?
#
# The failure this exists to prevent, observed here on 2026-09-01: a review-gate run on the
# kingshand repository reached its `ci` step and sat there for over an hour. This repository has no
# CI at all - no workflow files, nothing on GitHub, zero check runs on the commit - so the checks it
# was waiting for could never arrive. The gate cannot tell "checks have not started yet" from
# "checks will never exist", and neither can a worker, so the wait had no end. It was found only
# because the King asked what had happened to it.
#
# The answer has to be established BEFORE a `no-mistakes` task is dispatched, because that is the
# last moment it costs nothing. Afterwards it costs an hour of a worker's life and an hour of the
# King's patience.
#
# Three states, and the third is the point. `has-ci` and `no-ci` are answers; `unknown` is the
# refusal to guess when the question could not be settled - no `gh`, a remote that is not GitHub, an
# unauthenticated machine, a network that did not answer. Nothing here ever converts a failed lookup
# into either answer, because both wrong answers are expensive: a false `no-ci` throws away a real
# green check, and a false `has-ci` restores the hour-long wait this module exists to remove.
#
# WHAT COUNTS AS CI IS TWO SIGNALS, AND THE SECOND ONE IS WHY THIS IS NOT A DIRECTORY TEST.
# A `.github\workflows` directory is the obvious signal and it is not sufficient in either
# direction. `emgeelabs-site` has no workflow file anywhere in the repository and gets Cloudflare
# Pages check runs on every commit; a naive workflows-directory check calls that repository `no-ci`
# and tells a worker to stop at the pull request while real checks are running on it. So the second
# signal is the checks GitHub actually reported on recent commits of the default branch, which is
# the stronger one precisely because it survives CI that lives outside the repository.
#
# The other direction is handled three times, because a file existing is not a check arriving. An
# empty workflows directory is not CI - a repository that deleted its last workflow keeps the
# directory - and neither is a workflow that cannot run on a pull request. A workflow triggered only
# by `schedule` or `workflow_dispatch` will never put a check on one, so counting it as `has-ci`
# restores the hour-long wait exactly as an empty directory would. Workflows are therefore read for
# their triggers. And on a GitHub remote, another provider's config file - a dormant `.travis.yml`, a
# `.gitlab-ci.yml` carried over from a mirror - is not evidence about the GitHub pull request the
# worker will open, so it does not answer the question either. In every one of those cases the
# repository falls through to the check-runs lookup rather than being answered from the file listing.

$script:DefaultCommitsToCheck = 5

# Config files that mean some provider is wired up. The list is short and every entry is a file a
# provider reads: this is a positive signal only, and its absence proves nothing, which is why the
# check-runs lookup below runs whenever nothing here could report on a pull request.
$script:CiConfigFiles = @(
    'azure-pipelines.yml'
    'azure-pipelines.yaml'
    '.gitlab-ci.yml'
    '.circleci\config.yml'
    'Jenkinsfile'
    '.travis.yml'
    'appveyor.yml'
    '.appveyor.yml'
    'bitbucket-pipelines.yml'
)

function Get-GhCommandPath {
    [CmdletBinding()]
    param()

    $found = Get-Command 'gh' -CommandType Application -ErrorAction SilentlyContinue |
             Select-Object -First 1
    if ($found -and $found.Source) { return $found.Source }
    $null
}

# The one boundary between this module and the GitHub API, so every lookup below can be exercised
# without a network, a token or a repository - the same reason `Invoke-Herdr` is one function.
#
# It never throws. A missing `gh`, a 401, a 404 and a dead network all arrive as ok = $false with
# gh's own message, because the caller's job is to report which one happened rather than to catch.
function Invoke-GhApi {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Arguments)

    $exe = Get-GhCommandPath
    if (-not $exe) {
        return [pscustomobject]@{
            ok    = $false
            value = ''
            error = 'gh was not found. Install it with: winget install --id GitHub.cli - then run: gh auth login.'
        }
    }

    $raw  = & $exe @Arguments 2>&1
    $code = $LASTEXITCODE
    $text = ($raw | Out-String).Trim()

    if ($code -ne 0) {
        $one = ($text -replace '\s+', ' ').Trim()
        if (-not $one) { $one = "gh exited $code with no output." }
        return [pscustomobject]@{ ok = $false; value = ''; error = $one }
    }
    [pscustomobject]@{ ok = $true; value = $text; error = '' }
}

# owner/repo, or $null when the remote is absent or is not GitHub.
#
# Not-GitHub is deliberately $null rather than a slug: this module can only see GitHub's checks, so
# a GitLab or Azure DevOps remote is a question it cannot answer and must report as unknown.
function Get-RepoGitHubSlug {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoPath)

    $url = (& git -C $RepoPath remote get-url origin 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $url) { return $null }

    $m = [regex]::Match($url, '(?i)github\.com[:/](?<owner>[^/]+)/(?<repo>[^/]+?)(?:\.git)?/?$')
    if (-not $m.Success) { return $null }
    "$($m.Groups['owner'].Value)/$($m.Groups['repo'].Value)"
}

# CI configuration committed to the repository. Paths are returned so the caller can name what it
# found rather than asserting CI exists and leaving the reader to go looking.
function Get-RepoCiConfigFiles {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoPath)

    $hits = [System.Collections.Generic.List[string]]::new()

    $workflows = Join-Path $RepoPath '.github\workflows'
    if (Test-Path -LiteralPath $workflows -PathType Container) {
        # An empty workflows directory is not CI. A repository that deleted its last workflow keeps
        # the directory, and calling that `has-ci` restores the endless wait.
        foreach ($f in @(Get-ChildItem -LiteralPath $workflows -File -ErrorAction SilentlyContinue)) {
            if ($f.Extension -in '.yml', '.yaml') { $hits.Add('.github\workflows\' + $f.Name) }
        }
    }

    foreach ($rel in $script:CiConfigFiles) {
        if (Test-Path -LiteralPath (Join-Path $RepoPath $rel) -PathType Leaf) { $hits.Add($rel) }
    }

    $hits.ToArray()
}

# The events a GitHub workflow has to be triggered by before it can put a check on a pull request.
# `workflow_call` and `workflow_run` are in because both are reached from a workflow that is itself
# triggered by one of the others, and a check that arrives indirectly is still a check.
$script:PullRequestTriggers = @(
    'pull_request'
    'pull_request_target'
    'push'
    'merge_group'
    'workflow_call'
    'workflow_run'
)

# The trigger names out of one workflow's `on:` key, or $null when there is no readable `on:` block.
#
# This is a targeted read of one key rather than a YAML parse, because the three shapes GitHub
# accepts - `on: push`, `on: [push, pull_request]` and an indented block - are the whole surface
# needed, and pulling in a YAML dependency to answer a preflight would cost more than the preflight
# saves. Nested keys under a trigger, such as `branches:`, are skipped by indentation so a workflow
# restricted to one branch still reports the trigger it is restricted on.
#
# $null means "not established", never "no triggers", and the caller keeps a file it could not read.
function Get-WorkflowTriggers {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $lines = @(Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue)
    if ($lines.Count -eq 0) { return $null }

    for ($i = 0; $i -lt $lines.Count; $i++) {
        # `true` because YAML 1.1 readers, and the editors that reformat for them, turn a bare `on`
        # into a boolean.
        $m = [regex]::Match($lines[$i], '^(?:on|''on''|"on"|true)\s*:(?<rest>.*)$')
        if (-not $m.Success) { continue }

        $found = [System.Collections.Generic.List[string]]::new()

        $rest = ($m.Groups['rest'].Value -replace '#.*$', '').Trim()
        if ($rest) {
            foreach ($t in ($rest.Trim('[', ']') -split ',')) {
                $n = $t.Trim().Trim("'", '"')
                if ($n) { $found.Add($n.ToLowerInvariant()) }
            }
            if ($found.Count -eq 0) { return $null }
            return $found.ToArray()
        }

        $indent = -1
        for ($j = $i + 1; $j -lt $lines.Count; $j++) {
            $line = $lines[$j]
            if (-not $line.Trim() -or $line.Trim().StartsWith('#')) { continue }
            if ($line -notmatch '^\s') { break }

            $k = [regex]::Match($line, '^(?<pad>\s*)(?:-\s*)?(?<name>[A-Za-z_][A-Za-z0-9_-]*)\s*:?\s*(?:#.*)?$')
            if (-not $k.Success) { continue }

            $pad = $k.Groups['pad'].Value.Length
            if ($indent -lt 0) { $indent = $pad }
            if ($pad -ne $indent) { continue }
            $found.Add($k.Groups['name'].Value.ToLowerInvariant())
        }

        if ($found.Count -eq 0) { return $null }
        return $found.ToArray()
    }

    $null
}

# Which of the committed config files could actually put a check on a pull request.
#
# A file existing is not a check arriving. A workflow triggered only by `schedule` or
# `workflow_dispatch` reports on nothing a pull request can wait for, and answering `has-ci` from it
# restores the hour-long wait this module exists to remove - so its triggers decide, not its
# presence.
#
# A workflow whose `on:` could not be read is kept, because an unreadable file is not evidence of
# absence, and the check-runs lookup that follows is the honest way to settle what the files could
# not.
#
# ANOTHER PROVIDER'S CONFIG DEPENDS ON WHERE THE REPOSITORY LIVES, which is what -GitHubRemote says.
# On a GitHub remote, a dormant `.travis.yml` or a `.gitlab-ci.yml` carried over from a mirror is not
# evidence that a GitHub check will ever be posted - and the pull request the worker opens is on
# GitHub, so answering `has-ci` from that file is the false `has-ci` that restores the hour-long
# wait. GitHub can be asked what actually reported there, so it is asked. Where the remote is not
# GitHub, or there is no remote at all, nothing can be asked and the file stays a positive signal:
# it is in the list precisely because some provider reads it, and discarding it would be guessing in
# the expensive direction.
function Get-ReportingCiConfigFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [string[]]$ConfigFiles,
        [switch]$GitHubRemote
    )

    $hits = [System.Collections.Generic.List[string]]::new()

    foreach ($rel in @($ConfigFiles)) {
        if (-not $rel) { continue }
        if ($rel -notlike '.github\workflows\*') {
            if (-not $GitHubRemote) { $hits.Add($rel) }
            continue
        }

        # Tested against $null before it is wrapped, because @($null) is an array of one and would
        # turn "not established" into a trigger nothing recognises.
        $triggers = Get-WorkflowTriggers -Path (Join-Path $RepoPath $rel)
        if ($null -eq $triggers) { $hits.Add($rel); continue }

        $triggers = @($triggers)
        if ($triggers.Count -eq 0) { $hits.Add($rel); continue }
        if (@($triggers | Where-Object { $script:PullRequestTriggers -contains $_ }).Count -gt 0) {
            $hits.Add($rel)
        }
    }

    $hits.ToArray()
}

# How many checks GitHub reported on one commit: check runs plus the older commit statuses, because
# a provider may use either and both show up on a pull request.
#
# Returns $null when the lookup itself failed, which is not zero. Zero is "nothing reported here";
# $null is "nobody answered", and collapsing the two is how an unauthenticated machine reports a
# repository as having no CI.
function Get-CommitCheckCount {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Slug,
        [Parameter(Mandatory)][string]$Sha
    )

    $total = 0
    $any   = $false

    foreach ($endpoint in @('check-runs', 'status')) {
        $r = Invoke-GhApi -Arguments @('api', "repos/$Slug/commits/$Sha/$endpoint", '--jq', '.total_count')
        if (-not $r.ok) { continue }

        # Answered means a number came back, not that the command exited zero. `Invoke-GhApi` folds
        # stderr into the success value, so a warning riding along with the count leaves a reply
        # that parses as nothing - and counting that as zero is the same collapse of "nobody
        # answered" into "nothing reported" that this function exists to prevent.
        $n = 0
        if ([int]::TryParse(($r.value -replace '\s', ''), [ref]$n)) {
            $any = $true
            $total += $n
        }
    }

    if (-not $any) { return $null }
    $total
}

# The answer, and everything needed to say it out loud.
#
# .status       has-ci | no-ci | unknown
# .signal       what settled it
# .detail       one line naming the evidence, written to be read to a person
# .briefLine    the Done-means line a `no-mistakes` brief must carry for this repository, where
#               that brief drives the pipeline all the way out. A `yolo`-off task replaces the
#               whole bullet with muster Step 2's stop instead, because the push is held back for
#               the user and there is no CI wait left for this answer to describe. Nothing here
#               reads posture: this module answers only what the repository has.
#
# `unknown` takes the same brief line as `no-ci` on purpose. Under uncertainty the terminating
# instruction is the safe one: a worker told to stop at the pull request loses at most a wait for a
# check the user can see on the forge anyway, while a worker told to wait for green loses an hour to
# checks that may not exist. The Hand is told plainly which of the two it got, and the line itself
# states no more than both statuses support.
function Get-RepoCiStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [int]$CommitsToCheck = $script:DefaultCommitsToCheck
    )

    $result = [ordered]@{
        repoPath    = $RepoPath
        status      = 'unknown'
        signal      = ''
        detail      = ''
        slug        = ''
        configFiles = @()
        branch      = ''
        commits     = 0
        checksFound = 0
        briefLine   = ''
    }

    $finish = {
        param($status, $signal, $detail)
        $result.status = $status
        $result.signal = $signal
        $result.detail = $detail
        $result.briefLine = Get-CiBriefLine -Status $status
        [pscustomobject]$result
    }

    if (-not (Test-Path -LiteralPath $RepoPath -PathType Container)) {
        return & $finish 'unknown' 'no-such-path' "There is no directory at $RepoPath, so nothing could be checked."
    }

    $null = & git -C $RepoPath rev-parse --is-inside-work-tree 2>$null
    if ($LASTEXITCODE -ne 0) {
        return & $finish 'unknown' 'not-a-repo' "$RepoPath is not a git repository, so nothing could be checked."
    }

    $config = @(Get-RepoCiConfigFiles -RepoPath $RepoPath)
    $result.configFiles = $config

    # The remote is resolved BEFORE the files are judged, because which files count depends on it.
    # A pull request opened here is a GitHub pull request, so on a GitHub remote only GitHub's own
    # workflows are evidence that a check will be posted on it - and GitHub can be asked about the
    # rest. Where nothing can be asked, every provider's file counts.
    $slug = Get-RepoGitHubSlug -RepoPath $RepoPath

    $reporting = @(Get-ReportingCiConfigFiles -RepoPath $RepoPath -ConfigFiles $config -GitHubRemote:([bool]$slug))
    if ($reporting.Count -gt 0) {
        return & $finish 'has-ci' 'ci-config' ("CI is configured in the repository: " + ($reporting -join ', ') + '.')
    }

    # What the file listing settled, for the lines below that have to say it out loud. Configuration
    # that cannot report here is worth naming rather than reporting as an absence: the reader can
    # then see the file themselves and judge whether that is what they meant.
    $configNote = if ($config.Count -gt 0) {
        'holds only CI configuration that cannot report a check on a pull request here (' +
        ($config -join ', ') + ')'
    } else {
        'holds no CI configuration'
    }

    if (-not $slug) {
        $url = (& git -C $RepoPath remote get-url origin 2>$null | Out-String).Trim()
        if (-not $url) {
            # No forge, so there is nowhere for a check to be reported from. This one is settled
            # rather than unknown: the absence of a remote is a fact this can see directly.
            return & $finish 'no-ci' 'no-remote' `
                "There is no origin remote and the repository $configNote, so nothing can report a check."
        }
        return & $finish 'unknown' 'remote-not-github' `
            ("The origin remote is $url, which is not GitHub. This check can only see GitHub's checks, " +
             'so whether that repository has CI could not be established.')
    }
    $result.slug = $slug

    $repoInfo = Invoke-GhApi -Arguments @('api', "repos/$slug", '--jq', '.default_branch')
    if (-not $repoInfo.ok) {
        return & $finish 'unknown' 'lookup-failed' `
            ("$slug could not be read: $($repoInfo.error) Whether it has CI is therefore not known.")
    }
    $branch = ($repoInfo.value -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
    if (-not $branch) {
        return & $finish 'unknown' 'lookup-failed' `
            "$slug answered without naming a default branch, so its commits could not be checked."
    }
    $result.branch = $branch.Trim()

    $commitList = Invoke-GhApi -Arguments @(
        'api', "repos/$slug/commits?sha=$($result.branch)&per_page=$CommitsToCheck", '--jq', '.[].sha')
    if (-not $commitList.ok) {
        return & $finish 'unknown' 'lookup-failed' `
            ("The last commits of $slug's $($result.branch) could not be read: $($commitList.error) " +
             'Whether it has CI is therefore not known.')
    }

    $shas = @($commitList.value -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $result.commits = $shas.Count
    if ($shas.Count -eq 0) {
        return & $finish 'unknown' 'no-commits' `
            "$slug has no commits on $($result.branch) to check, so nothing could be established."
    }

    $answered = $false
    foreach ($sha in $shas) {
        $count = Get-CommitCheckCount -Slug $slug -Sha $sha
        if ($null -eq $count) { continue }
        $answered = $true
        if ($count -gt 0) {
            $result.checksFound = $count
            return & $finish 'has-ci' 'checks-reported' `
                ("$count check(s) reported on $slug commit $($sha.Substring(0, [Math]::Min(7, $sha.Length))), " +
                 "so checks do report here even though the repository $configNote.")
        }
    }

    if (-not $answered) {
        return & $finish 'unknown' 'lookup-failed' `
            "The checks on $slug's recent commits could not be read, so whether it has CI is not known."
    }

    & $finish 'no-ci' 'none-reported' `
        ("$slug $configNote and reported no checks on its last $($shas.Count) commits of " +
         "$($result.branch), so nothing will report on a pull request there.")
}

# The Done-means line for a `no-mistakes` brief, keyed on the status. Stated here rather than left
# to be retyped, because a preflight whose answer never reaches the brief changes nothing at all.
#
# The terminating line is shared by `no-ci` and `unknown`, so it may only claim what both of them
# support. "Checks may not report" is that claim; "checks are not expected to report" is not - it
# states as fact something an `unknown` lookup never established, and a worker told that would
# report a repository as having no CI on the strength of an expired token. The instruction is
# identical either way, which is the part that ends the wait.
function Get-CiBriefLine {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('has-ci', 'no-ci', 'unknown')][string]$Status)

    if ($Status -eq 'has-ci') {
        return ('- Drive the pipeline through to a pull request and report its full https:// URL when CI is ' +
                'first green. Do not merge it.')
    }

    '- Drive the pipeline through to a pull request and stop there. ' +
    'Checks may not report on this repository at all, so when the pipeline''s `ci` step has been ' +
    'waiting more than fifteen minutes with no checks reported, report the pull request''s full ' +
    'https:// URL as delivered, say plainly that no checks were reported, and stop. Do not sit on it. ' +
    'Do not merge it.'
}

Export-ModuleMember -Function Get-GhCommandPath, Invoke-GhApi, Get-RepoGitHubSlug,
                              Get-RepoCiConfigFiles, Get-WorkflowTriggers,
                              Get-ReportingCiConfigFiles, Get-CommitCheckCount, Get-RepoCiStatus,
                              Get-CiBriefLine
