#Requires -Version 7.0
Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'Paths.psm1')

# What a `no-mistakes` gate run is actually doing, read once, in one place, from the fields that
# say so.
#
# THE FAILURE THIS EXISTS TO PREVENT. Nothing in `bin\` read this output before, so every session
# invented its own parse of `no-mistakes axi status` by eye, and the eye was wrong every time it
# was measured. On 2026-09-10 one run's state was reported wrongly three times in a single session:
# a pull request called open when nothing had been pushed, the run called parked when it was
# mid-fix, then parked again when the review step had already completed. On 2026-09-24/25 the same
# session hand-wrote four different watch conditions over the same output - two fired falsely, one
# of them by matching `outcome:` inside the tool's own help text and one by reading a park that had
# been there before a steer was sent as the answer to that steer, and a third was keyed on the
# branch head moving, which a park does not do, so it missed a parked run for two hours and
# twenty-six minutes.
#
# One cause runs through all of it: state inferred from something next to the state instead of read
# from the field that states it.
#
# SO THIS READER INFERS NOTHING, and that is the whole product rather than a quality of it.
#
# - A finding count is never converted into "something is waiting". `run.findings` is a RESIDUAL
#   SUMMARY STRING that persists after findings have been declined - a real cancelled run on this
#   repository still reads `findings: "1 awaiting, 1 auto-fix"` with every step terminal and nothing
#   waiting on anybody. It is carried through as `findingsSummary`, and nothing computes from it.
# - Whether a run is parked comes from `awaiting_agent` and from a `gate:` object, which are the two
#   places the tool states it, and from nowhere else. Not from a count, not from a step's status,
#   not from how long something has been running.
# - A value the output does not carry is absent, never defaulted. Absence is a fact about the
#   output and is reported as one. A value it does carry but this reader does not recognise is
#   reported as unrecognised, and never quietly folded into whichever state word it resembles.
# - ABSENT AND UNRECOGNISED ARE DIFFERENT FACTS, and NO READ THAT DECIDES OR REPORTS ANYTHING
#   BYPASSES THE PRIMITIVE. Every key goes through `Read-ToonField`, `Read-ToonList`,
#   `Read-ToonTable` or `Read-ToonCells`, which answer three ways - absent, taken, or present in
#   a shape this cannot take - and every one of the third kind is named on the state's
#   `notUnderstood` list and in `detail`. Testing a value instead is one mistake, not seven, and
#   it was made here seven times across five rounds in seven different places before the rule was
#   stated this way: each fix was correct, each one held, and the next field did it again. That
#   is the argument for the rule rather than for the fixes.
#
#   `Get-ToonText`, `Get-ToonNumber` and `Get-ToonRows` still do the taking, but nothing above
#   calls them to decide anything any more - they are reached through the four readers, which is
#   what keeps "present but not understood" from collapsing back into "absent".
# - `steps[]` and `active_steps[]` stay two separate lists. Flattening them - which is what
#   `Select-Object -Unique` over a step regex did - produces a composite that reads like a step list
#   and is not one.
#
# WHERE THE OUTPUT CANNOT BE READ, THERE IS NO STATE. Three statuses and the third is the point,
# the shape Ci.psm1 and Usage.psm1 already use here: `has-run` and `no-run` are answers,
# `unreadable` is the refusal to guess. Nothing below ever turns a failed read into a state word or
# into an empty run, because a reader that guessed is the reason this whole class of bug exists.
#
# HOW THE FORMAT IS READ, WHICH IS STANDING CRITERION 12 AND WAS SETTLED BEFORE ANY OF THIS WAS
# WRITTEN. `no-mistakes axi status` has no JSON mode - `--help` offers only `--run` - and prints
# TOON. TOON is not an open-ended text format: it has a published grammar and a reference
# implementation. But its input set does not close here either, because a review finding's
# `description` is free text somebody's reviewer wrote, and TOON quotes it with its own backslash
# escape set rather than CSV's doubled quote - so it cannot be handed to `ConvertFrom-Csv` and it
# cannot be split by hand without reimplementing that escape set. Hand-rolling the rest of the
# grammar around it is the criterion 12 failure outright.
#
# So the format is decoded by the reference implementation and nothing here reads TOON at all.
# `bin\assets\toon\` holds @toon-format/toon vendored verbatim with its MIT licence, and
# `decode.mjs` beside it turns one document into JSON. Everything below reads only that JSON, which
# is the same boundary Usage.psm1 keeps to `quota-axi`'s JSON and Ci.psm1 keeps to `gh`. Node is
# already a hard prerequisite of this installation - install.ps1 installs it for `lavish-axi` and
# `tasks-axi` - so this adds a file, not a class of dependency.
#
# The decoder runs in strict mode, which is its own default and is left on deliberately: it
# enforces the row and item counts each table declares, so a truncated capture raises an error
# instead of arriving here as a short table that looks complete.
#
# WHAT THIS DOES NOT DO. It does not wait, poll, or notice a change - being woken when a run moves
# is a separate problem and building it on top of a reader is the only order that works. It does
# not drive a run: no flag that responds, approves, aborts or starts anything is ever passed from
# here, and the arguments come from this module rather than from a caller's input.
#
# THE EXPORTS ARE WHAT MAKE THAT LAST CLAIM TRUE, rather than the code merely happening to keep
# it. `Invoke-NoMistakesAxi` takes free-form arguments and would run `axi respond --action approve`
# as readily as `axi status`, so it is deliberately not exported: this module's job is reading, and
# that helper is only how it reads. Unexported, the no-drive claim holds for everything a caller
# can reach rather than for the one path this module happens to take. A stated safety property the
# exports do not enforce is worse than claiming nothing at all, because the claim is what a reader
# trusts instead of checking.

# How long the gate binary may take to answer before it is given up on. `axi status` asks a local
# daemon and returns in well under a second, so this is a guard against a wedged daemon rather than
# a budget for slow work - and a read that hangs is worse than one that fails, because the caller
# is usually a session that is watching something else.
$script:DefaultTimeoutSeconds = 30

# How long the decoder may take. It is a single local Node process over at most a few dozen lines.
$script:DefaultDecodeTimeoutSeconds = 30

# How long the two redirected streams may take to reach end of file after the child has already
# exited. It is a flush rather than a wait for work, so this only stops a handle a grandchild
# process inherited and never closed from holding a read open forever.
$script:StreamDrainMilliseconds = 10000

# The launchable `node`, or $null.
#
# `.ps1` is never returned and neither is an extensionless shim, for the reason Paths.psm1's own
# Get-ClaudeCommandPath header owns in full: a native launch of either dies with "%1 is not a valid
# Win32 application". Only `.exe` and `.cmd` can be started here, and `.exe` wins where both exist.
function Get-NodeCommandPath {
    [CmdletBinding()]
    param()

    $found = @(Get-Command 'node' -CommandType Application -ErrorAction SilentlyContinue |
               Where-Object { $_.Source })
    foreach ($ext in @('.exe', '.cmd')) {
        foreach ($c in $found) {
            if ($c.Source.EndsWith($ext, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $c.Source
            }
        }
    }
    $null
}

# One message, so every caller tells the user the same actionable thing.
#
# Node is not an optional extra here. install.ps1 installs it because `lavish-axi` and `tasks-axi`
# are npm packages, so a machine without it has a broken installation rather than a missing nicety,
# and the hint says so rather than sending someone to nodejs.org for one reader.
function Get-NodeHint {
    [CmdletBinding()]
    param()

    'node was not found. It is what decodes the gate''s output, and this installation already ' +
    'needs it for lavish-axi and tasks-axi - so an absent node means the install is incomplete. ' +
    'Run: .\install.ps1 -InstallMissing - then open a new shell so PATH is picked up.'
}

# The vendored decoder, or $null when it is not beside this module.
#
# Resolved from $PSScriptRoot rather than from KINGSHAND_HOME, because it ships with this file and
# a worktree running its own copy of `bin\` must use the copy it has rather than the installation's.
function Get-ToonDecoderPath {
    [CmdletBinding()]
    param()

    $path = Join-Path $PSScriptRoot 'assets\toon\decode.mjs'
    if (Test-Path -LiteralPath $path -PathType Leaf) { return $path }
    $null
}

# One child process launched with each argument passed as its own argument, and what it said.
#
# .launched  whether the process started at all
# .timedOut  whether it was stopped for not answering inside the timeout
# .stdout    what it wrote to stdout, or ''
# .stderr    what it wrote to stderr, or ''
# .exitCode  its exit code, or $null where it never answered
# .error     one line naming a launch failure, or ''
#
# EVERY ARGUMENT GOES THROUGH ArgumentList AND NOTHING IS QUOTED BY HAND, which is why both
# launches below come through here rather than each calling Start-Process. `Start-Process` joins
# its -ArgumentList array with spaces and quotes nothing, so a path holding a space arrives at the
# child split into two arguments - and every path this module launches with comes from %TEMP% or
# from $PSScriptRoot, either of which holds a space the moment an account name or an install
# directory does. ProcessStartInfo's own ArgumentList collection quotes each element itself, so the
# rule is kept by the runtime rather than by a caller remembering to keep it.
#
# BOTH STREAMS ARE DRAINED BEFORE THE WAIT, never after it. A redirected pipe nobody is reading
# fills and blocks the child, which would turn a large document into the hang the timeout exists to
# catch rather than into the answer it should be.
#
# It never throws. A binary that cannot be launched comes back as launched = $false carrying its
# own message, because each caller's job is to say which failure happened rather than to catch.
function Start-CapturedProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Arguments,
        [string]$WorkingDirectory = '',
        [Parameter(Mandatory)][int]$TimeoutSeconds
    )

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName               = $FilePath
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $psi.StandardErrorEncoding  = [System.Text.UTF8Encoding]::new($false)
    foreach ($a in $Arguments) { $psi.ArgumentList.Add("$a") }
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }

    $p = $null
    try {
        $p = [System.Diagnostics.Process]::Start($psi)
        $outTask = $p.StandardOutput.ReadToEndAsync()
        $errTask = $p.StandardError.ReadToEndAsync()

        if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
            try { $p.Kill($true) } catch { }
            return [pscustomobject]@{
                launched = $true; timedOut = $true; stdout = ''; stderr = ''
                exitCode = $null; error = ''
            }
        }

        # The timed wait returns the moment the process ends, which is not the moment the
        # redirected streams reach end of file. Waiting on the two reads is what makes the last
        # thing the child wrote part of the answer rather than a race against its own exit.
        $reads = [System.Threading.Tasks.Task[]]@($outTask, $errTask)
        $null = [System.Threading.Tasks.Task]::WaitAll($reads, $script:StreamDrainMilliseconds)

        [pscustomobject]@{
            launched = $true
            timedOut = $false
            stdout   = $(if ($outTask.IsCompletedSuccessfully) { "$($outTask.Result)" } else { '' })
            stderr   = $(if ($errTask.IsCompletedSuccessfully) { "$($errTask.Result)" } else { '' })
            exitCode = $p.ExitCode
            error    = ''
        }
    } catch {
        [pscustomobject]@{
            launched = $false; timedOut = $false; stdout = ''; stderr = ''
            exitCode = $null; error = "$($_.Exception.Message)"
        }
    } finally {
        if ($p) { $p.Dispose() }
    }
}

# One TOON document as JSON text, or a failure naming what went wrong.
#
# .ok     whether the document was decoded
# .value  the JSON text, or ''
# .error  one line naming the failure, or ''
#
# It never throws. A missing node, a missing decoder, a document that is not TOON and a decoder
# that died all arrive as ok = $false carrying their own message, because the caller's job here is
# to say which one happened rather than to catch.
#
# THE DOCUMENT GOES THROUGH A FILE RATHER THAN THROUGH AN ARGUMENT, and that is not incidental. A
# gate run's output is tens of lines carrying quotes, backslashes and a reviewer's free text, and
# every one of those is a character some layer of Windows command-line re-parsing would take for
# its own - which is the same corruption Paths.psm1 records npm's claude.cmd wrapper performing on
# a JSON schema. A file has no quoting rules to get wrong.
function ConvertFrom-ToonText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [int]$TimeoutSeconds = $script:DefaultDecodeTimeoutSeconds
    )

    $node = Get-NodeCommandPath
    if (-not $node) {
        return [pscustomobject]@{ ok = $false; value = ''; error = (Get-NodeHint) }
    }

    $decoder = Get-ToonDecoderPath
    if (-not $decoder) {
        return [pscustomobject]@{
            ok = $false; value = ''
            error = ('The TOON decoder was not found at ' +
                     (Join-Path $PSScriptRoot 'assets\toon\decode.mjs') +
                     '. It ships with this module, so a missing one means this installation is ' +
                     'incomplete - re-run install.ps1 or restore the file from the repository.')
        }
    }

    # The path is created inside the try, not beside it. A temp directory that is full, read-only
    # or missing makes GetTempFileName throw, and a line above the try is a line outside the
    # promise this function makes.
    #
    # This temp file is the only thing this module ever writes: a fresh unique path the operating
    # system creates and this function deletes. There is no caller-supplied path to mistype, so
    # there is no file it does not own that it could land on.
    $doc = $null
    try {
        $doc = [System.IO.Path]::GetTempFileName()

        # UTF-8 with no byte order mark. The decoder strips one if it finds it, but writing one
        # here would put a character into the document that the tool never emitted.
        [System.IO.File]::WriteAllText($doc, $Text, [System.Text.UTF8Encoding]::new($false))

        $r = Start-CapturedProcess -FilePath $node -Arguments @($decoder, $doc) `
                                   -TimeoutSeconds $TimeoutSeconds
        if (-not $r.launched) {
            return [pscustomobject]@{
                ok = $false; value = ''
                error = "The gate's output could not be decoded: $($r.error)"
            }
        }
        if ($r.timedOut) {
            return [pscustomobject]@{
                ok = $false; value = ''
                error = ("The gate's output could not be decoded: node did not answer within " +
                         "$TimeoutSeconds seconds and was stopped.")
            }
        }

        $code = $r.exitCode
        $json = $r.stdout
        $errs = $r.stderr

        if ($code -ne 0) {
            $one = ("$errs" -replace '\s+', ' ').Trim()
            if (-not $one) { $one = "the decoder exited $code with no message" }
            return [pscustomobject]@{
                ok = $false; value = ''
                error = "The gate's output is not readable as TOON: $one"
            }
        }

        # A zero exit with nothing on stdout is not an empty document - the decoder writes `{}` for
        # one. It means the process did not produce what it promised, and reporting that as an
        # empty run is the fabrication this module refuses.
        if ([string]::IsNullOrWhiteSpace($json)) {
            return [pscustomobject]@{
                ok = $false; value = ''
                error = ("The gate's output could not be decoded: the decoder exited cleanly but " +
                         'wrote nothing.')
            }
        }

        [pscustomobject]@{ ok = $true; value = "$json"; error = '' }
    } catch {
        [pscustomobject]@{
            ok = $false; value = ''
            error = "The gate's output could not be decoded: $($_.Exception.Message)"
        }
    } finally {
        if ($doc) { Remove-Item -LiteralPath $doc -Force -ErrorAction SilentlyContinue }
    }
}

# The one boundary between this module and the gate binary, so every answer below can be exercised
# without a daemon, a repository or a run - the same reason Invoke-GhApi is one function in Ci.psm1
# and Invoke-QuotaAxi is one function in Usage.psm1.
#
# .ok         whether the binary ran at all
# .value      its stdout
# .errorText  its stderr
# .exitCode   its exit code, or $null where it never ran
# .error      one line naming the failure, or ''
#
# A NON-ZERO EXIT IS NOT A FAILURE HERE, and getting that wrong would throw away the answer. The
# tool exits 1 for a run it could not find and prints a perfectly readable `error:` document saying
# so, and it exits 1 on a failed or cancelled outcome while printing the whole run. Only the binary
# being absent, unlaunchable or wedged is a failure of the read; what it said is for the caller to
# decide on.
#
# NO FLAG THAT DRIVES A RUN IS EVER PASSED. The arguments come from this module's own callers
# below, never from a caller's free input, and every one of them inspects.
function Invoke-NoMistakesAxi {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [string]$RepoPath = '',
        [int]$TimeoutSeconds = $script:DefaultTimeoutSeconds
    )

    $exe = Get-NoMistakesCommandPath
    if (-not $exe) {
        return [pscustomobject]@{
            ok = $false; value = ''; errorText = ''; exitCode = $null; error = (Get-NoMistakesHint)
        }
    }

    # The gate is repository-scoped: run it anywhere else and it answers about another repository
    # or about nothing. An empty RepoPath means the current directory, which is what a caller
    # already standing in the repository wants.
    $workingDirectory = $RepoPath
    if (-not $workingDirectory) { $workingDirectory = (Get-Location).Path }
    if (-not (Test-Path -LiteralPath $workingDirectory -PathType Container)) {
        return [pscustomobject]@{
            ok = $false; value = ''; errorText = ''; exitCode = $null
            error = ("There is no directory at $workingDirectory, so the gate could not be asked " +
                     'about it.')
        }
    }

    # Each argument is passed as its own argument by the launcher above, so a `--run` value holding
    # a space stays one value rather than becoming two the tool would not recognise.
    $r = Start-CapturedProcess -FilePath $exe -Arguments $Arguments `
                               -WorkingDirectory $workingDirectory -TimeoutSeconds $TimeoutSeconds
    if (-not $r.launched) {
        return [pscustomobject]@{
            ok = $false; value = ''; errorText = ''; exitCode = $null
            error = "no-mistakes could not be run: $($r.error)"
        }
    }
    if ($r.timedOut) {
        return [pscustomobject]@{
            ok = $false; value = ''; errorText = ''; exitCode = $null
            error = "no-mistakes did not answer within $TimeoutSeconds seconds and was stopped."
        }
    }

    [pscustomobject]@{
        ok        = $true
        value     = $r.stdout
        errorText = $r.stderr
        exitCode  = $r.exitCode
        error     = ''
    }
}

# One value off a decoded hashtable as trimmed text, or '' when the key is not there.
#
# '' means the output did not carry it. That is the absence R-002 asks for rather than a default:
# nothing below ever treats '' as a state word, a step name or a count, and every field that could
# be misread as one is reported beside the reason it is empty.
function Get-ToonText {
    [CmdletBinding()]
    param($Table, [Parameter(Mandatory)][string]$Key)

    if ($null -eq $Table) { return '' }
    if ($Table -isnot [System.Collections.IDictionary]) { return '' }
    if (-not $Table.Contains($Key)) { return '' }
    $v = $Table[$Key]
    if ($null -eq $v) { return '' }
    if ($v -is [System.Collections.IDictionary] -or
        ($v -is [System.Collections.IEnumerable] -and $v -isnot [string])) { return '' }
    "$v".Trim()
}

# One value off a decoded hashtable as a whole number, or $null when it is not one.
#
# $null is "the output did not say", which is not zero. A duration of zero is a real reading - the
# `ci` step reports exactly that when it was skipped - so collapsing the two would make a step
# nobody ran indistinguishable from one whose duration this could not read.
function Get-ToonNumber {
    [CmdletBinding()]
    param($Table, [Parameter(Mandatory)][string]$Key)

    if ($null -eq $Table) { return $null }
    if ($Table -isnot [System.Collections.IDictionary]) { return $null }
    if (-not $Table.Contains($Key)) { return $null }
    $v = $Table[$Key]
    if ($null -eq $v -or $v -is [bool]) { return $null }
    if ($v -is [System.Collections.IDictionary]) { return $null }
    if ($v -is [System.Collections.IEnumerable] -and $v -isnot [string]) { return $null }
    $n = [long]0
    if ([long]::TryParse("$v".Trim(), [ref]$n)) { return $n }
    $null
}

# What a decoded value looks like, in words, for a message that has to name a shape it could not
# read.
#
# The SHAPE is named and the value itself is never quoted. A shape this does not recognise is not
# one it should be repeating content out of, and "a list of 2 items" is what a reader needs in
# order to act anyway.
function Get-ToonShapeName {
    [CmdletBinding()]
    param($Value)

    if ($null -eq $Value) { return 'nothing at all' }
    if ($Value -is [string]) {
        if ($Value.Trim()) { return 'text' }
        return 'an empty string'
    }
    if ($Value -is [System.Collections.IDictionary]) { return 'an object' }
    if ($Value -is [System.Collections.IEnumerable]) {
        return "a list of $(@($Value).Count) item(s)"
    }
    "a $($Value.GetType().Name)"
}

# One decoded table as a list of its rows, with an absent or empty table reading as no rows.
#
# The leading comma is the same load-bearing idiom Usage.psm1's ConvertTo-JsonList documents:
# PowerShell unrolls an array on return, so a bare `@()` would come back as $null and a caller's
# `.Count` would fail on nothing at all.
function Get-ToonRows {
    [CmdletBinding()]
    param($Table, [Parameter(Mandatory)][string]$Key)

    if ($null -eq $Table) { return , @() }
    if ($Table -isnot [System.Collections.IDictionary]) { return , @() }
    if (-not $Table.Contains($Key)) { return , @() }
    $v = $Table[$Key]
    if ($null -eq $v) { return , @() }
    if ($v -is [System.Collections.IDictionary]) { return , @() }
    if ($v -is [string]) { return , @() }
    , @($v)
}

# ONE KEY AS A FACT ABOUT THE DOCUMENT RATHER THAN AS A VALUE, AND THE REASON EVERY FIELD BELOW
# THAT DECIDES ANYTHING GOES THROUGH IT.
#
# .present  whether the key is there at all
# .text     its value as trimmed text, or '' where there is none this reader can take
# .value    the decoded value itself, or $null
# .shape    what the value looks like where the key is present and `.text` could not take it
#
# `Get-ToonText` answers '' for a key that is absent and '' for a key whose value is an object, a
# list or an explicit null. A caller testing that '' therefore cannot tell "the tool said nothing"
# from "the tool said something this reader could not take", and treats the second as the first.
# THAT ONE COLLAPSE IS THE DEFECT THIS MODULE HAS PRODUCED FOUR TIMES, in four different fields,
# every time by testing a value where the question was about a key: `awaiting_agent` matched only
# a wording, `gate:` was read as a scalar, `gate:` presence was then taken from the value's shape,
# and `awaiting_agent` fell to the same thing again. `.present` is that question asked directly
# and `.shape` is what to say instead of falling silent, so the next field added here inherits the
# answer rather than re-deriving it.
function Read-ToonField {
    [CmdletBinding()]
    param($Table, [Parameter(Mandatory)][string]$Key)

    $present = ($null -ne $Table) -and
               ($Table -is [System.Collections.IDictionary]) -and
               $Table.Contains($Key)
    if (-not $present) {
        return [pscustomobject]@{ present = $false; text = ''; value = $null; shape = '' }
    }

    $value = $Table[$Key]
    $text  = Get-ToonText -Table $Table -Key $Key
    [pscustomobject]@{
        present = $true
        text    = $text
        value   = $value
        shape   = $(if ($text) { '' } else { Get-ToonShapeName -Value $value })
    }
}

# The same question one level down, for a key that should carry a table of rows.
#
# .present  whether the key is there at all
# .rows     the entries that are objects, and only those
# .shape    what was there instead, where the key is present and some entry is not an object
#
# A DECLARED TABLE WHOSE ENTRIES ARE NOT OBJECTS IS NOT A TABLE. `steps[2]: intent,review` is
# valid TOON - a list of two strings rather than two rows of fields - and reading it row by row
# gives two steps whose every column is '', which is a run reported confidently in a shape nobody
# sent. Dropping those entries silently is the same fault in a third costume, so what was seen is
# named and the caller says so rather than emitting rows it cannot describe.
# One key that should carry a list, answered the same three ways.
#
# .present  whether the key is there at all
# .items    its entries, whatever they are, and none where the value is not a list at all
# .shape    what was there instead, where the key is present and its value is not a list
#
# The list-ness is decided from the VALUE'S OWN SHAPE and never from how many entries came back,
# because an empty list is a real reading - a run with no active step says exactly that - while a
# mapping, a string or an explicit null where a list belongs is not a list at all. Deciding from
# the count collapses those two, which is this module's one defect wearing a fourth costume.
function Read-ToonList {
    [CmdletBinding()]
    param($Table, [Parameter(Mandatory)][string]$Key)

    $present = ($null -ne $Table) -and
               ($Table -is [System.Collections.IDictionary]) -and
               $Table.Contains($Key)
    if (-not $present) { return [pscustomobject]@{ present = $false; items = @(); shape = '' } }

    $value  = $Table[$Key]
    $isList = ($null -ne $value) -and
              ($value -is [System.Collections.IEnumerable]) -and
              ($value -isnot [string]) -and
              ($value -isnot [System.Collections.IDictionary])
    if (-not $isList) {
        return [pscustomobject]@{
            present = $true; items = @(); shape = (Get-ToonShapeName -Value $value)
        }
    }

    [pscustomobject]@{ present = $true; items = @($value); shape = '' }
}

function Read-ToonTable {
    [CmdletBinding()]
    param($Table, [Parameter(Mandatory)][string]$Key)

    $list = Read-ToonList -Table $Table -Key $Key
    if (-not $list.present) { return [pscustomobject]@{ present = $false; rows = @(); shape = '' } }
    if ($list.shape) {
        return [pscustomobject]@{ present = $true; rows = @(); shape = $list.shape }
    }

    $usable = @(foreach ($row in $list.items) {
        if ($row -is [System.Collections.IDictionary]) { $row }
    })
    $lost = @($list.items).Count - $usable.Count

    $shape = ''
    if ($lost -gt 0) {
        $shape = if ($usable.Count -eq 0) { Get-ToonShapeName -Value $Table[$Key] }
                 else { "$lost of its $(@($list.items).Count) entries in a shape it cannot take" }
    }

    [pscustomobject]@{ present = $true; rows = $usable; shape = $shape }
}

# One row's named columns read through the same primitive, so a cell in a shape this cannot take
# is named by its column rather than handed on as an empty value.
#
# `$Columns` is an ordered map of property name to `@(key, kind)`, where kind is 'text' or
# 'number'. A NUMBER COLUMN IS CHECKED TWICE, because `Get-ToonNumber` answers $null both for a
# key that is not there and for one holding something that is not a number - the same collapse
# one level further down, and the one place it could still hide after the fields above were fixed.
function Read-ToonCells {
    [CmdletBinding()]
    param(
        $Row,
        [Parameter(Mandatory)]$Columns,
        [Parameter(Mandatory)][AllowEmptyCollection()]
        [System.Collections.Generic.List[string]]$Unreadable
    )

    $out = [ordered]@{}
    foreach ($name in $Columns.Keys) {
        $key   = $Columns[$name][0]
        $kind  = $Columns[$name][1]
        $field = Read-ToonField -Table $Row -Key $key
        if ($field.shape) { $Unreadable.Add($key) }

        if ($kind -eq 'number') {
            $number = Get-ToonNumber -Table $Row -Key $key
            if ($null -eq $number -and $field.text) { $Unreadable.Add($key) }
            $out[$name] = $number
        } else {
            $out[$name] = $field.text
        }
    }
    [pscustomobject]$out
}

# The columns a table's cells could not be taken in, as one phrase and with each named once.
#
# Bounded on purpose: a hundred rows sharing one bad column is one fact about the table, not a
# hundred, and a detail line nobody can read to a person is its own kind of unreadable.
function Get-ToonCellNote {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Columns)

    $named = @($Columns | Select-Object -Unique | Sort-Object)
    'values it cannot take in ' + ($named -join ', ')
}

# The columns each table carries, declared rather than spelled out at the loop, so every cell in
# them goes through Read-ToonCells and a column added here is named by default when it cannot be
# taken. Adding one to the loop instead is how a field ends up bypassing the primitive.
$script:StepColumns = [ordered]@{
    step       = @('step',        'text')
    status     = @('status',      'text')
    findings   = @('findings',    'number')
    durationMs = @('duration_ms', 'number')
}
$script:ActiveStepColumns = [ordered]@{
    step         = @('step',          'text')
    activeFor    = @('active_for',    'text')
    lastActivity = @('last_activity', 'text')
    agentPid     = @('agent_pid',     'number')
    round        = @('round',         'text')
}
$script:FindingColumns = [ordered]@{
    id          = @('id',          'text')
    severity    = @('severity',    'text')
    file        = @('file',        'text')
    line        = @('line',        'text')
    action      = @('action',      'text')
    description = @('description', 'text')
}

# WHAT THIS READS AND WHAT IT REFUSES TO READ.
#
# `run.findings` is a residual summary string and is carried as `findingsSummary` alone. Nothing
# computes from it, nothing counts it, and no caller should: on a real cancelled run here it says
# "1 awaiting, 1 auto-fix" with every step terminal and nothing waiting on anybody, which is the
# reading that has already been got wrong more than once.
#
# `steps[]` and `active_steps[]` are two lists and stay two lists. They describe different things -
# what each step of the pipeline did, and what one currently running step is doing right now - and
# merging them produces rows with neither shape's columns.
#
# `help[]` is read into its own property and never looked inside. The tool's own help text contains
# `outcome:`, `approve` and `push`, so any pattern applied to the whole output matches help rather
# than state. Nothing here applies a pattern to the whole output at all, which is what makes that
# structural rather than a rule somebody has to remember.
function ConvertFrom-GateRunOutput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        # Absent is its own value rather than an in-band number. A crashed child on Windows exits
        # negative - 0xC0000005 arrives as -1073741819 - so a sentinel like -1 would record a real
        # reading as $null, which is what every other field here means by "the output did not say".
        [System.Nullable[int]]$ExitCode = $null
    )

    $result = [ordered]@{
        status          = 'unreadable'
        signal          = ''
        detail          = ''
        runId           = ''
        branch          = ''
        head            = ''
        pr              = ''
        runStatus       = ''
        outcome         = ''
        error           = ''
        findingsSummary = ''
        awaitingAgent   = ''
        isParked        = $false
        parkedOn        = ''
        gate            = ''
        gateStatus      = ''
        gateRisk        = ''
        gateNote        = ''
        steps           = @()
        activeSteps     = @()
        findings        = @()
        help            = @()
        notUnderstood   = @()
        json            = ''
        exitCode        = $ExitCode
        takenAt         = (Get-Date).ToUniversalTime().ToString('o')
    }
    $finish = {
        param($status, $signal, $detail)
        $result.status = $status
        $result.signal = $signal
        $result.detail = $detail
        [pscustomobject]$result
    }

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return & $finish 'unreadable' 'no-output' `
            ('no-mistakes printed nothing at all, so what the run is doing was not established. ' +
             'Silence is not an empty run.')
    }

    $decoded = ConvertFrom-ToonText -Text $Text
    if (-not $decoded.ok) {
        return & $finish 'unreadable' 'undecodable-output' $decoded.error
    }

    $doc = $null
    try { $doc = $decoded.value | ConvertFrom-Json -AsHashtable } catch {
        return & $finish 'unreadable' 'undecodable-output' `
            ('The gate''s output was decoded but did not come back as readable JSON ' +
             "($($_.Exception.Message)), so what the run is doing was not established.")
    }
    $result.json = $decoded.value

    # A document that is not an object at all - TOON decodes a lone primitive to one - is not a
    # gate response. It is readable text that says nothing this recognises, and reporting it as a
    # run with every field empty is exactly the empty run R-003 rules out.
    if ($doc -isnot [System.Collections.IDictionary]) {
        return & $finish 'unreadable' 'not-a-gate-response' `
            ('no-mistakes printed something that decoded cleanly but is not a gate response - ' +
             'it carries no fields at all - so what the run is doing was not established.')
    }

    # EVERY SCALAR READ BELOW GOES THROUGH HERE. Naming the field is the default rather than
    # something each call site has to remember, because a call site that forgets is exactly how
    # this defect came back five times. `$unread` carries the key path as well as the words, so
    # the state can list what it could not take without anyone parsing the sentence.
    $unread = [System.Collections.Generic.List[object]]::new()
    $note = {
        param([string]$Path, [string]$Shape, [string]$Kind)
        $unread.Add([pscustomobject]@{
            path = $Path
            text = "its $Path $(if ($Kind) { $Kind } else { 'field' }) held $Shape"
        })
    }
    $take = {
        param($Table, [string]$Key, [string]$Path)
        $field = Read-ToonField -Table $Table -Key $Key
        if ($field.shape) { & $note $Path $field.shape '' }
        $field
    }
    # A table or a list, named the same way and with its rows handed back.
    $takeTable = {
        param($Table, [string]$Key, [string]$Path)
        $read = Read-ToonTable -Table $Table -Key $Key
        if ($read.shape) { & $note $Path $read.shape 'table' }
        $read
    }

    # `help[]` is carried and never looked inside - see this function's header - but a help key in
    # a shape this cannot take is still named, because "never read" is not "never reported".
    $helpList    = Read-ToonList -Table $doc -Key 'help'
    if ($helpList.shape) { & $note 'help' $helpList.shape 'list' }
    $result.help = $helpList.items

    # `outcome` decides whether the run is over, which is the one thing the wait helper this
    # reader exists to be built on will key on. Read by value it would read a finished run as
    # unfinished and wait forever, so it goes through the primitive like everything else.
    $outcomeField   = & $take $doc 'outcome' 'outcome'
    $result.outcome = $outcomeField.text
    $result.error   = (& $take $doc 'error' 'error').text

    # `gate:` ARRIVES IN TWO SHAPES AND BOTH ARE READ, because the tool has already changed which
    # one it emits. The shipped documentation shows a scalar step name; v1.57.0 emits an object
    # carrying step, status, risk, note and its own findings table. Reading only the documented
    # shape cost the whole gate answer - the step name came back empty, so the park had nowhere to
    # point, and a response carrying six findings read as none. Neither shape is dropped in favour
    # of the other, because a different version may emit either and a reader that follows the
    # documentation off a cliff is the failure this module exists to prevent.
    # THE KEY BEING THERE IS THE GATE, NOT THE SHAPE OF ITS VALUE. The tool has changed this
    # field's shape once already, so reading the park off whichever shapes this reader happens to
    # handle would leave a third shape - a list, an explicit null, an empty string - falling
    # through every arm and coming back as no gate at all, with nothing said anywhere. That is the
    # same silent default that cost the whole gate answer last time and a missed park before that:
    # three times in this one field, always because presence was inferred from something other
    # than presence. `Contains` is the question actually being asked.
    $gateField = Read-ToonField -Table $doc -Key 'gate'
    $gateTable = $null
    if ($gateField.present) {
        if ($gateField.value -is [System.Collections.IDictionary]) {
            $gateTable         = $gateField.value
            $result.gate       = (& $take $gateTable 'step'   'gate.step').text
            $result.gateStatus = (& $take $gateTable 'status' 'gate.status').text
            $result.gateRisk   = (& $take $gateTable 'risk'   'gate.risk').text
            $result.gateNote   = (& $take $gateTable 'note'   'gate.note').text
        } else {
            $result.gate = $gateField.text
            # Neither of the two known shapes. The gate still counts - the key is the tool saying
            # the pipeline is waiting - and what came instead is named rather than dropped.
            if ($gateField.shape) { & $note 'gate' $gateField.shape '' }
        }
    }

    $hasGate = $gateField.present

    # The run key gets the same treatment. A `run:` this reader cannot take is not the tool saying
    # there is no run, and answering "answered without reporting a run" to one would be a wrong
    # word about the very thing being asked for.
    $runField = Read-ToonField -Table $doc -Key 'run'
    $run = $null
    if ($runField.present -and $runField.value -is [System.Collections.IDictionary]) {
        $run = $runField.value
    } elseif ($runField.present) {
        & $note 'run' $runField.shape ''
    }

    $runFindings = $null
    if ($run) {
        $result.runId     = (& $take $run 'id'     'run.id').text
        $result.branch    = (& $take $run 'branch' 'run.branch').text
        $result.head      = (& $take $run 'head'   'run.head').text
        $result.pr        = (& $take $run 'pr'     'run.pr').text
        $result.runStatus = (& $take $run 'status' 'run.status').text
        # READ BY KEY, NOT BY VALUE - the sibling of the gate rule above and the reason this whole
        # field family goes through Read-ToonField. An `awaiting_agent` carrying an object is the
        # tool saying the run is waiting; taking the '' Get-ToonText makes of it as "not waiting"
        # is the exact miss this module was written for.
        $awaitingField        = & $take $run 'awaiting_agent' 'run.awaiting_agent'
        $result.awaitingAgent = $awaitingField.text

        # `run.findings` is the residual summary STRING and is carried, never counted. Some
        # versions put the findings table there instead, so a value that is not a string is read
        # as a table below rather than as a summary - and a string here is the summary rather than
        # a table this could not take, which is why it is not named as unreadable.
        $runFindingsField       = Read-ToonField -Table $run -Key 'findings'
        $result.findingsSummary = $runFindingsField.text
        if ($runFindingsField.present -and $runFindingsField.value -isnot [string]) {
            $runFindings = & $takeTable $run 'findings' 'run.findings'
        }

        if (-not $result.outcome) {
            $result.outcome = (& $take $run 'outcome' 'run.outcome').text
        }

        $stepsTable   = & $takeTable $run 'steps'        'run.steps'
        $stepCells    = [System.Collections.Generic.List[string]]::new()
        $result.steps = @(foreach ($row in $stepsTable.rows) {
            Read-ToonCells -Row $row -Columns $script:StepColumns -Unreadable $stepCells
        })
        if ($stepCells.Count -gt 0) {
            & $note 'run.steps' (Get-ToonCellNote -Columns $stepCells) 'table'
        }

        # A separate list, deliberately. Never folded into `steps` and never deduplicated against
        # it: these rows describe one running step's current activity and carry none of the other
        # list's columns.
        $activeTable        = & $takeTable $run 'active_steps' 'run.active_steps'
        $activeCells        = [System.Collections.Generic.List[string]]::new()
        $result.activeSteps = @(foreach ($row in $activeTable.rows) {
            Read-ToonCells -Row $row -Columns $script:ActiveStepColumns -Unreadable $activeCells
        })
        if ($activeCells.Count -gt 0) {
            & $note 'run.active_steps' (Get-ToonCellNote -Columns $activeCells) 'table'
        }
    }

    # THE FINDINGS TABLE SITS IN THREE PLACES and every one of them is read, nearest to the gate
    # first. Each is named when it cannot be taken, whether or not precedence went on to use it:
    # which rows are used is a decision, but a location that was present and unreadable is a fact,
    # and a fact this reader hides is the whole defect. Precedence falls through only on a key
    # that is ABSENT - never on one that is present and produced no rows, which is how a gate
    # carrying `findings[2]: r1,r2` came back as nothing to decide on.
    $findingsRead = @(
        (& $takeTable $gateTable 'findings' 'gate.findings'),
        (& $takeTable $doc       'findings' 'findings'),
        $runFindings
    )
    $findingRows = @()
    foreach ($read in $findingsRead) {
        if ($null -ne $read -and $read.present) { $findingRows = $read.rows; break }
    }

    $findingCells    = [System.Collections.Generic.List[string]]::new()
    $result.findings = @(foreach ($row in $findingRows) {
        Read-ToonCells -Row $row -Columns $script:FindingColumns -Unreadable $findingCells
    })
    if ($findingCells.Count -gt 0) {
        & $note 'findings' (Get-ToonCellNote -Columns $findingCells) 'table'
    }

    # WHETHER THE RUN IS PARKED, FROM THE TWO FIELDS THAT SAY SO AND FROM NOTHING ELSE.
    #
    # `awaiting_agent` is the tool stating it on a run object, and a `gate:` is the tool stating it
    # on a drive result - "if the output contains a `gate:` object, the pipeline is waiting on you"
    # is the gate's own documentation. No count, no step status and no elapsed time contributes,
    # because every one of those has already produced a wrong answer here.
    #
    # A PRESENT `awaiting_agent` IS A PARK WHATEVER IT HOLDS, and the recognised wording only
    # decides how the detail line reads. The field's name is the tool saying what it is waiting on,
    # so neither a value this reader has not seen before - a later version's wording, say - nor one
    # in a shape it cannot take may come back as "not waiting". Matching `parked <duration>` and
    # calling everything else unparked, or testing the text and calling an object nothing, both put
    # the silent default back inside the module written to forbid it, in the one direction that has
    # already cost two hours and twenty-six minutes of a parked run sitting unanswered.
    #
    # The absence of both keys is the documented way of saying a run is not waiting on anybody, so
    # `$false` is a reading rather than a default - but it is only ever reached on output that
    # decoded, which is why an unreadable output returns above with no state at all.
    $awaitingPresent = if ($run) { $awaitingField.present } else { $false }
    $awaitingRecognised = [bool]($result.awaitingAgent -match '^parked\b')
    $result.isParked = $awaitingPresent -or $hasGate
    if ($result.gate) { $result.parkedOn = $result.gate }

    # Built here, after every field has had its say, so one sentence carries all of them. The key
    # paths go onto the state beside it: a caller deciding what to do about an unreadable field
    # should not have to parse an English sentence to find out which field it was.
    $result.notUnderstood = @($unread | ForEach-Object { $_.path })
    $shapeNote = if ($unread.Count -gt 0) {
        ' Part of the output was in a shape this reader does not recognise: ' +
        (@($unread | ForEach-Object { $_.text }) -join '; ') +
        '. Those fields are not in this reading.'
    } else { '' }

    if (-not $run) {
        # Readable, and it carries no run object. Two quite different documents arrive here and the
        # detail has to tell them apart, because one of them is a pipeline waiting on somebody.
        #
        # A gate response is the tool answering a drive call: it names the step it is parked at and
        # lists that step's findings, and every one of those fields is filled in above - it simply
        # has no run object beside them. Calling that "no run state to read" would be the same kind
        # of wrong answer this module exists to stop, so it says what it is.
        if ($hasGate) {
            $howMany = @($result.findings).Count
            $listed = if ($howMany -gt 0) { " It lists $howMany finding(s) to decide on." }
                      else { '' }
            # An unnamed gate is still a gate. Saying "parked at its  step" would read as a
            # missing word rather than as a missing field, so the absence is named out loud.
            $at = if ($result.gate) { "at its $($result.gate) step" }
                  else { 'at a step it did not name' }
            return & $finish 'no-run' 'gate-response' `
                ("no-mistakes answered with a gate response rather than a run: the pipeline is " +
                 "parked $at and waiting to be answered.$shapeNote$listed It carries " +
                 'no run object, so the run id, branch, head and step list are not in this output.')
        }

        # The tool's own message is carried verbatim rather than being turned into a state word.
        $why = if ($result.error) { " It said: $($result.error)" } else { '' }
        # A `run:` that was there but could not be taken is not the tool reporting no run, and
        # saying so would be a wrong word about the one thing the caller asked after.
        $none = if ($runField.present) {
            'no-mistakes answered with a run field this reader could not take, so there is no ' +
            'run state to read.'
        } else {
            'no-mistakes answered without reporting a run, so there is no run state to read.'
        }
        return & $finish 'no-run' 'no-run-reported' ($none + $shapeNote + $why)
    }

    $named = if ($result.runId) { "Run $($result.runId)" } else { 'The run' }
    $on    = if ($result.branch) { " on $($result.branch)" } else { '' }
    $said  = if ($result.runStatus) { "reports status $($result.runStatus)" }
             else { 'reported no status word' }
    $where = if ($result.parkedOn) { " at its $($result.parkedOn) step" } else { '' }
    $waiting = if ($result.awaitingAgent -and -not $awaitingRecognised) {
        # The tool's own word, quoted rather than translated, and named as unrecognised. A caller
        # reading this knows the run is waiting and knows this reader could not say what for,
        # which is the honest pair; calling it an ordinary park would state the second half.
        " It is waiting$where - no-mistakes said ""$($result.awaitingAgent)"", which this reader " +
        'does not recognise, so what it is waiting for is not established.'
    } elseif ($result.isParked) {
        " It is parked$where and waiting to be answered."
    } else { '' }
    $ended = if ($result.outcome) { " Its outcome is $($result.outcome)." } else { '' }

    & $finish 'has-run' 'run-reported' "$named$on $said.$waiting$shapeNote$ended"
}

# What a gate run is doing, read from the gate itself.
#
# .status   has-run | no-run | unreadable
# .signal   what settled it
# .detail   one line naming the evidence, written to be read to a person
#
# and, on `has-run`, everything ConvertFrom-GateRunOutput documents above.
#
# -RepoPath defaults to the current directory, which is what a caller already standing in the
# repository wants and is how muster and rally will call it. -Run defaults to empty, which is the
# tool's own default of the active or most recent run; a caller that wants one particular run names
# it. Neither default is ever widened into another flag.
#
# -Branch IS THE GUARD ON THAT DEFAULT, AND IT EXISTS BECAUSE THE DEFAULT HAS ALREADY LIED.
# `axi status` with no `--run` returns the most recent run in the repository, which is not
# necessarily the one the caller means. docs\2026-09-01-stall-detection.md records what that costs:
# a watcher started before its own run had registered read a different, already completed run and
# reported success immediately. The run it read was real and its `outcome: passed` was true - about
# somebody else's run.
#
# Naming the branch turns that into a refusal. A run whose own `branch` field is not the one asked
# for comes back `no-run` naming both, rather than as state about the wrong run. It is a guard
# rather than a sentence telling a caller to check afterwards, because the caller is usually a
# session watching something else and a check it has to remember is a check it will not make.
#
# Empty means no check, which is the right default for a caller reading a repository it is standing
# in and asking what is going on at all.
function Get-GateRunState {
    [CmdletBinding()]
    param(
        [string]$RepoPath = '',
        [string]$Run = '',
        [string]$Branch = '',
        [int]$TimeoutSeconds = $script:DefaultTimeoutSeconds
    )

    $arguments = @('axi', 'status')
    if ($Run) { $arguments += @('--run', $Run) }

    $r = Invoke-NoMistakesAxi -Arguments $arguments -RepoPath $RepoPath -TimeoutSeconds $TimeoutSeconds
    if (-not $r.ok) {
        # Built by the same function that builds every other answer, so the shape is stated once.
        # Empty text is the one input guaranteed to come back `unreadable` with every field at its
        # absent value, which is exactly what a read that never happened should look like.
        $failed = ConvertFrom-GateRunOutput -Text ''
        $failed.signal = 'lookup-failed'
        $failed.detail = "What the gate run is doing could not be established: $($r.error)"
        return $failed
    }

    # The exit code is recorded and never decides. The tool exits 1 both for a run it could not
    # find, printing a readable `error:` document, and for a run that ended failed or cancelled,
    # printing the whole thing - so refusing on it would throw away the state it was asked for.
    $state = ConvertFrom-GateRunOutput -Text $r.value -ExitCode $r.exitCode

    # stderr carries the tool's progress and its own update notice, never state. It is worth saying
    # out loud only when there was no state to read, where it is often the only clue what happened.
    if ($state.status -eq 'unreadable' -and $r.errorText) {
        $note = ("$($r.errorText)" -replace '\s+', ' ').Trim()
        if ($note) { $state.detail = "$($state.detail) no-mistakes also said: $note" }
    }

    # The branch guard, applied to a reading that succeeded. A run on another branch is a real run
    # and everything it says is true - about work nobody here asked about - so it is refused rather
    # than returned, and both branches are named so the caller can see what happened.
    if ($Branch -and $state.status -eq 'has-run' -and $state.branch -ne $Branch) {
        $found = if ($state.runId) { "run $($state.runId)" } else { 'a run' }
        $where = if ($state.branch) { "on $($state.branch)" } else { 'with no branch named' }

        # Built by the same function that builds every other answer, so the shape is stated once
        # and no field of the wrong run's state survives into it.
        $refused = ConvertFrom-GateRunOutput -Text ''
        $refused.status = 'no-run'
        $refused.signal = 'wrong-branch'
        $refused.detail = ("no-mistakes answered about $found $where, not about $Branch, so there " +
                           'is no state here for that branch. Asking without a run id returns the ' +
                           'most recent run in the repository, which is not necessarily the one ' +
                           'being watched.')
        return $refused
    }

    $state
}

# `Invoke-NoMistakesAxi` is absent from this list on purpose - see the no-drive paragraph in the
# header. Nothing may add it back without answering the argument made there.
Export-ModuleMember -Function Get-NodeCommandPath, Get-NodeHint, Get-ToonDecoderPath,
                              ConvertFrom-ToonText,
                              Get-ToonText, Get-ToonNumber, Get-ToonRows, Get-ToonShapeName,
                              Read-ToonField, Read-ToonList, Read-ToonTable, Read-ToonCells,
                              Get-ToonCellNote,
                              ConvertFrom-GateRunOutput, Get-GateRunState
