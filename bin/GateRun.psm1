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
        [int]$ExitCode = -1
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
        json            = ''
        exitCode        = $(if ($ExitCode -ge 0) { $ExitCode } else { $null })
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

    $result.help    = Get-ToonRows  -Table $doc -Key 'help'
    $result.outcome = Get-ToonText  -Table $doc -Key 'outcome'
    $result.error   = Get-ToonText  -Table $doc -Key 'error'

    # `gate:` ARRIVES IN TWO SHAPES AND BOTH ARE READ, because the tool has already changed which
    # one it emits. The shipped documentation shows a scalar step name; v1.57.0 emits an object
    # carrying step, status, risk, note and its own findings table. Reading only the documented
    # shape cost the whole gate answer - the step name came back empty, so the park had nowhere to
    # point, and a response carrying six findings read as none. Neither shape is dropped in favour
    # of the other, because a different version may emit either and a reader that follows the
    # documentation off a cliff is the failure this module exists to prevent.
    $gateTable = $null
    if ($doc.Contains('gate') -and $doc['gate'] -is [System.Collections.IDictionary]) {
        $gateTable = $doc['gate']
    }
    if ($gateTable) {
        $result.gate       = Get-ToonText -Table $gateTable -Key 'step'
        $result.gateStatus = Get-ToonText -Table $gateTable -Key 'status'
        $result.gateRisk   = Get-ToonText -Table $gateTable -Key 'risk'
        $result.gateNote   = Get-ToonText -Table $gateTable -Key 'note'
    } else {
        $result.gate = Get-ToonText -Table $doc -Key 'gate'
    }

    # THE GATE'S PRESENCE, NOT ITS STEP NAME. A gate object that names no step still states that
    # the pipeline is waiting, and deriving the park from `$result.gate` alone would read that
    # unnamed gate as no gate at all - the silent default this module's header rules out.
    $hasGate = ($null -ne $gateTable) -or [bool]$result.gate

    # The findings table sits inside the `gate:` object on v1.57.0, beside it on the documented
    # shape, and under the run elsewhere. All three are read, nearest to the gate first.
    $findingRows = Get-ToonRows -Table $gateTable -Key 'findings'
    if (@($findingRows).Count -eq 0) { $findingRows = Get-ToonRows -Table $doc -Key 'findings' }

    $run = $null
    if ($doc.Contains('run') -and $doc['run'] -is [System.Collections.IDictionary]) {
        $run = $doc['run']
    }

    if ($run) {
        $result.runId           = Get-ToonText -Table $run -Key 'id'
        $result.branch          = Get-ToonText -Table $run -Key 'branch'
        $result.head            = Get-ToonText -Table $run -Key 'head'
        $result.pr              = Get-ToonText -Table $run -Key 'pr'
        $result.runStatus       = Get-ToonText -Table $run -Key 'status'
        $result.awaitingAgent   = Get-ToonText -Table $run -Key 'awaiting_agent'
        # Carried, never counted. See this function's header.
        $result.findingsSummary = Get-ToonText -Table $run -Key 'findings'

        if (-not $result.outcome) { $result.outcome = Get-ToonText -Table $run -Key 'outcome' }

        # ASSIGNED BEFORE IT IS ITERATED, never piped straight out of Get-ToonRows. That function
        # returns its empty case as `, @()` so a caller's `.Count` works, and piping that wrapper
        # hands the pipeline one item - the empty array itself - which comes back as a single row
        # with every column blank. A step list of one empty step is exactly the composite this
        # module refuses to produce, so the unwrap happens here in an assignment.
        $stepRows = Get-ToonRows -Table $run -Key 'steps'
        $result.steps = @(foreach ($row in $stepRows) {
            [pscustomobject]@{
                step       = Get-ToonText   -Table $row -Key 'step'
                status     = Get-ToonText   -Table $row -Key 'status'
                findings   = Get-ToonNumber -Table $row -Key 'findings'
                durationMs = Get-ToonNumber -Table $row -Key 'duration_ms'
            }
        })

        # A separate list, deliberately. Never folded into `steps` and never deduplicated against
        # it: these rows describe one running step's current activity and carry none of the other
        # list's columns.
        $activeRows = Get-ToonRows -Table $run -Key 'active_steps'
        $result.activeSteps = @(foreach ($row in $activeRows) {
            [pscustomobject]@{
                step         = Get-ToonText   -Table $row -Key 'step'
                activeFor    = Get-ToonText   -Table $row -Key 'active_for'
                lastActivity = Get-ToonText   -Table $row -Key 'last_activity'
                agentPid     = Get-ToonNumber -Table $row -Key 'agent_pid'
                round        = Get-ToonText   -Table $row -Key 'round'
            }
        })

        if (@($findingRows).Count -eq 0) { $findingRows = Get-ToonRows -Table $run -Key 'findings' }
    }

    $result.findings = @(foreach ($row in $findingRows) {
        if ($row -isnot [System.Collections.IDictionary]) { continue }
        [pscustomobject]@{
            id          = Get-ToonText -Table $row -Key 'id'
            severity    = Get-ToonText -Table $row -Key 'severity'
            file        = Get-ToonText -Table $row -Key 'file'
            line        = Get-ToonText -Table $row -Key 'line'
            action      = Get-ToonText -Table $row -Key 'action'
            description = Get-ToonText -Table $row -Key 'description'
        }
    })

    # WHETHER THE RUN IS PARKED, FROM THE TWO FIELDS THAT SAY SO AND FROM NOTHING ELSE.
    #
    # `awaiting_agent` is the tool stating it on a run object, and a `gate:` is the tool stating it
    # on a drive result - "if the output contains a `gate:` object, the pipeline is waiting on you"
    # is the gate's own documentation. No count, no step status and no elapsed time contributes,
    # because every one of those has already produced a wrong answer here.
    #
    # A NON-EMPTY `awaiting_agent` IS A PARK WHATEVER IT SAYS, and the recognised wording only
    # decides how the detail line reads. The field's name is the tool saying what it is waiting on,
    # so a value this reader has not seen before - a later version's wording, say - must never come
    # back as "not waiting". Matching `parked <duration>` and calling everything else unparked
    # would put the silent default back inside the module written to forbid it, in the one
    # direction that has already cost two hours and twenty-six minutes of a parked run sitting
    # unanswered.
    #
    # The absence of both is the documented way of saying a run is not waiting on anybody, so
    # `$false` is a reading rather than a default - but it is only ever reached on output that
    # decoded, which is why an unreadable output returns above with no state at all.
    $awaitingRecognised = [bool]($result.awaitingAgent -match '^parked\b')
    $result.isParked = [bool]$result.awaitingAgent -or $hasGate
    if ($result.gate) { $result.parkedOn = $result.gate }

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
                 "parked $at and waiting to be answered.$listed It carries " +
                 'no run object, so the run id, branch, head and step list are not in this output.')
        }

        # The tool's own message is carried verbatim rather than being turned into a state word.
        $why = if ($result.error) { " It said: $($result.error)" } else { '' }
        return & $finish 'no-run' 'no-run-reported' `
            ('no-mistakes answered without reporting a run, so there is no run state to read.' + $why)
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

    & $finish 'has-run' 'run-reported' "$named$on $said.$waiting$ended"
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

Export-ModuleMember -Function Get-NodeCommandPath, Get-NodeHint, Get-ToonDecoderPath,
                              ConvertFrom-ToonText, Invoke-NoMistakesAxi,
                              Get-ToonText, Get-ToonNumber, Get-ToonRows,
                              ConvertFrom-GateRunOutput, Get-GateRunState
