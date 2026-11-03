#Requires -Version 7.0
Set-StrictMode -Version Latest

# bin\Teardown.psm1 against real git repositories in TestDrive, each with a bare repository as its
# remote, and with herdr faked: the six herdr functions the module calls are mocked over one
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
        $deep = $copy
        while ($deep.Length -lt 300) { $deep = Join-Path $deep 'node_modules_nested_package_dir' }
        $null = New-Item -ItemType Directory -Force -Path $deep
        Set-Content -LiteralPath (Join-Path $deep 'f.js') -Value 'x'

        $r = Remove-WorkerCopy -WorkerId 'w-long' -StatePath $script:F.state
        $r.outcome | Should -Be 'removed'
        Test-Path -LiteralPath $copy | Should -BeFalse
    }

    It 'reports a leftover folder something still holds as kept with the reason locked, once (R11)' {
        $copy = New-WorkerCopy $script:F 'w-locked' -Push
        Invoke-Git $script:F.repo worktree remove $copy | Out-Null
        $null = New-Item -ItemType Directory -Force -Path $copy
        $held = Join-Path $copy 'held.txt'
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
            Should -Be 'LEFTOVERS: 2 dead panes, 2 empty workspaces, 2 leftover copies - clear them with Invoke-WorkerSweep from bin\Teardown.psm1.'
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

    It 'keeps a locked leftover with the reason locked and counts it again next time (R11)' {
        $left = New-WorkerCopy $script:F 'w-held' -Push -NoRecord
        Invoke-Git $script:F.repo worktree remove $left | Out-Null
        $null = New-Item -ItemType Directory -Force -Path $left
        $held = Join-Path $left 'held.txt'
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
