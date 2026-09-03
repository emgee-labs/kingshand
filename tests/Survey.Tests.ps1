# Get-SurveySnapshot.ps1 is the one gather behind /survey, and the digest it feeds is only as
# honest as it is. Two properties matter more than any single field: it must never throw, because
# a catch-up that explodes leaves the user with nothing at the exact moment they asked where they
# left off; and it must never read or write the live fleet, because a status read that mutates
# state is not a status read. Every case below runs against its own throwaway root under
# TestDrive - the live data\projects.md, state\crew.json and data\<id>\ directories are never
# touched by this suite.

BeforeAll {
    $script:SnapshotScript = Join-Path (Split-Path $PSScriptRoot -Parent) 'bin\Get-SurveySnapshot.ps1'

    function New-Fixture {
        param([Parameter(Mandatory)][string]$Name)
        $root = Join-Path $TestDrive $Name
        New-Item -ItemType Directory -Force -Path (Join-Path $root 'data')  | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $root 'state') | Out-Null
        [pscustomobject]@{
            Root     = $root
            Registry = Join-Path $root 'data\projects.md'
            Data     = Join-Path $root 'data'
            State    = Join-Path $root 'state\crew.json'
        }
    }

    function Get-Snapshot {
        param([Parameter(Mandatory)]$Fixture)
        & $script:SnapshotScript -RegistryPath $Fixture.Registry -DataPath $Fixture.Data -StatePath $Fixture.State
    }

    # An entry is one line, with its indented path: line immediately after it.
    function Add-RegistryEntry {
        param(
            [Parameter(Mandatory)]$Fixture,
            [Parameter(Mandatory)][string]$Line,
            [Parameter(Mandatory)][string]$Path
        )
        if (-not (Test-Path $Fixture.Registry)) {
            Set-Content -Path $Fixture.Registry -Value '# Projects' -Encoding utf8
        }
        Add-Content -Path $Fixture.Registry -Encoding utf8 -Value @('', $Line, "      path: $Path")
    }

    function New-WorkDirectory {
        param(
            [Parameter(Mandatory)]$Fixture,
            [Parameter(Mandatory)][string]$Id,
            [switch]$WithBrief,
            [switch]$WithReport
        )
        $dir = Join-Path $Fixture.Data $Id
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        if ($WithBrief)  { Set-Content -Path (Join-Path $dir 'brief.md')  -Value '# brief'  -Encoding utf8 }
        if ($WithReport) { Set-Content -Path (Join-Path $dir 'report.md') -Value '# report' -Encoding utf8 }
        $dir
    }
}

Describe 'an empty fleet is a state, not a failure' {
    It 'returns a snapshot without throwing when there is no registry and no crew.json' {
        $f = New-Fixture 'empty'
        { Get-Snapshot $f } | Should -Not -Throw
    }

    It 'reports the registry as empty when the file does not exist' {
        $f = New-Fixture 'empty-noreg'
        $s = Get-Snapshot $f
        $s.registry.present | Should -BeFalse
        $s.registry.empty   | Should -BeTrue
        $s.registry.count   | Should -Be 0
    }

    It 'reports the registry as empty when the file exists but holds no entries' {
        $f = New-Fixture 'empty-header'
        Set-Content -Path $f.Registry -Value '# Projects' -Encoding utf8
        $s = Get-Snapshot $f
        $s.registry.present | Should -BeTrue
        $s.registry.empty   | Should -BeTrue
        $s.registry.count   | Should -Be 0
    }

    It 'reports an absent crew.json as no workers rather than as a fault' {
        $f = New-Fixture 'empty-crew'
        $s = Get-Snapshot $f
        $s.crew.present     | Should -BeFalse
        $s.crew.readable    | Should -BeTrue
        $s.crew.count       | Should -Be 0
        $s.diagnostics.Count | Should -Be 0
    }
}

Describe 'every registry entry is named with its posture' {
    BeforeAll {
        $script:Reg = New-Fixture 'registry'
        foreach ($n in @('alpha', 'beta', 'gamma')) {
            New-Item -ItemType Directory -Force -Path (Join-Path $script:Reg.Root "repos\$n") | Out-Null
        }
        Add-RegistryEntry $script:Reg '- alpha [direct-PR] - alpha repo (added 2026-01-01)' (Join-Path $script:Reg.Root 'repos\alpha')
        Add-RegistryEntry $script:Reg '- beta [no-mistakes +yolo] - beta repo (added 2026-01-02)' (Join-Path $script:Reg.Root 'repos\beta')
        Add-RegistryEntry $script:Reg '- gamma [no-mistakes-prod-only] - gamma repo (added 2026-01-03)' (Join-Path $script:Reg.Root 'repos\gamma')
        $script:RegSnap = Get-Snapshot $script:Reg
    }

    It 'lists all three entries' {
        $script:RegSnap.registry.count | Should -Be 3
        $script:RegSnap.registry.empty | Should -BeFalse
        @($script:RegSnap.registry.entries.name) | Should -Be @('alpha', 'beta', 'gamma')
    }

    It 'carries each entry''s registered mode' {
        $e = @($script:RegSnap.registry.entries)
        $e[0].rawMode | Should -Be 'direct-PR'
        $e[1].rawMode | Should -Be 'no-mistakes'
        $e[2].rawMode | Should -Be 'no-mistakes-prod-only'
    }

    It 'keeps rawMode distinct from the mechanically resolved mode' {
        $gamma = @($script:RegSnap.registry.entries | Where-Object { $_.name -eq 'gamma' })[0]
        $gamma.rawMode | Should -Be 'no-mistakes-prod-only'
        $gamma.mode    | Should -Be 'no-mistakes'
    }

    It 'carries yolo as the string on or off, never a boolean' {
        $e = @($script:RegSnap.registry.entries)
        $e[0].yolo | Should -Be 'off'
        $e[1].yolo | Should -Be 'on'
        $e[2].yolo | Should -Be 'off'
        foreach ($entry in $e) { $entry.yolo | Should -BeOfType [string] }
    }

    It 'records each entry''s path as present on disk' {
        foreach ($entry in @($script:RegSnap.registry.entries)) {
            $entry.pathExists | Should -BeTrue -Because "$($entry.name) was created under the fixture"
        }
    }
}

Describe 'a registered project whose path is gone is flagged' {
    It 'marks the missing path and leaves the present one alone' {
        $f = New-Fixture 'missing-path'
        New-Item -ItemType Directory -Force -Path (Join-Path $f.Root 'repos\here') | Out-Null
        Add-RegistryEntry $f '- here [local-only] - present repo (added 2026-01-01)' (Join-Path $f.Root 'repos\here')
        Add-RegistryEntry $f '- gone [local-only] - deleted repo (added 2026-01-02)' (Join-Path $f.Root 'repos\gone')

        $s = Get-Snapshot $f
        $here = @($s.registry.entries | Where-Object { $_.name -eq 'here' })[0]
        $gone = @($s.registry.entries | Where-Object { $_.name -eq 'gone' })[0]
        $here.pathExists | Should -BeTrue
        $gone.pathExists | Should -BeFalse
        $gone.path       | Should -Be (Join-Path $f.Root 'repos\gone')
    }
}

Describe 'a brief with no worker is un-dispatched work' {
    It 'lists a data directory holding brief.md with no crew.json entry' {
        $f = New-Fixture 'undispatched'
        New-WorkDirectory -Fixture $f -Id 'brief-skill' -WithBrief | Out-Null

        $s = Get-Snapshot $f
        $s.data.undispatchedCount | Should -Be 1
        $s.data.undispatched[0].id        | Should -Be 'brief-skill'
        $s.data.undispatched[0].briefPath | Should -Be (Join-Path $f.Data 'brief-skill\brief.md')
    }

    It 'ignores a data directory with no brief.md at all' {
        $f = New-Fixture 'undispatched-nobrief'
        New-WorkDirectory -Fixture $f -Id 'leftovers' | Out-Null

        (Get-Snapshot $f).data.undispatchedCount | Should -Be 0
    }

    It 'ignores directories beginning with an underscore' {
        $f = New-Fixture 'scratch'
        foreach ($scratch in @('_dispatch', '_context', '_coverage')) {
            New-WorkDirectory -Fixture $f -Id $scratch -WithBrief | Out-Null
        }
        New-WorkDirectory -Fixture $f -Id 'real-work' -WithBrief | Out-Null

        $s = Get-Snapshot $f
        $s.data.undispatchedCount | Should -Be 1
        @($s.data.undispatched.id) | Should -Be @('real-work')
    }

    # Regression. A work directory is named by TICKET - Dispatch-Worker takes -Name <ticket> while
    # the id is minted by the supervisor and is opaque. The skip originally compared a directory
    # name against worker ids, so it never matched and every dispatched worker's brief reported as
    # un-dispatched. Live on 2026-08-28: four dispatched workers, five un-dispatched briefs
    # reported, which invites dispatching work that is already running.
    #
    # The other fixtures in this file all name a directory with the same string used as the crew
    # key, so the broken comparison matched by coincidence and 381 tests passed against the bug.
    # This fixture keeps the two deliberately different, as real dispatches do.
    It 'skips a dispatched worker whose directory is named by ticket, not by id' {
        $f = New-Fixture 'ticket-named-dirs'
        New-WorkDirectory -Fixture $f -Id 'acme-low-med-email' -WithBrief | Out-Null
        New-WorkDirectory -Fixture $f -Id 'acme-repo-topology' -WithBrief | Out-Null
        New-WorkDirectory -Fixture $f -Id 'never-dispatched'    -WithBrief | Out-Null

        $crew = @{
            workers = @{
                'b0f00ff5' = @{ ticket = 'acme-low-med-email'; kind = 'adhoc'; repo = 'acme-manager'; stage = 'ready' }
                'bc6d6922' = @{ ticket = 'acme-repo-topology'; kind = 'adhoc'; repo = 'acme-manager'; stage = 'ready' }
            }
        }
        $crew | ConvertTo-Json -Depth 10 | Set-Content -Path $f.State -Encoding utf8

        $s = Get-Snapshot $f
        $s.data.undispatchedCount | Should -Be 1
        @($s.data.undispatched.id) | Should -Be @('never-dispatched')
    }

    It 'still skips a directory named by worker id, so a rename cannot resurrect the bug' {
        $f = New-Fixture 'id-named-dirs'
        New-WorkDirectory -Fixture $f -Id 'b0f00ff5'        -WithBrief | Out-Null
        New-WorkDirectory -Fixture $f -Id 'never-dispatched' -WithBrief | Out-Null

        $crew = @{ workers = @{ 'b0f00ff5' = @{ ticket = 'some-ticket'; kind = 'adhoc'; repo = 'r'; stage = 'ready' } } }
        $crew | ConvertTo-Json -Depth 10 | Set-Content -Path $f.State -Encoding utf8

        $s = Get-Snapshot $f
        @($s.data.undispatched.id) | Should -Be @('never-dispatched')
    }
}

Describe 'a malformed crew.json degrades rather than exploding' {
    BeforeAll {
        $script:Bad = New-Fixture 'malformed'
        New-Item -ItemType Directory -Force -Path (Join-Path $script:Bad.Root 'repos\alpha') | Out-Null
        Add-RegistryEntry $script:Bad '- alpha [direct-PR] - alpha repo (added 2026-01-01)' (Join-Path $script:Bad.Root 'repos\alpha')
        Set-Content -Path $script:Bad.State -Value '{ "workers": ' -Encoding utf8
    }

    It 'does not throw' {
        { Get-Snapshot $script:Bad } | Should -Not -Throw
    }

    It 'records a diagnostic naming crew.json' {
        $s = Get-Snapshot $script:Bad
        $s.crew.readable     | Should -BeFalse
        $s.diagnostics.Count | Should -BeGreaterThan 0
        @($s.diagnostics | Where-Object { $_ -like '*crew.json*' }).Count |
            Should -BeGreaterThan 0 -Because 'a failure must say which section it lost'
    }

    It 'still populates the registry the broken file did not touch' {
        $s = Get-Snapshot $script:Bad
        $s.registry.count           | Should -Be 1
        $s.registry.entries[0].name | Should -Be 'alpha'
    }
}

Describe 'a worker is joined with its durable report' {
    # One snapshot for the whole block: workers present means one liveness call through herdr,
    # and this is the only case in the suite that has any. The join itself, and herdr's state
    # vocabulary, are covered in CrewStatus.Tests.ps1 - here the point is only that intent and
    # the durable report survive whatever liveness answers.
    BeforeAll {
        $script:Fleet = New-Fixture 'fleet'
        New-WorkDirectory -Fixture $script:Fleet -Id 'w-reported' -WithBrief -WithReport | Out-Null
        New-WorkDirectory -Fixture $script:Fleet -Id 'w-silent'   -WithBrief | Out-Null

        $crew = @{
            workers = @{
                'w-reported' = @{ ticket = 'T-1001'; kind = 'ticket'; repo = 'acme-web'; stage = 'ready';       brief = 'data\w-reported\brief.md'; waiting_on = 'T-1001-shorter-hero-copy' }
                'w-silent'   = @{ ticket = 'T-1002'; kind = 'ticket'; repo = 'acme-api'; stage = 'implementing'; brief = 'data\w-silent\brief.md' }
            }
        }
        $crew | ConvertTo-Json -Depth 10 | Set-Content -Path $script:Fleet.State -Encoding utf8
        $script:FleetSnap = Get-Snapshot $script:Fleet
    }

    It 'reports both workers with their intent intact' {
        $script:FleetSnap.crew.readable | Should -BeTrue
        $script:FleetSnap.crew.count    | Should -Be 2
        $reported = @($script:FleetSnap.crew.workers | Where-Object { $_.id -eq 'w-reported' })[0]
        $reported.ticket | Should -Be 'T-1001'
        $reported.repo   | Should -Be 'acme-web'
        $reported.stage  | Should -Be 'ready'
    }

    It 'marks the worker whose report.md exists as having one' {
        $reported = @($script:FleetSnap.crew.workers | Where-Object { $_.id -eq 'w-reported' })[0]
        $reported.hasReport  | Should -BeTrue
        $reported.reportPath | Should -Be (Join-Path $script:Fleet.Data 'w-reported\report.md')
    }

    It 'marks the worker with no report.md as having none' {
        $silent = @($script:FleetSnap.crew.workers | Where-Object { $_.id -eq 'w-silent' })[0]
        $silent.hasReport | Should -BeFalse
    }

    # A worker parked on the King's own decision settles, so liveness reports it exactly as it
    # reports a finished one. The pointer is the only thing that separates them, so the snapshot
    # has to carry it or the digest is left guessing between finished and waiting on an answer.
    It 'carries the parked-decision pointer, which liveness cannot answer' {
        $parked = @($script:FleetSnap.crew.workers | Where-Object { $_.id -eq 'w-reported' })[0]
        $silent = @($script:FleetSnap.crew.workers | Where-Object { $_.id -eq 'w-silent' })[0]
        $parked.waitingOn | Should -Be 'T-1001-shorter-hero-copy'
        $silent.waitingOn | Should -Be '' -Because 'a worker parked on nothing has no key, not a missing field'
    }

    It 'does not call a dispatched brief un-dispatched work' {
        $script:FleetSnap.data.undispatchedCount | Should -Be 0
    }
}

Describe 'the snapshot reads the live fleet without changing it' {
    It 'writes nothing under the fixture it was pointed at' {
        $f = New-Fixture 'readonly'
        New-Item -ItemType Directory -Force -Path (Join-Path $f.Root 'repos\alpha') | Out-Null
        Add-RegistryEntry $f '- alpha [direct-PR] - alpha repo (added 2026-01-01)' (Join-Path $f.Root 'repos\alpha')
        New-WorkDirectory -Fixture $f -Id 'pending' -WithBrief | Out-Null
        Set-Content -Path $f.State -Value (@{ workers = @{} } | ConvertTo-Json) -Encoding utf8

        $before = Get-ChildItem -Path $f.Root -Recurse -File | Sort-Object FullName |
            ForEach-Object { "$($_.FullName)|$((Get-FileHash $_.FullName -Algorithm SHA256).Hash)" }
        Get-Snapshot $f | Out-Null
        $after = Get-ChildItem -Path $f.Root -Recurse -File | Sort-Object FullName |
            ForEach-Object { "$($_.FullName)|$((Get-FileHash $_.FullName -Algorithm SHA256).Hash)" }

        @($after) | Should -Be @($before) -Because 'a status read that mutates state is not a status read'
    }
}
