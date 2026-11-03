#Requires -Version 7.0
Set-StrictMode -Version Latest

# The data tidy deletes files from a directory with no recovery at all, so every rule that keeps a
# file is driven here through the public function with the failure forced, on a temp data\ tree.
# The backlog is reached through one boundary function and these cases mock it with the TOON
# tasks-axi prints; one case at the end runs the real tool against a throwaway backlog, so the
# decode is proven against what the tool actually says.

BeforeAll {
    Import-Module "$PSScriptRoot\..\bin\DataTidy.psm1" -Force

    function New-Home {
        $h = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path (Join-Path $h 'data'), (Join-Path $h 'state') | Out-Null
        $h
    }

    function New-File {
        param([string]$Path, [string]$Text = 'settled text')
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
        Set-Content -LiteralPath $Path -Value $Text -Encoding utf8
        $Path
    }

    # tasks-axi's `list --fields closed` answer, one row per "id=state".
    function Set-Backlog {
        param([string[]]$Rows = @(), [string]$Count)
        $n = if ($PSBoundParameters.ContainsKey('Count')) { $Count } else { "$($Rows.Count)" }
        $text = if ($Rows.Count -eq 0) { "count: $n`ntasks: 0 tasks in this backlog" } else {
            $lines = foreach ($r in $Rows) {
                $id, $state = $r -split '='
                $closed = if ($state -eq 'done') { '2026-09-01' } else { '-' }
                "  $id,$state,task,acme-api,A title,$closed"
            }
            "count: $n`ntasks[$($Rows.Count)]{id,state,kind,repo,title,closed}:`n" + ($lines -join "`n")
        }
        $script:Reply = [pscustomobject]@{ ok = $true; text = $text; error = '' }
        Mock -ModuleName DataTidy Invoke-TidyTasksAxi { $script:Reply }
    }

    function Invoke-Tidy {
        param([string]$KhHome, [switch]$Apply)
        Invoke-DataTidy -Apply:$Apply -DataPath (Join-Path $KhHome 'data') -QueueRoot $KhHome -KingshandHome $KhHome
    }
}

Describe 'a staged copy of closed work' {
    BeforeEach {
        $script:H    = New-Home
        $script:Orig = New-File (Join-Path $script:H 'data\done-acme.md')
        $script:Copy = New-File (Join-Path $script:H 'data\T-1\read-first\done-acme.md')
        $script:Brief  = New-File (Join-Path $script:H 'data\T-1\brief.md') 'the brief'
        $script:Report = New-File (Join-Path $script:H 'data\T-1\report.md') 'the findings'
        Set-Backlog 'T-1=done'
    }

    It 'is only listed by a dry run, which is the default' {
        $r = Invoke-Tidy $script:H
        $r.applied | Should -BeFalse
        @($r.removable.path) | Should -Be @($script:Copy)
        $r.removable[0].original | Should -Be $script:Orig
        @($r.removed).Count | Should -Be 0
        Test-Path -LiteralPath $script:Copy | Should -BeTrue
    }

    It 'is removed with -Apply, and the brief and report beside it stay' {
        $r = Invoke-Tidy $script:H -Apply
        @($r.removed) | Should -Be @($script:Copy)
        Test-Path -LiteralPath $script:Copy   | Should -BeFalse
        Test-Path -LiteralPath $script:Orig   | Should -BeTrue
        Test-Path -LiteralPath $script:Brief  | Should -BeTrue
        Test-Path -LiteralPath $script:Report | Should -BeTrue
    }

    It 'stays when its original has gone, because the copy may be the last one' {
        Remove-Item -LiteralPath $script:Orig
        $r = Invoke-Tidy $script:H -Apply
        Test-Path -LiteralPath $script:Copy | Should -BeTrue
        $s = @($r.suspected | Where-Object path -eq $script:Copy)
        $s[0].class  | Should -Be 'staged-copy'
        $s[0].reason | Should -BeLike '*original is not on disk*'
    }

    It 'stays when its original has changed since it was copied' {
        Set-Content -LiteralPath $script:Orig -Value 'a later revision'
        $r = Invoke-Tidy $script:H -Apply
        Test-Path -LiteralPath $script:Copy | Should -BeTrue
        @($r.suspected | Where-Object path -eq $script:Copy)[0].reason | Should -BeLike '*changed since it was copied*'
    }

    It 'finds a family file''s original under families\' {
        $fam  = New-File (Join-Path $script:H 'data\families\acme.md') 'shared rules'
        $copy = New-File (Join-Path $script:H 'data\T-1\read-first\family-acme.md') 'shared rules'
        $r = Invoke-Tidy $script:H -Apply
        @($r.removed) | Should -Contain $copy
        Test-Path -LiteralPath $fam | Should -BeTrue
    }

    It 'finds the browser procedure''s original in the installation itself' {
        $skill = New-File (Join-Path $script:H '.claude\skills\witness\SKILL.md') 'procedure'
        $copy  = New-File (Join-Path $script:H 'data\T-1\read-first\SKILL.md') 'procedure'
        $r = Invoke-Tidy $script:H -Apply
        @($r.removed) | Should -Contain $copy
        Test-Path -LiteralPath $skill | Should -BeTrue
    }
}

Describe 'work that is not closed keeps everything' {
    BeforeEach {
        $script:H = New-Home
        New-File (Join-Path $script:H 'data\spec.md') | Out-Null
        $script:Copy = New-File (Join-Path $script:H 'data\T-2\read-first\spec.md')
    }

    # The forced failure the design asks for: nothing but a staged copy and an old brief revision,
    # which looks dead, on an item that is held on a decision.
    It 'keeps a directory that looks dead but belongs to a held item' {
        New-File (Join-Path $script:H 'data\T-2\brief.pass2.md') 'old brief' | Out-Null
        Set-Backlog 'T-2=queued'
        $r = Invoke-Tidy $script:H -Apply
        Test-Path -LiteralPath $script:Copy | Should -BeTrue
        @($r.removed).Count | Should -Be 0
        @($r.suspected | Where-Object path -eq $script:Copy)[0].reason | Should -BeLike '*T-2 is queued, not closed*'
    }

    It 'keeps the copies of an item still in flight' {
        Set-Backlog 'T-2=in_flight'
        (Invoke-Tidy $script:H -Apply).removed.Count | Should -Be 0
        Test-Path -LiteralPath $script:Copy | Should -BeTrue
    }

    It 'keeps the copies of an item the backlog does not list' {
        Set-Backlog 'T-9=done'
        $r = Invoke-Tidy $script:H -Apply
        Test-Path -LiteralPath $script:Copy | Should -BeTrue
        @($r.suspected | Where-Object path -eq $script:Copy)[0].reason | Should -BeLike '*does not list T-2*'
    }
}

Describe 'a backlog that cannot be read deletes nothing and says so' {
    BeforeEach {
        $script:H = New-Home
        New-File (Join-Path $script:H 'data\spec.md') | Out-Null
        $script:Copy = New-File (Join-Path $script:H 'data\T-1\read-first\spec.md')
    }

    It 'when the tool cannot be run' {
        Mock -ModuleName DataTidy Invoke-TidyTasksAxi { [pscustomobject]@{ ok = $false; text = ''; error = 'tasks-axi is not installed.' } }
        $r = Invoke-Tidy $script:H -Apply
        $r.backlog.readable | Should -BeFalse
        $r.backlog.problem  | Should -BeLike '*not installed*'
        Test-Path -LiteralPath $script:Copy | Should -BeTrue
        (Format-DataTidyReport -Result $r)[0] | Should -BeLike 'NOTHING DELETED:*not installed*'
    }

    It 'when the answer will not decode' {
        $script:Reply = [pscustomobject]@{ ok = $true; text = "count: 1`ntasks[1]{id,state}:`n  ""unterminated"; error = '' }
        Mock -ModuleName DataTidy Invoke-TidyTasksAxi { $script:Reply }
        $r = Invoke-Tidy $script:H -Apply
        $r.backlog.readable | Should -BeFalse
        Test-Path -LiteralPath $script:Copy | Should -BeTrue
    }

    It 'when the answer lists fewer items than it counts' {
        Set-Backlog 'T-1=done' -Count 2
        $r = Invoke-Tidy $script:H -Apply
        $r.backlog.readable | Should -BeFalse
        $r.backlog.problem  | Should -BeLike '*partial list*'
        Test-Path -LiteralPath $script:Copy | Should -BeTrue
    }

    It 'when the count is not a whole number' {
        Set-Backlog 'T-1=done' -Count '1 of 5 total'
        $r = Invoke-Tidy $script:H -Apply
        $r.backlog.readable | Should -BeFalse
        Test-Path -LiteralPath $script:Copy | Should -BeTrue
    }

    It 'when an item carries no state' {
        $script:Reply = [pscustomobject]@{ ok = $true; text = "count: 1`ntasks[1]{id,kind}:`n  T-1,task"; error = '' }
        Mock -ModuleName DataTidy Invoke-TidyTasksAxi { $script:Reply }
        $r = Invoke-Tidy $script:H -Apply
        $r.backlog.readable | Should -BeFalse
        $r.backlog.problem  | Should -BeLike '*no id or no state*'
        Test-Path -LiteralPath $script:Copy | Should -BeTrue
    }
}

Describe 'a failure at the file names itself and keeps the copy' {
    BeforeEach {
        $script:H    = New-Home
        $script:Orig = New-File (Join-Path $script:H 'data\spec.md')
        $script:Copy = New-File (Join-Path $script:H 'data\T-1\read-first\spec.md')
        Set-Backlog 'T-1=done'
    }

    It 'when the original cannot be read to compare' {
        $lock = [System.IO.File]::Open($script:Orig, 'Open', 'Read', 'None')
        try { $r = Invoke-Tidy $script:H -Apply } finally { $lock.Dispose() }
        Test-Path -LiteralPath $script:Copy | Should -BeTrue
        @($r.suspected | Where-Object path -eq $script:Copy)[0].reason | Should -BeLike '*could not be read to compare*'
    }

    It 'when the removal itself fails' {
        Mock -ModuleName DataTidy Remove-Item { throw 'access denied' }
        $r = Invoke-Tidy $script:H -Apply
        @($r.removed).Count | Should -Be 0
        $r.failed[0].reason | Should -BeLike '*access denied*'
        Test-Path -LiteralPath $script:Copy | Should -BeTrue
    }

    # What a dry run listed is checked again at the moment of removal, not trusted.
    It 'when the original changes between the listing and the removal' {
        $r = Invoke-Tidy $script:H
        @($r.removable).Count | Should -Be 1
        $script:Calls = 0
        Mock -ModuleName DataTidy Get-TidyHash { $script:Calls++; if ($script:Calls -le 2) { 'A' } else { "$script:Calls" } }
        $r = Invoke-Tidy $script:H -Apply
        @($r.removed).Count | Should -Be 0
        $r.failed[0].reason | Should -BeLike '*changed since it was copied*'
        Test-Path -LiteralPath $script:Copy | Should -BeTrue
    }

    It 'when the index cannot be read' {
        Mock -ModuleName DataTidy Get-IndexDrift { throw 'index unreadable' }
        $r = Invoke-Tidy $script:H
        $r.indexProblem | Should -BeLike 'The index could not be read:*index unreadable*'
        @($r.unindexed).Count | Should -Be 0
        (Format-DataTidyReport -Result $r) | Should -Contain $r.indexProblem
    }
}

Describe 'files refused by rule' {
    BeforeAll {
        $script:H = New-Home
        $script:D = Join-Path $script:H 'data'
    }

    It 'refuses <name>' -ForEach @(
        @{ name = 'a report';             rel = 'data\T-1\report.md' }
        @{ name = 'a brief';              rel = 'data\T-1\brief.md' }
        @{ name = 'a brief revision';     rel = 'data\T-1\brief.pass2.md' }
        @{ name = 'a standing rules file'; rel = 'data\rules-acme.md' }
        @{ name = 'a criteria file';      rel = 'data\done-acme.md' }
        @{ name = 'a family file';        rel = 'data\families\acme.md' }
        @{ name = 'king.md';              rel = 'data\king.md' }
        @{ name = 'learnings.md';         rel = 'data\learnings.md' }
        @{ name = 'the backlog';          rel = 'data\backlog.md' }
        @{ name = 'instructions.md';      rel = 'instructions.md' }
        @{ name = 'anything under state'; rel = 'state\crew.json' }
        @{ name = 'a report even as a staged copy'; rel = 'data\T-1\read-first\report.md' }
        @{ name = 'a brief even as a staged copy';  rel = 'data\T-1\read-first\brief.md' }
        @{ name = 'a copy under families'; rel = 'data\families\read-first\acme.md' }
        @{ name = 'a copy nested deeper than an item'; rel = 'data\T-1\sub\read-first\spec.md' }
    ) {
        Get-DataTidyRefusal -Path (Join-Path $script:H $rel) -DataPath $script:D -KingshandHome $script:H |
            Should -Not -BeNullOrEmpty
    }

    It 'allows a staged copy directly under a work item' {
        Get-DataTidyRefusal -Path (Join-Path $script:D 'T-1\read-first\spec.md') -DataPath $script:D -KingshandHome $script:H |
            Should -BeNullOrEmpty
    }

    It 'keeps a staged report.md of closed work even when its original matches' {
        $h = New-Home
        New-File (Join-Path $h 'data\report.md') 'findings' | Out-Null
        $copy = New-File (Join-Path $h 'data\T-1\read-first\report.md') 'findings'
        Set-Backlog 'T-1=done'
        $r = Invoke-Tidy $h -Apply
        Test-Path -LiteralPath $copy | Should -BeTrue
        @($r.suspected | Where-Object path -eq $copy)[0].reason | Should -BeLike '*report.md is never deleted*'
    }
}

Describe 'what is reported and never removed' {
    BeforeAll {
        $script:H = New-Home
        New-File (Join-Path $script:H 'data\T-1\brief.md') | Out-Null
        New-File (Join-Path $script:H 'data\T-1\brief.pass2.md') | Out-Null
        New-File (Join-Path $script:H 'data\T-1\brief.dispatch.md') | Out-Null
        New-File (Join-Path $script:H 'data\T-3\report.md') | Out-Null
        New-File (Join-Path $script:H 'data\T-4\brief.md') | Out-Null
        New-File (Join-Path $script:H 'data\away\20260925T005924Z.jsonl') | Out-Null
        New-File (Join-Path $script:H 'data\families\acme.md') | Out-Null
        New-File (Join-Path $script:H 'data\loose-note.md') | Out-Null
        Set-Backlog 'T-1=done', 'T-4=queued'
        $script:R = Invoke-Tidy $script:H -Apply
    }

    It 'names an extra brief revision, and not the brief or its dispatch file' {
        @($script:R.suspected | Where-Object class -eq 'brief-revision' | ForEach-Object { Split-Path $_.path -Leaf }) |
            Should -Be @('brief.pass2.md')
    }

    It 'names a closed item''s directory with when it closed' {
        $s = @($script:R.suspected | Where-Object class -eq 'closed-item')
        @($s | ForEach-Object { Split-Path $_.path -Leaf }) | Should -Be @('T-1')
        $s[0].reason | Should -BeLike '*closed on 2026-09-01*'
        $s[0].bytes  | Should -BeGreaterThan 0
    }

    It 'names a directory the backlog does not list, and not kingshand''s own' {
        @($script:R.suspected | Where-Object class -eq 'not-in-backlog' | ForEach-Object { Split-Path $_.path -Leaf }) |
            Should -Be @('T-3')
    }

    It 'names nothing about an open item' {
        @($script:R.suspected | Where-Object { $_.path -like '*T-4*' }).Count | Should -Be 0
    }

    It 'removes none of it' {
        Test-Path -LiteralPath (Join-Path $script:H 'data\T-1\brief.pass2.md') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:H 'data\T-3\report.md') | Should -BeTrue
    }

    It 'lists the files no index lists' {
        @($script:R.unindexed) | Should -Contain 'data\loose-note.md'
    }

    It 'says plainly in its printed form that a dry run removed nothing' {
        $lines = Format-DataTidyReport -Result (Invoke-Tidy $script:H)
        $lines[0] | Should -BeLike 'Dry run - nothing removed.*Pass -Apply*'
        ($lines -join "`n") | Should -BeLike '*Suspected, not deleted - brief-revision: 1*'
    }
}

Describe 'against the real backlog tool' {
    BeforeAll {
        $script:HasTool = [bool](Get-Command tasks-axi -ErrorAction SilentlyContinue)
    }

    # A throwaway .tasks.toml in the temp home, so the live backlog is never touched.
    It 'removes a closed item''s identical copy and keeps an open item''s' {
        if (-not $script:HasTool) {
            Set-ItResult -Skipped -Because 'tasks-axi is not on PATH'
            return
        }
        $h = New-Home
        Set-Content -LiteralPath (Join-Path $h '.tasks.toml') -Encoding utf8 -Value @(
            'backend = "markdown"', '', '[markdown]', 'path = "data/backlog.md"',
            'archive = "data/done-archive.md"', 'done_keep = 10')
        Push-Location $h
        try {
            tasks-axi add T-1 'closed work' | Out-Null
            tasks-axi done T-1 | Out-Null
            tasks-axi add T-2 'open work' | Out-Null
        } finally { Pop-Location }
        New-File (Join-Path $h 'data\spec.md') | Out-Null
        $closed = New-File (Join-Path $h 'data\T-1\read-first\spec.md')
        $open   = New-File (Join-Path $h 'data\T-2\read-first\spec.md')

        $r = Invoke-Tidy $h -Apply
        $r.backlog.readable | Should -BeTrue -Because $r.backlog.problem
        Test-Path -LiteralPath $closed | Should -BeFalse
        Test-Path -LiteralPath $open   | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $h 'data\backlog.md') | Should -BeTrue
    }
}
