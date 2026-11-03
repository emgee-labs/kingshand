#Requires -Version 7.0
Set-StrictMode -Version Latest

# Discovery for the optional review gate.
#
# The rule that matters here is not "can it find a file". It is that kingshand names the RIGHT
# source. `npm install -g no-mistakes` is the obvious guess and it installs a completely different,
# unrelated tool - a TS/JS static-analysis package by another author. It installs cleanly, so the
# mistake surfaces later, as a gate that does not gate. Anything that tells a user where to get the
# review gate has to steer them away from that name, and these cases pin it.

BeforeAll {
    Import-Module "$PSScriptRoot\..\bin\Paths.psm1" -Force

    $script:TempFixtures = [System.Collections.Generic.List[string]]::new()
    $script:SavedPath = $env:PATH
    $script:SavedHome = $env:KINGSHAND_HOME

    function New-TempFixtureDir {
        param([Parameter(Mandatory)][string]$Prefix)
        $p = Join-Path ([IO.Path]::GetTempPath()) ($Prefix + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $p | Out-Null
        $script:TempFixtures.Add($p)
        $p
    }

    # A program this host can actually find on PATH and launch: a `.cmd` on Windows, an executable
    # shell script with no extension on macOS and Linux.
    function New-LaunchableStub {
        param([Parameter(Mandatory)][string]$Directory, [Parameter(Mandatory)][string]$Name)
        if ($IsWindows) {
            $p = Join-Path $Directory "$Name.cmd"
            Set-Content -LiteralPath $p -Value '@echo off' -Encoding ascii
        } else {
            $p = Join-Path $Directory $Name
            Set-Content -LiteralPath $p -Value '#!/bin/sh' -Encoding ascii
            # Through .NET rather than chmod: a case may already have pointed PATH at a fixture.
            [IO.File]::SetUnixFileMode($p, [IO.UnixFileMode]'UserRead, UserWrite, UserExecute')
        }
        $p
    }

    $script:HostExe = if ($IsWindows) { 'no-mistakes.exe' } else { 'no-mistakes' }
}

AfterAll {
    $env:PATH = $script:SavedPath
    $env:KINGSHAND_HOME = $script:SavedHome
    foreach ($p in $script:TempFixtures) {
        Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Get-NoMistakesCommandPath finds the review gate without demanding it' {

    It 'finds the bundled copy under this system''s own file name' {
        $home_ = New-TempFixtureDir -Prefix 'nm-name-'
        New-Item -ItemType Directory -Force -Path (Join-Path $home_ 'tools' 'no-mistakes') | Out-Null
        $exe = Join-Path $home_ 'tools' 'no-mistakes' 'no-mistakes'
        Set-Content -LiteralPath $exe -Value 'stub' -Encoding utf8

        Mock -ModuleName Paths Get-KingshandPlatform { 'Linux' }
        $env:KINGSHAND_HOME = $home_
        $env:PATH = New-TempFixtureDir -Prefix 'nm-path-'

        Get-NoMistakesCommandPath | Should -Be $exe -Because 'on macOS and Linux the binary has no .exe'
    }

    It 'returns null when there is neither one on PATH nor one bundled' {
        $home_ = New-TempFixtureDir -Prefix 'nm-empty-'
        $env:KINGSHAND_HOME = $home_
        $env:PATH = New-TempFixtureDir -Prefix 'nm-path-'

        Get-NoMistakesCommandPath | Should -BeNullOrEmpty -Because 'the gate is optional, so absent is a normal answer rather than an error'
    }

    It 'finds the copy the installer drops in tools\no-mistakes' {
        $home_ = New-TempFixtureDir -Prefix 'nm-bundled-'
        New-Item -ItemType Directory -Force -Path (Join-Path $home_ 'tools\no-mistakes') | Out-Null
        $exe = Join-Path $home_ 'tools' 'no-mistakes' $script:HostExe
        Set-Content -LiteralPath $exe -Value 'stub' -Encoding utf8

        $env:KINGSHAND_HOME = $home_
        $env:PATH = New-TempFixtureDir -Prefix 'nm-path-'

        Get-NoMistakesCommandPath | Should -Be $exe
    }

    # Someone who already manages their own copy must not be given a second one. Same rule as herdr.
    It 'prefers a copy the user already has on PATH over the bundled one' {
        $home_ = New-TempFixtureDir -Prefix 'nm-both-'
        New-Item -ItemType Directory -Force -Path (Join-Path $home_ 'tools\no-mistakes') | Out-Null
        Set-Content -LiteralPath (Join-Path $home_ 'tools' 'no-mistakes' $script:HostExe) -Value 'bundled' -Encoding utf8

        $onPath = New-TempFixtureDir -Prefix 'nm-onpath-'
        $theirs = New-LaunchableStub -Directory $onPath -Name 'no-mistakes'

        $env:KINGSHAND_HOME = $home_
        $env:PATH = $onPath

        Get-NoMistakesCommandPath | Should -Be $theirs
    }
}

Describe 'Get-NoMistakesHint sends people to the right tool' {

    It 'names the switch that installs it' {
        (Get-NoMistakesHint) | Should -BeLike '*-WithReviewGate*'
    }

    It 'names the actual source repository' {
        (Get-NoMistakesHint) | Should -BeLike '*github.com/kunchenguid/no-mistakes*'
    }

    # The whole reason this hint exists as one owned string rather than three ad-hoc messages.
    It 'warns against the npm package of the same name, which is a different tool' {
        $h = Get-NoMistakesHint
        $h | Should -BeLike '*npm install -g no-mistakes*'
        $h | Should -BeLike '*unrelated*'
    }

    It 'says the gate is only needed by the postures that use it' {
        $h = Get-NoMistakesHint
        $h | Should -BeLike '*no-mistakes-prod-only*'
    }
}


# ---------------------------------------------------------------------------------------------
# Which form of Claude Code gets resolved, and why the wrapper is the wrong answer.
#
# npm's claude.cmd forwards with `%*`, which re-expands the raw command line, so cmd.exe parses the
# quotes inside an argument as delimiters and the value is cut at the first one. Measured: a JSON
# schema passed through the wrapper arrived as `{` and Claude Code answered "--json-schema is not
# valid JSON: JSON Parse error: Expected '}'". The same call to the real binary, same machine, same
# minute, returned correct output.
#
# The cost of getting this wrong is not a crash - workers still dispatch fine, because kingshand
# passes no quoted arguments. It is the review gate: every one of its agent steps passes a JSON
# schema, so the whole pipeline dies instantly with an error about JSON that never mentions PATH.
# That is why the order below is asserted rather than left to whichever Get-Command answers first.
# ---------------------------------------------------------------------------------------------
#
# Windows only: the wrapper and the nested binary exist only there, and on macOS and Linux PATH's
# own `claude` is the answer - asserted further down, under the platform helpers.
Describe 'Get-ClaudeCommandPath prefers the binary over npm''s wrapper' -Skip:(-not $IsWindows) {

    BeforeEach {
        $script:Bin = New-TempFixtureDir -Prefix 'claude-bin-'
        $script:Npm = New-TempFixtureDir -Prefix 'claude-npm-'
    }

    It 'returns claude.exe when it is on PATH, even with a wrapper also present' {
        Set-Content -LiteralPath (Join-Path $script:Bin 'claude.exe') -Value 'stub' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $script:Npm 'claude.cmd') -Value '@echo off' -Encoding ascii
        $env:PATH = "$($script:Bin);$($script:Npm)"

        Get-ClaudeCommandPath | Should -Be (Join-Path $script:Bin 'claude.exe')
    }

    # The npm bin directory holds claude, claude.cmd and claude.ps1 but no claude.exe - the binary
    # is one package directory down. Finding it there is what spares a user the PATH edit.
    It 'digs the binary out of the npm package when only the wrapper is on PATH' {
        $nested = Join-Path $script:Npm 'node_modules\@anthropic-ai\claude-code\bin'
        New-Item -ItemType Directory -Force -Path $nested | Out-Null
        Set-Content -LiteralPath (Join-Path $nested 'claude.exe') -Value 'stub' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $script:Npm 'claude.cmd') -Value '@echo off' -Encoding ascii
        $env:PATH = $script:Npm

        Get-ClaudeCommandPath | Should -Be (Join-Path $nested 'claude.exe')
    }

    It 'falls back to the wrapper rather than reporting nothing at all' {
        Set-Content -LiteralPath (Join-Path $script:Npm 'claude.cmd') -Value '@echo off' -Encoding ascii
        $env:PATH = $script:Npm

        $p = Get-ClaudeCommandPath
        $p | Should -Be (Join-Path $script:Npm 'claude.cmd')
        Test-ClaudeCommandIsWrapper -Path $p |
            Should -BeTrue -Because 'a degraded answer has to be recognisable as one'
    }

    It 'does not call the binary a wrapper' {
        Set-Content -LiteralPath (Join-Path $script:Bin 'claude.exe') -Value 'stub' -Encoding utf8
        $env:PATH = $script:Bin
        Test-ClaudeCommandIsWrapper -Path (Get-ClaudeCommandPath) | Should -BeFalse
    }

    It 'returns null when Claude Code is nowhere' {
        $env:PATH = New-TempFixtureDir -Prefix 'claude-none-'
        Get-ClaudeCommandPath | Should -BeNullOrEmpty
    }
}

Describe 'Get-ClaudeWrapperHint explains the failure someone will actually see' {

    It 'names the error text the wrapper produces' {
        (Get-ClaudeWrapperHint) | Should -BeLike '*--json-schema is not valid JSON*'
    }

    It 'names the directory that fixes it' {
        (Get-ClaudeWrapperHint) | Should -BeLike '*node_modules\@anthropic-ai\claude-code\bin*'
    }

    It 'says why the wrapper breaks, not just that it does' {
        $h = Get-ClaudeWrapperHint
        $h | Should -BeLike '*%`**'
        $h | Should -BeLike '*review gate*'
    }
}

# ---------------------------------------------------------------------------------------------
# The platform helpers. Every branch is driven on whichever host runs the suite by faking the
# platform and architecture inside Paths.psm1, so a Windows run still proves the macOS and Linux
# answers and a Linux run still proves the Windows ones. Where a branch needs the host's own
# filesystem to answer - what Get-Command can find - the case is skipped on hosts that cannot.
# ---------------------------------------------------------------------------------------------
Describe 'Get-KingshandPlatform names the system it runs on' {

    It 'agrees with the host' {
        $expected = if ($IsWindows) { 'Windows' } elseif ($IsMacOS) { 'MacOS' } else { 'Linux' }
        Get-KingshandPlatform | Should -Be $expected
    }
}

Describe 'Get-UserHomePath reads the variable each system''s shells set' {

    BeforeAll {
        $script:SavedProfile = $env:USERPROFILE
        $script:SavedUnixHome = $env:HOME
    }
    AfterAll {
        $env:USERPROFILE = $script:SavedProfile
        $env:HOME = $script:SavedUnixHome
    }
    BeforeEach {
        $env:USERPROFILE = Join-Path $TestDrive 'profile'
        $env:HOME = Join-Path $TestDrive 'home'
    }

    It 'reads USERPROFILE on Windows' {
        Mock -ModuleName Paths Get-KingshandPlatform { 'Windows' }
        Get-UserHomePath | Should -Be (Join-Path $TestDrive 'profile')
    }

    It 'reads HOME on <_>' -ForEach @('MacOS', 'Linux') {
        $p = $_
        Mock -ModuleName Paths Get-KingshandPlatform { $p }.GetNewClosure()
        Get-UserHomePath | Should -Be (Join-Path $TestDrive 'home')
    }

    It 'throws naming USERPROFILE when Windows has none, rather than inventing a home' {
        Mock -ModuleName Paths Get-KingshandPlatform { 'Windows' }
        $env:USERPROFILE = ''
        { Get-UserHomePath } | Should -Throw '*USERPROFILE*'
    }

    It 'throws naming HOME when Linux has none' {
        Mock -ModuleName Paths Get-KingshandPlatform { 'Linux' }
        $env:HOME = ''
        { Get-UserHomePath } | Should -Throw '*HOME environment variable is not set*'
    }
}

Describe 'Get-ClaudeGlobalConfigPath finds the file Claude Code keeps its trust in' {

    BeforeAll {
        $script:SavedConfigDir = $env:CLAUDE_CONFIG_DIR
        $script:SavedProfile = $env:USERPROFILE
        $script:SavedUnixHome = $env:HOME
    }
    AfterAll {
        $env:CLAUDE_CONFIG_DIR = $script:SavedConfigDir
        $env:USERPROFILE = $script:SavedProfile
        $env:HOME = $script:SavedUnixHome
    }
    BeforeEach {
        $env:CLAUDE_CONFIG_DIR = ''
        $env:USERPROFILE = Join-Path $TestDrive 'profile'
        $env:HOME = Join-Path $TestDrive 'home'
    }

    It 'is .claude.json in the home directory on <_>' -ForEach @('Windows', 'MacOS', 'Linux') {
        $p = $_
        Mock -ModuleName Paths Get-KingshandPlatform { $p }.GetNewClosure()
        $dir = if ($p -eq 'Windows') { 'profile' } else { 'home' }
        Get-ClaudeGlobalConfigPath | Should -Be (Join-Path $TestDrive $dir '.claude.json')
    }

    # Claude Code moves the file there on every system, so trust written anywhere else is trust it
    # never reads.
    It 'follows CLAUDE_CONFIG_DIR when it is set' {
        $env:CLAUDE_CONFIG_DIR = Join-Path $TestDrive 'elsewhere'
        Get-ClaudeGlobalConfigPath | Should -Be (Join-Path $TestDrive 'elsewhere' '.claude.json')
    }

    It 'throws rather than guessing when there is no home and no override' {
        Mock -ModuleName Paths Get-KingshandPlatform { 'Linux' }
        $env:HOME = ''
        { Get-ClaudeGlobalConfigPath } | Should -Throw '*HOME*'
    }
}

Describe 'Get-ExecutableName gives a program its file name on this system' {

    It 'adds .exe on Windows' {
        Mock -ModuleName Paths Get-KingshandPlatform { 'Windows' }
        Get-ExecutableName 'herdr' | Should -Be 'herdr.exe'
    }

    It 'adds nothing on <_>' -ForEach @('MacOS', 'Linux') {
        $p = $_
        Mock -ModuleName Paths Get-KingshandPlatform { $p }.GetNewClosure()
        Get-ExecutableName 'herdr' | Should -Be 'herdr'
    }
}

Describe 'Get-HerdrPlatformKey names the build herdr publishes for this machine' {

    It '<platform> on <arch> is <key>' -ForEach @(
        @{ platform = 'Windows'; arch = 'X64';   key = 'windows-x86_64' }
        @{ platform = 'Windows'; arch = 'Arm64'; key = 'windows-x86_64' }
        @{ platform = 'MacOS';   arch = 'Arm64'; key = 'macos-aarch64' }
        @{ platform = 'MacOS';   arch = 'X64';   key = 'macos-x86_64' }
        @{ platform = 'Linux';   arch = 'X64';   key = 'linux-x86_64' }
        @{ platform = 'Linux';   arch = 'Arm64'; key = 'linux-aarch64' }
    ) {
        $p = $platform; $a = $arch
        Mock -ModuleName Paths Get-KingshandPlatform { $p }.GetNewClosure()
        Mock -ModuleName Paths Get-KingshandArchitecture { $a }.GetNewClosure()
        Get-HerdrPlatformKey | Should -Be $key
    }

    It 'refuses an architecture herdr has no build for, naming it' {
        Mock -ModuleName Paths Get-KingshandPlatform { 'Linux' }
        Mock -ModuleName Paths Get-KingshandArchitecture { 'X86' }
        { Get-HerdrPlatformKey } | Should -Throw '*Linux on X86*'
    }
}

Describe 'Resolve-LaunchableCommand finds a copy this system can start' {

    BeforeAll { $script:SavedPathForLaunch = $env:PATH }
    AfterAll { $env:PATH = $script:SavedPathForLaunch }
    BeforeEach { $script:Dir = New-TempFixtureDir -Prefix 'launch-' }

    It 'returns null when PATH holds no copy' {
        $env:PATH = $script:Dir
        Resolve-LaunchableCommand -Name 'kh-launch-none' | Should -BeNullOrEmpty
    }

    It 'prefers .exe over .cmd on Windows' -Skip:(-not $IsWindows) {
        Set-Content -LiteralPath (Join-Path $script:Dir 'kh-tool.cmd') -Value '@echo off' -Encoding ascii
        Set-Content -LiteralPath (Join-Path $script:Dir 'kh-tool.exe') -Value 'stub' -Encoding utf8
        $env:PATH = $script:Dir
        Resolve-LaunchableCommand -Name 'kh-tool' | Should -Be (Join-Path $script:Dir 'kh-tool.exe')
    }

    It 'never returns a .ps1 on Windows, which a native caller cannot start' -Skip:(-not $IsWindows) {
        Set-Content -LiteralPath (Join-Path $script:Dir 'kh-tool.ps1') -Value '' -Encoding utf8
        $env:PATH = $script:Dir
        Resolve-LaunchableCommand -Name 'kh-tool' | Should -BeNullOrEmpty
    }

    # On macOS and Linux an extensionless shim with a shebang is exactly what npm installs, and it
    # launches fine - so the first executable PATH holds is the answer, whatever its name.
    It 'takes the first executable PATH holds on macOS and Linux' {
        $stub = New-LaunchableStub -Directory $script:Dir -Name 'kh-tool'
        $env:PATH = $script:Dir
        Mock -ModuleName Paths Get-KingshandPlatform { 'Linux' }
        Resolve-LaunchableCommand -Name 'kh-tool' | Should -Be $stub
    }

    It 'refuses an extensionless executable when the system is Windows' -Skip:($IsWindows) {
        $null = New-LaunchableStub -Directory $script:Dir -Name 'kh-tool'
        $env:PATH = $script:Dir
        Mock -ModuleName Paths Get-KingshandPlatform { 'Windows' }
        Resolve-LaunchableCommand -Name 'kh-tool' | Should -BeNullOrEmpty
    }

    It 'gives Get-ClaudeCommandPath the claude PATH holds on macOS and Linux' {
        $stub = New-LaunchableStub -Directory $script:Dir -Name 'claude'
        $env:PATH = $script:Dir
        Mock -ModuleName Paths Get-KingshandPlatform { 'MacOS' }
        Get-ClaudeCommandPath | Should -Be $stub
    }
}

Describe 'paths compare as paths, case-insensitively on Windows only' {

    BeforeAll { $script:R = Join-Path $TestDrive 'Data' }

    It 'Get-PathComparison ignores case on Windows and not on <_>' -ForEach @('MacOS', 'Linux') {
        $p = $_
        Mock -ModuleName Paths Get-KingshandPlatform { 'Windows' }
        Get-PathComparison | Should -Be ([StringComparison]::OrdinalIgnoreCase)
        Mock -ModuleName Paths Get-KingshandPlatform { $p }.GetNewClosure()
        Get-PathComparison | Should -Be ([StringComparison]::Ordinal)
    }

    It 'Get-PathComparer hands back a comparer that follows the same rule' {
        Mock -ModuleName Paths Get-KingshandPlatform { 'Windows' }
        $set = [System.Collections.Generic.HashSet[string]]::new((Get-PathComparer))
        $null = $set.Add('a\B')
        $set.Contains('A\b') | Should -BeTrue

        Mock -ModuleName Paths Get-KingshandPlatform { 'Linux' }
        $set = [System.Collections.Generic.HashSet[string]]::new((Get-PathComparer))
        $null = $set.Add('a/B')
        $set.Contains('A/b') | Should -BeFalse
    }

    It 'ConvertTo-NormalPath makes a path absolute and drops a trailing separator' {
        $sep = [IO.Path]::DirectorySeparatorChar
        ConvertTo-NormalPath ($script:R + $sep) | Should -Be $script:R
        ConvertTo-NormalPath (Join-Path $script:R 'x' '..') | Should -Be $script:R
    }

    It 'ConvertTo-NormalPath keeps a filesystem root whole' {
        $root = [IO.Path]::GetPathRoot($TestDrive)
        ConvertTo-NormalPath $root | Should -Be $root
    }

    It 'Test-SamePath ignores a trailing separator' {
        Test-SamePath ($script:R + [IO.Path]::DirectorySeparatorChar) $script:R | Should -BeTrue
    }

    It 'Test-SamePath treats paths differing only in case as the same on Windows' {
        Mock -ModuleName Paths Get-KingshandPlatform { 'Windows' }
        Test-SamePath $script:R $script:R.ToLowerInvariant() | Should -BeTrue
    }

    It 'Test-SamePath treats them as different on Linux' {
        Mock -ModuleName Paths Get-KingshandPlatform { 'Linux' }
        Test-SamePath $script:R $script:R.ToLowerInvariant() | Should -BeFalse
    }

    It 'Test-SamePath says no, rather than throwing, for <why>' -ForEach @(
        @{ why = 'an empty path'; a = '' }
        @{ why = 'a path that will not normalise'; a = "bad`0path" }
    ) {
        Test-SamePath $a $script:R | Should -BeFalse
    }

    It 'Test-PathWithin counts the root itself unless told not to' {
        Test-PathWithin -Path $script:R -Root $script:R | Should -BeTrue
        Test-PathWithin -Path $script:R -Root $script:R -ExcludeRoot | Should -BeFalse
    }

    It 'Test-PathWithin finds a file inside and refuses a sibling that only shares a prefix' {
        Test-PathWithin -Path (Join-Path $script:R 'sub' 'x.md') -Root $script:R | Should -BeTrue
        Test-PathWithin -Path (Join-Path $TestDrive 'Data2' 'x.md') -Root $script:R | Should -BeFalse
    }

    It 'Test-PathWithin works under a filesystem root' {
        $root = [IO.Path]::GetPathRoot($TestDrive)
        Test-PathWithin -Path $TestDrive -Root $root -ExcludeRoot | Should -BeTrue
    }

    It 'Test-PathWithin follows the case rule of the system' {
        $inner = Join-Path $script:R.ToLowerInvariant() 'x.md'
        Mock -ModuleName Paths Get-KingshandPlatform { 'Windows' }
        Test-PathWithin -Path $inner -Root $script:R | Should -BeTrue
        Mock -ModuleName Paths Get-KingshandPlatform { 'Linux' }
        Test-PathWithin -Path $inner -Root $script:R | Should -BeFalse
    }

    It 'Test-PathWithin says outside for an empty or unusable path' {
        Test-PathWithin -Path '' -Root $script:R | Should -BeFalse
        Test-PathWithin -Path "bad`0path" -Root $script:R | Should -BeFalse
    }
}
