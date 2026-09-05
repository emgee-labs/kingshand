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

Import-Module (Join-Path $PSScriptRoot 'Paths.psm1')

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

# The file's own marker. A write destination that cannot prove it owns the file it is about to
# overwrite refuses, and this is the proof: state\ also holds crew.json, and a mistyped path that
# silently replaced the worker records would lose the fleet.
$script:StateKind = 'kingshand-usage'

# A property off a ConvertFrom-Json object, or $null when it is not there. Under
# Set-StrictMode -Version Latest a missing property throws, and every field below is one the tool
# is allowed to leave out.
function Get-JsonField {
    [CmdletBinding()]
    param($Object, [Parameter(Mandatory)][string]$Name)

    if ($null -eq $Object) { return $null }
    if ($Object -isnot [psobject]) { return $null }
    if ($Object.PSObject.Properties.Name -notcontains $Name) { return $null }
    $Object.$Name
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
function Format-UsageResetTime {
    [CmdletBinding()]
    param([string]$IsoTime)

    if (-not $IsoTime) { return '' }
    $parsed = [datetimeoffset]::MinValue
    if (-not [datetimeoffset]::TryParse($IsoTime, [ref]$parsed)) { return '' }
    ' It resets at ' + $parsed.ToLocalTime().ToString('HH:mm') + ' local time.'
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

# How much of the current usage window is spent.
#
# .status    has-usage | no-usage | unknown
# .signal    what settled it
# .percent   the percentage used, or $null - NEVER 0 as a stand-in for "not known"
# .detail    one line naming the evidence, written to be read to a person
# .resetsAt  when the limiting window resets, ISO, or '' where that could not be read
# .window    which window the percentage came from, or ''
# .takenAt   when this reading was taken, ISO
#
# WHICH WINDOW, AND WHY IT IS NOT THE WORST OF THEM. An account has several windows and they do not
# all bound the same thing: a spend-limit window sitting at 100 percent says nothing about whether
# the next dispatch can run, and taking the worst of the list would refuse every dispatch on this
# machine today. So the tool's own judgement is used - it publishes which windows bound every model
# and what is effectively left across them - and only where it declines to answer that does this
# fall back to the five-hour session window, which is the one the King means by "the window".
function Get-UsageWindow {
    [CmdletBinding()]
    param([int]$TimeoutSeconds = $script:DefaultTimeoutSeconds)

    $result = [ordered]@{
        status   = 'unknown'
        signal   = ''
        percent  = $null
        detail   = ''
        resetsAt = ''
        window   = ''
        takenAt  = (Get-Date).ToUniversalTime().ToString('o')
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

        $providers = ConvertTo-JsonList (Get-JsonField $json 'providers')
        $claude = @($providers | Where-Object { (Get-JsonField $_ 'provider') -eq 'claude' }) |
                  Select-Object -First 1
        if (-not $claude) {
            return & $finish 'unknown' 'no-provider' `
                ('quota-axi answered without reporting on the Claude account, so how much of the ' +
                 'usage window is spent was not established.')
        }

        # A reading the tool itself calls stale is not this window's answer. Presenting it as
        # current is the "stale value presented as current" R-003 rules out, and it is worse than
        # saying nothing: an old low percentage is exactly what would wave through a dispatch near
        # the limit.
        $state = Get-JsonField $claude 'state'
        if ($true -eq (Get-JsonField $state 'stale')) {
            return & $finish 'unknown' 'stale-reading' `
                ('quota-axi reports its own Claude reading as stale, so it describes an earlier ' +
                 'moment rather than this one and no current percentage can be given.')
        }

        $windows = ConvertTo-JsonList (Get-JsonField $claude 'windows')
        if ($windows.Count -eq 0) {
            return & $finish 'no-usage' 'no-windows' `
                ('quota-axi reports the Claude account with no usage windows at all, so there is ' +
                 'no window percentage to watch on this machine.')
        }

        # BY ID, NEVER BY POSITION. The order windows arrive in is the tool's business and it has
        # already changed once; a window looked up by where it sat in the list would read a spend
        # cap as the session window and never say a word about it. A window that is missing or has
        # been renamed comes back as $null here and is treated as not known, which is the whole
        # point of looking it up by name.
        $byId = {
            param($id)
            @($windows | Where-Object { (Get-JsonField $_ 'id') -eq $id }) | Select-Object -First 1
        }

        # The tool's own answer for what bounds every model, which is the question a dispatch is
        # really asking. `boundedBy` names the windows it took into account, so the reader can see
        # for themselves that a spend cap or a single model's window did not decide it.
        $semantics = Get-JsonField $claude 'quotaSemantics'
        # Assigned before it is piped. ConvertTo-JsonList hands its array back through the
        # leading-comma idiom, so piping the call directly would give Where-Object the whole array
        # as one item and match nothing at all.
        $availability = ConvertTo-JsonList (Get-JsonField $semantics 'effectiveAvailability')
        $effective = @($availability | Where-Object { (Get-JsonField $_ 'scope') -eq 'all_models' -and
                                                      (Get-JsonField $_ 'status') -eq 'known' }) |
                     Select-Object -First 1

        $remaining = if ($effective) {
            ConvertTo-UsageNumber (Get-JsonField $effective 'effectivePercentRemaining')
        } else { $null }
        if ($null -ne $remaining) {
            $percent = 100 - $remaining
            # Assigned, then indexed. The same leading-comma idiom means `@(ConvertTo-JsonList ...)`
            # collects ONE item - the inner list - so `[0]` on it hands back the whole list rather
            # than its first id. With a single id the coercion back to a string hides it; with two,
            # the window is looked up under "id1 id2" and never found.
            $ids      = ConvertTo-JsonList (Get-JsonField $effective 'limitingWindowIds')
            $limiting = if ($ids.Count -gt 0) { "$($ids[0])".Trim() } else { '' }
            $bounded  = ConvertTo-JsonList (Get-JsonField $effective 'boundedBy')
            $w        = if ($limiting) { & $byId $limiting } else { $null }
            $result.percent  = $percent
            $result.window   = $limiting
            $result.resetsAt = ConvertTo-UsageResetTime (Get-JsonField $w 'resetsAt')
            $when   = Format-UsageResetTime -IsoTime $result.resetsAt
            $names  = @($bounded | ForEach-Object { Format-UsageWindowName -Id "$_" })
            $across = if ($names.Count -gt 0) { " across $($names -join ' and ')" } else { '' }
            return & $finish 'has-usage' 'effective-availability' `
                ("$([Math]::Round($percent, 1)) percent of the usage window is spent$across." + $when)
        }

        # The five-hour session window on its own, for a tool that reported windows but would not
        # say what they add up to. Narrower than the answer above and still a real reading.
        $five = & $byId 'five_hour'
        $used = if ($five) { ConvertTo-UsageNumber (Get-JsonField $five 'percentUsed') } else { $null }
        if ($null -ne $used) {
            $result.percent  = $used
            $result.window   = 'five_hour'
            $result.resetsAt = ConvertTo-UsageResetTime (Get-JsonField $five 'resetsAt')
            $when = Format-UsageResetTime -IsoTime $result.resetsAt
            return & $finish 'has-usage' 'five-hour-window' `
                ("$([Math]::Round($used, 1)) percent of the five-hour session window is spent." + $when)
        }

        & $finish 'unknown' 'no-percentage' `
            ('quota-axi reported ' + $windows.Count + ' Claude window(s) and a used percentage ' +
             'could not be read from any of them, so the usage window is not known.')
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

# state\usage.json under this installation's root, unless a caller names another file.
#
# The default is composed here rather than at a parameter default so every caller lands on one
# answer, and so the root comes from Paths.psm1 - the one place that decision is made - rather than
# from a path written out a second time.
function Get-UsageStatePath {
    [CmdletBinding()]
    param([string]$StatePath = '')

    if ($StatePath -and $StatePath.Trim()) { return $StatePath.Trim() }
    Join-Path (Get-KingshandHome) 'state\usage.json'
}

# THE CONSTRAINT ON THE DESTINATION, IN ONE PLACE. state\ is the Hand's own directory and it already
# holds crew.json, which is the record of every dispatched worker. A write here refuses unless the
# file is absent or is one this module wrote - proved by its own `kind` marker and nothing else.
# Refusing costs a message; guessing wrong costs the fleet.
function Assert-UsageStateOwned {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (Test-Path -LiteralPath $Path -PathType Container) {
        throw ("$Path is where the usage record belongs and it is a directory. Move it aside, or " +
               "point the usage record at a file. Nothing was written.")
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }

    $existing = $null
    try { $existing = (Get-Content -LiteralPath $Path -Raw) | ConvertFrom-Json } catch {
        throw ("$Path already exists and is not a usage record this wrote - it could not be read " +
               "as JSON at all ($($_.Exception.Message)). Overwriting it would destroy whatever " +
               "it is. Point the usage record at another file. Nothing was written.")
    }
    if ((Get-JsonField $existing 'kind') -ne $script:StateKind) {
        throw ("$Path already exists and does not carry the '$($script:StateKind)' marker, so it " +
               "belongs to something else - state\crew.json is the file this refusal exists to " +
               "protect. Point the usage record at another file. Nothing was written.")
    }
}

# The record, or a fresh empty one. An absent file is an ordinary state - nothing has pulsed yet -
# and never an error. A file that is there and is not ours is refused rather than read.
function Import-UsageState {
    [CmdletBinding()]
    param([string]$StatePath = '')

    $path = Get-UsageStatePath -StatePath $StatePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return @{ kind = $script:StateKind }
    }
    Assert-UsageStateOwned -Path $path
    (Get-Content -LiteralPath $path -Raw) | ConvertFrom-Json -AsHashtable
}

function Save-UsageState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [string]$StatePath = ''
    )

    $path = Get-UsageStatePath -StatePath $StatePath
    Assert-UsageStateOwned -Path $path

    $State['kind'] = $script:StateKind
    $dir = Split-Path -Parent $path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    $State | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path -Encoding utf8
}

# What the fleet is doing, taken from the readers that already join intent to liveness rather than
# from a second inventory of this module's own. Get-CrewStatus.ps1 owns that join; this is only the
# seam that lets the pulse be exercised without a herdr server.
function Get-UsageFleet {
    [CmdletBinding()]
    param([string]$CrewStatePath = '')

    $script = Join-Path $PSScriptRoot 'Get-CrewStatus.ps1'
    if ($CrewStatePath) { @(& $script -StatePath $CrewStatePath) } else { @(& $script) }
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

# One line. ONE LINE, whatever is live - the tail becomes a count rather than a second line.
function Format-UsagePulse {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Reading,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Live
    )

    $head = if ($Reading.status -eq 'has-usage' -and $null -ne $Reading.percent) {
        "$([int][Math]::Round([double]$Reading.percent))% used"
    } elseif ($Reading.status -eq 'no-usage') {
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
    param(
        [string]$StatePath = '',
        [string]$CrewStatePath = ''
    )

    $reading = Get-UsageWindow
    $fleet   = @(Get-UsageFleet -CrewStatePath $CrewStatePath)
    $live    = @($fleet | Where-Object { $true -eq (Get-JsonField $_ 'live') })

    # The band, so a percentage that ticks from 61 to 62 does not speak while one that crosses 70
    # does. An unknown reading is its own band, so losing the number is itself a change worth one
    # line rather than a silence indistinguishable from nothing happening.
    $band = if ($reading.status -eq 'has-usage' -and $null -ne $reading.percent) {
        "b$([int][Math]::Floor([double]$reading.percent / 10))"
    } else {
        $reading.status
    }
    $shape = (@($live | ForEach-Object { "$(Get-WorkerLabel $_)=$(Get-WorkerPhrase $_)" }) -join '|')

    $state = Import-UsageState -StatePath $StatePath
    $state['lastReading'] = @{
        status   = $reading.status
        signal   = $reading.signal
        percent  = $reading.percent
        resetsAt = $reading.resetsAt
        window   = $reading.window
        takenAt  = $reading.takenAt
    }

    $spoken = if ($state.ContainsKey('lastSpoken')) { $state['lastSpoken'] } else { $null }
    $sameBand  = $spoken -and "$(Get-JsonField ([pscustomobject]$spoken) 'band')"  -eq $band
    $sameShape = $spoken -and "$(Get-JsonField ([pscustomobject]$spoken) 'shape')" -eq $shape
    if ($sameBand -and $sameShape) {
        Save-UsageState -State $state -StatePath $StatePath
        return
    }

    $line = Format-UsagePulse -Reading $reading -Live $live
    $state['lastSpoken'] = @{
        band  = $band
        shape = $shape
        line  = $line
        at    = (Get-Date).ToUniversalTime().ToString('o')
    }
    Save-UsageState -State $state -StatePath $StatePath
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
        [string]$StatePath = '',
        [string]$CrewStatePath = ''
    )

    if ($IntervalMinutes -lt 0) { throw "IntervalMinutes cannot be negative; got $IntervalMinutes." }
    if ($Count -lt 0)           { throw "Count cannot be negative; got $Count." }

    # Recorded before the first tick, so the cadence a session is actually running at is on disk
    # rather than only in the job that armed it.
    $state = Import-UsageState -StatePath $StatePath
    $state['pulse'] = @{
        intervalMinutes = $IntervalMinutes
        armedAt         = (Get-Date).ToUniversalTime().ToString('o')
    }
    Save-UsageState -State $state -StatePath $StatePath

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
            Get-UsagePulse -StatePath $StatePath -CrewStatePath $CrewStatePath
        } catch {
            Write-Warning ("The usage pulse could not take this reading and will try again next " +
                           "interval: $($_.Exception.Message)")
        }
        $i++
    }
}

Export-ModuleMember -Function Get-QuotaAxiCommandPath, Get-QuotaAxiHint, Invoke-QuotaAxi,
                              ConvertTo-JsonList, ConvertTo-UsageNumber,
                              ConvertTo-UsageResetTime, Format-UsageResetTime,
                              Format-UsageWindowName, Get-UsageWindow, Get-UsageStatePath,
                              Import-UsageState, Save-UsageState, Get-UsageFleet,
                              Get-WorkerPhrase, Get-WorkerLabel, Format-UsagePulse,
                              Get-UsagePulse, Watch-UsagePulse
