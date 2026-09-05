#Requires -Version 7.0
Set-StrictMode -Version Latest

# How much of the current usage window is spent, and one line saying what the fleet is doing.
#
# The failure this exists to prevent: kingshand can spend the whole of a five-hour window without
# noticing, and the King finds out when work dies mid-run. Three things follow from that - a reader
# that answers or says plainly it cannot, a refusal that stops a new dispatch near the limit
# (Dispatch-Worker.ps1 owns that), and a pulse line that speaks only when something has changed.
#
# WHERE THE NUMBER COMES FROM, AND WHY IT IS NOT READ HERE. `quota-axi` is a separate tool that
# already owns this question: it reports the account's own windows as JSON, with a used percentage
# and a reset time per window. Nothing in this file opens a credential file, a transcript or a
# terminal - it runs that tool and parses its JSON, which is the same boundary Ci.psm1 keeps to
# `gh`. That matters twice over: it is what keeps standing criterion 12 honoured, because the only
# format read here is JSON with a declared schema version, and it is what keeps this change clear
# of the account-switch machinery, which reads credentials and is none of this module's business.
#
# Four candidates were tested before settling on it and all four gave nothing:
# docs\2026-09-05-usage-window-watch.md records what each one returned.
#
# THREE ANSWERS, AND THE THIRD IS THE POINT - the shape Ci.psm1 already uses on this repo.
# `has-usage` and `no-usage` are answers; `unknown` is the refusal to guess when the question could
# not be settled - no `quota-axi`, a tool that would not run, output that is not the JSON this
# expects, or a reading the tool itself marks stale. A percentage is NEVER invented to fill the
# gap. Zero is the most dangerous fabrication available here: it reads as a wide open window and
# would wave through the dispatch this module exists to refuse.
#
# NOTHING HERE READS instructions.md. The King turns the pulse off by writing a line in that file,
# and the Hand honours it by reading its own instructions - which are injected in full at session
# start. A script matching a phrase in free prose written by a person is exactly the open-ended
# scanner standing criterion 12 forbids, and there is no round after which such a matcher is
# finished. The switch is a person's word read by the Hand, and it stays that way.

# Ten minutes between pulses, and it is a parameter on Watch-UsagePulse rather than a constant so a
# session that wants a different cadence can say so without editing this file.
$script:DefaultPulseIntervalMinutes = 10

# How long a `quota-axi` call may take before it is given up on. It reaches the network, so a
# dispatch that waited on it indefinitely would be a dispatch a hung tool could stop - which is the
# fail-closed outcome R-006 rules out. A timeout reads as `unknown`, which fails open.
$script:DefaultTimeoutSeconds = 20

# How many workers the pulse names before the rest become a count. The line is one line, hard cap,
# however many workers are live - so the tail is summarised rather than wrapped.
$script:PulseNameLimit = 3

# The windows that bound every dispatch, and the only ones the threshold is taken across. A single
# model's window and a spend cap are excluded deliberately - Get-AccountUsageWindows owns why.
$script:AccountWindowIds = @('five_hour', 'seven_day')

# WHAT THE PULSE LAST SAID, HELD FOR THE LIFE OF THE PROCESS AND WRITTEN NOWHERE.
#
# This is the whole of the pulse's memory: the band and the fleet shape of the last line it spoke.
# It never needs to outlive the process, because a tick is only ever compared against the tick
# before it and the documented arming is one long-lived background job.
#
# NOTHING IN THIS MODULE OPENS A FILE TO KEEP IT, and that is deliberate rather than incidental. A
# record here would live in state\, beside crew.json, and every guard written to stop a mistyped
# path replacing the fleet is a guard that can be got wrong - a half-written crew.json read as a
# half-written record of ours was exactly that, and it cost the fleet with nothing raised anywhere.
# There is no path to mistype and no file to overwrite when the baseline is a variable.
#
# The accepted cost is one line: a restarted session speaks its first pulse even where nothing has
# moved, because it has nothing yet to compare against.
$script:LastSpoken = $null

# A property off a ConvertFrom-Json object, or $null when it is not there. Under
# Set-StrictMode -Version Latest a missing property throws, and every field below is one the tool
# is allowed to leave out.
function Get-JsonField {
    [CmdletBinding()]
    param($Object, [Parameter(Mandatory)][string]$Name)

    if ($null -eq $Object) { return $null }
    if ($Object -isnot [psobject]) { return $null }
    if ($Object.PSObject.Properties.Name -notcontains $Name) { return $null }

    # The leading comma is the same load-bearing idiom ConvertTo-JsonList documents, and it is here
    # for the case that idiom exists for: PowerShell unrolls an array on return, so a field the tool
    # wrote as `[]` came back as $null - indistinguishable from one it wrote as `null`, which is the
    # difference between "there are none" and "the tool did not say". The outer array survives the
    # unwrap and every scalar field reads exactly as it did.
    , $Object.$Name
}

# WHETHER THE TOOL WROTE THE FIELD AT ALL, which is a different question from what it wrote there.
#
# Get-JsonField answers $null to both an absent key and a key the tool wrote as JSON `null`, and
# collapsing those two is how a renamed field would read as a settled fact about this machine. "The
# tool did not mention windows" and "the tool says there are none" are not the same sentence.
function Test-JsonField {
    [CmdletBinding()]
    param($Object, [Parameter(Mandatory)][string]$Name)

    if ($null -eq $Object) { return $false }
    if ($Object -isnot [psobject]) { return $false }
    $Object.PSObject.Properties.Name -contains $Name
}

# A JSON field that should be a list, as a list - with $null meaning EMPTY rather than one item.
#
# `@($null)` is an array of one, so a field the tool wrote as `null` would arrive looking like a
# window that exists and then fail every test of what is in it. Ci.psm1 records the same trap at its
# own trigger lookup. Tested against $null before it is wrapped, in one place, so no caller has to
# remember.
function ConvertTo-JsonList {
    [CmdletBinding()]
    param($Value)

    # The leading comma is load-bearing, and it is the same idiom Crew.psm1's Get-CrewByStage
    # documents. PowerShell unrolls an array on return, so a bare `@()` would come back as $null and
    # the caller's `.Count` would fail on nothing at all. The outer array survives the unwrap.
    if ($null -eq $Value) { return , @() }
    , @($Value)
}

# The launchable `quota-axi`, or $null.
#
# `.ps1` is never returned, and npm installs one alongside the others. Paths.psm1's own
# Get-ClaudeCommandPath header owns the reasoning in full: a native launch of a `.ps1` dies with
# "%1 is not a valid Win32 application", and the extensionless npm shim is a shell script with the
# same problem. Only `.exe` and `.cmd` can be started here, and `.exe` wins where both exist.
function Get-QuotaAxiCommandPath {
    [CmdletBinding()]
    param()

    $found = @(Get-Command 'quota-axi' -CommandType Application -ErrorAction SilentlyContinue |
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
function Get-QuotaAxiHint {
    [CmdletBinding()]
    param()

    'quota-axi was not found. Install it with: npm install -g quota-axi - it is what reports how ' +
    'much of the current usage window is spent. Without it kingshand still dispatches; it just ' +
    'cannot tell you how close to the limit you are.'
}

# The one boundary between this module and the outside world, so every answer below can be
# exercised without a network, a token or a subscription - the same reason Invoke-GhApi is one
# function in Ci.psm1.
#
# It never throws. A missing tool, a non-zero exit, a hang and a crash all arrive as ok = $false
# carrying the tool's own message, because the caller's job is to say which one happened.
#
# NO FLAG THAT CAN PROMPT IS EVER PASSED. `quota-axi` has one - it opens a keychain dialog - and a
# dispatch that stopped on a dialog nobody is sitting in front of is the worst outcome available
# here. The arguments come from this module and never from a caller's input.
function Invoke-QuotaAxi {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [int]$TimeoutSeconds = $script:DefaultTimeoutSeconds
    )

    $exe = Get-QuotaAxiCommandPath
    if (-not $exe) {
        return [pscustomobject]@{ ok = $false; value = ''; error = (Get-QuotaAxiHint) }
    }

    # Created inside the try, not beside it. A temp directory that is full, read-only or missing
    # makes GetTempFileName throw, and a line above the try is a line outside the promise this
    # function makes - the exception would reach Get-UsageWindow and through it the dispatch.
    $out = $null
    $err = $null
    try {
        $out = [System.IO.Path]::GetTempFileName()
        $err = [System.IO.Path]::GetTempFileName()
        $p = Start-Process -FilePath $exe -ArgumentList $Arguments -NoNewWindow -PassThru `
                           -RedirectStandardOutput $out -RedirectStandardError $err
        if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
            try { $p.Kill($true) } catch { }
            return [pscustomobject]@{
                ok    = $false
                value = ''
                error = "quota-axi did not answer within $TimeoutSeconds seconds and was stopped."
            }
        }
        $code = $p.ExitCode
        $text = (Get-Content -LiteralPath $out -Raw -ErrorAction SilentlyContinue)
        $errs = (Get-Content -LiteralPath $err -Raw -ErrorAction SilentlyContinue)
        if ($code -ne 0) {
            $one = (("$errs $text") -replace '\s+', ' ').Trim()
            if (-not $one) { $one = "quota-axi exited $code with no output." }
            return [pscustomobject]@{ ok = $false; value = ''; error = $one }
        }
        [pscustomobject]@{ ok = $true; value = "$text"; error = '' }
    } catch {
        [pscustomobject]@{
            ok = $false; value = ''
            error = "quota-axi could not be run: $($_.Exception.Message)"
        }
    } finally {
        foreach ($f in @($out, $err)) {
            if ($f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
        }
    }
}

# A JSON field that must be a number, as a double - or $null where it is anything else.
#
# WHY THIS IS NOT A CAST. `[double]$Value` on a field the tool wrote as a word, an object or a list
# raises a terminating error, and the one caller that matters runs under
# $ErrorActionPreference = 'Stop' with nothing between it and the dispatch. A percentage that cannot
# be read is the `unknown` this module already has an answer for, so it is converted here and tested
# for $null there rather than thrown from the middle of a reading.
#
# $true converts to 1 and would read as one percent spent, so a boolean is refused by name rather
# than left to the framework. NaN and infinity go the same way: both survive a conversion and
# neither is a percentage anything downstream can compare against.
function ConvertTo-UsageNumber {
    [CmdletBinding()]
    param($Value)

    if ($null -eq $Value)  { return $null }
    if ($Value -is [bool]) { return $null }
    if ($Value -is [string] -and -not $Value.Trim()) { return $null }

    $n = $null
    try { $n = [System.Convert]::ToDouble($Value, [cultureinfo]::InvariantCulture) } catch { return $null }
    if ([double]::IsNaN($n) -or [double]::IsInfinity($n)) { return $null }
    $n
}

# The reset time as an ISO string, or '' when the tool did not give one that parses.
#
# Separate from the percentage on purpose. A reset time that cannot be read is not evidence against
# a percentage that was read perfectly well, and collapsing the two would throw away the answer over
# the footnote. Parsed by the framework rather than by anything hand-written here.
function ConvertTo-UsageResetTime {
    [CmdletBinding()]
    param($Value)

    if ($null -eq $Value) { return '' }
    if ($Value -is [datetime])       { return ([datetimeoffset]$Value).ToString('o') }
    if ($Value -is [datetimeoffset]) { return $Value.ToString('o') }

    $text = "$Value".Trim()
    if (-not $text) { return '' }
    $parsed = [datetimeoffset]::MinValue
    if ([datetimeoffset]::TryParse($text, [ref]$parsed)) { return $parsed.ToString('o') }
    ''
}

# A reset time and a window name as a person would say them, because `detail` is a line the Hand
# reads out and CLAUDE.md has it translate internal labels before they leave. The window names are
# a closed set of two and anything else passes through as the tool's own word rather than being
# renamed into something this cannot stand behind.
#
# THE DAY IS SAID WHENEVER IT IS NOT TODAY, and that is not decoration. This sentence is pasted
# straight into the dispatch refusal, immediately before "Wait for the window to reset", so it is
# the sentence the user acts on. The limiting window is not always the five-hour one - the weekly
# window bounds the answer often enough to be ordinary - and a reset six days out rendered as a
# bare "10:00" reads as this morning. Nothing errors and no number is wrong; the reader simply
# waits for a time that has already passed and finds the window still spent.
#
# Decided against the local day of the reset itself rather than against a fixed number of hours,
# so a reset at one in the morning says tomorrow's date instead of reading as tonight.
function Format-UsageResetTime {
    [CmdletBinding()]
    param([string]$IsoTime)

    if (-not $IsoTime) { return '' }
    $parsed = [datetimeoffset]::MinValue
    if (-not [datetimeoffset]::TryParse($IsoTime, [ref]$parsed)) { return '' }

    $local = $parsed.ToLocalTime()
    $when  = $local.ToString('HH:mm') + ' local time'
    if ($local.Date -ne (Get-Date).Date) { $when += ' on ' + $local.ToString('ddd d MMM') }
    " It resets at $when."
}

function Format-UsageWindowName {
    [CmdletBinding()]
    param([string]$Id)

    switch ($Id) {
        'five_hour' { return 'the session window' }
        'seven_day' { return 'the weekly window' }
    }
    $Id
}

# The same two windows in the one or two words the pulse has room for.
function Format-UsageWindowShortName {
    [CmdletBinding()]
    param([string]$Id)

    switch ($Id) {
        'five_hour' { return 'session' }
        'seven_day' { return 'week' }
    }
    $Id
}

# WHICH ACCOUNT THIS PERCENTAGE BELONGS TO, AND WHY IT HAS TO BE SAID OUT LOUD.
#
# `quota-axi` reads the live credential file, and on this machine that file is swapped between two
# accounts by a script of the King's own. So the percentage is always about whichever account is
# active at that moment, and a switch changes which pool it describes with nothing visible to show
# it. Two readings either side of a switch are about different quotas and must never be compared.
#
# THE NAME ONLY. This opens one file that holds one word. It never reads, logs or stores anything
# from a credential file, and nothing here may start: the deliverable stops at knowing which account
# is active, and the account-switch machinery is none of this module's business.
#
# An absent file is the ordinary state on a machine with no such script, and reads as no account
# rather than as an error.
function Get-ActiveAccountName {
    [CmdletBinding()]
    param()

    $profileRoot = $env:USERPROFILE
    if (-not $profileRoot) { return '' }
    $path = Join-Path $profileRoot '.claude\accounts\.active'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return '' }
    try {
        $name = (Get-Content -LiteralPath $path -Raw -ErrorAction Stop).Trim()
    } catch { return '' }
    # One word, and only a plausible one. A file holding anything else is not a name this can vouch
    # for, and reporting whatever it happened to contain would put unchecked text into the pulse.
    if ($name -match '\A[A-Za-z0-9._-]{1,64}\z') { return $name }
    ''
}

# The account's own windows - the only ones that bound a dispatch - each carrying what could be
# read off it and what could not.
#
# .id           five_hour or seven_day
# .percent      the used percentage, or $null where the tool wrote something that is not a number
# .resetsAt     when it resets, ISO, or '' where the tool gave no time this could read
# .resetStatus  known | unreadable | rolled
# .applies      whether this window bounds the dispatch running now
#
# ONLY THE ACCOUNT-LEVEL WINDOWS, AND THAT FILTER ALONE CARRIES THE MEASURED TRAP. A single model's
# window bounds that model and a spend cap bounds spending; neither says whether the next worker can
# run. `extra_usage` on this machine reports 100 percent used with no reset time at all, and taking
# the worst percentage across the whole list would answer 100 for ever - blocking every dispatch
# permanently, which is the hard block this guard is written never to perform. It is excluded
# because it is neither `five_hour` nor `seven_day`, so it never reaches the reset rule below.
#
# A MISSING RESET TIME DOES NOT DISQUALIFY AN ACCOUNT WINDOW - IT ONLY COSTS THE CLAIM ABOUT WHEN IT
# CLEARS. The percentage is what bounds the dispatch and it was read perfectly well; throwing it
# away over the footnote is how a session window reported at 95 percent disappeared while the reader
# answered a confident 30 from the week, and a worker went out into it. So the number survives and
# only `resetsAt` is lost. A session or weekly window at 100 percent with no reset therefore refuses,
# which is right - unlike the spend cap, that one really does bound the next worker.
#
# A RESET ALREADY IN THE PAST IS DIFFERENT AND IS STILL DISCARDED. That pool has genuinely rolled, so
# its percentage describes a window that is over rather than the one running now.
#
# NOTHING IS DROPPED IN SILENCE EITHER WAY. Every window present comes back annotated, and
# Format-UsageWindowNotes turns what could not be read into a sentence beside the percentage - an
# unreadable input has to read as unreadable rather than simply vanishing.
function Get-AccountUsageWindows {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][array]$Windows, [datetimeoffset]$Now)

    if (-not $PSBoundParameters.ContainsKey('Now')) { $Now = [datetimeoffset]::UtcNow }

    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($id in $script:AccountWindowIds) {
        $w = @($Windows | Where-Object { (Get-JsonField $_ 'id') -eq $id }) | Select-Object -First 1
        if (-not $w) { continue }

        $iso    = ConvertTo-UsageResetTime (Get-JsonField $w 'resetsAt')
        $status = 'known'
        $reset  = [datetimeoffset]::MinValue
        if (-not $iso -or -not [datetimeoffset]::TryParse($iso, [ref]$reset)) {
            $iso    = ''
            $status = 'unreadable'
        } elseif ($reset -le $Now) {
            $status = 'rolled'
        }

        $out.Add([pscustomobject]@{
            id          = $id
            percent     = ConvertTo-UsageNumber (Get-JsonField $w 'percentUsed')
            resetsAt    = $iso
            resetStatus = $status
            applies     = ($status -ne 'rolled')
        })
    }
    , $out.ToArray()
}

# What could not be read off the account's windows, as a sentence to sit beside the percentage.
#
# THE POINT IS THAT DISCARDED EVIDENCE IS NEVER SILENT. This module already splits an absent
# `windows` field from an empty one so a renamed field cannot read as a settled fact; the same rule
# has to hold one level down, or a window the reader threw away leaves the answer looking whole. A
# reading that names what it could not use is one a person can judge; one that quietly drops it is
# not, and that is the defect this whole feature exists to prevent.
function Format-UsageWindowNotes {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][array]$Windows)

    $notes = @()
    foreach ($w in $Windows) {
        $named = Format-UsageWindowName -Id $w.id
        if (-not $w.applies) {
            $notes += "$named was left out because its own reset time has already passed, so that " +
                      'window is over'
            continue
        }
        if ($w.resetStatus -eq 'unreadable') {
            $notes += "$named carries no reset time this could read, so its percentage still counts " +
                      'and only when it clears is unknown'
        }
        if ($null -eq $w.percent) {
            $notes += "$named reported a used percentage this could not read as a number"
        }
    }
    if ($notes.Count -eq 0) { return '' }
    # Each note is its own sentence following a full stop, so it opens in upper case. The window
    # names are written for the middle of a sentence - "the session window" - and reading one back
    # as the start of one is the only place that shows.
    ' ' + (@($notes | ForEach-Object { $_.Substring(0, 1).ToUpper() + $_.Substring(1) }) -join '. ') + '.'
}

# The applicable window NEAREST ITS THRESHOLD, which is the one a dispatch is really bounded by.
#
# Not the session window alone. An overnight run sits comfortably inside a five-hour window and
# still burns the week, and the weekly window resets in days rather than hours, so tripping that one
# costs far more. Both are considered and the worse of them decides.
function Select-DrivingUsageWindow {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][array]$Applicable)

    @($Applicable | Where-Object { $null -ne $_.percent } |
        Sort-Object -Property percent -Descending) | Select-Object -First 1
}

# How much of the current usage window is spent.
#
# .status        has-usage | no-usage | unknown
# .signal        what settled it
# .percent       the percentage used, or $null - NEVER 0 as a stand-in for "not known", and set
#                ONLY on a current reading. A stale one leaves it unset and fills floorPercent.
# .floorPercent  a lower bound from a cached reading, or $null. Never an answer; see below.
# .stale         whether the tool called its own reading stale
# .detail        one line naming the evidence, written to be read to a person
# .resetsAt      when the driving window resets, ISO, or '' where that could not be read
# .window        which window the percentage came from, or ''
# .account       which account the reading belongs to, or '' where that could not be read
# .generatedAt   when the tool generated the answer, ISO, or ''
# .schemaVersion the schema the tool stamped its answer with, as it wrote it, or ''
# .takenAt       when this reading was taken, ISO
#
# THE SCHEMA VERSION IS RECORDED AND NEVER REFUSED ON. It is what tells a later reader whether an
# answer this could not make sense of came from a format that has moved on, so it is carried on the
# reading and named in the detail of every answer that is not a percentage. Refusing an unfamiliar
# version would be the opposite mistake: a compatible bump would take the reader out on a machine
# where it was working the day before, and this guard fails open by design.
#
# WHICH WINDOW, AND WHY IT IS THE WORST OF ONLY SOME OF THEM. An account reports several windows and
# they do not all bound the same thing. The session and weekly windows both bound every dispatch, so
# the threshold is taken across BOTH and the one nearest its limit decides - an overnight run sits
# comfortably inside a five-hour window while burning the week, and the weekly one resets in days
# rather than hours, so tripping it costs far more. A single model's window and a spend cap bound
# something else and are excluded, as is an account window whose reset has already passed - that
# pool has rolled. A missing or unreadable reset time costs only the claim about when the window
# clears, never the percentage. Get-AccountUsageWindows owns those rules and the measured trap
# behind them, and nothing it drops is dropped in silence.
#
# A STALE READING NEVER BECOMES A PERCENTAGE. It becomes a floor, and the floor is the only thing
# guarding a dispatch while the tool's live fetch is rate limited - which, measured on this machine,
# is most of the time. The comment at the stale branch below owns that in full.
function Get-UsageWindow {
    [CmdletBinding()]
    param([int]$TimeoutSeconds = $script:DefaultTimeoutSeconds)

    $result = [ordered]@{
        status        = 'unknown'
        signal        = ''
        percent       = $null
        floorPercent  = $null
        stale         = $false
        detail        = ''
        resetsAt      = ''
        window        = ''
        account       = (Get-ActiveAccountName)
        generatedAt   = ''
        schemaVersion = ''
        takenAt       = (Get-Date).ToUniversalTime().ToString('o')
    }
    $finish = {
        param($status, $signal, $detail)
        $result.status = $status
        $result.signal = $signal
        $result.detail = $detail
        [pscustomobject]$result
    }

    # NOTHING BELOW MAY LEAVE THIS FUNCTION AS AN EXCEPTION, and the try is what guarantees it
    # rather than each read being individually careful. Dispatch-Worker.ps1 calls this under
    # $ErrorActionPreference = 'Stop' as the first check of a dispatch, so a throw would stop the
    # dispatch dead - turning a guard that was written to fail OPEN into the hard block the whole
    # design rules out. A reading nobody could take is `unknown`, whatever went wrong taking it.
    try {
        $r = Invoke-QuotaAxi -Arguments @('--provider', 'claude', '--json') -TimeoutSeconds $TimeoutSeconds
        if (-not $r.ok) {
            return & $finish 'unknown' 'lookup-failed' `
                "How much of the usage window is spent could not be established: $($r.error)"
        }

        $json = $null
        try { $json = $r.value | ConvertFrom-Json } catch {
            return & $finish 'unknown' 'unreadable-answer' `
                ('quota-axi answered with something that is not the JSON report this reads ' +
                 "($($_.Exception.Message)), so the usage window is not known.")
        }

        # Recorded from the answer, never compared against a version this was written for. The note
        # rides along on every answer below that is not a percentage, which are exactly the ones a
        # later reader would want to know the schema for.
        $result.schemaVersion = "$(Get-JsonField $json 'schemaVersion')".Trim()
        # When the tool generated this answer, carried on every reading so a cached one is visibly
        # cached rather than presented as a measurement taken now.
        $result.generatedAt = ConvertTo-UsageResetTime (Get-JsonField $json 'generatedAt')
        $schema = if ($result.schemaVersion) {
            " The answer was stamped schema version $($result.schemaVersion)."
        } else {
            ' The answer carried no schema version.'
        }

        $providers = ConvertTo-JsonList (Get-JsonField $json 'providers')
        $claude = @($providers | Where-Object { (Get-JsonField $_ 'provider') -eq 'claude' }) |
                  Select-Object -First 1
        if (-not $claude) {
            return & $finish 'unknown' 'no-provider' `
                ('quota-axi answered without reporting on the Claude account, so how much of the ' +
                 'usage window is spent was not established.' + $schema)
        }

        # Read here and acted on further down, once the windows have been parsed - because a stale
        # reading still yields a floor, and the floor comes out of those same windows.
        $state = Get-JsonField $claude 'state'
        $result.stale = ($true -eq (Get-JsonField $state 'stale'))

        # THREE FACTS, NOT ONE, AND ONLY ONE OF THEM SWITCHES THE GUARD OFF QUIETLY. An empty list
        # is the tool saying there are no windows here, which is a settled fact about this machine
        # and rightly draws no warning on a dispatch. A field the tool never wrote, and one it wrote
        # as null, are the tool not answering - and a renamed field would otherwise read as that
        # settled fact, leaving every dispatch unguarded with nothing said to anybody. Not knowing
        # is `unknown`, which is the one answer of the three that warns.
        $windowsValue = Get-JsonField $claude 'windows'
        if (-not (Test-JsonField $claude 'windows')) {
            return & $finish 'unknown' 'no-windows-field' `
                ('quota-axi answered about the Claude account without saying anything about usage ' +
                 'windows at all, so how much of the window is spent was not established - the ' +
                 'field this reads them from was not there.' + $schema)
        }
        if ($null -eq $windowsValue) {
            return & $finish 'unknown' 'windows-not-reported' `
                ('quota-axi reported the Claude account with its usage windows left empty rather ' +
                 'than listed, so it did not say what they are and how much of the window is ' +
                 'spent is not known.' + $schema)
        }

        $windows = ConvertTo-JsonList $windowsValue
        if ($windows.Count -eq 0) {
            return & $finish 'no-usage' 'no-windows' `
                ('quota-axi reports the Claude account with no usage windows at all, so there is ' +
                 'no window percentage to watch on this machine.' + $schema)
        }

        # The account's own windows, looked up BY ID and never by position, each annotated with what
        # could be read off it. Get-AccountUsageWindows owns which windows those are and what makes
        # one of them stop applying.
        $present = Get-AccountUsageWindows -Windows $windows

        # An account-level window that IS there and has rolled is a different fact from there being
        # none at all, and the two get different answers. None at all is settled: this account has
        # no session or weekly window and there is nothing here to watch. One that exists and
        # describes a window already over is something the reader has to say out loud.
        if ($present.Count -eq 0) {
            return & $finish 'no-usage' 'no-account-windows' `
                ('quota-axi reports the Claude account with no session or weekly window, so there ' +
                 'is no window percentage to watch on this machine.' + $schema)
        }

        # Every note this reading could carry, computed once from every window present rather than
        # only from the ones that survived - a window that was dropped is exactly the one whose
        # absence has to be said out loud.
        $notes      = Format-UsageWindowNotes -Windows $present
        $applicable = @($present | Where-Object { $_.applies })
        if ($applicable.Count -eq 0) {
            return & $finish 'unknown' 'no-applicable-window' `
                ('quota-axi reported the Claude account''s windows and every one of them has ' +
                 'already reset, so none of them describes a window that is currently running and ' +
                 'how much is spent is not known.' + $notes + $schema)
        }

        $driving = Select-DrivingUsageWindow -Applicable $applicable
        if (-not $driving) {
            return & $finish 'unknown' 'no-percentage' `
                ('quota-axi reported the Claude account''s windows and a used percentage could not ' +
                 'be read from any of them, so the usage window is not known.' + $notes + $schema)
        }

        $result.window   = $driving.id
        $result.resetsAt = $driving.resetsAt
        $named = Format-UsageWindowName -Id $driving.id
        $when  = Format-UsageResetTime -IsoTime $driving.resetsAt

        # A STALE READING IS AN UNKNOWN, NEVER A NUMBER - and this is the failure that put a figure
        # of 10 percent in front of the King when the true one was 42. The tool's live fetch had
        # been rate limited and it answered from a cache taken before four workers ran for ninety
        # minutes. Reporting that as current is precisely the "stale value presented as current"
        # this module refuses, so `percent` stays unset and the status is `unknown`.
        #
        # THE NUMBER IS STILL A FLOOR, AND THE FLOOR IS WORTH KEEPING. Consumption never falls
        # inside a window, so a cached 10 percent means at least 10 percent is spent. It is carried
        # as `floorPercent` - a lower bound the dispatch refusal may still act on - and nothing ever
        # presents it as the answer.
        #
        # COMPARED RAW, SHOWN ROUNDED DOWN, and the two are not in tension. The guard's safety is
        # carried entirely by the comparison, which the dispatch refusal makes against the exact
        # double and never against the digits. What is shown is a different job: "at least" is a
        # claim about the evidence, and at a true 89.2 the sentence "at least 90 percent is spent"
        # asserts more than the reading supports. Rounding a lower bound DOWN is what keeps "at
        # least" true, so every rendering of a floor - here, the dispatch refusal and the pulse -
        # floors it, and no rendering ever overstates what was actually measured.
        #
        # The reset time rides along on this one as well as on a measured reading. This sentence is
        # pasted straight into the refusal the user acts on, and "when does it clear" is the one
        # thing wanted next after being told the dispatch was refused.
        if ($result.stale) {
            $result.floorPercent = $driving.percent
            $why = "$(Get-JsonField $state 'error')".Trim()
            $because = if ($why) { " Its own last attempt failed: $why." } else { '' }
            $age = if ($result.generatedAt) { " The cached answer was generated at $($result.generatedAt)." }
                   else { '' }
            return & $finish 'unknown' 'stale-reading' `
                ('quota-axi reports its own Claude reading as stale, so it describes an earlier ' +
                 'moment rather than this one and no current percentage can be given. At least ' +
                 "$([Math]::Floor($driving.percent)) percent of $named is spent, which is a floor " +
                 "rather than a reading." + $when + $notes + $because + $age + $schema)
        }

        $others = @($applicable | Where-Object { $_.id -ne $driving.id -and $null -ne $_.percent })
        $beside = if ($others.Count -gt 0) {
            ' It is the nearest its limit of ' +
            (@(@($driving) + $others | ForEach-Object {
                "$(Format-UsageWindowName -Id $_.id) at $([Math]::Round($_.percent, 1)) percent"
            }) -join ' and ') + '.'
        } else { '' }

        $result.percent = $driving.percent
        & $finish 'has-usage' 'driving-window' `
            ("$([Math]::Round($driving.percent, 1)) percent of $named is spent." + $when + $beside +
             $notes)
    } catch {
        # Reset rather than reported as read. A field set on the way to a throw is a half-finished
        # answer, and a percentage carried out of a reading that failed is the fabrication this
        # module exists to refuse.
        $result.percent  = $null
        $result.window   = ''
        $result.resetsAt = ''
        & $finish 'unknown' 'lookup-failed' `
            ('How much of the usage window is spent could not be established: quota-axi answered ' +
             "with something this could not read ($($_.Exception.Message)).")
    }
}

# What the fleet is doing, taken from the readers that already join intent to liveness rather than
# from a second inventory of this module's own. Get-CrewStatus.ps1 owns that join; this is only the
# seam that lets the pulse be exercised without a herdr server.
function Get-UsageFleet {
    [CmdletBinding()]
    param([string]$CrewStatePath = '')

    # INVOKED IN A CHILD SCOPE WITH STRICT MODE OFF, the same way bin\Get-SurveySnapshot.ps1 calls
    # this very script and for the same reason. A script run with `&` inherits the caller's strict
    # mode, this module runs under Latest, and Get-CrewStatus.ps1 reads fields that are optional in
    # practice - a crew record written by an older version with no `stage`, a herdr agent with no
    # `title`. Under Latest each of those is an exception instead of a $null, and one such record
    # would take the pulse out for the whole session: the tick throws, the loop's containment turns
    # it into a warning, and it does the same again every interval from then on.
    $script = Join-Path $PSScriptRoot 'Get-CrewStatus.ps1'
    if ($CrewStatePath) {
        @(& { Set-StrictMode -Off; & $script -StatePath $CrewStatePath })
    } else {
        @(& { Set-StrictMode -Off; & $script })
    }
}

# What one live worker is doing, in the King's own words rather than in a stage label.
#
# The map is a closed set, which is the whole reason the phrase comes from the stage and not from
# the worker's screen: a pane title is free text a person never wrote to a schema, and reading a
# phase out of it is the open-ended scan standing criterion 12 forbids. A stage this does not
# recognise says so for that worker rather than being guessed at or quietly dropped.
function Get-WorkerPhrase {
    [CmdletBinding()]
    param($Worker)

    if ((Get-JsonField $Worker 'agentState') -eq 'blocked') { return 'stuck on a question' }

    switch ("$(Get-JsonField $Worker 'stage')") {
        'dispatched'   { return 'starting' }
        'implementing' { return 'working' }
        'gating'       { return 'running checks' }
        'ready'        { return 'waiting on you' }
        'landed'       { return 'merged' }
        'failed'       { return 'stopped after a failure' }
    }
    'phase not known'
}

# What to call a worker out loud. Its ticket is the King's noun for the work; the internal id is a
# last resort and only where there is nothing else to say.
function Get-WorkerLabel {
    [CmdletBinding()]
    param($Worker)

    foreach ($field in @('ticket', 'id')) {
        $v = "$(Get-JsonField $Worker $field)".Trim()
        if ($v) { return $v }
    }
    'a worker'
}

# THE ONE ROUNDING OF A PERCENTAGE IN THIS MODULE, so the number the pulse prints and the band that
# decides whether it prints at all cannot disagree. They did: the band floored the raw percentage
# while the line rounded it, so 69.6 and 70.2 fell in different bands and printed the identical
# "70% used" - the same sentence twice, for a change the reader could not see.
function Get-UsagePercentShown {
    [CmdletBinding()]
    param($Percent)

    $n = ConvertTo-UsageNumber $Percent
    if ($null -eq $n) { return $null }
    [int][Math]::Round($n)
}

# One line. ONE LINE, whatever is live - the tail becomes a count rather than a second line.
function Format-UsagePulse {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Reading,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Live
    )

    # What the number is about, in the few words a one-line pulse has room for: which window is
    # driving it, and which account it belongs to. The account is there because the reading silently
    # follows whichever account is active, so a percentage with no name on it is a percentage the
    # reader cannot place.
    # Every field of the reading is taken through Get-JsonField rather than as a property. This
    # module runs under StrictMode Latest, the reading arrives from a caller, and a reading built
    # before a field existed would otherwise throw here instead of simply not having it.
    $window  = "$(Get-JsonField $Reading 'window')"
    $account = "$(Get-JsonField $Reading 'account')"
    $status  = "$(Get-JsonField $Reading 'status')"

    $notes = @()
    if ($window)  { $notes += (Format-UsageWindowShortName -Id $window) }
    if ($account) { $notes += $account }
    $suffix = if ($notes.Count -gt 0) { ' (' + ($notes -join ', ') + ')' } else { '' }

    $shown = Get-UsagePercentShown (Get-JsonField $Reading 'percent')
    # A floor is said as "at least" and rounded DOWN, which is what keeps that phrase true - at a
    # true 41.2 the line "at least 42% used" claims more than the reading supports. Printing it as a
    # bare percentage is the thing forbidden here: a bare percentage reads as a measurement, which is
    # exactly how a cached 10 was taken for a current one. No guard rests on these digits.
    $floor = ConvertTo-UsageNumber (Get-JsonField $Reading 'floorPercent')

    $head = if ($status -eq 'has-usage' -and $null -ne $shown) {
        "$shown% used$suffix"
    } elseif ($null -ne $floor) {
        "at least $([int][Math]::Floor($floor))% used" +
        $(if ($notes.Count -gt 0) { ' (stale, ' + ($notes -join ', ') + ')' } else { ' (stale)' })
    } elseif ($status -eq 'no-usage') {
        'usage not reported here'
    } else {
        'usage unknown'
    }

    if ($Live.Count -eq 0) { return "$head - nothing running" }

    $named = @($Live | Select-Object -First $script:PulseNameLimit | ForEach-Object {
        "$(Get-WorkerLabel $_) $(Get-WorkerPhrase $_)"
    })
    $rest = $Live.Count - $named.Count
    $tail = if ($rest -gt 0) { ", +$rest more" } else { '' }

    $line = "$head - $($Live.Count) running: " + ($named -join ', ') + $tail
    # Composed from a worker's own ticket, which is text somebody typed. A newline in one of them
    # would break the single-line contract at the one moment nobody is watching.
    ($line -replace '[\r\n]+', ' ').Trim()
}

# The pulse: the percentage, how many workers are running, and a few words on each - or NOTHING.
#
# NOTHING IS THE COMMON CASE AND IT IS THE POINT. A line every interval regardless is the progress
# narration CLAUDE.md hard rule 6 forbids, and the King asked for this so he would not have to ask
# for updates - not so he would get a heartbeat. So it speaks only when the fleet has moved or the
# percentage has crossed into a new band, and the record of what it last said is what it compares
# against. Ticks in between update the last reading and say nothing.
function Get-UsagePulse {
    [CmdletBinding()]
    param([string]$CrewStatePath = '')

    $reading = Get-UsageWindow
    $fleet   = @(Get-UsageFleet -CrewStatePath $CrewStatePath)
    $live    = @($fleet | Where-Object { $true -eq (Get-JsonField $_ 'live') })

    # The band, so a percentage that ticks from 61 to 62 does not speak while one that crosses 70
    # does. An unknown reading is its own band, so losing the number is itself a change worth one
    # line rather than a silence indistinguishable from nothing happening.
    #
    # Banded on the number the line will print, not on the raw percentage, so the two can never
    # part company and speak for a change the reader cannot see.
    # Read the same tolerant way Format-UsagePulse does, and for the same reason.
    $status   = "$(Get-JsonField $reading 'status')"
    $window   = "$(Get-JsonField $reading 'window')"
    $account  = "$(Get-JsonField $reading 'account')"
    $shown = Get-UsagePercentShown (Get-JsonField $reading 'percent')
    $floor = ConvertTo-UsageNumber (Get-JsonField $reading 'floorPercent')
    $band = if ($status -eq 'has-usage' -and $null -ne $shown) {
        "b$([int][Math]::Floor($shown / 10))"
    } elseif ($null -ne $floor) {
        # Banded separately from a real reading, so the line changes when a measurement decays into
        # a floor even though the number itself has not moved. Banded on the number the line will
        # print, floored the same way, so the band and the line can never part company.
        "f$([int][Math]::Floor([Math]::Floor($floor) / 10))"
    } else {
        $status
    }
    # Which window is driving it counts as a change too: the same 62 percent, session one tick and
    # week the next, is a different fact about what is about to run out.
    $band  = "$band/$window"
    $shape = (@($live | ForEach-Object { "$(Get-WorkerLabel $_)=$(Get-WorkerPhrase $_)" }) -join '|')

    # A CHANGE OF ACCOUNT VOIDS THE COMPARISON RATHER THAN PASSING IT. The reading follows whichever
    # account is active, so two ticks either side of a switch are percentages of two different pools
    # - and a silence, which is what a matching band and shape produce, would say they were the same
    # quota sitting still. Comparing only within one account is what stops that.
    $spoken = $script:LastSpoken
    if ($spoken -and $spoken.account -eq $account -and
        $spoken.band -eq $band -and $spoken.shape -eq $shape) { return }

    $line = Format-UsagePulse -Reading $reading -Live $live
    $script:LastSpoken = @{
        band    = $band
        shape   = $shape
        account = $account
        line    = $line
        at      = (Get-Date).ToUniversalTime().ToString('o')
    }
    $line
}

# The pulse on a timer, which is what the Hand arms as a background job. `vigil` owns when it is
# armed and what the Hand does with a line; this owns only the cadence.
#
# The first tick speaks immediately and every later one waits out the interval, so arming it costs
# nothing and a -Count of 1 never sleeps. -Count 0 runs until the job is stopped, which is what the
# documented job uses.
function Watch-UsagePulse {
    [CmdletBinding()]
    param(
        [double]$IntervalMinutes = $script:DefaultPulseIntervalMinutes,
        [int]$Count = 0,
        [string]$CrewStatePath = ''
    )

    if ($IntervalMinutes -lt 0) { throw "IntervalMinutes cannot be negative; got $IntervalMinutes." }
    if ($Count -lt 0)           { throw "Count cannot be negative; got $Count." }

    # NO INTERVAL AND NO END IS A BUSY LOOP, and this is the one shape of it. The sleep is skipped
    # for an interval of zero, which is right for a bounded run - a test asking for two ticks back
    # to back should not wait - and catastrophic for an unbounded one: every pass starts quota-axi
    # and reads the fleet through herdr, as fast as the machine allows, for the life of the session.
    # It is silent while it does it, because after the first tick nothing has changed and the
    # pulse's normal answer is nothing at all, which the King is taught to read as a pulse that is
    # working. Refused rather than quietly given a cadence nobody asked for.
    if ($Count -eq 0 -and $IntervalMinutes -le 0) {
        throw ("A pulse that runs until it is stopped needs an interval to wait out; got " +
               "$IntervalMinutes. Give -IntervalMinutes a positive number of minutes, or pass " +
               "-Count to bound the run if you want ticks with no wait between them.")
    }

    $i = 0
    while ($Count -eq 0 -or $i -lt $Count) {
        if ($i -gt 0 -and $IntervalMinutes -gt 0) {
            Start-Sleep -Milliseconds ([int]($IntervalMinutes * 60000))
        }
        # ONE BAD TICK COSTS ONE TICK, never the session. This runs as a background job whose
        # normal output is nothing at all, so an exception out of the loop would end the pulse in a
        # way that looks exactly like a healthy quiet interval - and the King would find out by
        # noticing he had heard nothing for hours. crew.json is written without a temp-and-rename,
        # so a tick that reads it mid-write is the ordinary way this happens.
        try {
            Get-UsagePulse -CrewStatePath $CrewStatePath
        } catch {
            Write-Warning ("The usage pulse could not take this reading and will try again next " +
                           "interval: $($_.Exception.Message)")
        }
        $i++
    }
}

Export-ModuleMember -Function Get-QuotaAxiCommandPath, Get-QuotaAxiHint, Invoke-QuotaAxi,
                              ConvertTo-JsonList, Test-JsonField, ConvertTo-UsageNumber,
                              ConvertTo-UsageResetTime, Format-UsageResetTime,
                              Format-UsageWindowName, Format-UsageWindowShortName,
                              Get-ActiveAccountName, Get-AccountUsageWindows,
                              Format-UsageWindowNotes,
                              Select-DrivingUsageWindow, Get-UsageWindow, Get-UsageFleet,
                              Get-WorkerPhrase, Get-WorkerLabel, Format-UsagePulse,
                              Get-UsagePulse, Watch-UsagePulse
