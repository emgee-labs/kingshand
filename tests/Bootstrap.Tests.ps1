#Requires -Version 7.0
Set-StrictMode -Version Latest

# bootstrap.ps1 is the one-URL install: it clones kingshand, checks out the latest release and runs
# install.ps1 from the clone. Every case here runs it as a separate pwsh process - the way a user
# runs it - against a local bare repository under TestDrive, never the network. That remote carries
# the real bin\Update.psm1 and the modules it imports, because the release rules are read from
# there, and a stub install.ps1 that records how it was called.
#
# The stub writes its record beside the target folder rather than inside it, so a clone stays clean
# and "the installer never ran" is the absence of one file.

BeforeAll {
    $script:Root      = Split-Path $PSScriptRoot -Parent
    $script:Bootstrap = Join-Path $script:Root 'bootstrap.ps1'
    $script:Pwsh      = (Get-Process -Id $PID).Path

    $script:InstallStub = @(
        'param([switch]$InstallMissing)'
        '$record = Join-Path (Split-Path $PSScriptRoot -Parent) ''install-ran.txt'''
        'Set-Content -LiteralPath $record -Value (''bound='' + (@($PSBoundParameters.Keys) -join '','') + '';args='' + ($args -join '',''))'
        'Write-Host ''stub installer ran'''
        'exit {0}'
    )

    function Invoke-Git {
        param([Parameter(Mandatory, ValueFromRemainingArguments)][string[]]$GitArgs)
        $out = & git @GitArgs 2>&1
        if ($LASTEXITCODE -ne 0) { throw "git $($GitArgs -join ' ') failed: $out" }
        $out
    }

    function Add-Commit {
        param([Parameter(Mandatory)][string]$RepoPath, [Parameter(Mandatory)][string]$Message)
        Invoke-Git -C $RepoPath add -A | Out-Null
        Invoke-Git -C $RepoPath commit -q -m $Message | Out-Null
    }

    # A bare remote shaped like kingshand: two releases, and a pre-release commit past the newest
    # one, so "the latest release" is neither the branch head nor the first tag.
    function New-Remote {
        param(
            [Parameter(Mandatory)][string]$Name,
            [switch]$NoTags,
            [switch]$NoUpdateModule,
            [switch]$NoInstaller,
            [switch]$ReleaseIsNotACommit,
            [int]$InstallExit = 0
        )
        $base   = Join-Path $TestDrive "remote-$Name"
        $remote = Join-Path $base 'kingshand.git'
        $seed   = Join-Path $base 'seed'
        New-Item -ItemType Directory -Force -Path $base | Out-Null

        Invoke-Git init --bare -q -b main $remote | Out-Null
        Invoke-Git init -q -b main $seed | Out-Null
        Invoke-Git -C $seed config user.name 'Test' | Out-Null
        Invoke-Git -C $seed config user.email 'test@example.invalid' | Out-Null
        Invoke-Git -C $seed config core.autocrlf false | Out-Null

        if (-not $NoUpdateModule) {
            $bin = Join-Path $seed 'bin'
            New-Item -ItemType Directory -Force -Path $bin | Out-Null
            foreach ($m in 'Update.psm1', 'Version.psm1', 'Herdr.psm1', 'Paths.psm1') {
                Copy-Item -LiteralPath (Join-Path (Join-Path $script:Root 'bin') $m) -Destination $bin
            }
        }
        if (-not $NoInstaller) {
            Set-Content -LiteralPath (Join-Path $seed 'install.ps1') -Encoding utf8 `
                        -Value (($script:InstallStub -join "`n") -f $InstallExit)
        }

        Set-Content -LiteralPath (Join-Path $seed 'VERSION') -Value '0.1.0' -Encoding utf8
        Add-Commit -RepoPath $seed -Message 'first release'
        if (-not $NoTags) { Invoke-Git -C $seed tag v0.1.0 | Out-Null }

        Set-Content -LiteralPath (Join-Path $seed 'VERSION') -Value '0.2.0' -Encoding utf8
        Add-Commit -RepoPath $seed -Message 'second release'
        if (-not $NoTags) { Invoke-Git -C $seed tag v0.2.0 | Out-Null }

        Set-Content -LiteralPath (Join-Path $seed 'VERSION') -Value '0.3.0-rc1' -Encoding utf8
        Add-Commit -RepoPath $seed -Message 'not released yet'
        if (-not $NoTags) { Invoke-Git -C $seed tag v0.3.0-rc1 | Out-Null }

        # The newest release tag names a file's contents rather than a commit, so nothing can be
        # checked out at it.
        if ($ReleaseIsNotACommit) {
            $blob = Invoke-Git -C $seed rev-parse 'HEAD:VERSION' | Select-Object -First 1
            Invoke-Git -C $seed tag v9.9.9 $blob | Out-Null
        }

        Invoke-Git -C $seed push -q --tags $remote main | Out-Null
        [pscustomobject]@{
            Path      = $remote
            V020 = if ($NoTags) { $null } else { Invoke-Git -C $seed rev-parse 'v0.2.0^{commit}' | Select-Object -First 1 }
        }
    }

    # A child pwsh prints an error wrapped to the console width with ` | ` down its left edge, so
    # the gutter is taken out along with the line breaks before any phrase is looked for.
    function ConvertTo-FlatText {
        param($Output)
        (($Output | Out-String) -replace '\s+\|\s+', ' ' -replace '\s+', ' ')
    }

    # Runs the bootstrap as a file in its own pwsh, the way `.\bootstrap.ps1 ...` runs it.
    function Invoke-Bootstrap {
        param([string[]]$ArgumentList = @())
        $out  = & $script:Pwsh -NoProfile -NonInteractive -File $script:Bootstrap @ArgumentList 2>&1
        $code = $LASTEXITCODE
        $global:LASTEXITCODE = 0
        [pscustomobject]@{ Code = $code; Text = (ConvertTo-FlatText $out) }
    }

    # Runs a command line in its own pwsh, for the piped forms.
    function Invoke-Pwsh {
        param([Parameter(Mandatory)][string]$Command)
        $out  = & $script:Pwsh -NoProfile -NonInteractive -Command $Command 2>&1
        $code = $LASTEXITCODE
        $global:LASTEXITCODE = 0
        [pscustomobject]@{ Code = $code; Text = (ConvertTo-FlatText $out) }
    }

    function Get-InstallRecord {
        param([Parameter(Mandatory)][string]$Target)
        $record = Join-Path (Split-Path $Target -Parent) 'install-ran.txt'
        if (Test-Path -LiteralPath $record) { (Get-Content -LiteralPath $record -Raw).Trim() } else { $null }
    }

    function New-TargetBase {
        param([Parameter(Mandatory)][string]$Name)
        $base = Join-Path $TestDrive "target-$Name"
        New-Item -ItemType Directory -Force -Path $base | Out-Null
        $base
    }

    $script:Remote = New-Remote -Name 'releases'
}

# git writes its objects read-only, and TestDrive's own cleanup cannot delete a read-only file.
AfterAll {
    Get-ChildItem -LiteralPath $TestDrive -Recurse -Force -File -ErrorAction SilentlyContinue |
        Where-Object { $_.IsReadOnly } | ForEach-Object { $_.IsReadOnly = $false }
}

Describe 'bootstrap.ps1 - a fresh install' {
    It 'clones into a folder that does not exist, checks out the latest release on main, and runs the installer' {
        $target = Join-Path (New-TargetBase 'new') 'kingshand'

        $r = Invoke-Bootstrap -ArgumentList @('-Path', $target, '-Repository', $script:Remote.Path)

        $r.Code | Should -Be 0 -Because $r.Text
        (git -C $target rev-parse HEAD) | Should -Be $script:Remote.V020
        (git -C $target rev-parse --abbrev-ref HEAD) | Should -Be 'main'
        $r.Text.Contains('Checked out v0.2.0') | Should -BeTrue -Because $r.Text
        Get-InstallRecord -Target $target | Should -Be 'bound=;args='
    }

    It 'clones into an existing empty folder and passes -InstallMissing through' {
        $target = Join-Path (New-TargetBase 'empty') 'kingshand'
        New-Item -ItemType Directory -Path $target | Out-Null

        $r = Invoke-Bootstrap -ArgumentList @('-Path', $target, '-Repository', $script:Remote.Path, '-InstallMissing')

        $r.Code | Should -Be 0 -Because $r.Text
        (git -C $target rev-parse HEAD) | Should -Be $script:Remote.V020
        Get-InstallRecord -Target $target | Should -Be 'bound=InstallMissing;args='
    }

    It 'leaves the clone on main tracking origin, so /update can move it later' {
        $target = Join-Path (New-TargetBase 'upstream') 'kingshand'

        $r = Invoke-Bootstrap -ArgumentList @('-Path', $target, '-Repository', $script:Remote.Path)

        $r.Code | Should -Be 0 -Because $r.Text
        (git -C $target rev-parse --abbrev-ref '@{upstream}') | Should -Be 'origin/main'
        (git -C $target status --porcelain) | Should -BeNullOrEmpty
    }

    It 'passes on a non-zero exit from the installer when run as a file' {
        $remote = New-Remote -Name 'install-fails' -InstallExit 3
        $target = Join-Path (New-TargetBase 'install-fails') 'kingshand'

        $r = Invoke-Bootstrap -ArgumentList @('-Path', $target, '-Repository', $remote.Path)

        $r.Code | Should -Be 3
        $r.Text.Contains('install.ps1 finished with exit code 3') | Should -BeTrue -Because $r.Text
    }
}

Describe 'bootstrap.ps1 - an existing kingshand clone' {
    It 'runs the installer there and leaves its checkout exactly where it was' {
        $target = Join-Path (New-TargetBase 'existing') 'kingshand'
        git clone -q "$($script:Remote.Path)" $target 2>&1 | Out-Null
        git -C $target checkout -q v0.1.0 2>&1 | Out-Null
        $before = git -C $target rev-parse HEAD
        # Given without the `.git` its origin carries, to prove the two name one remote.
        $repository = $script:Remote.Path -replace '\.git$', ''

        $r = Invoke-Bootstrap -ArgumentList @('-Path', $target, '-Repository', $repository)

        $r.Code | Should -Be 0 -Because $r.Text
        (git -C $target rev-parse HEAD) | Should -Be $before
        $r.Text.Contains('already a kingshand clone') | Should -BeTrue -Because $r.Text
        $r.Text.Contains('not on a release') | Should -BeFalse -Because $r.Text
        Get-InstallRecord -Target $target | Should -Be 'bound=;args='
    }

    It 'says a clone off a release tag is not on a release, points at /update, and still runs the installer' {
        $target = Join-Path (New-TargetBase 'existing-offtag') 'kingshand'
        git clone -q "$($script:Remote.Path)" $target 2>&1 | Out-Null
        $before = git -C $target rev-parse HEAD

        $r = Invoke-Bootstrap -ArgumentList @('-Path', $target, '-Repository', $script:Remote.Path)

        $r.Code | Should -Be 0 -Because $r.Text
        (git -C $target rev-parse HEAD) | Should -Be $before
        $r.Text.Contains('It is not on a release; /update moves it to the latest release.') | Should -BeTrue -Because $r.Text
        Get-InstallRecord -Target $target | Should -Be 'bound=;args='
    }

    It 'says the release could not be checked when the clone has no update module' {
        $remote = New-Remote -Name 'existing-nomodule' -NoUpdateModule
        $target = Join-Path (New-TargetBase 'existing-nomodule') 'kingshand'
        git clone -q "$($remote.Path)" $target 2>&1 | Out-Null

        $r = Invoke-Bootstrap -ArgumentList @('-Path', $target, '-Repository', $remote.Path)

        $r.Code | Should -Be 0 -Because $r.Text
        $r.Text.Contains('could not be checked: it has no bin\Update.psm1') | Should -BeTrue -Because $r.Text
        $r.Text.Contains('not on a release') | Should -BeFalse -Because $r.Text
        Get-InstallRecord -Target $target | Should -Be 'bound=;args='
    }
}

Describe 'bootstrap.ps1 - refusals that change nothing' {
    It 'refuses a folder that is not empty and is not a git repository' {
        $target = Join-Path (New-TargetBase 'occupied') 'kingshand'
        New-Item -ItemType Directory -Path $target | Out-Null
        Set-Content -LiteralPath (Join-Path $target 'notes.txt') -Value 'mine'

        $r = Invoke-Bootstrap -ArgumentList @('-Path', $target, '-Repository', $script:Remote.Path)

        $r.Code | Should -Not -Be 0
        $r.Text.Contains('already exists, is not empty, and is not a kingshand clone') | Should -BeTrue -Because $r.Text
        @(Get-ChildItem -LiteralPath $target -Force).Name | Should -Be @('notes.txt')
        Get-Content -LiteralPath (Join-Path $target 'notes.txt') | Should -Be 'mine'
        Get-InstallRecord -Target $target | Should -BeNullOrEmpty
    }

    It 'refuses a clone of some other repository, and names it' {
        $other  = Join-Path $TestDrive 'other.git'
        git init --bare -q -b main $other 2>&1 | Out-Null
        $target = Join-Path (New-TargetBase 'other') 'kingshand'
        git init -q -b main $target 2>&1 | Out-Null
        git -C $target remote add origin $other
        Set-Content -LiteralPath (Join-Path $target 'work.txt') -Value 'mine'

        $r = Invoke-Bootstrap -ArgumentList @('-Path', $target, '-Repository', $script:Remote.Path)

        $r.Code | Should -Not -Be 0
        $r.Text.Contains("is a clone of $other") | Should -BeTrue -Because $r.Text
        (git -C $target remote get-url origin) | Should -Be $other
        Get-InstallRecord -Target $target | Should -BeNullOrEmpty
    }

    It 'refuses a path that is a file' {
        $target = Join-Path (New-TargetBase 'file') 'kingshand'
        Set-Content -LiteralPath $target -Value 'a file'

        $r = Invoke-Bootstrap -ArgumentList @('-Path', $target, '-Repository', $script:Remote.Path)

        $r.Code | Should -Not -Be 0
        $r.Text.Contains('is a file, not a folder') | Should -BeTrue -Because $r.Text
        Get-Content -LiteralPath $target | Should -Be 'a file'
    }
}

Describe 'bootstrap.ps1 - failures name themselves' {
    It 'names git when it is not on PATH' {
        $target = Join-Path (New-TargetBase 'nogit') 'kingshand'
        $pwshDir = Split-Path $script:Pwsh -Parent
        $cmd = "`$env:PATH = '$pwshDir'; & '$script:Bootstrap' -Path '$target' -Repository '$($script:Remote.Path)'"

        $r = Invoke-Pwsh -Command $cmd

        $r.Code | Should -Not -Be 0
        $r.Text.Contains('git is not on PATH') | Should -BeTrue -Because $r.Text
        Test-Path -LiteralPath $target | Should -BeFalse
    }

    It 'names the clone that failed, and creates nothing' {
        $target  = Join-Path (New-TargetBase 'noclone') 'kingshand'
        $missing = Join-Path $TestDrive 'no-such-remote.git'

        $r = Invoke-Bootstrap -ArgumentList @('-Path', $target, '-Repository', $missing)

        $r.Code | Should -Not -Be 0
        $r.Text.Contains("git could not clone $missing") | Should -BeTrue -Because $r.Text
        Test-Path -LiteralPath $target | Should -BeFalse
        Get-InstallRecord -Target $target | Should -BeNullOrEmpty
    }

    It 'stops before the installer when no release has been tagged, and leaves the clone' {
        $remote = New-Remote -Name 'untagged' -NoTags
        $target = Join-Path (New-TargetBase 'untagged') 'kingshand'

        $r = Invoke-Bootstrap -ArgumentList @('-Path', $target, '-Repository', $remote.Path)

        $r.Code | Should -Not -Be 0
        $r.Text.Contains('its latest release could not be read') | Should -BeTrue -Because $r.Text
        $r.Text.Contains('No release has been tagged') | Should -BeTrue -Because $r.Text
        Test-Path -LiteralPath (Join-Path $target '.git') | Should -BeTrue
        Get-InstallRecord -Target $target | Should -BeNullOrEmpty
    }

    It 'stops before the installer when the clone carries no update module' {
        $remote = New-Remote -Name 'nomodule' -NoUpdateModule
        $target = Join-Path (New-TargetBase 'nomodule') 'kingshand'

        $r = Invoke-Bootstrap -ArgumentList @('-Path', $target, '-Repository', $remote.Path)

        $r.Code | Should -Not -Be 0
        $r.Text.Contains('has no bin\Update.psm1') | Should -BeTrue -Because $r.Text
        Get-InstallRecord -Target $target | Should -BeNullOrEmpty
    }

    It 'names the release it could not check out, and stops before the installer' {
        $remote = New-Remote -Name 'badtag' -ReleaseIsNotACommit
        $target = Join-Path (New-TargetBase 'badtag') 'kingshand'

        $r = Invoke-Bootstrap -ArgumentList @('-Path', $target, '-Repository', $remote.Path)

        $r.Code | Should -Not -Be 0
        $r.Text.Contains('git could not check out v9.9.9 on main') | Should -BeTrue -Because $r.Text
        Get-InstallRecord -Target $target | Should -BeNullOrEmpty
    }

    It 'names a clone with no installer in it' {
        $remote = New-Remote -Name 'noinstaller' -NoInstaller
        $target = Join-Path (New-TargetBase 'noinstaller') 'kingshand'

        $r = Invoke-Bootstrap -ArgumentList @('-Path', $target, '-Repository', $remote.Path)

        $r.Code | Should -Not -Be 0
        $r.Text.Contains("there is no install.ps1 in $target") | Should -BeTrue -Because $r.Text
    }

    It 'never prints a credential carried in the repository URL' {
        $target = Join-Path (New-TargetBase 'secret') 'kingshand'
        $cmd = "`$env:GIT_TERMINAL_PROMPT = '0'; & '$script:Bootstrap' -Path '$target' " +
               "-Repository 'https://someone:s3cr3t-token@127.0.0.1:9/kingshand.git'"

        $r = Invoke-Pwsh -Command $cmd

        $r.Code | Should -Not -Be 0
        $r.Text.Contains('***@127.0.0.1') | Should -BeTrue -Because $r.Text
        $r.Text.Contains('s3cr3t-token') | Should -BeFalse -Because $r.Text
    }

    It 'names PowerShell 7 when piped into Windows PowerShell 5.1' -Skip:(-not (Get-Command 'powershell.exe' -ErrorAction SilentlyContinue)) {
        $out = & powershell.exe -NoProfile -NonInteractive -Command "Get-Content -Raw -LiteralPath '$script:Bootstrap' | Invoke-Expression" 2>&1
        $global:LASTEXITCODE = 0
        $text = ConvertTo-FlatText $out

        $text.Contains('it needs PowerShell 7 or newer') | Should -BeTrue -Because $text
    }
}

Describe 'bootstrap.ps1 - piped' {
    It 'takes the default folder under the home directory when piped with no parameters' {
        $fakeHome = New-TargetBase 'home'
        $default  = Join-Path $fakeHome 'kingshand'
        New-Item -ItemType Directory -Path $default | Out-Null
        Set-Content -LiteralPath (Join-Path $default 'notes.txt') -Value 'mine'
        # Refused on purpose: the default folder is occupied, so the run proves which folder it
        # chose without cloning anything from the network.
        $cmd = "Set-Variable -Name HOME -Value '$fakeHome' -Force -Scope Global; " +
               "Get-Content -Raw -LiteralPath '$script:Bootstrap' | Invoke-Expression"

        $r = Invoke-Pwsh -Command $cmd

        $r.Text.Contains("$default already exists, is not empty") | Should -BeTrue -Because $r.Text
        Get-Content -LiteralPath (Join-Path $default 'notes.txt') | Should -Be 'mine'
    }

    It 'installs when piped through a script block with parameters, and leaves no strict mode behind' {
        $target = Join-Path (New-TargetBase 'piped') 'kingshand'
        $cmd = "& ([scriptblock]::Create((Get-Content -Raw -LiteralPath '$script:Bootstrap'))) " +
               "-Path '$target' -Repository '$($script:Remote.Path)' -InstallMissing; " +
               "'unset-read=' + `$notAVariable"

        $r = Invoke-Pwsh -Command $cmd

        $r.Code | Should -Be 0 -Because $r.Text
        (git -C $target rev-parse HEAD) | Should -Be $script:Remote.V020
        Get-InstallRecord -Target $target | Should -Be 'bound=InstallMissing;args='
        $r.Text.Contains('unset-read=') | Should -BeTrue -Because $r.Text
    }
}
