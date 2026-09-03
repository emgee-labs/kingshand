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

  TWO FILES ARE STAGED WITHOUT ANYONE PASSING THEM, keyed off the project this dispatch already
  resolves from the registry: data\done-<project>.md, the standing criteria, and
  data\rules-<project>.md, the standing rules - conventions, vocabulary, exclusions, branch naming,
  where a login is kept. Each is staged when it exists, and its absence is an ordinary state.

  Automatic because delivery by memory has already failed: a settled brand spec sat in data\ naming
  itself the input to the website brief while the site shipped without its logo, favicon, tagline or
  palette, because no brief named the file. A per-project file the Hand has to remember to pass is
  that failure with a shorter fuse - it applies to EVERY task in the project, so forgetting it once
  is forgetting it for whichever task happened to be dispatched that day.

  Staging alone would not be enough: a file copied beside the brief that nothing tells the worker to
  read reaches it not at all, which is the original failure with an extra step. So this script also
  writes one `Read first` line per file it staged itself, into the brief, immediately under that
  heading. It writes a line only for a file IT staged - a file the Hand passed to -ReadPath is one
  the Hand already named - and it recognises its own line verbatim, so a re-dispatch adds nothing.
  That is an insertion at a heading this script already locates, and it is not a path parser: no
  file name is ever read back out of the brief's prose.

  NEITHER counts towards the index gate below, for the reason the gate's own comment gives: a path
  that arrives on every dispatch is no evidence that the index was consulted for THIS task.

  A per-project file that exists and cannot be opened is refused by name. Reading it as absent would
  be the worst outcome available - the worker would ship without standing rules nobody could see had
  gone missing, which is the failure this whole mechanism exists to close.

  Nothing here reads what is INSIDE either file. It is reference material handed to a worker whole,
  so the only question this script asks is whether the file is there.

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
  section stays as what the WORKER reads and acts on, and exactly two things below read it
  mechanically: that its heading is there, and that one line states the index was checked. Neither
  turns prose into a file name. Do not reintroduce a parser here.

  What survives is the one check that never needed a path: the section must EXIST. A brief with no
  `## Read first` heading names no settled file at all - the original failure verbatim rather than
  a variant of it, since a brief with nothing to read says so in one line while a brief missing the
  slot says nothing, and only the first is a decision somebody made. It is a regex against a
  heading, and refusing here costs one line in a brief that has not been dispatched yet.

  Fenced code is quoted text, so it is skipped while looking for that heading. A brief for a task
  on muster's own template quotes that template, fence and all, and the quoted `## Read first`
  heading satisfied the check for a brief that had no section of its own.

  The section being PRESENT is not the same as the index having been read, and the second refusal
  closes that gap. When anything at all is indexed for this dispatch, it is refused unless one of two
  deliberate acts is on record: at least one -ReadPath was passed, or the section states in one line
  that the index was checked and nothing in it applies. An index of pointers nobody is obliged to
  follow is the settled-spec failure at a larger scale and worse, because it looks solved. Neither
  way past is an absence: an empty section, or a heading with nothing under it, still refuses.

  FOUR PATHS do not count towards it, and all for one reason: each arrives by rote rather than
  because this task touches it. THE PROJECT'S OWN TWO FILES are data\done-<project>.md and
  data\rules-<project>.md for the project this dispatch resolved to. Both arrive on every brief for
  a project that has them - the criteria file because muster hands it over, and either because this
  script stages it whether or not anyone did. The other two are .claude\skills\witness\SKILL.md and
  bin\BrowserVerify.psm1, the browser procedure and the module it imports, which muster hands over on
  every brief carrying a `## Browser checks` section - a worker reaches its own worktree and the
  brief's directory and nowhere else, and it cannot load a skill from this repository at all, so both
  travel as copies. Those two discounts apply ONLY to a brief carrying that section, which is the one
  place the files are passed by rote: a kingshand task to change the procedure itself passes it
  because it is the subject, carries no browser checks, and engages the gate like any other chosen
  file. Counting a path that arrives by rote would make this refusal unreachable from the moment the
  first criteria file is written, and the premise of the whole check is that a -ReadPath is evidence
  the Hand went through the index for THIS task. Every other path counts, including another file
  sitting beside them in data\. When the discounted paths are the only ones the brief passed, the
  refusal says which it discounted and why - a message denying what the reader can see it just
  did is one nobody can act on - and it recommends muster's longer stated line rather than the short
  one, because the short one would tell the worker there is nothing beyond the brief in the same
  breath as the section hands it those copies.

  EVERY index that could cover the dispatch counts, and the root one counts first. data\index.md is
  where the settled files this gate exists to protect actually land - chronicle, annex and survey all
  write data\<topic>.md with no project - while data\index\<project>.md holds little beyond briefs
  and reports. A gate that consulted the project index alone therefore never fired at all on a real
  installation: the inert version of the very failure it was written for. The root index is not
  project-scoped, so it gates a repo the registry has never heard of exactly as it gates a registered
  one, and only the project index needs the project resolved at all.

  The project is resolved from the REGISTRY by repo path, never from a parameter. A parameter can be
  left off, and a gate that is skipped by forgetting one is the forgetting it exists to stop. An
  unregistered repo resolves to no project and so has no project index - posture is read there, never
  inferred, and hard rule 2 already forbids dispatching into one. A registry that is there and
  cannot be read, or one entry whose path is unusable, WARNS and carries on rather than switching the
  gate off in silence: one hand-edited `path:` line used to disable it for every project at once,
  with no signal at all. A registry that does not exist yet says nothing, because a fresh
  installation has registered nothing and a warning on every dispatch teaches the reader to skip the
  next one. A data root where nothing is indexed anywhere is the only case that leaves a dispatch
  untouched, and it is the only case where "no index to check" is actually true.

  That check parses nothing about paths either. It counts -ReadPath entries, which arrived
  structurally, asks Index.psm1 what each index lists, and looks at the section's own lines for one
  stated sentence. Nothing in it turns prose into a file name.

  A brief carrying a `## Browser checks` section is refused unless it passes BOTH the browser
  procedure and the module, because that section points the worker at copies under read-first and
  those copies exist only where -ReadPath put them. Forget either and the worker follows its brief
  to a file that is not there, then drives a browser with none of the rules the section carries.
  Prose said so first and prose is not a mechanism; this is the same principle as the rest of the
  gate, that a check a forgotten argument switches off is not a check.

  Everything else refused here is about a path that is known exactly, with nothing being read out of
  anything: a -ReadPath that is not on disk, a directory where a file was meant, two entries whose
  file names would collide in the staging directory, a project file that is there and cannot be
  opened, and a brief that cannot be written to once there is something to auto-attach to it.
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

# The data root, rooted ONCE by Index.psm1's own rule, so this script and the indexes it reads below
# agree about where data\ is. [IO.Path]::GetFullPath would not be that rule: it resolves against the
# process working directory, which Set-Location does not move, so a relative -DataPath could put the
# project's own files somewhere the index never looked.
#
# Unguarded on purpose, and it decides where the per-project files are looked for as well as what
# the index gate discounts. A root this cannot resolve has to stop the dispatch rather than fall
# through to an empty answer that quietly attaches nothing and discounts nothing. Nothing is created
# at this point, so throwing here costs the caller only the message.
$dataRoot = Resolve-IndexDataPath -DataPath $DataPath

# The project is resolved from the registry by repo path. Nothing is inferred from the path itself
# and no -Project parameter is taken: a parameter can be omitted, and a gate or an attachment that a
# forgotten argument switches off is not one. An unregistered repo therefore resolves to no project,
# has no project index and gets no per-project files - but the root index is not project-scoped and
# gates it all the same.
#
# The try covers the REGISTRY READ and nothing else, which is the only thing the catch below can
# honestly claim to be a state rather than a fault. It used to wrap the whole loop, so one
# hand-edited `path: ` line with no value - which parses, is truthy, and throws from GetFullPath -
# abandoned resolution for every project at once and turned the gate off in silence.
#
# A registry that is not there at all is silent, and only that one: a fresh installation has
# registered nothing yet, and a warning on every dispatch until the first /annex is noise that
# teaches a reader to skip the next one. A registry that EXISTS and cannot be read is different -
# something is wrong with a file somebody wrote - so that one says so.
$project      = ''
$registered   = @()
$registryPath = Join-Path $DataPath 'projects.md'
if (Test-Path -LiteralPath $registryPath -PathType Leaf) {
    try {
        # Get-AllProjects returns the whole array as ONE pipeline object - Projects.psm1's
        # leading-comma idiom - so the loop below runs over the assigned value rather than an @()
        # wrap, which would nest it a second time and iterate once over the array itself.
        $registered = Get-AllProjects -RegistryPath $registryPath -WarningAction SilentlyContinue
    } catch {
        Write-Warning ("The project registry at $registryPath could not be read " +
                       "($($_.Exception.Message)), so no project index can be checked for this " +
                       "dispatch and no standing file can be attached. The root index still gates it.")
        $registered = @()
    }
}

$target = [IO.Path]::GetFullPath($RepoPath).TrimEnd('\')
foreach ($entry in $registered) {
    if (-not $entry.path -or -not $entry.indexable) { continue }
    # Guarded per entry, so one unusable path costs that entry and not the whole resolution.
    $entryPath = ''
    try { $entryPath = [IO.Path]::GetFullPath($entry.path).TrimEnd('\') }
    catch {
        Write-Warning ("Project $($entry.name) records a 'path:' line that is not a usable path " +
                       "($($_.Exception.Message)); skipping it while resolving this dispatch.")
        continue
    }
    if ($entryPath.Equals($target, [System.StringComparison]::OrdinalIgnoreCase)) {
        $project = $entry.name
        break
    }
}

# The project's own two files, composed by name from the project the registry just resolved. Only a
# name the index can turn into a file name ever reaches this - the loop above skips an entry whose
# name is not indexable - so the leaf is letters, digits, '.', '_' and '-' and can hold no separator
# and no traversal. That is the whole constraint keeping these two names inside the data root and
# off any other file.
$standing = [ordered]@{}
if ($project) {
    $standing["done-$project.md"]  = @{
        path = Join-Path $dataRoot "done-$project.md"
        what = "the standing definition of done for $project"
        # Says only what is true from HERE. muster usually pastes these lines into the brief as well
        # and writes its own line saying so, but this script never reads the brief's body, so a claim
        # about what the body contains is one it cannot stand behind - and it would be wrong in
        # exactly the case this attachment is the backstop for, where nobody pasted anything.
        how  = 'Read it in full. It is this project''s standing definition of done, and you work its lines one by one.'
    }
    $standing["rules-$project.md"] = @{
        path = Join-Path $dataRoot "rules-$project.md"
        what = ("the standing rules for $project - conventions, vocabulary, exclusions, branch " +
                "naming, environment facts")
        how  = ('Read it in full before you start. It is reference to consult, not a list to ' +
                'answer, so never self-report against its lines.')
    }
}

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

# What this dispatch attaches on its own, because nobody has to remember to. Order follows
# $standing, so the criteria file is named before the rules file in every brief.
#
# ABSENT IS AN ORDINARY STATE and says so quietly: a project with neither file dispatches exactly as
# it did before either existed. UNREADABLE IS NOT ABSENT, and the difference is the point - a rules
# file skipped in silence ships a worker without the project's standing instructions and leaves no
# trace that anything went missing, which is the failure this attachment exists to close. So a file
# that is there and cannot be opened stops the dispatch and names itself.
$autoStaged = [System.Collections.Generic.List[hashtable]]::new()
foreach ($leaf in $standing.Keys) {
    $p = $standing[$leaf].path
    if (-not (Test-Path -LiteralPath $p)) { continue }

    if (Test-Path -LiteralPath $p -PathType Container) {
        throw ("$p is where project $project's file of that name belongs and it is a directory. " +
               "A worker cannot be handed a directory to read. Move it aside, or put the file " +
               "there. Nothing was created.")
    }
    # Test-Path answers whether the entry is there, never whether it can be read. Opened rather than
    # read: this script never looks at what is inside either file, and a locked or unreadable file
    # has to fail here rather than at the copy, where a worktree would already exist.
    try { [System.IO.File]::OpenRead($p).Dispose() }
    catch {
        throw ("Project $project's file $p exists and could not be opened " +
               "($($_.Exception.Message)), so the worker would go out without it and nothing would " +
               "show that it had. Fix the file or move it aside deliberately - an absent file is " +
               "attached as nothing, an unreadable one is refused. Nothing was created.")
    }

    if ($staged.ContainsKey($leaf)) {
        # The same file, passed by hand as well. The Hand's own `Read first` line already names it,
        # so this adds nothing and writes no second line for it.
        if ($staged[$leaf].Equals($p, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        throw ("Read first names $($staged[$leaf]), and project $project's own $leaf at $p is " +
               "attached to every brief for this project. Both would land on $leaf in the staging " +
               "directory and one would overwrite the other. Pass the file under a distinct name, " +
               "or leave it out and let the project's own copy be the one the worker reads. " +
               "Nothing was created.")
    }

    $autoStaged.Add(@{
        leaf = $leaf
        path = $p
        what = $standing[$leaf].what
        how  = $standing[$leaf].how
    })
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
#
# Whether the brief carries a `## Browser checks` section is read here too, and for one purpose
# only: it is what tells the index gate below that the browser procedure was passed by rote rather
# than because this task is about that file. Read under the same fence rule, so a brief quoting
# muster's template does not acquire a browser step it never asked for.
#
# WHERE the section is, is remembered as well, so the lines for what this dispatch attaches on its
# own can be inserted into it. That is a position in the file rather than anything read out of it,
# and it is the section this loop was already finding.
#
# The POSITIONS are collected here, in this same pass, rather than by a second scan of their own.
# A second scan is what went wrong: it started after the heading and ran to the end of the file
# without skipping fences, so a brief quoting a generated line inside a fenced block under a later
# heading moved the insertion anchor there - and the attached copy ended up named inside a quoted
# block, in a section no worker acts on, which is the "a copy nothing names reaches nobody" failure
# this attachment exists to close. One boundary rule, computed once, cannot disagree with itself.
#
# $sectionIndexes covers the FIRST section only, because that is where the insertion goes, while
# $sectionLines keeps spanning every one of them - it feeds the index gate, which asks whether the
# statement was made anywhere at all. $sectionEnd is the last line still inside that first section,
# fenced lines included, so appending after it lands at the end of the section rather than inside a
# block it happens to finish with.
$briefLines     = @(Get-Content -LiteralPath $BriefPath)
$hasSection     = $false
$hasBrowser     = $false
$inSection      = $false
$inFence        = $false
$headingIndex   = -1
$sectionEnd     = -1
$firstOpen      = $false
$sectionLines   = [System.Collections.Generic.List[string]]::new()
$sectionIndexes = [System.Collections.Generic.List[int]]::new()
for ($i = 0; $i -lt $briefLines.Count; $i++) {
    $line = $briefLines[$i]
    if ($line -match '^\s*```') {
        $inFence = -not $inFence
        if ($firstOpen) { $sectionEnd = $i }
        continue
    }
    if ($inFence) {
        if ($firstOpen) { $sectionEnd = $i }
        continue
    }
    if ($line -match '^\s*##\s+Browser checks\b') { $hasBrowser = $true }
    if ($line -match '^\s*##\s+Read first\s*$') {
        $hasSection   = $true
        $inSection    = $true
        if ($headingIndex -lt 0) { $headingIndex = $i; $sectionEnd = $i; $firstOpen = $true }
        continue
    }
    if ($inSection) {
        if ($line -match '^\s*#{1,6}\s') { $inSection = $false; $firstOpen = $false; continue }
        $sectionLines.Add($line)
        if ($firstOpen) { $sectionIndexes.Add($i); $sectionEnd = $i }
    }
}

# The section has to be PRESENT. This is the check that closes the originating failure: a brief
# that names no settled file at all, a worker that never learns one exists, and a site shipped
# without the brand that was already decided. A brief with nothing to read says so in a line; a
# brief missing the slot says nothing, and the two are not the same fact.
#
# The line it recommends is the one the index gate below accepts, and it has to be: a first refusal
# that recommends a line the second refusal rejects costs two round trips and misleads on the first.
if (-not $hasSection) {
    throw ("The brief at $BriefPath has no '## Read first' section. Every brief carries one, " +
           "because a worker reads exactly one thing and a settled file it is never handed reaches " +
           "it not at all. Add the section naming each file to read - or the single line " +
           "'- Nothing beyond this brief - the index was checked and nothing in it applies.' when " +
           "the index turns up nothing this task touches, so that it reads as a decision rather " +
           "than an omission. Nothing was created.")
}

# The two files a browser step is carried out with: the procedure the worker reads and the module
# it imports. Rooted off this script rather than off the data root, because both are part of the
# installation rather than of anybody's data, and resolved so every comparison below sees the same
# shape Resolve-Path gave the staged copies.
$procedurePath = [System.IO.Path]::GetFullPath(
    (Join-Path $PSScriptRoot '..\.claude\skills\witness\SKILL.md'))
$modulePath    = [System.IO.Path]::GetFullPath(
    (Join-Path $PSScriptRoot 'BrowserVerify.psm1'))

# A brief that asks for browser checks has to hand both of them over, and prose saying so is not
# the mechanism - this is. A worker reaches its own worktree and the brief's directory and nowhere
# else, and it cannot load a skill from this repository at all, so the section points it at copies
# under read-first and those copies exist only because -ReadPath was passed. Forget either and the
# worker follows the section to a file that is not there, then either stops with the browser step
# dead or drives a browser with no read-only boundary, no dialog rule, no credential rule and no
# record format. That is the failure the whole file-delivery mechanism was added to close, and a
# gate a forgotten argument switches off is not a gate.
if ($hasBrowser) {
    $needed = [ordered]@{
        'browser procedure' = $procedurePath
        'browser module'    = $modulePath
    }
    $absent = @(foreach ($k in $needed.Keys) {
        $p = $needed[$k]
        $there = @($staged.Values | Where-Object {
            $_.Equals($p, [System.StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
        if (-not $there) { "the $k at $p" }
    })
    if ($absent.Count -gt 0) {
        throw ("The brief at $BriefPath carries a '## Browser checks' section and passes no " +
               "-ReadPath for " + ($absent -join ' or ') + ". A worker reaches its own worktree " +
               "and the brief's directory and nowhere else, so a section naming a file outside " +
               "both delivers nothing and would send it into a browser with none of the rules " +
               "attached. Pass each of those files to -ReadPath and name the copies under " +
               "'Read first' - or drop the '## Browser checks' section, which is the whole opt-in " +
               "and belongs only on a task that renders something to look at. Nothing was created.")
    }
}

# The index gate. The section exists; this asks whether the index behind it was actually consulted.
#
# The index was built, written to as files are written, and nothing obliged anyone to open it - and
# a pointer nobody is obliged to follow is exactly the failure that already happened once, when a
# settled brand spec named itself the input to the website brief and the site shipped without it. So
# forgetting the index is refused here, at the moment it happens, rather than discovered later.
#
# Every index that could cover this dispatch. "Lists something" is Index.psm1's answer, never a
# Test-Path of ours: an index file that lists nothing has nothing to consult, and demanding a
# statement about an empty table of contents would refuse a dispatch nobody could act on.
#
# The ROOT index is read whether or not the repo is registered - it is not project-scoped, and it is
# where the settled files this gate exists to protect are listed. Reading only the project index left
# the gate unable to fire at all.
$gates = [System.Collections.Generic.List[hashtable]]::new()

$rootEntries = @(Get-IndexEntries -DataPath $DataPath)
if ($rootEntries.Count -gt 0) {
    $gates.Add(@{
        label = 'the root index'
        path  = Get-IndexPath -DataPath $DataPath
        count = $rootEntries.Count
    })
}

if ($project) {
    $projectEntries = @(Get-IndexEntries -Project $project -DataPath $DataPath)
    if ($projectEntries.Count -gt 0) {
        $gates.Add(@{
            label = "project $project's index"
            path  = Get-IndexPath -Project $project -DataPath $DataPath
            count = $projectEntries.Count
        })
    }
}

if ($gates.Count -gt 0) {
    # The stated line, and nothing else about these lines. It has to name the index, say what was
    # DONE to it, and say nothing in it applies - all three, on one line, because that is a decision
    # somebody made, where an empty section or `- Nothing beyond this brief.` on its own says only
    # that the slot was filled in.
    #
    # First condition - the line is ABOUT an index. The token refuses a word character or a hyphen
    # on either side, because a hyphenated compound is a different noun rather than a mention: a
    # plain \bindex\b treats the hyphen as a word boundary, so `- Nothing in the search-index module
    # changes; read only the API layer.` satisfied it and went out having never had an index opened.
    # The plural counts, because muster sends the Hand to two indexes and "both indexes were checked"
    # is the sentence that writes itself.
    #
    # Second condition - what was DONE to it, which is what makes the line a statement rather than a
    # coincidence. Without it, two ordinary words landing on one line opened the gate: `- The search
    # index rebuild is out of scope; change nothing about it.` says nothing whatever about consulting
    # an index, and it was accepted - on exactly the class of task most likely to write the word.
    #
    # Third condition - that nothing in it applies, which is the decision itself. A line saying only
    # that an index was read has not said what reading it settled.
    $statesIndexChecked = $false
    foreach ($line in $sectionLines) {
        if ($line -match '(?<![\w-])index(es)?(?![\w-])' -and
            $line -match '\b(check|checked|consulted|read|reviewed)\b' -and
            $line -match '\b(nothing|none|no entr(y|ies))\b') {
            $statesIndexChecked = $true
            break
        }
    }

    # The project's own two standing files do not count towards this. Both arrive on EVERY brief for
    # a project that has them - the criteria file because muster passes it, and either because this
    # script attaches it whether or not anyone passed it - so counting one would make this refusal
    # unreachable from the moment the first is written. The gate's whole premise is that a -ReadPath
    # is evidence the Hand went through the index for THIS task, and a path that arrives by rote is
    # no evidence. Every other -ReadPath still counts, including another file sitting beside them in
    # data\.
    #
    # $standing was composed from $dataRoot, which is Index.psm1's own Resolve-IndexDataPath answer,
    # so these paths and the entries Get-IndexEntries just read above are rooted by one rule. Rooted
    # any other way - GetFullPath resolves against the process working directory, which Set-Location
    # does not move - a relative -DataPath would put the criteria file somewhere the index never
    # looked and the discount would silently stop discounting.
    #
    # The browser procedure and its module are the other two files muster passes by rote, on every
    # brief carrying a `## Browser checks` section - and by the refusal above, every such brief
    # passes both.
    #
    # Discounted only on a brief that carries that section, because only there are they passed by
    # rote. On a kingshand task to change the procedure itself, that file IS the subject and the
    # brief carries no browser checks - so it counts, exactly as any other file the Hand chose
    # would. A discount keyed on the path alone refused that dispatch and told it a reason that
    # was not true of it.
    $procedure = if ($hasBrowser) { $procedurePath } else { '' }
    $module    = if ($hasBrowser) { $modulePath }    else { '' }

    $byRote = [System.Collections.Generic.HashSet[string]]::new(
                  [System.StringComparer]::OrdinalIgnoreCase)
    foreach ($leaf in $standing.Keys) { $null = $byRote.Add($standing[$leaf].path) }
    foreach ($p in @($procedure, $module)) { if ($p) { $null = $byRote.Add($p) } }

    $engaged = @($staged.Values | Where-Object { -not $byRote.Contains($_) })

    if ($engaged.Count -eq 0 -and -not $statesIndexChecked) {
        # Every index that triggered this is named with its path, because the refusal is the Hand's
        # instruction sheet: a refusal that says only "an index" is one the reader has to research.
        $named = ($gates | ForEach-Object { "$($_.label) at $($_.path), listing $($_.count) file(s)" }) -join '; '
        # Said plainly when the brief DID pass a path, or the Hand reads a refusal denying what it
        # can see it just did and has no way to work out which path was discounted.
        #
        # The line recommended below changes with it, and the two standing-file cases part company.
        #
        # A file the Hand PASSED by hand is named by a line the Hand wrote, and nothing scopes that
        # line: the lead-in this script inserts covers only the bullets this script inserts. So the
        # literal line would still tell the worker there is nothing beyond the brief in the same
        # breath as the Hand's own line names a copy - the contradiction muster rules out, and the
        # 2026-09-02 reasoning for the paraphrase stands unchanged. That branch keeps recommending
        # muster's paraphrase, which states both halves and passes the regex above.
        #
        # A standing file this dispatch attaches ITSELF is different, and stopped being a
        # contradiction when the lead-in below was introduced: the lead-in sits above those bullets
        # and says in the section that they arrive on top of whatever else it says, including a line
        # saying nothing beyond this brief was named. So that branch recommends the canonical short
        # literal line, because the lead-in is what makes it true. $beyond is what tells the two
        # apart: it is filled only from paths the brief actually passed.
        #
        # Every clause stands on its own, because any of them can be the first one written. An
        # earlier version had the browser clause open with "for the same reason" and end with
        # "either", which on a project with no criteria file referred back to a sentence that was
        # never there.
        $wasPassed = {
            param($path)
            $path -and @($staged.Values | Where-Object {
                $_.Equals($path, [System.StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
        }
        # Walked in $standing's order, so the criteria file is named before the rules file wherever
        # both were passed by hand.
        $discountedPaths = @(foreach ($leaf in $standing.Keys) {
            if (& $wasPassed $standing[$leaf].path) { $standing[$leaf].path }
        })
        $passedProcedure = [bool](& $wasPassed $procedure)
        $passedModule    = [bool](& $wasPassed $module)

        $clauses = @()
        $beyond  = @()
        if ($discountedPaths.Count -eq 1) {
            $clauses += ("$($discountedPaths[0]), one of the project's own standing files, which " +
                         'every brief for this project passes')
        } elseif ($discountedPaths.Count -gt 1) {
            $clauses += (($discountedPaths -join ' and ') + " - the project's own standing files, " +
                         'which every brief for this project passes')
        }
        if ($discountedPaths.Count -gt 0) { $beyond += 'the standing criteria' }
        if ($passedProcedure) {
            $clauses += ("the browser procedure $procedure, which every brief carrying browser " +
                         'checks passes')
            $beyond  += 'the browser procedure'
        }
        if ($passedModule) {
            $clauses += ("the browser module $module, which every brief carrying browser checks " +
                         'passes')
            $beyond  += 'the browser module'
        }

        $discounted = ''
        $stated = "'- Nothing beyond this brief - the index was checked and nothing in it applies.'"
        if ($clauses.Count -gt 0) {
            $lead = if ($clauses.Count -eq 1 -and $discountedPaths.Count -le 1) {
                        'The only file this brief passes is'
                    } else { 'The only files this brief passes are' }
            $discounted = ("$lead " + ($clauses -join '; and ') + " - each passed by rote, so " +
                           'none of them says anything about this task. ')
        } elseif ($autoStaged.Count -gt 0) {
            $discounted = ("This dispatch attaches project $project's own " +
                           "$(($autoStaged | ForEach-Object { $_.leaf }) -join ' and ') by itself, " +
                           "and every brief for this project gets them, so they say nothing about " +
                           "this task either. ")
        }

        # The recommended line names every copy the section already hands over, because a line
        # saying nothing applies beyond one of them, written beside a section naming two, is the
        # same self-contradiction this branch exists to keep out of the brief. Empty where the only
        # copies came from this dispatch, so that case keeps the canonical short literal line.
        if ($beyond.Count -gt 0) {
            $beyondText = if ($beyond.Count -le 2) { $beyond -join ' and ' }
                          else { ($beyond[0..($beyond.Count - 2)] -join ', ') + ' and ' + $beyond[-1] }
            $stated = ("'- The index was checked; nothing in it applies to this task beyond " +
                       "$beyondText above.' - which says so without contradicting " +
                       'what the section already hands the worker.')
        }
        throw ("This dispatch is gated by $named - and this brief neither names a file from them to " +
               "read nor says they were checked. $discounted" +
               "A worker reads exactly one thing, so a settled file " +
               "no brief names reaches it not at all - which is how a site shipped without the brand " +
               "that was already decided. Open each index named above, then either pass -ReadPath for " +
               "each file this task touches and name the copies under 'Read first', or put one line " +
               "there saying the index was checked and nothing in it applies - $stated Nothing was " +
               "created.")
    }
}

# The lines this dispatch will add to the brief for what it attached itself, composed here so the
# same text is produced every time. That is what makes a re-dispatch add nothing: the check below is
# a whole-line comparison against text this script wrote, never a search for a file name in prose.
#
# One physical line per file, however long. A brief is generated, and a line broken for width is a
# line the idempotence check would have to reassemble.
#
# Composed through one function because the same text has to be produced for a file that is THERE
# and for one that has since been REMOVED - the line an earlier dispatch wrote can only be found
# again by composing exactly what was written. Everything it needs comes from $standing, which is
# built from the project name alone and so survives the file itself going away.
function New-AutoLine {
    param([Parameter(Mandatory)][string]$Leaf, [Parameter(Mandatory)]$Entry)
    "- ``$(Join-Path $readFirstDir $Leaf)`` - $($Entry.what), attached automatically at dispatch " +
    "from ``$($Entry.path)`` rather than named by hand. $($Entry.how)"
}

$autoLines = @(foreach ($a in $autoStaged) { New-AutoLine -Leaf $a.leaf -Entry $standing[$a.leaf] })

# The one line that goes above them, and the reason the block can be inserted into a section that
# already says there is nothing to read. The Hand writes `- Nothing beyond this brief - the index was
# checked and nothing in it applies.` when the index turns up nothing, and that line is true about
# the index at the moment it was written; these copies arrive afterwards and from somewhere else. So
# the block SCOPES ITSELF rather than editing what the Hand wrote - nothing here parses the section
# looking for a sentence to rewrite, and nothing suppresses the attachment, because a standing file
# that reaches nobody is the whole failure this exists to close.
#
# One physical line, like the bullets, so the idempotence check below is a whole-line comparison.
$autoLeadIn = ('- The file(s) named directly below were attached by dispatch from this project''s ' +
               'own standing files, not by hand. They apply as well as everything else in this ' +
               'section, including any line saying nothing beyond this brief was named - that line ' +
               'was written before these were attached. Read them.')

# WHAT this dispatch will actually add to the brief, and WHERE - decided here, before anything is
# created, because the preflight below has to key on whether there is a write at all rather than on
# whether there is something attached. On an ordinary re-dispatch every line is already in the brief
# and no write happens, so demanding an exclusive handle on the file would refuse over a write that
# was never going to be performed - and a share lock is transient, where the read-only flag it
# replaced was a deliberate persistent state.
#
# Only lines the brief does not already carry verbatim, so a second dispatch of the same ticket
# changes nothing. Comparison is whole-line and ordinal against text this script composed itself -
# never a search for a file name in prose, and no parser of the section.
#
# WHERE is decided per line rather than for the block as a whole, because the block is not always
# added as a block. The lead-in scopes the bullets, so it stays above them; and $standing's order -
# criteria before rules - has to survive the GROWTH CASE, where one file was already named by an
# earlier dispatch and another has since appeared. Inserting the missing lines together at one anchor
# under the lead-in put the newest file ABOVE one already there, silently reversing that order.
#
# So the composed lines are walked in their own order behind a moving anchor. A line already in the
# brief moves the anchor onto it; a line that is missing is scheduled just after the current anchor
# and becomes the anchor itself, so the next missing line lands after it rather than on top of it.
# The anchor starts at the lead-in when the section already carries it, and at the END of the section
# when it does not, in which case the lead-in is the first thing scheduled and every bullet follows
# it. Appending rather than inserting at the top is what makes the lead-in's own sentence true: it
# says the files named DIRECTLY BELOW were attached by dispatch and not by hand, so it must not be
# put above lines the Hand wrote. The Hand's bullets keep their place, and the order among the
# attached lines themselves is unchanged - lead-in, criteria, rules, for a first dispatch with either
# or both files and for growth in either direction.
#
# Every comparison is whole-line and ordinal against text this script composed itself - never a
# search for a file name in prose, and no parser of the section. Only lines INSIDE the Read first
# section are indexed, by the same boundary the parse pass above computed, so a copy quoted in a
# fenced block or under a later heading can neither claim the anchor nor pass for one already there.
$toAdd = @()
$plan  = [System.Collections.Generic.Dictionary[int, System.Collections.Generic.List[string]]]::new()
$seen  = [System.Collections.Generic.Dictionary[string, int]]::new([System.StringComparer]::Ordinal)
foreach ($idx in $sectionIndexes) {
    $t = $briefLines[$idx].Trim()
    if (-not $seen.ContainsKey($t)) { $seen[$t] = $idx }
}

# A standing file the King has REMOVED must stop reaching the worker. An earlier dispatch of this
# same ticket copied it into read-first\ and wrote a line naming it; nothing about it being absent
# now would otherwise undo either, so the worker would be handed rules the King deleted under a line
# asserting they came from a file that is no longer there. Both are cleared instead, and the whole
# thing is reversible: restore the file, re-dispatch, and both come back.
#
# Scoped as tightly as it can be, by TWO conditions that are only safe together.
#
# The first is the -ReadPath guard, and it covers this dispatch: a leaf the Hand passed is the Hand's
# own file staged under the same name, and the line naming it is a line the Hand wrote. Neither is
# this script's to touch.
#
# The second covers every EARLIER dispatch, which the first cannot see. `read-first\<leaf>` is one
# directory shared by both routes, so the copy on disk carries no record of who put it there - and
# muster passes `data\done-<project>.md` through -ReadPath on every brief it writes, with a bullet
# of its own wording. Retire that file and re-dispatch, and the leaf looks exactly like an abandoned
# auto-attachment: absent source, copy present, nothing passed this time. Deleting it on that
# evidence removed the Hand's file while the Hand's differently-worded bullet survived, leaving the
# brief naming a file that is gone - the very thing -ReadPath is refused for above, reached through
# the pruning meant to prevent staleness.
#
# So the discriminator is this script's OWN composed bullet for that leaf being in the Read first
# section. That line is written by nothing else, so its presence is the only available evidence that
# this script staged the copy. Where it is absent - the Hand's own line is there instead, or no line
# at all - nothing is removed and the copy is left alone: the copy is then not this script's to
# delete, and a stale copy a line correctly names is better than a live line naming nothing.
$staleBullets = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
$staleCopies  = [System.Collections.Generic.List[string]]::new()
foreach ($leaf in $standing.Keys) {
    if ($staged.ContainsKey($leaf)) { continue }
    if (Test-Path -LiteralPath $standing[$leaf].path) { continue }
    $bullet = (New-AutoLine -Leaf $leaf -Entry $standing[$leaf]).Trim()
    if (-not $seen.ContainsKey($bullet)) { continue }
    $null = $staleBullets.Add($bullet)
    $copy = Join-Path $readFirstDir $leaf
    if (Test-Path -LiteralPath $copy -PathType Leaf) { $staleCopies.Add($copy) }
}
# With no attached bullet left, the lead-in introduces nothing and goes with them.
if ($staleBullets.Count -gt 0 -and $autoLines.Count -eq 0) {
    $null = $staleBullets.Add($autoLeadIn.Trim())
}

$removeIndexes = [System.Collections.Generic.HashSet[int]]::new()
if ($staleBullets.Count -gt 0) {
    foreach ($idx in $sectionIndexes) {
        if ($staleBullets.Contains($briefLines[$idx].Trim())) { $null = $removeIndexes.Add($idx) }
    }
}

if ($autoLines.Count -gt 0 -and $headingIndex -ge 0) {
    if (@($autoLines | Where-Object { -not $seen.ContainsKey($_.Trim()) }).Count -gt 0) {
        $anchor = $sectionEnd
        if ($seen.ContainsKey($autoLeadIn.Trim())) {
            $anchor = $seen[$autoLeadIn.Trim()]
        } else {
            if (-not $plan.ContainsKey($anchor)) {
                $plan[$anchor] = [System.Collections.Generic.List[string]]::new()
            }
            $plan[$anchor].Add($autoLeadIn)
            $toAdd += $autoLeadIn
        }

        foreach ($line in $autoLines) {
            if ($seen.ContainsKey($line.Trim())) { $anchor = $seen[$line.Trim()]; continue }
            if (-not $plan.ContainsKey($anchor)) {
                $plan[$anchor] = [System.Collections.Generic.List[string]]::new()
            }
            $plan[$anchor].Add($line)
            $toAdd += $line
        }
    }
}

# Refused BEFORE anything is created, like every other refusal here. A brief that cannot be written
# to would leave the copies on disk with nothing telling the worker to open them - the failure this
# attachment exists to close, arrived at through the attachment itself.
#
# The brief is OPENED for writing rather than inspected for its read-only flag. The flag is one cause
# among several and not the common one: another process holding the file, or an ACL denying write,
# reaches the Set-Content below exactly the same way and used to abort it with the copies already on
# disk and no line naming them. Disposed at once - this asks the question, it is not the write.
#
# The residual this cannot close is a failure BETWEEN here and the write - a full disk, or another
# process taking the file in that window. A retry is idempotent: the copies are overwritten in place
# and the insertion is checked line by line against what the brief already carries, so nothing is
# duplicated by running the dispatch again.
#
# Removing a stale line is a write like any other, and a stale copy is deleted just below it, so this
# guards that case too rather than only an insertion.
if ($toAdd.Count -gt 0 -or $removeIndexes.Count -gt 0) {
    try { [System.IO.File]::Open($BriefPath, 'Open', 'ReadWrite', 'None').Dispose() }
    catch {
        $why = $_.Exception.Message
        # Read back after the failure, so the read-only case keeps saying so plainly instead of
        # being folded into a generic access message the reader has to interpret.
        $readOnly = $false
        try { $readOnly = (Get-Item -LiteralPath $BriefPath).IsReadOnly } catch { }
        $cause = if ($readOnly) { 'that file is read-only' }
                 else           { "that file could not be opened for writing ($why)" }
        $fix   = if ($readOnly) { 'Clear the read-only flag on the brief.' }
                 else           { 'Close whatever is holding it open, or fix its permissions.' }
        throw ("Project $project's standing files have to be named in $BriefPath under 'Read first' " +
               "and $cause, so the worker would be handed copies nothing tells it to read. $fix " +
               "Nothing was created.")
    }
}

# Copied only once every check above has passed, so a refusal is always true when it says nothing
# was created. Staging first left a directory and a file on disk under a message denying both.
#
# The two sources share one directory and one leaf-name space: $staged is keyed case-insensitively
# and the auto-attach loop above refused any leaf already in it, so no copy here can land on
# another. The order is the Hand's files first, then the project's, and it does not matter - by this
# point every name is distinct.
if ($staged.Count -gt 0 -or $autoStaged.Count -gt 0) {
    if (-not (Test-Path -LiteralPath $readFirstDir)) {
        New-Item -ItemType Directory -Force -Path $readFirstDir | Out-Null
    }
    foreach ($leaf in $staged.Keys) {
        Copy-Item -LiteralPath $staged[$leaf] -Destination (Join-Path $readFirstDir $leaf) -Force
    }
    foreach ($a in $autoStaged) {
        Copy-Item -LiteralPath $a.path -Destination (Join-Path $readFirstDir $a.leaf) -Force
    }
}

# And the brief is told, because a copy nothing names reaches nobody. Written AFTER the copies, so
# the brief never names a file that failed to arrive. What goes in and where it goes were both
# decided above, so nothing is recomputed here.
if ($toAdd.Count -gt 0 -or $removeIndexes.Count -gt 0) {
    $rewritten = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $briefLines.Count; $i++) {
        if (-not $removeIndexes.Contains($i)) { $rewritten.Add($briefLines[$i]) }
        if ($plan.ContainsKey($i)) { foreach ($l in $plan[$i]) { $rewritten.Add($l) } }
    }
    Set-Content -LiteralPath $BriefPath -Encoding utf8 -Value $rewritten.ToArray()
}

# The copy of a standing file that is no longer there. Each path was composed above from a leaf this
# script owns, confirmed to be a file, and confirmed to be named by this script's own bullet, so this
# removes something this script itself staged and nothing else.
#
# Deleted AFTER the rewrite, which is the safe order for a removal: an addition writes the line only
# once the file has arrived, and a removal deletes the file only once the line naming it has gone.
# Fail in between either way and the brief still describes what is on disk.
foreach ($copy in $staleCopies) { Remove-Item -LiteralPath $copy -Force }

# WHICH ref this is belongs to Resolve-BaseRef.ps1's header, and nothing here restates it. What
# matters at this call site is that the one string it returns is used twice below - as the branch
# point `git worktree add -b` cuts from, and as the base recorded for the landing gate - so on a
# FIRST dispatch the recorded base is where the worktree actually started, by construction.
#
# That holds for the fresh-branch path and only that one. The two re-dispatch paths below do not
# branch at all: one reuses a registered worktree without touching git, the other checks out a
# branch that survived its worktree, and in both the branch point is whatever the earlier dispatch
# chose. Resolve it again after the repository has moved - a `.no-mistakes.yaml` added since, a
# default branch that changed - and the base recorded here describes a branch cut somewhere else,
# so `git log "$base..HEAD"` carries commits nobody in this ticket wrote. The landing gate's
# attribution scan runs over that same range, so any of them carrying a co-author trailer surfaces
# there - which muster reads as a bad diff base rather than as the worker's doing - but the rest
# just widen the diff. Closing that gap is possible and is simply not done here: the branch's own
# reflog records where it was cut from - `git reflog show worktree-<name>` ends at
# `branch: Created from <ref>`, written by the `-b` add below, so it exists by construction on the
# reuse path and survives until gc.reflogExpire - and crew.json already holds the base the first
# dispatch recorded under this same worker id. Either would give the real branch point; both are
# a behaviour change to make deliberately rather than a line to slip in beside a comment.
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
