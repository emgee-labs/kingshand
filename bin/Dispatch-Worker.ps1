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

  The brief's own `Read first` section is what decides whether -ReadPath was right, and the two
  must agree in both directions: every read-first\<file> the section names must have been staged by
  this call, and every file this call stages must be named there. One direction alone leaves the
  other half of the fault reachable - a section naming the ORIGINAL path instead of the copy stages
  the file and still sends the worker somewhere it cannot read. The two are written in different
  steps, and prose was the only thing tying them together.

  They must agree on the directory as well as the file name. A `read-first\` path under another
  unit of work's id agrees on the name with what this call staged and still points outside this
  worker's only grant, so it is refused by name.

  Both of those checks are keyed on `read-first\<file>` mentions, so a section that names ONLY the
  original - the path the Hand actually knows, `data\<name>.md` - put nothing in either set and
  passed them both, with or without -ReadPath. So the section is also read for any path under the
  data root that is not under the brief's own directory: that is precisely the tree the single
  grant excludes, and a path there reaches nothing. A path handed to -ReadPath is exempt, which is
  what keeps the template's "copied here from <original>" note legal.

  That last check reads all three forms such a path is written in, not just drive-letter paths:
  `C:\...\data\<name>.md`, the `$env:KINGSHAND_HOME\data\<name>.md` the brief template itself
  models, and the `data\<name>.md` the index stores. The latter two are resolved against the
  brief's own data root, because the brief's directory is what this dispatch actually knows about
  the tree. The relative form is refused only when it names a real file there, since it is the one
  shape that could equally be a path in the repo the worker is about to work in.

  It reads the `Read first` section and NOT the whole brief, on purpose. That section is the list
  of files the worker must open, so an unreachable path in it is a defect; elsewhere a data\ path is
  prose - a brief about this repo describes `data\backlog.md` without asking anyone to open it - and
  refusing a legitimate brief is worse than the gap.

  Every path is lifted out of a line WHOLE before any of this matches against it, because a file
  name may contain a space. Each pattern used to stop at the first one, which refused a correct
  brief naming `read-first\brand spec.md` by comparing the leaf `brand` against the staged
  `brand spec.md`, and blinded the scan above to `data\brand spec.md` by looking for a file called
  `data\brand`. The template writes paths in backticks, so a backtick span is one candidate; a path
  written without them yields the token, the token plus the next word, and so on, and whichever
  reading the staged copy or the filesystem confirms is the one used.

  Fenced code is quoted text and is skipped entirely. A brief that quotes the brief template used
  to have that quotation read as its own structure: the quoted `## Read first` heading satisfied the
  mandatory-section check for a brief that had none, and the quoted `<id>` placeholder was refused
  as another unit of work's directory.

  And the section must EXIST. Agreement between two empty sets is not agreement about anything, so
  a brief with no `## Read first` heading passed every check above while naming no settled file at
  all - the original failure exactly, not a variant of it. A brief with nothing to read says so in
  one line; a brief missing the slot says nothing, and only the first is a decision. Refusing here
  costs one line in a brief that has not been dispatched yet.
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
               "$resolved. One would overwrite the other. Pass only the one this task needs, or " +
               "copy one under a distinct name first and pass that copy. Do not rename either " +
               "original: two reports really are both called report.md, and that name is the " +
               "convention every index entry pointing at them already uses. Nothing was created.")
    }
    $staged[$leaf] = $resolved
}

# The brief and -ReadPath are written in two different steps and nothing but prose tied them
# together. It is the brief's own text that the worker acts on, so it is the brief's own text that
# is checked, and the check runs BOTH ways: a line naming a copy nothing staged, and a staged copy
# no line names, are the same fault seen from opposite ends and each leaves the worker holding a
# path it cannot open.
#
# The file name is compared, and so is the ONE segment in front of `read-first`, which has to be
# this brief's own directory. Matching the name alone let another ticket's directory through -
# briefs are written several at a time from one template, so `data\T-1002\read-first\brand.md`
# copied into T-1003's brief agreed on the name with what T-1003 staged and still sent the worker
# outside its only grant. The segment is compared rather than the whole path because the root may
# be written expanded or not, and a bare `read-first\<file>` carries no segment at all and is
# taken as this brief's own. The template's "copied here from <original>" note never puts a
# foreign id in front of `read-first`, so it stays untouched.
#
# A path is pulled out of a line as a WHOLE candidate before anything is matched against it,
# because a file name is allowed to contain a space and every earlier pattern stopped at the first
# one. `read-first\brand spec.md` parsed as the leaf `brand spec.md` in the staging loop above and
# as `brand` here, so a correctly written brief was refused with a message naming a file nobody
# had mentioned - and in the other direction an unreachable `data\brand spec.md` was scanned as
# `data\brand`, which exists nowhere and so was waved through.
#
# The template writes paths in backticks, so a backtick span is one candidate, spaces and all. A
# path written WITHOUT them is where the space is undecidable from the text alone, so each starting
# token instead yields a RUN of candidates - the token, then the token plus the next word, and so on
# - and the caller keeps the one its own evidence confirms: the copy the section named that was
# actually staged, or the path that actually names a file. Nothing is added for a run whose
# candidates confirm nothing, so extending never invents a mention; it only stops truncating one.
function Get-PathCandidate {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Line)

    $runs  = [System.Collections.Generic.List[string[]]]::new()
    $plain = [System.Text.StringBuilder]::new()
    $i     = 0
    while ($i -lt $Line.Length) {
        $open = $Line.IndexOf('`', $i)
        if ($open -lt 0) {
            $null = $plain.Append($Line.Substring($i))
            break
        }
        $null = $plain.Append($Line.Substring($i, $open - $i))
        $close = $Line.IndexOf('`', $open + 1)
        if ($close -lt 0) {
            $null = $plain.Append($Line.Substring($open + 1))
            break
        }
        $span = $Line.Substring($open + 1, $close - $open - 1).Trim()
        if ($span) { $runs.Add(@($span)) }
        # A separator in place of the span, or the words either side of it join into one token.
        $null = $plain.Append(' ')
        $i = $close + 1
    }

    $tokens = @(
        foreach ($token in ($plain.ToString() -split '\s+')) {
            $trimmed = $token.Trim('(', '[', '{', '<', '>', '|', '"', "'", ',', ';', ':', ')', ']', '}', '!', '?', '.')
            if ($trimmed) { $trimmed }
        }
    )

    # Seven words past the first is far more than any real file name, and a bound keeps a long
    # prose line from generating candidates by the square of its length.
    for ($start = 0; $start -lt $tokens.Count; $start++) {
        $alternatives = [System.Collections.Generic.List[string]]::new()
        $last = [Math]::Min($tokens.Count - 1, $start + 7)
        for ($end = $start; $end -le $last; $end++) {
            $alternatives.Add(($tokens[$start..$end] -join ' '))
        }
        $runs.Add($alternatives.ToArray())
    }

    , $runs
}

# Fenced blocks are QUOTED TEXT, not this brief's own structure, and both halves of the section
# guard read them as structure. A brief for a task on muster's own template quotes that template,
# fence and all: the quoted `## Read first` heading satisfied the mandatory-section check for a
# brief that had no section of its own, and the quoted placeholder line
# `$env:KINGSHAND_HOME\data\<id>\read-first\<filename>` was then read as a real path whose owner
# segment is the literal `<id>`, refusing the dispatch over "another unit of work's read-first
# directory" for a path nobody wrote as a path. Skipping fenced lines closes both at once.
$briefLeaf  = Split-Path $briefDir -Leaf
$briefLines = @(Get-Content -LiteralPath $BriefPath)
$inSection  = $false
$inFence    = $false
$hasSection = $false
$named      = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$foreign    = [System.Collections.Generic.List[string]]::new()
$sectionLines = [System.Collections.Generic.List[string]]::new()
$readFirstPattern = '(?:(?<owner>[^\\/]+)[\\/])?read-first[\\/](?<leaf>[^\\/]+)$'
foreach ($line in $briefLines) {
    if ($line -match '^\s*```') {
        $inFence = -not $inFence
        continue
    }
    if ($inFence) { continue }
    if ($line -match '^\s*##\s+') {
        $inSection = $line -match '^\s*##\s+Read first\s*$'
        if ($inSection) { $hasSection = $true }
        continue
    }
    if (-not $inSection) { continue }
    $sectionLines.Add($line)

    foreach ($run in (Get-PathCandidate -Line $line)) {
        $pick = $null
        foreach ($alternative in $run) {
            $m = [regex]::Match($alternative, $readFirstPattern)
            if (-not $m.Success) { continue }
            # The match has to begin where the path does. Extending a candidate across spaces means
            # `Read read-first\brand` is one of them, and reading a leaf out of that invents the
            # file `brand` from two words of prose.
            if ($m.Index -gt 0 -and $alternative[$m.Index - 1] -notin @('\', '/')) { continue }
            if (-not $pick) { $pick = $m }
            # The staged copy is the evidence that this longer reading is the real file name.
            if ($staged.ContainsKey($m.Groups['leaf'].Value)) {
                $pick = $m
                break
            }
        }
        if (-not $pick) { continue }
        $owner = $pick.Groups['owner'].Value
        if ($owner -and $owner -ne $briefLeaf) {
            $foreign.Add($pick.Value)
            continue
        }
        $null = $named.Add($pick.Groups['leaf'].Value)
    }
}

# The section has to be PRESENT, not merely consistent with -ReadPath. Every other check here
# compares two sets, and both are empty when the section was never written and -ReadPath was never
# passed - so the one case this whole mechanism exists to prevent was the one case that passed
# every guard. That case is the original failure verbatim: a brief that names no settled file, a
# worker that never learns one exists, and a site shipped without the brand that was already
# decided. A brief with nothing to read says so in a line; a brief missing the slot says nothing,
# and the two are not the same fact.
if (-not $hasSection) {
    throw ("The brief at $BriefPath has no '## Read first' section. Every brief carries one, " +
           "because a worker reads exactly one thing and a settled file it is never handed reaches " +
           "it not at all. Add the section naming each file to read - or the single line " +
           "'- Nothing beyond this brief.' when the index turns up nothing this task touches, so " +
           "that it reads as a decision rather than an omission. Nothing was created.")
}

if ($foreign.Count -gt 0) {
    throw ("The brief's Read first section names " + (($foreign | Sort-Object -Unique) -join ', ') +
           ", which is another unit of work's read-first directory, not this one's. A worker can " +
           "read only $briefDir, so that path reaches nothing. Name it under " +
           "$briefLeaf\read-first\ instead. Nothing was created.")
}

$unstaged = @(@($named) | Where-Object { -not $staged.ContainsKey($_) } | Sort-Object)
if ($unstaged.Count -gt 0) {
    throw ("The brief's Read first section names " + ($unstaged -join ', ') + " under read-first\, " +
           "and nothing staged " + $(if ($unstaged.Count -eq 1) { 'it' } else { 'them' }) + ". Pass " +
           "the original of each to -ReadPath, or take the line out of the brief. Nothing was created.")
}

$unnamed = @(@($staged.Keys) | Where-Object { -not $named.Contains($_) } | Sort-Object)
if ($unnamed.Count -gt 0) {
    throw ("-ReadPath stages " + ($unnamed -join ', ') + " and the brief's Read first section names " +
           $(if ($unnamed.Count -eq 1) { 'no line for it' } else { 'no line for them' }) + ". A copy " +
           "the brief never names reaches nobody, and a section naming the ORIGINAL instead points " +
           "the worker outside the only directory it can read. Name each one as " +
           "read-first\<filename> in that section. Nothing was created.")
}

# The residual case, and the one both checks above are blind to: a section naming the ORIGINAL and
# no copy at all. Neither set is keyed on it - no `read-first\` file was named, so nothing was
# missing, and with -ReadPath omitted nothing was staged either, so nothing was unnamed. Every
# guard passed on two empty sets while the brief pointed the worker at data\<name>.md, a sibling of
# the one directory it can read.
#
# Scoped to the data root rather than to every absolute path, because that is the tree the single
# grant deliberately excludes - every other worker's brief and report, king.md, learnings.md,
# backlog.md and projects.md. A path under the brief's own directory is reachable, and a path
# passed to -ReadPath is what the template's "copied here from <original>" note repeats, so both
# are exempt. Paths are compared normalized: the root may be written expanded or with `..` in it.
#
# All THREE forms a kingshand path is actually written in are read, because a drive-letter scan
# alone missed the two the Hand is most likely to type. muster's own brief template writes
# `$env:KINGSHAND_HOME\data\...`, and the index stores its entries relative to the install root as
# `data\<name>.md` - so a section naming the settled file in either form sailed past a check whose
# claim was "any path under the data root". Both are resolved against the BRIEF's own data root
# rather than against the environment variable: the brief's directory is the ground truth for
# where this dispatch's data lives, and an installation whose KINGSHAND_HOME points somewhere else
# would otherwise resolve the mention out of the tree and pass it.
#
# The relative form is the one genuinely ambiguous shape - `data\schema.json` could be a file in
# the repo the worker is about to work in - so it is refused only when it really names a file under
# the data root. The other two forms name kingshand's own tree by construction and need no such
# proof.
#
# It reads the `Read first` section ONLY, and that is deliberate - do not widen it to the whole
# brief. That section is by definition the list of files the worker must open, so every path in it
# ought to be a staged copy and "this one is not reachable" is a decidable statement about it.
# Anywhere else in a brief a data\ path is prose: a statute task on this very module carries
# "`Add-IndexEntry` must list `data\backlog.md` the first time the digest reports it unindexed"
# under Requirements, which is a description of behaviour, not an instruction to open a file. A
# whole-brief scan refused that brief and offered staging a dispatch-time snapshot of the live
# backlog as the remedy, which is not what the line meant. Refusing a legitimate brief is worse
# than the gap.
$dataRoot = Split-Path $briefDir -Parent
$outside  = [System.Collections.Generic.List[string]]::new()
if ($dataRoot) {
    $rootPrefix  = [IO.Path]::GetFullPath($dataRoot).TrimEnd('\') + '\'
    $briefPrefix = [IO.Path]::GetFullPath($briefDir).TrimEnd('\') + '\'
    $homeRoot    = Split-Path $dataRoot -Parent
    $dataLeaf    = Split-Path $dataRoot -Leaf
    $originals   = [System.Collections.Generic.HashSet[string]]::new(
                       [System.StringComparer]::OrdinalIgnoreCase)
    foreach ($v in $staged.Values) { $null = $originals.Add($v) }

    $forms = [System.Collections.Generic.List[hashtable]]::new()
    $forms.Add(@{ kind = 'absolute'; pattern = '^[A-Za-z]:[\\/].+$' })
    if ($homeRoot) {
        $forms.Add(@{ kind = 'home'; pattern = '^\$env:KINGSHAND_HOME[\\/].+$' })
        if ($dataLeaf) {
            $forms.Add(@{ kind    = 'relative'
                          pattern = '^' + [regex]::Escape($dataLeaf) + '[\\/].+$' })
        }
    }

    # One mention, resolved: $null when it is not a kingshand path this worker is barred from, and
    # otherwise the resolved path plus whether a file is really there.
    function Resolve-Mention {
        param([Parameter(Mandatory)][string]$Mention)

        foreach ($form in $forms) {
            if ($Mention -notmatch $form.pattern) { continue }
            $target = switch ($form.kind) {
                'absolute' { $Mention }
                'home'     { Join-Path $homeRoot ($Mention -replace '^\$env:KINGSHAND_HOME[\\/]', '') }
                default    { Join-Path $homeRoot $Mention }
            }
            $full = $null
            try { $full = [IO.Path]::GetFullPath($target) } catch { return $null }
            if ($originals.Contains($full)) { return $null }
            $probe = $full.TrimEnd('\') + '\'
            if ($probe.StartsWith($briefPrefix, [StringComparison]::OrdinalIgnoreCase)) { return $null }
            if (-not $probe.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) { return $null }

            $exists = [bool](Test-Path -LiteralPath $full -PathType Leaf)
            # The relative form is the ambiguous one, so it counts only when the file is really
            # there; the other two name kingshand's tree by construction and are refused either way.
            if ($form.kind -eq 'relative' -and -not $exists) { return $null }
            return @{ full = $full; exists = $exists }
        }
        $null
    }

    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($line in $sectionLines) {
        foreach ($run in (Get-PathCandidate -Line $line)) {
            $take = $null
            foreach ($alternative in $run) {
                $r = Resolve-Mention -Mention $alternative
                if (-not $r) { continue }
                # An existing file is proof that this reading of the words is the path meant, so it
                # wins over the shorter one that named nothing.
                if ($r.exists) {
                    $take = @{ mention = $alternative; full = $r.full }
                    break
                }
                if (-not $take) { $take = @{ mention = $alternative; full = $r.full } }
            }
            if ($take -and $seen.Add($take.full)) { $outside.Add($take.mention) }
        }
    }
}

if ($outside.Count -gt 0) {
    $bad  = @($outside | Sort-Object -Unique)
    $leaf = Split-Path $bad[0] -Leaf
    throw ("The brief at $BriefPath names " + ($bad -join ', ') + " under Read first, and a worker " +
           "can read only $briefDir - so that path reaches nothing, which is the original failure " +
           "with one extra hop. Pass each one to -ReadPath and name the copy in that section " +
           "instead, one line each - '- read-first\$leaf - what it settles, copied here from " +
           "$($bad[0]). Read it in full.' Nothing was created.")
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
