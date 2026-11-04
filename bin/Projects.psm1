#Requires -Version 7.0
Set-StrictMode -Version Latest

# Project registry: the Hand's STANDING delivery posture per project.
#
# This answers "what posture did the Hand register", never "how does this task ship".
# A task's mode is resolved at intake and passed explicitly to the brief and the dispatch.
#
# Entry format (data\projects.md), byte-compatible with firstmate's line plus a path line:
#   - <name> [<mode> +yolo +merge +watch-merge +family:<family>] - <desc> (added <date>)
#         path: <absolute path>
#
# `+merge` is the per-repository permission to merge that project's own green pull requests on the
# forge, reported as the string 'on' or 'off' on the entry's `merge` key. It is NOT a mode and not
# a posture of its own: the mode decides how work ships, `yolo` decides whether the Hand asks first,
# and this decides one thing only. `muster` Step 7 owns what it permits; this module only reports
# what was declared.
#
# It is off unless the token is there, and an annotation this parser could not read in full never
# yields it whatever else that line says. An unrecognised token of either shape - a `+something`
# it does not know, or a bare word after the mode - warns and forces merge off for that entry; an
# unknown mode resets the whole annotation; and an unreadable registry throws out of
# Get-ProjectEntry rather than returning a value at all, so a caller never receives 'off' as a
# substitute for "could not tell", and never receives 'on' by accident.
#
# `+watch-merge` is night's watch's own permission to merge that project's green pull requests
# while the King is away, reported as 'on' or 'off' on the entry's `watchMerge` key. It is
# INDEPENDENT of `+merge`: neither implies the other, and `+merge` alone grants night's watch
# nothing. It is read exactly as strictly as `+merge` - off unless the token is there, and forced
# off by every failure that forces `+merge` off. `muster` Step 7 owns what it permits.
#
# `+family:<name>` names the family of projects this one belongs to, reported on the entry's
# `family` key. A family is a set of repositories that share conventions, and its shared rules live
# in one file, data\families\<name>.md, which bin\Dispatch-Worker.ps1 attaches to every brief for
# every project in the family beside that project's own. Its own directory, so a family name and a
# project name can never be the same file. `annex` owns what goes in the file; this module only
# reports which family was declared.
#
# NO FAMILY IS THE ORDINARY STATE and it is reported as the EMPTY STRING, never as a word. The key
# is always present, so a caller reads it without testing for it, and the empty string is the one
# value that cannot be composed into a file name to go looking for - where a state word like 'none'
# would name data\families\none.md, which somebody could perfectly well have written.
#
# The name after the colon becomes that file name, so it is held to the same shape a project name
# is, asked of Index.psm1 for the reason the import below gives. A token of any other shape - no
# colon, an empty name, a name with a separator or a traversal in it - is unrecognised, and so is a
# second `+family:` naming a different family, because one project belongs to one family and a line
# declaring two is a line this parser could not read unambiguously. The same family declared twice
# is read as the one family it names.
#
# Merge, watch-merge and family are the strict ones, deliberately: mode and yolo keep their existing
# leniency, because an unrecognised token has never changed either and this is not the change that
# makes it. An annotation this parser could not read in full yields neither permission nor the
# family, and an unknown mode drops all three with everything else the annotation granted.
#
# All strictness lives in Get-ProjectEntry. Get-ProjectPosture inherits it by calling through.
# Get-AllProjects is the sole lenient function: it is a listing and validates nothing.

# `review-only` is the one posture that delivers nothing: its work is reviewed and reported, and
# nothing is committed to land, pushed, or raised anywhere. `annex` owns what each mode means and
# `muster` owns how each one routes; this module only accepts the names.
$script:ValidModes = @('no-mistakes', 'direct-PR', 'local-only', 'no-mistakes-prod-only', 'review-only')

# The modes that must be able to push. local-only and review-only are deliberately absent: neither
# ever pushes, so neither needs an origin remote, and neither has a pull request to merge.
$script:PushCapableModes = @('no-mistakes', 'direct-PR', 'no-mistakes-prod-only')

# For the shape of a name that becomes a file name - a project name, and the family name after
# `+family:`. The index owns that rule because a project name becomes a file name there, and this
# module asks rather than keeping a second copy of the pattern: two copies of one validation drift
# the moment either is edited, and a registry that accepted more than the index could resolve let a
# project register and then fail every index write it was ever named in. A family name is the same
# question one step along - it becomes data\families\<name>.md - so it is asked of the same owner.
#
# NOT -Force - a module never forces a nested import. The rule and the failure it prevents are in
# the `statute` skill's style rules; tests\Projects.Tests.ps1 pins this edge.
Import-Module (Join-Path $PSScriptRoot 'Index.psm1')

# Every mode the registry accepts, one per pipeline object, in the order the error messages list
# them. A copy, so a caller cannot change what this module accepts by editing what it was handed.
function Get-ProjectModes {
    [CmdletBinding()]
    param()
    $script:ValidModes.Clone()
}

function Get-DefaultRegistryPath {
    Join-Path (Split-Path $PSScriptRoot -Parent) 'data' 'projects.md'
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

        $name   = $m.Groups['name'].Value
        $desc   = $m.Groups['desc'].Value.Trim()
        $mode   = 'no-mistakes'
        $yolo   = 'off'
        $merge  = 'off'
        $watchMerge = 'off'
        $family = ''

        $ann = $m.Groups['ann'].Value.Trim()
        if ($ann) {
            $modeSeen = $false

            # Whether every token in this annotation was recognised. A false here forces merge off
            # and the family away after the loop, and after is the only place it can be done:
            # forcing it inside would be undone by a later `+merge` or `+family:`, so
            # `[no-mistakes garbage +merge]` would still grant the permission from a line this
            # parser demonstrably could not read in full.
            $annReadInFull = $true

            foreach ($tok in ($ann -split '\s+' | Where-Object { $_ })) {
                if ($tok.StartsWith('+')) {
                    if ($tok -eq '+yolo') {
                        $yolo = 'on'
                    } elseif ($tok -eq '+merge') {
                        $merge = 'on'
                    } elseif ($tok -eq '+watch-merge') {
                        $watchMerge = 'on'
                    } elseif ($tok.StartsWith('+family:')) {
                        # Two questions, both fatal to the token and neither to the mode: whether
                        # the name can be a file name at all, and whether this entry already
                        # declared a different family. A project belongs to one family, so a line
                        # naming two has not said which, and guessing would hand a worker the wrong
                        # repositories' conventions with nothing to show it had happened.
                        $declared = $tok.Substring('+family:'.Length)
                        if (-not (Test-IndexProjectName -Project $declared)) {
                            # ${name} rather than $name, because a colon straight after a variable
                            # name is PowerShell's scope qualifier - "$name:" is a parse error, not
                            # the sentence it looks like.
                            Write-Warning ("Unusable family token '$tok' for ${name}: the name after " +
                                           "'+family:' becomes the file name data\families\$declared.md, " +
                                           "which allows only $(Get-IndexProjectNameRule). It declares " +
                                           'no family, and merge is forced off for this entry.')
                            $annReadInFull = $false
                        } elseif ($family -and $family -ne $declared) {
                            Write-Warning ("$name declares two families, '$family' and '$declared'. " +
                                           'A project belongs to one, so neither is taken, no family ' +
                                           'rules file is attached, and merge is forced off for this ' +
                                           'entry. Leave one `+family:` token on the line.')
                            $annReadInFull = $false
                        } else {
                            $family = $declared
                        }
                    } else {
                        # Says what was ignored and what that costs, never what state resulted.
                        # An earlier wording claimed it left yolo and merge off when it changed
                        # neither, which read as a lost permission on an entry that still had one.
                        Write-Warning ("Unrecognised token '$tok' for $name; it grants nothing, " +
                                       'and merge is forced off for this entry, along with any ' +
                                       'family declared on the same line.')
                        $annReadInFull = $false
                    }
                } elseif (-not $modeSeen) {
                    $modeSeen = $true
                    if ($script:ValidModes -contains $tok) {
                        $mode = $tok
                    } else {
                        # A typo can only ever make a project stricter, never looser. Everything
                        # the annotation granted is dropped with it, merge and the family included -
                        # a line this function could not read in full is not a line to take a
                        # permission from, nor one to take a set of shared conventions from.
                        Write-Warning ("Unknown mode '$tok' for $name; defaulting to " +
                                       'no-mistakes off, merge off, no family.')
                        $mode   = 'no-mistakes'
                        $yolo   = 'off'
                        $merge  = 'off'
                        $watchMerge = 'off'
                        $family = ''
                        break
                    }
                } else {
                    # A bare token after the mode used to fall through both branches in silence,
                    # so the annotation was partly unread and nothing said so.
                    Write-Warning ("Unrecognised token '$tok' for $name; it grants nothing, " +
                                   'and merge is forced off for this entry, along with any ' +
                                   'family declared on the same line.')
                    $annReadInFull = $false
                }
            }

            if (-not $annReadInFull) { $merge = 'off'; $watchMerge = 'off'; $family = '' }
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
            watchMerge  = $watchMerge
            # Always present, and the empty string where no family is declared - the header owns
            # why that rather than a word.
            family      = $family
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

# The posture string is the mode and yolo, and deliberately neither merge nor the family: neither
# is a posture and folding either in here would make it look like one. Read them off
# Get-ProjectEntry's `merge` and `family` keys.
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
        # Night's watch's own merge permission, independent of -Merge. Off for every caller that
        # does not pass it, which is the default the token takes.
        [switch]$WatchMerge,
        # The family this project belongs to, or nothing. EMPTY IS THE ORDINARY CASE and the default
        # every import takes unless the user names a family: most projects share conventions with no
        # other repository, so the entry is written exactly as it always was and no token appears.
        [string]$Family = '',
        [string]$RegistryPath = (Get-DefaultRegistryPath)
    )

    if ($script:ValidModes -notcontains $Mode) {
        throw "Invalid mode '$Mode'. Must be one of: $($script:ValidModes -join ', ')"
    }

    # Refused at the one place the token is written, rather than left inert in the brackets. A
    # local-only or review-only entry never reaches Step 8a, so `[local-only +merge]` grants nothing
    # today - but a posture is raised by hand-editing that same annotation, and the moment the mode
    # becomes push-capable a permission nobody re-considered is live forge merge authority.
    $pushCapable = $script:PushCapableModes -contains $Mode
    if ($Merge -and -not $pushCapable) {
        throw ("Cannot register '$Name' as $Mode with -Merge: a $Mode project never " +
               'pushes, so it has no forge and no pull request to merge. Register it with a ' +
               'push-capable mode, or register it without -Merge.')
    }
    if ($WatchMerge -and -not $pushCapable) {
        throw ("Cannot register '$Name' as $Mode with -WatchMerge: a $Mode project never " +
               'pushes, so it has no pull request for night''s watch to merge. Register it with a ' +
               'push-capable mode, or register it without -WatchMerge.')
    }

    # Refused where the family is chosen, for the reason the project name below is: the name becomes
    # the file name of the family's shared rules, so a name that cannot be one registers a project
    # whose family file nothing can ever write or attach - and the parser would then drop the token
    # on every read, one dispatch at a time, with only a warning to show for it.
    $familyName = $Family.Trim()
    if ($familyName -and -not (Test-IndexProjectName -Project $familyName)) {
        throw ("Family name '$familyName' cannot be registered: it becomes the file name of the " +
               "family's shared rules at data\families\$familyName.md. Use a name of " +
               "$(Get-IndexProjectNameRule) - for example " +
               "'$(ConvertTo-IndexProjectName -Project $familyName)'.")
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

    # Built from the tokens that were actually asked for, so an entry written without -Merge and
    # without -Family is byte-identical to what this function has always written and the permission
    # is absent rather than present-and-off. There is no "+merge off" spelling and no "+family:none"
    # spelling: absence is the off state and the no-family state.
    $tokens = @($Mode)
    if ($Yolo)       { $tokens += '+yolo' }
    if ($Merge)      { $tokens += '+merge' }
    if ($WatchMerge) { $tokens += '+watch-merge' }
    if ($familyName) { $tokens += "+family:$familyName" }
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

        if (($script:PushCapableModes -contains $Mode) -and -not $result.hasOrigin) {
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

# The files a repository documents its own conventions in, for `annex` to offer as the source of a
# seed for data\done-<name>.md. A CLOSED list of names, matched by git as pathspecs against tracked
# files, so nothing here reads, scans or interprets what any file says - the Hand quotes the files
# for the King and he decides every line. Only tracked files count: an untracked file is nobody's
# convention yet. Lint and format configuration is looked for at the root only, because a deeper
# match is as likely a vendored package's own config as the project's.
$script:ConventionPathspecs = [ordered]@{
    'contributing' = @(':(glob,icase)CONTRIBUTING*', ':(glob,icase).github/CONTRIBUTING*',
                       ':(glob,icase)docs/CONTRIBUTING*')
    'codeowners'   = @(':(glob)CODEOWNERS', ':(glob).github/CODEOWNERS', ':(glob)docs/CODEOWNERS')
    'instructions' = @(':(glob)**/AGENTS.md', ':(glob)**/CLAUDE.md')
    'conventions'  = @(':(glob,icase)docs/**/*convention*', ':(glob,icase)**/STYLEGUIDE*',
                       ':(glob,icase)**/*style-guide*')
    'lint-format'  = @(':(glob).editorconfig', ':(glob).eslintrc*', ':(glob)eslint.config.*',
                       ':(glob).prettierrc*', ':(glob)prettier.config.*', ':(glob).stylelintrc*',
                       ':(glob).markdownlint*', ':(glob)ruff.toml', ':(glob).rubocop.yml',
                       ':(glob).golangci.*', ':(glob)rustfmt.toml', ':(glob).clang-format',
                       ':(glob)PSScriptAnalyzerSettings.psd1')
}

# Lists the tracked convention files in one repository: one pipeline object per file, with `kind` (a
# key of the list above) and `path` (repository-relative, forward slashes), sorted by kind then
# path - wrap the call in @() to count them. No output means the repository documents none of them. A repository that cannot be listed
# THROWS, naming why, because an empty list there would read as "documents nothing" when the truth
# is "could not tell".
function Find-ProjectConventionFiles {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "Cannot list convention files: the path does not exist: $Path"
    }

    $found = [System.Collections.Generic.List[pscustomobject]]::new()
    $seen  = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    try {
        foreach ($kind in $script:ConventionPathspecs.Keys) {
            # -z, so a path holding a space or a non-ASCII character arrives as itself rather than
            # in git's quoted form.
            $raw  = & git -C $Path ls-files -z -- @($script:ConventionPathspecs[$kind]) 2>$null
            $code = $LASTEXITCODE
            if ($code -ne 0) {
                throw "Cannot list convention files: git ls-files exited $code in $Path - is it a git repository?"
            }
            $paths = @("$raw" -split "`0" | Where-Object { $_ } | Sort-Object)
            foreach ($p in $paths) {
                # One file is listed once, under the first kind that named it.
                if ($seen.Add($p)) { $found.Add([pscustomobject]@{ kind = $kind; path = $p }) }
            }
        }
    } finally {
        $global:LASTEXITCODE = 0
    }

    $found.ToArray()
}

# Writes the seed of one project's standing criteria, data\done-<Name>.md, and indexes it, in one
# call. The content is what the King approved, one line per criterion, written one per line -
# nothing here composes or checks it. `muster` owns the file's form and grows it from then on.
#
# THE ONE CONSTRAINT ON THE PATH: it is always data\done-<Name>.md, and that file must not already
# exist. A seed is only ever the first content of the file; once one exists, muster's close-out owns
# every later line, so a seed written over it would silently delete criteria earned from findings.
# The name is held to the index's file-name rule by Write-DataFile before anything is written.
function New-ProjectCriteriaSeed {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowEmptyString()][AllowEmptyCollection()][string[]]$Content,
        # The registry's own directory, which is where annex's call writes - it passes no -DataPath.
        [string]$DataPath = (Split-Path -Parent (Get-DefaultRegistryPath))
    )

    $text = ($Content -join "`n").Trim()
    if (-not $text) {
        throw ("Nothing approved for $Name, so no criteria file was written. A declined seed " +
               'writes nothing - absence is the ordinary state.')
    }
    if (-not (Test-IndexProjectName -Project $Name)) {
        throw ("Project name '$Name' cannot name a criteria file: it allows only " +
               "$(Get-IndexProjectNameRule).")
    }
    $target = Join-Path $DataPath "done-$Name.md"
    if (Test-Path -LiteralPath $target) {
        throw ("$target already exists, so no seed was written. A seed is only ever a project's " +
               'first criteria; an existing file is grown by muster, never replaced.')
    }

    Write-DataFile -Project $Name -Path $target -Content $text -DataPath $DataPath `
        -Summary "standing criteria for ${Name}: seeded at import from its own convention files"
}

Export-ModuleMember -Function Get-ProjectEntry, Get-ProjectPosture, Get-AllProjects,
                              Get-DefaultRegistryPath, Add-ProjectEntry, Test-ProjectImportable,
                              Get-ProjectModes, Find-ProjectConventionFiles, New-ProjectCriteriaSeed
