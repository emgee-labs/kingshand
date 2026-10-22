#Requires -Version 7.0
Set-StrictMode -Version Latest

# bin\Dependencies.psm1 is exercised with no network, no npm and no herdr. Each narrow reader - npm's
# JSON, a binary's version line, a web document, herdr's own version - is mocked inside the module,
# so every case below drives the public functions with exactly the answer a tool could give.

BeforeAll {
    Import-Module "$PSScriptRoot\..\bin\Dependencies.psm1" -Force

    $script:RepoRoot = Resolve-Path "$PSScriptRoot\.."

    $script:Digest = 'd2c6c9c971c43a0bfdde8c692a9a1a7a45c3e4807cd01ae45662b4734fac1cbf'

    # A manifest written to a directory of its own, with whatever entries a case needs.
    function New-PinRoot {
        param([Parameter(Mandatory)][AllowEmptyString()][string]$Json)
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'dependencies.json') -Value $Json -Encoding utf8
        $dir
    }

    $script:HerdrEntry = "`"herdr`":{`"source`":`"herdr`",`"version`":`"0.9.5`",`"protocol`":22,`"sha256`":{`"windows-x86_64`":`"$($script:Digest)`"}}"
    $script:NpmEntry   = '"tasks-axi":{"source":"npm","package":"tasks-axi","version":"0.2.6"}'
    $script:GhEntry    = '"no-mistakes":{"source":"github","repository":"acme/no-mistakes","version":"1.84.0"}'
    $script:MinEntry   = '"claude-code":{"source":"npm","package":"@acme/cli","minimum":"2.1.307"}'
}

Describe 'the tracked manifest' {
    It 'pins herdr 0.9.5, protocol 22, with its Windows digest' {
        $pins = Read-DependencyPins -Path (Join-Path $script:RepoRoot 'dependencies.json')
        $h = @($pins | Where-Object name -eq 'herdr')[0]
        $h.version  | Should -Be '0.9.5'
        $h.protocol | Should -Be 22
        Get-HerdrPinnedDigest -Pin $h | Should -Be $script:Digest
    }

    It 'pins every dependency the release depends on, and Claude Code by minimum only' {
        $pins = Read-DependencyPins -Path (Join-Path $script:RepoRoot 'dependencies.json')
        @($pins.name) | Should -Be @('herdr', 'no-mistakes', 'lavish-axi', 'tasks-axi', 'quota-axi', 'claude-code')
        $c = @($pins | Where-Object name -eq 'claude-code')[0]
        $c.minimum | Should -Not -BeNullOrEmpty
        $c.version | Should -BeNullOrEmpty -Because 'it updates itself, so only a floor is pinned'
        @($pins | Where-Object { $_.name -ne 'claude-code' -and -not $_.version }).Count | Should -Be 0
    }
}

Describe 'Read-DependencyPins refuses a manifest it cannot trust, by name' {
    It 'refuses <why>' -ForEach @(
        @{ why = 'a missing file';                 json = $null }
        @{ why = 'text that is not JSON';          json = '{ not json' }
        @{ why = 'an unknown source';              json = '{"x":{"source":"pip","version":"1.0.0"}}' }
        @{ why = 'both version and minimum';       json = '{"x":{"source":"npm","package":"x","version":"1.0.0","minimum":"1.0.0"}}' }
        @{ why = 'neither version nor minimum';    json = '{"x":{"source":"npm","package":"x"}}' }
        @{ why = 'a version that is not three numbers'; json = '{"x":{"source":"npm","package":"x","version":"latest"}}' }
        @{ why = 'an npm entry with no package';   json = '{"x":{"source":"npm","version":"1.0.0"}}' }
        @{ why = 'a GitHub entry with no repository'; json = '{"x":{"source":"github","version":"1.0.0"}}' }
        @{ why = 'a herdr entry with no protocol'; json = '{"herdr":{"source":"herdr","version":"0.9.5","sha256":{"windows-x86_64":"' + ('a' * 64) + '"}}}' }
        @{ why = 'a herdr entry with no Windows digest'; json = '{"herdr":{"source":"herdr","version":"0.9.5","protocol":22,"sha256":{"linux-x86_64":"' + ('a' * 64) + '"}}}' }
    ) {
        $path = if ($null -eq $json) { Join-Path $TestDrive 'absent\dependencies.json' }
                else { Join-Path (New-PinRoot -Json $json) 'dependencies.json' }
        { Read-DependencyPins -Path $path } | Should -Throw
    }

    It 'names the entry that is wrong' {
        $root = New-PinRoot -Json '{"lavish-axi":{"source":"npm","version":"1.0.0"}}'
        { Read-DependencyPins -Path (Join-Path $root 'dependencies.json') } | Should -Throw "*'lavish-axi'*"
    }
}

Describe 'ConvertTo-DependencyVersion reads three numbers and nothing else' {
    It 'reads <text> as <expected>' -ForEach @(
        @{ text = '0.9.5';      expected = '0.9.5' }
        @{ text = 'v1.84.0';    expected = '1.84.0' }
        @{ text = ' 2.1.307 ';  expected = '2.1.307' }
    ) {
        "$(ConvertTo-DependencyVersion -Text $text)" | Should -Be $expected
    }

    It 'reads <text> as no version at all' -ForEach @(
        @{ text = '' }, @{ text = '1.2' }, @{ text = '1.0.0-rc1' }, @{ text = 'latest' }
    ) {
        ConvertTo-DependencyVersion -Text $text | Should -BeNullOrEmpty
    }
}

Describe 'Test-DependencyMoveBreaking marks a move that may break a caller' {
    It '<from> to <to> is breaking: <expected>' -ForEach @(
        @{ from = '1.84.0'; to = '1.90.2'; expected = $false }
        @{ from = '1.84.0'; to = '2.0.0';  expected = $true }
        @{ from = '0.9.5';  to = '0.9.6';  expected = $false }
        @{ from = '0.9.5';  to = '0.10.0'; expected = $true }
        @{ from = '0.0.3';  to = '0.0.4';  expected = $true }
    ) {
        Test-DependencyMoveBreaking -From $from -To $to | Should -Be $expected
    }

    It 'calls a herdr protocol change breaking whatever the version says' {
        Test-DependencyMoveBreaking -From '0.9.5' -To '0.9.6' -FromProtocol 22 -ToProtocol 23 | Should -BeTrue
    }

    It 'answers nothing, rather than false, when a version could not be read' {
        Test-DependencyMoveBreaking -From '0.9.5' -To '' | Should -BeNullOrEmpty
    }
}

Describe 'Get-InstalledDependencyVersion reads each version from the tool that owns it' {
    BeforeAll {
        $pins = Read-DependencyPins -Path (Join-Path (New-PinRoot -Json "{$($script:HerdrEntry),$($script:NpmEntry),$($script:GhEntry),$($script:MinEntry)}") 'dependencies.json')
        $script:PinHerdr = $pins[0]; $script:PinNpm = $pins[1]; $script:PinGh = $pins[2]; $script:PinMin = $pins[3]
        $script:FakeRoot = Join-Path $TestDrive 'install'
    }

    Context 'herdr' {
        It 'reads the version herdr reports, and knows the copy under this root''s tools\ as its own' {
            $exe = Join-Path $script:FakeRoot 'tools\herdr\herdr.exe'
            Mock -ModuleName Dependencies Get-HerdrVersion { [pscustomobject]@{ version = '0.8.2'; protocol = 20; path = $exe; detail = '' } }
            $r = Get-InstalledDependencyVersion -Pin $script:PinHerdr -Root $script:FakeRoot
            $r.found   | Should -BeTrue
            $r.version | Should -Be '0.8.2'
            $r.bundled | Should -BeTrue
        }

        It 'does not claim a herdr under another installation''s tools\ as its own' {
            Mock -ModuleName Dependencies Get-HerdrVersion {
                [pscustomobject]@{ version = '0.8.2'; protocol = 20; path = (Join-Path $TestDrive 'other\tools\herdr\herdr.exe'); detail = '' }
            }
            (Get-InstalledDependencyVersion -Pin $script:PinHerdr -Root $script:FakeRoot).bundled | Should -BeFalse
        }

        It 'reads a herdr whose version could not be read as unreadable, not as any version' {
            Mock -ModuleName Dependencies Get-HerdrVersion { [pscustomobject]@{ version = $null; protocol = $null; path = 'C:\x\herdr.exe'; detail = 'no client version' } }
            $r = Get-InstalledDependencyVersion -Pin $script:PinHerdr -Root $script:FakeRoot
            $r.found   | Should -BeTrue
            $r.version | Should -BeNullOrEmpty
            $r.detail  | Should -Match 'no client version'
        }

        It 'reads no herdr as not installed' {
            Mock -ModuleName Dependencies Get-HerdrVersion { [pscustomobject]@{ version = $null; protocol = $null; path = $null; detail = 'herdr was not found' } }
            (Get-InstalledDependencyVersion -Pin $script:PinHerdr -Root $script:FakeRoot).found | Should -BeFalse
        }
    }

    Context 'the review gate' {
        BeforeEach { Mock -ModuleName Dependencies Get-NoMistakesCommandPath { 'C:\x\no-mistakes.exe' } }

        It 'reads the version out of its one version line' {
            Mock -ModuleName Dependencies Read-VersionLine { 'no-mistakes version v1.84.0 (4822244) 2026-09-26T08:30:47Z' }
            (Get-InstalledDependencyVersion -Pin $script:PinGh -Root $script:FakeRoot).version | Should -Be '1.84.0'
        }

        It 'reads a line that names no version as unreadable' {
            Mock -ModuleName Dependencies Read-VersionLine { 'error: unknown flag --version' }
            $r = Get-InstalledDependencyVersion -Pin $script:PinGh -Root $script:FakeRoot
            $r.version | Should -BeNullOrEmpty
            $r.detail  | Should -Match 'names no version'
        }
    }

    Context 'an npm package' {
        BeforeEach { Mock -ModuleName Dependencies Get-NpmCommand { 'C:\x\npm.cmd' } }

        It 'reads the version npm lists' {
            Mock -ModuleName Dependencies Invoke-NpmJson { '{"dependencies":{"tasks-axi":{"version":"0.2.5"}}}' | ConvertFrom-Json }
            $r = Get-InstalledDependencyVersion -Pin $script:PinNpm -Root $script:FakeRoot
            $r.found   | Should -BeTrue
            $r.version | Should -Be '0.2.5'
        }

        It 'reads a package npm does not list as not installed' {
            Mock -ModuleName Dependencies Invoke-NpmJson { '{"name":"npm"}' | ConvertFrom-Json }
            (Get-InstalledDependencyVersion -Pin $script:PinNpm -Root $script:FakeRoot).found | Should -BeFalse
        }

        It 'says it could not tell when npm answered nothing readable' {
            Mock -ModuleName Dependencies Invoke-NpmJson { $null }
            $r = Get-InstalledDependencyVersion -Pin $script:PinNpm -Root $script:FakeRoot
            $r.found  | Should -BeNullOrEmpty -Because 'nothing readable is not the same as not installed'
            $r.detail | Should -Match 'nothing readable'
        }

        It 'says it could not tell when there is no npm at all' {
            Mock -ModuleName Dependencies Get-NpmCommand { $null }
            $r = Get-InstalledDependencyVersion -Pin $script:PinNpm -Root $script:FakeRoot
            $r.found  | Should -BeNullOrEmpty
            $r.detail | Should -Match 'npm is not on PATH'
        }
    }

    Context 'the agent CLI, pinned by minimum' {
        It 'asks the binary itself, which may not have come from npm' {
            Mock -ModuleName Dependencies Get-ClaudeCommandPath { 'C:\x\cli.exe' }
            Mock -ModuleName Dependencies Read-VersionLine { '2.1.310 (Acme CLI)' }
            Mock -ModuleName Dependencies Invoke-NpmJson { throw 'npm must not be asked' }
            $pin = [pscustomobject]@{ name = 'claude-code'; source = 'npm'; package = '@acme/cli'; minimum = '2.1.307'; version = $null }
            (Get-InstalledDependencyVersion -Pin $pin -Root $script:FakeRoot).version | Should -Be '2.1.310'
        }
    }
}

Describe 'Get-DependencyPinStatus sets every pin against what is installed' {
    BeforeAll {
        $script:StatusRoot = New-PinRoot -Json "{$($script:HerdrEntry),$($script:NpmEntry),$($script:GhEntry),$($script:MinEntry)}"
    }

    It 'calls <installed> against a pin of <name> <state>' -ForEach @(
        @{ name = 'herdr';       installed = '0.9.5';   found = $true;  state = 'current' }
        @{ name = 'herdr';       installed = '0.8.2';   found = $true;  state = 'behind' }
        @{ name = 'herdr';       installed = '0.9.6';   found = $true;  state = 'ahead' }
        @{ name = 'herdr';       installed = $null;     found = $false; state = 'missing' }
        @{ name = 'herdr';       installed = $null;     found = $true;  state = 'unreadable' }
        @{ name = 'tasks-axi';   installed = $null;     found = $null;  state = 'unreadable' }
        @{ name = 'claude-code'; installed = '2.1.400'; found = $true;  state = 'satisfied' }
        @{ name = 'claude-code'; installed = '2.1.307'; found = $true;  state = 'satisfied' }
        @{ name = 'claude-code'; installed = '2.1.200'; found = $true;  state = 'behind' }
    ) {
        $script:CaseVersion = $installed
        $script:CaseFound   = $found
        Mock -ModuleName Dependencies Get-InstalledDependencyVersion {
            [pscustomobject]@{ found = $script:CaseFound; version = $script:CaseVersion; path = 'C:\x'; bundled = $true; detail = 'read failed' }
        }

        $row = @(Get-DependencyPinStatus -Root $script:StatusRoot | Where-Object name -eq $name)[0]
        $row.state | Should -Be $state
    }

    It 'gives each row the command that moves it' {
        Mock -ModuleName Dependencies Get-InstalledDependencyVersion {
            [pscustomobject]@{ found = $true; version = '0.0.1'; path = 'C:\x'; bundled = $true; detail = '' }
        }
        $rows = @(Get-DependencyPinStatus -Root $script:StatusRoot)
        @($rows | Where-Object name -eq 'tasks-axi')[0].command | Should -Be 'npm install -g tasks-axi@0.2.6'
        @($rows | Where-Object name -eq 'herdr')[0].command     | Should -Be '.\install.ps1 -SyncPins'
        @($rows | Where-Object name -eq 'claude-code')[0].command | Should -Be 'claude update'
    }
}

Describe 'Get-DependencySyncCommand never moves a dependency past its pin' {
    It 'installs an npm package at exactly its pinned version' {
        $pin = [pscustomobject]@{ name = 'lavish-axi'; source = 'npm'; package = 'lavish-axi'; version = '0.1.90'; minimum = $null }
        Get-DependencySyncCommand -Pin $pin | Should -Be 'npm install -g lavish-axi@0.1.90'
    }
}

Describe 'Test-HerdrReplaceable lets herdr be replaced only under a stopped server' {
    It 'allows it when the server is stopped' {
        Mock -ModuleName Dependencies Get-HerdrServerState { [pscustomobject]@{ state = 'stopped'; detail = ''; compatible = $null } }
        (Test-HerdrReplaceable).ok | Should -BeTrue
    }

    It 'refuses while the server is running, and says how to stop it' {
        Mock -ModuleName Dependencies Get-HerdrServerState { [pscustomobject]@{ state = 'running'; detail = ''; compatible = $true } }
        $r = Test-HerdrReplaceable
        $r.ok     | Should -BeFalse
        $r.reason | Should -Match 'is running'
        $r.reason | Should -Match 'herdr server stop'
    }

    It 'refuses when whether it is running could not be read' {
        Mock -ModuleName Dependencies Get-HerdrServerState { [pscustomobject]@{ state = 'unknown'; detail = 'answered nothing at all'; compatible = $null } }
        $r = Test-HerdrReplaceable
        $r.ok     | Should -BeFalse
        $r.reason | Should -Match 'could not be read - answered nothing at all'
    }
}

Describe 'the weekly pin report' {
    BeforeAll {
        $script:ReportRoot = New-PinRoot -Json "{$($script:HerdrEntry),$($script:NpmEntry),$($script:GhEntry)}"
    }

    It 'reads herdr''s latest version and protocol from latest.json' {
        Mock -ModuleName Dependencies Invoke-WebJson { '{"version":"0.9.6","protocol":23}' | ConvertFrom-Json }
        $pin = (Read-DependencyPins -Path (Join-Path $script:ReportRoot 'dependencies.json'))[0]
        $p = Get-PublishedDependencyVersion -Pin $pin
        $p.version  | Should -Be '0.9.6'
        $p.protocol | Should -Be 23
    }

    It 'reports, per pin, the latest version, where it stands and whether it breaks' {
        Mock -ModuleName Dependencies Invoke-WebJson {
            if ($Uri -like '*herdr.dev*') { '{"version":"0.9.6","protocol":23}' | ConvertFrom-Json }
            else { '{"tag_name":"v1.90.0"}' | ConvertFrom-Json }
        }
        Mock -ModuleName Dependencies Invoke-NpmJson { '"0.2.6"' | ConvertFrom-Json }

        $rows = @(Get-DependencyPinReport -Root $script:ReportRoot)
        $h = @($rows | Where-Object name -eq 'herdr')[0]
        $h.latest   | Should -Be '0.9.6'
        $h.move     | Should -Be 'newer'
        $h.breaking | Should -BeTrue -Because 'the protocol moved from 22 to 23'

        $g = @($rows | Where-Object name -eq 'no-mistakes')[0]
        $g.latest   | Should -Be '1.90.0'
        $g.breaking | Should -BeFalse

        $n = @($rows | Where-Object name -eq 'tasks-axi')[0]
        $n.move | Should -Be 'none'
    }

    It 'reports a latest version it could not read as unknown, and says why' {
        Mock -ModuleName Dependencies Invoke-WebJson { throw 'offline' }
        Mock -ModuleName Dependencies Invoke-NpmJson { $null }

        $rows = @(Get-DependencyPinReport -Root $script:ReportRoot)
        foreach ($r in $rows) {
            $r.latest   | Should -BeNullOrEmpty
            $r.move     | Should -Be 'unknown'
            $r.breaking | Should -BeNullOrEmpty
            $r.detail   | Should -Not -BeNullOrEmpty
        }
        @($rows | Where-Object name -eq 'herdr')[0].detail | Should -Match 'offline'
    }

    It 'writes nothing' {
        Mock -ModuleName Dependencies Invoke-WebJson { '{"version":"0.9.5","protocol":22,"tag_name":"v1.84.0"}' | ConvertFrom-Json }
        Mock -ModuleName Dependencies Invoke-NpmJson { '"0.2.6"' | ConvertFrom-Json }
        $before = @(Get-ChildItem -LiteralPath $script:ReportRoot -Recurse -File | ForEach-Object { "$($_.FullName) $($_.Length) $($_.LastWriteTimeUtc.Ticks)" })

        $null = Get-DependencyPinReport -Root $script:ReportRoot

        @(Get-ChildItem -LiteralPath $script:ReportRoot -Recurse -File | ForEach-Object { "$($_.FullName) $($_.Length) $($_.LastWriteTimeUtc.Ticks)" }) |
            Should -Be $before
    }

    It 'is what bin\Update-DependencyPins.ps1 runs, against the root it is given' {
        $bad = New-PinRoot -Json '{"x":{"source":"pip","version":"1.0.0"}}'
        { & "$PSScriptRoot\..\bin\Update-DependencyPins.ps1" -Root $bad } | Should -Throw "*'x'*"
    }
}
