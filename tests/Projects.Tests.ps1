BeforeAll {
    Import-Module "$PSScriptRoot\..\bin\Projects.psm1" -Force

    function New-TestRegistry {
        param([string]$Content)
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("reg-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $p = Join-Path $dir 'projects.md'
        Set-Content -Path $p -Value $Content -Encoding utf8
        $p
    }

    # Returns a named entry's WHOLE block - the entry line plus the indented path: line that
    # belongs to it - so a comparison can cover everything an append might disturb.
    function Get-EntryBlock {
        param([string]$Path, [string]$Name)
        $lines = @(Get-Content $Path)
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -like "- $Name *") {
                $block = @($lines[$i])
                if ($i + 1 -lt $lines.Count) { $block += $lines[$i + 1] }
                return , $block
            }
        }
        , @()
    }

    # A real directory every fixture can point at, so the on-disk path check passes.
    $script:RealPath = ([System.IO.Path]::GetTempPath()).TrimEnd('\')
}

Describe 'Get-ProjectPosture - mode parsing' {
    It 'parses <mode> with yolo off' -ForEach @(
        @{ mode = 'no-mistakes' }
        @{ mode = 'direct-PR' }
        @{ mode = 'local-only' }
    ) {
        $reg = New-TestRegistry @"
# Projects

- proj [$mode] - a project (added 2026-08-24)
      path: $script:RealPath
"@
        Get-ProjectPosture -Name proj -RegistryPath $reg | Should -Be "$mode off"
    }

    It 'parses <mode> with +yolo on' -ForEach @(
        @{ mode = 'no-mistakes' }
        @{ mode = 'direct-PR' }
        @{ mode = 'local-only' }
    ) {
        $reg = New-TestRegistry @"
# Projects

- proj [$mode +yolo] - a project (added 2026-08-24)
      path: $script:RealPath
"@
        Get-ProjectPosture -Name proj -RegistryPath $reg | Should -Be "$mode on"
    }

    It 'treats an entry with no bracket as no-mistakes off' {
        $reg = New-TestRegistry @"
- proj - a legacy entry (added 2026-08-24)
      path: $script:RealPath
"@
        Get-ProjectPosture -Name proj -RegistryPath $reg | Should -Be 'no-mistakes off'
    }
}

Describe 'Get-ProjectPosture - conditional policy' {
    BeforeEach {
        $script:reg = New-TestRegistry @"
- proj [no-mistakes-prod-only +yolo] - conditional (added 2026-08-24)
      path: $script:RealPath
"@
    }

    It 'maps the policy to its most rigorous leg for mechanical callers' {
        Get-ProjectPosture -Name proj -RegistryPath $script:reg | Should -Be 'no-mistakes on'
    }

    It 'returns the annotation unmapped with -Raw' {
        Get-ProjectPosture -Name proj -RegistryPath $script:reg -Raw |
            Should -Be 'no-mistakes-prod-only on'
    }
}

Describe 'Get-ProjectPosture - typos fail safe' {
    It 'warns and resets to no-mistakes off on an unknown mode' {
        $reg = New-TestRegistry @"
- proj [no-mstakes +yolo] - typo in the mode (added 2026-08-24)
      path: $script:RealPath
"@
        $w = @()
        $r = Get-ProjectPosture -Name proj -RegistryPath $reg -WarningVariable w -WarningAction SilentlyContinue
        $r | Should -Be 'no-mistakes off'
        $w.Count | Should -BeGreaterThan 0
    }

    It 'warns and leaves yolo off on an unknown autonomy token' {
        $reg = New-TestRegistry @"
- proj [direct-PR +yolo2] - typo in the flag (added 2026-08-24)
      path: $script:RealPath
"@
        $w = @()
        $r = Get-ProjectPosture -Name proj -RegistryPath $reg -WarningVariable w -WarningAction SilentlyContinue
        $r | Should -Be 'direct-PR off'
        $w.Count | Should -BeGreaterThan 0
    }
}

Describe 'Get-ProjectEntry - refusals' {
    It 'refuses when the registry file is absent' {
        { Get-ProjectEntry -Name proj -RegistryPath 'C:\nope\projects.md' } | Should -Throw '*registry*'
    }

    It 'refuses when the project is absent from the registry' {
        $reg = New-TestRegistry @"
- other [local-only] - a different project (added 2026-08-24)
      path: $script:RealPath
"@
        { Get-ProjectEntry -Name proj -RegistryPath $reg } | Should -Throw '*not registered*'
    }

    It 'refuses when the path line is missing' {
        $reg = New-TestRegistry '- proj [local-only] - no path line (added 2026-08-24)'
        { Get-ProjectEntry -Name proj -RegistryPath $reg } | Should -Throw '*path*'
    }

    It 'refuses when the recorded path is not on disk' {
        $reg = New-TestRegistry @"
- proj [local-only] - points nowhere (added 2026-08-24)
      path: C:\definitely\not\here
"@
        { Get-ProjectEntry -Name proj -RegistryPath $reg } | Should -Throw '*not exist*'
    }
}

Describe 'Get-ProjectEntry - fields' {
    It 'returns every field' {
        $reg = New-TestRegistry @"
- acme-api [direct-PR +yolo] - Acme .NET API (added 2026-08-24)
      path: $script:RealPath
"@
        $e = Get-ProjectEntry -Name acme-api -RegistryPath $reg
        $e.name        | Should -Be 'acme-api'
        $e.path        | Should -Be $script:RealPath
        $e.mode        | Should -Be 'direct-PR'
        $e.rawMode     | Should -Be 'direct-PR'
        $e.yolo        | Should -Be 'on'
        $e.added       | Should -Be '2026-08-24'
        $e.description | Should -BeLike 'Acme .NET API*'
    }

    It 'keeps rawMode distinct from mode for a conditional policy' {
        $reg = New-TestRegistry @"
- proj [no-mistakes-prod-only] - conditional (added 2026-08-24)
      path: $script:RealPath
"@
        $e = Get-ProjectEntry -Name proj -RegistryPath $reg
        $e.mode    | Should -Be 'no-mistakes'
        $e.rawMode | Should -Be 'no-mistakes-prod-only'
    }

    It 'does not let a hyphen or bracket in the description corrupt the parse' {
        $reg = New-TestRegistry @"
- proj [local-only] - a desc - with a hyphen and [brackets] (added 2026-08-24; raised from direct-PR)
      path: $script:RealPath
"@
        $e = Get-ProjectEntry -Name proj -RegistryPath $reg
        $e.mode        | Should -Be 'local-only'
        # Backtick-escape the brackets: -BeLike uses wildcard matching, where a bare [brackets]
        # is a character class (matching one of b/r/a/c/k/e/t/s), not the literal substring.
        $e.description | Should -BeLike '*hyphen and `[brackets`]*'
    }
}

Describe 'Get-ProjectEntry - multi-entry registry' {
    BeforeAll {
        $script:multiReg = New-TestRegistry @"
# Projects

- one [local-only] - first project (added 2026-08-24)
      path: $script:RealPath

- two [direct-PR] - second project (added 2026-08-24)
      path: $script:RealPath

- three [no-mistakes +yolo] - third project (added 2026-08-24)
      path: $script:RealPath
"@
    }

    It 'returns only the requested entry for the first one in the file' {
        $e = Get-ProjectEntry -Name one -RegistryPath $script:multiReg
        $e.name | Should -Be 'one'
        $e.mode | Should -Be 'local-only'
        $e.yolo | Should -Be 'off'
    }

    It 'returns only the requested entry for the middle one in the file' {
        $e = Get-ProjectEntry -Name two -RegistryPath $script:multiReg
        $e.name | Should -Be 'two'
        $e.mode | Should -Be 'direct-PR'
        $e.yolo | Should -Be 'off'
    }

    It 'returns only the requested entry for the last one in the file' {
        $e = Get-ProjectEntry -Name three -RegistryPath $script:multiReg
        $e.name | Should -Be 'three'
        $e.mode | Should -Be 'no-mistakes'
        $e.yolo | Should -Be 'on'
    }

    It 'returns the correct posture string for a middle entry' {
        Get-ProjectPosture -Name two -RegistryPath $script:multiReg | Should -Be 'direct-PR off'
    }

    It 'refuses an absent name even when the registry has multiple entries' {
        { Get-ProjectEntry -Name four -RegistryPath $script:multiReg } | Should -Throw '*not registered*'
    }
}

Describe 'Get-AllProjects' {
    It 'lists every entry without validating paths' {
        $reg = New-TestRegistry @"
# Projects

- one [local-only] - first (added 2026-08-24)
      path: C:\does\not\exist

- two [direct-PR +yolo] - second (added 2026-08-24)
      path: $script:RealPath
"@
        $all = Get-AllProjects -RegistryPath $reg
        $all.Count | Should -Be 2
        $all[0].name | Should -Be 'one'
        $all[1].yolo | Should -Be 'on'
    }

    It 'returns an empty array for a registry with no entries' {
        $reg = New-TestRegistry '# Projects'
        # Plain parens, not @(...): wrapping a leading-comma return in @() at the call site
        # re-nests it into a 1-element array (see Crew.Tests.ps1's Get-CrewByStage empty case,
        # which uses the same (cmd).Count form for the same reason).
        (Get-AllProjects -RegistryPath $reg).Count | Should -Be 0
    }
}

Describe 'Add-ProjectEntry' {
    BeforeEach {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("addreg-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $script:reg = Join-Path $dir 'projects.md'
    }

    It 'creates the registry with a heading when absent' {
        Add-ProjectEntry -Name proj -Path $script:RealPath -Mode 'local-only' `
                         -Description 'a project' -RegistryPath $script:reg
        (Get-Content $script:reg -Raw) | Should -BeLike '# Projects*'
    }

    It 'round-trips every field' {
        Add-ProjectEntry -Name acme-api -Path $script:RealPath -Mode 'direct-PR' -Yolo `
                         -Description 'Acme .NET API' -RegistryPath $script:reg
        $e = Get-ProjectEntry -Name acme-api -RegistryPath $script:reg
        $e.name    | Should -Be 'acme-api'
        $e.path    | Should -Be $script:RealPath
        $e.mode    | Should -Be 'direct-PR'
        $e.yolo    | Should -Be 'on'
        $e.added   | Should -Be (Get-Date -Format 'yyyy-MM-dd')
    }

    It 'defaults yolo to off when the switch is absent' {
        Add-ProjectEntry -Name proj -Path $script:RealPath -Mode 'direct-PR' `
                         -Description 'd' -RegistryPath $script:reg
        (Get-ProjectEntry -Name proj -RegistryPath $script:reg).yolo | Should -Be 'off'
    }

    It 'refuses a duplicate name' {
        Add-ProjectEntry -Name proj -Path $script:RealPath -Mode 'local-only' `
                         -Description 'd' -RegistryPath $script:reg
        { Add-ProjectEntry -Name proj -Path $script:RealPath -Mode 'local-only' `
                           -Description 'd' -RegistryPath $script:reg } | Should -Throw '*already registered*'
    }

    It 'refuses the same path under a different name' {
        Add-ProjectEntry -Name one -Path $script:RealPath -Mode 'local-only' `
                         -Description 'd' -RegistryPath $script:reg
        { Add-ProjectEntry -Name two -Path $script:RealPath -Mode 'local-only' `
                           -Description 'd' -RegistryPath $script:reg } | Should -Throw '*same path*'
    }

    It 'refuses an invalid mode' {
        { Add-ProjectEntry -Name proj -Path $script:RealPath -Mode 'nonsense' `
                           -Description 'd' -RegistryPath $script:reg } | Should -Throw '*mode*'
    }

    # Every durable file written for a project is indexed at data\index\<name>.md, so a name the
    # index cannot turn into a file name is a project nothing can ever index. It used to register
    # happily and then fail each index write one brief at a time, after the brief was on disk.
    It 'refuses a name the index cannot resolve to a file, and registers nothing' {
        $err = { Add-ProjectEntry -Name '@acme/web' -Path $script:RealPath -Mode 'local-only' `
                                  -Description 'd' -RegistryPath $script:reg } | Should -Throw -PassThru
        $err.Exception.Message | Should -BeLike "*letters, digits, '.', '_' and '-'*"
        $err.Exception.Message |
            Should -BeLike '*-acme-web*' -Because 'the message has to offer a name that would work'
        Test-Path -LiteralPath $script:reg |
            Should -BeFalse -Because 'a refused name must leave no entry and no registry behind'
    }

    It 'accepts the slug-shaped names the index can resolve' {
        foreach ($name in @('acme-api', 'acme_api', 'acme.api', 'Acme123')) {
            Add-ProjectEntry -Name $name -Path (Join-Path $script:RealPath $name) -Mode 'local-only' `
                             -Description 'd' -RegistryPath $script:reg
        }
        @(Get-AllProjects -RegistryPath $script:reg | ForEach-Object { $_.name }) |
            Should -Be @('acme-api', 'acme_api', 'acme.api', 'Acme123')
    }

    It 'refuses the same path written with a trailing separator' {
        Add-ProjectEntry -Name one -Path $script:RealPath -Mode 'local-only' `
                         -Description 'd' -RegistryPath $script:reg
        { Add-ProjectEntry -Name two -Path ($script:RealPath + '\') -Mode 'local-only' `
                           -Description 'd' -RegistryPath $script:reg } | Should -Throw '*same path*'
    }

    # Add-ProjectEntry stamps `(added <date>)` itself. A caller that also wrote one used to
    # produce a doubled date on the entry line, which is how two live registry entries ended up
    # reading "(added 2026-08-25) (added 2026-08-25)". These assert on the exact line written.
    It 'writes one date only when the description already ends in one' {
        Add-ProjectEntry -Name proj -Path $script:RealPath -Mode 'local-only' `
                         -Description 'a project (added 2026-01-01)' -RegistryPath $script:reg
        $line  = (Get-EntryBlock -Path $script:reg -Name 'proj')[0]
        $today = Get-Date -Format 'yyyy-MM-dd'
        $line | Should -Be "- proj [local-only] - a project (added $today)"
        ([regex]::Matches($line, '\(added\s')).Count |
            Should -Be 1 -Because 'the caller-supplied date is stripped, not appended to'
    }

    It 'strips a trailing date written with no space before it' {
        Add-ProjectEntry -Name proj -Path $script:RealPath -Mode 'direct-PR' `
                         -Description 'a project(added 2026-01-01)' -RegistryPath $script:reg
        $today = Get-Date -Format 'yyyy-MM-dd'
        (Get-EntryBlock -Path $script:reg -Name 'proj')[0] |
            Should -Be "- proj [direct-PR] - a project (added $today)"
    }

    It 'keeps an (added ...) that appears mid-description' {
        # Posture-change history lives mid-description and is legitimate. Only a trailing
        # stamp is the function's own duplicate.
        Add-ProjectEntry -Name proj -Path $script:RealPath -Mode 'local-only' `
                         -Description 'tooling (added 2026-08-24); gate not initialised' `
                         -RegistryPath $script:reg
        $line  = (Get-EntryBlock -Path $script:reg -Name 'proj')[0]
        $today = Get-Date -Format 'yyyy-MM-dd'
        $line | Should -Be ("- proj [local-only] - tooling (added 2026-08-24); " +
                            "gate not initialised (added $today)")
        ([regex]::Matches($line, '\(added\s')).Count | Should -Be 2
    }

    It 'leaves a description carrying no date of its own unaffected' {
        Add-ProjectEntry -Name proj -Path $script:RealPath -Mode 'no-mistakes' `
                         -Description 'Acme .NET API' -RegistryPath $script:reg
        $today = Get-Date -Format 'yyyy-MM-dd'
        (Get-EntryBlock -Path $script:reg -Name 'proj')[0] |
            Should -Be "- proj [no-mistakes] - Acme .NET API (added $today)"
    }

    It 'still round-trips through Get-ProjectEntry after stripping' {
        Add-ProjectEntry -Name proj -Path $script:RealPath -Mode 'local-only' `
                         -Description 'a project (added 2026-01-01)' -RegistryPath $script:reg
        $e = Get-ProjectEntry -Name proj -RegistryPath $script:reg
        $e.added       | Should -Be (Get-Date -Format 'yyyy-MM-dd')
        $e.description | Should -Be "a project (added $(Get-Date -Format 'yyyy-MM-dd'))"
    }

    It 'leaves an existing entry byte-identical when adding a second' {
        $other = Join-Path ([System.IO.Path]::GetTempPath()) ("other-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $other -Force | Out-Null
        Add-ProjectEntry -Name one -Path $script:RealPath -Mode 'local-only' `
                         -Description 'first' -RegistryPath $script:reg
        # The whole block, not just the name line. An append that disturbed the indented
        # `path:` line beneath an existing entry would leave its name line untouched, and a
        # check that looked only at `- one*` would pass while the entry no longer resolved.
        $before = Get-EntryBlock -Path $script:reg -Name 'one'
        $before.Count | Should -Be 2
        $before[1]    | Should -Be "      path: $script:RealPath"
        Add-ProjectEntry -Name two -Path $other -Mode 'direct-PR' `
                         -Description 'second' -RegistryPath $script:reg
        (Get-EntryBlock -Path $script:reg -Name 'one') | Should -Be $before
    }
}

Describe 'Test-ProjectImportable' {
    BeforeAll {
        # Every directory this block puts in the OS temp directory is recorded here so AfterAll
        # can remove it. The path is recorded before the directory is created, so a git failure
        # part way through still leaves a removable trail.
        $script:TempFixtures = [System.Collections.Generic.List[string]]::new()

        function New-TempFixturePath {
            param([Parameter(Mandatory)][string]$Prefix)
            $p = Join-Path ([System.IO.Path]::GetTempPath()) ($Prefix + [guid]::NewGuid().ToString('N'))
            $script:TempFixtures.Add($p)
            $p
        }

        function New-TempRepo {
            param([switch]$WithOrigin)
            $d = New-TempFixturePath -Prefix 'repo-'
            git init -b main $d -q
            if ($WithOrigin) {
                $bare = "$d-remote.git"
                $script:TempFixtures.Add($bare)
                git init --bare -b main $bare -q
                git -C $d remote add origin $bare
            }
            $d
        }
    }

    # Runs even when an It above fails or throws, so fixtures never accumulate.
    AfterAll {
        foreach ($p in $script:TempFixtures) {
            if (Test-Path -LiteralPath $p) {
                Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        $script:TempFixtures.Clear()
    }

    It 'refuses a path that does not exist' {
        $r = Test-ProjectImportable -Path 'C:\definitely\not\here' -Mode 'local-only'
        $r.ok     | Should -BeFalse
        $r.reason | Should -BeLike '*does not exist*'
    }

    It 'refuses a directory that is not a git repository' {
        $d = New-TempFixturePath -Prefix 'plain-'
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        $r = Test-ProjectImportable -Path $d -Mode 'local-only'
        $r.ok     | Should -BeFalse
        $r.reason | Should -BeLike '*not a git repository*'
    }

    It 'accepts a git repository with no remote for local-only' {
        $r = Test-ProjectImportable -Path (New-TempRepo) -Mode 'local-only'
        $r.ok        | Should -BeTrue
        $r.hasOrigin | Should -BeFalse
    }

    It 'refuses <mode> when there is no origin remote' -ForEach @(
        @{ mode = 'no-mistakes' }
        @{ mode = 'direct-PR' }
        @{ mode = 'no-mistakes-prod-only' }
    ) {
        $r = Test-ProjectImportable -Path (New-TempRepo) -Mode $mode
        $r.ok     | Should -BeFalse
        $r.reason | Should -BeLike '*origin remote*'
    }

    It 'accepts <mode> when an origin remote exists' -ForEach @(
        @{ mode = 'no-mistakes' }
        @{ mode = 'direct-PR' }
        @{ mode = 'no-mistakes-prod-only' }
    ) {
        $r = Test-ProjectImportable -Path (New-TempRepo -WithOrigin) -Mode $mode
        $r.ok        | Should -BeTrue
        $r.hasOrigin | Should -BeTrue
    }

    It 'leaves LASTEXITCODE at 0 after accepting a repository with no origin' {
        # The internal `git remote get-url origin` probe exits 2 on a repository with no origin,
        # which is a normal outcome for local-only. A caller must not read that as a failure.
        $repo = New-TempRepo
        $global:LASTEXITCODE = 0
        $r = Test-ProjectImportable -Path $repo -Mode 'local-only'
        $r.ok         | Should -BeTrue
        $r.hasOrigin  | Should -BeFalse
        $LASTEXITCODE | Should -Be 0
    }

    It 'leaves LASTEXITCODE at 0 after refusing a path that does not exist' {
        $global:LASTEXITCODE = 0
        $r = Test-ProjectImportable -Path 'C:\definitely\not\here' -Mode 'local-only'
        $r.ok         | Should -BeFalse
        $LASTEXITCODE | Should -Be 0
    }

    It 'refuses an invalid mode and names it alongside the valid ones' {
        $r = Test-ProjectImportable -Path (New-TempRepo) -Mode 'nonsense-mode'
        $r.ok        | Should -BeFalse
        $r.hasOrigin | Should -BeFalse
        $r.reason    | Should -Be ("Invalid mode 'nonsense-mode'. Must be one of: " +
                                   'no-mistakes, direct-PR, local-only, no-mistakes-prod-only')
    }

    It 'refuses an empty-ish mode rather than treating it as local-only' {
        $r = Test-ProjectImportable -Path (New-TempRepo) -Mode ' '
        $r.ok     | Should -BeFalse
        $r.reason | Should -BeLike 'Invalid mode*'
    }
}
