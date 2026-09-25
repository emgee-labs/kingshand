# Every case here runs against a throwaway fixture tree under $TestDrive. Nothing in this file
# reads or writes $env:KINGSHAND_HOME\state or \data - a real away period is the King's own record,
# and a test that opened a journal there would write into it.
#
# The subject is the failure the journal exists to remove: an away period whose account was lost
# with the session that held it. So the cases that matter most are the negative ones - an
# unreadable journal must read as unreadable, never as a clean empty night.

BeforeAll {
    Import-Module "$PSScriptRoot\..\bin\AwayJournal.psm1" -Force

    $script:SinceA = '2026-09-25T00:59:24.1234567Z'
    $script:SinceB = '2026-09-26T21:03:05.7654321Z'
    $script:StampA = '20260925T005924Z'
    $script:StampB = '20260926T210305Z'

    # One fixture: a data directory, a state directory, and whatever away flag the case needs.
    function New-AwayFixture {
        param([string]$Since = $script:SinceA, [string]$Note = 'overnight', [switch]$NoFlag)

        $root  = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $data  = Join-Path $root 'data'
        $state = Join-Path $root 'state'
        New-Item -ItemType Directory -Force -Path $data, $state | Out-Null

        $flag = Join-Path $state '.afk'
        if (-not $NoFlag) {
            Set-Content -LiteralPath $flag -Encoding utf8 -Value (@("since: $Since", "note: $Note") -join "`n")
        }
        @{ Root = $root; Data = $data; State = $state; Flag = $flag }
    }

    # A flag written with content this module did not choose, for the cases that have to survive one.
    function Set-RawFlag {
        param([Parameter(Mandatory)]$Fixture, [Parameter(Mandatory)][AllowEmptyString()][string]$Content)
        [System.IO.File]::WriteAllText($Fixture.Flag, $Content)
    }

    function Add-FixtureEntry {
        param([Parameter(Mandatory)]$Fixture, [Parameter(Mandatory)][hashtable]$Entry)
        Write-AwayJournalEntry @Entry -FlagPath $Fixture.Flag -DataPath $Fixture.Data
    }

    function Get-FixtureDigest {
        param([Parameter(Mandatory)]$Fixture)
        Get-AwayDigest -FlagPath $Fixture.Flag -DataPath $Fixture.Data
    }

    function Get-FixtureJournalPath {
        param([Parameter(Mandatory)]$Fixture)
        (Get-AwayFlag -FlagPath $Fixture.Flag -DataPath $Fixture.Data).journalPath
    }
}

Describe 'Get-AwayFlag reports the flag without ever throwing' {
    It 'reports no regency when the flag is absent, and calls that a state rather than a fault' {
        $f = New-AwayFixture -NoFlag
        $r = $null
        { $script:r = Get-AwayFlag -FlagPath $f.Flag -DataPath $f.Data } | Should -Not -Throw
        $script:r.present | Should -BeFalse
        $script:r.problem | Should -BeNullOrEmpty
        $script:r.since   | Should -BeNullOrEmpty
    }

    It 'reads the since value verbatim and names the journal it belongs to' {
        $f = New-AwayFixture
        $r = Get-AwayFlag -FlagPath $f.Flag -DataPath $f.Data
        $r.present     | Should -BeTrue
        $r.since       | Should -Be $script:SinceA
        $r.stamp       | Should -Be $script:StampA
        $r.journalPath | Should -Be (Join-Path $f.Data "away\$script:StampA.jsonl")
    }

    It 'reads the since line whichever line it is on and whatever the line endings are' {
        $f = New-AwayFixture
        Set-RawFlag -Fixture $f -Content "note: back in an hour`r`nsince: $script:SinceA`r`n"
        (Get-AwayFlag -FlagPath $f.Flag -DataPath $f.Data).since | Should -Be $script:SinceA
    }

    # Fail-closed, and this is the one that matters: a flag nobody can read must not resolve to a
    # plausible-looking journal name. A guessed stamp is a journal pointing at the wrong period.
    It 'reports a <case> flag as a problem and produces no stamp at all' -ForEach @(
        @{ case = 'since-less';     content = "note: overnight`n" }
        @{ case = 'empty';          content = '' }
        @{ case = 'blank-since';    content = "since:`nnote: overnight`n" }
        @{ case = 'unparseable';    content = "since: whenever`n" }
    ) {
        $f = New-AwayFixture
        Set-RawFlag -Fixture $f -Content $content
        $r = $null
        { $script:r = Get-AwayFlag -FlagPath $f.Flag -DataPath $f.Data } | Should -Not -Throw
        $script:r.present     | Should -BeTrue -Because 'the King is still away even when the flag is malformed'
        $script:r.problem     | Should -Not -BeNullOrEmpty
        $script:r.stamp       | Should -BeNullOrEmpty
        $script:r.journalPath | Should -BeNullOrEmpty
    }

    It 'names the flag file in the problem so the message is actionable' {
        $f = New-AwayFixture
        Set-RawFlag -Fixture $f -Content "note: overnight`n"
        (Get-AwayFlag -FlagPath $f.Flag -DataPath $f.Data).problem.Contains($f.Flag) |
            Should -BeTrue -Because 'the Hand has to be told which file to fix'
    }
}

Describe 'Open-AwayJournal opens one journal per away period' {
    It 'creates the file, its header, and an index entry for it' {
        $f = New-AwayFixture
        $o = Open-AwayJournal -FlagPath $f.Flag -DataPath $f.Data

        $o.created | Should -BeTrue
        $o.since   | Should -Be $script:SinceA
        $o.path    | Should -Be (Join-Path $f.Data "away\$script:StampA.jsonl")
        Test-Path -LiteralPath $o.path -PathType Leaf | Should -BeTrue

        $o.indexed      | Should -BeTrue
        $o.indexProblem | Should -BeNullOrEmpty
        (Get-Content -LiteralPath (Join-Path $f.Data 'index.md') -Raw).Contains("away\$script:StampA.jsonl") |
            Should -BeTrue -Because 'a durable file under data\ that no index lists is drift'
    }

    # R-007's restart half. A fresh session mid-period reads the same since: and must land on the
    # same file with the existing records untouched.
    It 'reopens the same file mid-period and keeps what is already recorded' {
        $f = New-AwayFixture
        $first = Open-AwayJournal -FlagPath $f.Flag -DataPath $f.Data
        Add-FixtureEntry -Fixture $f -Entry @{ Kind = 'landed'; Text = 'T-1001 merged' } | Out-Null

        $second = Open-AwayJournal -FlagPath $f.Flag -DataPath $f.Data
        $second.path    | Should -Be $first.path
        $second.created | Should -BeFalse

        $d = Get-FixtureDigest $f
        $d.count | Should -Be 1 -Because 'reopening appends to the period, it does not start it over'
    }

    # R-007's other half. Two periods, two names, and the first file is never touched again.
    It 'gives a second away period its own file and leaves the first one alone' {
        $f = New-AwayFixture
        Add-FixtureEntry -Fixture $f -Entry @{ Kind = 'landed'; Text = 'first period' } | Out-Null
        $firstPath = (Get-FixtureJournalPath $f)
        $firstText = [System.IO.File]::ReadAllText($firstPath)

        Set-Content -LiteralPath $f.Flag -Encoding utf8 -Value "since: $script:SinceB"
        Add-FixtureEntry -Fixture $f -Entry @{ Kind = 'landed'; Text = 'second period' } | Out-Null
        $secondPath = (Get-FixtureJournalPath $f)

        $secondPath | Should -Not -Be $firstPath
        $secondPath | Should -Be (Join-Path $f.Data "away\$script:StampB.jsonl")
        [System.IO.File]::ReadAllText($firstPath) |
            Should -BeExactly $firstText -Because 'one away period may never overwrite another'
    }

    # The period check has to compare instants, not bytes. The header's since: goes out as text and
    # comes back from ConvertFrom-Json as a DateTime that re-renders with seven fraction digits, so
    # a flag holding any other spelling of the same moment - `2026-09-25T00:59:24Z`, which is what
    # the session-start digest prints - failed the check and the period recorded exactly one line.
    It 'keeps appending when the flag spells the same instant with <case>' -ForEach @(
        @{ case = 'no fractional seconds'; since = '2026-09-25T00:59:24Z' }
        @{ case = 'three fraction digits'; since = '2026-09-25T00:59:24.100Z' }
        @{ case = 'a UTC offset';          since = '2026-09-25T02:59:24+02:00' }
    ) {
        $f = New-AwayFixture -Since $since
        Add-FixtureEntry -Fixture $f -Entry @{ Kind = 'landed'; Text = 'T-1' } | Out-Null
        { Add-FixtureEntry -Fixture $f -Entry @{ Kind = 'landed'; Text = 'T-2' } } |
            Should -Not -Throw -Because 'one instant spelled two ways is still one away period'

        $d = Get-FixtureDigest $f
        $d.readable | Should -BeTrue -Because 'an intact journal must never be reported unreadable'
        $d.count    | Should -Be 2
        @($d.entries | ForEach-Object { $_.text }) | Should -Be @('T-1', 'T-2')
    }

    # An index write that failed once would otherwise never be retried, leaving the journal in the
    # session-start unindexed count for good.
    It 'puts the journal back in the index when the entry went missing' {
        $f = New-AwayFixture
        Open-AwayJournal -FlagPath $f.Flag -DataPath $f.Data | Out-Null
        Remove-Item -LiteralPath (Join-Path $f.Data 'index.md') -Force

        $second = Open-AwayJournal -FlagPath $f.Flag -DataPath $f.Data
        $second.created      | Should -BeFalse
        $second.indexed      | Should -BeTrue
        $second.indexProblem | Should -BeNullOrEmpty
        (Get-Content -LiteralPath (Join-Path $f.Data 'index.md') -Raw).Contains("away\$script:StampA.jsonl") |
            Should -BeTrue
    }

    It 'refuses to open a journal when no regency is in force' {
        $f = New-AwayFixture -NoFlag
        { Open-AwayJournal -FlagPath $f.Flag -DataPath $f.Data } | Should -Throw '*No regency is in force*'
    }

    It 'refuses a flag whose since is not a timestamp rather than naming a file after it' {
        $f = New-AwayFixture
        Set-RawFlag -Fixture $f -Content "since: last tuesday`n"
        { Open-AwayJournal -FlagPath $f.Flag -DataPath $f.Data } | Should -Throw '*not a timestamp*'
        Test-Path -LiteralPath (Join-Path $f.Data 'away') |
            Should -BeFalse -Because 'nothing is created from a since: that could not be read'
    }
}

# Criterion 8: a new write destination cannot overwrite a file it does not own. The path is
# constrained two ways - it is always data\away\<stamp>.jsonl, and the stamp is re-rendered from a
# parsed timestamp so no byte of file content can reach it - and the header check is what refuses
# the collision when something else has already taken the name.
Describe 'the journal refuses to write over a file it does not own' {
    It 'builds a name of digits, T and Z only, whatever the flag holds' {
        $f = New-AwayFixture
        Set-RawFlag -Fixture $f -Content "since: 2026-09-25T00:59:24.1234567+02:00`n"
        $r = Get-AwayFlag -FlagPath $f.Flag -DataPath $f.Data
        $r.stamp | Should -Match '^[0-9]{8}T[0-9]{6}Z$'
        $r.stamp | Should -Be '20260924T225924Z' -Because 'the name is normalised to UTC, not copied'
        (Split-Path $r.journalPath -Parent) | Should -Be (Join-Path $f.Data 'away')
    }

    It 'refuses a path traversal dressed up as a since value' {
        $f = New-AwayFixture
        Set-RawFlag -Fixture $f -Content "since: ..\..\..\crew.json`n"
        { Open-AwayJournal -FlagPath $f.Flag -DataPath $f.Data } | Should -Throw '*not a timestamp*'
    }

    It 'refuses to append to a <case> sitting on the journal name, leaving it byte for byte' -ForEach @(
        @{ case = 'foreign file';    content = "hello, this is not a journal`n" }
        @{ case = 'empty file';      content = '' }
        @{ case = 'bare json array'; content = "[1,2,3]`n" }
    ) {
        $f    = New-AwayFixture
        $path = (Get-FixtureJournalPath $f)
        New-Item -ItemType Directory -Force -Path (Split-Path $path -Parent) | Out-Null
        [System.IO.File]::WriteAllText($path, $content)

        { Add-FixtureEntry -Fixture $f -Entry @{ Kind = 'landed'; Text = 'T-1' } } | Should -Throw
        [System.IO.File]::ReadAllText($path) |
            Should -BeExactly $content -Because 'the file that already held the name is left alone'
    }

    It 'refuses a journal belonging to a different away period' {
        $f = New-AwayFixture
        Add-FixtureEntry -Fixture $f -Entry @{ Kind = 'landed'; Text = 'first period' } | Out-Null
        $firstPath = (Get-FixtureJournalPath $f)

        # Same second, different away period: the name collides and the header does not.
        Set-Content -LiteralPath $f.Flag -Encoding utf8 -Value 'since: 2026-09-25T00:59:24.9999999Z'
        { Open-AwayJournal -FlagPath $f.Flag -DataPath $f.Data } |
            Should -Throw '*Refusing to write one period*'
        (Get-Content -LiteralPath $firstPath).Count |
            Should -Be 2 -Because 'the first period keeps its header and its one record'
    }
}

Describe 'Write-AwayJournalEntry records one outcome as it happens' {
    It 'records the kind, the text, the worker and the evidence' {
        $f = New-AwayFixture
        Add-FixtureEntry -Fixture $f -Entry @{
            Kind = 'failed'; Text = 'could not build'; Worker = 'w3'; Evidence = 'MSB4018 at Api.csproj'
        } | Out-Null

        $e = (Get-FixtureDigest $f).entries[0]
        $e.kind     | Should -Be 'failed'
        $e.text     | Should -Be 'could not build'
        $e.worker   | Should -Be 'w3'
        $e.evidence | Should -Be 'MSB4018 at Api.csproj'
    }

    It 'stamps the time itself and refuses to be handed one' {
        $f      = New-AwayFixture
        $before = (Get-Date).ToUniversalTime()
        $r      = Add-FixtureEntry -Fixture $f -Entry @{ Kind = 'note'; Text = 'quiet' }
        $after  = (Get-Date).ToUniversalTime()

        $at = [datetimeoffset]::Parse($r.at, [System.Globalization.CultureInfo]::InvariantCulture)
        $at.UtcDateTime | Should -BeGreaterOrEqual $before.AddSeconds(-1)
        $at.UtcDateTime | Should -BeLessOrEqual $after.AddSeconds(1)

        # No caller may back-date a record, which is what makes a journal assembled at the end of an
        # away period visibly assembled at the end rather than passing as contemporaneous.
        { Write-AwayJournalEntry -Kind note -Text 'x' -At '2020-01-01T00:00:00Z' `
            -FlagPath $f.Flag -DataPath $f.Data } | Should -Throw
    }

    # The floor under "written as each thing happens": once the flag is off, the period is over and
    # the journal is closed. Nothing can be added at return time.
    It 'cannot write anything once the away flag is gone' {
        $f = New-AwayFixture
        Add-FixtureEntry -Fixture $f -Entry @{ Kind = 'landed'; Text = 'T-1' } | Out-Null
        Remove-Item -LiteralPath $f.Flag -Force
        { Add-FixtureEntry -Fixture $f -Entry @{ Kind = 'landed'; Text = 'T-2' } } |
            Should -Throw '*No regency is in force*'
    }

    It 'refuses a kind outside the closed set' {
        $f = New-AwayFixture
        { Add-FixtureEntry -Fixture $f -Entry @{ Kind = 'merged'; Text = 'T-1' } } | Should -Throw
    }

    It 'refuses an entry with no text' {
        $f = New-AwayFixture
        { Add-FixtureEntry -Fixture $f -Entry @{ Kind = 'note'; Text = '' } } | Should -Throw
    }

    # regency and petition both require the basis of a call taken in his stead to be recorded. This
    # is that requirement with something behind it rather than a sentence asking for it.
    It 'refuses a decision that does not say what it rested on' {
        $f = New-AwayFixture
        { Add-FixtureEntry -Fixture $f -Entry @{ Kind = 'decided'; Text = 'renamed the label' } } |
            Should -Throw '*-Basis*'
    }

    It 'records a decision made on <basis>' -ForEach @(
        @{ basis = 'recorded' }
        @{ basis = 'judgement' }
    ) {
        $f = New-AwayFixture
        Add-FixtureEntry -Fixture $f -Entry @{ Kind = 'decided'; Text = 'renamed the label'; Basis = $basis } | Out-Null
        (Get-FixtureDigest $f).byKind['decided'][0].basis | Should -Be $basis
    }

    It 'refuses a basis on anything that is not a decision' {
        $f = New-AwayFixture
        { Add-FixtureEntry -Fixture $f -Entry @{ Kind = 'landed'; Text = 'T-1'; Basis = 'recorded' } } |
            Should -Throw '*decided entry*'
    }

    It 'survives a worker question carrying quotes, backslashes and newlines' {
        $f        = New-AwayFixture
        $question = "Overwrite `"settings.local.json`"?`nPath: C:\repos\acme\.claude [y/N]"
        Add-FixtureEntry -Fixture $f -Entry @{ Kind = 'blocked'; Text = $question; Worker = 'w2' } | Out-Null
        Add-FixtureEntry -Fixture $f -Entry @{ Kind = 'note'; Text = 'after' } | Out-Null

        $d = Get-FixtureDigest $f
        $d.count                   | Should -Be 2 -Because 'a newline in a record must not become a second line'
        $d.byKind['blocked'][0].text | Should -Be $question
    }
}

Describe 'Get-AwayDigest reads the journal or says it could not' {
    # R-006: an away period that produced nothing renders correctly. An opened journal with no
    # records is a complete report, and it is a different answer from one that could not be read.
    It 'reports a quiet night as "Nothing needed you."' {
        $f = New-AwayFixture
        Open-AwayJournal -FlagPath $f.Flag -DataPath $f.Data | Out-Null

        $d = Get-FixtureDigest $f
        $d.readable | Should -BeTrue
        $d.count    | Should -Be 0
        $d.summary  | Should -Be 'Nothing needed you.'
        foreach ($k in $d.byKind.Keys) { @($d.byKind[$k]).Count | Should -Be 0 }
    }

    # R-003, and the whole point of the change: a digest that cannot read the journal says so in
    # words of its own rather than rendering as though nothing happened.
    It 'says it could not read the journal when <case>, and never returns an empty-looking digest' -ForEach @(
        @{ case = 'none was ever opened'; setup = 'none' }
        @{ case = 'the file is empty';    setup = 'empty' }
        @{ case = 'the file is foreign';  setup = 'foreign' }
        @{ case = 'there is no flag';     setup = 'noflag' }
    ) {
        $f = New-AwayFixture
        switch ($setup) {
            'empty'   {
                $p = (Get-FixtureJournalPath $f)
                New-Item -ItemType Directory -Force -Path (Split-Path $p -Parent) | Out-Null
                [System.IO.File]::WriteAllText($p, '')
            }
            'foreign' {
                $p = (Get-FixtureJournalPath $f)
                New-Item -ItemType Directory -Force -Path (Split-Path $p -Parent) | Out-Null
                [System.IO.File]::WriteAllText($p, "# an away journal`n- nothing happened`n")
            }
            'noflag'  { Remove-Item -LiteralPath $f.Flag -Force }
        }

        $d = $null
        { $script:d = Get-FixtureDigest $f } | Should -Not -Throw -Because 'the return digest cannot die on a bad file'
        $script:d.readable | Should -BeFalse
        $script:d.problem  | Should -Not -BeNullOrEmpty
        $script:d.count    | Should -Be 0
        $script:d.summary  | Should -Match 'could not be read'
        $script:d.summary  | Should -Not -Match 'Nothing needed you'
        $script:d.summary.Contains('nothing here was reconstructed from memory') |
            Should -BeTrue -Because 'the sentence the King is given comes from here, not from the session'
    }

    It 'groups records by kind and keeps them in the order they happened' {
        $f = New-AwayFixture
        Add-FixtureEntry -Fixture $f -Entry @{ Kind = 'dispatched'; Text = 'T-1 out' }  | Out-Null
        Add-FixtureEntry -Fixture $f -Entry @{ Kind = 'landed';     Text = 'T-1 in' }   | Out-Null
        Add-FixtureEntry -Fixture $f -Entry @{ Kind = 'failed';     Text = 'T-2 red' }  | Out-Null
        Add-FixtureEntry -Fixture $f -Entry @{ Kind = 'landed';     Text = 'T-3 in' }   | Out-Null

        $d = Get-FixtureDigest $f
        $d.readable | Should -BeTrue
        $d.count    | Should -Be 4
        $d.since    | Should -Be $script:SinceA
        $d.summary  | Should -Be '4 things were recorded while you were away.'
        @($d.entries | ForEach-Object { $_.text }) | Should -Be @('T-1 out', 'T-1 in', 'T-2 red', 'T-3 in')
        @($d.byKind['landed'] | ForEach-Object { $_.text }) | Should -Be @('T-1 in', 'T-3 in')
        @($d.byKind['failed']).Count     | Should -Be 1
        @($d.byKind['dispatched']).Count | Should -Be 1
    }

    It 'says "One thing" rather than "1 things"' {
        $f = New-AwayFixture
        Add-FixtureEntry -Fixture $f -Entry @{ Kind = 'landed'; Text = 'T-1' } | Out-Null
        (Get-FixtureDigest $f).summary | Should -Be 'One thing was recorded while you were away.'
    }

    # A crash mid-append leaves a truncated line. The records that survived are still given, and
    # the one that did not is counted and named - never dropped into a report that looks whole.
    It 'counts a damaged record, names its line, and still gives the ones that read' {
        $f = New-AwayFixture
        Add-FixtureEntry -Fixture $f -Entry @{ Kind = 'landed'; Text = 'T-1' } | Out-Null
        [System.IO.File]::AppendAllText(
            (Get-FixtureJournalPath $f), ('{"record":"away-ent' + "`n"))
        Add-FixtureEntry -Fixture $f -Entry @{ Kind = 'landed'; Text = 'T-2' } | Out-Null

        $d = Get-FixtureDigest $f
        $d.readable     | Should -BeTrue
        $d.count        | Should -Be 2
        $d.damaged      | Should -Be 1
        $d.damagedLines | Should -Be @(3)
        $d.summary      | Should -Match 'this account is incomplete'
    }

    It 'keeps a record whose kind it does not know and names the kind' {
        $f = New-AwayFixture
        Add-FixtureEntry -Fixture $f -Entry @{ Kind = 'landed'; Text = 'T-1' } | Out-Null
        [System.IO.File]::AppendAllText(
            (Get-FixtureJournalPath $f),
            '{"record":"away-entry","at":"2026-09-25T01:00:00.0000000Z","kind":"rekeyed","text":"x"}' + "`n")

        $d = Get-AwayDigest -FlagPath $f.Flag -DataPath $f.Data
        $d.readable     | Should -BeTrue
        $d.count        | Should -Be 2 -Because 'an unknown kind is reported, never dropped'
        $d.unknownKinds | Should -Be @('rekeyed')
        $d.summary      | Should -Match 'rekeyed'
    }

    # The flag comes off at return, so a journal has to stay readable by name afterwards - which is
    # also what lets an earlier away period be read back later.
    It 'reads a named journal after the flag has gone' {
        $f = New-AwayFixture
        Add-FixtureEntry -Fixture $f -Entry @{ Kind = 'landed'; Text = 'T-1' } | Out-Null
        $path = (Get-FixtureJournalPath $f)
        Remove-Item -LiteralPath $f.Flag -Force

        $d = Get-AwayDigest -Path $path -DataPath $f.Data -FlagPath $f.Flag
        $d.readable | Should -BeTrue
        $d.count    | Should -Be 1
        $d.since    | Should -Be $script:SinceA -Because 'the header carries the period the flag no longer can'
    }

    It 'refuses a journal whose header names a different period from the flag' {
        $f = New-AwayFixture
        Add-FixtureEntry -Fixture $f -Entry @{ Kind = 'landed'; Text = 'T-1' } | Out-Null
        $path = (Get-FixtureJournalPath $f)

        # The same name reached from a flag claiming a different period within the same second.
        Set-Content -LiteralPath $f.Flag -Encoding utf8 -Value 'since: 2026-09-25T00:59:24.5000000Z'
        $d = Get-FixtureDigest $f
        $d.readable | Should -BeFalse
        $d.summary  | Should -Match 'could not be read'
        (Get-Content -LiteralPath $path).Count | Should -Be 2
    }
}

# Criterion 6: every new parameter default has to be reachable. regency spells every command with
# no path arguments at all, so the defaults are the path every real call takes - this fires them.
Describe 'the default paths resolve under KINGSHAND_HOME' {
    BeforeAll {
        $script:HomeFixture = New-AwayFixture
        $script:SavedHome   = $env:KINGSHAND_HOME
        $env:KINGSHAND_HOME = $script:HomeFixture.Root
    }
    AfterAll {
        if ($null -eq $script:SavedHome) { Remove-Item Env:\KINGSHAND_HOME -ErrorAction SilentlyContinue }
        else { $env:KINGSHAND_HOME = $script:SavedHome }
    }

    It 'finds state\.afk and data\away with no arguments at all' {
        $flag = Get-AwayFlag
        $flag.present | Should -BeTrue
        $flag.since   | Should -Be $script:SinceA
        $flag.journalPath | Should -Be (Join-Path $script:HomeFixture.Data "away\$script:StampA.jsonl")

        Write-AwayJournalEntry -Kind landed -Text 'defaulted' | Out-Null
        $d = Get-AwayDigest
        $d.readable | Should -BeTrue
        $d.count    | Should -Be 1
        $d.entries[0].text | Should -Be 'defaulted'
    }
}

# A forced nested import removes Paths.psm1 before re-importing it, so a script that had already
# imported it loses Get-KingshandHome the moment this module loads. Get-SessionStart.ps1 imports
# this module after Paths is already in the session, which is exactly that order.
Describe 'importing AwayJournal does not unload Paths or Index from the caller' {
    BeforeAll {
        $root   = Split-Path $PSScriptRoot -Parent
        $driver = Join-Path ([IO.Path]::GetTempPath()) ("awayimport-" + [guid]::NewGuid().ToString('N') + '.ps1')
        Set-Content -LiteralPath $driver -Encoding utf8 -Value @"
Import-Module '$root\bin\Paths.psm1' -Force
Import-Module '$root\bin\Index.psm1' -Force
Import-Module '$root\bin\AwayJournal.psm1' -Force
Write-Host "PATHS_BOUND=`$([bool](Get-Command Get-KingshandHome -ErrorAction SilentlyContinue))"
Write-Host "INDEX_BOUND=`$([bool](Get-Command Add-IndexEntry -ErrorAction SilentlyContinue))"
Write-Host "AWAY_BOUND=`$([bool](Get-Command Get-AwayDigest -ErrorAction SilentlyContinue))"
"@
        try {
            $script:ImportOut = & (Get-Process -Id $PID).Path -NoProfile -File $driver 2>&1 | Out-String
        } finally {
            Remove-Item -LiteralPath $driver -Force -ErrorAction SilentlyContinue
        }
    }

    It 'keeps <name> bound in the session that imported it first' -ForEach @(
        @{ name = 'Get-KingshandHome'; marker = 'PATHS_BOUND=True' }
        @{ name = 'Add-IndexEntry';    marker = 'INDEX_BOUND=True' }
    ) {
        $script:ImportOut | Should -BeLike "*$marker*"
    }

    It 'still binds its own exports' {
        $script:ImportOut | Should -BeLike '*AWAY_BOUND=True*'
    }
}
