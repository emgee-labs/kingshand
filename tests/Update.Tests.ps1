#Requires -Version 7.0
Set-StrictMode -Version Latest

# bin\Update.psm1 updates the installation it is pointed at, so EVERY case here runs against a
# throwaway repository under TestDrive with its own bare remote and its own stub installer. Nothing
# in this suite fetches, merges, tags or installs anything into the copy of kingshand it is running
# from - an update command tested by updating the live installation is a test that can break the
# machine it runs on, which is the same reason bin\Resolve-BaseRef.ps1 exists as its own file.
#
# The four refusals are the point of the module, so each one is forced rather than described: a
# dirty tree, a live worker, the wrong branch, and a repository with no releases. Every refusal
# case also asserts that HEAD did not move, because a refusal that half-updated would be worse
# than no guard at all.
#
# Liveness is mocked at herdr's own boundary - Invoke-Herdr, the one place that knows its command
# line - so the real Get-HerdrAgents and the real guard run, with no herdr server, no pane and no
# worker anywhere. Mocking the guard's own reader instead would prove nothing about the guard.

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent

    # Herdr first, then Update. Update imports Herdr as a nested module without -Force, so a -Force
    # import of Herdr AFTERWARDS would remove the copy Update is holding and take its functions
    # with it - the failure the statute skill's style rules describe.
    Import-Module (Join-Path $script:Root 'bin\Herdr.psm1')  -Force
    Import-Module (Join-Path $script:Root 'bin\Update.psm1') -Force

    $script:InstallStub = @(
        '#Requires -Version 7.0'
        '# A stub, not the real installer. It records that it ran, OUTSIDE the repository, so the'
        '# working tree it was called from stays clean.'
        'Set-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) ''install-ran.txt'') -Value ''ran'''
        'Write-Host ''stub installer ran'''
        'exit {0}'
    )

    function Add-Commit {
        param([Parameter(Mandatory)][string]$RepoPath, [Parameter(Mandatory)][string]$Message)
        git -C $RepoPath add -A
        git -C $RepoPath commit -q -m $Message
    }

    # An installation and the remote it fetches releases from. The installation is a real clone, so
    # it has a real origin, a real default branch and real tags to fetch.
    function New-Installation {
        param(
            [Parameter(Mandatory)][string]$Name,
            [switch]$TagSeed,
            [switch]$NoRemote,
            [int]$InstallExit = 0
        )

        $base   = Join-Path $TestDrive $Name
        $remote = Join-Path $base 'remote'
        $seed   = Join-Path $base 'seed'
        $inst   = Join-Path $base 'install'
        New-Item -ItemType Directory -Force -Path $base | Out-Null

        git init --bare -b main $remote -q
        git init -b main $seed -q
        git -C $seed config user.name  'Test'
        git -C $seed config user.email 'test@example.invalid'
        # Off, so committing LF content on Windows does not print a line-ending warning per file
        # into the middle of the test output.
        git -C $seed config core.autocrlf false

        Set-Content -LiteralPath (Join-Path $seed 'VERSION') -Value '0.1.0' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $seed 'README.md') -Value 'a throwaway kingshand' -Encoding utf8
        New-Item -ItemType Directory -Force -Path (Join-Path $seed 'bin') | Out-Null
        Set-Content -LiteralPath (Join-Path $seed 'bin\thing.ps1') -Value '# a tool' -Encoding utf8
        # The parentheses are load-bearing: -f binds tighter than -join, so without them the
        # newline is formatted with the exit code and the stub keeps a literal {0} placeholder -
        # which exits 0 and quietly turns the failing-installer case into a passing one.
        Set-Content -LiteralPath (Join-Path $seed 'install.ps1') `
            -Value (($script:InstallStub -join "`n") -f $InstallExit) -Encoding utf8
        Add-Commit -RepoPath $seed -Message 'Seed the repository'
        if ($TagSeed) { git -C $seed tag 'v0.1.0' }

        git -C $seed remote add origin $remote
        git -C $seed push -q origin main --tags 2>&1 | Out-Null

        git clone -q $remote $inst 2>&1 | Out-Null
        git -C $inst config user.name  'Test'
        git -C $inst config user.email 'test@example.invalid'
        git -C $inst config core.autocrlf false
        if ($NoRemote) { git -C $inst remote remove origin }

        [pscustomobject]@{
            Path   = $inst
            Seed   = $seed
            Remote = $remote
            Marker = Join-Path $base 'install-ran.txt'
        }
    }

    # Cuts one release on the remote: one commit per subject, the version bumped in the last of
    # them, then the tag. The subjects are what "what changed" must come back with.
    function Publish-Release {
        param(
            [Parameter(Mandatory)]$Fixture,
            [Parameter(Mandatory)][string]$Version,
            [Parameter(Mandatory)][string[]]$Subjects,
            [string]$Touch = 'README.md',
            [switch]$DropVersionFile
        )

        $seed = $Fixture.Seed
        for ($i = 0; $i -lt $Subjects.Count; $i++) {
            Add-Content -LiteralPath (Join-Path $seed $Touch) -Value "change $i for $Version"
            if ($i -eq $Subjects.Count - 1) {
                if ($DropVersionFile) {
                    git -C $seed rm -q --cached 'VERSION' | Out-Null
                    Remove-Item -LiteralPath (Join-Path $seed 'VERSION') -Force
                } else {
                    Set-Content -LiteralPath (Join-Path $seed 'VERSION') -Value $Version -Encoding utf8
                }
            }
            Add-Commit -RepoPath $seed -Message $Subjects[$i]
        }
        git -C $seed tag "v$Version"
        git -C $seed push -q origin main --tags 2>&1 | Out-Null
    }

    function Get-Head {
        param([Parameter(Mandatory)][string]$RepoPath)
        (& git -C $RepoPath rev-parse HEAD | Out-String).Trim()
    }
}

Describe 'the release branch is named in one place' {
    It 'is main, which is what the guard compares against' {
        Get-ReleaseBranchName | Should -Be 'main'
    }
}

Describe 'liveness comes from herdr, and unknown is not none' {
    It 'reports no workers when herdr knows of none' {
        Mock -ModuleName Herdr Invoke-Herdr { [pscustomobject]@{ agents = @() } }
        @(Get-LiveWorkerNames).Count | Should -Be 0
    }

    It 'names every worker herdr knows about' {
        Mock -ModuleName Herdr Invoke-Herdr {
            [pscustomobject]@{ agents = @(
                [pscustomobject]@{ name = 't-9001'; state = 'working' }
                [pscustomobject]@{ name = 't-9002'; state = 'idle' }
            ) }
        }
        @(Get-LiveWorkerNames) | Should -Be @('t-9001', 't-9002')
    }

    It 'throws rather than reporting none when herdr cannot be asked' {
        Mock -ModuleName Herdr Invoke-Herdr { throw (Get-HerdrCommandHint) }
        { Get-LiveWorkerNames } | Should -Throw -ExpectedMessage '*herdr was not found*'
    }
}

Describe 'the latest release is the highest version tag, and only a release tag counts' {
    BeforeAll {
        $script:TagRepo = Join-Path $TestDrive 'tagorder'
        git init -b main $script:TagRepo -q
        git -C $script:TagRepo config user.name  'Test'
        git -C $script:TagRepo config user.email 'test@example.invalid'
        Set-Content -LiteralPath (Join-Path $script:TagRepo 'VERSION') -Value '0.1.0' -Encoding utf8
        Add-Commit -RepoPath $script:TagRepo -Message 'Seed the repository'
    }

    It 'sorts by version rather than by string, so v0.10.0 beats v0.9.0' {
        git -C $script:TagRepo tag 'v0.9.0'
        git -C $script:TagRepo tag 'v0.10.0'
        Get-LatestReleaseTag -RepoPath $script:TagRepo | Should -Be 'v0.10.0'
    }

    It 'ignores a tag that is not a release' {
        git -C $script:TagRepo tag 'v2-backup'
        git -C $script:TagRepo tag 'vendor-drop'
        Get-LatestReleaseTag -RepoPath $script:TagRepo | Should -Be 'v0.10.0'
    }

    It 'refuses by name where nothing has been tagged at all' {
        $none = Join-Path $TestDrive 'notags'
        git init -b main $none -q
        git -C $none config user.name  'Test'
        git -C $none config user.email 'test@example.invalid'
        Set-Content -LiteralPath (Join-Path $none 'VERSION') -Value '0.1.0' -Encoding utf8
        Add-Commit -RepoPath $none -Message 'Seed the repository'

        { Get-LatestReleaseTag -RepoPath $none } |
            Should -Throw -ExpectedMessage '*No release has been tagged in this repository yet*'
    }
}

Describe 'what changed is the commit subjects, with no parsing of anything' {
    BeforeAll {
        $script:LogRepo = Join-Path $TestDrive 'changes'
        git init -b main $script:LogRepo -q
        git -C $script:LogRepo config user.name  'Test'
        git -C $script:LogRepo config user.email 'test@example.invalid'
        Set-Content -LiteralPath (Join-Path $script:LogRepo 'VERSION') -Value '0.1.0' -Encoding utf8
        Add-Commit -RepoPath $script:LogRepo -Message 'Seed the repository'
        git -C $script:LogRepo tag 'v0.1.0'

        # A side branch merged with a merge commit, so the merge subject is there to be excluded.
        git -C $script:LogRepo checkout -q -b side
        Add-Content -LiteralPath (Join-Path $script:LogRepo 'README.md') -Value 'side work'
        Add-Commit -RepoPath $script:LogRepo -Message 'Teach the drawer to close'
        git -C $script:LogRepo checkout -q main
        git -C $script:LogRepo merge -q --no-ff side -m 'Merge pull request #1 from side' 2>&1 | Out-Null
        Add-Content -LiteralPath (Join-Path $script:LogRepo 'README.md') -Value 'more'
        Add-Commit -RepoPath $script:LogRepo -Message 'Refresh the badge'
        git -C $script:LogRepo tag 'v0.2.0'
    }

    It 'returns one subject per commit between the two releases' {
        $changes = @(Get-ReleaseChanges -RepoPath $script:LogRepo -From 'v0.1.0' -To 'v0.2.0')
        $changes | Should -Contain 'Teach the drawer to close'
        $changes | Should -Contain 'Refresh the badge'
    }

    It 'leaves out the merge commit, which names a branch rather than a change' {
        @(Get-ReleaseChanges -RepoPath $script:LogRepo -From 'v0.1.0' -To 'v0.2.0') |
            Should -Not -Contain 'Merge pull request #1 from side'
    }

    It 'is empty between a release and itself' {
        @(Get-ReleaseChanges -RepoPath $script:LogRepo -From 'v0.2.0' -To 'v0.2.0').Count | Should -Be 0
    }
}

Describe 'a session is told to re-read only what an update actually moved' {
    BeforeAll {
        $script:SurfaceRepo = Join-Path $TestDrive 'surface'
        git init -b main $script:SurfaceRepo -q
        git -C $script:SurfaceRepo config user.name  'Test'
        git -C $script:SurfaceRepo config user.email 'test@example.invalid'
        New-Item -ItemType Directory -Force -Path (Join-Path $script:SurfaceRepo 'bin') | Out-Null
        Set-Content -LiteralPath (Join-Path $script:SurfaceRepo 'README.md') -Value 'start' -Encoding utf8
        Add-Commit -RepoPath $script:SurfaceRepo -Message 'Seed the repository'
        $script:SurfaceBase = Get-Head -RepoPath $script:SurfaceRepo

        Add-Content -LiteralPath (Join-Path $script:SurfaceRepo 'README.md') -Value 'docs only'
        Add-Commit -RepoPath $script:SurfaceRepo -Message 'Document something'
        $script:SurfaceDocs = Get-Head -RepoPath $script:SurfaceRepo

        Set-Content -LiteralPath (Join-Path $script:SurfaceRepo 'bin\thing.ps1') -Value '# tool' -Encoding utf8
        Add-Commit -RepoPath $script:SurfaceRepo -Message 'Add a tool'
        $script:SurfaceBin = Get-Head -RepoPath $script:SurfaceRepo
    }

    It 'says no when only prose moved' {
        Test-RereadNeeded -RepoPath $script:SurfaceRepo -From $script:SurfaceBase -To $script:SurfaceDocs |
            Should -BeFalse
    }

    It 'says yes when bin\ moved' {
        Test-RereadNeeded -RepoPath $script:SurfaceRepo -From $script:SurfaceDocs -To $script:SurfaceBin |
            Should -BeTrue
    }
}

Describe 'an update that can happen moves the installation and reports the move' {
    BeforeEach { Mock -ModuleName Herdr Invoke-Herdr { [pscustomobject]@{ agents = @() } } }

    It 'fast-forwards to the latest release and names both versions and every change' {
        $f = New-Installation -Name 'happy'
        Publish-Release -Fixture $f -Version '0.2.0' -Subjects @('Teach the drawer to close', 'Refresh the badge')

        $r = Invoke-KingshandUpdate -Root $f.Path

        $r.status      | Should -Be 'updated'
        $r.ok          | Should -BeTrue
        $r.reason      | Should -Be ''
        $r.fromVersion | Should -Be '0.1.0'
        $r.toVersion   | Should -Be '0.2.0'
        $r.tag         | Should -Be 'v0.2.0'
        @($r.changes)  | Should -Contain 'Teach the drawer to close'
        @($r.changes)  | Should -Contain 'Refresh the badge'
        Get-Head -RepoPath $f.Path | Should -Be $r.toCommit
    }

    It 'runs the installer it found beside the installation, without being told where it is' {
        $f = New-Installation -Name 'installer'
        Publish-Release -Fixture $f -Version '0.2.0' -Subjects @('Change a thing')

        $r = Invoke-KingshandUpdate -Root $f.Path

        $r.installOk | Should -BeTrue
        Test-Path -LiteralPath $f.Marker |
            Should -BeTrue -Because 'the default -InstallScript is the install.ps1 at the root being updated'
    }

    It 'reports an installer that did not finish, rather than reporting plain success' {
        $f = New-Installation -Name 'badinstaller' -InstallExit 3
        Publish-Release -Fixture $f -Version '0.2.0' -Subjects @('Change a thing')

        $r = Invoke-KingshandUpdate -Root $f.Path

        $r.status       | Should -Be 'updated'
        $r.installOk    | Should -BeFalse
        $r.ok           | Should -BeFalse -Because 'the installation moved and its configuration may not have followed'
        $r.installError | Should -Match 'exited 3'
    }

    It 'says a release that moved bin\ needs the instructions read again' {
        $f = New-Installation -Name 'reread'
        Publish-Release -Fixture $f -Version '0.2.0' -Subjects @('Add a tool') -Touch 'bin\thing.ps1'

        (Invoke-KingshandUpdate -Root $f.Path).rereadNeeded | Should -BeTrue
    }

    It 'says nothing needs re-reading when only prose moved' {
        $f = New-Installation -Name 'noreread'
        Publish-Release -Fixture $f -Version '0.2.0' -Subjects @('Document something') -Touch 'README.md'

        (Invoke-KingshandUpdate -Root $f.Path).rereadNeeded | Should -BeFalse
    }

    It 'reports already-current where the installation is on the latest release' {
        $f = New-Installation -Name 'current' -TagSeed

        $before = Get-Head -RepoPath $f.Path
        $r = Invoke-KingshandUpdate -Root $f.Path

        $r.status      | Should -Be 'already-current'
        $r.ok          | Should -BeTrue
        $r.tag         | Should -Be 'v0.1.0'
        $r.fromVersion | Should -Be '0.1.0'
        $r.toVersion   | Should -Be '0.1.0'
        @($r.changes).Count | Should -Be 0
        Get-Head -RepoPath $f.Path | Should -Be $before
        Test-Path -LiteralPath $f.Marker |
            Should -BeFalse -Because 'nothing moved, so there is nothing to re-install'
    }
}

Describe 'every refusal names itself and leaves the installation exactly as it was' {
    BeforeEach { Mock -ModuleName Herdr Invoke-Herdr { [pscustomobject]@{ agents = @() } } }

    It 'refuses a dirty working tree' {
        $f = New-Installation -Name 'dirty'
        Publish-Release -Fixture $f -Version '0.2.0' -Subjects @('Change a thing')
        Add-Content -LiteralPath (Join-Path $f.Path 'README.md') -Value 'my own unsaved work'

        $before = Get-Head -RepoPath $f.Path
        $r = Invoke-KingshandUpdate -Root $f.Path

        $r.status | Should -Be 'refused'
        $r.ok     | Should -BeFalse
        $r.reason | Should -Match 'uncommitted changes'
        $r.reason | Should -Match 'README\.md'
        $r.reason | Should -Match 'never stashes or discards anything'
        Get-Head -RepoPath $f.Path | Should -Be $before
    }

    It 'refuses while any worker is live, and names it' {
        Mock -ModuleName Herdr Invoke-Herdr {
            [pscustomobject]@{ agents = @([pscustomobject]@{ name = 't-9001'; state = 'working' }) }
        }
        $f = New-Installation -Name 'liveworker'
        Publish-Release -Fixture $f -Version '0.2.0' -Subjects @('Change a thing')

        $before = Get-Head -RepoPath $f.Path
        $r = Invoke-KingshandUpdate -Root $f.Path

        $r.status | Should -Be 'refused'
        $r.reason | Should -Match 't-9001'
        $r.reason | Should -Match 'live'
        Get-Head -RepoPath $f.Path | Should -Be $before
    }

    It 'refuses when whether a worker is live could not be established' {
        Mock -ModuleName Herdr Invoke-Herdr { throw (Get-HerdrCommandHint) }
        $f = New-Installation -Name 'nolivenessanswer'
        Publish-Release -Fixture $f -Version '0.2.0' -Subjects @('Change a thing')

        $before = Get-Head -RepoPath $f.Path
        $r = Invoke-KingshandUpdate -Root $f.Path

        $r.status | Should -Be 'refused'
        $r.reason | Should -Match 'could not be established'
        Get-Head -RepoPath $f.Path |
            Should -Be $before -Because 'unknown liveness must never be read as no workers'
    }

    It 'refuses a checkout that is not on the release branch' {
        $f = New-Installation -Name 'wrongbranch'
        Publish-Release -Fixture $f -Version '0.2.0' -Subjects @('Change a thing')
        git -C $f.Path checkout -q -b 'my-experiment'

        $before = Get-Head -RepoPath $f.Path
        $r = Invoke-KingshandUpdate -Root $f.Path

        $r.status | Should -Be 'refused'
        $r.reason | Should -Match 'not on the release branch main'
        $r.reason | Should -Match 'my-experiment'
        Get-Head -RepoPath $f.Path | Should -Be $before
    }

    It 'refuses a detached HEAD by name rather than calling it a branch' {
        $f = New-Installation -Name 'detached'
        Publish-Release -Fixture $f -Version '0.2.0' -Subjects @('Change a thing')
        git -C $f.Path checkout -q --detach 2>&1 | Out-Null

        $r = Invoke-KingshandUpdate -Root $f.Path

        $r.status | Should -Be 'refused'
        $r.reason | Should -Match 'detached HEAD'
    }

    It 'refuses where no release has been tagged yet, which is the common path' {
        $f = New-Installation -Name 'noreleases'

        $before = Get-Head -RepoPath $f.Path
        $r = Invoke-KingshandUpdate -Root $f.Path

        $r.status | Should -Be 'refused'
        $r.reason | Should -Match 'No release has been tagged'
        $r.tag    | Should -Be ''
        Get-Head -RepoPath $f.Path |
            Should -Be $before -Because 'with no release to move to, nothing may be pulled instead'
    }

    It 'refuses an installation that has diverged, rather than forcing it' {
        $f = New-Installation -Name 'diverged'
        Publish-Release -Fixture $f -Version '0.2.0' -Subjects @('Change a thing')
        Add-Content -LiteralPath (Join-Path $f.Path 'README.md') -Value 'work of my own'
        Add-Commit -RepoPath $f.Path -Message 'Keep something of my own'

        $before = Get-Head -RepoPath $f.Path
        $r = Invoke-KingshandUpdate -Root $f.Path

        $r.status | Should -Be 'refused'
        $r.reason | Should -Match 'cannot be fast-forwarded'
        Get-Head -RepoPath $f.Path |
            Should -Be $before -Because 'unlanded work of the user''s own is never discarded'
    }

    It 'refuses a release whose own version cannot be read' {
        $f = New-Installation -Name 'noversionatrelease'
        Publish-Release -Fixture $f -Version '0.2.0' -Subjects @('Drop the version file') -DropVersionFile

        $before = Get-Head -RepoPath $f.Path
        $r = Invoke-KingshandUpdate -Root $f.Path

        $r.status | Should -Be 'refused'
        $r.reason | Should -Match 'has no readable VERSION file'
        Get-Head -RepoPath $f.Path |
            Should -Be $before -Because 'a move nobody can report is not made'
    }

    It 'refuses an installation whose own VERSION file is missing' {
        $f = New-Installation -Name 'noversionhere'
        Publish-Release -Fixture $f -Version '0.2.0' -Subjects @('Change a thing')
        Remove-Item -LiteralPath (Join-Path $f.Path 'VERSION') -Force

        $r = Invoke-KingshandUpdate -Root $f.Path

        $r.status      | Should -Be 'refused'
        $r.reason      | Should -Match 'There is no VERSION file at'
        $r.fromVersion | Should -Be '' -Because 'a version that could not be read is never invented'
    }

    It 'refuses where there is nowhere to fetch releases from' {
        $f = New-Installation -Name 'noremote' -NoRemote

        $r = Invoke-KingshandUpdate -Root $f.Path

        $r.status | Should -Be 'refused'
        $r.reason | Should -Match 'no origin remote'
    }

    It 'refuses where the installer it would re-run is not there' {
        $f = New-Installation -Name 'noinstaller'
        Publish-Release -Fixture $f -Version '0.2.0' -Subjects @('Change a thing')
        Remove-Item -LiteralPath (Join-Path $f.Path 'install.ps1') -Force
        Add-Commit -RepoPath $f.Path -Message 'Remove the installer locally'

        $before = Get-Head -RepoPath $f.Path
        $r = Invoke-KingshandUpdate -Root $f.Path

        $r.status | Should -Be 'refused'
        $r.reason | Should -Match 'There is no installer at'
        Get-Head -RepoPath $f.Path |
            Should -Be $before -Because 'a half-moved installation is worse than a refusal'
    }

    It 'refuses a path that is not a git repository' {
        $plain = Join-Path $TestDrive 'notarepo'
        New-Item -ItemType Directory -Force -Path $plain | Out-Null

        $r = Invoke-KingshandUpdate -Root $plain
        $r.status | Should -Be 'refused'
        $r.reason | Should -Match 'not a git repository'
    }

    It 'refuses a path that does not exist' {
        $r = Invoke-KingshandUpdate -Root (Join-Path $TestDrive 'nothing-here')
        $r.status | Should -Be 'refused'
        $r.reason | Should -Match 'no directory at'
    }
}

Describe 'the guard readers answer for themselves' {
    It 'reports a clean tree as clean and a dirty one by path' {
        $f = New-Installation -Name 'readers'
        @(Get-DirtyPaths -RepoPath $f.Path).Count | Should -Be 0

        Add-Content -LiteralPath (Join-Path $f.Path 'README.md') -Value 'edit'
        @(Get-DirtyPaths -RepoPath $f.Path) | Should -Contain 'README.md'
    }

    It 'reports the checked-out branch, and an empty string on a detached HEAD' {
        $f = New-Installation -Name 'branchreader'
        Get-CheckedOutBranch -RepoPath $f.Path | Should -Be 'main'

        git -C $f.Path checkout -q --detach 2>&1 | Out-Null
        Get-CheckedOutBranch -RepoPath $f.Path | Should -Be ''
    }

    It 'refuses to resolve a ref that names no commit' {
        $f = New-Installation -Name 'refreader'
        { Resolve-CommitId -RepoPath $f.Path -Ref 'v9.9.9' } |
            Should -Throw -ExpectedMessage '*does not name a commit*'
    }
}
