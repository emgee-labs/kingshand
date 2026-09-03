#Requires -Version 7.0
Set-StrictMode -Version Latest

# bin\Version.psm1 is the only reader of the VERSION file, and everything that reports a version
# reports what it returns. So the cases that matter here are the ones where there is no version to
# return: absent, empty, more than one line, and content that is not a version. Each has to name
# its own failure and none of them may hand back a number, because a fabricated version is quoted
# straight back by whoever reads it as the one they are running.
#
# The shipped VERSION file is read once, deliberately. It is the one file in this repository whose
# content IS the contract, and a release cut from a copy that does not parse would report itself as
# unreadable to every user who updated to it.

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $script:Root 'bin\Version.psm1') -Force

    function New-VersionFixture {
        param([Parameter(Mandatory)][string]$Name)
        $d = Join-Path $TestDrive $Name
        New-Item -ItemType Directory -Force -Path $d | Out-Null
        $d
    }

    # A throwaway git repository, so the ref reader can be exercised without touching this
    # installation - the same reason bin\Resolve-BaseRef.ps1 is testable on its own.
    function New-VersionRepo {
        param([Parameter(Mandatory)][string]$Name)
        $d = New-VersionFixture -Name $Name
        git init -b main $d -q
        git -C $d config user.name  'Test'
        git -C $d config user.email 'test@example.invalid'
        $d
    }

    function Add-Commit {
        param(
            [Parameter(Mandatory)][string]$RepoPath,
            [Parameter(Mandatory)][string]$Message
        )
        git -C $RepoPath add -A
        git -C $RepoPath commit -q -m $Message
    }
}

Describe 'the VERSION file lives at the root and is named in one place' {
    It 'hangs VERSION off the root it is given' {
        Get-VersionFilePath -Root 'C:\somewhere\kingshand' |
            Should -Be 'C:\somewhere\kingshand\VERSION'
    }

    It 'this repository ships a VERSION file that parses' {
        $v = Get-KingshandVersion -Path (Get-VersionFilePath -Root $script:Root)
        $v | Should -Match '^\d+\.\d+\.\d+'
    }
}

Describe 'a version that can be read is returned exactly' {
    It 'reads the version, trailing newline and all' {
        $d = New-VersionFixture -Name 'plain'
        Set-Content -LiteralPath (Join-Path $d 'VERSION') -Value "0.1.0" -Encoding utf8
        Get-KingshandVersion -Path (Join-Path $d 'VERSION') | Should -Be '0.1.0'
    }

    It 'accepts a pre-release suffix' {
        $d = New-VersionFixture -Name 'prerelease'
        Set-Content -LiteralPath (Join-Path $d 'VERSION') -Value "1.2.3-rc.1" -Encoding utf8
        Get-KingshandVersion -Path (Join-Path $d 'VERSION') | Should -Be '1.2.3-rc.1'
    }
}

Describe 'every unreadable VERSION names its own failure and returns no version' {
    It 'says there is no file, rather than defaulting' {
        $missing = Join-Path (New-VersionFixture -Name 'absent') 'VERSION'
        { Get-KingshandVersion -Path $missing } |
            Should -Throw -ExpectedMessage "*There is no VERSION file at*"
    }

    It 'says an empty file holds no version' {
        $d = New-VersionFixture -Name 'empty'
        Set-Content -LiteralPath (Join-Path $d 'VERSION') -Value '' -Encoding utf8
        { Get-KingshandVersion -Path (Join-Path $d 'VERSION') } |
            Should -Throw -ExpectedMessage "*holds no version*"
    }

    It 'refuses a file with a second line in it' {
        $d = New-VersionFixture -Name 'twolines'
        Set-Content -LiteralPath (Join-Path $d 'VERSION') -Value @('0.1.0', 'and a note') -Encoding utf8
        { Get-KingshandVersion -Path (Join-Path $d 'VERSION') } |
            Should -Throw -ExpectedMessage "*holds more than one line*"
    }

    It 'refuses content that is not a version, and quotes it back' {
        $d = New-VersionFixture -Name 'prose'
        Set-Content -LiteralPath (Join-Path $d 'VERSION') -Value 'the next one, probably' -Encoding utf8
        { Get-KingshandVersion -Path (Join-Path $d 'VERSION') } |
            Should -Throw -ExpectedMessage "*does not hold a version: 'the next one, probably'*"
    }

    It 'refuses a v prefix, which belongs on the tag and not in the file' {
        $d = New-VersionFixture -Name 'vprefix'
        Set-Content -LiteralPath (Join-Path $d 'VERSION') -Value 'v0.1.0' -Encoding utf8
        { Get-KingshandVersion -Path (Join-Path $d 'VERSION') } |
            Should -Throw -ExpectedMessage "*does not hold a version*"
    }
}

Describe 'the version a release holds is read out of that release' {
    BeforeAll {
        $script:Repo = New-VersionRepo -Name 'refs'
        Set-Content -LiteralPath (Join-Path $script:Repo 'VERSION') -Value '0.1.0' -Encoding utf8
        Add-Commit -RepoPath $script:Repo -Message 'Seed the repository'
        git -C $script:Repo tag 'v0.1.0'

        Set-Content -LiteralPath (Join-Path $script:Repo 'VERSION') -Value '0.2.0' -Encoding utf8
        Add-Commit -RepoPath $script:Repo -Message 'Move to the next version'
        git -C $script:Repo tag 'v0.2.0'
    }

    It 'reads the older release out of its own tag, not off the checkout' {
        Get-KingshandVersionAtRef -RepoPath $script:Repo -Ref 'v0.1.0' | Should -Be '0.1.0'
    }

    It 'reads the newer release' {
        Get-KingshandVersionAtRef -RepoPath $script:Repo -Ref 'v0.2.0' | Should -Be '0.2.0'
    }

    It 'refuses a release that carries no VERSION file at all' {
        $bare = New-VersionRepo -Name 'noversionfile'
        Set-Content -LiteralPath (Join-Path $bare 'README.md') -Value 'no version here' -Encoding utf8
        Add-Commit -RepoPath $bare -Message 'Seed without a version'
        git -C $bare tag 'v9.9.9'

        { Get-KingshandVersionAtRef -RepoPath $bare -Ref 'v9.9.9' } |
            Should -Throw -ExpectedMessage "*has no readable VERSION file*"
    }

    It 'refuses a ref that does not exist' {
        { Get-KingshandVersionAtRef -RepoPath $script:Repo -Ref 'v4.0.0' } |
            Should -Throw -ExpectedMessage "*has no readable VERSION file*"
    }
}
