#Requires -Version 7.0
Set-StrictMode -Version Latest

# The data index: one line per durable file kingshand holds, so a later session can find it.
#
# The failure this exists to prevent: a fully settled brand spec sat in data\ naming itself the
# input to the website brief, and the site shipped with none of it, because nothing made anyone
# read the file. The first fix attempted was a "settled decisions" category - and classifying a
# file as important at the moment it is written means guessing what some future task will need.
# That guess is wrong regularly and silently, which is the same failure in a different hat.
#
# So nothing here judges importance. EVERY durable file gets one line; the reader decides at read
# time, with the context to decide, which handful of files their own task actually touches.
#
# Entry format, one physical line however long, matching the registry's one-line rule:
#   - `data\emgee-brand.md` - settled brand: logo, favicon, tagline, palettes (added 2026-08-29)
#
# Paths are stored relative to the installation root, so a clone at a different path still
# resolves. The summary is capped: this is a table of contents, never content, and a cap is the
# only thing that keeps it one.
#
# The exclusions are mechanical and none is a judgement about worth. The test each one passes is
# DERIVATION: the file is produced from something else that is itself listed, so listing it would
# record the same fact twice. An index does not index itself; a rendered `*.html` surface is
# regenerated from state; a `read-first\` copy is the snapshot dispatch took of a file that already
# has its own entry at its own path. An exclusion that cannot answer "derived from what?" is the
# rejected classification creeping back, and does not belong here.
#
# Anything else under data\ that no index lists is drift, and Get-IndexDrift counts it - "this file
# was never indexed" is detectable, where "somebody should have realised this mattered" never was.

Import-Module (Join-Path $PSScriptRoot 'Paths.psm1') -Force

$script:MaxSummary   = 160
$script:IndexHeader  = @(
    '# Index'
    ''
    'One line per durable file, so a later session can find it. A table of contents, never'
    'content: open the file itself for anything longer than its line. Paths are relative to the'
    'installation root, and an entry is exactly one line however long.'
)

function Get-DefaultIndexDataPath {
    Join-Path (Get-KingshandHome) 'data'
}

# The one place a caller's -DataPath becomes an absolute path, so every function below compares
# like with like. It resolves against POWERSHELL's location, not [System.IO.Path]::GetFullPath's,
# because those two disagree: GetFullPath uses the process working directory, which Set-Location
# does not move. A relative `data` then resolved somewhere nobody was looking, Get-ChildItem
# quietly found nothing there, and the drift count came back empty instead of wrong-looking.
#
# It does not require the directory to exist: an index can be written into a data directory that
# is about to be created.
function Resolve-IndexDataPath {
    param([Parameter(Mandatory)][string]$DataPath)

    $p = $DataPath.Trim().Replace('/', '\')
    if (-not [System.IO.Path]::IsPathRooted($p)) { $p = Join-Path $PWD.ProviderPath $p }
    [System.IO.Path]::GetFullPath($p).TrimEnd('\')
}

# The root index holds kingshand's own operational files; a project's index holds that project's.
# The root is a file beside the directory rather than a reserved name inside it, so no project can
# ever collide with it.
function Get-IndexPath {
    [CmdletBinding()]
    param(
        [string]$Project,
        [string]$DataPath = (Get-DefaultIndexDataPath)
    )

    if ([string]::IsNullOrWhiteSpace($Project)) { return (Join-Path $DataPath 'index.md') }
    if ($Project -notmatch '^[A-Za-z0-9._-]+$') {
        throw "Project name '$Project' is not slug-shaped. Use the name it is registered under: letters, digits, '.', '_' and '-'."
    }
    Join-Path $DataPath "index\$Project.md"
}

# Every index that exists: the root one first, then one per project, in name order.
function Get-AllIndexPaths {
    [CmdletBinding()]
    param([string]$DataPath = (Get-DefaultIndexDataPath))

    $paths = [System.Collections.Generic.List[string]]::new()
    $root  = Join-Path $DataPath 'index.md'
    if (Test-Path -LiteralPath $root -PathType Leaf) { $paths.Add($root) }

    $dir = Join-Path $DataPath 'index'
    if (Test-Path -LiteralPath $dir -PathType Container) {
        foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter '*.md' -File | Sort-Object Name)) {
            $paths.Add($f.FullName)
        }
    }
    # Returned WITHOUT the leading-comma idiom, deliberately, and every list function below agrees.
    # That idiom hands the caller the whole array as ONE object, so an `@(...)` at the call site
    # wraps it a second time and `.Count` reports 1 - which is exactly how the first draft of
    # Get-IndexDrift counted three indexed files as one. Call sites wrap in @() instead.
    $paths.ToArray()
}

# Whatever a caller had to hand - an absolute path, or one already relative - reduced to the single
# stored form. The data directory's own leaf is tolerated at the head so `data\x.md` and `x.md`
# both resolve, and a fixture whose data directory is not called `data` still works.
#
# BOTH branches resolve and then check containment, and they refuse the same input the same way.
# The relative branch used to strip leading dots instead, so `..\..\notes.md` came back as
# `data\notes.md` - a wrong answer returned without failing, for a file that was never the
# caller's subject, while the identical file named absolutely threw.
function ConvertTo-IndexRelativePath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$DataPath
    )

    $leaf  = Split-Path $DataPath -Leaf
    $data  = Resolve-IndexDataPath -DataPath $DataPath
    $clean = $Path.Trim().Replace('/', '\')

    $full = if ([System.IO.Path]::IsPathRooted($clean)) {
        [System.IO.Path]::GetFullPath($clean)
    } else {
        $rel = $clean.TrimStart('\')
        if ($rel.StartsWith($leaf + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
            $rel = $rel.Substring($leaf.Length + 1)
        }
        if (-not $rel.Trim()) { throw "An index entry needs a file path. '$Path' names no file under $DataPath." }
        [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($data, $rel))
    }

    if (-not $full.StartsWith($data + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Only files under $DataPath can be indexed. $Path is outside it."
    }
    $leaf + '\' + $full.Substring($data.Length + 1)
}

function ConvertFrom-IndexRelativePath {
    param(
        [Parameter(Mandatory)][string]$Relative,
        [Parameter(Mandatory)][string]$DataPath
    )
    $leaf  = Split-Path $DataPath -Leaf
    $clean = $Relative.Trim().Replace('/', '\')
    if ($clean.StartsWith($leaf + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        $clean = $clean.Substring($leaf.Length + 1)
    }
    Join-Path $DataPath $clean
}

# A table of contents cannot hold a paragraph. Whitespace collapses to one line, and anything over
# the cap is refused rather than truncated, because a silently cut summary is a summary that lies.
function ConvertTo-IndexSummary {
    param([Parameter(Mandatory)][string]$Summary)

    $one = ($Summary -replace '\s+', ' ').Trim()
    if (-not $one) { throw 'An index entry needs a summary saying what the file is, in one line.' }
    if ($one.Length -gt $script:MaxSummary) {
        throw "That summary is $($one.Length) characters and the index allows $($script:MaxSummary). The index is a table of contents, never content - say what the file is in one line and put the rest in the file."
    }
    $one
}

function Read-IndexFile {
    param(
        [Parameter(Mandatory)][string]$IndexPath,
        [Parameter(Mandatory)][string]$DataPath
    )

    $entries = [System.Collections.Generic.List[hashtable]]::new()
    if (-not (Test-Path -LiteralPath $IndexPath -PathType Leaf)) { return $entries.ToArray() }

    $project = ''
    if ((Split-Path $IndexPath -Leaf) -ne 'index.md') {
        $project = [System.IO.Path]::GetFileNameWithoutExtension($IndexPath)
    }

    foreach ($line in @(Get-Content -LiteralPath $IndexPath)) {
        $m = [regex]::Match($line, '^-\s+`(?<path>[^`]+)`\s+-\s+(?<summary>.*)$')
        if (-not $m.Success) { continue }

        $summary = $m.Groups['summary'].Value.Trim()
        $added   = ''
        $am = [regex]::Match($summary, '\s*\(added\s+(?<d>\d{4}-\d{2}-\d{2})\)$')
        if ($am.Success) {
            $added   = $am.Groups['d'].Value
            $summary = $summary.Substring(0, $am.Index).Trim()
        }

        # A hand-edited line naming somewhere outside data\ is one bad line, not a broken index.
        # Skipping it leaves every other entry readable, where throwing would cost the digest its
        # whole INDEX section over a line nobody can act on from the error anyway.
        $relative = $null
        try { $relative = ConvertTo-IndexRelativePath -Path $m.Groups['path'].Value -DataPath $DataPath }
        catch { $relative = $null }
        if (-not $relative) { continue }
        $full = ConvertFrom-IndexRelativePath -Relative $relative -DataPath $DataPath

        $entries.Add(@{
            project  = $project
            path     = $relative
            fullPath = $full
            summary  = $summary
            added    = $added
            exists   = [bool](Test-Path -LiteralPath $full -PathType Leaf)
        })
    }

    $entries.ToArray()
}

# One index read, or every index at once when no project is named and -All is passed.
function Get-IndexEntries {
    [CmdletBinding()]
    param(
        [string]$Project,
        [switch]$All,
        [string]$DataPath = (Get-DefaultIndexDataPath)
    )

    if ($All) {
        $entries = [System.Collections.Generic.List[hashtable]]::new()
        foreach ($p in @(Get-AllIndexPaths -DataPath $DataPath)) {
            foreach ($e in @(Read-IndexFile -IndexPath $p -DataPath $DataPath)) { $entries.Add($e) }
        }
        return $entries.ToArray()
    }

    Read-IndexFile -IndexPath (Get-IndexPath -Project $Project -DataPath $DataPath) -DataPath $DataPath
}

# Records one file. An existing entry for the same path is rewritten in place and keeps the date it
# first entered the index, so re-indexing a file that changed does not make it look new.
function Add-IndexEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Summary,
        [string]$Project,
        [string]$DataPath = (Get-DefaultIndexDataPath)
    )

    $relative  = ConvertTo-IndexRelativePath -Path $Path -DataPath $DataPath
    $one       = ConvertTo-IndexSummary -Summary $Summary
    $indexPath = Get-IndexPath -Project $Project -DataPath $DataPath

    $dir = Split-Path -Parent $indexPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }

    $lines = if (Test-Path -LiteralPath $indexPath -PathType Leaf) {
        @(Get-Content -LiteralPath $indexPath)
    } else {
        @($script:IndexHeader)
    }

    $added   = Get-Date -Format 'yyyy-MM-dd'
    $replace = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $m = [regex]::Match($lines[$i], '^-\s+`(?<path>[^`]+)`\s+-\s+(?<summary>.*)$')
        if (-not $m.Success) { continue }
        $existing = $null
        try { $existing = ConvertTo-IndexRelativePath -Path $m.Groups['path'].Value -DataPath $DataPath }
        catch { $existing = $null }
        if ($existing -ne $relative) { continue }
        $replace = $i
        $am = [regex]::Match($m.Groups['summary'].Value, '\(added\s+(?<d>\d{4}-\d{2}-\d{2})\)\s*$')
        if ($am.Success) { $added = $am.Groups['d'].Value }
        break
    }

    $entryLine = "- ``$relative`` - $one (added $added)"

    if ($replace -ge 0) {
        $lines[$replace] = $entryLine
        Set-Content -Path $indexPath -Encoding utf8 -Value $lines
    } elseif (Test-Path -LiteralPath $indexPath -PathType Leaf) {
        # An index whose last line is unterminated would take this entry onto the end of it, and
        # the reader's regex still matches that joined line as the FIRST entry with the second
        # swallowed into its summary - so the file just added silently becomes drift again, which
        # is the failure this module exists to prevent. Module-written indexes always end in a
        # newline; a hand-edited one need not.
        $existingText = Get-Content -LiteralPath $indexPath -Raw
        if ($existingText -and -not $existingText.EndsWith("`n")) {
            Add-Content -Path $indexPath -Encoding utf8 -Value ''
        }
        Add-Content -Path $indexPath -Encoding utf8 -Value $entryLine
    } else {
        Set-Content -Path $indexPath -Encoding utf8 -Value (@($lines) + @('', $entryLine))
    }

    @{
        project   = if ([string]::IsNullOrWhiteSpace($Project)) { '' } else { $Project }
        indexPath = $indexPath
        path      = $relative
        fullPath  = ConvertFrom-IndexRelativePath -Relative $relative -DataPath $DataPath
        summary   = $one
        added     = $added
    }
}

# Writing and indexing in ONE call, so the two cannot come apart. A rule that says "remember to
# index it afterwards" is the rule that was forgotten last time; this leaves nothing to remember.
function Write-DataFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content,
        [Parameter(Mandatory)][string]$Summary,
        [string]$Project,
        [string]$DataPath = (Get-DefaultIndexDataPath)
    )

    # Validated before a byte is written: a summary the index would refuse must not leave a file
    # on disk that nothing lists.
    $one  = ConvertTo-IndexSummary -Summary $Summary
    $rel  = ConvertTo-IndexRelativePath -Path $Path -DataPath $DataPath
    $full = ConvertFrom-IndexRelativePath -Relative $rel -DataPath $DataPath

    $dir = Split-Path -Parent $full
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    Set-Content -Path $full -Value $Content -Encoding utf8

    Add-IndexEntry -Path $full -Summary $one -Project $Project -DataPath $DataPath
}

# Every durable file under data\, minus the mechanical exclusions at the top of this file. None is
# a judgement about a file's worth: each names a file derived from one the index already covers.
function Get-IndexableFiles {
    [CmdletBinding()]
    param([string]$DataPath = (Get-DefaultIndexDataPath))

    if (-not (Test-Path -LiteralPath $DataPath -PathType Container)) { return @() }

    # Normalised the way ConvertTo-IndexRelativePath normalises, because the two are compared
    # against each other. Get-ChildItem always reports an absolute FullName, so a relative
    # -DataPath left the two exclusions below unable to match anything and every index file came
    # back as drift.
    $DataPath = Resolve-IndexDataPath -DataPath $DataPath
    $indexDir = (Join-Path $DataPath 'index').TrimEnd('\')
    $rootIdx  = Join-Path $DataPath 'index.md'

    $files = foreach ($f in @(Get-ChildItem -LiteralPath $DataPath -File -Recurse -Force -ErrorAction SilentlyContinue)) {
        if ($f.Extension -eq '.html') { continue }
        if ($f.FullName -eq $rootIdx) { continue }
        if ($f.FullName.StartsWith($indexDir + '\', [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        if ((Split-Path $f.FullName -Parent) -match '(^|\\)read-first$') { continue }
        $f.FullName
    }

    @(@($files) | Sort-Object)
}

# What the index covers and what it has lost track of. The count is the point: a file in data\ that
# no index lists is drift, and drift that nothing reports is how the last one went unread.
function Get-IndexDrift {
    [CmdletBinding()]
    param([string]$DataPath = (Get-DefaultIndexDataPath))

    $indexes = @(Get-AllIndexPaths -DataPath $DataPath)
    $entries = @(Get-IndexEntries -All -DataPath $DataPath)

    $listed = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($e in $entries) { $null = $listed.Add($e.path) }

    $unindexed = [System.Collections.Generic.List[string]]::new()
    foreach ($full in @(Get-IndexableFiles -DataPath $DataPath)) {
        $rel = ConvertTo-IndexRelativePath -Path $full -DataPath $DataPath
        if (-not $listed.Contains($rel)) { $unindexed.Add($rel) }
    }

    # An entry whose file is gone is the other half of the same drift, and it is not the same fact.
    $missing = @(@($entries | Where-Object { -not $_.exists }) | ForEach-Object { $_.path })

    @{
        indexes   = @($indexes)
        indexed   = $listed.Count
        unindexed = @($unindexed.ToArray())
        missing   = @($missing)
    }
}

Export-ModuleMember -Function Get-IndexPath, Get-AllIndexPaths, Get-IndexEntries, Add-IndexEntry,
                              Write-DataFile, Get-IndexableFiles, Get-IndexDrift,
                              Get-DefaultIndexDataPath
