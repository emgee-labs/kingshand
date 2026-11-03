#Requires -Version 7.0
Set-StrictMode -Version Latest

# Worker cleanup that finishes, and a sweep for what earlier cleanups left behind.
#
# `muster` Step 8b runs Remove-WorkerCopy and nothing else; `rally` and every other mention point
# here. THIS HEADER OWNS THE ORDER AND THE SAFETY RULES, and nothing restates them.
#
# THE ORDER, and each step exists because of a failure that was seen:
#
#   1. Read everything first - herdr's agents and panes, and git's list of worktrees. A read that
#      fails keeps the copy and names the failure. Nothing open is exactly the answer that lets a
#      folder be deleted, so "could not ask" is never read as "nothing there".
#   2. Refuse before touching anything. A copy with uncommitted changes, or whose HEAD carries a
#      commit that is on no remote branch, is kept with that reason and nothing is stopped, closed
#      or removed. The kingshand gate's own `no-mistakes` remote is not counted as a remote here: it
#      is a local repository on this machine, and a commit only there has not reached a server.
#   3. Stop the agent if one is alive in the copy - found by its cwd, never by the dispatched id,
#      because herdr cuts a long name to 25 characters plus a hash and a stop against the long name
#      reports success having done nothing. Stop-HerdrAgent exits with `/exit` and never kills; a
#      stop that refuses or does not finish keeps everything, and so does an agent herdr lists with
#      no name, because there is nothing to stop it by.
#   4. Close the panes - every pane whose cwd is inside the copy, and the one recorded at dispatch,
#      which is the only way to reach a pane whose worker has already exited. herdr reuses short
#      pane ids, so the recorded one is closed only while it has no live agent and its workspace
#      carries the label dispatch gives it; a recorded id that now names another worker's live pane
#      is skipped, not refused. Where that label cannot be read and the recorded pane is still
#      open, the copy is kept. Then read the list again: a pane still open is still holding the
#      folder, and the copy is kept.
#   5. Close the worker's workspace when its pane was the last one in it. A workspace holding a
#      live agent is never closed.
#   6. `git worktree remove`, never with --force, so git refuses a dirty tree a second time.
#   7. Check the folder is actually gone. Where git dropped the worktree but the folder stayed - a
#      handle still open on it - delete the folder once no pane holds it, long paths included. A
#      folder git no longer lists is deleted only when it has no `.git` entry of any kind and its
#      top-level entries are all build output (node_modules, bin, obj, .angular, dist, build, out,
#      target, .next, .nuxt, coverage, .turbo, .cache), or when its worker is recorded landed or
#      failed and its branch has no commit missing from a remote, by the same test as step 2. git
#      cannot vouch for such a folder - a moved project makes every copy read as unlisted - so any
#      other is kept with the reason `unlisted folder still holds files - check it by hand`, and
#      that is decided in step 2, before anything is touched. A folder that still cannot be deleted
#      is kept with the reason `locked`, once, with no retry loop, and the next sweep counts it
#      again.
#   8. `git worktree prune`, then the branch: deleted only when every commit on it is already on a
#      remote branch, by the same test as step 2.
#   9. Record the cleanup on the worker's crew entry with Set-CrewTornDown.
#
# A worker recorded with `checkout` has no copy: it goes to Stop-CheckoutWorker in
# ClaudeWorkspace.psm1 and nothing here runs on it.
#
# WHAT "KINGSHAND DISPATCHED IT" MEANS. A folder under a registered project's .claude\worktrees is
# kingshand's when its name is a crew.json worker id or data\<name>\brief.md exists - crew.json alone
# is not enough, because older dispatches were not always recorded there. Anything else in that
# folder, such as a copy another tool made, is never counted and never touched. A pane is
# kingshand's when its cwd is inside such a copy or its workspace carries the label dispatch gives
# every workspace it creates.
#
# The sweep never runs on its own. The session-start digest counts what it would clear and names
# it, and the Hand runs it.

# NOT -Force - a module never forces a nested import. The `statute` skill's style rules own why.
Import-Module (Join-Path $PSScriptRoot 'Paths.psm1')
Import-Module (Join-Path $PSScriptRoot 'Herdr.psm1')
Import-Module (Join-Path $PSScriptRoot 'Crew.psm1')
Import-Module (Join-Path $PSScriptRoot 'Projects.psm1')
Import-Module (Join-Path $PSScriptRoot 'ClaudeWorkspace.psm1')

# The label New-HerdrPane gives every workspace dispatch creates.
$script:WorkspaceLabel = 'kingshand'
# The review gate's own remote, which is a repository on this machine rather than a server.
$script:GateRemote = 'no-mistakes'
# The top-level entries a folder git no longer lists may hold and still be deleted unread.
$script:BuildOutput = @('node_modules', 'bin', 'obj', '.angular', 'dist', 'build', 'out', 'target',
                        '.next', '.nuxt', 'coverage', '.turbo', '.cache')

function Get-TeardownDefaultPath {
    param([string]$Leaf)
    Join-Path (Get-KingshandHome) $Leaf
}

function Invoke-TeardownGit {
    param([Parameter(Mandatory)][string]$Directory, [Parameter(Mandatory)][string[]]$Arguments)

    $PSNativeCommandUseErrorActionPreference = $false
    $out  = & git -C $Directory @Arguments 2>&1
    $code = $LASTEXITCODE
    $global:LASTEXITCODE = 0
    $text = (@($out) | ForEach-Object { "$_" }) -join "`n"
    [pscustomobject]@{ ok = ($code -eq 0); text = $text.Trim(); code = $code }
}

function ConvertTo-TeardownPath {
    param([string]$Path)
    if (-not $Path) { return '' }
    [System.IO.Path]::TrimEndingDirectorySeparator([System.IO.Path]::GetFullPath($Path))
}

# True when $Path is $Root or somewhere inside it.
function Test-TeardownPathWithin {
    param([string]$Path, [string]$Root)
    if (-not $Path -or -not $Root) { return $false }
    $p = ConvertTo-TeardownPath $Path
    $r = ConvertTo-TeardownPath $Root
    $p.Equals($r, [StringComparison]::OrdinalIgnoreCase) -or
        $p.StartsWith($r + [System.IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}

function Get-TeardownField {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }
    if ($Object.PSObject.Properties.Name -contains $Name) { return $Object.$Name }
    $null
}

# git's own list of a repository's worktrees, read from `--porcelain -z`, whose records git
# defines: NUL-separated lines, each worktree opening with `worktree <path>`.
function Get-RegisteredCopies {
    param([Parameter(Mandatory)][string]$RepoPath)

    $r = Invoke-TeardownGit -Directory $RepoPath -Arguments @('worktree', 'list', '--porcelain', '-z')
    if (-not $r.ok) {
        return [pscustomobject]@{ ok = $false; paths = @(); error = "git worktree list in $RepoPath failed: $($r.text)" }
    }
    $paths = foreach ($field in ($r.text -split "`0")) {
        $f = $field.Trim("`n")
        if ($f.StartsWith('worktree ')) { ConvertTo-TeardownPath $f.Substring(9) }
    }
    [pscustomobject]@{ ok = $true; paths = @($paths); error = '' }
}

function Test-TeardownRegistered {
    param($Registered, [string]$Path)
    $p = ConvertTo-TeardownPath $Path
    foreach ($x in @($Registered.paths)) {
        if ($x.Equals($p, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    $false
}

# How many commits reachable from $Rev are on no remote branch, or $null where git could not say.
function Get-UnpushedCount {
    param([Parameter(Mandatory)][string]$Directory, [Parameter(Mandatory)][string]$Rev)

    $r = Invoke-TeardownGit -Directory $Directory -Arguments @(
        # The pattern carries no refs/remotes/ prefix: git matches an --exclude given to --remotes
        # against the name below it.
        'rev-list', '--count', $Rev, '--not', "--exclude=$($script:GateRemote)/*", '--remotes')
    if (-not $r.ok) { return $null }
    $n = 0
    if (-not [int]::TryParse($r.text, [ref]$n)) { return $null }
    $n
}

# Whether a copy git still lists may be removed: '' when it may, otherwise the reason it is kept.
function Get-CopyRefusal {
    param([Parameter(Mandatory)][string]$CopyPath)

    $status = Invoke-TeardownGit -Directory $CopyPath -Arguments @('status', '--porcelain')
    if (-not $status.ok) { return "git could not read its status, so it is kept unread: $($status.text)" }
    if ($status.text) {
        $n = @($status.text -split "`n" | Where-Object { $_.Trim() }).Count
        return "it has uncommitted changes ($n paths)"
    }
    $unpushed = Get-UnpushedCount -Directory $CopyPath -Rev 'HEAD'
    if ($null -eq $unpushed) { return 'git could not say whether its commits are on a remote, so it is kept' }
    if ($unpushed -gt 0) { return "$unpushed commits on it are on no remote branch" }
    ''
}

# Whether a folder git no longer lists may be deleted, by the rule this module's header owns.
function Test-UnlistedCopyRemovable {
    param([string]$CopyPath, [string]$RepoPath, [string]$Branch, [string]$Stage)

    try { $entries = @(Get-ChildItem -LiteralPath $CopyPath -Force -ErrorAction Stop) } catch { return $false }
    if (@($entries | Where-Object { $script:BuildOutput -notcontains $_.Name }).Count -eq 0) { return $true }
    if ($Stage -notin @('landed', 'failed') -or -not $Branch) { return $false }
    0 -eq (Get-UnpushedCount -Directory $RepoPath -Rev "refs/heads/$Branch")
}

function Test-KingshandDispatched {
    param([string]$Name, [hashtable]$State, [string]$DataPath)
    if (-not $Name) { return $false }
    if ($State -and $State.workers.ContainsKey($Name)) { return $true }
    Test-Path -LiteralPath (Join-Path (Join-Path $DataPath $Name) 'brief.md') -PathType Leaf
}

# The three herdr reads cleanup acts on, taken together. .error names the first that failed.
#
# A read that throws - no herdr at all, or a binary and server on different versions - comes back
# as a failed read naming why, never as an exception half way through a cleanup.
function Read-TeardownHerdrList {
    param([scriptblock]$Read, [string]$Field)
    try { & $Read } catch {
        $r = [pscustomobject]@{ ok = $false; error = $_.Exception.Message }
        $r | Add-Member -NotePropertyName $Field -NotePropertyValue @()
        $r
    }
}

function Read-TeardownHerdr {
    $agents = Read-TeardownHerdrList { Get-HerdrAgentInventory } 'agents'
    $panes  = Read-TeardownHerdrList { Get-HerdrPaneInventory } 'panes'
    $spaces = Read-TeardownHerdrList { Get-HerdrWorkspaceInventory } 'workspaces'
    $err = @(@($agents, $panes, $spaces) | Where-Object { -not $_.ok } | ForEach-Object { $_.error })
    [pscustomobject]@{
        agents = $agents; panes = $panes; workspaces = $spaces
        ok = ($agents.ok -and $panes.ok); error = ($err -join ' ')
    }
}

function Get-LivePaneIds {
    param($Agents)
    $set = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($a in @($Agents.agents)) {
        $id = "$(Get-TeardownField $a 'pane_id')"
        if ($id) { $null = $set.Add($id) }
    }
    , $set
}

# Closes each workspace in $WorkspaceIds that no longer holds a pane, re-reading herdr first so a
# workspace with a live agent in it - or any pane at all - is left exactly as it is.
function Close-EmptyWorkspaces {
    param([string[]]$WorkspaceIds, $Removed, $Kept)

    $ids = @($WorkspaceIds | Where-Object { $_ } | Select-Object -Unique)
    if ($ids.Count -eq 0) { return }
    $h = Read-TeardownHerdr
    if (-not $h.ok -or -not $h.workspaces.ok) {
        $Kept.Add([pscustomobject]@{ what = "workspaces $($ids -join ', ')"; why = "herdr could not be read - $($h.error)" })
        return
    }
    $listed = @($h.workspaces.workspaces | ForEach-Object { "$(Get-TeardownField $_ 'workspace_id')" })
    $closed = [System.Collections.Generic.List[string]]::new()
    foreach ($ws in $ids) {
        # Already gone - herdr may close a workspace with its last pane - is nothing to do.
        if ($listed -notcontains $ws) { continue }
        $inside = @($h.panes.panes | Where-Object { "$(Get-TeardownField $_ 'workspace_id')" -eq $ws })
        $live   = @($h.agents.agents | Where-Object { "$(Get-TeardownField $_ 'workspace_id')" -eq $ws })
        if ($inside.Count -gt 0 -or $live.Count -gt 0) { continue }
        Remove-HerdrWorkspace -WorkspaceId $ws
        $closed.Add($ws)
    }
    if ($closed.Count -eq 0) { return }
    $after = Read-TeardownHerdrList { Get-HerdrWorkspaceInventory } 'workspaces'
    $still = @(if ($after.ok) { $after.workspaces | ForEach-Object { "$(Get-TeardownField $_ 'workspace_id')" } })
    foreach ($ws in $closed) {
        if (-not $after.ok) { $Kept.Add([pscustomobject]@{ what = "workspace $ws"; why = "herdr could not confirm it closed - $($after.error)" }) }
        elseif ($still -contains $ws) { $Kept.Add([pscustomobject]@{ what = "workspace $ws"; why = 'it did not close' }) }
        else { $Removed.Add("workspace $ws") }
    }
}

# The teardown itself, shared by Remove-WorkerCopy and the sweep. The header owns the order.
function Invoke-CopyTeardown {
    param(
        [Parameter(Mandatory)][string]$CopyPath,
        [string]$Branch = '',
        [string]$RecordedPaneId = '',
        [string]$Stage = ''
    )

    $removed = [System.Collections.Generic.List[string]]::new()
    $kept    = [System.Collections.Generic.List[object]]::new()
    $result  = {
        param([bool]$gone)
        [pscustomobject]@{ copyGone = $gone; removed = @($removed.ToArray()); kept = @($kept.ToArray()) }
    }
    $keep = { param($why) $kept.Add([pscustomobject]@{ what = $CopyPath; why = $why }) }

    $copy = ConvertTo-TeardownPath $CopyPath
    $worktrees = Split-Path -Parent $copy
    if ((Split-Path -Leaf $worktrees) -ne 'worktrees' -or
        (Split-Path -Leaf (Split-Path -Parent $worktrees)) -ne '.claude') {
        & $keep 'it is not under a project''s .claude\worktrees folder, so it is not a worker copy'
        return & $result $false
    }
    $repo = Split-Path -Parent (Split-Path -Parent $worktrees)

    # 1. Read everything first.
    $h = Read-TeardownHerdr
    if (-not $h.ok) { & $keep "herdr could not be read, so nothing was touched - $($h.error)"; return & $result $false }
    $registered = Get-RegisteredCopies -RepoPath $repo
    if (-not $registered.ok) { & $keep "git could not be read, so nothing was touched - $($registered.error)"; return & $result $false }

    $exists = Test-Path -LiteralPath $copy
    $isRegistered = Test-TeardownRegistered -Registered $registered -Path $copy

    # 2. Refuse before touching anything.
    if ($exists -and $isRegistered) {
        $why = Get-CopyRefusal -CopyPath $copy
        if ($why) { & $keep $why; return & $result $false }
    } elseif ($exists) {
        if (Test-Path -LiteralPath (Join-Path $copy '.git') -PathType Container) {
            & $keep 'it holds a repository of its own rather than a worktree, so git cannot vouch for it'
            return & $result $false
        }
        if (-not (Test-UnlistedCopyRemovable -CopyPath $copy -RepoPath $repo -Branch $Branch -Stage $Stage)) {
            & $keep 'unlisted folder still holds files - check it by hand'
            return & $result $false
        }
    }

    # 3. Stop any agent alive in the copy, found by cwd.
    $stopped = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($a in @($h.agents.agents | Where-Object { Test-TeardownPathWithin "$(Get-TeardownField $_ 'cwd')" $copy })) {
        $name = "$(Get-TeardownField $a 'name')"
        if ($name -notmatch '[A-Za-z]') {
            & $keep "an unnamed agent is live in it in pane $(Get-TeardownField $a 'pane_id') - load rally"
            return & $result $false
        }
        $stop = Stop-HerdrAgent -Name $name
        if (-not $stop.stopped) {
            $why = if ($stop.refused) { "its worker $name was not stopped ($($stop.refused)): its box reads '$($stop.promptBox)' - load rally" }
                   else { "its worker $name did not exit, so it still holds the folder" }
            & $keep $why
            return & $result $false
        }
        $removed.Add("worker $name")
        $paneOf = "$(Get-TeardownField $a 'pane_id')"
        if ($paneOf) { $null = $stopped.Add($paneOf) }
    }

    # 4. Close the recorded pane and every pane in the copy, then check they went.
    $h2 = Read-TeardownHerdr
    if (-not $h2.ok) { & $keep "herdr could not be read after the stop - $($h2.error)"; return & $result $false }
    $panes = $h2.panes
    $live = Get-LivePaneIds -Agents $h2.agents
    if ($RecordedPaneId -and -not $h2.workspaces.ok -and -not $live.Contains($RecordedPaneId) -and
        @($panes.panes | Where-Object { "$(Get-TeardownField $_ 'pane_id')" -eq $RecordedPaneId }).Count -gt 0) {
        & $keep "herdr workspaces could not be read, so the recorded pane could not be checked - $($h2.workspaces.error)"
        return & $result $false
    }
    $ours =@($h2.workspaces.workspaces | Where-Object { "$(Get-TeardownField $_ 'label')" -eq $script:WorkspaceLabel } |
              ForEach-Object { "$(Get-TeardownField $_ 'workspace_id')" })
    $targets = @($panes.panes | Where-Object {
        $id = "$(Get-TeardownField $_ 'pane_id')"
        ((Test-TeardownPathWithin "$(Get-TeardownField $_ 'cwd')" $copy) -or
         ($RecordedPaneId -and $id -eq $RecordedPaneId -and -not $live.Contains($id) -and
          $ours -contains "$(Get-TeardownField $_ 'workspace_id')"))
    })
    foreach ($p in $targets) {
        $id = "$(Get-TeardownField $p 'pane_id')"
        if ($live.Contains($id)) {
            & $keep "pane $id still has a live agent in it"
            return & $result $false
        }
    }
    $workspaces = @($targets | ForEach-Object { "$(Get-TeardownField $_ 'workspace_id')" })
    foreach ($p in $targets) { Remove-HerdrPane -PaneId "$(Get-TeardownField $p 'pane_id')" }
    if ($targets.Count -gt 0) {
        $after = Read-TeardownHerdrList { Get-HerdrPaneInventory } 'panes'
        if (-not $after.ok) { & $keep "herdr could not confirm the panes closed - $($after.error)"; return & $result $false }
        $open = @($after.panes | ForEach-Object { "$(Get-TeardownField $_ 'pane_id')" })
        foreach ($p in $targets) {
            $id = "$(Get-TeardownField $p 'pane_id')"
            if ($open -contains $id) { & $keep "pane $id did not close, so it may still hold the folder"; return & $result $false }
            $removed.Add("pane $id")
        }
    }

    # 5. The workspace, when its last pane just went.
    Close-EmptyWorkspaces -WorkspaceIds $workspaces -Removed $removed -Kept $kept

    # 6. git worktree remove, never forced.
    if ($exists -and $isRegistered) {
        $rm = Invoke-TeardownGit -Directory $repo -Arguments @('worktree', 'remove', $copy)
        $again = Get-RegisteredCopies -RepoPath $repo
        if (-not $again.ok) { & $keep "git could not confirm the removal - $($again.error)"; return & $result $false }
        if (Test-TeardownRegistered -Registered $again -Path $copy) {
            & $keep "git worktree remove refused: $($rm.text)"
            return & $result $false
        }
    }

    # 7. The folder is gone, or it is deleted once, or it is kept as locked.
    if (Test-Path -LiteralPath $copy) {
        try {
            Remove-Item -LiteralPath $copy -Recurse -Force -ErrorAction Stop
        } catch {
            & $keep "locked - something still holds the folder ($($_.Exception.Message)); the next sweep tries again"
        }
    }
    $gone = -not (Test-Path -LiteralPath $copy)
    if ($gone -and $exists) { $removed.Add("copy $copy") }

    # 8. Prune, then the branch only when all of it is on a remote.
    $null = Invoke-TeardownGit -Directory $repo -Arguments @('worktree', 'prune')
    if ($Branch) {
        $has = Invoke-TeardownGit -Directory $repo -Arguments @('rev-parse', '--verify', '--quiet', "refs/heads/$Branch")
        if ($has.ok) {
            $unpushed = Get-UnpushedCount -Directory $repo -Rev "refs/heads/$Branch"
            if ($null -eq $unpushed) {
                $kept.Add([pscustomobject]@{ what = "branch $Branch"; why = 'git could not say whether its commits are on a remote' })
            } elseif ($unpushed -gt 0) {
                $kept.Add([pscustomobject]@{ what = "branch $Branch"; why = "$unpushed commits on it are on no remote branch" })
            } else {
                $del = Invoke-TeardownGit -Directory $repo -Arguments @('branch', '-D', $Branch)
                if ($del.ok) { $removed.Add("branch $Branch") }
                else { $kept.Add([pscustomobject]@{ what = "branch $Branch"; why = "git branch -D refused: $($del.text)" }) }
            }
        }
    }

    & $result $gone
}

# Tears one recorded worker down, in the order this module's header owns, and records it.
#
#   .id        the worker
#   .outcome   removed - the copy and its panes are gone; kept - something stopped it, see .kept
#   .removed   what went: worker, panes, workspace, copy, branch
#   .kept      what stayed, each with .what and .why
#
# Throws only for a worker crew.json does not know. Everything else is an answer.
function Remove-WorkerCopy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkerId,
        # The crew record. Every real caller takes the installation's own; tests point it elsewhere.
        [string]$StatePath = (Get-TeardownDefaultPath 'state\crew.json')
    )

    $state = Import-CrewState -Path $StatePath
    $rec = Get-CrewWorker -State $state -WorkerId $WorkerId
    if (-not $rec) { throw "Worker '$WorkerId' is not in $StatePath, so there is nothing recorded to clean up." }

    if ((Get-TeardownField $rec 'checkout') -eq $true) {
        try {
            $c = Stop-CheckoutWorker -Name $WorkerId -RecordPath "$($rec.settings_record)" -EndSession
        } catch {
            return [pscustomobject]@{
                id = $WorkerId; outcome = 'kept'; removed = @()
                kept = @([pscustomobject]@{ what = "worker $WorkerId"; why = $_.Exception.Message })
            }
        }
        Set-CrewTornDown -State $state -WorkerId $WorkerId
        Save-CrewState -State $state -Path $StatePath
        $what = @("worker $WorkerId", "settings $($c.settings)")
        if ($c.paneRemoved) { $what += 'pane' }
        return [pscustomobject]@{ id = $WorkerId; outcome = 'removed'; removed = $what; kept = @() }
    }

    $r = Invoke-CopyTeardown -CopyPath "$($rec.worktree)" -Branch "$($rec.branch)" `
                             -RecordedPaneId "$(Get-TeardownField $rec 'pane_id')" -Stage "$($rec.stage)"
    if ($r.copyGone) {
        Set-CrewTornDown -State $state -WorkerId $WorkerId
        Save-CrewState -State $state -Path $StatePath
    }
    [pscustomobject]@{
        id      = $WorkerId
        outcome = if ($r.copyGone) { 'removed' } else { 'kept' }
        removed = $r.removed
        kept    = $r.kept
    }
}

# What earlier cleanups left behind, counted - the session-start digest's one line and the sweep's
# work list. Every count is $null where its read failed, and .problems says which, so a failed read
# is never printed as nothing left over.
#
#   .deadPanes        panes with no live agent, in a kingshand copy or a kingshand workspace
#   .emptyWorkspaces  kingshand workspaces with no pane, or with only dead ones
#   .copies           dispatched folders git no longer lists, and copies git still lists for a
#                     worker recorded landed or failed - each with .path, .name, .workerId, .reason
#   .problems         every read that failed, in words
function Get-WorkerLeftovers {
    [CmdletBinding()]
    param(
        [string]$RegistryPath = (Get-TeardownDefaultPath 'data\projects.md'),
        [string]$StatePath    = (Get-TeardownDefaultPath 'state\crew.json'),
        [string]$DataPath     = (Get-TeardownDefaultPath 'data')
    )

    $problems = [System.Collections.Generic.List[string]]::new()

    $state = $null
    try { $state = Import-CrewState -Path $StatePath } catch { $problems.Add("crew.json could not be read: $($_.Exception.Message)") }
    $projects = @()
    # Assigned bare: Get-AllProjects hands back its list as one object, and @() would nest it. No
    # registry at all is nothing registered - an ordinary state - rather than a failed read.
    try {
        if (Test-Path -LiteralPath $RegistryPath -PathType Leaf) { $projects = Get-AllProjects -RegistryPath $RegistryPath }
    } catch { $problems.Add("the registry could not be read: $($_.Exception.Message)") }

    # Copies, per registered project.
    $copies = [System.Collections.Generic.List[object]]::new()
    $roots  = [System.Collections.Generic.List[string]]::new()
    $copiesOk = ($null -ne $state) -and ($problems.Count -eq 0)
    if ($copiesOk) {
        foreach ($p in $projects) {
            $path = "$(Get-TeardownField $p 'path')"
            if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Container)) { continue }
            $dir = Join-Path (Join-Path $path '.claude') 'worktrees'
            if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
            $null = $roots.Add($dir)
            $reg = Get-RegisteredCopies -RepoPath $path
            if (-not $reg.ok) { $problems.Add($reg.error); $copiesOk = $false; continue }
            foreach ($d in @(Get-ChildItem -LiteralPath $dir -Directory -Force -ErrorAction SilentlyContinue)) {
                if (-not (Test-KingshandDispatched -Name $d.Name -State $state -DataPath $DataPath)) { continue }
                $full = ConvertTo-TeardownPath $d.FullName
                $wid = if ($state.workers.ContainsKey($d.Name)) { $d.Name } else { '' }
                if (-not (Test-TeardownRegistered -Registered $reg -Path $full)) {
                    $copies.Add([pscustomobject]@{ path = $full; name = $d.Name; workerId = $wid; reason = 'git no longer lists it' })
                    continue
                }
                if ($wid -and "$($state.workers[$wid].stage)" -in @('landed', 'failed') -and
                    (Get-TeardownField $state.workers[$wid] 'checkout') -ne $true) {
                    $copies.Add([pscustomobject]@{ path = $full; name = $d.Name; workerId = $wid; reason = "its worker is recorded $($state.workers[$wid].stage)" })
                }
            }
        }
    }

    # Panes and workspaces.
    $deadPanes = $null; $emptyWorkspaces = $null
    $h = Read-TeardownHerdr
    if ($h.ok) {
        $live = Get-LivePaneIds -Agents $h.agents
        $kingshandSpaces = @($h.workspaces.workspaces | Where-Object { "$(Get-TeardownField $_ 'label')" -eq $script:WorkspaceLabel } |
                             ForEach-Object { "$(Get-TeardownField $_ 'workspace_id')" })
        $inCopy = {
            param($cwd)
            foreach ($r in $roots) {
                if (-not (Test-TeardownPathWithin $cwd $r)) { continue }
                $rest = (ConvertTo-TeardownPath $cwd).Substring((ConvertTo-TeardownPath $r).Length).TrimStart('\', '/')
                $name = ($rest -split '[\\/]')[0]
                if ($name -and (Test-KingshandDispatched -Name $name -State $state -DataPath $DataPath)) { return $true }
            }
            $false
        }
        $deadPanes = @($h.panes.panes | Where-Object {
            -not $live.Contains("$(Get-TeardownField $_ 'pane_id')") -and
            (($kingshandSpaces -contains "$(Get-TeardownField $_ 'workspace_id')") -or (& $inCopy "$(Get-TeardownField $_ 'cwd')"))
        })
        if ($h.workspaces.ok) {
            $emptyWorkspaces = @($h.workspaces.workspaces | Where-Object {
                $ws = "$(Get-TeardownField $_ 'workspace_id')"
                if ($kingshandSpaces -notcontains $ws) { return $false }
                $inside = @($h.panes.panes | Where-Object { "$(Get-TeardownField $_ 'workspace_id')" -eq $ws })
                $liveIn = @($inside | Where-Object { $live.Contains("$(Get-TeardownField $_ 'pane_id')") })
                $liveIn.Count -eq 0
            })
        } else {
            $problems.Add("herdr workspaces could not be read - $($h.workspaces.error)")
        }
    } else {
        $problems.Add("herdr could not be read - $($h.error)")
    }

    # Assigned rather than returned from an `if`, which would turn an empty list into $null - and
    # $null here means unreadable.
    $copyList = $null
    if ($copiesOk) { $copyList = [object[]]$copies.ToArray() }
    [pscustomobject]@{
        deadPanes       = $deadPanes
        emptyWorkspaces = $emptyWorkspaces
        copies          = $copyList
        problems        = @($problems.ToArray())
    }
}

# The digest's one line, or '' when there is nothing left over and every read succeeded.
function Format-WorkerLeftovers {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Leftovers)

    $part = {
        param($items, $noun)
        if ($null -eq $items) { return "$noun unreadable" }
        "$(@($items).Count) $noun"
    }
    $counts = @(
        (& $part $Leftovers.deadPanes 'dead panes'),
        (& $part $Leftovers.emptyWorkspaces 'empty workspaces'),
        (& $part $Leftovers.copies 'leftover copies')
    )
    $any = @(@($Leftovers.deadPanes) + @($Leftovers.emptyWorkspaces) + @($Leftovers.copies) | Where-Object { $_ }).Count
    $problems = @($Leftovers.problems)
    if ($any -eq 0 -and $problems.Count -eq 0) { return '' }
    # Short on purpose: the digest is built to fit a fixed limit, and the full reason for a failed
    # read is the sweep's to report, not this line's.
    $line = "LEFTOVERS: $($counts -join ', ') - Invoke-WorkerSweep (bin\Teardown.psm1) clears them."
    if ($problems.Count -gt 0) {
        $why = ($problems[0] -replace '\s+', ' ').Trim()
        if ($why.Length -gt 60) { $why = $why.Substring(0, 60) + '...' }
        $line += " Unreadable: $why"
    }
    $line
}

# Clears what Get-WorkerLeftovers counts: closes every dead pane, tears down every leftover copy by
# this module's rules, then closes every kingshand workspace left with no live agent. The Hand runs
# it; nothing runs it on its own.
#
#   .summary  one line of totals
#   .removed  what went
#   .kept     what stayed, each with .what and .why
function Invoke-WorkerSweep {
    [CmdletBinding()]
    param(
        [string]$RegistryPath = (Get-TeardownDefaultPath 'data\projects.md'),
        [string]$StatePath    = (Get-TeardownDefaultPath 'state\crew.json'),
        [string]$DataPath     = (Get-TeardownDefaultPath 'data')
    )

    $removed = [System.Collections.Generic.List[string]]::new()
    $kept    = [System.Collections.Generic.List[object]]::new()

    $found = Get-WorkerLeftovers -RegistryPath $RegistryPath -StatePath $StatePath -DataPath $DataPath
    foreach ($p in @($found.problems)) { $kept.Add([pscustomobject]@{ what = 'the count'; why = $p }) }

    $panesClosed = 0
    $dead = @(@($found.deadPanes) | Where-Object { $_ } | ForEach-Object { "$(Get-TeardownField $_ 'pane_id')" })
    foreach ($id in $dead) { Remove-HerdrPane -PaneId $id }
    if ($dead.Count -gt 0) {
        $after = Read-TeardownHerdrList { Get-HerdrPaneInventory } 'panes'
        $open = @(if ($after.ok) { $after.panes | ForEach-Object { "$(Get-TeardownField $_ 'pane_id')" } })
        foreach ($id in $dead) {
            if (-not $after.ok) { $kept.Add([pscustomobject]@{ what = "pane $id"; why = "herdr could not confirm it closed - $($after.error)" }) }
            elseif ($open -contains $id) { $kept.Add([pscustomobject]@{ what = "pane $id"; why = 'it did not close' }) }
            else { $removed.Add("pane $id"); $panesClosed++ }
        }
    }

    $copiesRemoved = 0
    $state = if ($null -ne $found.copies) { Import-CrewState -Path $StatePath } else { $null }
    foreach ($c in @($found.copies)) {
        $rec = if ($c.workerId) { Get-CrewWorker -State $state -WorkerId $c.workerId } else { $null }
        $branch = if ($rec) { "$($rec.branch)" } else { "worktree-$($c.name)" }
        $pane   = if ($rec) { "$(Get-TeardownField $rec 'pane_id')" } else { '' }
        $stage  = if ($rec) { "$($rec.stage)" } else { '' }
        $r = Invoke-CopyTeardown -CopyPath $c.path -Branch $branch -RecordedPaneId $pane -Stage $stage
        foreach ($x in $r.removed) { $removed.Add($x) }
        foreach ($x in $r.kept) { $kept.Add($x) }
        if ($r.copyGone) {
            $copiesRemoved++
            if ($rec) { Set-CrewTornDown -State $state -WorkerId $c.workerId }
        }
    }
    if ($state -and $copiesRemoved -gt 0) { Save-CrewState -State $state -Path $StatePath }

    $before = @($removed | Where-Object { $_ -like 'workspace *' }).Count
    $spaces = @(@($found.emptyWorkspaces) | ForEach-Object { "$(Get-TeardownField $_ 'workspace_id')" })
    Close-EmptyWorkspaces -WorkspaceIds $spaces -Removed $removed -Kept $kept
    $spacesClosed = @($removed | Where-Object { $_ -like 'workspace *' }).Count - $before

    [pscustomobject]@{
        summary = ("Sweep: $panesClosed dead panes closed, $copiesRemoved leftover copies removed, " +
                   "$spacesClosed workspaces closed, $($kept.Count) kept.")
        removed = @($removed.ToArray())
        kept    = @($kept.ToArray())
    }
}

Export-ModuleMember -Function Remove-WorkerCopy, Get-WorkerLeftovers, Format-WorkerLeftovers,
                              Invoke-WorkerSweep
