# kingshand's rules are prose, and when one moved nothing found the places that pointed at it. A
# rule that anything else points at now carries a rule id where it is owned, and every pointer
# cites that id, so this fails - naming the file and the line - when a citation names an id nobody
# declares, an id is declared twice or outside its owner's file, a declared id has nothing outside
# its own file citing it, or something opens like an id and is not a whole one. Moving or deleting
# a rule then breaks here at each place that pointed at it. statute's "Rule ids" section owns the
# grammar; tests\rule-ids.psd1 holds the literal exceptions.
#
# The rest of the file proves the check against throwaway repositories, because a check that is
# green on a clean tree says nothing about whether it would have gone red.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'RuleIds.psm1') -Force

    $script:Root = Split-Path $PSScriptRoot -Parent
    $script:List = Join-Path $PSScriptRoot 'rule-ids.psd1'
    $script:Scope = @(':(glob)**/*.md')

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
        param([Parameter(Mandatory)][string]$Repo, [string]$Body = '@{ Uncited = @(); NotAnId = @() }')
        $path = Join-Path $Repo 'rule-ids.psd1'
        Set-Content -LiteralPath $path -Value $Body -Encoding utf8
        $path
    }

    function Find-Fixture {
        param([Parameter(Mandatory)][hashtable]$Files, [string]$Body, [string[]]$Untracked = @())
        $repo = New-FixtureRepo -Files $Files -Untracked $Untracked
        $list = if ($Body) { New-FixtureList -Repo $repo -Body $Body } else { New-FixtureList -Repo $repo }
        $found = Find-RuleIdProblem -Root $repo -ListPath $list -Pathspec @(':(glob)**/*.md')
        , $found
    }

    $script:Owner = '.claude/skills/zork/SKILL.md'
}

Describe 'every rule id in tracked Markdown resolves' {
    It 'the shipped list reads cleanly' {
        { Read-RuleIdList -Path $script:List } | Should -Not -Throw
    }

    It 'finds no unresolved, duplicated, misplaced, uncited or malformed rule id' {
        { Assert-RuleIdsResolve -Root $script:Root -ListPath $script:List -Pathspec $script:Scope } |
            Should -Not -Throw
    }
}

Describe 'the check goes red when it should' {
    It 'is clean when a declared id is cited from another file' {
        $found = Find-Fixture -Files @{
            $script:Owner = @('## Rule', '<!-- rule:zork/the-rule -->', 'Say it once.')
            'CLAUDE.md'   = 'Point at it [rule:zork/the-rule].'
        }
        $found.Count | Should -Be 0
    }

    It 'fails naming the file and line of a citation nobody declares' {
        $repo = New-FixtureRepo -Files @{ 'CLAUDE.md' = @('clean', 'see [rule:zork/gone]') }
        $list = New-FixtureList -Repo $repo
        { Assert-RuleIdsResolve -Root $repo -ListPath $list -Pathspec @(':(glob)**/*.md') } |
            Should -Throw -ExpectedMessage '*CLAUDE.md:2: `[rule:zork/gone`] cites a rule id nobody declares*'
    }

    It 'fails an id declared twice, naming the first declaration' {
        $found = Find-Fixture -Files @{
            $script:Owner = @('<!-- rule:zork/twice -->', 'text', '<!-- rule:zork/twice -->')
            'CLAUDE.md'   = '[rule:zork/twice]'
        }
        @($found | Where-Object Kind -eq 'Duplicate').Count | Should -Be 1
        ($found | Where-Object Kind -eq 'Duplicate').Message |
            Should -BeLike "*SKILL.md:3: rule id 'zork/twice' is declared again*SKILL.md:1*"
    }

    It 'fails an id declared outside the file its owner names' {
        $found = Find-Fixture -Files @{
            'docs/2026-01-01-note.md' = '<!-- rule:zork/moved -->'
            'CLAUDE.md'               = '[rule:zork/moved]'
        }
        $found.Kind | Should -Be 'WrongOwner'
        $found.Message | Should -BeLike "*docs/2026-01-01-note.md:1:*declared in '.claude/skills/zork/SKILL.md'*"
    }

    It 'maps <Owner> to <File>' -ForEach @(
        @{ Owner = 'claude';                File = 'CLAUDE.md' }
        @{ Owner = '2026-01-01-some-note';  File = 'docs/2026-01-01-some-note.md' }
        @{ Owner = 'zork';                  File = '.claude/skills/zork/SKILL.md' }
    ) {
        $found = Find-Fixture -Files @{
            $File       = "<!-- rule:$Owner/x -->"
            'README.md' = "[rule:$Owner/x]"
        }
        $found.Count | Should -Be 0
    }

    It 'fails a declared id that nothing outside its own file cites' {
        $found = Find-Fixture -Files @{ $script:Owner = @('<!-- rule:zork/alone -->', 'see [rule:zork/alone]') }
        $found.Kind | Should -Be 'Uncited'
        $found.Message | Should -BeLike "*SKILL.md:1: rule id 'zork/alone' is declared but nothing outside its own file cites it*"
    }

    It 'lets a listed uncited id through' {
        $found = Find-Fixture -Files @{ $script:Owner = '<!-- rule:zork/alone -->' } -Body @'
@{ Uncited = @( @{ Id = 'zork/alone'; Reason = 'owned, not pointed at yet' } ) }
'@
        $found.Count | Should -Be 0
    }

    It 'fails a listed uncited id that is cited after all' {
        $found = Find-Fixture -Files @{
            $script:Owner = '<!-- rule:zork/alone -->'
            'CLAUDE.md'   = '[rule:zork/alone]'
        } -Body @'
@{ Uncited = @( @{ Id = 'zork/alone'; Reason = 'r' } ) }
'@
        $found.Kind | Should -Be 'StaleList'
        $found.Message | Should -BeLike '*is cited now*'
    }

    It 'fails a listed uncited id that nothing declares' {
        $found = Find-Fixture -Files @{ 'CLAUDE.md' = 'clean' } -Body @'
@{ Uncited = @( @{ Id = 'zork/gone'; Reason = 'r' } ) }
'@
        $found.Kind | Should -Be 'StaleList'
        $found.Message | Should -BeLike '*nothing declares it*'
    }

    It 'fails <Case> as malformed' -ForEach @(
        @{ Case = 'an upper-case citation';        Text = 'see [rule:Zork/x]' }
        @{ Case = 'a citation with a space';       Text = 'see [rule: zork/x]' }
        @{ Case = 'a citation with no owner';      Text = 'see [rule:x]' }
        @{ Case = 'a declaration with no spaces';  Text = '<!--rule:zork/x-->and <!-- rule:zork/x' }
        @{ Case = 'a second, broken form beside a whole one'; Text = '[rule:zork/x] and [rule:zork/x' }
    ) {
        $found = Find-Fixture -Files @{
            $script:Owner = '<!-- rule:zork/x -->'
            'CLAUDE.md'   = @('[rule:zork/x]', $Text)
        }
        @($found | Where-Object { $_.Kind -eq 'Malformed' -and $_.Line -eq 2 }).Count | Should -Be 1
    }

    It 'masks a listed phrase only in the file it names' {
        $found = Find-Fixture -Files @{
            'docs/a.md' = 'written as [rule:<owner>/<name>] here'
            'docs/b.md' = 'written as [rule:<owner>/<name>] here'
        } -Body @'
@{ NotAnId = @( @{ File = 'docs/a.md'; Phrase = '[rule:<owner>/<name>]'; Reason = 'the grammar' } ) }
'@
        @($found.File) | Should -Be @('docs/b.md')
        $found.Kind | Should -Be 'Malformed'
    }

    It 'reads only tracked files, and only under the paths it is given' {
        $found = Find-Fixture -Files @{
            'docs/tracked.md'   = '[rule:zork/none]'
            'docs/untracked.md' = '[rule:zork/none]'
            'other/outside.txt' = '[rule:zork/none]'
        } -Untracked 'docs/untracked.md'
        @($found.File) | Should -Be @('docs/tracked.md')
    }
}

Describe 'the check stops safely and names what failed' {
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
        { Read-RuleIdList -Path (Join-Path $script:BadDir 'missing.psd1') } |
            Should -Throw -ExpectedMessage '*does not exist*'
    }

    It 'refuses a list that does not parse' {
        { Read-RuleIdList -Path (New-BadList '@{ Uncited = @( ') } |
            Should -Throw -ExpectedMessage '*could not be read*'
    }

    It 'refuses <Case>' -ForEach @(
        @{ Case = 'an unknown key';                 Body = '@{ Uncite = @() }';                                         Expect = "*unknown key 'Uncite'*" }
        @{ Case = 'an uncited entry with no Reason'; Body = "@{ Uncited = @( @{ Id = 'zork/x' } ) }";                    Expect = '*has no Reason*' }
        @{ Case = 'an uncited id out of grammar';   Body = "@{ Uncited = @( @{ Id = 'Zork/x'; Reason = 'r' } ) }";      Expect = '*is not a rule id*' }
        @{ Case = 'an uncited id listed twice';     Body = "@{ Uncited = @( @{ Id = 'zork/x'; Reason = 'r' }; @{ Id = 'zork/x'; Reason = 'r' } ) }"; Expect = '*appears twice*' }
        @{ Case = 'an entry that is not a table';   Body = "@{ Uncited = @( 'zork/x' ) }";                              Expect = '*not a @{ ... } entry*' }
        @{ Case = 'a phrase with no File';          Body = "@{ NotAnId = @( @{ Phrase = '[rule:x'; Reason = 'r' } ) }"; Expect = '*has no File*' }
        @{ Case = 'a phrase that opens no id';      Body = "@{ NotAnId = @( @{ File = 'a.md'; Phrase = 'other'; Reason = 'r' } ) }"; Expect = '*can never apply*' }
    ) {
        { Read-RuleIdList -Path (New-BadList $Body) } | Should -Throw -ExpectedMessage $Expect
    }

    It 'reports a git grep that fails rather than reading it as a clean tree' {
        $dir = Join-Path $TestDrive 'not-a-repo'
        New-Item -ItemType Directory -Path $dir | Out-Null
        $list = Join-Path $dir 'list.psd1'
        Set-Content -LiteralPath $list -Value '@{}'

        { Find-RuleIdProblem -Root $dir -ListPath $list -Pathspec @(':(glob)**/*.md') } |
            Should -Throw -ExpectedMessage '*git grep for rule-id declarations*failed*'
    }
}
