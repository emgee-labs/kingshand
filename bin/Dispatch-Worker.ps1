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

  The paths arrive STRUCTURALLY, in -ReadPath, and nothing here reads them back out of the brief's
  prose. An earlier version did: it parsed the `Read first` section for file paths and compared
  that set against -ReadPath in both directions. The intent was right and the mechanism has no last
  bug. It cost six consecutive review rounds - refuse paths outside the grant, read every path
  form, read whole paths, tighten the parsing, refuse spaced names, refuse spaced mentions - each
  one closing a real hole and exposing the next, because a path written in prose can be absolute or
  relative, forward or back slashed, quoted or bare, contain spaces, sit inside a sentence, or wrap
  across a line. Two of those rounds had already refused correct briefs over paths nobody wrote.

  The Hand writes the brief AND calls this script, so it is holding the list at the moment it
  dispatches. Passing that list is the whole fix, and there is nothing left to infer. The prose
  section stays as what the WORKER reads and acts on; nothing reads it mechanically except the
  presence check below. Do not reintroduce a parser here.

  What survives is the one check that never needed a path: the section must EXIST. A brief with no
  `## Read first` heading names no settled file at all - the original failure verbatim rather than
  a variant of it, since a brief with nothing to read says so in one line while a brief missing the
  slot says nothing, and only the first is a decision somebody made. It is a regex against a
  heading, and refusing here costs one line in a brief that has not been dispatched yet.

  Fenced code is quoted text, so it is skipped while looking for that heading. A brief for a task
  on muster's own template quotes that template, fence and all, and the quoted `## Read first`
  heading satisfied the check for a brief that had no section of its own.

  The section being PRESENT is not the same as the index having been read, and the second refusal
  closes that gap. When the target project has an index, the dispatch is refused unless one of two
  deliberate acts is on record: at least one -ReadPath was passed, or the section states in one line
  that the index was checked and nothing in it applies. An index of pointers nobody is obliged to
  follow is the settled-spec failure at a larger scale and worse, because it looks solved. Neither
  way past is an absence: an empty section, or a heading with nothing under it, still refuses.

  The project is resolved from the REGISTRY by repo path, never from a parameter. A parameter can be
  left off, and a gate that is skipped by forgetting one is the forgetting it exists to stop. An
  unregistered repo resolves to no project, has no index, and dispatches exactly as before - posture
  is read there, never inferred, and hard rule 2 already forbids dispatching into one.

  That check parses nothing about paths either. It counts -ReadPath entries, which arrived
  structurally, asks Index.psm1 whether the project's index lists anything, and looks at the
  section's own lines for one stated sentence. Nothing in it turns prose into a file name.

  Everything else refused here is about -ReadPath itself, where the path is known exactly and
  nothing is being read out of anything: a path that is not on disk, a directory where a file was
  meant, and two entries whose file names would collide in the staging directory.
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
    [int]$TimeoutSeconds = 90,
    # The data root the index gate reads: this installation's data\ unless a caller points it
    # elsewhere. Index.psm1 and Projects.psm1 both take the same seam for the same reason - a check
    # that can only ever be exercised against the real installation is a check no test can drive.
    # Resolved in the body rather than here: a parameter default is evaluated before the script's
    # own Import-Module lines run, so Get-DefaultIndexDataPath is not loaded yet at this point.
    [string]$DataPath = ''
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
# Index BEFORE Projects, and both before anything reads them. Projects.psm1 imports Index.psm1 as a
# nested module without -Force, so forcing Index afterwards would remove the copy Projects is
# already holding - the failure Test-CrewPrereqs hit, recorded in `statute`'s style rules.
Import-Module (Join-Path $PSScriptRoot 'Index.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Projects.psm1') -Force

# Checked here rather than at the first herdr call: without it nothing below can work, and finding
# that out after a worktree and a branch exist leaves debris to clean up.
if (-not (Get-HerdrCommandPath)) { throw (Get-HerdrCommandHint) }

$RepoPath  = (Resolve-Path $RepoPath).Path
$BriefPath = (Resolve-Path $BriefPath).Path
$briefDir  = Split-Path $BriefPath -Parent
if (-not $DataPath.Trim()) { $DataPath = Get-DefaultIndexDataPath }

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

    $leaf = Split-Path $resolved -Leaf

    # Two sources with one file name would land on top of each other, and the worker would read
    # whichever was copied last with no sign the other ever existed.
    if ($staged.ContainsKey($leaf) -and $staged[$leaf] -ne $resolved) {
        throw ("Read first names two different files called $leaf - $($staged[$leaf]) and " +
               "$resolved. One would overwrite the other. Pass only the one this task needs, or " +
               "copy one under a distinct name first and pass that copy. Do not rename either " +
               "original: two reports really are both called report.md, and that name is the " +
               "convention every index entry pointing at them already uses. Nothing was created.")
    }
    $staged[$leaf] = $resolved
}

# The heading, and NOTHING about the paths underneath it. The section's lines are what the worker
# reads and acts on; the files it must be handed arrive in -ReadPath, from the same Hand that wrote
# the section. An earlier version read the paths back out of these lines and compared the two sets,
# and that parser is what the header records: six review rounds, no last bug, and two correct
# briefs refused over paths nobody had written. Nothing here may start parsing this text again.
#
# Fenced blocks are QUOTED TEXT rather than this brief's own structure. A brief for a task on
# muster's own template quotes that template, fence and all, and the quoted `## Read first` heading
# satisfied this check for a brief that had no section of its own.
#
# The section's own lines are collected as well, for the one stated sentence the index gate below
# accepts. That is the whole of what is read out of them: no path, no file name, no comparison
# against -ReadPath. The section ends at the next heading, and a fenced block inside it is quoted
# text there too - a template a brief quotes cannot make a statement on that brief's behalf.
$hasSection   = $false
$inSection    = $false
$inFence      = $false
$sectionLines = [System.Collections.Generic.List[string]]::new()
foreach ($line in @(Get-Content -LiteralPath $BriefPath)) {
    if ($line -match '^\s*```') {
        $inFence = -not $inFence
        continue
    }
    if ($inFence) { continue }
    if ($line -match '^\s*##\s+Read first\s*$') {
        $hasSection = $true
        $inSection  = $true
        continue
    }
    if ($inSection) {
        if ($line -match '^\s*#{1,6}\s') { $inSection = $false; continue }
        $sectionLines.Add($line)
    }
}

# The section has to be PRESENT. This is the check that closes the originating failure: a brief
# that names no settled file at all, a worker that never learns one exists, and a site shipped
# without the brand that was already decided. A brief with nothing to read says so in a line; a
# brief missing the slot says nothing, and the two are not the same fact.
if (-not $hasSection) {
    throw ("The brief at $BriefPath has no '## Read first' section. Every brief carries one, " +
           "because a worker reads exactly one thing and a settled file it is never handed reaches " +
           "it not at all. Add the section naming each file to read - or the single line " +
           "'- Nothing beyond this brief.' when the index turns up nothing this task touches, so " +
           "that it reads as a decision rather than an omission. Nothing was created.")
}

# The index gate. The section exists; this asks whether the index behind it was actually consulted.
#
# The index was built, written to as files are written, and nothing obliged anyone to open it - and
# a pointer nobody is obliged to follow is exactly the failure that already happened once, when a
# settled brand spec named itself the input to the website brief and the site shipped without it. So
# forgetting the index is refused here, at the moment it happens, rather than discovered later.
#
# The project is resolved from the registry by repo path. Nothing is inferred from the path itself
# and no -Project parameter is taken: a parameter can be omitted, and a gate that a forgotten
# argument switches off is not a gate. An unregistered repo therefore has no project and no index,
# and dispatches exactly as it did before.
$project = ''
try {
    $target = [IO.Path]::GetFullPath($RepoPath).TrimEnd('\')
    # Get-AllProjects returns the whole array as ONE pipeline object - Projects.psm1's leading-comma
    # idiom - so this is a plain loop over the assigned value rather than an @() wrap, which would
    # nest it a second time and iterate once over the array itself.
    $registered = Get-AllProjects -RegistryPath (Join-Path $DataPath 'projects.md') -WarningAction SilentlyContinue
    foreach ($entry in $registered) {
        if (-not $entry.path -or -not $entry.indexable) { continue }
        if ([IO.Path]::GetFullPath($entry.path).TrimEnd('\').Equals($target, [System.StringComparison]::OrdinalIgnoreCase)) {
            $project = $entry.name
            break
        }
    }
} catch {
    # No registry, or one nothing can parse. That is a state, not a failure of this dispatch: the
    # gate has nothing to check and every other refusal above still stands. Throwing here would
    # block every dispatch on a fresh installation that has registered nothing yet.
    $project = ''
}

if ($project) {
    # "Has an index" is Index.psm1's answer, never a Test-Path of ours: an index file that lists
    # nothing has nothing to consult, and demanding a statement about an empty table of contents
    # would refuse a dispatch nobody could act on.
    $indexed = @(Get-IndexEntries -Project $project -DataPath $DataPath)
    if ($indexed.Count -gt 0) {
        # The stated line, and nothing else about these lines. It has to name the index and say
        # nothing in it applies, because that is a decision somebody made - where an empty section,
        # or `- Nothing beyond this brief.` on its own, says only that the slot was filled in.
        $statesIndexChecked = $false
        foreach ($line in $sectionLines) {
            if ($line -match '\bindex\b' -and $line -match '\b(nothing|none|no entr(y|ies))\b') {
                $statesIndexChecked = $true
                break
            }
        }

        if ($staged.Count -eq 0 -and -not $statesIndexChecked) {
            $indexPath = Get-IndexPath -Project $project -DataPath $DataPath
            throw ("Project $project has an index at $indexPath listing $($indexed.Count) file(s), " +
                   "and this brief neither names a file from it to read nor says it was checked. A " +
                   "worker reads exactly one thing, so a settled file no brief names reaches it not " +
                   "at all - which is how a site shipped without the brand that was already decided. " +
                   "Open that index, then either pass -ReadPath for each file this task touches and " +
                   "name the copies under 'Read first', or put one line there saying the index was " +
                   "checked and nothing in it applies - '- Nothing beyond this brief - the index was " +
                   "checked and nothing in it applies.' Nothing was created.")
        }
    }
}

# Copied only once every check above has passed, so a refusal is always true when it says nothing
# was created. Staging first left a directory and a file on disk under a message denying both.
if ($staged.Count -gt 0) {
    if (-not (Test-Path -LiteralPath $readFirstDir)) {
        New-Item -ItemType Directory -Force -Path $readFirstDir | Out-Null
    }
    foreach ($leaf in $staged.Keys) {
        Copy-Item -LiteralPath $staged[$leaf] -Destination (Join-Path $readFirstDir $leaf) -Force
    }
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
