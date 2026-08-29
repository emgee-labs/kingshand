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
