#Requires -Version 7.0
<#
.SYNOPSIS
  Creates one worker's git worktree, prepares it, and starts a Claude Code agent in it under herdr.
.DESCRIPTION
  The worker id is now CHOSEN, not discovered. `claude --bg --worktree` ignored --session-id and
  minted its own id, so dispatch had to diff `claude agents --json` before and after the spawn and
  hope exactly one background session appeared in the gap. herdr takes the name it is given, so the
  id is simply $Name and the whole before/after diff is gone. crew.json keeps that id verbatim;
  herdr only ever sees `ConvertTo-HerdrAgentName $Name`, which Herdr.psm1 owns.

  kingshand creates the worktree itself now - `claude --bg --worktree` used to. It goes at
  <repo>\.claude\worktrees\<name>, which is exactly where Claude Code put it, because .gitignore
  already covers .claude/worktrees/ and every other script, skill and recorded crew.json row
  already names that location.

  ORDER IS LOAD-BEARING, and each step exists because of a concrete failure:

    1. Resolve-BaseRef, BEFORE anything is spawned. It refuses rather than inventing a ref, and a
       refusal after a worker exists would leave one running with nothing recorded about it.
    2. git worktree add - the isolated checkout the worker will never leave.
    3. Set-WorkerWorkspaceSettings - the two grants that used to be command-line flags. herdr
       cannot pass arguments to claude on Windows at all (it launches through Start-Process against
       a .ps1 and dies with "%1 is not a valid Win32 application"), so --permission-mode and
       --add-dir have to be on disk in the worktree before the agent starts.
    4. Grant-ClaudeFolderTrust - a fresh worktree is a directory Claude Code has never seen, so it
       stops on the folder-trust dialog with nobody there to answer. `claude --bg --worktree` never
       met this: it inherited the trust of the session that spawned it.
    5. Start-HerdrServer, New-HerdrPane, Start-HerdrAgent - the spawn.
    6. Send-HerdrPrompt with NO -Wait. Arming the wait is the caller's job: a dispatch that blocked
       here would hold the Hand for the length of the worker's first turn.

  The brief is passed BY PATH, never by value. That began as a defence against Start-Process
  flattening -ArgumentList (a 1,733-character brief arrived as its 57-character first line), and it
  outlives the defect: a brief on disk is what the worker can re-read mid-task and what survives a
  restart, and the settings written in step 3 grant read access to the brief's directory, which
  lives outside the repo.

  -ReadPath carries the files the brief's `Read first` section names, and it does it by COPYING
  each one into <briefdir>\read-first\ rather than by granting where it lives. Those files sit
  beside the brief's directory rather than inside it - a settled spec at data\<name>.md is a
  sibling of data\<id>\ - and a brief naming a file the worker cannot open delivers nothing, which
  is the original failure with one extra hop.

  Granting the containing directory was the obvious answer and it is wrong. The canonical settled
  file is data\<name>.md, whose containing directory IS the kingshand data root, so that grant
  hands the worker every other worker's brief and report, king.md, learnings.md, backlog.md and
  projects.md - and hands them writable, because these settings also set bypassPermissions. Copying
  keeps additionalDirectories at exactly one entry, the brief's own directory, on every dispatch
  and whatever the brief names.

  The copy is a snapshot taken at dispatch, which is the same thing the brief itself is. A worker
  re-reading it mid-task sees what it was given, not what has changed underneath it since. It is
  derived from a file the index already lists at its own path, so Get-IndexableFiles excludes
  read-first\ and the drift count does not grow by one per dispatch forever.

  The brief's own `Read first` section is what decides whether -ReadPath was right: every
  read-first\<file> it names must have been staged by this call, and dispatch refuses when one was
  not. The two are written in different steps, and prose was the only thing tying them together.
.EXAMPLE
  $r = .\Dispatch-Worker.ps1 -RepoPath C:\repos\foo -Name T-1001 -BriefPath $env:KINGSHAND_HOME\data\T-1001\brief.md
  $r.id, $r.worktree, $r.branch
.EXAMPLE
  # The brief's Read first section names $env:KINGSHAND_HOME\data\T-1001\read-first\emgee-brand.md,
  # which is where this call puts it.
  $r = .\Dispatch-Worker.ps1 -RepoPath C:\repos\foo -Name T-1001 `
         -BriefPath $env:KINGSHAND_HOME\data\T-1001\brief.md `
         -ReadPath $env:KINGSHAND_HOME\data\emgee-brand.md
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepoPath,
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$BriefPath,
    [string[]]$ReadPath = @(),
    [int]$TimeoutSeconds = 90
)

$ErrorActionPreference = 'Stop'

# Every git call below is checked on $LASTEXITCODE and reported with git's own output. Left mapped
# onto $ErrorActionPreference, the first probe for a branch that does not exist would terminate the
# whole dispatch with "Program git.exe ended with non-zero exit code: 1" and say nothing useful.
$PSNativeCommandUseErrorActionPreference = $false

if (-not (Test-Path $RepoPath))  { throw "Repo path not found: $RepoPath" }
if (-not (Test-Path $BriefPath)) { throw "Brief not found: $BriefPath" }

Import-Module (Join-Path $PSScriptRoot 'Herdr.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ClaudeWorkspace.psm1') -Force

# Checked here rather than at the first herdr call: without it nothing below can work, and finding
# that out after a worktree and a branch exist leaves debris to clean up.
if (-not (Get-HerdrCommandPath)) { throw (Get-HerdrCommandHint) }

$RepoPath  = (Resolve-Path $RepoPath).Path
$BriefPath = (Resolve-Path $BriefPath).Path
$briefDir  = Split-Path $BriefPath -Parent

# Staged BEFORE the worktree exists, for the same reason the base ref is resolved first: a brief
# naming a file that is not there is a brief the worker cannot carry out, and finding that out
# after a worker is running means one more dispatch spent discovering it. Every refusal below
# names the offending path and leaves nothing created.
$readFirstDir = Join-Path $briefDir 'read-first'
$staged       = [System.Collections.Generic.Dictionary[string, string]]::new(
                    [System.StringComparer]::OrdinalIgnoreCase)

foreach ($p in @($ReadPath | Where-Object { $_ -and $_.Trim() })) {
    if (-not (Test-Path -LiteralPath $p)) {
        throw ("The brief names $p under Read first and it does not exist, so the worker would be " +
               "told to read a file that is not there. Nothing was created.")
    }
    $resolved = (Resolve-Path -LiteralPath $p).Path
    if (Test-Path -LiteralPath $resolved -PathType Container) {
        throw ("Read first names the directory $resolved. Name the files the worker must read, " +
               "one path each - a directory would copy whatever happens to be in it. Nothing was created.")
    }

    # Two sources with one file name would land on top of each other, and the worker would read
    # whichever was copied last with no sign the other ever existed.
    $leaf = Split-Path $resolved -Leaf
    if ($staged.ContainsKey($leaf) -and $staged[$leaf] -ne $resolved) {
        throw ("Read first names two different files called $leaf - $($staged[$leaf]) and " +
               "$resolved. One would overwrite the other. Rename one, or name only the one the " +
               "worker needs. Nothing was created.")
    }
    $staged[$leaf] = $resolved
}

if ($staged.Count -gt 0) {
    if (-not (Test-Path -LiteralPath $readFirstDir)) {
        New-Item -ItemType Directory -Force -Path $readFirstDir | Out-Null
    }
    foreach ($leaf in $staged.Keys) {
        Copy-Item -LiteralPath $staged[$leaf] -Destination (Join-Path $readFirstDir $leaf) -Force
    }
}

# The brief and -ReadPath are written in two different steps and nothing but prose tied them
# together, so a brief could name read-first\<file> with -ReadPath left off and dispatch would
# succeed having staged nothing - the worker then opens a path that does not exist. It is the
# brief's own text that decides, so it is the brief's own text that is checked. Only the leaf is
# compared, which holds however the root was written.
$briefLines = @(Get-Content -LiteralPath $BriefPath)
$inSection  = $false
$named      = [System.Collections.Generic.List[string]]::new()
foreach ($line in $briefLines) {
    if ($line -match '^\s*##\s+') { $inSection = $line -match '^\s*##\s+Read first\s*$' ; continue }
    if (-not $inSection) { continue }
    foreach ($m in [regex]::Matches($line, 'read-first[\\/](?<leaf>[^\s`''"<>|,;)\]]+)')) {
        $named.Add($m.Groups['leaf'].Value)
    }
}

$unstaged = @(@($named) | Where-Object { -not $staged.ContainsKey($_) } | Select-Object -Unique)
if ($unstaged.Count -gt 0) {
    throw ("The brief's Read first section names " + ($unstaged -join ', ') + " under read-first\, " +
           "and nothing staged " + $(if ($unstaged.Count -eq 1) { 'it' } else { 'them' }) + ". Pass " +
           "the original of each to -ReadPath, or take the line out of the brief. Nothing was created.")
}

# The worktree branches from the REMOTE default branch when the repo has one, not the local
# branch. Local main is often behind origin/main, and diffing the worker's branch against local
# main then attributes the upstream commits in that gap to the worker - including other people's
# Co-Authored-By trailers, which trips the attribution check on a colleague's commit. Record the
# real base at dispatch.
#
# Resolved BEFORE the spawn on purpose: Resolve-BaseRef refuses rather than inventing a ref, and
# a refusal after the worker exists would leave an orphaned agent running in the repo.
. (Join-Path $PSScriptRoot 'Resolve-BaseRef.ps1')
$base = Resolve-BaseRef -RepoPath $RepoPath

$branch   = "worktree-$Name"
$worktree = Join-Path (Join-Path (Join-Path $RepoPath '.claude') 'worktrees') $Name

function Get-GitOutput {
    param([Parameter(Mandatory)][string[]]$Arguments)
    (& git -C $RepoPath @Arguments 2>&1 | Out-String).Trim()
}

function Test-LocalBranch {
    param([Parameter(Mandatory)][string]$Ref)
    $null = & git -C $RepoPath rev-parse --verify --quiet "refs/heads/$Ref" 2>$null
    $LASTEXITCODE -eq 0
}

# git prints worktree paths with forward slashes and its own casing, so a string compare against a
# Windows path built with Join-Path never matches. Compare fully-qualified paths instead.
function Test-WorktreeRegistered {
    param([Parameter(Mandatory)][string]$Path)
    $target = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    foreach ($line in @((Get-GitOutput @('worktree', 'list', '--porcelain')) -split "`r?`n")) {
        if ($line -notmatch '^worktree\s+(.+)$') { continue }
        $listed = [IO.Path]::GetFullPath(($Matches[1].Trim() -replace '/', '\')).TrimEnd('\')
        if ($listed -eq $target) { return $true }
    }
    $false
}

# A worktree whose directory was deleted by hand is still recorded under .git\worktrees, and
# `git worktree add` at that path then refuses with "already exists" about a directory nobody can
# see. Pruning first turns that into an ordinary fresh add.
$null = Get-GitOutput @('worktree', 'prune')

# Re-dispatching the same ticket is ordinary - a worker that stopped at the trust dialog, or one
# the King sent back to keep going - and `git worktree add -b` cannot be told twice. So the three
# states are decided here rather than left to a raw git error the Hand would have to interpret.
if (Test-WorktreeRegistered $worktree) {
    # Already a checkout of this ticket's branch. Reuse it: whatever the previous attempt committed
    # is the work in progress, and discarding it to get a clean `add` would throw that away.
    if (-not (Test-LocalBranch $branch)) {
        throw ("A worktree is already registered at $worktree but branch $branch does not exist, " +
               "so this is not a kingshand worker's checkout. Resolve it by hand - dispatch will " +
               "not repoint someone else's worktree.")
    }
} elseif (Test-Path -LiteralPath $worktree) {
    throw ("$worktree already exists and git does not own it, so a worktree cannot be created " +
           "there. Remove it, or dispatch this ticket under a different name.")
} elseif (Test-LocalBranch $branch) {
    # The branch survived its worktree - the usual shape after a teardown that removed the
    # directory but kept the work. Check it out again rather than branching a second time from a
    # base that has since moved.
    $out = Get-GitOutput @('worktree', 'add', $worktree, $branch)
    if ($LASTEXITCODE -ne 0) { throw "git worktree add $worktree $branch failed: $out" }
} else {
    $out = Get-GitOutput @('worktree', 'add', '-b', $branch, $worktree, $base)
    if ($LASTEXITCODE -ne 0) { throw "git worktree add -b $branch $worktree $base failed: $out" }
}

# The two grants that used to be `--permission-mode bypassPermissions --add-dir <briefdir>` on the
# command line. Written into the WORKTREE, which is a fresh checkout with no .claude of its own -
# nothing carries across from the main checkout, because settings.local.json is untracked.
$null = Set-WorkerWorkspaceSettings -WorktreePath $worktree -AdditionalDirectories @($briefDir)

# Pre-seeded rather than answered afterwards with a synthetic keystroke: this is a written,
# inspectable record made before launch, and it cannot race the dialog. Its result is kept because
# a worker that comes back blocked is almost always a trust grant that did not land, and saying so
# is the difference between an actionable failure and "the agent is blocked".
$trust = Grant-ClaudeFolderTrust -Path $worktree

Start-HerdrServer
$paneId = New-HerdrPane -Cwd $worktree

$agent = Start-HerdrAgent -Name $Name -PaneId $paneId -TimeoutMs ($TimeoutSeconds * 1000)
if (-not $agent) {
    throw ("herdr started no agent for $Name in pane $paneId. The worktree at $worktree and " +
           "branch $branch were created and are untouched.")
}

# `agent start` can exit non-zero and still have registered the agent, so Start-HerdrAgent hands
# back the live record instead of throwing. A blocked agent is sitting on an interactive prompt: it
# is NOT given keys here, because a blind arrow-and-enter at a security prompt answers whichever
# option happens to be highlighted, and herdr delivers a batched arrow+enter out of order anyway.
#
# Read through Get-HerdrAgentState, never `agent_status` directly. herdr misreports a Claude Code
# worker sitting on a prompt - a folder-trust dialog here would come back `idle` or `done` - so the
# raw field would wave the worker through and the brief would land in a dialog instead of a session.
$state = Get-HerdrAgentState -Name $Name
if ($state -eq 'blocked') {
    $why = if ($trust.granted) { "folder trust was recorded ($($trust.reason))" }
           else { "folder trust was NOT recorded ($($trust.reason))" }
    throw ("Worker $Name started but is blocked on an interactive prompt in pane $paneId - " +
           "$why. Read it with Read-HerdrAgent and answer it deliberately; nothing here sends " +
           "keys at a prompt it has not read. The worktree at $worktree and branch $branch exist " +
           "and hold no work yet.")
}

# One line, so the brief cannot be lost in transit and the worker has to open the file. The worker
# reads the rest from disk, which is also what lets it re-read its own brief mid-task.
$prompt = "Read the file $BriefPath in full - it is your brief and the complete statement of " +
          "your task - then carry it out exactly as written. Treat every requirement, exclusion " +
          "and Done-means item in it as binding. If you cannot read that file, stop immediately " +
          "and report that instead of guessing at the task."

# No -Wait: the caller arms the wait, as a background job running Wait-HerdrAgent, and its
# completion is what wakes the Hand. Waiting here would hold the Hand for the whole first turn.
#
# The status this returns is STALE by design - herdr's `agent prompt` returns before the state
# machine has moved, so the agent still reads `idle` for a moment after submitting. It is not read
# as progress here, only for the one thing it can say straight away: that the prompt bounced.
$submitted = Send-HerdrPrompt -Name $Name -Text $prompt
if ($submitted -and $submitted.PSObject.Properties.Name -contains 'blocked') {
    throw ("Worker $Name would not take its brief - it is blocked on an interactive prompt in " +
           "pane $paneId. The worktree at $worktree and branch $branch exist; read the pane with " +
           "Read-HerdrAgent before answering anything.")
}

# Whether the guard can actually read this worker, checked once and reported rather than assumed.
#
# Everything that decides a worker is stuck reads its SCREEN, because herdr's own state is known to
# be wrong in both directions for a worker sitting on a prompt. A terminal too narrow to render
# "Enter to select" makes that read impossible - and the failure is silent, because a screen with no
# match looks exactly like a screen with no prompt. Two real workers were measured at 6 and 3
# columns, rendering one character per line, with both the guard and herdr's own detection blind.
#
# Not a refusal: the worker is running and will do its work, and killing it over terminal geometry
# would be worse. But the caller must be told, because "no prompt found" and "cannot look" are
# different answers and only one of them means the worker is fine.
$readable = Test-HerdrAgentReadable -Name $Name
if (-not $readable) {
    Write-Warning ("Worker $Name is in a terminal too narrow to read. Nothing can tell a stuck " +
                   "worker from a busy one in it - not this guard and not herdr's own detection, " +
                   "because both match patterns against the rendered screen. Treat its silence as " +
                   "unknown rather than healthy and read data\$Name\report.md instead of its screen." +
                   " A fresh workspace is 93 columns, so this means the herdr server's layout is " +
                   "already wrecked - almost always by an older kingshand that split panes. " +
                   "Recover it by letting every worker finish, then: herdr server stop. The next " +
                   "dispatch starts a clean one.")
}

[hashtable]@{
    id       = $Name
    worktree = $worktree
    branch   = $branch
    base     = $base
    readable = $readable
}
