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
        param([Parameter(Mandatory)][string]$RepoPath, [string]$Name = 'ci.yml')
        $dir = Join-Path $RepoPath '.github\workflows'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Set-Content -Path (Join-Path $dir $Name) -Value 'on: push' -Encoding utf8
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
