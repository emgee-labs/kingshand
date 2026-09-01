#Requires -Version 7.0
Set-StrictMode -Version Latest

# bin\Ci.psm1 is exercised here against throwaway git repositories and a mocked GitHub API. Nothing
# below reaches the network, needs a token, or knows which repositories exist.
#
# `Invoke-GhApi` is the module's single boundary to the outside world - every lookup goes through
# that one function - so mocking it is what makes the whole answer testable, including the cases
# that matter most: the ones where GitHub does not answer at all.
#
# The rule every case here defends is the same one: an unanswered question is `unknown`, never
# `no-ci` and never `has-ci`. A false `no-ci` throws away a real green check; a false `has-ci`
# restores the hour-long wait for checks that will never arrive.

BeforeAll {
    Import-Module "$PSScriptRoot\..\bin\Ci.psm1" -Force

    $script:TempFixtures = [System.Collections.Generic.List[string]]::new()

    function New-TempFixtureDir {
        param([string]$Prefix = 'ci-')
        $p = Join-Path ([System.IO.Path]::GetTempPath()) ($Prefix + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $p | Out-Null
        $script:TempFixtures.Add($p)
        $p
    }

    # A real repository, because Get-RepoCiStatus asks git directly whether it is one. Cheap enough
    # to make per case, and a stub would only prove the stub works.
    function New-TempRepo {
        param([string]$Origin)
        $d = New-TempFixtureDir -Prefix 'ci-repo-'
        git init -b main $d -q
        git -C $d config user.name  'Test'
        git -C $d config user.email 'test@example.invalid'
        if ($Origin) { git -C $d remote add origin $Origin }
        $d
    }

    function New-WorkflowFile {
        param(
            [Parameter(Mandatory)][string]$RepoPath,
            [string]$Name = 'ci.yml',
            [string]$Content = 'on: push'
        )
        $dir = Join-Path $RepoPath '.github\workflows'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Set-Content -Path (Join-Path $dir $Name) -Value $Content -Encoding utf8
    }

    # gh's two reply shapes, and nothing invented: a success carrying the --jq output as text, and a
    # failure carrying gh's own message.
    function New-GhOk   { param([string]$Value = '') [pscustomobject]@{ ok = $true;  value = $Value; error = '' } }
    function New-GhFail { param([string]$Error = 'gh: Not Found (HTTP 404)') [pscustomobject]@{ ok = $false; value = ''; error = $Error } }
}

AfterAll {
    foreach ($p in $script:TempFixtures) {
        if (Test-Path -LiteralPath $p) {
            Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    $script:TempFixtures.Clear()
}

Describe 'Get-CiBriefLine puts the answer into the brief rather than leaving it to be retyped' {
    # A preflight whose answer never reaches the worker's brief changes nothing at all: the worker
    # only ever reads its brief, so the line IS the delivery mechanism.

    It 'tells a worker on a repository with CI to wait for the first green' {
        $line = Get-CiBriefLine -Status 'has-ci'
        $line.Contains('when CI is first green') | Should -BeTrue
        $line.Contains('Do not merge it.')       | Should -BeTrue
    }

    It 'tells a worker on a repository with no CI to stop at the pull request' {
        $line = Get-CiBriefLine -Status 'no-ci'
        $line.Contains('stop there')            | Should -BeTrue
        $line.Contains('fifteen minutes')       | Should -BeTrue -Because 'an open-ended wait is the failure this removes'
        $line.Contains('Do not sit on it.')     | Should -BeTrue
        $line.Contains('when CI is first green') |
            Should -BeFalse -Because 'green can never arrive where nothing reports'
    }

    # Under uncertainty the terminating instruction is the safe one: stopping at the pull request
    # loses at most a wait for a check the user can see on the forge anyway, while waiting for green
    # loses an hour to checks that may not exist.
    It 'gives an undetermined repository the same terminating line as one with no CI' {
        Get-CiBriefLine -Status 'unknown' | Should -Be (Get-CiBriefLine -Status 'no-ci')
    }

    # Sharing the instruction is deliberate; sharing a claim would not be. An `unknown` lookup never
    # established that nothing reports here - a missing `gh` or an expired token gets that answer -
    # so a line asserting it as fact would have the worker report a repository as CI-less on the
    # strength of a failed lookup, which is the one conversion this module refuses to make.
    It 'states only what both statuses support, never that nothing reports here' {
        $line = Get-CiBriefLine -Status 'unknown'
        $line.Contains('may not report') |
            Should -BeTrue -Because 'the shared line may only claim what an unanswered lookup supports'
        $line.Contains('are not expected to report') |
            Should -BeFalse -Because 'an unsettled question is not evidence that nothing reports'
    }

    It 'refuses a status that is not one of the three' {
        { Get-CiBriefLine -Status 'probably' } | Should -Throw
    }
}

Describe 'Get-RepoCiConfigFiles reads what is committed, and an empty directory is not CI' {
    It 'finds a workflow file' {
        $repo = New-TempRepo
        New-WorkflowFile -RepoPath $repo
        @(Get-RepoCiConfigFiles -RepoPath $repo) | Should -Contain '.github\workflows\ci.yml'
    }

    It 'finds a <name> at the repository root' -ForEach @(
        @{ name = 'azure-pipelines.yml' }
        @{ name = '.gitlab-ci.yml' }
        @{ name = 'Jenkinsfile' }
    ) {
        $repo = New-TempRepo
        Set-Content -Path (Join-Path $repo $name) -Value 'x' -Encoding utf8
        @(Get-RepoCiConfigFiles -RepoPath $repo) | Should -Contain $name
    }

    # A repository that deleted its last workflow keeps the directory. Calling that `has-ci`
    # restores the endless wait, which is the whole failure being fixed.
    It 'does not count an empty workflows directory' {
        $repo = New-TempRepo
        New-Item -ItemType Directory -Force -Path (Join-Path $repo '.github\workflows') | Out-Null
        @(Get-RepoCiConfigFiles -RepoPath $repo).Count | Should -Be 0
    }

    It 'does not count a README that happens to live in the workflows directory' {
        $repo = New-TempRepo
        New-WorkflowFile -RepoPath $repo -Name 'README.md'
        @(Get-RepoCiConfigFiles -RepoPath $repo).Count | Should -Be 0
    }

    It 'finds nothing in a repository that has none' {
        @(Get-RepoCiConfigFiles -RepoPath (New-TempRepo)).Count | Should -Be 0
    }
}

Describe 'Get-RepoGitHubSlug reads owner/repo, and answers nothing for a remote it cannot see' {
    It 'reads <url>' -ForEach @(
        @{ url = 'https://github.com/emgee-labs/kingshand.git'; expected = 'emgee-labs/kingshand' }
        @{ url = 'https://github.com/emgee-labs/kingshand';     expected = 'emgee-labs/kingshand' }
        @{ url = 'git@github.com:emgee-labs/kingshand.git';     expected = 'emgee-labs/kingshand' }
        @{ url = 'ssh://git@github.com/emgee-labs/kingshand';   expected = 'emgee-labs/kingshand' }
    ) {
        Get-RepoGitHubSlug -RepoPath (New-TempRepo -Origin $url) | Should -Be $expected
    }

    It 'answers nothing for a remote that is not GitHub' {
        Get-RepoGitHubSlug -RepoPath (New-TempRepo -Origin 'https://gitlab.com/someone/elsewhere.git') |
            Should -BeNullOrEmpty
    }

    It 'answers nothing when there is no origin at all' {
        Get-RepoGitHubSlug -RepoPath (New-TempRepo) | Should -BeNullOrEmpty
    }
}

Describe 'Get-CommitCheckCount separates zero checks from nobody answering' {
    # THE GUARD THAT KEEPS AN UNAUTHENTICATED MACHINE FROM REPORTING NO CI. Zero is "nothing
    # reported on this commit"; $null is "the question was not answered". Collapsing the two is how
    # a token that expired turns into a worker told to stop before its checks ran.

    It 'adds check runs and commit statuses together' {
        Mock -ModuleName Ci Invoke-GhApi {
            if ($Arguments[1] -like '*check-runs') { New-GhOk '2' } else { New-GhOk '3' }
        }
        Get-CommitCheckCount -Slug 'o/r' -Sha 'abc' | Should -Be 5
    }

    It 'still counts a provider that only posts the older commit statuses' {
        Mock -ModuleName Ci Invoke-GhApi {
            if ($Arguments[1] -like '*check-runs') { New-GhOk '0' } else { New-GhOk '1' }
        }
        Get-CommitCheckCount -Slug 'o/r' -Sha 'abc' | Should -Be 1
    }

    It 'reports zero when both endpoints answered zero' {
        Mock -ModuleName Ci Invoke-GhApi { New-GhOk '0' }
        Get-CommitCheckCount -Slug 'o/r' -Sha 'abc' | Should -Be 0
    }

    It 'reports nothing at all when neither endpoint answered' {
        Mock -ModuleName Ci Invoke-GhApi { New-GhFail }
        Get-CommitCheckCount -Slug 'o/r' -Sha 'abc' |
            Should -BeNullOrEmpty -Because 'a failed lookup is not a count of zero'
    }

    # The same collapse arriving through the success path. `Invoke-GhApi` folds stderr into the
    # value it returns, so any non-fatal line gh prints alongside the count leaves a reply that is
    # not a number - and reading that as zero is how a repository with CI gets reported as having
    # none, with nothing anywhere saying the question went unanswered.
    It 'reports nothing at all when the reply came back but was not a number' {
        Mock -ModuleName Ci Invoke-GhApi { New-GhOk 'gh: a warning arrived instead of a count' }
        Get-CommitCheckCount -Slug 'o/r' -Sha 'abc' |
            Should -BeNullOrEmpty -Because 'a reply nobody could parse is not a count of zero'
    }

    It 'still counts the endpoint that answered when the other reply was unreadable' {
        Mock -ModuleName Ci Invoke-GhApi {
            if ($Arguments[1] -like '*check-runs') { New-GhOk 'gh: a warning' } else { New-GhOk '2' }
        }
        Get-CommitCheckCount -Slug 'o/r' -Sha 'abc' |
            Should -Be 2 -Because 'one endpoint failing to parse does not discard the one that answered'
    }
}

Describe 'Get-RepoCiStatus refuses to guess, and never converts a failed lookup into an answer' {

    Context 'when the repository configures CI itself' {
        It 'answers has-ci from the workflow file, without asking GitHub anything' {
            Mock -ModuleName Ci Invoke-GhApi { throw 'the network must not be reached for this case' }
            $repo = New-TempRepo -Origin 'https://github.com/o/r.git'
            New-WorkflowFile -RepoPath $repo

            $r = Get-RepoCiStatus -RepoPath $repo
            $r.status | Should -Be 'has-ci'
            $r.signal | Should -Be 'ci-config'
            $r.detail | Should -BeLike '*ci.yml*' -Because 'the reader must be able to check the evidence'
            Should -Invoke Invoke-GhApi -ModuleName Ci -Times 0 -Exactly
        }

        It 'answers has-ci from a workflow triggered by a pull request, without asking GitHub' {
            Mock -ModuleName Ci Invoke-GhApi { throw 'the network must not be reached for this case' }
            $repo = New-TempRepo -Origin 'https://github.com/o/r.git'
            New-WorkflowFile -RepoPath $repo -Content "on:`n  pull_request:`n    branches: [main]`n"

            (Get-RepoCiStatus -RepoPath $repo).status | Should -Be 'has-ci'
            Should -Invoke Invoke-GhApi -ModuleName Ci -Times 0 -Exactly
        }
    }

    # THE OTHER HALF OF "NOT SUFFICIENT IN EITHER DIRECTION". A file existing is not a check
    # arriving: a workflow triggered only by `schedule` or `workflow_dispatch` will never report on
    # a pull request, so answering has-ci from its presence restores the hour-long wait exactly as
    # an empty workflows directory would.
    Context 'when the repository configures CI that cannot run on a pull request' {
        BeforeEach {
            $script:Repo = New-TempRepo -Origin 'https://github.com/o/r.git'
            New-WorkflowFile -RepoPath $script:Repo -Name 'nightly.yml' `
                -Content "name: nightly`non:`n  schedule:`n    - cron: '0 3 * * *'`n  workflow_dispatch:`njobs:`n  build:`n    runs-on: ubuntu-latest`n"
        }

        It 'asks GitHub instead of answering from the file, and reports no-ci when nothing reported' {
            Mock -ModuleName Ci Invoke-GhApi {
                if ($Arguments[1] -eq 'repos/o/r') { return New-GhOk 'main' }
                New-GhOk 'sha1'
            }
            Mock -ModuleName Ci Get-CommitCheckCount { 0 }

            $r = Get-RepoCiStatus -RepoPath $script:Repo
            $r.status | Should -Be 'no-ci' -Because 'a nightly workflow cannot put a check on a pull request'
            $r.detail | Should -BeLike '*nightly.yml*' -Because 'the file that was discounted has to reach the reader'
        }

        It 'still answers has-ci when GitHub reports checks on the commits anyway' {
            Mock -ModuleName Ci Invoke-GhApi {
                if ($Arguments[1] -eq 'repos/o/r') { return New-GhOk 'main' }
                New-GhOk 'sha1'
            }
            Mock -ModuleName Ci Get-CommitCheckCount { 3 }

            (Get-RepoCiStatus -RepoPath $script:Repo).signal | Should -Be 'checks-reported'
        }

        It 'answers unknown rather than no-ci when the checks could not be read' {
            Mock -ModuleName Ci Invoke-GhApi { New-GhFail 'gh: Bad credentials (HTTP 401)' }

            (Get-RepoCiStatus -RepoPath $script:Repo).status |
                Should -Be 'unknown' -Because 'discounting the file settles nothing on its own'
        }

        # Both biases point the same way: keep the file. An unreadable `on:` block is not evidence
        # of absence, and another provider's config is only in the list because that provider reads
        # it - this can reason about GitHub's schema and nobody else's.
        It 'keeps a workflow whose triggers could not be read at all' {
            Mock -ModuleName Ci Invoke-GhApi { throw 'the network must not be reached for this case' }
            $repo = New-TempRepo -Origin 'https://github.com/o/r.git'
            New-WorkflowFile -RepoPath $repo -Content "name: something with no triggers`njobs: {}`n"

            (Get-RepoCiStatus -RepoPath $repo).status | Should -Be 'has-ci'
        }

        It 'keeps another provider''s config, whose schema this cannot read' {
            Mock -ModuleName Ci Invoke-GhApi { throw 'the network must not be reached for this case' }
            $repo = New-TempRepo -Origin 'https://github.com/o/r.git'
            Set-Content -Path (Join-Path $repo 'azure-pipelines.yml') -Value 'schedules: []' -Encoding utf8

            (Get-RepoCiStatus -RepoPath $repo).status | Should -Be 'has-ci'
        }
    }

    Context 'reading one workflow''s triggers' {
        It 'reads <case>' -ForEach @(
            @{ case = 'a bare trigger';        yaml = "on: push`n";                                expected = 'push' }
            @{ case = 'an inline list';        yaml = "on: [schedule, pull_request]`n";            expected = 'pull_request' }
            @{ case = 'a block';               yaml = "on:`n  pull_request:`n    branches: [main]`n"; expected = 'pull_request' }
            @{ case = 'a block written as a list'; yaml = "on:`n  - schedule`n  - push`n";         expected = 'push' }
            @{ case = 'a quoted key';          yaml = "'on':`n  merge_group:`n";                   expected = 'merge_group' }
            @{ case = 'the YAML 1.1 boolean';  yaml = "true:`n  workflow_call:`n";                 expected = 'workflow_call' }
        ) {
            $repo = New-TempRepo
            New-WorkflowFile -RepoPath $repo -Content $yaml
            @(Get-WorkflowTriggers -Path (Join-Path $repo '.github\workflows\ci.yml')) |
                Should -Contain $expected
        }

        # The nested keys under a trigger are not triggers. Reading `branches` as one would make
        # every branch-restricted workflow unrecognisable.
        It 'does not mistake a trigger''s own settings for triggers' {
            $repo = New-TempRepo
            New-WorkflowFile -RepoPath $repo -Content "on:`n  schedule:`n    - cron: '0 3 * * *'`njobs:`n  build:`n"
            $triggers = @(Get-WorkflowTriggers -Path (Join-Path $repo '.github\workflows\ci.yml'))
            $triggers.Count | Should -Be 1 -Because 'cron and build are not triggers'
            $triggers[0]    | Should -Be 'schedule'
        }

        It 'answers nothing at all for a file with no on: key, rather than an empty list' {
            $repo = New-TempRepo
            New-WorkflowFile -RepoPath $repo -Content "name: nothing`njobs: {}`n"
            Get-WorkflowTriggers -Path (Join-Path $repo '.github\workflows\ci.yml') |
                Should -BeNullOrEmpty -Because 'not established is not the same as no triggers'
        }
    }

    Context 'when nothing is configured in the repository' {
        BeforeEach { $script:Repo = New-TempRepo -Origin 'https://github.com/o/r.git' }

        # THE CASE A NAIVE WORKFLOWS-DIRECTORY CHECK GETS WRONG, and it is a real repository on this
        # machine: emgeelabs-site has no workflow file anywhere and gets Cloudflare Pages check runs
        # on every commit. A directory test calls that no-ci and stops a worker while checks run.
        It 'answers has-ci when GitHub reports checks even with no CI file in the repository' {
            Mock -ModuleName Ci Invoke-GhApi {
                if ($Arguments[1] -eq 'repos/o/r') { return New-GhOk 'main' }
                New-GhOk "sha1`nsha2"
            }
            Mock -ModuleName Ci Get-CommitCheckCount { 2 }

            $r = Get-RepoCiStatus -RepoPath $script:Repo
            $r.status      | Should -Be 'has-ci'
            $r.signal      | Should -Be 'checks-reported'
            $r.checksFound | Should -Be 2
        }

        It 'looks past a commit with no checks rather than stopping at the newest one' {
            Mock -ModuleName Ci Invoke-GhApi {
                if ($Arguments[1] -eq 'repos/o/r') { return New-GhOk 'main' }
                New-GhOk "sha1`nsha2`nsha3"
            }
            Mock -ModuleName Ci Get-CommitCheckCount {
                if ($Sha -eq 'sha3') { 1 } else { 0 }
            }

            $r = Get-RepoCiStatus -RepoPath $script:Repo
            $r.status | Should -Be 'has-ci' -Because 'a run that has not started on the newest commit is not an absence of CI'
        }

        It 'answers no-ci only when GitHub answered and reported nothing on any commit' {
            Mock -ModuleName Ci Invoke-GhApi {
                if ($Arguments[1] -eq 'repos/o/r') { return New-GhOk 'main' }
                New-GhOk "sha1`nsha2"
            }
            Mock -ModuleName Ci Get-CommitCheckCount { 0 }

            $r = Get-RepoCiStatus -RepoPath $script:Repo
            $r.status | Should -Be 'no-ci'
            $r.signal | Should -Be 'none-reported'
        }

        It 'answers unknown when the repository lookup failed' {
            Mock -ModuleName Ci Invoke-GhApi { New-GhFail 'gh: Not Found (HTTP 404)' }
            $r = Get-RepoCiStatus -RepoPath $script:Repo
            $r.status | Should -Be 'unknown'
            $r.signal | Should -Be 'lookup-failed'
            $r.detail | Should -BeLike '*404*' -Because 'the reason has to reach the reader, not just the verdict'
        }

        It 'answers unknown when the commit list could not be read' {
            Mock -ModuleName Ci Invoke-GhApi {
                if ($Arguments[1] -eq 'repos/o/r') { return New-GhOk 'main' }
                New-GhFail 'gh: Bad credentials (HTTP 401)'
            }
            $r = Get-RepoCiStatus -RepoPath $script:Repo
            $r.status | Should -Be 'unknown'
            $r.detail | Should -BeLike '*401*'
        }

        # The dangerous one. Every commit lookup failing looks exactly like every commit having no
        # checks unless the two are kept apart all the way up.
        It 'answers unknown, never no-ci, when the checks themselves could not be read' {
            Mock -ModuleName Ci Invoke-GhApi {
                if ($Arguments[1] -eq 'repos/o/r') { return New-GhOk 'main' }
                New-GhOk "sha1`nsha2"
            }
            Mock -ModuleName Ci Get-CommitCheckCount { $null }

            $r = Get-RepoCiStatus -RepoPath $script:Repo
            $r.status | Should -Be 'unknown' -Because 'nobody answered, which is not the same as nothing reported'
            $r.signal | Should -Be 'lookup-failed'
        }

        It 'answers unknown when gh is not installed at all' {
            Mock -ModuleName Ci Get-GhCommandPath { $null }
            $r = Get-RepoCiStatus -RepoPath $script:Repo
            $r.status | Should -Be 'unknown'
            $r.detail | Should -BeLike '*gh*' -Because 'the missing tool is the thing to fix'
        }
    }

    Context 'when the question cannot be asked at all' {
        It 'answers unknown for a remote that is not GitHub' {
            $r = Get-RepoCiStatus -RepoPath (New-TempRepo -Origin 'https://gitlab.com/someone/elsewhere.git')
            $r.status | Should -Be 'unknown'
            $r.signal | Should -Be 'remote-not-github'
        }

        It 'answers unknown for a directory that is not a git repository' {
            $r = Get-RepoCiStatus -RepoPath (New-TempFixtureDir)
            $r.status | Should -Be 'unknown'
            $r.signal | Should -Be 'not-a-repo'
        }

        It 'answers unknown for a path that does not exist' {
            $r = Get-RepoCiStatus -RepoPath (Join-Path ([System.IO.Path]::GetTempPath()) 'no-such-repo-4f2a')
            $r.status | Should -Be 'unknown'
            $r.signal | Should -Be 'no-such-path'
        }

        # Settled rather than unknown: with no remote there is no forge, so there is nowhere a check
        # could be reported from, and that is a fact this can see directly.
        It 'answers no-ci for a repository with no remote and no CI file' {
            $r = Get-RepoCiStatus -RepoPath (New-TempRepo)
            $r.status | Should -Be 'no-ci'
            $r.signal | Should -Be 'no-remote'
        }
    }

    Context 'the answer always carries the line the brief needs' {
        It 'carries the matching brief line for <case>' -ForEach @(
            @{ case = 'has-ci' }
            @{ case = 'no-ci' }
            @{ case = 'unknown' }
        ) {
            $repo = New-TempRepo -Origin 'https://github.com/o/r.git'
            switch ($case) {
                'has-ci'  { New-WorkflowFile -RepoPath $repo }
                'no-ci'   {
                    Mock -ModuleName Ci Invoke-GhApi {
                        if ($Arguments[1] -eq 'repos/o/r') { return New-GhOk 'main' } else { return New-GhOk 'sha1' }
                    }
                    Mock -ModuleName Ci Get-CommitCheckCount { 0 }
                }
                'unknown' { Mock -ModuleName Ci Invoke-GhApi { New-GhFail } }
            }

            $r = Get-RepoCiStatus -RepoPath $repo
            $r.status    | Should -Be $case
            $r.briefLine | Should -Be (Get-CiBriefLine -Status $case)
        }
    }
}
