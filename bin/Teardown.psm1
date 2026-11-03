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
#      commit that is not yet safe, is kept with that reason and nothing is stopped, closed or
#      removed. A commit is safe when it is on a remote branch, or already merged into the local
#      branch the worker was cut from - the crew record's base with a leading `origin/` stripped,
#      so `origin/dev` is checked as `dev` - because merged work is landed work, and a local-only
#      project lands by merging and never pushes. Where the base is empty or that local branch does
#      not exist, only the remote test counts; a base that cannot be read is never taken as safe.
#      The kingshand gate's own `no-mistakes` remote is not counted as a remote here: it is a local
#      repository on this machine, and a commit only there has not reached a server.
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
#      failed and every commit on its branch is safe, by the same test as step 2. git
#      cannot vouch for such a folder - a moved project makes every copy read as unlisted - so any
#      other is kept with the reason `unlisted folder still holds files - check it by hand`, and
#      that is decided in step 2, before anything is touched. A folder that still cannot be deleted
#      is kept with the reason `locked`, once, with no retry loop, and the next sweep counts it
#      again.
#   8. `git worktree prune`, then the branch: deleted only when every commit on it is safe, by the
#      same test as step 2.
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
#
# PAUSING IS NOT CLEANUP. Suspend-Worker ends a worker and keeps everything it made - the copy, the
# branch and the gate's commits - so a later session can start it again in the same copy. It shares
# steps 4 and 5 above and none of the rest, and its own comment owns its order.

# NOT -Force - a module never forces a nested import. The `statute` skill's style rules own why.
Import-Module (Join-Path $PSScriptRoot 'Paths.psm1')
Import-Module (Join-Path $PSScriptRoot 'Herdr.psm1')
Import-Module (Join-Path $PSScriptRoot 'Crew.psm1')
Import-Module (Join-Path $PSScriptRoot 'Projects.psm1')
Import-Module (Join-Path $PSScriptRoot 'ClaudeWorkspace.psm1')
Import-Module (Join-Path $PSScriptRoot 'GateRun.psm1')
Import-Module (Join-Path $PSScriptRoot 'NightsWatch.psm1')
Import-Module (Join-Path $PSScriptRoot 'Index.psm1')

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
    ConvertTo-NormalPath $Path
}

# True when $Path is $Root or somewhere inside it.
function Test-TeardownPathWithin {
    param([string]$Path, [string]$Root)
    Test-PathWithin -Path $Path -Root $Root
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
        if ($x.Equals($p, (Get-PathComparison))) { return $true }
    }
    $false
}

# How many commits reachable from $Rev are not yet safe by step 2's test, or $null where git could
# not say.
function Get-UnpushedCount {
    param([Parameter(Mandatory)][string]$Directory, [Parameter(Mandatory)][string]$Rev, [string]$Base = '')

    # The pattern carries no refs/remotes/ prefix: git matches an --exclude given to --remotes
    # against the name below it.
    $not = @("--exclude=$($script:GateRemote)/*", '--remotes')
    $local = $Base -replace '^origin/', ''
    if ($local) {
        $ref = "refs/heads/$local"
        if ((Invoke-TeardownGit -Directory $Directory -Arguments @('rev-parse', '--verify', '--quiet', $ref)).ok) { $not += $ref }
    }
    $r = Invoke-TeardownGit -Directory $Directory -Arguments (@('rev-list', '--count', $Rev, '--not') + $not)
    if (-not $r.ok) { return $null }
    $n = 0
    if (-not [int]::TryParse($r.text, [ref]$n)) { return $null }
    $n
}

# Whether a copy git still lists may be removed: '' when it may, otherwise the reason it is kept.
function Get-CopyRefusal {
    param([Parameter(Mandatory)][string]$CopyPath, [string]$Base = '')

    $status = Invoke-TeardownGit -Directory $CopyPath -Arguments @('status', '--porcelain')
    if (-not $status.ok) { return "git could not read its status, so it is kept unread: $($status.text)" }
    if ($status.text) {
        $n = @($status.text -split "`n" | Where-Object { $_.Trim() }).Count
        return "it has uncommitted changes ($n paths)"
    }
    $unpushed = Get-UnpushedCount -Directory $CopyPath -Rev 'HEAD' -Base $Base
    if ($null -eq $unpushed) { return 'git could not say whether its commits are on a remote, so it is kept' }
    if ($unpushed -gt 0) { return "$unpushed commits on it are on no remote branch nor merged into its base" }
    ''
}

# Whether a folder git no longer lists may be deleted, by the rule this module's header owns.
function Test-UnlistedCopyRemovable {
    param([string]$CopyPath, [string]$RepoPath, [string]$Branch, [string]$Stage, [string]$Base)

    try { $entries = @(Get-ChildItem -LiteralPath $CopyPath -Force -ErrorAction Stop) } catch { return $false }
    if (@($entries | Where-Object { $script:BuildOutput -notcontains $_.Name }).Count -eq 0) { return $true }
    if ($Stage -notin @('landed', 'failed') -or -not $Branch) { return $false }
    0 -eq (Get-UnpushedCount -Directory $RepoPath -Rev "refs/heads/$Branch" -Base $Base)
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

# Steps 4 and 5 of the order the header owns: close the recorded pane and every pane in the copy,
# check they went, then close a workspace whose last pane just went. Shared by the teardown and by
# Suspend-Worker. '' when every pane went, otherwise the reason it stopped, with nothing after it
# touched.
function Close-CopyPanes {
    param([Parameter(Mandatory)][string]$Copy, [string]$RecordedPaneId = '', $Removed, $Kept)

    $h2 = Read-TeardownHerdr
    if (-not $h2.ok) { return "herdr could not be read after the stop - $($h2.error)" }
    $panes = $h2.panes
    $live = Get-LivePaneIds -Agents $h2.agents
    if ($RecordedPaneId -and -not $h2.workspaces.ok -and -not $live.Contains($RecordedPaneId) -and
        @($panes.panes | Where-Object { "$(Get-TeardownField $_ 'pane_id')" -eq $RecordedPaneId }).Count -gt 0) {
        return "herdr workspaces could not be read, so the recorded pane could not be checked - $($h2.workspaces.error)"
    }
    $ours =@($h2.workspaces.workspaces | Where-Object { "$(Get-TeardownField $_ 'label')" -eq $script:WorkspaceLabel } |
              ForEach-Object { "$(Get-TeardownField $_ 'workspace_id')" })
    $targets = @($panes.panes | Where-Object {
        $id = "$(Get-TeardownField $_ 'pane_id')"
        ((Test-TeardownPathWithin "$(Get-TeardownField $_ 'cwd')" $Copy) -or
         ($RecordedPaneId -and $id -eq $RecordedPaneId -and -not $live.Contains($id) -and
          $ours -contains "$(Get-TeardownField $_ 'workspace_id')"))
    })
    foreach ($p in $targets) {
        $id = "$(Get-TeardownField $p 'pane_id')"
        if ($live.Contains($id)) { return "pane $id still has a live agent in it" }
    }
    $workspaces = @($targets | ForEach-Object { "$(Get-TeardownField $_ 'workspace_id')" })
    foreach ($p in $targets) { Remove-HerdrPane -PaneId "$(Get-TeardownField $p 'pane_id')" }
    if ($targets.Count -gt 0) {
        $after = Read-TeardownHerdrList { Get-HerdrPaneInventory } 'panes'
        if (-not $after.ok) { return "herdr could not confirm the panes closed - $($after.error)" }
        $open = @($after.panes | ForEach-Object { "$(Get-TeardownField $_ 'pane_id')" })
        foreach ($p in $targets) {
            $id = "$(Get-TeardownField $p 'pane_id')"
            if ($open -contains $id) { return "pane $id did not close, so it may still hold the folder" }
            $Removed.Add("pane $id")
        }
    }

    Close-EmptyWorkspaces -WorkspaceIds $workspaces -Removed $Removed -Kept $Kept
    ''
}

# The teardown itself, shared by Remove-WorkerCopy and the sweep. The header owns the order.
function Invoke-CopyTeardown {
    param(
        [Parameter(Mandatory)][string]$CopyPath,
        [string]$Branch = '',
        [string]$RecordedPaneId = '',
        [string]$Stage = '',
        [string]$Base = ''
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
        $why = Get-CopyRefusal -CopyPath $copy -Base $Base
        if ($why) { & $keep $why; return & $result $false }
    } elseif ($exists) {
        if (Test-Path -LiteralPath (Join-Path $copy '.git') -PathType Container) {
            & $keep 'it holds a repository of its own rather than a worktree, so git cannot vouch for it'
            return & $result $false
        }
        if (-not (Test-UnlistedCopyRemovable -CopyPath $copy -RepoPath $repo -Branch $Branch -Stage $Stage -Base $Base)) {
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

    # 4 and 5. The panes, then the workspace a closed pane left empty.
    $why = Close-CopyPanes -Copy $copy -RecordedPaneId $RecordedPaneId -Removed $removed -Kept $kept
    if ($why) { & $keep $why; return & $result $false }

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

    # 8. Prune, then the branch only when all of it is safe.
    $null = Invoke-TeardownGit -Directory $repo -Arguments @('worktree', 'prune')
    if ($Branch) {
        $has = Invoke-TeardownGit -Directory $repo -Arguments @('rev-parse', '--verify', '--quiet', "refs/heads/$Branch")
        if ($has.ok) {
            $unpushed = Get-UnpushedCount -Directory $repo -Rev "refs/heads/$Branch" -Base $Base
            if ($null -eq $unpushed) {
                $kept.Add([pscustomobject]@{ what = "branch $Branch"; why = 'git could not say whether its commits are on a remote' })
            } elseif ($unpushed -gt 0) {
                $kept.Add([pscustomobject]@{ what = "branch $Branch"; why = "$unpushed commits on it are on no remote branch nor merged into its base" })
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
                             -RecordedPaneId "$(Get-TeardownField $rec 'pane_id')" -Stage "$($rec.stage)" `
                             -Base "$(Get-TeardownField $rec 'base')"
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
        $base   = if ($rec) { "$(Get-TeardownField $rec 'base')" } else { '' }
        $r = Invoke-CopyTeardown -CopyPath $c.path -Branch $branch -RecordedPaneId $pane -Stage $stage -Base $base
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

# ---------------------------------------------------------------------------------------------
# Pausing a worker
# ---------------------------------------------------------------------------------------------

# How long one gate call may take. `axi abort` and `axi sync` answer from a local daemon in seconds,
# so this guards against a wedged daemon rather than budgeting slow work - the Hand is blocked until
# the pause returns.
$script:PauseGateTimeoutSeconds = 60

# A run reading one of these has ended and there is nothing to abort. Anything else - running,
# waiting on approval, or a word this does not know - may still own the branch, so it is aborted
# and read again.
$script:EndedRunStatuses = @('completed', 'failed', 'cancelled')

# The pause record's first line. A file at that path not opening with it is somebody else's.
function Get-PauseRecordHeading {
    param([Parameter(Mandatory)][string]$WorkerId)
    "# Paused - $WorkerId"
}

# '' when the pause record may be written - absent, or opening with this command's own heading -
# otherwise why not.
function Get-PauseRecordRefusal {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$WorkerId)

    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    $heading = Get-PauseRecordHeading -WorkerId $WorkerId
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return "$Path is there and is not a file, so it is not overwritten" }
    try { $first = "$(Get-Content -LiteralPath $Path -TotalCount 1 -ErrorAction Stop)" } catch {
        return "$Path is there and could not be read, so it is not overwritten - $($_.Exception.Message)"
    }
    if ($first.TrimEnd() -ne $heading) {
        return "$Path is there and this command did not write it - it does not open with '$heading' - so it is not overwritten"
    }
    ''
}

# The gate binary, run in the copy, for the pause's two calls that drive a run: `axi abort` and
# `axi sync`. GateRun.psm1 reads and never drives - its export list enforces that - so the driving
# lives here beside the one function that needs it.
#
# .ok        whether the binary ran and answered inside the timeout
# .stdout    what it printed
# .stderr    what it said on stderr - progress and its update notice, never state
# .exitCode  its exit code, or $null where it never answered
# .error     why it did not answer, or ''
#
# Never throws. A non-zero exit is not a failure here: `axi sync --check` exits 1 on a blocked
# branch while printing a readable answer, and the caller reads the answer.
function Invoke-PauseGate {
    param([Parameter(Mandatory)][string[]]$Arguments, [Parameter(Mandatory)][string]$Directory)

    $failed = { param($why) [pscustomobject]@{ ok = $false; stdout = ''; stderr = ''; exitCode = $null; error = $why } }
    $exe = Get-NoMistakesCommandPath
    if (-not $exe) { return & $failed (Get-NoMistakesHint) }

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName               = $exe
    $psi.WorkingDirectory       = $Directory
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $psi.StandardErrorEncoding  = [System.Text.UTF8Encoding]::new($false)
    foreach ($a in $Arguments) { $psi.ArgumentList.Add($a) }

    $p = $null
    try {
        $p = [System.Diagnostics.Process]::Start($psi)
        # Both streams are drained before the wait, so a full pipe cannot block the child.
        $out = $p.StandardOutput.ReadToEndAsync()
        $err = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit($script:PauseGateTimeoutSeconds * 1000)) {
            try { $p.Kill($true) } catch { }
            return & $failed "no-mistakes $($Arguments -join ' ') did not answer within $($script:PauseGateTimeoutSeconds) seconds and was stopped"
        }
        $null = [System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]@($out, $err), 10000)
        [pscustomobject]@{
            ok = $true; exitCode = $p.ExitCode; error = ''
            stdout = $(if ($out.IsCompletedSuccessfully) { "$($out.Result)" } else { '' })
            stderr = $(if ($err.IsCompletedSuccessfully) { "$($err.Result)".Trim() } else { '' })
        }
    } catch {
        & $failed "no-mistakes could not be run: $($_.Exception.Message)"
    } finally {
        if ($p) { $p.Dispose() }
    }
}

# Who holds the branch, from `axi sync`'s own answer.
#
# .ok           whether the answer was read
# .safety       branch_sync.safety - custody_returned, blocked_pipeline_owned_recoverable, ...
# .relation     branch_sync.relation - equal, behind, ...
# .currentHead  branch_sync.pipeline.current_head, the gate's own head, or ''
# .note         branch_sync.note, the tool's own words, or ''
# .error        why it could not be read, or ''
#
# The answer is TOON, decoded by GateRun.psm1's vendored decoder and read through its field reader -
# nothing here matches text - so a field that is missing or in a shape this cannot take reads as
# unreadable, never as a state word.
function Read-PauseCustody {
    param([AllowEmptyString()][string]$Text)

    $fail = { param($why) [pscustomobject]@{ ok = $false; safety = ''; relation = ''; currentHead = ''; note = ''; error = $why } }
    if ([string]::IsNullOrWhiteSpace($Text)) { return & $fail 'no-mistakes axi sync printed nothing' }
    $decoded = ConvertFrom-ToonText -Text $Text
    if (-not $decoded.ok) { return & $fail $decoded.error }
    $doc = $null
    try { $doc = $decoded.value | ConvertFrom-Json -AsHashtable } catch {
        return & $fail "its answer did not come back as readable JSON ($($_.Exception.Message))"
    }
    $sync = (Read-ToonField -Table $doc -Key 'branch_sync').value
    if ($sync -isnot [System.Collections.IDictionary]) { return & $fail 'its answer carries no branch_sync object' }
    $safety   = Read-ToonField -Table $sync -Key 'safety'
    $relation = Read-ToonField -Table $sync -Key 'relation'
    if (-not $safety.text)   { return & $fail 'its branch_sync.safety is missing or in a shape this cannot read' }
    if (-not $relation.text) { return & $fail 'its branch_sync.relation is missing or in a shape this cannot read' }
    $pipeline = (Read-ToonField -Table $sync -Key 'pipeline').value
    $head = if ($pipeline -is [System.Collections.IDictionary]) { (Read-ToonField -Table $pipeline -Key 'current_head').text } else { '' }
    [pscustomobject]@{
        ok = $true; safety = $safety.text; relation = $relation.text; currentHead = $head
        note = (Read-ToonField -Table $sync -Key 'note').text; error = ''
    }
}

# `axi sync --check` in the copy, read.
function Get-PauseCustody {
    param([Parameter(Mandatory)][string]$Copy)
    $r = Invoke-PauseGate -Arguments @('axi', 'sync', '--check') -Directory $Copy
    if (-not $r.ok) {
        return [pscustomobject]@{ ok = $false; safety = ''; relation = ''; currentHead = ''; note = ''; error = $r.error }
    }
    Read-PauseCustody -Text $r.stdout
}

function Test-PauseCustodyReturned {
    param($Custody)
    $Custody.ok -and $Custody.safety -eq 'custody_returned' -and $Custody.relation -eq 'equal'
}

function Format-PauseCustody {
    param($Custody)
    $note = if ($Custody.note) { " - no-mistakes said: $($Custody.note)" } else { '' }
    "safety $($Custody.safety), relation $($Custody.relation)$note"
}

# What the gate had reached, in one line for the pause record.
function Format-PauseGateReached {
    param($Gate)

    $run = if ($Gate.runId) { "run $($Gate.runId)" } else { 'its run' }
    $said = if ($Gate.runStatus) { $Gate.runStatus } else { 'no status word' }
    $parts = [System.Collections.Generic.List[string]]::new()
    $parts.Add("$run read $said")
    if ($Gate.isParked) {
        $at = if ($Gate.parkedOn) { "its $($Gate.parkedOn) step" } else { 'a step it did not name' }
        $parts.Add("parked at $at with $(@($Gate.findings).Count) finding(s) to decide")
    }
    $steps = @(@($Gate.steps) | Where-Object { $_ -and $_.status -and $_.status -ne 'pending' } |
               ForEach-Object { "$($_.step) $($_.status)" })
    if ($steps.Count -gt 0) { $parts.Add("steps: $($steps -join ', ')") }
    if ($Gate.pr) { $parts.Add("pull request $($Gate.pr)") }
    if ($Gate.outcome) { $parts.Add("outcome $($Gate.outcome)") }
    $parts -join '; '
}

# The one PowerShell line that starts a paused worker again in its kept copy: herdr's server, a fresh
# pane at the copy, the worker started in it, a prompt pointing it at its brief and its pause record,
# and the crew record moved back to `dispatched` the way rally re-records a relaunch. A worker that
# did not start, sits on a prompt, or bounced the prompt throws before the record moves, as dispatch
# does.
function Format-PauseResumeCommand {
    param([string]$WorkerId, [string]$Copy, [string]$Branch, [string]$Base, [string]$Brief,
          [string]$RecordPath, [string]$StatePath)

    $q = { param($s) "'" + ("$s" -replace "'", "''") + "'" }
    $prompt = ("You were paused and are now started again in the same copy, on the same branch. " +
               "Read your brief at $Brief and anything dispatch wrote beside it, then the pause " +
               "record at $RecordPath, which says where the work stood. Carry on from there. The " +
               'earlier review gate run was ended, so start a fresh one when you reach the gate.')
    $id = & $q $WorkerId
    $state = & $q $StatePath
    ("Import-Module $(& $q (Join-Path $PSScriptRoot 'Herdr.psm1')), $(& $q (Join-Path $PSScriptRoot 'Crew.psm1')); " +
     "Start-HerdrServer; `$p = New-HerdrPane -Cwd $(& $q $Copy); " +
     "if (-not (Start-HerdrAgent -Name $id -PaneId `$p)) { throw `"herdr started no worker in pane `$p`" }; " +
     "if ((Get-HerdrAgentState -Name $id) -eq 'blocked') { throw `"the worker is blocked on a prompt in pane `$p - read it before answering`" }; " +
     "`$r = Send-HerdrPrompt -Name $id -Text $(& $q $prompt); " +
     "if (`$r -and `$r.PSObject.Properties.Name -contains 'blocked') { throw `"the worker did not take its prompt - it is blocked in pane `$p`" }; " +
     "`$s = Import-CrewState -Path $state; Set-CrewRelaunch -State `$s -WorkerId $id " +
     "-Worktree $(& $q $Copy) -Branch $(& $q $Branch) -Base $(& $q $Base); Save-CrewState -State `$s -Path $state")
}

# Pauses one recorded worker: ends its review gate run, brings the gate's commits back to its
# branch, stops it, closes its pane and keeps its copy, then writes down where the work stands.
#
# THE ORDER, and each step stops the pause where it fails, naming the step and why:
#
#   read     The record, its copy on disk, and the pause record's path - which must be absent or
#            this command's own - all checked before anything is touched.
#   gate     The gate run on the worker's branch, read through GateRun.psm1. A run that has not
#            ended is aborted with `no-mistakes axi abort` and read again until it reads ended. An
#            unreadable run ends nothing, and neither does a newest run on another branch, which
#            says nothing about this one. No run on the branch skips the custody steps: the gate
#            holds nothing of it.
#   custody  `axi sync --check`. custody_returned with relation equal is already safe. Only
#            blocked_pipeline_owned_recoverable is recovered; any other answer stops here, because
#            moving a branch nobody understood is how commits are lost.
#   rescue   Before recovering, the gate's own head is saved to a refs/gate/ ref with
#            Save-WatchGateRescue, so the commits are reachable from the repository even if the
#            recover is refused.
#   recover  `axi sync --recover`, which returns the gate's commits to the branch.
#   verify   A second `--check`, which must read custody_returned and equal.
#   stop     Every agent alive in the copy, found by its cwd as cleanup finds it, is stopped with
#            Stop-HerdrAgent. Never a kill. Text in its input box stops the pause with the text
#            quoted. A worker that did not exit because it sits on Claude Code's exit dialog for its
#            own background work has its pane closed instead - the work is already safe by then -
#            and the record says so. One that did not exit with no dialog showing is left running.
#   pane     Steps 4 and 5 of cleanup, shared with it: every pane in the copy and the recorded one.
#   record   data\<id>\pause.md - branch, head, what the gate had reached, uncommitted files and the
#            one command to resume - written and indexed in one call, and the crew stage set to
#            `paused`.
#
# THE COPY AND THE BRANCH ARE NEVER REMOVED, by anything here. Removing them stays Remove-WorkerCopy's
# alone, with its own refusals.
#
# NIGHT'S WATCH DOES NOT USE THIS. Its pause across a usage reset keeps the gate run alive so the
# worker can resume it, and the `nights-watch` skill owns that order.
#
#   .id          the worker
#   .outcome     paused - every step went; failed - .failedStep says where it stopped
#   .failedStep  '' or the step that stopped it
#   .steps       every step reached, each with .step, .ok and .detail
#   .record      the pause record's path, or ''
#   .stoppedBy   exit, pane-closed or not-running - pane-closed where any one worker's pane was
#                closed - or '' where the stop step did not finish
#
# Throws only for a worker crew.json does not know. Everything else is an answer.
function Suspend-Worker {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkerId,
        # The crew record and the data root. Every real caller takes the installation's own; tests
        # point them elsewhere.
        [string]$StatePath = (Get-TeardownDefaultPath 'state\crew.json'),
        [string]$DataPath  = (Get-TeardownDefaultPath 'data')
    )

    $state = Import-CrewState -Path $StatePath
    $rec = Get-CrewWorker -State $state -WorkerId $WorkerId
    if (-not $rec) { throw "Worker '$WorkerId' is not in $StatePath, so there is nothing recorded to pause." }

    $steps = [System.Collections.Generic.List[object]]::new()
    $out = [ordered]@{ id = $WorkerId; outcome = 'failed'; failedStep = ''; steps = @(); record = ''; stoppedBy = '' }
    $done = { param($step, $detail) $steps.Add([pscustomobject]@{ step = $step; ok = $true; detail = $detail }) }
    $stopAt = {
        param($step, $detail)
        $steps.Add([pscustomobject]@{ step = $step; ok = $false; detail = $detail })
        $out.failedStep = $step
        $out.steps = @($steps.ToArray())
        [pscustomobject]$out
    }

    # read
    $copy   = "$($rec.worktree)"
    $branch = "$($rec.branch)"
    $repo   = "$($rec.repo)"
    if ((Get-TeardownField $rec 'checkout') -eq $true) {
        return & $stopAt 'read' ('it runs in the project''s own checkout with no copy of its own - ' +
                                 'fief ends that worker, and this command is for a worker with a copy')
    }
    if (Get-TeardownField $rec 'torn_down_at') { return & $stopAt 'read' 'its cleanup already finished, so there is no copy left to keep' }
    if (-not $copy -or -not (Test-Path -LiteralPath $copy -PathType Container)) {
        return & $stopAt 'read' "its copy is not on disk at '$copy', so there is nothing to keep"
    }
    $copy = ConvertTo-TeardownPath $copy
    $recordPath = Join-Path (Join-Path $DataPath $WorkerId) 'pause.md'
    $why = Get-PauseRecordRefusal -Path $recordPath -WorkerId $WorkerId
    if ($why) { return & $stopAt 'read' "$why, and nothing was touched" }
    try { $null = Get-IndexPath -Project $repo -DataPath $DataPath } catch {
        return & $stopAt 'read' "its pause record could not be indexed under project '$repo', so nothing was touched - $($_.Exception.Message)"
    }
    & $done 'read' "its copy is $copy on branch $branch"

    # gate
    $gate = Get-GateRunState -RepoPath $copy -Branch $branch
    if ($gate.status -eq 'unreadable') {
        return & $stopAt 'gate' "what its review gate is doing could not be read, so nothing was ended - $($gate.detail)"
    }
    if ($gate.signal -eq 'wrong-branch') {
        return & $stopAt 'gate' ("the newest gate run is on another branch, so whether this branch has a live run " +
                                 "could not be told and nothing was ended - $($gate.detail)")
    }
    $hasRun = $gate.status -eq 'has-run'
    $reached = 'no review gate run on this branch'
    if (-not $hasRun) {
        & $done 'gate' "there is no gate run on its branch - $($gate.detail)"
    } else {
        $reached = Format-PauseGateReached -Gate $gate
        if ($gate.runStatus -in $script:EndedRunStatuses -and -not $gate.isParked) {
            & $done 'gate' "its gate run had already ended ($($gate.runStatus)), so there was nothing to end"
        } else {
            $abort = Invoke-PauseGate -Arguments @('axi', 'abort') -Directory $copy
            if (-not $abort.ok) { return & $stopAt 'gate' "its gate run could not be ended - $($abort.error)" }
            $after = Get-GateRunState -RepoPath $copy -Branch $branch
            if ($after.status -ne 'has-run' -or $after.runStatus -notin $script:EndedRunStatuses) {
                $said = if ($abort.stderr) { " no-mistakes said: $($abort.stderr)" } else { '' }
                return & $stopAt 'gate' ("no-mistakes axi abort exited $($abort.exitCode) and the run does not read ended " +
                                         "afterwards - $($after.detail)$said")
            }
            & $done 'gate' "ended its gate run, which now reads $($after.runStatus)"
        }
    }

    # custody, rescue, recover, verify
    $custodyNote = 'the gate never ran on this branch, so it holds none of its commits'
    $rescueRef = ''
    if ($hasRun) {
        $c = Get-PauseCustody -Copy $copy
        if (-not $c.ok) { return & $stopAt 'custody' "who holds the branch could not be read, so nothing was moved - $($c.error)" }
        if (Test-PauseCustodyReturned $c) {
            $custodyNote = 'already back with the copy - custody_returned, equal'
            & $done 'custody' "the branch is $custodyNote"
        } elseif ($c.safety -eq 'blocked_pipeline_owned_recoverable') {
            & $done 'custody' "the gate still holds commits of this branch ($(Format-PauseCustody $c))"

            $local = Invoke-TeardownGit -Directory $copy -Arguments @('rev-parse', 'HEAD')
            if ($c.currentHead -match '^[0-9a-f]{40}$' -and (-not $local.ok -or $local.text -ne $c.currentHead)) {
                try {
                    $rescueRef = (Save-WatchGateRescue -RepoPath $copy -Head $c.currentHead -Task $WorkerId).ref
                } catch {
                    return & $stopAt 'rescue' ("the gate's head $($c.currentHead) could not be saved before " +
                                               "recovering it, so nothing was moved - $($_.Exception.Message)")
                }
                & $done 'rescue' "the gate's head $($c.currentHead) is saved at $rescueRef"
            }
            $saved = if ($rescueRef) { " The gate's commits are saved at $rescueRef." } else { '' }

            $r = Invoke-PauseGate -Arguments @('axi', 'sync', '--recover') -Directory $copy
            if (-not $r.ok) { return & $stopAt 'recover' "the gate's commits could not be recovered - $($r.error).$saved" }
            if ($r.exitCode -ne 0) {
                $said = Read-PauseCustody -Text $r.stdout
                $what = if ($said.ok) { Format-PauseCustody $said } else { "an answer that could not be read - $($said.error)" }
                return & $stopAt 'recover' "no-mistakes refused to recover the gate's commits (exit $($r.exitCode)): $what.$saved"
            }
            & $done 'recover' 'no-mistakes axi sync --recover returned the gate''s commits'

            $v = Get-PauseCustody -Copy $copy
            if (-not $v.ok) { return & $stopAt 'verify' "who holds the branch after the recover could not be read - $($v.error).$saved" }
            if (-not (Test-PauseCustodyReturned $v)) {
                return & $stopAt 'verify' "after the recover the branch reads $(Format-PauseCustody $v), not custody_returned and equal.$saved"
            }
            $custodyNote = "recovered to the branch - custody_returned, equal$(if ($rescueRef) { "; also saved at $rescueRef" })"
            & $done 'verify' 'the branch reads custody_returned and equal'
        } else {
            return & $stopAt 'custody' ("the branch reads $(Format-PauseCustody $c). Only " +
                                        'blocked_pipeline_owned_recoverable is recovered here, so nothing was moved')
        }
    }

    # stop
    $agents = Read-TeardownHerdrList { Get-HerdrAgentInventory } 'agents'
    if (-not $agents.ok) { return & $stopAt 'stop' "herdr could not be read, so the worker was not stopped - $($agents.error)" }
    $mine = @($agents.agents | Where-Object { Test-TeardownPathWithin "$(Get-TeardownField $_ 'cwd')" $copy })
    $out.stoppedBy = 'not-running'
    if ($mine.Count -eq 0) { & $done 'stop' 'no worker was running in the copy' }
    $spaces = [System.Collections.Generic.List[string]]::new()
    foreach ($a in $mine) {
        $name = "$(Get-TeardownField $a 'name')"
        $paneOf = "$(Get-TeardownField $a 'pane_id')"
        if ($name -notmatch '[A-Za-z]') {
            $out.stoppedBy = ''
            return & $stopAt 'stop' "an unnamed agent is live in the copy in pane $paneOf, so there is nothing to stop it by - load rally"
        }
        $stop = Stop-HerdrAgent -Name $name
        if ($stop.stopped) {
            if ($out.stoppedBy -ne 'pane-closed') { $out.stoppedBy = 'exit' }
            & $done 'stop' "worker $name exited"
            continue
        }
        if ($stop.refused) {
            $out.stoppedBy = ''
            return & $stopAt 'stop' "worker $name was not stopped ($($stop.refused)): its box reads '$($stop.promptBox)' and nothing was sent - load rally"
        }
        if (-not (Test-HerdrAgentAwaitingInput -Name $name)) {
            $out.stoppedBy = ''
            return & $stopAt 'stop' "worker $name did not exit and shows no dialog, so it was left running - load rally"
        }
        # The exit dialog for its own background work. Answering it would mean sending keys at a
        # menu nobody has read; the work is safe by now, so the pane is closed instead.
        $pane = if ("$($stop.paneId)") { "$($stop.paneId)" } else { $paneOf }
        if (-not $pane) {
            $out.stoppedBy = ''
            return & $stopAt 'stop' "worker $name sits on a dialog and herdr named no pane for it, so it was left running - load rally"
        }
        Remove-HerdrPane -PaneId $pane
        $again = Read-TeardownHerdrList { Get-HerdrAgentInventory } 'agents'
        if (-not $again.ok) {
            $out.stoppedBy = ''
            return & $stopAt 'stop' "herdr could not confirm worker $name went after its pane $pane was closed - $($again.error)"
        }
        if (@($again.agents | Where-Object { "$(Get-TeardownField $_ 'name')" -eq $name }).Count -gt 0) {
            $out.stoppedBy = ''
            return & $stopAt 'stop' "worker $name is still there after its pane $pane was closed - load rally"
        }
        $ws = "$(Get-TeardownField $a 'workspace_id')"
        if ($ws) { $spaces.Add($ws) }
        $out.stoppedBy = 'pane-closed'
        & $done 'stop' ("worker $name sat on the exit dialog for its own background work, so its pane $pane " +
                        'was closed rather than the dialog answered - its copy and commits were already safe')
    }

    # pane
    $removed = [System.Collections.Generic.List[string]]::new()
    $kept    = [System.Collections.Generic.List[object]]::new()
    Close-EmptyWorkspaces -WorkspaceIds @($spaces) -Removed $removed -Kept $kept
    $why = Close-CopyPanes -Copy $copy -RecordedPaneId "$(Get-TeardownField $rec 'pane_id')" -Removed $removed -Kept $kept
    if ($why) { return & $stopAt 'pane' $why }
    $closed = if ($removed.Count -gt 0) { "closed $($removed -join ', ')" } else { 'no pane was left open' }
    $left = @($kept | ForEach-Object { "$($_.what) kept: $($_.why)" })
    & $done 'pane' ((@($closed) + $left) -join '; ')

    # record
    $head   = Invoke-TeardownGit -Directory $copy -Arguments @('rev-parse', 'HEAD')
    $onto   = Invoke-TeardownGit -Directory $copy -Arguments @('branch', '--show-current')
    $status = Invoke-TeardownGit -Directory $copy -Arguments @('status', '--short')
    foreach ($g in @($head, $onto, $status)) {
        if (-not $g.ok) {
            return & $stopAt 'record' ('the worker is stopped and its copy kept, but git could not read ' +
                                       "the copy for the pause record - $($g.text)")
        }
    }
    $why = Get-PauseRecordRefusal -Path $recordPath -WorkerId $WorkerId
    if ($why) { return & $stopAt 'record' "the worker is stopped and its copy kept, but $why" }

    $uncommitted = if ($status.text) { @('```', $status.text, '```') } else { @('None.') }
    $onBranch = if ($onto.text) { $onto.text } else { 'none - its HEAD is detached' }
    $resume = Format-PauseResumeCommand -WorkerId $WorkerId -Copy $copy -Branch $branch `
                  -Base "$(Get-TeardownField $rec 'base')" -Brief "$($rec.brief)" -RecordPath $recordPath -StatePath $StatePath
    $lines = @(
        (Get-PauseRecordHeading -WorkerId $WorkerId),
        '',
        "Paused $((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm')) UTC by Suspend-Worker. The copy and the branch are kept.",
        '',
        "- Project: $repo",
        "- Copy: $copy",
        "- Branch: $onBranch",
        "- Head: $($head.text)",
        "- Stage before the pause: $($rec.stage)",
        "- Review gate: $reached",
        "- Gate commits: $custodyNote",
        "- Worker: $(($steps | Where-Object { $_.step -eq 'stop' } | ForEach-Object { $_.detail }) -join '; ')",
        '',
        '## Uncommitted files',
        ''
    ) + $uncommitted + @(
        '',
        '## Resume',
        '',
        'One line, run from PowerShell. Arm its watch afterwards, as for any dispatch.',
        '',
        '```powershell',
        $resume,
        '```'
    )
    try {
        $null = Write-DataFile -Path $recordPath -Content ($lines -join "`n") -Project $repo -DataPath $DataPath `
                               -Summary "where paused worker $WorkerId stands, and the one command to resume it"
    } catch {
        return & $stopAt 'record' "the worker is stopped and its copy kept, but the pause record could not be written - $($_.Exception.Message)"
    }
    Set-CrewStage -State $state -WorkerId $WorkerId -Stage 'paused'
    Save-CrewState -State $state -Path $StatePath
    & $done 'record' "wrote $recordPath and set the stage to paused"

    $out.outcome = 'paused'
    $out.record  = $recordPath
    $out.steps   = @($steps.ToArray())
    [pscustomobject]$out
}

Export-ModuleMember -Function Remove-WorkerCopy, Get-WorkerLeftovers, Format-WorkerLeftovers,
                              Invoke-WorkerSweep, Suspend-Worker
