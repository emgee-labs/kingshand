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

$script:DefaultCommitsToCheck = 5

# Config files that mean some provider is wired up. The list is short and every entry is a file a
# provider reads: this is a positive signal only, and its absence proves nothing, which is why the
# check-runs lookup below runs whenever this finds nothing.
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
        $any = $true
        $n = 0
        if ([int]::TryParse(($r.value -replace '\s', ''), [ref]$n)) { $total += $n }
    }

    if (-not $any) { return $null }
    $total
}

# The answer, and everything needed to say it out loud.
#
# .status       has-ci | no-ci | unknown
# .signal       what settled it
# .detail       one line naming the evidence, written to be read to a person
# .briefLine    the Done-means line a `no-mistakes` brief must carry for this repository
#
# `unknown` takes the same brief line as `no-ci` on purpose. Under uncertainty the terminating
# instruction is the safe one: a worker told to stop at the pull request loses at most a wait for a
# check the user can see on the forge anyway, while a worker told to wait for green loses an hour to
# checks that may not exist. The Hand is told plainly which of the two it got.
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
    if ($config.Count -gt 0) {
        return & $finish 'has-ci' 'ci-config' ("CI is configured in the repository: " + ($config -join ', ') + '.')
    }

    $slug = Get-RepoGitHubSlug -RepoPath $RepoPath
    if (-not $slug) {
        $url = (& git -C $RepoPath remote get-url origin 2>$null | Out-String).Trim()
        if (-not $url) {
            # No forge, so there is nowhere for a check to be reported from. This one is settled
            # rather than unknown: the absence of a remote is a fact this can see directly.
            return & $finish 'no-ci' 'no-remote' `
                'There is no origin remote and no CI configuration in the repository, so nothing can report a check.'
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
                 'so checks do report here even though the repository holds no CI configuration.')
        }
    }

    if (-not $answered) {
        return & $finish 'unknown' 'lookup-failed' `
            "The checks on $slug's recent commits could not be read, so whether it has CI is not known."
    }

    & $finish 'no-ci' 'none-reported' `
        ("$slug holds no CI configuration and reported no checks on its last $($shas.Count) commits of " +
         "$($result.branch), so nothing will report on a pull request there.")
}

# The Done-means line for a `no-mistakes` brief, keyed on the status. Stated here rather than left
# to be retyped, because a preflight whose answer never reaches the brief changes nothing at all.
function Get-CiBriefLine {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('has-ci', 'no-ci', 'unknown')][string]$Status)

    if ($Status -eq 'has-ci') {
        return ('- Drive the pipeline through to a pull request and report its full https:// URL when CI is ' +
                'first green. Do not merge it.')
    }

    '- Drive the pipeline through to a pull request and stop there. Checks are not expected to report on ' +
    'this repository, so when the pipeline''s `ci` step has been waiting more than fifteen minutes with no ' +
    'checks reported, report the pull request''s full https:// URL as delivered and say plainly that CI ' +
    'cannot report here. Do not sit on it. Do not merge it.'
}

Export-ModuleMember -Function Get-GhCommandPath, Invoke-GhApi, Get-RepoGitHubSlug,
                              Get-RepoCiConfigFiles, Get-CommitCheckCount, Get-RepoCiStatus,
                              Get-CiBriefLine
