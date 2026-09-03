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
# line - so the real Get-HerdrAgentInventory and the real guard run, with no herdr server, no pane
# and no worker anywhere. Mocking the guard's own reader instead would prove nothing about the guard.
#
# The two reads the guard makes BEFORE that boundary - is herdr installed, is its server up - run
# the binary rather than going through Invoke-Herdr, so they are mocked too, and every case that
# reaches the guard says herdr is installed and its server running unless it is the case about one
# of those. Without that this suite would pass only on a machine that happens to have herdr
# installed with its server up, which is exactly the coupling the rest of it avoids.
#
# Each of those two is mocked in Update rather than in Herdr, because that is where the call
# resolves: Get-LiveWorkerNames calls them directly, and Pester replaces a function in the scope
# doing the calling. Invoke-Herdr is the other way round - Get-HerdrAgentInventory calls it from
# inside Herdr - so that one is mocked there, which is what lets the real inventory reader run.
#
# The server read is Get-HerdrServerState, not the boolean beside it: a status call that failed and
# a server that is genuinely down are different answers here, and tests\Herdr.Tests.ps1 is where
# that reader is exercised against a stubbed binary.

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent

    # A path, not a binary. Nothing here executes it: it exists so the guard's "is herdr installed"
    # read answers yes without the machine needing an actual herdr.
    $script:StubHerdrPath = 'C:\not-a-real-place\herdr.exe'

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

    # One seeded repository per tag case. Tags are repository-wide and cumulative, so a case that
    # adds one to a shared repository changes what every later case sees - and the earlier ones then
    # pass only while Pester happens to run the block in declaration order.
    function New-TagRepo {
        param(
            [Parameter(Mandatory)][string]$Name,
            [string]$Version = '0.1.0',
            [string[]]$Tags = @()
        )

        $path = Join-Path $TestDrive $Name
        git init -b main $path -q
        git -C $path config user.name  'Test'
        git -C $path config user.email 'test@example.invalid'
        Set-Content -LiteralPath (Join-Path $path 'VERSION') -Value $Version -Encoding utf8
        Add-Commit -RepoPath $path -Message 'Seed the repository'
        foreach ($t in $Tags) { git -C $path tag $t }
        $path
    }
}

Describe 'the release branch is named in one place' {
    It 'is main, which is what the guard compares against' {
        Get-ReleaseBranchName | Should -Be 'main'
    }
}

Describe 'liveness comes from herdr, and unknown is not none' {
    # Only ONE state means nobody is working: a server that is genuinely down, because a pane dies
    # with it. Every other way of not getting an answer - no herdr, a status read that failed, an
    # agent list that failed - is not knowing, and an update that proceeds on not knowing is the
    # failure this guard exists to prevent.
    BeforeEach {
        Mock -ModuleName Update Get-HerdrCommandPath { $script:StubHerdrPath }
        Mock -ModuleName Update Get-HerdrServerState { [pscustomobject]@{ state = 'running'; detail = '' } }
    }

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

    It 'throws rather than reporting none when herdr is not installed at all' {
        Mock -ModuleName Update Get-HerdrCommandPath { $null }
        { Get-LiveWorkerNames } | Should -Throw -ExpectedMessage '*herdr was not found*'
    }

    It 'reports no workers when herdr is installed but its server is not running' {
        Mock -ModuleName Update Get-HerdrServerState {
            [pscustomobject]@{ state = 'stopped'; detail = 'not running' }
        }
        Mock -ModuleName Herdr Invoke-Herdr { throw 'agent list must not be reached with the server down' }

        @(Get-LiveWorkerNames).Count |
            Should -Be 0 -Because 'a pane dies with its server, so a server that is down holds no worker'
    }

    It 'throws rather than reporting none when the server state itself could not be read' {
        Mock -ModuleName Update Get-HerdrServerState {
            [pscustomobject]@{ state = 'unknown'; detail = 'herdr status exited 1 - could not reach the server' }
        }
        Mock -ModuleName Herdr Invoke-Herdr { throw 'agent list must not be reached on an unknown server state' }

        { Get-LiveWorkerNames } |
            Should -Throw -ExpectedMessage '*could not be read*' `
                -Because 'a status call that failed did not establish that the server is down'
    }

    It 'throws rather than reporting none when the running server could not be asked' {
        Mock -ModuleName Herdr Invoke-Herdr {
            [pscustomobject]@{ error = [pscustomobject]@{ code = 'timeout'; message = 'no reply' } }
        }

        { Get-LiveWorkerNames } |
            Should -Throw -ExpectedMessage '*timeout*' -Because 'an error from agent list is not an empty list'
    }

    It 'throws rather than reporting none when the server answered nothing readable' {
        Mock -ModuleName Herdr Invoke-Herdr { $null }
        { Get-LiveWorkerNames } | Should -Throw -ExpectedMessage '*nothing that could be read*'
    }
}

Describe 'the latest release is the highest version tag, and only a release tag counts' {
    # A repository per case, because tags are repository-wide and cumulative. Sharing one would let
    # a case that tags a higher version decide what an earlier case sees, so the block would pass
    # only while Pester ran it in declaration order.

    It 'sorts by version rather than by string, so v0.10.0 beats v0.9.0' {
        $repo = New-TagRepo -Name 'tagorder' -Tags @('v0.9.0', 'v0.10.0')
        Get-LatestReleaseTag -RepoPath $repo | Should -Be 'v0.10.0'
    }

    It 'ignores a tag that is not a release' {
        $repo = New-TagRepo -Name 'tagnotarelease' -Tags @('v0.9.0', 'v0.10.0', 'v2-backup', 'vendor-drop')
        Get-LatestReleaseTag -RepoPath $repo | Should -Be 'v0.10.0'
    }

    It 'never picks a pre-release, which git''s own ordering ranks above the release' {
        # Not hypothetical: `git tag --sort=-v:refname` really does list v1.0.0-rc1 before v1.0.0
        # unless versionsort.suffix is configured, so a pattern that admitted the suffix would have
        # selected the candidate and moved people back to its older commit.
        $repo = New-TagRepo -Name 'prereleaseorder' -Version '1.0.0' `
                    -Tags @('v0.9.0', 'v1.0.0', 'v1.0.0-rc1', 'v1.0.0+build3')

        Get-LatestReleaseTag -RepoPath $repo |
            Should -Be 'v1.0.0' -Because 'only a plain three-number tag is a release'
    }

    It 'refuses by name where the only tags are pre-releases' {
        $repo = New-TagRepo -Name 'onlyprereleases' -Version '1.0.0-rc.1' -Tags @('v1.0.0-rc1')

        { Get-LatestReleaseTag -RepoPath $repo } |
            Should -Throw -ExpectedMessage '*No release has been tagged in this repository yet*' `
                -Because 'a candidate is something to try, not something to update everybody to'
    }

    It 'refuses by name where nothing has been tagged at all' {
        $none = New-TagRepo -Name 'notags'

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
    BeforeEach {
        Mock -ModuleName Update Get-HerdrCommandPath { $script:StubHerdrPath }
        Mock -ModuleName Update Get-HerdrServerState { [pscustomobject]@{ state = 'running'; detail = '' } }
        Mock -ModuleName Herdr Invoke-Herdr { [pscustomobject]@{ agents = @() } }
    }

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
    BeforeEach {
        Mock -ModuleName Update Get-HerdrCommandPath { $script:StubHerdrPath }
        Mock -ModuleName Update Get-HerdrServerState { [pscustomobject]@{ state = 'running'; detail = '' } }
        Mock -ModuleName Herdr Invoke-Herdr { [pscustomobject]@{ agents = @() } }
    }

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

    It 'refuses when there is no herdr to ask whether a worker is live' {
        Mock -ModuleName Update Get-HerdrCommandPath { $null }
        $f = New-Installation -Name 'noherdratall'
        Publish-Release -Fixture $f -Version '0.2.0' -Subjects @('Change a thing')

        $before = Get-Head -RepoPath $f.Path
        $r = Invoke-KingshandUpdate -Root $f.Path

        $r.status | Should -Be 'refused'
        $r.reason | Should -Match 'could not be established'
        $r.reason | Should -Match 'herdr was not found'
        Get-Head -RepoPath $f.Path |
            Should -Be $before -Because 'unknown liveness must never be read as no workers'
    }

    It 'refuses when the herdr that is running could not be asked' {
        Mock -ModuleName Herdr Invoke-Herdr {
            [pscustomobject]@{ error = [pscustomobject]@{ code = 'timeout'; message = 'no reply' } }
        }
        $f = New-Installation -Name 'nolivenessanswer'
        Publish-Release -Fixture $f -Version '0.2.0' -Subjects @('Change a thing')

        $before = Get-Head -RepoPath $f.Path
        $r = Invoke-KingshandUpdate -Root $f.Path

        $r.status | Should -Be 'refused'
        $r.reason | Should -Match 'could not be established'
        $r.reason | Should -Match 'timeout'
        Get-Head -RepoPath $f.Path |
            Should -Be $before -Because 'an unreadable answer is not an answer of none'
    }

    It 'updates when herdr is installed but its server is down, which really is no workers' {
        Mock -ModuleName Update Get-HerdrServerState {
            [pscustomobject]@{ state = 'stopped'; detail = 'not running' }
        }
        Mock -ModuleName Herdr Invoke-Herdr { throw 'agent list must not be reached with the server down' }
        $f = New-Installation -Name 'serverdown'
        Publish-Release -Fixture $f -Version '0.2.0' -Subjects @('Change a thing')

        $r = Invoke-KingshandUpdate -Root $f.Path

        $r.status | Should -Be 'updated' -Because 'a pane dies with its server, so this is a fact rather than a guess'
        $r.reason | Should -Be ''
    }

    It 'refuses when whether herdr''s server is up could not be read' {
        Mock -ModuleName Update Get-HerdrServerState {
            [pscustomobject]@{ state = 'unknown'; detail = 'herdr status exited 1 - could not reach the server' }
        }
        Mock -ModuleName Herdr Invoke-Herdr { throw 'agent list must not be reached on an unknown server state' }
        $f = New-Installation -Name 'serverstateunknown'
        Publish-Release -Fixture $f -Version '0.2.0' -Subjects @('Change a thing')

        $before = Get-Head -RepoPath $f.Path
        $r = Invoke-KingshandUpdate -Root $f.Path

        $r.status | Should -Be 'refused'
        $r.reason | Should -Match 'could not be established'
        $r.reason | Should -Match 'exited 1'
        Get-Head -RepoPath $f.Path |
            Should -Be $before -Because 'a status read that failed is not a server that is down'
    }

    It 'refuses when the checked-out branch could not be read at all' {
        # Not the same state as a detached HEAD, and it used to be reported as one: git failing
        # returned the same empty string the detached case does, so the refusal named a branch
        # position nothing had established.
        $f = New-Installation -Name 'unreadablebranch'
        Publish-Release -Fixture $f -Version '0.2.0' -Subjects @('Change a thing')
        Mock -ModuleName Update Get-CheckedOutBranch { throw 'The branch checked out could not be read - fatal: not a git repository' }

        $before = Get-Head -RepoPath $f.Path
        $r = Invoke-KingshandUpdate -Root $f.Path

        $r.status | Should -Be 'refused'
        $r.reason | Should -Match 'could not be read'
        $r.reason | Should -Not -Match 'detached HEAD'
        Get-Head -RepoPath $f.Path | Should -Be $before
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

    It 'throws rather than answering an empty string when git could not say' {
        # The empty string means one specific thing - git replied HEAD, so the checkout is detached.
        # A git that failed said nothing at all, and answering the same empty string for both is how
        # a refusal came to call a checkout detached when nothing had established that it was.
        $plain = Join-Path $TestDrive 'branchreader-notarepo'
        New-Item -ItemType Directory -Force -Path $plain | Out-Null

        { Get-CheckedOutBranch -RepoPath $plain } |
            Should -Throw -ExpectedMessage '*could not be read*'
    }

    It 'refuses to resolve a ref that names no commit' {
        $f = New-Installation -Name 'refreader'
        { Resolve-CommitId -RepoPath $f.Path -Ref 'v9.9.9' } |
            Should -Throw -ExpectedMessage '*does not name a commit*'
    }
}
