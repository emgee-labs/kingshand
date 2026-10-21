#Requires -Version 7.0
Set-StrictMode -Version Latest

# Every case here runs against throwaway fixtures under $TestDrive. NOTHING in this file reads or
# writes the real ~\.claude.json - that file is the user's own Claude Code configuration, and it
# carries the whole list of projects they have ever opened. Every Grant-ClaudeFolderTrust call
# below passes -ConfigPath at a fixture, and a case that forgot to would be editing the machine
# the suite happens to be running on.

BeforeAll {
    Import-Module "$PSScriptRoot\..\bin\ClaudeWorkspace.psm1" -Force

    function New-CaseDir {
        $d = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $d | Out-Null
        $d
    }

    function New-ConfigFixture {
        param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Json)
        $dir = Split-Path -Parent $Path
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
        }
        [System.IO.File]::WriteAllText($Path, $Json)
        $Path
    }

    # Read back through JsonNode, the same way the module writes, because that is the only reader
    # that preserves two keys differing only in case. ConvertFrom-Json refuses such a file outright
    # and -AsHashtable silently merges them - either would make the case-preservation test below
    # pass or fail for the wrong reason.
    function Get-ConfigProjects {
        param([Parameter(Mandatory)][string]$Path)
        $root = [System.Text.Json.Nodes.JsonNode]::Parse([System.IO.File]::ReadAllText($Path))
        # Wrapped in the leading-comma idiom on purpose. A JsonObject is enumerable, so returning
        # it bare makes PowerShell unroll it into loose key/value pairs - and an unrolled map
        # cannot be indexed by key, which is the only reason this reads the file at all.
        , $root['projects']
    }

    function Get-ProjectKeys {
        param([Parameter(Mandatory)][string]$Path)
        @((Get-ConfigProjects -Path $Path).GetEnumerator() | ForEach-Object { $_.Key })
    }
}

Describe 'Set-WorkerWorkspaceSettings writes the two grants that used to be command-line flags' {
    # herdr cannot pass arguments to claude on Windows, so `--permission-mode bypassPermissions`
    # and `--add-dir <briefdir>` have nowhere to go but the worktree's own settings.local.json.
    # A worker whose directory was not prepared stops at the first permission prompt with nobody
    # there to answer it.

    BeforeEach {
        $script:Worktree = New-CaseDir
        $script:Settings = Join-Path $script:Worktree '.claude\settings.local.json'
    }

    It 'writes .claude\settings.local.json into the worktree and returns its path' {
        $returned = Set-WorkerWorkspaceSettings -WorktreePath $script:Worktree -AdditionalDirectories @('D:\briefs\t-9001')
        $returned | Should -Be $script:Settings
        Test-Path -LiteralPath $script:Settings -PathType Leaf | Should -BeTrue
    }

    It 'sets permissions.defaultMode to bypassPermissions' {
        Set-WorkerWorkspaceSettings -WorktreePath $script:Worktree -AdditionalDirectories @('D:\briefs\t-9001') | Out-Null
        $json = Get-Content -LiteralPath $script:Settings -Raw | ConvertFrom-Json
        $json.permissions.defaultMode | Should -Be 'bypassPermissions'
    }

    It 'carries every additional directory it was given' {
        $dirs = @('D:\briefs\t-9001', 'D:\shared\reference')
        Set-WorkerWorkspaceSettings -WorktreePath $script:Worktree -AdditionalDirectories $dirs | Out-Null
        $json = Get-Content -LiteralPath $script:Settings -Raw | ConvertFrom-Json
        @($json.permissions.additionalDirectories) | Should -Be $dirs
    }

    It 'writes additionalDirectories as an array even for a single directory' {
        # A one-element list that serialises as a bare string is a settings file Claude Code reads
        # as malformed, and the worker then cannot reach its brief at all.
        Set-WorkerWorkspaceSettings -WorktreePath $script:Worktree -AdditionalDirectories @('D:\briefs\t-9001') | Out-Null
        $raw = Get-Content -LiteralPath $script:Settings -Raw
        $raw | Should -Match '"additionalDirectories"\s*:\s*\['
    }

    It 'writes an empty array when no additional directory was given' {
        Set-WorkerWorkspaceSettings -WorktreePath $script:Worktree | Out-Null
        $json = Get-Content -LiteralPath $script:Settings -Raw | ConvertFrom-Json
        $json.permissions.defaultMode | Should -Be 'bypassPermissions'
        @($json.permissions.additionalDirectories).Count | Should -Be 0
    }

    It 'creates the .claude directory itself - a worktree is a fresh checkout that has none' {
        Test-Path -LiteralPath (Join-Path $script:Worktree '.claude') | Should -BeFalse
        Set-WorkerWorkspaceSettings -WorktreePath $script:Worktree | Out-Null
        Test-Path -LiteralPath (Join-Path $script:Worktree '.claude') -PathType Container | Should -BeTrue
    }

    It 'overwrites a previous settings file rather than merging into it' {
        Set-WorkerWorkspaceSettings -WorktreePath $script:Worktree -AdditionalDirectories @('D:\first') | Out-Null
        Set-WorkerWorkspaceSettings -WorktreePath $script:Worktree -AdditionalDirectories @('D:\second') | Out-Null
        $json = Get-Content -LiteralPath $script:Settings -Raw | ConvertFrom-Json
        @($json.permissions.additionalDirectories) | Should -Be @('D:\second')
    }

    It 'throws rather than creating a worktree that does not exist' {
        # Writing into a path git never created would leave a directory nothing owns and a worker
        # that appears prepared while its checkout is absent.
        $absent = Join-Path $TestDrive 'no-such-worktree'
        { Set-WorkerWorkspaceSettings -WorktreePath $absent } | Should -Throw '*Worktree not found*'
        Test-Path -LiteralPath $absent | Should -BeFalse
    }

    It 'names the missing worktree in the refusal' {
        $absent = Join-Path $TestDrive 'also-no-such-worktree'
        $err = $null
        try { Set-WorkerWorkspaceSettings -WorktreePath $absent } catch { $err = $_.Exception.Message }
        $err | Should -Not -BeNullOrEmpty
        $err.Contains($absent) | Should -BeTrue -Because 'the reader has to know which path was wrong'
    }
}

Describe 'Grant-ClaudeFolderTrust records one worktree as trusted' {
    # A fresh worktree is a directory Claude Code has never seen, so an unattended worker stops on
    # the folder-trust dialog and herdr reports agent_not_ready while the agent sits blocked. The
    # grant is pre-seeded before launch instead: a written, inspectable record that cannot race,
    # rather than a synthetic keystroke sent blind at a security prompt.

    BeforeEach {
        $script:Case   = New-CaseDir
        $script:Config = Join-Path $script:Case '.claude.json'
    }

    It 'writes the key with FORWARD SLASHES, which is how Claude Code stores it' {
        New-ConfigFixture -Path $script:Config -Json '{"projects":{"D:/repo":{"hasTrustDialogAccepted":true}}}' | Out-Null

        $r = Grant-ClaudeFolderTrust -Path 'D:\repo\.claude\worktrees\t-9001' -ConfigPath $script:Config
        $r.granted | Should -BeTrue
        $r.reason  | Should -Be 'written'
        $r.key     | Should -Be 'D:/repo/.claude/worktrees/t-9001'
        $r.key     | Should -Not -Match '\\' -Because 'a backslash key is simply never matched by Claude Code'

        $keys = Get-ProjectKeys -Path $script:Config
        $keys | Should -Contain 'D:/repo/.claude/worktrees/t-9001'
    }

    It 'marks the new entry as having accepted the trust dialog' {
        New-ConfigFixture -Path $script:Config -Json '{"projects":{"D:/repo":{}}}' | Out-Null
        Grant-ClaudeFolderTrust -Path 'D:\repo\wt' -ConfigPath $script:Config | Out-Null
        $projects = Get-ConfigProjects -Path $script:Config
        [bool]$projects['D:/repo/wt']['hasTrustDialogAccepted'] | Should -BeTrue
    }

    It 'leaves every project that was already there alone' {
        New-ConfigFixture -Path $script:Config `
            -Json '{"projects":{"D:/one":{"a":1},"D:/two":{"b":2}},"other":"kept"}' | Out-Null

        Grant-ClaudeFolderTrust -Path 'D:\three' -ConfigPath $script:Config | Out-Null

        $keys = Get-ProjectKeys -Path $script:Config
        $keys.Count | Should -Be 3
        $keys | Should -Contain 'D:/one'
        $keys | Should -Contain 'D:/two'

        # Top-level settings outside `projects` belong to the user too, and an edit that dropped
        # them would take their whole Claude Code configuration with it.
        $root = [System.Text.Json.Nodes.JsonNode]::Parse([System.IO.File]::ReadAllText($script:Config))
        [string]$root['other'] | Should -Be 'kept'
    }

    It 'is idempotent: a second call reports already and duplicates nothing' {
        New-ConfigFixture -Path $script:Config -Json '{"projects":{"D:/repo":{}}}' | Out-Null

        $first = Grant-ClaudeFolderTrust -Path 'D:\repo\wt' -ConfigPath $script:Config
        $first.reason | Should -Be 'written'
        $afterFirst = Get-ProjectKeys -Path $script:Config

        $second = Grant-ClaudeFolderTrust -Path 'D:\repo\wt' -ConfigPath $script:Config
        $second.granted | Should -BeTrue
        $second.reason  | Should -Be 'already'
        $second.key     | Should -Be 'D:/repo/wt'

        $afterSecond = Get-ProjectKeys -Path $script:Config
        $afterSecond.Count | Should -Be $afterFirst.Count
        @($afterSecond | Where-Object { $_ -eq 'D:/repo/wt' }).Count |
            Should -Be 1 -Because 'a re-dispatch into the same worktree must not grow the file'
    }

    It 'treats a trailing separator as the same worktree, not a second one' {
        New-ConfigFixture -Path $script:Config -Json '{"projects":{"D:/repo":{}}}' | Out-Null
        Grant-ClaudeFolderTrust -Path 'D:\repo\wt'  -ConfigPath $script:Config | Out-Null
        $second = Grant-ClaudeFolderTrust -Path 'D:\repo\wt\' -ConfigPath $script:Config
        $second.reason | Should -Be 'already'
        (Get-ProjectKeys -Path $script:Config).Count | Should -Be 2
    }

    It 'returns granted=$false with reason no-config rather than inventing a config file' {
        # No ~\.claude.json means Claude Code has never run here. Writing one on its behalf would
        # be guessing at a schema nobody has seen; the worker stops at the dialog and dispatch
        # reports that plainly instead.
        Test-Path -LiteralPath $script:Config | Should -BeFalse

        $r = Grant-ClaudeFolderTrust -Path 'D:\repo\wt' -ConfigPath $script:Config
        $r.granted | Should -BeFalse
        $r.reason  | Should -Be 'no-config'
        $r.key     | Should -BeNullOrEmpty

        Test-Path -LiteralPath $script:Config |
            Should -BeFalse -Because 'the absent config must still be absent afterwards'
    }

    It 'returns granted=$false with reason no-projects when the config has no projects map' {
        New-ConfigFixture -Path $script:Config -Json '{"other":"kept"}' | Out-Null
        $r = Grant-ClaudeFolderTrust -Path 'D:\repo\wt' -ConfigPath $script:Config
        $r.granted | Should -BeFalse
        $r.reason  | Should -Be 'no-projects'
        $r.key     | Should -Be 'D:/repo/wt'
    }

    It 'leaves no temp file behind' {
        New-ConfigFixture -Path $script:Config -Json '{"projects":{"D:/repo":{}}}' | Out-Null
        Grant-ClaudeFolderTrust -Path 'D:\repo\wt' -ConfigPath $script:Config | Out-Null
        Test-Path -LiteralPath "$($script:Config).kingshand-tmp" | Should -BeFalse
    }
}

Describe 'Grant-ClaudeFolderTrust preserves two keys that differ only in case' {
    # THE CASE THIS MODULE'S JsonNode CODE EXISTS FOR. A real ~\.claude.json can hold the same
    # directory twice under keys differing only in drive-letter case - 'D:/code' and 'd:/code' -
    # because Windows treats the paths as one and JSON does not. A PowerShell hashtable round trip
    # would silently merge them and destroy user data; this test is what stops someone
    # "simplifying" the JsonNode code back to `ConvertFrom-Json -AsHashtable`.
    #
    # The failure is silent and total: -AsHashtable merges the pair, the file is written back with
    # one of the two gone, and the user loses that project's history to save four lines of code.
    # Plain ConvertFrom-Json refuses outright with "keys with different casing", which is the same
    # hazard announcing itself rather than hiding.

    BeforeEach {
        $script:Case   = New-CaseDir
        $script:Config = Join-Path $script:Case '.claude.json'
        New-ConfigFixture -Path $script:Config -Json (
            '{"projects":{' +
            '"D:/foo":{"hasTrustDialogAccepted":true,"marker":"upper"},' +
            '"d:/foo":{"hasTrustDialogAccepted":true,"marker":"lower"}}}') | Out-Null
    }

    It 'both keys are still there after the edit' {
        Grant-ClaudeFolderTrust -Path 'D:\repo\wt' -ConfigPath $script:Config | Out-Null

        $keys = Get-ProjectKeys -Path $script:Config
        $keys | Should -Contain 'D:/foo'
        $keys | Should -Contain 'd:/foo'
        $keys | Should -Contain 'D:/repo/wt'
        $keys.Count | Should -Be 3 -Because 'a hashtable round trip would have merged the pair into one'
    }

    It 'each of the two keeps its own distinct contents' {
        Grant-ClaudeFolderTrust -Path 'D:\repo\wt' -ConfigPath $script:Config | Out-Null

        $projects = Get-ConfigProjects -Path $script:Config
        [string]$projects['D:/foo']['marker'] | Should -Be 'upper'
        [string]$projects['d:/foo']['marker'] | Should -Be 'lower'
    }

    It 'a PowerShell hashtable really does merge them, which is why this is not done that way' {
        # Asserted rather than asserted-about. If a future PowerShell made hashtable keys
        # case-sensitive, this case fails and tells the next reader that the constraint changed -
        # far better than a comment claiming a hazard that no longer exists.
        $h = @{}
        $h['D:/foo'] = 'upper'
        $h['d:/foo'] = 'lower'
        $h.Keys.Count | Should -Be 1 -Because 'PowerShell hashtable keys are case-insensitive'
    }

    It 'ConvertFrom-Json refuses the same file outright, so it is no substitute either' {
        $raw = [System.IO.File]::ReadAllText($script:Config)
        { $raw | ConvertFrom-Json } |
            Should -Throw -Because 'the plain reader announces the hazard instead of hiding it'
    }
}

# A worker in the project's own checkout, with no worktree. The settings file there is the King's,
# so it is edited rather than written, its original is recorded before the first change, and it is
# put back exactly at cleanup - or deleted, where there was none. Each case below is one of the
# things that went wrong when this was done by hand.
Describe 'the permission file in a checkout is backed up, edited and put back' {
    BeforeAll {
        function Set-Original {
            param([Parameter(Mandatory)][string]$Text)
            New-Item -ItemType Directory -Force -Path (Split-Path $script:Settings -Parent) | Out-Null
            [System.IO.File]::WriteAllText($script:Settings, $Text)
        }
    }

    BeforeEach {
        $script:Checkout = New-CaseDir
        $script:Settings = Join-Path $script:Checkout '.claude\settings.local.json'
        $script:Record   = Join-Path (New-CaseDir) 'checkout-settings.json'
    }

    It 'keeps the existing allow list and every other key, and adds the two grants' {
        Set-Original '{ "permissions": { "allow": ["Bash(npm test)"] }, "env": { "A": "1" } }'
        $plan = New-CheckoutSettingsPlan -CheckoutPath $script:Checkout -RecordPath $script:Record `
                    -AdditionalDirectories @('D:\data\acme-api-session')
        $null = Set-CheckoutWorkerSettings -Plan $plan
        $json = Get-Content -LiteralPath $script:Settings -Raw | ConvertFrom-Json
        @($json.permissions.allow)                 | Should -Be @('Bash(npm test)')
        $json.env.A                                | Should -Be '1'
        $json.permissions.defaultMode              | Should -Be 'bypassPermissions'
        @($json.permissions.additionalDirectories) | Should -Be @('D:\data\acme-api-session')
    }

    It 'adds the brief directory once, beside directories the file already granted' {
        Set-Original '{ "permissions": { "additionalDirectories": ["D:\\shared", "D:\\brief"] } }'
        $plan = New-CheckoutSettingsPlan -CheckoutPath $script:Checkout -RecordPath $script:Record `
                    -AdditionalDirectories @('D:\brief')
        $null = Set-CheckoutWorkerSettings -Plan $plan
        $json = Get-Content -LiteralPath $script:Settings -Raw | ConvertFrom-Json
        @($json.permissions.additionalDirectories) | Should -Be @('D:\shared', 'D:\brief')
    }

    It 'never writes allow: [null] where there was no allow list' {
        $plan = New-CheckoutSettingsPlan -CheckoutPath $script:Checkout -RecordPath $script:Record `
                    -AdditionalDirectories @('D:\brief')
        $null = Set-CheckoutWorkerSettings -Plan $plan
        $json = Get-Content -LiteralPath $script:Settings -Raw | ConvertFrom-Json
        $json.permissions.PSObject.Properties.Name | Should -Not -Contain 'allow'
    }

    It 'refuses a settings file that is not JSON, and writes nothing' {
        Set-Original '{ "permissions": '
        { New-CheckoutSettingsPlan -CheckoutPath $script:Checkout -RecordPath $script:Record } |
            Should -Throw '*not valid JSON*'
        Test-Path -LiteralPath $script:Record | Should -BeFalse
        [System.IO.File]::ReadAllText($script:Settings) | Should -Be '{ "permissions": '
    }

    It 'refuses a settings file that is not a JSON object' {
        Set-Original '[1, 2]'
        { New-CheckoutSettingsPlan -CheckoutPath $script:Checkout -RecordPath $script:Record } |
            Should -Throw '*does not hold a JSON object*'
    }

    It 'refuses a settings file that cannot be read rather than building from the failure' {
        Set-Original '{ "permissions": { "allow": ["Bash(ls)"] } }'
        $lock = [System.IO.File]::Open($script:Settings, 'Open', 'ReadWrite', 'None')
        try {
            { New-CheckoutSettingsPlan -CheckoutPath $script:Checkout -RecordPath $script:Record } |
                Should -Throw '*could not be read*'
        } finally { $lock.Dispose() }
        Test-Path -LiteralPath $script:Record | Should -BeFalse
    }

    # The record is the only copy of the original. A second dispatch into an un-cleaned checkout
    # would otherwise record the first worker's edit as the original and lose the King's file.
    It 'refuses to overwrite a record it did not just write' {
        Set-Original '{ "a": 1 }'
        $plan = New-CheckoutSettingsPlan -CheckoutPath $script:Checkout -RecordPath $script:Record
        $null = Set-CheckoutWorkerSettings -Plan $plan
        $before = [System.IO.File]::ReadAllText($script:Record)
        { New-CheckoutSettingsPlan -CheckoutPath $script:Checkout -RecordPath $script:Record } |
            Should -Throw '*record already exists*'
        { Set-CheckoutWorkerSettings -Plan $plan } | Should -Throw '*could not be created*'
        [System.IO.File]::ReadAllText($script:Record) | Should -Be $before
    }

    It 'restores the original byte for byte and removes the record' {
        $original = "{`r`n  // a comment of the owner's`r`n  `"permissions`": { `"allow`": [`"Bash(ls)`"] }`r`n}`r`n"
        Set-Original $original
        $plan = New-CheckoutSettingsPlan -CheckoutPath $script:Checkout -RecordPath $script:Record `
                    -AdditionalDirectories @('D:\brief')
        $null = Set-CheckoutWorkerSettings -Plan $plan
        [System.IO.File]::ReadAllText($script:Settings) | Should -Not -Be $original

        $r = Restore-CheckoutWorkerSettings -RecordPath $script:Record
        $r.action | Should -Be 'restored'
        [System.IO.File]::ReadAllText($script:Settings) | Should -Be $original
        Test-Path -LiteralPath $script:Record | Should -BeFalse
    }

    It 'deletes the file, and the .claude directory it made, where neither existed before' {
        $plan = New-CheckoutSettingsPlan -CheckoutPath $script:Checkout -RecordPath $script:Record
        $null = Set-CheckoutWorkerSettings -Plan $plan
        Test-Path -LiteralPath $script:Settings | Should -BeTrue

        $r = Restore-CheckoutWorkerSettings -RecordPath $script:Record
        $r.action | Should -Be 'deleted'
        Test-Path -LiteralPath $script:Settings | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:Checkout '.claude') | Should -BeFalse
    }

    It 'leaves a .claude directory that existed before, with its other files' {
        New-Item -ItemType Directory -Force -Path (Join-Path $script:Checkout '.claude') | Out-Null
        Set-Content -Path (Join-Path $script:Checkout '.claude\settings.json') -Value '{}'
        $plan = New-CheckoutSettingsPlan -CheckoutPath $script:Checkout -RecordPath $script:Record
        $null = Set-CheckoutWorkerSettings -Plan $plan
        $null = Restore-CheckoutWorkerSettings -RecordPath $script:Record
        Test-Path -LiteralPath $script:Settings | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:Checkout '.claude\settings.json') | Should -BeTrue
    }

    It 'refuses to restore with no record, because nothing says whether a file existed' {
        Set-Original '{ "a": 1 }'
        { Restore-CheckoutWorkerSettings -RecordPath $script:Record } |
            Should -Throw '*no permission-file record*'
        [System.IO.File]::ReadAllText($script:Settings) | Should -Be '{ "a": 1 }'
    }

    It 'refuses a record it cannot parse, and changes nothing' {
        Set-Original '{ "a": 1 }'
        Set-Content -LiteralPath $script:Record -Value '{ not json'
        { Restore-CheckoutWorkerSettings -RecordPath $script:Record } | Should -Throw '*could not be read*'
        [System.IO.File]::ReadAllText($script:Settings) | Should -Be '{ "a": 1 }'
    }

    It 'refuses a record that does not say plainly whether a file existed' {
        @{ settingsPath = $script:Settings; existed = 'yes'; claudeDirCreated = $false; original = $null } |
            ConvertTo-Json | Set-Content -LiteralPath $script:Record
        { Restore-CheckoutWorkerSettings -RecordPath $script:Record } |
            Should -Throw '*does not say plainly*'
    }

    It 'refuses a record whose copy of the original is unreadable' {
        @{ settingsPath = $script:Settings; existed = $true; claudeDirCreated = $false; original = '%%%' } |
            ConvertTo-Json | Set-Content -LiteralPath $script:Record
        { Restore-CheckoutWorkerSettings -RecordPath $script:Record } |
            Should -Throw '*copy of that file is unreadable*'
    }

    # A record is a file anyone could edit, and a cleanup that deletes whatever it names would
    # delete a file it never wrote.
    It 'refuses a record naming anything but a .claude\settings.local.json' {
        $victim = Join-Path $script:Checkout 'important.txt'
        Set-Content -LiteralPath $victim -Value 'keep me'
        @{ settingsPath = $victim; existed = $false; claudeDirCreated = $false; original = $null } |
            ConvertTo-Json | Set-Content -LiteralPath $script:Record
        { Restore-CheckoutWorkerSettings -RecordPath $script:Record } | Should -Throw '*is not a .claude*'
        Test-Path -LiteralPath $victim | Should -BeTrue
    }
}

Describe 'Stop-CheckoutWorker cleans up a checkout worker and never touches the branch or checkout' {
    BeforeEach {
        $script:Checkout = New-CaseDir
        $script:Settings = Join-Path $script:Checkout '.claude\settings.local.json'
        $script:Data     = New-CaseDir
        $script:Record   = Join-Path $script:Data 'acme-api-session\checkout-settings.json'
        New-Item -ItemType Directory -Force -Path (Split-Path $script:Settings -Parent) | Out-Null
        [System.IO.File]::WriteAllText($script:Settings, '{ "permissions": { "allow": ["Bash(ls)"] } }')
        $plan = New-CheckoutSettingsPlan -CheckoutPath $script:Checkout -RecordPath $script:Record
        $null = Set-CheckoutWorkerSettings -Plan $plan
        Set-Content -LiteralPath (Join-Path $script:Checkout 'work.txt') -Value 'the work'
    }

    It 'stops the worker, discards its pane and puts the settings back, in that order' {
        $script:order = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName ClaudeWorkspace Stop-HerdrAgent {
            $script:order.Add('stop')
            [pscustomobject]@{ stopped = $true; paneId = 'p7'; paneReusable = $true }
        }
        Mock -ModuleName ClaudeWorkspace Remove-HerdrPane { $script:order.Add("pane $PaneId") }

        $r = Stop-CheckoutWorker -Name 'acme-api-session' -RecordPath $script:Record -DataPath $script:Data
        @($script:order) | Should -Be @('stop', 'pane p7')
        $r.settings | Should -Be 'restored'
        [System.IO.File]::ReadAllText($script:Settings) |
            Should -Be '{ "permissions": { "allow": ["Bash(ls)"] } }'
        Test-Path -LiteralPath $script:Record | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:Checkout 'work.txt') | Should -BeTrue
    }

    It 'leaves the pane and the settings in place when the worker does not stop' {
        Mock -ModuleName ClaudeWorkspace Stop-HerdrAgent { [pscustomobject]@{ stopped = $false; paneId = 'p7' } }
        Mock -ModuleName ClaudeWorkspace Remove-HerdrPane { }
        { Stop-CheckoutWorker -Name 'acme-api-session' -RecordPath $script:Record -DataPath $script:Data } |
            Should -Throw '*did not stop*'
        Should -Invoke -ModuleName ClaudeWorkspace Remove-HerdrPane -Times 0
        Test-Path -LiteralPath $script:Record | Should -BeTrue
    }

    It 'stops nothing when the record cannot be read' {
        Set-Content -LiteralPath $script:Record -Value 'garbage'
        Mock -ModuleName ClaudeWorkspace Stop-HerdrAgent { [pscustomobject]@{ stopped = $true; paneId = 'p7' } }
        { Stop-CheckoutWorker -Name 'acme-api-session' -RecordPath $script:Record -DataPath $script:Data } |
            Should -Throw '*could not be read*'
        Should -Invoke -ModuleName ClaudeWorkspace Stop-HerdrAgent -Times 0
    }
}
