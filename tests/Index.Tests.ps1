# The data index is what makes a file written in one session reachable from a brief written in the
# next. A settled brand spec sat in data\ while the site it described shipped with none of it,
# because nothing listed the file and nothing noticed that nothing did.
#
# So the two behaviours that carry the whole design are pinned hardest here: writing a file and
# indexing it must be ONE call, and a file no index lists must be counted as drift. Everything else
# - the one-line cap, the per-project scope, the three exclusions - exists to keep those two
# honest. The exclusions are an index file, a rendered `*.html` surface and a `read-first\` copy,
# and each passes the same test: it is derived from a file the index already lists, so an entry
# would record one fact twice. An exclusion that cannot say what it is derived from does not
# belong, whatever the count.
#
# Every case runs against its own throwaway data directory under TestDrive. The live
# $env:KINGSHAND_HOME\data\ is never read and never written by this suite.

BeforeAll {
    Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'bin\Index.psm1') -Force

    function New-DataFixture {
        param([Parameter(Mandatory)][string]$Name)
        $data = Join-Path $TestDrive "$Name\data"
        New-Item -ItemType Directory -Force -Path $data | Out-Null
        $data
    }

    function New-DataFile {
        param(
            [Parameter(Mandatory)][string]$DataPath,
            [Parameter(Mandatory)][string]$Relative,
            [string]$Content = 'x'
        )
        $full = Join-Path $DataPath $Relative
        $dir  = Split-Path -Parent $full
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
        }
        Set-Content -Path $full -Value $Content -Encoding utf8
        $full
    }
}

Describe 'an entry says where a file is and what it is, in one line' {
    BeforeAll {
        $script:Data = New-DataFixture 'entry'
        $script:File = New-DataFile -DataPath $script:Data -Relative 'emgee-brand.md'
        $script:Entry = Add-IndexEntry -Path $script:File -Summary 'settled brand: logo, favicon, tagline, palettes' `
            -Project 'emgeelabs-site' -DataPath $script:Data
    }

    It 'writes the project index under data\index\, named for the project' {
        $script:Entry.indexPath | Should -Be (Join-Path $script:Data 'index\emgeelabs-site.md')
        Test-Path -LiteralPath $script:Entry.indexPath | Should -BeTrue
    }

    It 'records the path relative to the installation root, so a clone elsewhere still resolves' {
        $script:Entry.path | Should -Be 'data\emgee-brand.md'
        (Get-Content -LiteralPath $script:Entry.indexPath -Raw).Contains('- `data\emgee-brand.md` - settled brand: logo, favicon, tagline, palettes (added') |
            Should -BeTrue -Because 'path, one line of what it is, and the date is the whole entry'
    }

    It 'reads back with the path resolved to a file that exists' {
        $entries = @(Get-IndexEntries -Project 'emgeelabs-site' -DataPath $script:Data)
        $entries.Count      | Should -Be 1
        $entries[0].fullPath | Should -Be $script:File
        $entries[0].exists   | Should -BeTrue
        $entries[0].summary  | Should -Be 'settled brand: logo, favicon, tagline, palettes'
        $entries[0].added    | Should -Match '^\d{4}-\d{2}-\d{2}$'
    }

    It 'takes an already-relative path and stores it identically' {
        $data = New-DataFixture 'relative'
        New-DataFile -DataPath $data -Relative 'notes.md' | Out-Null
        (Add-IndexEntry -Path 'data\notes.md' -Summary 'a note' -DataPath $data).path |
            Should -Be 'data\notes.md' -Because 'an absolute and a relative path must not produce two entries for one file'
    }

    It 'collapses a summary written across lines into the one line an index allows' {
        $data = New-DataFixture 'collapse'
        New-DataFile -DataPath $data -Relative 'x.md' | Out-Null
        (Add-IndexEntry -Path 'data\x.md' -Summary "what it   is`nand more of it" -DataPath $data).summary |
            Should -Be 'what it is and more of it'
    }

    It 'refuses a summary long enough to be content rather than a table of contents' {
        $data = New-DataFixture 'too-long'
        New-DataFile -DataPath $data -Relative 'x.md' | Out-Null
        { Add-IndexEntry -Path 'data\x.md' -Summary ('x' * 161) -DataPath $data } |
            Should -Throw -ExpectedMessage '*table of contents, never content*' `
            -Because 'truncating it silently would be a summary that lies'
    }

    It 'refuses a file outside data\, which is not kingshand''s to index' {
        $data = New-DataFixture 'outside'
        { Add-IndexEntry -Path (Join-Path $TestDrive 'elsewhere.md') -Summary 'not ours' -DataPath $data } |
            Should -Throw -ExpectedMessage '*outside it*'
    }

    # The relative branch used to strip leading dots, so this came back as data\notes.md: an entry
    # for a file that was never the caller's subject, written into the index with no error, while
    # the identical file named absolutely threw. Both branches now refuse the same input.
    It 'refuses a relative path that climbs out of data\ rather than rewriting it' {
        $data = New-DataFixture 'escape'
        { Add-IndexEntry -Path '..\..\notes.md' -Summary 'not ours' -DataPath $data } |
            Should -Throw -ExpectedMessage '*outside it*'
        Test-Path -LiteralPath (Join-Path $data 'index.md') |
            Should -BeFalse -Because 'a refused entry must leave no line behind'
    }

    It 'still resolves a relative path that stays inside data\' {
        $data = New-DataFixture 'inside-relative'
        New-DataFile -DataPath $data -Relative 'sub\deep.md' | Out-Null
        (Add-IndexEntry -Path '.\sub\deep.md' -Summary 'a nested note' -DataPath $data).path |
            Should -Be 'data\sub\deep.md'
    }

    # A hand-edited line naming somewhere outside data\ is one bad line, not a broken index: the
    # digest reads drift through here and would otherwise lose its whole INDEX section to it.
    It 'skips an unreadable line rather than failing the whole index' {
        $data = New-DataFixture 'bad-line'
        New-DataFile -DataPath $data -Relative 'good.md' | Out-Null
        Add-IndexEntry -Path 'data\good.md' -Summary 'a good one' -DataPath $data | Out-Null
        Add-Content -LiteralPath (Join-Path $data 'index.md') -Value '- `..\..\escape.md` - hand-edited'

        $entries = @(Get-IndexEntries -DataPath $data)
        $entries.Count   | Should -Be 1
        $entries[0].path | Should -Be 'data\good.md'
        { Get-IndexDrift -DataPath $data } | Should -Not -Throw
    }

    It 'refuses a project name that is not slug-shaped' {
        $data = New-DataFixture 'bad-project'
        { Get-IndexPath -Project '..\..\escape' -DataPath $data } |
            Should -Throw -ExpectedMessage '*slug-shaped*' -Because 'the index file name comes straight from it'
    }
}

Describe 're-indexing a file rewrites its line rather than adding a second one' {
    BeforeAll {
        $script:Data = New-DataFixture 'reindex'
        New-DataFile -DataPath $script:Data -Relative 'spec.md' | Out-Null
        $indexDir = Join-Path $script:Data 'index'
        New-Item -ItemType Directory -Force -Path $indexDir | Out-Null
        Set-Content -Path (Join-Path $indexDir 'acme.md') -Encoding utf8 -Value @(
            '# Index'
            ''
            '- `data\spec.md` - the first summary (added 2026-01-01)'
        )
        $script:Again = Add-IndexEntry -Path 'data\spec.md' -Summary 'the corrected summary' `
            -Project 'acme' -DataPath $script:Data
    }

    It 'leaves exactly one entry for that file' {
        @(Get-IndexEntries -Project 'acme' -DataPath $script:Data).Count | Should -Be 1
    }

    It 'keeps the date it first entered the index' {
        $script:Again.added | Should -Be '2026-01-01' -Because 'a re-index is not a new file'
    }

    It 'carries the corrected summary' {
        # @() before the index, always: a lone hashtable unrolls out of the pipeline, and [0] on a
        # hashtable is a key lookup that quietly returns $null rather than the entry.
        @(Get-IndexEntries -Project 'acme' -DataPath $script:Data)[0].summary | Should -Be 'the corrected summary'
    }

    # A hand-edited index whose last line has no terminator took the appended entry onto the end of
    # it. The reader's regex still matched that joined line as the FIRST entry, with the second
    # swallowed into its summary - so the file just indexed silently became drift again, which is
    # the one failure this module exists to prevent.
    It 'appends to an index whose last line has no newline without joining the two' {
        $data = New-DataFixture 'unterminated'
        New-DataFile -DataPath $data -Relative 'a.md' | Out-Null
        New-DataFile -DataPath $data -Relative 'b.md' | Out-Null
        $index = Join-Path $data 'index\acme.md'
        New-Item -ItemType Directory -Force -Path (Split-Path $index -Parent) | Out-Null
        [IO.File]::WriteAllText($index, "# Index`n`n- ``data\a.md`` - the brand (added 2026-08-29)")

        Add-IndexEntry -Path 'data\b.md' -Summary 'the report' -Project 'acme' -DataPath $data | Out-Null

        $entries = @(Get-IndexEntries -Project 'acme' -DataPath $data)
        @($entries | ForEach-Object { $_.path }) | Should -Be @('data\a.md', 'data\b.md')
        @($entries | Where-Object { $_.path -eq 'data\a.md' })[0].summary |
            Should -Be 'the brand' -Because 'the first entry must not swallow the second as its summary'
        @(Get-IndexDrift -DataPath $data).unindexed |
            Should -BeNullOrEmpty -Because 'a file that was just indexed must not still read as drift'
    }
}

Describe 'writing a file and indexing it are one call' {
    # The rule that says "remember to add it afterwards" is the rule that was forgotten, so the
    # write and the index are not allowed to be two things a caller can do one of.
    BeforeAll { $script:Data = New-DataFixture 'write-data-file' }

    It 'writes the content and records the entry together' {
        $r = Write-DataFile -Path 'data\emgee-brand.md' -Content "# Brand`nteal" `
            -Summary 'settled brand' -Project 'emgeelabs-site' -DataPath $script:Data
        (Get-Content -LiteralPath $r.fullPath -Raw).Contains('teal') | Should -BeTrue
        @(Get-IndexEntries -Project 'emgeelabs-site' -DataPath $script:Data).Count | Should -Be 1
    }

    It 'creates the directories the path needs' {
        $r = Write-DataFile -Path 'data\T-1001\brief.md' -Content '# brief' -Summary 'the brief for T-1001' `
            -Project 'acme' -DataPath $script:Data
        Test-Path -LiteralPath $r.fullPath | Should -BeTrue
    }

    It 'leaves no file behind when the summary is one the index would refuse' {
        { Write-DataFile -Path 'data\rejected.md' -Content 'body' -Summary ('x' * 200) -DataPath $script:Data } |
            Should -Throw
        Test-Path -LiteralPath (Join-Path $script:Data 'rejected.md') |
            Should -BeFalse -Because 'a file on disk that nothing lists is the failure this module exists to prevent'
    }
}

Describe 'the index is scoped per project, with kingshand''s own files at the root' {
    BeforeAll {
        $script:Data = New-DataFixture 'scope'
        New-DataFile -DataPath $script:Data -Relative 'site\brand.md'   | Out-Null
        New-DataFile -DataPath $script:Data -Relative 'aegis\report.md' | Out-Null
        New-DataFile -DataPath $script:Data -Relative 'learnings.md'    | Out-Null
        Add-IndexEntry -Path 'data\site\brand.md'   -Summary 'the brand'   -Project 'emgeelabs-site' -DataPath $script:Data | Out-Null
        Add-IndexEntry -Path 'data\aegis\report.md' -Summary 'a refill bug' -Project 'aegis-manager' -DataPath $script:Data | Out-Null
        Add-IndexEntry -Path 'data\learnings.md'    -Summary 'operational learnings'                 -DataPath $script:Data | Out-Null
    }

    It 'hands a project only its own files' {
        $site = @(Get-IndexEntries -Project 'emgeelabs-site' -DataPath $script:Data)
        $site.Count  | Should -Be 1 -Because 'an index spanning every project hands a website worker the aegis reports'
        $site[0].path | Should -Be 'data\site\brand.md'
    }

    It 'keeps the operational files in the root index, which no project name can collide with' {
        $root = @(Get-IndexEntries -DataPath $script:Data)
        $root.Count   | Should -Be 1
        $root[0].path | Should -Be 'data\learnings.md'
        Get-IndexPath -DataPath $script:Data | Should -Be (Join-Path $script:Data 'index.md')
    }

    It 'reads every index at once when asked for all of them' {
        @(Get-IndexEntries -All -DataPath $script:Data).Count | Should -Be 3
        @(Get-AllIndexPaths -DataPath $script:Data).Count     | Should -Be 3
    }
}

Describe 'a file no index lists is drift, and drift is counted' {
    # This is the part that makes the design self-checking: "this file is listed nowhere" is a fact
    # a machine can notice, where "somebody should have realised this mattered" never was.
    BeforeAll {
        $script:Data = New-DataFixture 'drift'
        New-DataFile -DataPath $script:Data -Relative 'listed.md'          | Out-Null
        New-DataFile -DataPath $script:Data -Relative 'T-1\report.md'      | Out-Null
        New-DataFile -DataPath $script:Data -Relative 'T-1\review.html'    | Out-Null
        Add-IndexEntry -Path 'data\listed.md' -Summary 'this one is listed' -Project 'acme' -DataPath $script:Data | Out-Null
        $script:Drift = Get-IndexDrift -DataPath $script:Data
    }

    It 'counts what is listed' {
        $script:Drift.indexed | Should -Be 1
    }

    It 'names the durable file nobody indexed' {
        @($script:Drift.unindexed) | Should -Be @('data\T-1\report.md')
    }

    # Dispatch stages a copy of every Read-first file into data\<id>\read-first\, teardown keeps
    # data\<id>\, and the original already has its own entry - so counting the copies grew the
    # drift number by one per dispatch forever, and the instruction it printed ("index each as you
    # touch it") would have put a duplicate entry in the table of contents for a file already
    # listed. The exclusion is derivation, not worth: the copy is made from a listed file.
    It 'never counts a dispatch''s staged read-first copy against the drift' {
        $data = New-DataFixture 'read-first-copies'
        New-DataFile -DataPath $data -Relative 'emgee-brand.md'                     | Out-Null
        New-DataFile -DataPath $data -Relative 'T-1\read-first\emgee-brand.md'       | Out-Null
        New-DataFile -DataPath $data -Relative 'T-2\read-first\emgee-brand.md'       | Out-Null
        Add-IndexEntry -Path 'data\emgee-brand.md' -Summary 'settled brand' -Project 'acme' -DataPath $data | Out-Null

        $d = Get-IndexDrift -DataPath $data
        @($d.unindexed).Count | Should -Be 0 -Because 'the copies are snapshots of a file the index already lists'
        @($d.missing).Count   | Should -Be 0
    }

    # The exclusion must not become "anything with that name is uninteresting". A worker's own
    # durable files still count, and so does a file that merely starts with the same letters.
    It 'still counts the durable files that sit beside a read-first directory' {
        $data = New-DataFixture 'read-first-siblings'
        New-DataFile -DataPath $data -Relative 'T-1\read-first\spec.md' | Out-Null
        New-DataFile -DataPath $data -Relative 'T-1\report.md'          | Out-Null
        New-DataFile -DataPath $data -Relative 'read-first-notes.md'    | Out-Null

        @(Get-IndexDrift -DataPath $data).unindexed |
            Should -Be @('data\read-first-notes.md', 'data\T-1\report.md')
    }

    It 'never counts a rendered surface or an index against the drift' {
        @($script:Drift.unindexed) -contains 'data\T-1\review.html' |
            Should -BeFalse -Because 'a review surface is regenerated from state, not read as a source'
        @($script:Drift.unindexed) -contains 'data\index\acme.md' |
            Should -BeFalse -Because 'an index does not index itself'
        @(Get-IndexableFiles -DataPath $script:Data).Count |
            Should -Be 2 -Because 'the exclusions are an index, a rendered surface and a read-first copy, and each one is a file derived from a listed file rather than a file judged unimportant'
    }

    It 'reports an entry whose file has gone as stale rather than as indexed cover' {
        Add-IndexEntry -Path 'data\gone.md' -Summary 'deleted since' -Project 'acme' -DataPath $script:Data | Out-Null
        @((Get-IndexDrift -DataPath $script:Data).missing) | Should -Be @('data\gone.md')
    }

    It 'reports nothing missing and nothing unindexed once every file is listed' {
        $data = New-DataFixture 'clean'
        Write-DataFile -Path 'data\a.md' -Content 'a' -Summary 'file a' -Project 'acme' -DataPath $data | Out-Null
        Write-DataFile -Path 'data\b.md' -Content 'b' -Summary 'file b' -DataPath $data | Out-Null
        $d = Get-IndexDrift -DataPath $data
        $d.indexed              | Should -Be 2
        @($d.unindexed).Count   | Should -Be 0
        @($d.missing).Count     | Should -Be 0
    }

    # Both functions are exported and CLAUDE.md advertises the module as the way to count the
    # drift, so a hand call from KINGSHAND_HOME with `data` is an ordinary thing to do. The two
    # exclusions were built by string-joining $DataPath and compared against Get-ChildItem's
    # always-absolute FullName, so every index file came back as drift with no error at all.
    It 'counts the same drift whether the data directory is named absolutely or relatively' {
        $data = New-DataFixture 'relative-datapath'
        New-DataFile -DataPath $data -Relative 'listed.md'   | Out-Null
        New-DataFile -DataPath $data -Relative 'unlisted.md' | Out-Null
        Add-IndexEntry -Path 'data\listed.md' -Summary 'listed' -Project 'acme' -DataPath $data | Out-Null

        $absolute = Get-IndexDrift -DataPath $data
        Push-Location (Split-Path $data -Parent)
        try { $relative = Get-IndexDrift -DataPath 'data' } finally { Pop-Location }

        @($relative.unindexed)       | Should -Be @($absolute.unindexed)
        @($relative.unindexed)       | Should -Be @('data\unlisted.md')
        $relative.indexed            | Should -Be $absolute.indexed
        @($relative.unindexed) -contains 'data\index\acme.md' |
            Should -BeFalse -Because 'an index does not index itself, whichever way its directory was named'
    }

    It 'reads an installation with no data directory as empty rather than failing' {
        $absent = Join-Path $TestDrive 'never-installed\data'
        { Get-IndexDrift -DataPath $absent } | Should -Not -Throw
        $d = Get-IndexDrift -DataPath $absent
        $d.indexed            | Should -Be 0
        @($d.unindexed).Count | Should -Be 0
        @($d.indexes).Count   | Should -Be 0
    }
}
