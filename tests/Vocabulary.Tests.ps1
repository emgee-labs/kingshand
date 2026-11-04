# Nothing enforced kingshand's vocabulary, so every change was free to add a word the King had
# banned and only a deliberate pass ever took one out. This fails, naming the file, the line, the
# word and what to use instead, whenever a word on tests\banned-words.psd1 appears in tracked
# material. The list is the editable half and this file is the fixed half: adding a word never
# needs a change here.
#
# The rest of the file proves the guard against throwaway repositories, because a check that is
# green on a clean tree says nothing about whether it would have gone red.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Vocabulary.psm1') -Force

    $script:Root = Split-Path $PSScriptRoot -Parent
    $script:List = Join-Path $PSScriptRoot 'banned-words.psd1'
    $script:Scope = @('CLAUDE.md', 'README.md', 'bin', '.claude/skills', 'tests', 'docs')

    # A repository holding exactly the files given, all tracked unless named in -Untracked. Nothing
    # is committed: git grep searches what the index tracks.
    function New-FixtureRepo {
        param(
            [Parameter(Mandatory)][hashtable]$Files,
            [string[]]$Untracked = @()
        )
        $repo = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $repo | Out-Null
        & git -C $repo init -q
        foreach ($name in $Files.Keys) {
            $path = Join-Path $repo $name
            New-Item -ItemType Directory -Path (Split-Path $path -Parent) -Force | Out-Null
            Set-Content -LiteralPath $path -Value $Files[$name] -Encoding utf8
            if ($name -notin $Untracked) { & git -C $repo -c core.autocrlf=false add -- $name }
        }
        $repo
    }

    function New-FixtureList {
        param([Parameter(Mandatory)][string]$Repo, [Parameter(Mandatory)][string]$Body,
              [string]$Name = 'tests/banned-words.psd1')
        $path = Join-Path $Repo $Name
        New-Item -ItemType Directory -Path (Split-Path $path -Parent) -Force | Out-Null
        Set-Content -LiteralPath $path -Value $Body -Encoding utf8
        & git -C $Repo -c core.autocrlf=false add -- $Name
        $path
    }

    $script:ZorkList = @'
@{
    Banned = @(
        @{ Word = 'zork'; Use = 'quandle'; Reason = 'a made-up word for the test' }
    )
}
'@
}

Describe 'no banned word appears in tracked material' {
    It 'the shipped list reads cleanly' {
        { Read-BannedWordList -Path $script:List } | Should -Not -Throw
    }

    It 'finds no word from the list in CLAUDE.md, README.md, bin, skills, tests or docs' {
        { Assert-NoBannedVocabulary -Root $script:Root -ListPath $script:List -Pathspec $script:Scope } |
            Should -Not -Throw
    }
}

Describe 'the guard goes red when it should' {
    It 'fails naming the file, the line, the word and what to use instead' {
        $repo = New-FixtureRepo -Files @{ 'docs/note.md' = @('a clean line', 'the zork came back') }
        $list = New-FixtureList -Repo $repo -Body $script:ZorkList

        { Assert-NoBannedVocabulary -Root $repo -ListPath $list -Pathspec @('docs') } |
            Should -Throw -ExpectedMessage "*docs/note.md:2: 'zork' - use 'quandle' instead (a made-up word for the test)*"
    }

    It 'matches whole words in any case, and never inside a longer word' {
        $repo = New-FixtureRepo -Files @{ 'docs/a.md' = @('Zork', 'zorkland and unzorked', 'a ZORK here') }
        $list = New-FixtureList -Repo $repo -Body $script:ZorkList

        $found = @(Find-BannedVocabulary -Root $repo -ListPath $list -Pathspec @('docs'))
        @($found.Line) | Should -Be @(1, 3)
    }

    It 'does not read mate into material or estimate' {
        $repo = New-FixtureRepo -Files @{ 'docs/a.md' = @('material', 'an estimate', 'a mate') }
        $list = New-FixtureList -Repo $repo -Body @'
@{ Banned = @( @{ Word = 'mate'; Use = 'peer'; Reason = 'test' } ) }
'@
        @((Find-BannedVocabulary -Root $repo -ListPath $list -Pathspec @('docs')).Line) | Should -Be @(3)
    }

    It 'reads only tracked files, and only under the paths it is given' {
        $repo = New-FixtureRepo -Files @{
            'docs/tracked.md'   = 'zork'
            'docs/untracked.md' = 'zork'
            'other/outside.md'  = 'zork'
        } -Untracked 'docs/untracked.md'
        $list = New-FixtureList -Repo $repo -Body $script:ZorkList

        @((Find-BannedVocabulary -Root $repo -ListPath $list -Pathspec @('docs')).File) |
            Should -Be @('docs/tracked.md')
    }

    It 'never scans the file holding the list' {
        $repo = New-FixtureRepo -Files @{ 'docs/a.md' = 'clean' }
        $list = New-FixtureList -Repo $repo -Body $script:ZorkList

        @(Find-BannedVocabulary -Root $repo -ListPath $list -Pathspec @('tests', 'docs')) | Should -BeNullOrEmpty
    }

    It 'finds nothing and asks git nothing when the list is empty' {
        $repo = Join-Path $TestDrive 'not-a-repo-empty'
        New-Item -ItemType Directory -Path $repo | Out-Null
        $list = Join-Path $repo 'list.psd1'
        Set-Content -LiteralPath $list -Value '@{ Banned = @() }'

        @(Find-BannedVocabulary -Root $repo -ListPath $list -Pathspec @('docs')) | Should -BeNullOrEmpty
    }
}

Describe 'exceptions are literal, and exempt only what they name' {
    It 'an exact phrase exempts the word inside it and nowhere else' {
        $repo = New-FixtureRepo -Files @{ 'docs/a.md' = @(
            'tasks-axi hold x --kind captain',
            'the captain decides',
            '--KIND CAPTAIN then a captain'
        ) }
        $list = New-FixtureList -Repo $repo -Body @'
@{
    Banned = @( @{ Word = 'captain'; Use = 'King'; Reason = 'test' } )
    Allow  = @( @{ Word = 'captain'; Phrase = '--kind captain'; Reason = 'external schema' } )
}
'@
        @((Find-BannedVocabulary -Root $repo -ListPath $list -Pathspec @('docs')).Line) | Should -Be @(2, 3)
    }

    It 'a phrase holding the word inside a longer phrase still exempts it' {
        $repo = New-FixtureRepo -Files @{ 'docs/a.md' = @('an anchor point here', 'drop anchor') }
        $list = New-FixtureList -Repo $repo -Body @'
@{
    Banned = @( @{ Word = 'anchor'; Use = 'hold'; Reason = 'test' } )
    Allow  = @( @{ Word = 'anchor'; Phrase = 'anchor point'; Reason = 'not naval' } )
}
'@
        @((Find-BannedVocabulary -Root $repo -ListPath $list -Pathspec @('docs')).Line) | Should -Be @(2)
    }

    It 'a file exemption covers its own word in that file and no other word' {
        $repo = New-FixtureRepo -Files @{
            'README.md'  = @('credit to firstmate', 'a zork')
            'docs/a.md'  = 'firstmate'
        }
        $list = New-FixtureList -Repo $repo -Body @'
@{
    Banned = @(
        @{ Word = 'firstmate'; Use = 'Hand'; Reason = 'test' }
        @{ Word = 'zork'; Use = 'quandle'; Reason = 'test' }
    )
    Allow  = @( @{ Word = 'firstmate'; File = 'README.md'; Reason = 'attribution' } )
}
'@
        $found = @(Find-BannedVocabulary -Root $repo -ListPath $list -Pathspec @('README.md', 'docs'))
        @($found | ForEach-Object { "$($_.File):$($_.Word)" }) | Sort-Object |
            Should -Be @('docs/a.md:firstmate', 'README.md:zork')
    }
}

Describe 'the guard stops safely and names what failed' {
    BeforeAll {
        $script:BadDir = Join-Path $TestDrive 'bad-lists'
        New-Item -ItemType Directory -Path $script:BadDir | Out-Null
        function New-BadList([string]$Body) {
            $path = Join-Path $script:BadDir "$([guid]::NewGuid().ToString('N')).psd1"
            Set-Content -LiteralPath $path -Value $Body
            $path
        }
    }

    It 'refuses a list that does not exist' {
        { Read-BannedWordList -Path (Join-Path $script:BadDir 'missing.psd1') } |
            Should -Throw -ExpectedMessage '*does not exist*'
    }

    It 'refuses a list that does not parse' {
        { Read-BannedWordList -Path (New-BadList '@{ Banned = @( ') } |
            Should -Throw -ExpectedMessage '*could not be read*'
    }

    It 'refuses <Case>' -ForEach @(
        @{ Case = 'an unknown key';             Body = '@{ Baned = @() }';                                                      Expect = "*unknown key 'Baned'*" }
        @{ Case = 'an entry with no Use';       Body = "@{ Banned = @( @{ Word = 'zork'; Reason = 'r' } ) }";                   Expect = '*has no Use*' }
        @{ Case = 'an entry with no Reason';    Body = "@{ Banned = @( @{ Word = 'zork'; Use = 'u' } ) }";                      Expect = '*has no Reason*' }
        @{ Case = 'a word with a space';        Body = "@{ Banned = @( @{ Word = 'zo rk'; Use = 'u'; Reason = 'r' } ) }";       Expect = '*is not one word*' }
        @{ Case = 'a word listed twice';        Body = "@{ Banned = @( @{ Word = 'zork'; Use = 'u'; Reason = 'r' }; @{ Word = 'ZORK'; Use = 'u'; Reason = 'r' } ) }"; Expect = '*appears twice*' }
        @{ Case = 'an entry that is not a table'; Body = "@{ Banned = @( 'zork' ) }";                                           Expect = '*not a @{ ... } entry*' }
        @{ Case = 'an exception naming both a file and a phrase'; Body = "@{ Allow = @( @{ Word = 'zork'; File = 'a.md'; Phrase = 'a zork'; Reason = 'r' } ) }"; Expect = '*exactly one of File or Phrase*' }
        @{ Case = 'an exception naming neither'; Body = "@{ Allow = @( @{ Word = 'zork'; Reason = 'r' } ) }";                   Expect = '*exactly one of File or Phrase*' }
        @{ Case = 'an exception with no Reason'; Body = "@{ Allow = @( @{ Word = 'zork'; File = 'a.md' } ) }";                  Expect = '*has no Reason*' }
        @{ Case = 'a phrase that does not hold its word'; Body = "@{ Allow = @( @{ Word = 'zork'; Phrase = 'other'; Reason = 'r' } ) }"; Expect = '*can never apply*' }
    ) {
        { Read-BannedWordList -Path (New-BadList $Body) } | Should -Throw -ExpectedMessage $Expect
    }

    It 'reports a git grep that fails rather than reading it as a clean tree' {
        $dir = Join-Path $TestDrive 'not-a-repo'
        New-Item -ItemType Directory -Path $dir | Out-Null
        $list = Join-Path $dir 'list.psd1'
        Set-Content -LiteralPath $list -Value $script:ZorkList

        { Find-BannedVocabulary -Root $dir -ListPath $list -Pathspec @('docs') } |
            Should -Throw -ExpectedMessage "*git grep for 'zork'*failed*"
    }
}
