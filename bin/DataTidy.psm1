#Requires -Version 7.0
Set-StrictMode -Version Latest

# The data tidy: deletes the one provably safe class of duplicate under data\ and reports
# everything else it suspects, for the King to decide. It runs only when the Hand runs it, and it is
# not part of `chronicle` - that pass curates the two memory files, often just before a context
# reset with nobody watching, and a pass nobody watches must not be able to destroy work.
#
# WHY SO LITTLE IS DELETED. data\ is gitignored, so a deleted file has no blob to restore and no
# recovery of any kind. Telling "dead" from "dormant" is the whole difficulty: a directory that looks
# idle can hold the only record of a paused item's unpushed work. So exactly one class is removed,
# and only when every one of these holds at the moment of removal:
#
#   - the file is a dispatch's staged copy (Index.psm1's Test-IndexStagedCopy) sitting directly at
#     data\<id>\read-first\<leaf>;
#   - the backlog, asked through `tasks-axi`, lists <id> and says it is `done`;
#   - the copy's original is on disk at its canonical path and its bytes are identical to the copy's,
#     so deleting the copy loses nothing that is not still on disk elsewhere;
#   - Get-DataTidyRefusal finds no rule against it - report.md, a brief, a standing file, memory,
#     the backlog and anything under state\ are refused whatever else is true.
#
# Everything else is reported with its reason and left where it is: a copy that fails any of the
# above, an item directory whose work is closed or that the backlog does not list, a brief revision
# beside brief.md, and every file the index has lost track of. Anything this cannot classify is
# reported, never removed.
#
# THE CANONICAL ORIGINAL is found by name, from the staging names Dispatch-Worker.ps1 composes:
# `family-<name>.md` is data\families\<name>.md, `SKILL.md` and `BrowserVerify.psm1` are the browser
# procedure and its module in this installation, and every other leaf is data\<leaf> - where settled
# files and every project's standing files live. A wrong guess here can only fail closed: the bytes
# are compared before anything goes, so a candidate that is not the original keeps the copy.
#
# A DRY RUN IS THE DEFAULT. Nothing is removed without -Apply, and the answer is the same shape
# either way, so what a dry run said would go is exactly what -Apply removes - each condition is
# checked again at the moment of removal rather than trusted from earlier in the call.
#
# THE BACKLOG IS NEVER PARSED HERE. `tasks-axi list` is asked once and its TOON answer decoded by
# GateRun.psm1's decoder. An answer that cannot be read deletes nothing and says so; an item the
# backlog does not list - which includes every item it has archived, because no tasks-axi command
# reads the archive back - is never shown closed, so its copies stay.

# Nested imports WITHOUT -Force - `statute`'s style rules own why.
Import-Module (Join-Path $PSScriptRoot 'Paths.psm1')
Import-Module (Join-Path $PSScriptRoot 'Index.psm1')
Import-Module (Join-Path $PSScriptRoot 'GateRun.psm1')

# Large enough that no backlog is cut short. A short list is refused below rather than trusted.
$script:ListLimit = 1000000

# Top-level data\ directories that belong to kingshand itself rather than to a work item.
$script:OwnDirectories = @('index', 'families', 'away')

# Leaves refused wherever they sit. report.md and a brief are never deleted, not even as a copy,
# because each can be the only record of what a worker found or was told.
$script:ProtectedLeaves = @('report.md', 'king.md', 'learnings.md', 'instructions.md', 'backlog.md')

# The one boundary to `tasks-axi`, run from the directory whose .tasks.toml selects the backlog.
function Invoke-TidyTasksAxi {
    param(
        [Parameter(Mandatory)][string]$QueueRoot,
        [Parameter(Mandatory)][string[]]$Arguments
    )
    $exe = Get-Command 'tasks-axi' -CommandType Application -ErrorAction SilentlyContinue |
           Select-Object -First 1
    if (-not $exe) { return [pscustomobject]@{ ok = $false; text = ''; error = 'tasks-axi is not installed.' } }
    if (-not (Test-Path -LiteralPath $QueueRoot -PathType Container)) {
        return [pscustomobject]@{ ok = $false; text = ''; error = "$QueueRoot does not exist." }
    }
    Push-Location -LiteralPath $QueueRoot
    try {
        $out  = & $exe.Source @Arguments 2>&1 | Out-String
        $code = $LASTEXITCODE
        $global:LASTEXITCODE = 0
    } finally { Pop-Location }
    if ($code -ne 0) { return [pscustomobject]@{ ok = $false; text = $out; error = "tasks-axi exited $code." } }
    [pscustomobject]@{ ok = $true; text = $out; error = '' }
}

# Every item the backlog lists, by id, with its state and closed date. Asked of tasks-axi, never
# read out of backlog.md.
#
# .readable  whether the answer was read; $false means no item is known, never that none exist
# .items     id -> @{ state; closed }
# .problem   why it could not be read
function Get-TidyBacklog {
    param([Parameter(Mandatory)][string]$QueueRoot)

    $fail = { param($why) [pscustomobject]@{ readable = $false; items = @{}; problem = $why } }

    $r = Invoke-TidyTasksAxi -QueueRoot $QueueRoot -Arguments @(
        'list', '--limit', "$script:ListLimit", '--fields', 'closed')
    if (-not $r.ok) { return (& $fail "The backlog could not be read: $($r.error) $($r.text)".Trim()) }

    $decoded = ConvertFrom-ToonText -Text $r.text
    if (-not $decoded.ok) { return (& $fail "The backlog's answer could not be decoded: $($decoded.error)") }
    try { $doc = $decoded.value | ConvertFrom-Json -AsHashtable -ErrorAction Stop }
    catch { return (& $fail "The backlog's answer was not the shape expected: $($_.Exception.Message)") }
    if ($doc -isnot [System.Collections.IDictionary]) { return (& $fail "The backlog's answer was not an object.") }

    $count = Get-ToonNumber -Table $doc -Key 'count'
    if ($null -eq $count) {
        return (& $fail "The backlog's answer carries no whole count of its items, so it may be a partial list.")
    }

    # An empty backlog answers with a sentence where the table would be. That sentence is only
    # believed alongside a count of zero.
    $table = Read-ToonTable -Table $doc -Key 'tasks'
    $rows  = @()
    if ($count -gt 0) {
        if (-not $table.present -or $table.shape) {
            return (& $fail "The backlog's answer counts $count items but carries no readable table of them.")
        }
        $rows = @($table.rows)
    }
    if ($rows.Count -ne $count) {
        return (& $fail "The backlog's answer counts $count items and lists $($rows.Count), so it may be a partial list.")
    }

    $items = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($row in $rows) {
        $id    = Get-ToonText -Table $row -Key 'id'
        $state = Get-ToonText -Table $row -Key 'state'
        if (-not $id -or -not $state) {
            return (& $fail 'The backlog listed an item with no id or no state, so no item can be trusted as closed.')
        }
        $items[$id] = @{ state = $state; closed = (Get-ToonText -Table $row -Key 'closed') }
    }
    [pscustomobject]@{ readable = $true; items = $items; problem = '' }
}

# Why a path may not be deleted by this module, or '' when nothing forbids it. This answers the rules
# alone - whether the item is closed and the original matches are decided by the caller - and it is
# asked again immediately before every removal.
function Get-DataTidyRefusal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$DataPath = (Get-DefaultIndexDataPath),
        [string]$KingshandHome = (Get-KingshandHome)
    )

    $data = Resolve-IndexDataPath -DataPath $DataPath
    $full = $null
    try { $full = ConvertTo-NormalPath $Path } catch { return "$Path cannot be read as a path." }

    if (Test-PathWithin -Path $full -Root (Join-Path $KingshandHome 'state')) {
        return 'it is under state\, which this command never touches.'
    }
    if (-not (Test-PathWithin -Path $full -Root $data -ExcludeRoot)) {
        return "it is outside $data."
    }

    $leaf = Split-Path $full -Leaf
    if ($script:ProtectedLeaves -contains $leaf) { return "$leaf is never deleted." }
    if ($leaf.StartsWith('brief', [StringComparison]::OrdinalIgnoreCase) -and
        $leaf.EndsWith('.md', [StringComparison]::OrdinalIgnoreCase)) {
        return 'a brief is never deleted - it is the only record of what a worker was told.'
    }

    $parts = @([System.IO.Path]::GetRelativePath($data, $full) -split '[\\/]')
    if ($parts.Count -ne 3 -or -not (Test-IndexStagedCopy -Path $full)) {
        return 'it is not a staged copy at data\<id>\read-first\<file>, the one class this command deletes.'
    }
    if ($script:OwnDirectories -contains $parts[0] -or $parts[0] -eq 'state') {
        return "data\$($parts[0])\ is kingshand's own, never a work item's."
    }
    if (Test-Path -LiteralPath $full -PathType Container) { return 'it is a directory.' }
    ''
}

# Where a staged copy's original lives. The header owns the naming rule and why a wrong answer can
# only keep a copy.
function Get-TidyOriginalPath {
    param(
        [Parameter(Mandatory)][string]$Leaf,
        [Parameter(Mandatory)][string]$DataPath,
        [Parameter(Mandatory)][string]$KingshandHome
    )

    if ($Leaf -ceq 'SKILL.md') { return (Join-Path $KingshandHome '.claude' 'skills' 'witness' 'SKILL.md') }
    if ($Leaf -ceq 'BrowserVerify.psm1') { return (Join-Path $KingshandHome 'bin' 'BrowserVerify.psm1') }
    if ($Leaf.StartsWith('family-', [StringComparison]::Ordinal) -and $Leaf.Length -gt 'family-.md'.Length -and
        $Leaf.EndsWith('.md', [StringComparison]::Ordinal)) {
        return (Join-Path $DataPath 'families' $Leaf.Substring('family-'.Length))
    }
    Join-Path $DataPath $Leaf
}

function Get-TidyHash {
    param([Parameter(Mandatory)][string]$Path)
    try { (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash } catch { $null }
}

# Why a staged copy must stay, or '' when it may go. Asked once to classify and again at removal.
function Get-TidyCopyVerdict {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Item,
        [Parameter(Mandatory)]$Backlog,
        [Parameter(Mandatory)][string]$DataPath,
        [Parameter(Mandatory)][string]$KingshandHome
    )

    $refusal = Get-DataTidyRefusal -Path $Path -DataPath $DataPath -KingshandHome $KingshandHome
    if ($refusal) { return [pscustomobject]@{ reason = $refusal; original = '' } }

    $original = Get-TidyOriginalPath -Leaf (Split-Path $Path -Leaf) -DataPath $DataPath -KingshandHome $KingshandHome
    $keep = { param($why) [pscustomobject]@{ reason = $why; original = $original } }

    if (-not $Backlog.readable) { return (& $keep 'the backlog could not be read, so its item cannot be shown closed.') }
    if (-not $Backlog.items.ContainsKey($Item)) {
        return (& $keep "the backlog does not list $Item - archived after it closed, or never a work item - so it cannot be shown closed.")
    }
    $state = $Backlog.items[$Item].state
    if ($state -cne 'done') { return (& $keep "its work item $Item is $state, not closed.") }

    if (-not (Test-Path -LiteralPath $original -PathType Leaf)) {
        return (& $keep 'its original is not on disk where it was copied from, so this copy may be the last one.')
    }
    $a = Get-TidyHash -Path $Path
    $b = Get-TidyHash -Path $original
    if (-not $a -or -not $b) { return (& $keep 'the copy or its original could not be read to compare them.') }
    if ($a -ne $b) { return (& $keep 'its original has changed since it was copied, so this copy is the only record of what the worker was given.') }

    [pscustomobject]@{ reason = ''; original = $original }
}

function Get-TidySize {
    param([Parameter(Mandatory)][string]$Path)
    if (Test-Path -LiteralPath $Path -PathType Leaf) { return (Get-Item -LiteralPath $Path -Force).Length }
    $sum = 0L
    foreach ($f in @(Get-ChildItem -LiteralPath $Path -File -Recurse -Force -ErrorAction SilentlyContinue)) {
        $sum += $f.Length
    }
    $sum
}

<#
.SYNOPSIS
  Report what under data\ looks dead, and with -Apply delete the one class proven safe.
.DESCRIPTION
  The module header owns what is deleted, what is only reported, and why. Without -Apply nothing is
  removed: the answer lists what would go.

  Returns:
    .applied        whether -Apply was passed
    .backlog        @{ readable; problem } - an unreadable backlog removes nothing
    .removable      staged copies that may go: path, item, original, bytes. With -Apply, what went.
    .removed        paths actually removed (with -Apply only)
    .failed         path, reason - removals attempted that did not happen
    .suspected      class, path, bytes, reason - reported and never removed. Classes:
                      staged-copy      a copy that must stay, and why
                      brief-revision   an extra brief beside brief.md
                      closed-item      an item directory whose work item is done
                      not-in-backlog   an item directory the backlog does not list
    .unindexed      data\ files no index lists, from Get-IndexDrift
    .indexProblem   why the index could not be read, or ''
.EXAMPLE
  Import-Module $env:KINGSHAND_HOME\bin\DataTidy.psm1
  $plan = Invoke-DataTidy             # dry run
  $done = Invoke-DataTidy -Apply      # removes exactly $plan.removable, rechecking each
#>
function Invoke-DataTidy {
    [CmdletBinding()]
    param(
        [switch]$Apply,
        [string]$DataPath = (Get-DefaultIndexDataPath),
        # The directory tasks-axi is run from; its .tasks.toml selects the backlog.
        [string]$QueueRoot = (Get-KingshandHome),
        [string]$KingshandHome = (Get-KingshandHome)
    )

    $data      = Resolve-IndexDataPath -DataPath $DataPath
    $backlog   = Get-TidyBacklog -QueueRoot $QueueRoot
    $removable = [System.Collections.Generic.List[object]]::new()
    $suspected = [System.Collections.Generic.List[object]]::new()
    $removed   = [System.Collections.Generic.List[string]]::new()
    $failed    = [System.Collections.Generic.List[object]]::new()

    $suspect = {
        param($class, $path, $reason)
        $suspected.Add([pscustomobject]@{
            class = $class; path = $path; bytes = (Get-TidySize -Path $path); reason = $reason
        })
    }

    # Every staged copy anywhere under data\, so one in a place no rule expects is reported too.
    $copies = @(Get-ChildItem -LiteralPath $data -File -Recurse -Force -ErrorAction SilentlyContinue |
                Where-Object { Test-IndexStagedCopy -Path $_.FullName } | Sort-Object FullName)
    foreach ($c in $copies) {
        $item = Split-Path (Split-Path (Split-Path -Parent $c.FullName) -Parent) -Leaf
        $v = Get-TidyCopyVerdict -Path $c.FullName -Item $item -Backlog $backlog -DataPath $data `
                                 -KingshandHome $KingshandHome
        if ($v.reason) { & $suspect 'staged-copy' $c.FullName $v.reason; continue }
        $removable.Add([pscustomobject]@{
            path = $c.FullName; item = $item; original = $v.original; bytes = $c.Length
        })
    }

    foreach ($dir in @(Get-ChildItem -LiteralPath $data -Directory -Force -ErrorAction SilentlyContinue |
                       Sort-Object Name)) {
        if ($script:OwnDirectories -contains $dir.Name) { continue }

        foreach ($b in @(Get-ChildItem -LiteralPath $dir.FullName -File -Filter 'brief*.md' -Force |
                         Sort-Object Name)) {
            if ($b.Name -in @('brief.md', 'brief.dispatch.md')) { continue }
            & $suspect 'brief-revision' $b.FullName 'an earlier or extra revision beside brief.md. Briefs are never deleted by this command.'
        }

        if (-not $backlog.readable) { continue }
        if (-not $backlog.items.ContainsKey($dir.Name)) {
            & $suspect 'not-in-backlog' $dir.FullName 'the backlog does not list it - archived after it closed, or never a work item.'
        } elseif ($backlog.items[$dir.Name].state -ceq 'done') {
            $closed = $backlog.items[$dir.Name].closed
            $when = if ($closed -and $closed -ne '-') { " on $closed" } else { '' }
            & $suspect 'closed-item' $dir.FullName "its work item closed$when. Its report.md and brief stay whatever is decided."
        }
    }

    if ($Apply) {
        foreach ($r in $removable) {
            # Checked again here, at the moment of removal, rather than trusted from above.
            $v = Get-TidyCopyVerdict -Path $r.path -Item $r.item -Backlog $backlog -DataPath $data `
                                     -KingshandHome $KingshandHome
            if ($v.reason) { $failed.Add([pscustomobject]@{ path = $r.path; reason = $v.reason }); continue }
            try {
                Remove-Item -LiteralPath $r.path -Force -ErrorAction Stop
                $removed.Add($r.path)
            } catch {
                $failed.Add([pscustomobject]@{ path = $r.path; reason = $_.Exception.Message })
            }
        }
    }

    $unindexed = @()
    $indexProblem = ''
    try { $unindexed = @((Get-IndexDrift -DataPath $data).unindexed) }
    catch { $indexProblem = "The index could not be read: $($_.Exception.Message)" }

    [pscustomobject]@{
        applied      = [bool]$Apply
        backlog      = [pscustomobject]@{ readable = $backlog.readable; problem = $backlog.problem }
        removable    = @($removable.ToArray())
        removed      = @($removed.ToArray())
        failed       = @($failed.ToArray())
        suspected    = @($suspected.ToArray())
        unindexed    = $unindexed
        indexProblem = $indexProblem
    }
}

# The answer as lines a person reads: what went or would go, then each suspected class with its
# count and size, then the unindexed files.
function Format-DataTidyReport {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Result)

    $kb  = { param($n) '{0:N0} KB' -f [math]::Ceiling($n / 1KB) }
    $sum = { param($rows) $t = 0L; foreach ($x in @($rows)) { $t += [long]$x.bytes }; $t }
    $lines = [System.Collections.Generic.List[object]]::new()

    if (-not $Result.backlog.readable) {
        $lines.Add("NOTHING DELETED: $($Result.backlog.problem)")
    }
    if ($Result.applied) {
        $gone = @($Result.removable | Where-Object { @($Result.removed) -contains $_.path })
        $lines.Add("Removed $($gone.Count) staged copies of closed work, $(& $kb (& $sum $gone)) in all.")
        foreach ($r in $gone) { $lines.Add("  $($r.path) (same as $($r.original))") }
        foreach ($f in $Result.failed) { $lines.Add("  kept $($f.path) - $($f.reason)") }
    } else {
        $lines.Add("Dry run - nothing removed. $(@($Result.removable).Count) staged copies of closed work would go, $(& $kb (& $sum $Result.removable)) in all. Pass -Apply to remove them.")
        foreach ($r in $Result.removable) { $lines.Add("  $($r.path) (same as $($r.original))") }
    }

    foreach ($g in @($Result.suspected | Group-Object class | Sort-Object Name)) {
        $lines.Add('')
        $lines.Add("Suspected, not deleted - $($g.Name): $($g.Count), $(& $kb (& $sum $g.Group))")
        foreach ($s in $g.Group) { $lines.Add("  $($s.path) - $($s.reason)") }
    }

    $lines.Add('')
    if ($Result.indexProblem) {
        $lines.Add($Result.indexProblem)
    } else {
        $lines.Add("Unindexed - listed in no index: $(@($Result.unindexed).Count)")
        foreach ($u in $Result.unindexed) { $lines.Add("  $u") }
    }
    return , $lines
}

Export-ModuleMember -Function Invoke-DataTidy, Format-DataTidyReport, Get-DataTidyRefusal
