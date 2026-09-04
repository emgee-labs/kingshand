#Requires -Version 7.0
Set-StrictMode -Version Latest

# Project registry: the Hand's STANDING delivery posture per project.
#
# This answers "what posture did the Hand register", never "how does this task ship".
# A task's mode is resolved at intake and passed explicitly to the brief and the dispatch.
#
# Entry format (data\projects.md), byte-compatible with firstmate's line plus a path line:
#   - <name> [<mode> +yolo +merge] - <desc> (added <date>)
#         path: <absolute path>
#
# `+merge` is the per-repository permission to merge that project's own green pull requests on the
# forge, reported as the string 'on' or 'off' on the entry's `merge` key. It is NOT a mode and not
# a fourth posture: the mode decides how work ships, `yolo` decides whether the Hand asks first,
# and this decides one thing only. `muster` Step 7 owns what it permits; this module only reports
# what was declared.
#
# It is off unless the token is there, and every way of failing to read it leaves it off. An
# unknown token warns and changes nothing, an unknown mode resets the whole annotation, and an
# unreadable registry throws out of Get-ProjectEntry rather than returning a value at all - so a
# caller never receives 'off' as a substitute for "could not tell", and never receives 'on' by
# accident.
#
# All strictness lives in Get-ProjectEntry. Get-ProjectPosture inherits it by calling through.
# Get-AllProjects is the sole lenient function: it is a listing and validates nothing.

$script:ValidModes = @('no-mistakes', 'direct-PR', 'local-only', 'no-mistakes-prod-only')

# For the project-name shape only. The index owns that rule because the name becomes a file name
# there, and this module asks rather than keeping a second copy of the pattern: two copies of one
# validation drift the moment either is edited, and a registry that accepted more than the index
# could resolve let a project register and then fail every index write it was ever named in.
#
# NOT -Force - a module never forces a nested import. The rule and the failure it prevents are in
# the `statute` skill's style rules; tests\Projects.Tests.ps1 pins this edge.
Import-Module (Join-Path $PSScriptRoot 'Index.psm1')

function Get-DefaultRegistryPath {
    Join-Path (Split-Path $PSScriptRoot -Parent) 'data\projects.md'
}

# Parses the file into entries. Never touches the filesystem beyond reading the registry.
function Read-Registry {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RegistryPath)

    if (-not (Test-Path $RegistryPath)) {
        throw "No project registry at $RegistryPath. Import a project before dispatching."
    }

    $lines = @(Get-Content -Path $RegistryPath)
    $entries = [System.Collections.Generic.List[hashtable]]::new()

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $m = [regex]::Match($lines[$i], '^-\s+(?<name>\S+)(?:\s+\[(?<ann>[^\]]*)\])?\s+-\s+(?<desc>.*)$')
        if (-not $m.Success) { continue }

        $name  = $m.Groups['name'].Value
        $desc  = $m.Groups['desc'].Value.Trim()
        $mode  = 'no-mistakes'
        $yolo  = 'off'
        $merge = 'off'

        $ann = $m.Groups['ann'].Value.Trim()
        if ($ann) {
            $modeSeen = $false
            foreach ($tok in ($ann -split '\s+' | Where-Object { $_ })) {
                if ($tok.StartsWith('+')) {
                    if ($tok -eq '+yolo') {
                        $yolo = 'on'
                    } elseif ($tok -eq '+merge') {
                        $merge = 'on'
                    } else {
                        Write-Warning ("Unknown autonomy token '$tok' for $name; " +
                                       'leaving yolo and merge off.')
                    }
                } elseif (-not $modeSeen) {
                    $modeSeen = $true
                    if ($script:ValidModes -contains $tok) {
                        $mode = $tok
                    } else {
                        # A typo can only ever make a project stricter, never looser. Everything
                        # the annotation granted is dropped with it, merge included - a line this
                        # function could not read in full is not a line to take a permission from.
                        Write-Warning ("Unknown mode '$tok' for $name; defaulting to " +
                                       'no-mistakes off, merge off.')
                        $mode  = 'no-mistakes'
                        $yolo  = 'off'
                        $merge = 'off'
                        break
                    }
                }
            }
        }

        $added = ''
        $am = [regex]::Match($desc, '\(added\s+(?<d>\d{4}-\d{2}-\d{2})')
        if ($am.Success) { $added = $am.Groups['d'].Value }

        # The path lives on the next non-empty line, indented.
        $path = $null
        for ($j = $i + 1; $j -lt $lines.Count; $j++) {
            if (-not $lines[$j].Trim()) { continue }
            $pm = [regex]::Match($lines[$j], '^\s+path:\s*(?<p>.+?)\s*$')
            if ($pm.Success) { $path = $pm.Groups['p'].Value }
            break
        }

        # rawMode preserves the registered annotation; mode maps the conditional policy to its
        # most rigorous leg so mechanical callers treat it as the pipeline project it is.
        $rawMode = $mode
        if ($mode -eq 'no-mistakes-prod-only') { $mode = 'no-mistakes' }

        # The registry is maintained by hand as well as by /annex, so a name Add-ProjectEntry would
        # refuse can still arrive by hand - and every durable file written for that project is
        # indexed at data\index\<name>.md, so it fails one brief at a time, always after the brief
        # is on disk. Flagged and warned rather than refused: this function is read on every session
        # start, and an exception here would take the whole digest down over one bad line, while
        # dropping the entry would hide a project the user did register.
        $indexable = Test-IndexProjectName -Project $name
        if (-not $indexable) {
            Write-Warning ("Project name '$name' cannot be indexed: it becomes the file name " +
                           "data\index\$name.md, which allows only $(Get-IndexProjectNameRule). " +
                           "Rename it in $RegistryPath - '$(ConvertTo-IndexProjectName -Project $name)' " +
                           "would work - or nothing written for it can be listed.")
        }

        $entries.Add(@{
            name        = $name
            path        = $path
            mode        = $mode
            rawMode     = $rawMode
            yolo        = $yolo
            merge       = $merge
            description = $desc
            added       = $added
            indexable   = $indexable
        })
    }

    , $entries.ToArray()
}

function Get-AllProjects {
    [CmdletBinding()]
    param([string]$RegistryPath = (Get-DefaultRegistryPath))
    # Read-Registry already returns via the leading-comma idiom, so its output is a single
    # pipeline object holding the intact array. Re-wrapping with `, @(...)` here would nest it
    # a second time and corrupt .Count for callers - pass it through unchanged instead.
    Read-Registry -RegistryPath $RegistryPath
}

function Get-ProjectEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$RegistryPath = (Get-DefaultRegistryPath)
    )

    # Read-Registry returns via the leading-comma idiom - the whole array as one pipeline
    # object. Wrapping it in @(...) here would only re-confirm it is a single-element array
    # whose one element is that array, so a plain loop is used instead of a pipeline filter.
    $allEntries = Read-Registry -RegistryPath $RegistryPath
    $entry = $null
    foreach ($candidate in $allEntries) {
        if ($candidate.name -eq $Name) {
            $entry = $candidate
            break
        }
    }
    if (-not $entry) {
        throw "Project '$Name' is not registered. Import it before dispatching; posture is never inferred."
    }
    if (-not $entry.path) {
        throw "Project '$Name' has a missing or malformed 'path:' line in $RegistryPath."
    }
    if (-not (Test-Path $entry.path)) {
        throw "Project '$Name' records a path that does not exist on disk: $($entry.path)"
    }
    $entry
}

# The posture string is the mode and yolo, and deliberately not merge: merge is not a posture and
# folding it in here would make it look like one. Read it off Get-ProjectEntry's `merge` key.
function Get-ProjectPosture {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [switch]$Raw,
        [string]$RegistryPath = (Get-DefaultRegistryPath)
    )
    $e = Get-ProjectEntry -Name $Name -RegistryPath $RegistryPath
    $mode = if ($Raw) { $e.rawMode } else { $e.mode }
    "$mode $($e.yolo)"
}

# Comparing paths as raw strings would let "C:\x" and "C:\x\" register twice.
function Get-NormalisedPath {
    param([string]$Path)
    if (-not $Path) { return '' }
    [System.IO.Path]::TrimEndingDirectorySeparator($Path.Trim()).ToLowerInvariant()
}

function Add-ProjectEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Mode,
        [Parameter(Mandatory)][string]$Description,
        [switch]$Yolo,
        [switch]$Merge,
        [string]$RegistryPath = (Get-DefaultRegistryPath)
    )

    if ($script:ValidModes -notcontains $Mode) {
        throw "Invalid mode '$Mode'. Must be one of: $($script:ValidModes -join ', ')"
    }

    # Refused where the name is chosen, not later where it is used. Every durable file written for a
    # project is indexed under data\index\<name>.md, so a name the index cannot turn into a file name
    # is a project nothing can ever index - and the failure would land one brief at a time, after
    # each one was already on disk.
    if (-not (Test-IndexProjectName -Project $Name)) {
        throw ("Project name '$Name' cannot be registered: it becomes the file name of this " +
               "project's index at data\index\$Name.md. Use a name of $(Get-IndexProjectNameRule) - " +
               "for example '$(ConvertTo-IndexProjectName -Project $Name)'.")
    }

    if (Test-Path $RegistryPath) {
        # Read-Registry returns via the leading-comma idiom - the whole array as one pipeline
        # object. A plain loop is used instead of a pipeline filter, matching Get-ProjectEntry.
        $existing = Read-Registry -RegistryPath $RegistryPath
        $norm = Get-NormalisedPath $Path
        foreach ($candidate in $existing) {
            if ($candidate.name -eq $Name) {
                throw "Project '$Name' is already registered in $RegistryPath."
            }
            if ((Get-NormalisedPath $candidate.path) -eq $norm) {
                throw "Project '$($candidate.name)' is already registered at the same path: $Path"
            }
        }
    } else {
        $dir = Split-Path -Parent $RegistryPath
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        Set-Content -Path $RegistryPath -Value "# Projects" -Encoding utf8
    }

    # Built from the tokens that were actually asked for, so an entry written without -Merge is
    # byte-identical to what this function has always written and the permission is absent rather
    # than present-and-off. There is no "+merge off" spelling: absence is the off state.
    $tokens = @($Mode)
    if ($Yolo)  { $tokens += '+yolo' }
    if ($Merge) { $tokens += '+merge' }
    $ann   = '[' + ($tokens -join ' ') + ']'
    $added = Get-Date -Format 'yyyy-MM-dd'

    # This function stamps the date itself, so a caller that also wrote one produced
    # "... (added 2026-08-25) (added 2026-08-25)". Strip a trailing stamp defensively.
    # Anchored to the END only: an `(added ...)` mid-description is posture-change history
    # ("(added 2026-08-24; raised from direct-PR 2026-09-02)") and must survive untouched.
    $desc = ($Description -replace '\s*\(added\s+\d{4}-\d{2}-\d{2}\)\s*$', '').Trim()

    # Append only. Existing entries are never rewritten, so hand edits and posture-change
    # history in descriptions survive untouched.
    Add-Content -Path $RegistryPath -Encoding utf8 -Value @(
        ""
        "- $Name $ann - $desc (added $added)"
        "      path: $Path"
    )
}

# Filesystem and git preflight for an import. Lives here rather than in the skill's prose so it
# can be tested against throwaway repositories. Returns a result rather than throwing, because
# the caller reports the reason to the user verbatim - an invalid mode is a $false result with a
# reason, never an exception.
#
# $LASTEXITCODE is global, not function-scoped, so the git probes below would otherwise leak
# their exit status to the caller. `git remote get-url origin` exits 2 on a repository with no
# origin, which is the expected, correct outcome for a local-only project - a caller that checks
# $LASTEXITCODE after this function would misread that probe as a failed preflight. Each probe's
# status is captured into a local immediately, and the finally block restores the observable
# $LASTEXITCODE to 0 on every return path, because returning normally is this function's success.
function Test-ProjectImportable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Mode
    )

    $result = @{ ok = $false; reason = ''; hasOrigin = $false }

    try {
        # Checked before anything else: an unrecognised mode is refused outright rather than
        # falling through the push-capable test and being accepted as though it were local-only.
        if ($script:ValidModes -notcontains $Mode) {
            $result.reason = "Invalid mode '$Mode'. Must be one of: $($script:ValidModes -join ', ')"
            return $result
        }

        if (-not (Test-Path $Path)) {
            $result.reason = "Path does not exist: $Path"
            return $result
        }

        $inside     = & git -C $Path rev-parse --is-inside-work-tree 2>$null
        $insideCode = $LASTEXITCODE
        if ($insideCode -ne 0 -or $inside -ne 'true') {
            $result.reason = "Not a git repository: $Path"
            return $result
        }

        $null       = & git -C $Path remote get-url origin 2>$null
        $originCode = $LASTEXITCODE
        $result.hasOrigin = ($originCode -eq 0)

        # The subset of valid modes that must be able to push. local-only is deliberately absent.
        $pushCapable = @('no-mistakes', 'direct-PR', 'no-mistakes-prod-only')
        if (($pushCapable -contains $Mode) -and -not $result.hasOrigin) {
            $result.reason = "$Mode requires an origin remote and this repository has none."
            return $result
        }

        $result.ok = $true
        $result
    } finally {
        # Only this function's own probes are cleared. Anything the caller runs after this point
        # sets $LASTEXITCODE itself, so genuine downstream failures are still visible.
        $global:LASTEXITCODE = 0
    }
}

Export-ModuleMember -Function Get-ProjectEntry, Get-ProjectPosture, Get-AllProjects,
                              Get-DefaultRegistryPath, Add-ProjectEntry, Test-ProjectImportable
