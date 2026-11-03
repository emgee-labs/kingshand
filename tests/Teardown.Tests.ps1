#Requires -Version 7.0
Set-StrictMode -Version Latest

# bin\Teardown.psm1 against real git repositories in TestDrive, each with a bare repository as its
# remote, and with herdr faked: the herdr functions the module calls are mocked over one
# in-memory picture of agents, panes and workspaces, so a pane closed by the code under test is
# gone from the next read exactly as it would be from herdr's.

BeforeAll {
    Import-Module "$PSScriptRoot\..\bin\Teardown.psm1" -Force
    Import-Module "$PSScriptRoot\..\bin\Crew.psm1" -Force

    function Invoke-Git {
        param([string]$Dir, [Parameter(ValueFromRemainingArguments)][string[]]$Rest)
        $out = & git -C $Dir @Rest 2>&1
        if ($LASTEXITCODE -ne 0) { throw "git $($Rest -join ' ') failed: $out" }
        $out
    }

    # A project with one commit pushed to its remote, a registry naming it, an empty crew record
    # and a data folder - everything a cleanup reads, and nothing from the real installation.
    function New-Fixture {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8))
        $remote = Join-Path $root 'remote.git'
        $repo = Join-Path $root 'acme-api'
        $null = New-Item -ItemType Directory -Force -Path $root
        $null = & git init --bare -q $remote 2>&1
        $null = & git init -q -b main $repo 2>&1
        Invoke-Git $repo config user.email 't@example.com' | Out-Null
        Invoke-Git $repo config user.name 't' | Out-Null
        Set-Content -LiteralPath (Join-Path $repo 'readme.md') -Value 'x'
        Invoke-Git $repo add -A | Out-Null
        Invoke-Git $repo commit -q -m init | Out-Null
        Invoke-Git $repo remote add origin $remote | Out-Null
        Invoke-Git $repo push -q origin main | Out-Null

        $data = Join-Path $root 'data'
        $null = New-Item -ItemType Directory -Force -Path $data
        $registry = Join-Path $data 'projects.md'
        Set-Content -LiteralPath $registry -Value @("- acme-api [local-only] - a test project", "  path: $repo")
        $statePath = Join-Path $root 'state\crew.json'
        Save-CrewState -State (New-CrewState) -Path $statePath

        [pscustomobject]@{ root = $root; repo = $repo; data = $data; registry = $registry; state = $statePath }
    }

    # A worker copy the way dispatch makes one, recorded in crew.json with a brief on disk.
    function New-WorkerCopy {
        param($F, [string]$Name, [string]$Stage = 'ready', [string]$PaneId = '', [switch]$Push, [switch]$NoRecord)
        $copy = Join-Path $F.repo ".claude\worktrees\$Name"
        Invoke-Git $F.repo worktree add -q -b "worktree-$Name" $copy main | Out-Null
        Set-Content -LiteralPath (Join-Path $copy 'work.txt') -Value $Name
        Invoke-Git $copy add -A | Out-Null
        Invoke-Git $copy commit -q -m "work $Name" | Out-Null
        if ($Push) { Invoke-Git $copy push -q origin "worktree-$Name" | Out-Null }

        $brief = Join-Path $F.data "$Name\brief.md"
        $null = New-Item -ItemType Directory -Force -Path (Split-Path $brief)
        Set-Content -LiteralPath $brief -Value 'brief'
        if (-not $NoRecord) {
            $s = Import-CrewState -Path $F.state
            $rec = @{
                State = $s; WorkerId = $Name; Ticket = $Name; Kind = 'adhoc'; Repo = 'acme-api'
                Worktree = $copy; Branch = "worktree-$Name"; Brief = $brief; Base = 'origin/main'
            }
            if ($PaneId) { $rec.PaneId = $PaneId }
            Add-CrewWorker @rec
            Set-CrewStage -State $s -WorkerId $Name -Stage $Stage
            Save-CrewState -State $s -Path $F.state
        }
        (Resolve-Path $copy).Path
    }

    # The fake herdr: one picture, read by the inventories and changed by the closes and stops.
    function Reset-FakeHerdr {
        $script:Herdr = @{
            agents = [System.Collections.Generic.List[object]]::new()
            panes = [System.Collections.Generic.List[object]]::new()
            workspaces = [System.Collections.Generic.List[object]]::new()
            fail = ''
            stops = [System.Collections.Generic.List[string]]::new()
            stopRefuses = $false
        }
    }
    function Add-FakePane {
        param([string]$PaneId, [string]$Cwd, [string]$Workspace = 'w1', [string]$Agent = '', [string]$Label = 'kingshand')
        $script:Herdr.panes.Add([pscustomobject]@{ pane_id = $PaneId; cwd = $Cwd; workspace_id = $Workspace })
        if (-not @($script:Herdr.workspaces | Where-Object { $_.workspace_id -eq $Workspace })) {
            $script:Herdr.workspaces.Add([pscustomobject]@{ workspace_id = $Workspace; label = $Label })
        }
        if ($Agent) {
            $script:Herdr.agents.Add([pscustomobject]@{ name = $Agent; pane_id = $PaneId; cwd = $Cwd; workspace_id = $Workspace })
        }
    }
    function Get-FakeInventory {
        param([string]$Field)
        if ($script:Herdr.fail) { return [pscustomobject]@{ ok = $false; $Field = @(); error = $script:Herdr.fail } }
        [pscustomobject]@{ ok = $true; $Field = @($script:Herdr[$Field]); error = '' }
    }
}

Describe 'Remove-WorkerCopy' {
    BeforeEach {
        Reset-FakeHerdr
        Mock -ModuleName Teardown Get-HerdrAgentInventory { Get-FakeInventory 'agents' }
        Mock -ModuleName Teardown Get-HerdrPaneInventory { Get-FakeInventory 'panes' }
        Mock -ModuleName Teardown Get-HerdrWorkspaceInventory { Get-FakeInventory 'workspaces' }
        Mock -ModuleName Teardown Remove-HerdrPane {
            $gone = @($script:Herdr.panes | Where-Object { $_.pane_id -eq $PaneId })
            foreach ($g in $gone) { $null = $script:Herdr.panes.Remove($g) }
        }
        Mock -ModuleName Teardown Remove-HerdrWorkspace {
            $gone = @($script:Herdr.workspaces | Where-Object { $_.workspace_id -eq $WorkspaceId })
            foreach ($g in $gone) { $null = $script:Herdr.workspaces.Remove($g) }
        }
        Mock -ModuleName Teardown Stop-HerdrAgent {
            $script:Herdr.stops.Add($Name)
            if ($script:Herdr.stopRefuses) {
                return [pscustomobject]@{ stopped = $false; paneId = 'p1'; refused = 'prompt-box-not-empty'; promptBox = 'hello' }
            }
            $gone = @($script:Herdr.agents | Where-Object { $_.name -eq $Name })
            foreach ($g in $gone) { $null = $script:Herdr.agents.Remove($g) }
            [pscustomobject]@{ stopped = $true; paneId = 'p1'; refused = ''; promptBox = '' }
        }
        $script:F = New-Fixture
    }

    It 'closes the recorded pane of a worker that has already exited, and removes the copy and branch' {
        $copy = New-WorkerCopy $script:F 'w-exited' -PaneId 'p7' -Push
        # The shell in the pane has moved away, so only the recorded id finds it.
        Add-FakePane -PaneId 'p7' -Cwd 'C:\elsewhere' -Workspace 'w7'

        $r = Remove-WorkerCopy -WorkerId 'w-exited' -StatePath $script:F.state

        $r.outcome | Should -Be 'removed'
        $r.removed | Should -Contain 'pane p7'
        $r.removed | Should -Contain 'branch worktree-w-exited'
        @($script:Herdr.panes).Count | Should -Be 0
        Test-Path -LiteralPath $copy | Should -BeFalse
        (Import-CrewState -Path $script:F.state).workers['w-exited'].torn_down_at | Should -Not -BeNullOrEmpty
        $script:Herdr.stops.Count | Should -Be 0 -Because 'no agent was alive, so nothing is stopped'
    }

    It 'leaves a pane that reuses the recorded id somewhere else alone, and still removes the copy' {
        $copy = New-WorkerCopy $script:F 'w-reused' -PaneId 'p9' -Push
        Add-FakePane -PaneId 'p9' -Cwd 'C:\elsewhere' -Workspace 'w9' -Agent 'someone-else'
        $r = Remove-WorkerCopy -WorkerId 'w-reused' -StatePath $script:F.state
        $r.outcome | Should -Be 'removed'
        $r.removed | Should -Not -Contain 'pane p9'
        @($script:Herdr.panes).Count | Should -Be 1
        $script:Herdr.stops.Count | Should -Be 0
        Test-Path -LiteralPath $copy | Should -BeFalse
    }

    It 'never closes a pane at the recorded id in a workspace dispatch did not make, nor that workspace' {
        $copy = New-WorkerCopy $script:F 'w-reused-shell' -PaneId 'p11' -Push
        Add-FakePane -PaneId 'p11' -Cwd 'C:\elsewhere' -Workspace 'w11' -Label 'someone-elses'
        $r = Remove-WorkerCopy -WorkerId 'w-reused-shell' -StatePath $script:F.state
        $r.outcome | Should -Be 'removed'
        $r.removed | Should -Not -Contain 'pane p11'
        $r.removed | Should -Not -Contain 'workspace w11'
        @($script:Herdr.panes).Count | Should -Be 1
        @($script:Herdr.workspaces).Count | Should -Be 1
        Test-Path -LiteralPath $copy | Should -BeFalse
    }

    It 'keeps the copy rather than throwing when an agent in it has no name' {
        $copy = New-WorkerCopy $script:F 'w-unnamed' -PaneId 'p10' -Push
        Add-FakePane -PaneId 'p10' -Cwd $copy -Workspace 'w10'
        $script:Herdr.agents.Add([pscustomobject]@{ name = ''; pane_id = 'p10'; cwd = $copy; workspace_id = 'w10' })
        $r = Remove-WorkerCopy -WorkerId 'w-unnamed' -StatePath $script:F.state
        $r.outcome | Should -Be 'kept'
        $r.kept[0].why | Should -BeLike '*unnamed agent*'
        $script:Herdr.stops.Count | Should -Be 0
        @($script:Herdr.panes).Count | Should -Be 1
        Test-Path -LiteralPath $copy | Should -BeTrue
    }

    It 'finds the pane by its cwd where no pane id was recorded' {
        $copy = New-WorkerCopy $script:F 'w-old' -Push
        Add-FakePane -PaneId 'p3' -Cwd $copy -Workspace 'w3'
        $r = Remove-WorkerCopy -WorkerId 'w-old' -StatePath $script:F.state
        $r.outcome | Should -Be 'removed'
        $r.removed | Should -Contain 'pane p3'
    }

    It 'stops a live agent by the name herdr gave it, found by cwd, never by the dispatched id' {
        $copy = New-WorkerCopy $script:F 'acme-api-a-very-long-worker-name' -Push
        Add-FakePane -PaneId 'p4' -Cwd $copy -Workspace 'w4' -Agent 'acme-api-a-very-long-wor-1a2b3c'
        $r = Remove-WorkerCopy -WorkerId 'acme-api-a-very-long-worker-name' -StatePath $script:F.state
        $script:Herdr.stops | Should -Be @('acme-api-a-very-long-wor-1a2b3c')
        $r.outcome | Should -Be 'removed'
    }

    It 'closes the workspace when the worker''s pane was the last one in it (R10)' {
        $copy = New-WorkerCopy $script:F 'w-ws' -PaneId 'p5' -Push
        Add-FakePane -PaneId 'p5' -Cwd $copy -Workspace 'w5'
        $r = Remove-WorkerCopy -WorkerId 'w-ws' -StatePath $script:F.state
        $r.removed | Should -Contain 'workspace w5'
        @($script:Herdr.workspaces).Count | Should -Be 0
    }

    It 'never closes a workspace that still holds a live agent (R10)' {
        $copy = New-WorkerCopy $script:F 'w-shared' -PaneId 'p6' -Push
        Add-FakePane -PaneId 'p6' -Cwd $copy -Workspace 'w6'
        Add-FakePane -PaneId 'p6b' -Cwd 'C:\other' -Workspace 'w6' -Agent 'someone-else'
        $r = Remove-WorkerCopy -WorkerId 'w-shared' -StatePath $script:F.state
        $r.outcome | Should -Be 'removed'
        $r.removed | Should -Not -Contain 'workspace w6'
        @($script:Herdr.workspaces | Where-Object { $_.workspace_id -eq 'w6' }).Count | Should -Be 1
    }

    It 'keeps a copy with uncommitted changes, and touches nothing' {
        $copy = New-WorkerCopy $script:F 'w-dirty' -PaneId 'p8' -Push
        Add-FakePane -PaneId 'p8' -Cwd $copy -Workspace 'w8' -Agent 'w-dirty'
        Set-Content -LiteralPath (Join-Path $copy 'unsaved.txt') -Value 'not committed'

        $r = Remove-WorkerCopy -WorkerId 'w-dirty' -StatePath $script:F.state

        $r.outcome | Should -Be 'kept'
        $r.kept[0].why | Should -BeLike '*uncommitted changes*'
        Test-Path -LiteralPath $copy | Should -BeTrue
        $script:Herdr.stops.Count | Should -Be 0
        @($script:Herdr.panes).Count | Should -Be 1
        (Import-CrewState -Path $script:F.state).workers['w-dirty'].Contains('torn_down_at') | Should -BeFalse
    }

    It 'keeps a copy whose commit is on no remote branch, and keeps its branch (R3, R4)' {
        $copy = New-WorkerCopy $script:F 'w-unpushed'
        $r = Remove-WorkerCopy -WorkerId 'w-unpushed' -StatePath $script:F.state
        $r.outcome | Should -Be 'kept'
        $r.kept[0].why | Should -BeLike '*1 commits on it are on no remote branch*'
        Test-Path -LiteralPath $copy | Should -BeTrue
        Invoke-Git $script:F.repo branch --list 'worktree-w-unpushed' | Should -Not -BeNullOrEmpty
    }

    It 'does not count the review gate''s own local remote as a remote' {
        $gate = Join-Path $script:F.root 'gate.git'
        $null = & git init --bare -q $gate 2>&1
        Invoke-Git $script:F.repo remote add no-mistakes $gate | Out-Null
        $copy = New-WorkerCopy $script:F 'w-gate'
        Invoke-Git $copy push -q no-mistakes 'worktree-w-gate' | Out-Null
        $r = Remove-WorkerCopy -WorkerId 'w-gate' -StatePath $script:F.state
        $r.outcome | Should -Be 'kept'
    }

    It 'keeps everything when herdr cannot be read, and says so rather than reading it as no panes' {
        $copy = New-WorkerCopy $script:F 'w-blind' -Push
        $script:Herdr.fail = 'herdr agent list: server_down - from the fake'
        $r = Remove-WorkerCopy -WorkerId 'w-blind' -StatePath $script:F.state
        $r.outcome | Should -Be 'kept'
        $r.kept[0].why | Should -BeLike '*herdr could not be read*server_down*'
        Test-Path -LiteralPath $copy | Should -BeTrue
    }

    It 'keeps the copy when the workspace list cannot be read and the recorded pane is still open' {
        $copy = New-WorkerCopy $script:F 'w-nospaces' -PaneId 'p12' -Push
        Add-FakePane -PaneId 'p12' -Cwd 'C:\elsewhere' -Workspace 'w12'
        Mock -ModuleName Teardown Get-HerdrWorkspaceInventory {
            [pscustomobject]@{ ok = $false; workspaces = @(); error = 'herdr workspace list: timeout - from the fake' }
        }

        $r = Remove-WorkerCopy -WorkerId 'w-nospaces' -StatePath $script:F.state

        $r.outcome | Should -Be 'kept'
        $r.kept[0].why | Should -BeLike '*recorded pane could not be checked*timeout*'
        @($script:Herdr.panes).Count | Should -Be 1
        Test-Path -LiteralPath $copy | Should -BeTrue
        (Import-CrewState -Path $script:F.state).workers['w-nospaces'].Contains('torn_down_at') | Should -BeFalse
    }

    # A version mismatch throws out of every herdr read rather than answering, and it must come
    # back as a kept copy naming why, not as an exception half way through a cleanup.
    It 'keeps everything when herdr throws, and names the failure' {
        $copy = New-WorkerCopy $script:F 'w-throw' -Push
        Mock -ModuleName Teardown Get-HerdrAgentInventory { throw 'herdr protocol_mismatch: from the fake' }
        $r = Remove-WorkerCopy -WorkerId 'w-throw' -StatePath $script:F.state
        $r.outcome | Should -Be 'kept'
        $r.kept[0].why | Should -BeLike '*protocol_mismatch*'
        Test-Path -LiteralPath $copy | Should -BeTrue
    }

    It 'keeps the copy when a pane does not close, because it may still hold the folder' {
        $copy = New-WorkerCopy $script:F 'w-stuckpane' -PaneId 'p11' -Push
        Add-FakePane -PaneId 'p11' -Cwd $copy -Workspace 'w11'
        Mock -ModuleName Teardown Remove-HerdrPane { }
        $r = Remove-WorkerCopy -WorkerId 'w-stuckpane' -StatePath $script:F.state
        $r.outcome | Should -Be 'kept'
        $r.kept[0].why | Should -BeLike 'pane p11 did not close*'
        Test-Path -LiteralPath $copy | Should -BeTrue
    }

    It 'keeps a copy whose worker refuses to stop, without closing its pane' {
        $copy = New-WorkerCopy $script:F 'w-box' -Push
        Add-FakePane -PaneId 'p9' -Cwd $copy -Workspace 'w9' -Agent 'w-box'
        $script:Herdr.stopRefuses = $true
        $r = Remove-WorkerCopy -WorkerId 'w-box' -StatePath $script:F.state
        $r.outcome | Should -Be 'kept'
        $r.kept[0].why | Should -BeLike '*prompt-box-not-empty*'
        @($script:Herdr.panes).Count | Should -Be 1
    }

    It 'deletes the folder git dropped but left behind' {
        $copy = New-WorkerCopy $script:F 'w-left' -Push
        # What a cleanup against a held folder leaves: git's record gone, the folder still there.
        Invoke-Git $script:F.repo worktree remove $copy | Out-Null
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $copy 'node_modules\pkg')
        Set-Content -LiteralPath (Join-Path $copy 'node_modules\pkg\index.js') -Value 'x'

        $r = Remove-WorkerCopy -WorkerId 'w-left' -StatePath $script:F.state

        $r.outcome | Should -Be 'removed'
        Test-Path -LiteralPath $copy | Should -BeFalse
    }

    It 'deletes a leftover folder whose paths are longer than 260 characters' {
        $copy = New-WorkerCopy $script:F 'w-long' -Push
        Invoke-Git $script:F.repo worktree remove $copy | Out-Null
        $deep = Join-Path $copy 'node_modules'
        while ($deep.Length -lt 300) { $deep = Join-Path $deep 'node_modules_nested_package_dir' }
        $null = New-Item -ItemType Directory -Force -Path $deep
        Set-Content -LiteralPath (Join-Path $deep 'f.js') -Value 'x'

        $r = Remove-WorkerCopy -WorkerId 'w-long' -StatePath $script:F.state
        $r.outcome | Should -Be 'removed'
        Test-Path -LiteralPath $copy | Should -BeFalse
    }

    # Windows only: an open file there blocks deleting its folder, and macOS and Linux have no such lock.
    It 'reports a leftover folder something still holds as kept with the reason locked, once (R11)' -Skip:(-not $IsWindows) {
        $copy = New-WorkerCopy $script:F 'w-locked' -Push
        Invoke-Git $script:F.repo worktree remove $copy | Out-Null
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $copy 'obj')
        $held = Join-Path $copy 'obj\held.txt'
        Set-Content -LiteralPath $held -Value 'x'
        $fs = [System.IO.File]::Open($held, 'Open', 'Read', 'None')
        try {
            $r = Remove-WorkerCopy -WorkerId 'w-locked' -StatePath $script:F.state
        } finally { $fs.Dispose() }

        $r.outcome | Should -Be 'kept'
        $r.kept[0].why | Should -BeLike 'locked*'
        $r.removed | Should -Not -Contain "copy $copy"
        (Import-CrewState -Path $script:F.state).workers['w-locked'].Contains('torn_down_at') | Should -BeFalse
    }

    It 'keeps a folder git dropped that still holds a source file, when its worker has not finished' {
        $copy = New-WorkerCopy $script:F 'w-src' -Push
        Invoke-Git $script:F.repo worktree remove $copy | Out-Null
        $null = New-Item -ItemType Directory -Force -Path $copy
        Set-Content -LiteralPath (Join-Path $copy 'app.ts') -Value 'unsaved work'

        $r = Remove-WorkerCopy -WorkerId 'w-src' -StatePath $script:F.state

        $r.outcome | Should -Be 'kept'
        $r.kept[0].why | Should -Be 'unlisted folder still holds files - check it by hand'
        Test-Path -LiteralPath (Join-Path $copy 'app.ts') | Should -BeTrue
    }

    It 'removes a landed worker''s folder git dropped when its branch is all on a remote, source files and all' {
        $copy = New-WorkerCopy $script:F 'w-landed' -Stage 'landed' -Push
        Invoke-Git $script:F.repo worktree remove $copy | Out-Null
        $null = New-Item -ItemType Directory -Force -Path $copy
        Set-Content -LiteralPath (Join-Path $copy 'app.ts') -Value 'x'
        Set-Content -LiteralPath (Join-Path $copy '.git') -Value 'gitdir: C:\nowhere'

        $r = Remove-WorkerCopy -WorkerId 'w-landed' -StatePath $script:F.state

        $r.outcome | Should -Be 'removed'
        Test-Path -LiteralPath $copy | Should -BeFalse
    }

    It 'removes a local-only landed worker merged into its base branch and never pushed, branch and all' {
        $copy = New-WorkerCopy $script:F 'w-merged' -Stage 'landed'
        Invoke-Git $script:F.repo merge -q --ff-only 'worktree-w-merged' | Out-Null

        $r = Remove-WorkerCopy -WorkerId 'w-merged' -StatePath $script:F.state

        $r.outcome | Should -Be 'removed'
        $r.removed | Should -Contain 'branch worktree-w-merged'
        Test-Path -LiteralPath $copy | Should -BeFalse
        Invoke-Git $script:F.repo branch --list 'worktree-w-merged' | Should -BeNullOrEmpty
    }

    It 'keeps a copy whose commit is neither pushed nor merged into its base branch' {
        $copy = New-WorkerCopy $script:F 'w-neither' -Stage 'landed'

        $r = Remove-WorkerCopy -WorkerId 'w-neither' -StatePath $script:F.state

        $r.outcome | Should -Be 'kept'
        $r.kept[0].why | Should -Be '1 commits on it are on no remote branch nor merged into its base'
        Test-Path -LiteralPath $copy | Should -BeTrue
        Invoke-Git $script:F.repo branch --list 'worktree-w-neither' | Should -Not -BeNullOrEmpty
    }

    It 'removes a folder git dropped when its landed worker''s branch is merged into the local base' {
        $copy = New-WorkerCopy $script:F 'w-dropped-merged' -Stage 'landed'
        Invoke-Git $script:F.repo worktree remove $copy | Out-Null
        Invoke-Git $script:F.repo merge -q --ff-only 'worktree-w-dropped-merged' | Out-Null
        $null = New-Item -ItemType Directory -Force -Path $copy
        Set-Content -LiteralPath (Join-Path $copy 'app.ts') -Value 'x'

        $r = Remove-WorkerCopy -WorkerId 'w-dropped-merged' -StatePath $script:F.state

        $r.outcome | Should -Be 'removed'
        Test-Path -LiteralPath $copy | Should -BeFalse
    }

    It 'keeps a landed worker''s folder git dropped when its branch has a commit on no remote' {
        $copy = New-WorkerCopy $script:F 'w-landed-unpushed' -Stage 'landed'
        Invoke-Git $script:F.repo worktree remove $copy | Out-Null
        $null = New-Item -ItemType Directory -Force -Path $copy
        Set-Content -LiteralPath (Join-Path $copy 'app.ts') -Value 'x'

        $r = Remove-WorkerCopy -WorkerId 'w-landed-unpushed' -StatePath $script:F.state

        $r.outcome | Should -Be 'kept'
        $r.kept[0].why | Should -Be 'unlisted folder still holds files - check it by hand'
        Test-Path -LiteralPath (Join-Path $copy 'app.ts') | Should -BeTrue
        Invoke-Git $script:F.repo branch --list 'worktree-w-landed-unpushed' | Should -Not -BeNullOrEmpty
    }

    # The one destination this module deletes is a folder directly under a project's
    # .claude\worktrees. A record pointing anywhere else - a hand-edited one, an old shape - is
    # refused by its path before anything is read or removed.
    It 'never deletes a recorded copy outside a project''s .claude\worktrees folder' {
        $elsewhere = Join-Path $script:F.root 'not-a-worker-copy'
        $null = New-Item -ItemType Directory -Force -Path $elsewhere
        Set-Content -LiteralPath (Join-Path $elsewhere 'keep.txt') -Value 'x'
        $s = Import-CrewState -Path $script:F.state
        Add-CrewWorker -State $s -WorkerId 'w-odd' -Ticket 'w-odd' -Kind 'adhoc' -Repo 'acme-api' `
                       -Worktree $elsewhere -Branch 'main' -Brief 'b'
        Save-CrewState -State $s -Path $script:F.state

        $r = Remove-WorkerCopy -WorkerId 'w-odd' -StatePath $script:F.state

        $r.outcome | Should -Be 'kept'
        $r.kept[0].why | Should -BeLike '*not under a project*'
        Test-Path -LiteralPath (Join-Path $elsewhere 'keep.txt') | Should -BeTrue
        Invoke-Git $script:F.repo branch --list main | Should -Not -BeNullOrEmpty
    }

    It 'throws for a worker crew.json does not know' {
        { Remove-WorkerCopy -WorkerId 'nobody' -StatePath $script:F.state } | Should -Throw '*nothing recorded*'
    }

    It 'sends a checkout worker to Stop-CheckoutWorker and never to the copy path (R3)' {
        $s = Import-CrewState -Path $script:F.state
        Add-CrewWorker -State $s -WorkerId 'w-co' -Ticket 'w-co' -Kind 'adhoc' -Repo 'acme-api' `
                       -Worktree $script:F.repo -Branch 'feature-x' -Brief 'b' -InCheckout -SettingsRecord 'rec.json'
        Save-CrewState -State $s -Path $script:F.state
        Mock -ModuleName Teardown Stop-CheckoutWorker { [pscustomobject]@{ stopped = $true; paneRemoved = $true; settings = 'restored' } }

        $r = Remove-WorkerCopy -WorkerId 'w-co' -StatePath $script:F.state

        Should -Invoke -ModuleName Teardown Stop-CheckoutWorker -Times 1 -ParameterFilter { $RecordPath -eq 'rec.json' -and $EndSession }
        $r.outcome | Should -Be 'removed'
        Test-Path -LiteralPath $script:F.repo | Should -BeTrue
    }
}

Describe 'Get-WorkerLeftovers, Format-WorkerLeftovers and Invoke-WorkerSweep' {
    BeforeEach {
        Reset-FakeHerdr
        Mock -ModuleName Teardown Get-HerdrAgentInventory { Get-FakeInventory 'agents' }
        Mock -ModuleName Teardown Get-HerdrPaneInventory { Get-FakeInventory 'panes' }
        Mock -ModuleName Teardown Get-HerdrWorkspaceInventory { Get-FakeInventory 'workspaces' }
        Mock -ModuleName Teardown Remove-HerdrPane {
            $gone = @($script:Herdr.panes | Where-Object { $_.pane_id -eq $PaneId })
            foreach ($g in $gone) { $null = $script:Herdr.panes.Remove($g) }
        }
        Mock -ModuleName Teardown Remove-HerdrWorkspace {
            $gone = @($script:Herdr.workspaces | Where-Object { $_.workspace_id -eq $WorkspaceId })
            foreach ($g in $gone) { $null = $script:Herdr.workspaces.Remove($g) }
        }
        Mock -ModuleName Teardown Stop-HerdrAgent { [pscustomobject]@{ stopped = $true; paneId = $null; refused = ''; promptBox = '' } }
        $script:F = New-Fixture
        $script:Paths = @{ RegistryPath = $script:F.registry; StatePath = $script:F.state; DataPath = $script:F.data }
    }

    It 'counts nothing and prints no line when nothing is left over' {
        $l = Get-WorkerLeftovers @script:Paths
        @($l.copies).Count | Should -Be 0
        $null -eq $l.copies | Should -BeFalse -Because 'an empty list is a count of zero, and $null would mean unreadable'
        Format-WorkerLeftovers -Leftovers $l | Should -Be ''
    }

    It 'counts a dispatched folder git dropped, a finished worker''s copy, dead panes and empty workspaces' {
        $left = New-WorkerCopy $script:F 'w-dropped' -Push -NoRecord
        Invoke-Git $script:F.repo worktree remove $left | Out-Null
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $left 'bin')
        $done = New-WorkerCopy $script:F 'w-done' -Stage 'landed' -Push
        $null = New-WorkerCopy $script:F 'w-busy' -Stage 'implementing' -Push
        Add-FakePane -PaneId 'p1' -Cwd $done -Workspace 'w1'
        Add-FakePane -PaneId 'p2' -Cwd 'C:\anything' -Workspace 'w2'
        Add-FakePane -PaneId 'p3' -Cwd 'C:\live' -Workspace 'w3' -Agent 'live-one'

        $l = Get-WorkerLeftovers @script:Paths

        @($l.copies | ForEach-Object name | Sort-Object) | Should -Be @('w-done', 'w-dropped')
        @($l.deadPanes | ForEach-Object pane_id | Sort-Object) | Should -Be @('p1', 'p2')
        @($l.emptyWorkspaces | ForEach-Object workspace_id | Sort-Object) | Should -Be @('w1', 'w2')
        Format-WorkerLeftovers -Leftovers $l |
            Should -Be 'LEFTOVERS: 2 dead panes, 2 empty workspaces, 2 leftover copies - Invoke-WorkerSweep (bin\Teardown.psm1) clears them.'
    }

    It 'never counts or touches a folder kingshand did not dispatch (R8)' {
        $other = Join-Path $script:F.repo '.claude\worktrees\desktop-session-copy'
        $null = New-Item -ItemType Directory -Force -Path $other
        Add-FakePane -PaneId 'p9' -Cwd $other -Workspace 'wx' -Label 'someone-elses'

        $l = Get-WorkerLeftovers @script:Paths
        @($l.copies).Count | Should -Be 0
        @($l.deadPanes).Count | Should -Be 0
        @($l.emptyWorkspaces).Count | Should -Be 0

        $null = Invoke-WorkerSweep @script:Paths
        Test-Path -LiteralPath $other | Should -BeTrue
        @($script:Herdr.panes).Count | Should -Be 1
    }

    It 'reports an unreadable herdr as unreadable in the line, never as zero' {
        $script:Herdr.fail = 'herdr pane list: server_down - from the fake'
        $l = Get-WorkerLeftovers @script:Paths
        $l.deadPanes | Should -BeNullOrEmpty
        $null -eq $l.deadPanes | Should -BeTrue
        $line = Format-WorkerLeftovers -Leftovers $l
        $line | Should -BeLike '*dead panes unreadable*empty workspaces unreadable*0 leftover copies*server_down*'
        $line.Length | Should -BeLessOrEqual 220 -Because 'the digest is built to a fixed limit, and the full reason is the sweep''s to give'
    }

    It 'reports an unreadable crew record as unreadable copies, never as zero' {
        Set-Content -LiteralPath $script:F.state -Value '{ not json'
        $l = Get-WorkerLeftovers @script:Paths
        $null -eq $l.copies | Should -BeTrue
        $l.problems[0] | Should -BeLike 'crew.json could not be read*'
    }

    It 'reports an unreadable git as unreadable, never as zero' {
        Remove-Item -LiteralPath (Join-Path $script:F.repo '.git') -Recurse -Force
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $script:F.repo '.claude\worktrees')
        $l = Get-WorkerLeftovers @script:Paths
        $null -eq $l.copies | Should -BeTrue
        Format-WorkerLeftovers -Leftovers $l | Should -BeLike '*leftover copies unreadable*'
    }

    It 'clears what it counts, keeps what is unsafe, and says so in one line' {
        $left = New-WorkerCopy $script:F 'w-dropped' -Push -NoRecord
        Invoke-Git $script:F.repo worktree remove $left | Out-Null
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $left 'obj')
        $done = New-WorkerCopy $script:F 'w-done' -Stage 'landed' -PaneId 'p1' -Push
        $unsafe = New-WorkerCopy $script:F 'w-failed' -Stage 'failed'
        Add-FakePane -PaneId 'p1' -Cwd $done -Workspace 'w1'
        Add-FakePane -PaneId 'p2' -Cwd 'C:\anything' -Workspace 'w2'

        $r = Invoke-WorkerSweep @script:Paths

        $r.summary | Should -Be 'Sweep: 2 dead panes closed, 2 leftover copies removed, 2 workspaces closed, 1 kept.'
        $r.kept[0].what | Should -Be $unsafe
        $r.kept[0].why | Should -BeLike '*on no remote branch*'
        Test-Path -LiteralPath $left | Should -BeFalse
        Test-Path -LiteralPath $done | Should -BeFalse
        Test-Path -LiteralPath $unsafe | Should -BeTrue
        @($script:Herdr.panes).Count | Should -Be 0
        @($script:Herdr.workspaces).Count | Should -Be 0
        (Import-CrewState -Path $script:F.state).workers['w-done'].torn_down_at | Should -Not -BeNullOrEmpty
    }

    It 'removes an unrecorded dropped folder that holds only build output' {
        $left = New-WorkerCopy $script:F 'w-build' -Push -NoRecord
        Invoke-Git $script:F.repo worktree remove $left | Out-Null
        foreach ($d in 'node_modules\pkg', 'dist', '.angular') { $null = New-Item -ItemType Directory -Force -Path (Join-Path $left $d) }
        Set-Content -LiteralPath (Join-Path $left 'node_modules\pkg\index.js') -Value 'x'

        $r = Invoke-WorkerSweep @script:Paths

        $r.summary | Should -BeLike '*1 leftover copies removed*0 kept*'
        Test-Path -LiteralPath $left | Should -BeFalse
    }

    It 'keeps an unrecorded dropped folder that holds a source file, and says why' {
        $left = New-WorkerCopy $script:F 'w-src' -Push -NoRecord
        Invoke-Git $script:F.repo worktree remove $left | Out-Null
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $left 'obj')
        Set-Content -LiteralPath (Join-Path $left 'app.ts') -Value 'unsaved work'

        $r = Invoke-WorkerSweep @script:Paths

        $r.kept[0].what | Should -Be $left
        $r.kept[0].why | Should -Be 'unlisted folder still holds files - check it by hand'
        Test-Path -LiteralPath (Join-Path $left 'app.ts') | Should -BeTrue
    }

    It 'keeps an unrecorded dropped folder that still holds a .git pointer file' {
        $left = New-WorkerCopy $script:F 'w-pointer' -Push -NoRecord
        Invoke-Git $script:F.repo worktree remove $left | Out-Null
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $left 'node_modules')
        Set-Content -LiteralPath (Join-Path $left '.git') -Value 'gitdir: C:\moved\.git\worktrees\w-pointer'

        $r = Invoke-WorkerSweep @script:Paths

        $r.kept[0].why | Should -Be 'unlisted folder still holds files - check it by hand'
        Test-Path -LiteralPath (Join-Path $left '.git') | Should -BeTrue
    }

    # The Hand calls all three with no paths, so the defaults - the installation root's own
    # state\crew.json, data\projects.md and data\ - are the route every real call takes.
    It 'reads the installation''s own files when no path is passed' {
        $left = New-WorkerCopy $script:F 'w-default' -Stage 'landed' -Push
        $saved = $env:KINGSHAND_HOME
        try {
            $env:KINGSHAND_HOME = $script:F.root
            @((Get-WorkerLeftovers).copies).Count | Should -Be 1
            (Invoke-WorkerSweep).summary | Should -BeLike '*1 leftover copies removed*'
            Test-Path -LiteralPath $left | Should -BeFalse
            $null = New-WorkerCopy $script:F 'w-default2' -Push
            (Remove-WorkerCopy -WorkerId 'w-default2').outcome | Should -Be 'removed'
        } finally { $env:KINGSHAND_HOME = $saved }
    }

    # Windows only, for the same reason: elsewhere an open file never stops its folder being deleted.
    It 'keeps a locked leftover with the reason locked and counts it again next time (R11)' -Skip:(-not $IsWindows) {
        $left = New-WorkerCopy $script:F 'w-held' -Push -NoRecord
        Invoke-Git $script:F.repo worktree remove $left | Out-Null
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $left 'obj')
        $held = Join-Path $left 'obj\held.txt'
        Set-Content -LiteralPath $held -Value 'x'
        $fs = [System.IO.File]::Open($held, 'Open', 'Read', 'None')
        try {
            $r = Invoke-WorkerSweep @script:Paths
            $r.kept[0].why | Should -BeLike 'locked*'
            $r.summary | Should -BeLike '*0 leftover copies removed*1 kept*'
            @((Get-WorkerLeftovers @script:Paths).copies).Count | Should -Be 1
        } finally { $fs.Dispose() }

        $again = Invoke-WorkerSweep @script:Paths
        $again.summary | Should -BeLike '*1 leftover copies removed*0 kept*'
        Test-Path -LiteralPath $left | Should -BeFalse
    }
}

# Suspend-Worker with herdr and the review gate faked: the same in-memory herdr picture as above,
# a queue of gate-run readings, and the gate binary's answers - `axi sync` answering in real TOON so
# the decoder the module reads it with is exercised too. Git is real.
Describe 'Suspend-Worker' {
    BeforeAll {
        Import-Module "$PSScriptRoot\..\bin\Index.psm1"

        # One `axi sync --check` answer, in the shape the tool prints.
        function New-SyncAnswer {
            param([string]$Safety, [string]$Relation, [string]$CurrentHead = '', [string]$Note = '')
            @"
branch_sync:
  state: x
  changed: false
  local:
    branch: worktree-w
    head: "0000000000000000000000000000000000000000"
    clean: true
  pipeline:
    run: "01RUN"
    status: cancelled
    current_head: "$CurrentHead"
  relation: $Relation
  safety: $Safety
  note: "$Note"
"@
        }

        # One gate-run reading, in Get-GateRunState's shape.
        function New-GateReading {
            param([string]$Status = 'has-run', [string]$RunStatus = 'running', [switch]$Parked,
                  [string]$ParkedOn = '', [object[]]$Steps = @(), [string]$Pr = '', [string]$Outcome = '')
            [pscustomobject]@{
                status = $Status; signal = 'x'; detail = "reading $Status $RunStatus"
                runId = '01RUN'; branch = ''; head = ''; pr = $Pr; runStatus = $RunStatus
                outcome = $Outcome; isParked = [bool]$Parked; parkedOn = $ParkedOn
                steps = @($Steps); findings = @(); notUnderstood = @()
            }
        }
    }

    BeforeEach {
        Reset-FakeHerdr
        $script:Herdr.stopResult = 'exit'   # exit | box | hang
        $script:Herdr.dialog = $false
        Mock -ModuleName Teardown Get-HerdrAgentInventory { Get-FakeInventory 'agents' }
        Mock -ModuleName Teardown Get-HerdrPaneInventory { Get-FakeInventory 'panes' }
        Mock -ModuleName Teardown Get-HerdrWorkspaceInventory { Get-FakeInventory 'workspaces' }
        Mock -ModuleName Teardown Remove-HerdrPane {
            $gone = @($script:Herdr.panes | Where-Object { $_.pane_id -eq $PaneId })
            foreach ($g in $gone) { $null = $script:Herdr.panes.Remove($g) }
            # Closing a pane ends whatever was running in it.
            $dead = @($script:Herdr.agents | Where-Object { $_.pane_id -eq $PaneId })
            foreach ($d in $dead) { $null = $script:Herdr.agents.Remove($d) }
        }
        Mock -ModuleName Teardown Remove-HerdrWorkspace {
            $gone = @($script:Herdr.workspaces | Where-Object { $_.workspace_id -eq $WorkspaceId })
            foreach ($g in $gone) { $null = $script:Herdr.workspaces.Remove($g) }
        }
        Mock -ModuleName Teardown Stop-HerdrAgent {
            $script:Herdr.stops.Add($Name)
            switch ($script:Herdr.stopResult) {
                'box'  { return [pscustomobject]@{ stopped = $false; paneId = 'p1'; refused = 'prompt-box-not-empty'; promptBox = 'half a thought' } }
                'hang' { return [pscustomobject]@{ stopped = $false; paneId = 'p1'; refused = ''; promptBox = '' } }
            }
            $gone = @($script:Herdr.agents | Where-Object { $_.name -eq $Name })
            foreach ($g in $gone) { $null = $script:Herdr.agents.Remove($g) }
            [pscustomobject]@{ stopped = $true; paneId = 'p1'; refused = ''; promptBox = '' }
        }
        Mock -ModuleName Teardown Test-HerdrAgentAwaitingInput { $script:Herdr.dialog }
        Mock -ModuleName Teardown Send-HerdrKeys { }

        # The gate: readings handed out in order, the last one repeating; the binary's answers by
        # what it was asked; every call recorded.
        $script:Gate = @{
            readings = [System.Collections.Generic.Queue[object]]::new()
            last     = $null
            checks   = [System.Collections.Generic.Queue[string]]::new()
            recover  = [pscustomobject]@{ ok = $true; stdout = ''; stderr = ''; exitCode = 0; error = '' }
            abort    = [pscustomobject]@{ ok = $true; stdout = ''; stderr = ''; exitCode = 0; error = '' }
            calls    = [System.Collections.Generic.List[string]]::new()
            rescues  = [System.Collections.Generic.List[string]]::new()
        }
        Mock -ModuleName Teardown Get-GateRunState {
            if ($script:Gate.readings.Count -gt 0) { $script:Gate.last = $script:Gate.readings.Dequeue() }
            $script:Gate.last
        }
        Mock -ModuleName Teardown Invoke-PauseGate {
            $said = $Arguments -join ' '
            $script:Gate.calls.Add($said)
            switch ($said) {
                'axi abort'          { return $script:Gate.abort }
                'axi sync --recover' { return $script:Gate.recover }
                'axi sync --check'   {
                    return [pscustomobject]@{ ok = $true; stdout = $script:Gate.checks.Dequeue(); stderr = ''; exitCode = 0; error = '' }
                }
            }
            throw "unexpected gate call: $said"
        }
        Mock -ModuleName Teardown Save-WatchGateRescue {
            $script:Gate.rescues.Add($Head)
            [pscustomobject]@{ ref = "refs/gate/$Task-20261104T0100"; head = $Head; from = 'repository' }
        }

        $script:F = New-Fixture
        $script:Copy = New-WorkerCopy $script:F 'w-pause' -Stage 'implementing' -PaneId 'p1'
        Add-FakePane -PaneId 'p1' -Cwd $script:Copy -Workspace 'w1' -Agent 'w-pause'
        $script:Record = Join-Path $script:F.data 'w-pause\pause.md'
        $script:Suspend = { Suspend-Worker -WorkerId 'w-pause' -StatePath $script:F.state -DataPath $script:F.data }
    }

    It 'ends a running gate run, stops the worker, closes its pane, keeps the copy and writes the record' {
        $script:Gate.readings.Enqueue((New-GateReading -RunStatus 'running' -Steps @(
            [pscustomobject]@{ step = 'review'; status = 'completed' },
            [pscustomobject]@{ step = 'test'; status = 'running' },
            [pscustomobject]@{ step = 'push'; status = 'pending' })))
        $script:Gate.readings.Enqueue((New-GateReading -RunStatus 'cancelled'))
        $script:Gate.checks.Enqueue((New-SyncAnswer 'custody_returned' 'equal'))

        $r = & $script:Suspend

        $r.outcome | Should -Be 'paused'
        $r.failedStep | Should -Be ''
        $r.stoppedBy | Should -Be 'exit'
        @($r.steps | ForEach-Object { $_.step }) | Should -Be @('read', 'gate', 'custody', 'stop', 'pane', 'record')
        $script:Gate.calls | Should -Be @('axi abort', 'axi sync --check')
        $script:Herdr.stops | Should -Be @('w-pause')
        @($script:Herdr.panes).Count | Should -Be 0
        Test-Path -LiteralPath $script:Copy | Should -BeTrue -Because 'a pause keeps the copy'
        & git -C $script:F.repo rev-parse --verify --quiet refs/heads/worktree-w-pause | Should -Not -BeNullOrEmpty

        $text = Get-Content -LiteralPath $r.record -Raw
        (Get-Content -LiteralPath $r.record -TotalCount 1) | Should -Be '# Paused - w-pause'
        $head = (& git -C $script:Copy rev-parse HEAD).Trim()
        $text.Contains("- Head: $head") | Should -BeTrue
        $text.Contains('- Branch: worktree-w-pause') | Should -BeTrue
        $text.Contains('- Stage before the pause: implementing') | Should -BeTrue
        $text.Contains('run 01RUN read running; steps: review completed, test running') | Should -BeTrue
        $text.Contains('## Uncommitted files') | Should -BeTrue
        $text.Contains("Set-CrewRelaunch -State `$s -WorkerId 'w-pause'") | Should -BeTrue
        $text.Contains("New-HerdrPane -Cwd '$($script:Copy)'") | Should -BeTrue

        (Import-CrewState -Path $script:F.state).workers['w-pause'].stage | Should -Be 'paused'
        @(Get-IndexEntries -Project 'acme-api' -DataPath $script:F.data | Where-Object { $_.path -like '*w-pause\pause.md' }).Count |
            Should -Be 1
    }

    It 'lists uncommitted files in the record and leaves them on disk' {
        Set-Content -LiteralPath (Join-Path $script:Copy 'half.txt') -Value 'not yet committed'
        $script:Gate.readings.Enqueue((New-GateReading -Status 'no-run' -RunStatus ''))

        $r = & $script:Suspend

        $r.outcome | Should -Be 'paused'
        (Get-Content -LiteralPath $r.record -Raw).Contains('?? half.txt') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:Copy 'half.txt') | Should -BeTrue
    }

    It 'aborts nothing when the gate run has already finished, and still checks custody' {
        $script:Gate.readings.Enqueue((New-GateReading -RunStatus 'completed' -Pr 'https://example.com/pr/1' -Outcome 'passed'))
        $script:Gate.checks.Enqueue((New-SyncAnswer 'custody_returned' 'equal'))

        $r = & $script:Suspend

        $r.outcome | Should -Be 'paused'
        $script:Gate.calls | Should -Be @('axi sync --check')
        ($r.steps | Where-Object step -eq 'gate').detail | Should -BeLike '*already ended (completed)*'
        (Get-Content -LiteralPath $r.record -Raw).Contains('pull request https://example.com/pr/1') | Should -BeTrue
    }

    It 'skips the custody steps when the gate never ran on the branch' {
        $script:Gate.readings.Enqueue((New-GateReading -Status 'no-run' -RunStatus ''))

        $r = & $script:Suspend

        $r.outcome | Should -Be 'paused'
        $script:Gate.calls.Count | Should -Be 0
        (Get-Content -LiteralPath $r.record -Raw).Contains('- Review gate: no review gate run on this branch') | Should -BeTrue
    }

    It 'saves the gate''s head, recovers its commits and checks custody came back when the gate still holds them' {
        $gateHead = 'a' * 40
        $script:Gate.readings.Enqueue((New-GateReading -RunStatus 'running' -Parked -ParkedOn 'review'))
        $script:Gate.readings.Enqueue((New-GateReading -RunStatus 'cancelled'))
        $script:Gate.checks.Enqueue((New-SyncAnswer 'blocked_pipeline_owned_recoverable' 'behind' $gateHead))
        $script:Gate.checks.Enqueue((New-SyncAnswer 'custody_returned' 'equal' $gateHead))

        $r = & $script:Suspend

        $r.outcome | Should -Be 'paused'
        @($r.steps | ForEach-Object { $_.step }) |
            Should -Be @('read', 'gate', 'custody', 'rescue', 'recover', 'verify', 'stop', 'pane', 'record')
        $script:Gate.calls | Should -Be @('axi abort', 'axi sync --check', 'axi sync --recover', 'axi sync --check')
        $script:Gate.rescues | Should -Be @($gateHead)
        $text = Get-Content -LiteralPath $r.record -Raw
        $text.Contains('recovered to the branch - custody_returned, equal; also saved at refs/gate/w-pause-') | Should -BeTrue
        $text.Contains('parked at its review step') | Should -BeTrue
    }

    It 'stops at the recover when the gate refuses it, leaving the worker running and naming the saved ref' {
        $script:Gate.readings.Enqueue((New-GateReading -RunStatus 'cancelled'))
        $script:Gate.checks.Enqueue((New-SyncAnswer 'blocked_pipeline_owned_recoverable' 'behind' ('b' * 40)))
        $script:Gate.recover = [pscustomobject]@{
            ok = $true; stderr = ''; exitCode = 1; error = ''
            stdout = (New-SyncAnswer 'blocked_remote_moved' 'diverged' '' 'the remote moved')
        }

        $r = & $script:Suspend

        $r.outcome | Should -Be 'failed'
        $r.failedStep | Should -Be 'recover'
        ($r.steps | Where-Object step -eq 'recover').detail |
            Should -BeLike '*refused*blocked_remote_moved*the remote moved*saved at refs/gate/w-pause-*'
        $script:Herdr.stops.Count | Should -Be 0 -Because 'a failed step stops the sequence there'
        @($script:Herdr.panes).Count | Should -Be 1
        Test-Path -LiteralPath $script:Record | Should -BeFalse
        (Import-CrewState -Path $script:F.state).workers['w-pause'].stage | Should -Be 'implementing'
    }

    It 'stops at the verify when custody did not come back after the recover' {
        $script:Gate.readings.Enqueue((New-GateReading -RunStatus 'cancelled'))
        $script:Gate.checks.Enqueue((New-SyncAnswer 'blocked_pipeline_owned_recoverable' 'behind'))
        $script:Gate.checks.Enqueue((New-SyncAnswer 'custody_returned' 'behind'))

        $r = & $script:Suspend

        $r.failedStep | Should -Be 'verify'
        ($r.steps | Where-Object step -eq 'verify').detail | Should -BeLike '*relation behind*'
        $script:Gate.rescues.Count | Should -Be 0 -Because 'no gate head was named, so there was nothing to save'
        $script:Herdr.stops.Count | Should -Be 0
    }

    It 'moves nothing on a custody answer it does not recover' {
        $script:Gate.readings.Enqueue((New-GateReading -RunStatus 'cancelled'))
        $script:Gate.checks.Enqueue((New-SyncAnswer 'blocked_wrong_branch' 'unknown' '' 'no binding'))

        $r = & $script:Suspend

        $r.failedStep | Should -Be 'custody'
        ($r.steps | Where-Object step -eq 'custody').detail | Should -BeLike '*blocked_wrong_branch*no binding*nothing was moved*'
        $script:Gate.calls | Should -Not -Contain 'axi sync --recover'
        $script:Herdr.stops.Count | Should -Be 0
    }

    It 'reads a custody answer it cannot decode as unreadable, never as a state' {
        $script:Gate.readings.Enqueue((New-GateReading -RunStatus 'cancelled'))
        $script:Gate.checks.Enqueue('')

        $r = & $script:Suspend

        $r.failedStep | Should -Be 'custody'
        ($r.steps | Where-Object step -eq 'custody').detail | Should -BeLike '*could not be read*printed nothing*'
    }

    It 'ends nothing when the gate run cannot be read' {
        $script:Gate.readings.Enqueue((New-GateReading -Status 'unreadable' -RunStatus ''))

        $r = & $script:Suspend

        $r.failedStep | Should -Be 'gate'
        $script:Gate.calls.Count | Should -Be 0
        $script:Herdr.stops.Count | Should -Be 0
    }

    It 'stops at the gate when the run does not read ended after the abort' {
        $script:Gate.readings.Enqueue((New-GateReading -RunStatus 'running'))
        $script:Gate.abort = [pscustomobject]@{ ok = $true; stdout = ''; stderr = 'no active run'; exitCode = 1; error = '' }

        $r = & $script:Suspend

        $r.failedStep | Should -Be 'gate'
        ($r.steps | Where-Object step -eq 'gate').detail | Should -BeLike '*exited 1*does not read ended*no active run*'
        $script:Gate.calls | Should -Not -Contain 'axi sync --check'
    }

    It 'stops at the gate when the gate binary does not answer the abort' {
        $script:Gate.readings.Enqueue((New-GateReading -RunStatus 'running'))
        $script:Gate.abort = [pscustomobject]@{ ok = $false; stdout = ''; stderr = ''; exitCode = $null; error = 'it did not answer within 60 seconds' }

        $r = & $script:Suspend

        $r.failedStep | Should -Be 'gate'
        ($r.steps | Where-Object step -eq 'gate').detail | Should -BeLike '*could not be ended*did not answer*'
    }

    It 'refuses to stop a worker whose input box holds text, quoting it and closing nothing' {
        $script:Gate.readings.Enqueue((New-GateReading -Status 'no-run' -RunStatus ''))
        $script:Herdr.stopResult = 'box'

        $r = & $script:Suspend

        $r.failedStep | Should -Be 'stop'
        $r.stoppedBy | Should -Be ''
        ($r.steps | Where-Object step -eq 'stop').detail | Should -BeLike "*prompt-box-not-empty*'half a thought'*"
        @($script:Herdr.panes).Count | Should -Be 1
        Test-Path -LiteralPath $script:Record | Should -BeFalse
    }

    It 'closes the pane of a worker sitting on the exit dialog for its own background work, and says so' {
        $script:Gate.readings.Enqueue((New-GateReading -Status 'no-run' -RunStatus ''))
        $script:Herdr.stopResult = 'hang'
        $script:Herdr.dialog = $true

        $r = & $script:Suspend

        $r.outcome | Should -Be 'paused'
        $r.stoppedBy | Should -Be 'pane-closed'
        Should -Invoke -ModuleName Teardown Remove-HerdrPane -ParameterFilter { $PaneId -eq 'p1' }
        Should -Invoke -ModuleName Teardown Send-HerdrKeys -Times 0 -Exactly
        @($script:Herdr.agents).Count | Should -Be 0
        Test-Path -LiteralPath $script:Copy | Should -BeTrue
        (Get-Content -LiteralPath $r.record -Raw).Contains('its pane p1 was closed rather than the dialog answered') |
            Should -BeTrue
    }

    It 'leaves a worker running that did not exit and shows no dialog' {
        $script:Gate.readings.Enqueue((New-GateReading -Status 'no-run' -RunStatus ''))
        $script:Herdr.stopResult = 'hang'

        $r = & $script:Suspend

        $r.failedStep | Should -Be 'stop'
        ($r.steps | Where-Object step -eq 'stop').detail | Should -BeLike '*did not exit and shows no dialog*'
        Should -Invoke -ModuleName Teardown Remove-HerdrPane -Times 0 -Exactly
    }

    It 'stops nothing when herdr cannot be read' {
        $script:Gate.readings.Enqueue((New-GateReading -Status 'no-run' -RunStatus ''))
        $script:Herdr.fail = 'server not running'

        $r = & $script:Suspend

        $r.failedStep | Should -Be 'stop'
        ($r.steps | Where-Object step -eq 'stop').detail | Should -BeLike '*server not running*'
        $script:Herdr.stops.Count | Should -Be 0
    }

    It 'pauses a worker that has already exited, closing only its leftover pane' {
        $script:Herdr.agents.Clear()
        $script:Gate.readings.Enqueue((New-GateReading -Status 'no-run' -RunStatus ''))

        $r = & $script:Suspend

        $r.outcome | Should -Be 'paused'
        $r.stoppedBy | Should -Be 'not-running'
        ($r.steps | Where-Object step -eq 'pane').detail | Should -BeLike '*pane p1*'
    }

    It 'refuses a pause record it did not write, before touching anything' {
        $null = New-Item -ItemType Directory -Force -Path (Split-Path $script:Record)
        Set-Content -LiteralPath $script:Record -Value 'notes somebody kept here'
        $script:Gate.readings.Enqueue((New-GateReading -RunStatus 'running'))

        $r = & $script:Suspend

        $r.failedStep | Should -Be 'read'
        ($r.steps | Where-Object step -eq 'read').detail | Should -BeLike '*did not write it*not overwritten*'
        Get-Content -LiteralPath $script:Record -Raw | Should -BeLike 'notes somebody kept here*'
        Should -Invoke -ModuleName Teardown Get-GateRunState -Times 0 -Exactly
        $script:Herdr.stops.Count | Should -Be 0
    }

    It 'rewrites its own pause record on a second pause' {
        $null = New-Item -ItemType Directory -Force -Path (Split-Path $script:Record)
        Set-Content -LiteralPath $script:Record -Value @('# Paused - w-pause', '', 'an older pause')
        $script:Gate.readings.Enqueue((New-GateReading -Status 'no-run' -RunStatus ''))

        $r = & $script:Suspend

        $r.outcome | Should -Be 'paused'
        Get-Content -LiteralPath $script:Record -Raw | Should -Not -BeLike '*an older pause*'
    }

    It 'refuses a worker whose copy is gone' {
        Invoke-Git $script:F.repo worktree remove --force $script:Copy | Out-Null

        $r = & $script:Suspend

        $r.failedStep | Should -Be 'read'
        ($r.steps | Where-Object step -eq 'read').detail | Should -BeLike '*not on disk*'
    }

    It 'refuses <name> before touching anything' -ForEach @(
        @{ name = 'a worker in the project''s own checkout'; field = 'checkout'; value = $true; like = '*own checkout*fief*' }
        @{ name = 'a worker whose cleanup already finished'; field = 'torn_down_at'; value = '2026-11-01T00:00:00Z'; like = '*cleanup already finished*' }
        @{ name = 'a project name its record cannot be indexed under'; field = 'repo'; value = 'not/a name'; like = '*could not be indexed*' }
    ) {
        $s = Import-CrewState -Path $script:F.state
        $s.workers['w-pause'][$field] = $value
        Save-CrewState -State $s -Path $script:F.state
        $script:Gate.readings.Enqueue((New-GateReading -RunStatus 'running'))

        $r = & $script:Suspend

        $r.failedStep | Should -Be 'read'
        ($r.steps | Where-Object step -eq 'read').detail | Should -BeLike $like
        Should -Invoke -ModuleName Teardown Get-GateRunState -Times 0 -Exactly
        $script:Herdr.stops.Count | Should -Be 0
    }

    It 'moves nothing when the gate''s head cannot be saved first' {
        Mock -ModuleName Teardown Save-WatchGateRescue { throw 'No gate mirror holds it.' }
        $script:Gate.readings.Enqueue((New-GateReading -RunStatus 'cancelled'))
        $script:Gate.checks.Enqueue((New-SyncAnswer 'blocked_pipeline_owned_recoverable' 'behind' ('c' * 40)))

        $r = & $script:Suspend

        $r.failedStep | Should -Be 'rescue'
        ($r.steps | Where-Object step -eq 'rescue').detail | Should -BeLike '*could not be saved*No gate mirror*'
        $script:Gate.calls | Should -Not -Contain 'axi sync --recover'
    }

    It 'stops at the recover when the gate binary does not answer it' {
        $script:Gate.readings.Enqueue((New-GateReading -RunStatus 'cancelled'))
        $script:Gate.checks.Enqueue((New-SyncAnswer 'blocked_pipeline_owned_recoverable' 'behind'))
        $script:Gate.recover = [pscustomobject]@{ ok = $false; stdout = ''; stderr = ''; exitCode = $null; error = 'it was stopped' }

        $r = & $script:Suspend

        $r.failedStep | Should -Be 'recover'
        ($r.steps | Where-Object step -eq 'recover').detail | Should -BeLike '*could not be recovered*it was stopped*'
        $script:Herdr.stops.Count | Should -Be 0
    }

    It 'stops at the verify when the second custody answer cannot be read' {
        $script:Gate.readings.Enqueue((New-GateReading -RunStatus 'cancelled'))
        $script:Gate.checks.Enqueue((New-SyncAnswer 'blocked_pipeline_owned_recoverable' 'behind'))
        $script:Gate.checks.Enqueue('branch_sync: just text')

        $r = & $script:Suspend

        $r.failedStep | Should -Be 'verify'
        ($r.steps | Where-Object step -eq 'verify').detail | Should -BeLike '*could not be read*'
    }

    It 'stops nothing it has no name for' {
        $script:Herdr.agents.Clear()
        $script:Herdr.agents.Add([pscustomobject]@{ name = ''; pane_id = 'p1'; cwd = $script:Copy; workspace_id = 'w1' })
        $script:Gate.readings.Enqueue((New-GateReading -Status 'no-run' -RunStatus ''))

        $r = & $script:Suspend

        $r.failedStep | Should -Be 'stop'
        ($r.steps | Where-Object step -eq 'stop').detail | Should -BeLike '*unnamed agent*pane p1*'
        $script:Herdr.stops.Count | Should -Be 0
    }

    It 'stops at the stop when a worker on the exit dialog outlives its closed pane' {
        Mock -ModuleName Teardown Remove-HerdrPane { }
        $script:Gate.readings.Enqueue((New-GateReading -Status 'no-run' -RunStatus ''))
        $script:Herdr.stopResult = 'hang'
        $script:Herdr.dialog = $true

        $r = & $script:Suspend

        $r.failedStep | Should -Be 'stop'
        $r.stoppedBy | Should -Be ''
        ($r.steps | Where-Object step -eq 'stop').detail | Should -BeLike '*still there after its pane p1 was closed*'
        Test-Path -LiteralPath $script:Record | Should -BeFalse
    }

    It 'stops at the pane step when a pane in the copy will not close' {
        $script:Herdr.agents.Clear()
        Mock -ModuleName Teardown Remove-HerdrPane { }
        $script:Gate.readings.Enqueue((New-GateReading -Status 'no-run' -RunStatus ''))

        $r = & $script:Suspend

        $r.failedStep | Should -Be 'pane'
        ($r.steps | Where-Object step -eq 'pane').detail | Should -BeLike '*pane p1 did not close*'
        (Import-CrewState -Path $script:F.state).workers['w-pause'].stage | Should -Be 'implementing'
    }

    It 'throws for a worker crew.json does not know' {
        { Suspend-Worker -WorkerId 'nobody' -StatePath $script:F.state -DataPath $script:F.data } |
            Should -Throw '*nothing recorded to pause*'
    }
}
