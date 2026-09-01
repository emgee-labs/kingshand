#Requires -Version 7.0
Set-StrictMode -Version Latest

# The only place in kingshand that knows herdr's command line.
#
# Everything above this module speaks in workers, panes and states; nothing above it composes a
# herdr argument list. That boundary is the point: herdr replaced `claude --bg` once, and the
# next spawn layer will replace herdr, so the surface that has to be rewritten is kept to one
# file rather than scattered across four scripts and three skills the way `claude agents --json`
# was.
#
# Every non-obvious rule below was observed on this machine against herdr 0.8.2 (protocol 20),
# not read from the documentation. Where the two disagree the observation wins and says so.

$script:HerdrTimeoutMs = 240000

# NOT -Force - a module never forces a nested import. The rule and the failure it prevents (first
# observed here, against this edge) are in the `statute` skill's style rules. At module load rather
# than inside a function, so it happens once and not on every path lookup.
Import-Module (Join-Path $PSScriptRoot 'Paths.psm1')

# The bundled herdr binary, or $null when it is not installed.
#
# `tools\` is gitignored, so herdr is fetched by the installer rather than vendored - an 8.4 MB
# binary does not belong in a repo people clone. A herdr already on PATH is honoured first so a
# user who manages their own install is not forced into a second copy.
function Get-HerdrCommandPath {
    [CmdletBinding()]
    param()

    $onPath = Get-Command 'herdr' -CommandType Application -ErrorAction SilentlyContinue |
              Select-Object -First 1
    if ($onPath -and $onPath.Source) { return $onPath.Source }

    $bundled = Join-Path (Get-KingshandHome) 'tools\herdr\herdr.exe'
    if (Test-Path -LiteralPath $bundled -PathType Leaf) { return $bundled }

    $null
}

function Get-HerdrCommandHint {
    [CmdletBinding()]
    param()

    'herdr was not found. Run install.ps1 -InstallMissing, which downloads herdr 0.8.2 into ' +
    'tools\herdr and verifies its SHA-256 before extracting. Dispatch cannot spawn or steer a ' +
    'worker without it.'
}

# herdr's agent names are far narrower than kingshand's ticket ids, and the CLI rejects rather
# than normalising: `agent start T-9001` fails with invalid_agent_name. The rule it enforces is
# `^[a-z][a-z0-9_-]{0,31}$`, so an uppercase ticket - which is the ordinary shape - is refused.
#
# Normalising here rather than at each call site keeps the mapping single-valued: crew.json
# stores the kingshand id, this is only what herdr is told.
#
# Normalisation that merely discards characters is not safe here. Stripping a leading digit maps
# `9lives` and `lives` to the same name, and truncating at 32 maps any two ids sharing a long
# prefix to the same name - and two live workers under one herdr name means a prompt meant for
# one lands in the other. So whenever the name is not a clean pass-through, a short digest of the
# ORIGINAL id is appended, which keeps distinct ids distinct.
function ConvertTo-HerdrAgentName {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    $clean = $Name.ToLowerInvariant() -replace '[^a-z0-9_-]', '-'
    $lead  = $clean -replace '^[^a-z]+', ''
    if (-not ($lead -replace '[-_]', '')) {
        throw "Ticket '$Name' has no letter in it, so it cannot name a herdr agent."
    }

    if ($lead -eq $clean -and $clean.Length -le 32) { return $clean.TrimEnd('-', '_') }

    # Collision-proofing, not prettiness: 6 hex characters of SHA-256 over the original id.
    $bytes  = [Text.Encoding]::UTF8.GetBytes($Name)
    $digest = [BitConverter]::ToString(
        [Security.Cryptography.SHA256]::HashData($bytes)).Replace('-', '').Substring(0, 6).ToLowerInvariant()

    $stem = $lead.TrimEnd('-', '_')
    if ($stem.Length -gt 25) { $stem = $stem.Substring(0, 25).TrimEnd('-', '_') }
    "$stem-$digest"
}

# Runs herdr and returns its parsed JSON result, or throws with herdr's own error code.
#
# The CLI contract, confirmed: results and errors are both JSON, errors land on stderr with exit
# status 1, and a syntax error exits 2. `agent start` is the exception that matters - it can exit
# 1 while still having registered the agent, so callers that care must re-read rather than trust
# the exit status.
function Invoke-Herdr {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$AllowError
    )

    $exe = Get-HerdrCommandPath
    if (-not $exe) { throw (Get-HerdrCommandHint) }

    $raw = & $exe @Arguments 2>&1
    $text = ($raw | Out-String).Trim()
    if (-not $text) { return $null }

    $parsed = $null
    try { $parsed = $text | ConvertFrom-Json } catch { }

    if ($parsed -and $parsed.PSObject.Properties.Name -contains 'error') {
        if ($AllowError) { return $parsed }
        throw "herdr $($Arguments[0]) $($Arguments[1]): $($parsed.error.code) - $($parsed.error.message)"
    }

    if ($parsed -and $parsed.PSObject.Properties.Name -contains 'result') { return $parsed.result }
    $parsed
}

function Test-HerdrServer {
    [CmdletBinding()]
    param()

    $exe = Get-HerdrCommandPath
    if (-not $exe) { return $false }
    $out = (& $exe status 2>&1 | Out-String)
    # `status` is the one command that answers in YAML rather than JSON.
    [bool]($out -match '(?ms)server:.*?status:\s*running')
}

# Starts the herdr server if it is not already up, and returns once `status` confirms it.
#
# CLAUDE_CODE_CHILD_SESSION is scrubbed from the server's environment, not just from each pane.
# The Hand is itself a Claude Code session, so every worker herdr launches inherits the marker
# through the server and starts with transcript saving disabled - the worker prints
# "Transcript saving is off" and its session is never written to disk. The earlier trial saw
# this and recorded it as an artefact of how the trial was run; it is not. It is what production
# does, because production is also a Claude Code session spawning the server.
function Start-HerdrServer {
    [CmdletBinding()]
    param([int]$TimeoutSeconds = 30)

    if (Test-HerdrServer) { return }

    $exe = Get-HerdrCommandPath
    if (-not $exe) { throw (Get-HerdrCommandHint) }

    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName        = $exe
    $psi.WorkingDirectory = (Split-Path $exe -Parent)
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow  = $true
    $null = $psi.ArgumentList.Add('server')
    $psi.Environment['CLAUDE_CODE_CHILD_SESSION'] = ''
    $null = [Diagnostics.Process]::Start($psi)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        if (Test-HerdrServer) { return }
    }
    throw "herdr server did not report running within $TimeoutSeconds seconds."
}

# A pane at $Cwd, sitting at an interactive shell prompt and ready for `agent start`.
#
# ALWAYS ITS OWN WORKSPACE, never a split of an existing pane. This is not tidiness - it is the
# whole fix for the worst defect this layer has had.
#
# Width is load-bearing. Every way of telling a stuck worker from a busy one - kingshand's screen
# guard and herdr's own manifest rules alike - is a pattern match over the RENDERED terminal, and
# neither can match a UI that never renders. Measured on a real run: two workers dispatched into a
# workspace that already held other panes came out 6 and 3 columns wide, one character per line,
# and both detection paths went blind. The five-hour hang this layer exists to prevent was live
# again and undetectable.
#
# Splitting is what caused it. Each split halves the survivors, so the third worker of a session
# gets a quarter of a screen. Verified both ways afterwards: four workspaces created in a row were
# 93-94 columns each with no degradation, and a real dispatch into one produced a readable worker
# that both herdr and the guard classified correctly when it blocked.
#
# Closing the siblings does not heal it: the layout rectangles update, the terminals inside them do
# not reflow, and a worker that started narrow stays narrow for its whole life. Neither does
# creating a workspace on a server whose layout is already wrecked. The only fix is not to narrow it
# in the first place - and a herdr server that has been splitting needs restarting to recover.
#
# --env is passed here as well as at server start. The server scrub covers panes it launches, but a
# user may already have a herdr server running that kingshand did not start, and that one carries
# whatever environment it inherited.
function New-HerdrPane {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Cwd,
        [string]$Label = 'kingshand'
    )

    $r = Invoke-Herdr -Arguments @(
        'workspace', 'create', '--cwd', $Cwd, '--label', $Label, '--no-focus',
        '--env', 'CLAUDE_CODE_CHILD_SESSION='
    )
    $r.root_pane.pane_id
}

# True when a worker's terminal is wide enough for the screen guard to work on it.
#
# The guard matches phrases like "Enter to select". A pane too narrow to render one of them cannot
# be read, and a read that cannot succeed must not be reported as "no prompt found" - that is the
# difference between "this worker is fine" and "I cannot tell". Callers that treat a false from
# Test-HerdrAgentAwaitingInput as proof of health need to know which one they have.
function Test-HerdrAgentReadable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [int]$MinimumColumns = 40
    )

    $agentName = ConvertTo-HerdrAgentName -Name $Name
    $exe = Get-HerdrCommandPath
    if (-not $exe) { throw (Get-HerdrCommandHint) }

    $screen = (& $exe agent read $agentName --source visible 2>&1 | Out-String)
    if (-not $screen) { return $false }

    $widest = 0
    foreach ($line in ($screen -split "`n")) {
        $len = $line.TrimEnd().Length
        if ($len -gt $widest) { $widest = $len }
    }
    $widest -ge $MinimumColumns
}

# Launches Claude Code in an existing pane and returns once it is interactive.
#
# NO AGENT ARGUMENTS ARE PASSED, and none can be. herdr accepts `agent start <name> ... -- <args>`
# and it is broken on Windows for claude: with arguments herdr composes
# `Start-Process -FilePath claude -ArgumentList '...' -NoNewWindow -Wait` inside the pane, and
# `claude` resolves to a .ps1, so it dies with "%1 is not a valid Win32 application" - the same
# defect Paths.psm1 exists to work around. Without arguments herdr runs `& claude`, which works.
#
# So --permission-mode and --add-dir cannot be passed here. They move into the worktree's
# settings.local.json instead; see ClaudeWorkspace.psm1, which is not optional for a worker to
# function unattended.
#
# `agent start` can exit non-zero and still have registered the agent - a fresh directory stops
# at Claude Code's folder-trust prompt and herdr correctly reports agent_not_ready while the
# agent already exists and is blocked. The caller gets that state back rather than an exception,
# because the fix is to answer or pre-empt the prompt, not to retry the start.
function Start-HerdrAgent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$PaneId,
        [int]$TimeoutMs = $script:HerdrTimeoutMs
    )

    $agentName = ConvertTo-HerdrAgentName -Name $Name
    $r = Invoke-Herdr -AllowError -Arguments @(
        'agent', 'start', $agentName, '--kind', 'claude', '--pane', $PaneId,
        '--timeout', "$TimeoutMs"
    )

    if ($r -and $r.PSObject.Properties.Name -contains 'error') {
        # Re-read rather than trusting the exit status: the agent may be live and merely blocked.
        $live = Get-HerdrAgent -Name $agentName
        if ($live) { return $live }
        throw "herdr agent start: $($r.error.code) - $($r.error.message)"
    }
    $r.agent
}

function Get-HerdrAgent {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    $agentName = ConvertTo-HerdrAgentName -Name $Name
    $r = Invoke-Herdr -AllowError -Arguments @('agent', 'get', $agentName)
    if (-not $r) { return $null }
    if ($r.PSObject.Properties.Name -contains 'error') { return $null }
    $r.agent
}

function Get-HerdrAgents {
    [CmdletBinding()]
    param()

    $r = Invoke-Herdr -AllowError -Arguments @('agent', 'list')
    if (-not $r -or $r.PSObject.Properties.Name -contains 'error') { return , @() }
    , @($r.agents)
}

# Submits a prompt. With -Wait it returns only once the agent has settled, which is what makes
# an armed dispatch wake the Hand instead of a polling loop.
#
# Without -Wait the returned status is STALE and must not be read as progress: `agent prompt`
# returns before the state machine has moved, so an agent that is about to work still reports
# `idle` for a moment afterwards. A caller that submits and then immediately waits for `idle`
# gets an instant false completion. Either use -Wait, or wait for `working` first.
function Send-HerdrPrompt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Text,
        [switch]$Wait,
        [int]$TimeoutMs = $script:HerdrTimeoutMs
    )

    $agentName = ConvertTo-HerdrAgentName -Name $Name
    $args = @('agent', 'prompt', $agentName, $Text)
    if ($Wait) { $args += @('--wait', '--timeout', "$TimeoutMs") }

    $r = Invoke-Herdr -AllowError -Arguments $args
    if ($r -and $r.PSObject.Properties.Name -contains 'error') {
        # agent_blocked is a state, not a fault: the worker is sitting on an interactive prompt
        # and cannot take text until it is answered. Surfacing it as an exception would make
        # every caller catch it, so it comes back as a result the caller can route on.
        if ($r.error.code -eq 'agent_blocked') {
            return [pscustomobject]@{ blocked = $true; error = $r.error.code }
        }
        throw "herdr agent prompt: $($r.error.code) - $($r.error.message)"
    }
    $r.agent
}

# Blocks until the agent reaches one of $Until, or the timeout expires.
#
# With no -Until, herdr matches idle, done or blocked - which is exactly "the worker stopped
# needing to be left alone", and is the right default for waking on completion.
function Wait-HerdrAgent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [string[]]$Until,
        [int]$TimeoutMs = $script:HerdrTimeoutMs
    )

    $agentName = ConvertTo-HerdrAgentName -Name $Name
    $args = @('agent', 'wait', $agentName, '--timeout', "$TimeoutMs")
    foreach ($u in $Until) { $args += @('--until', $u) }

    $r = Invoke-Herdr -AllowError -Arguments $args
    if (-not $r -or $r.PSObject.Properties.Name -contains 'error') { return $null }
    $r.agent
}

# Reads the worker's rendered terminal. This is the replacement for `claude logs <id>`, and it is
# the only way to see a worker's final message: herdr's agent record carries state and a title,
# never content.
function Read-HerdrAgent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [int]$Lines = 40
    )

    $agentName = ConvertTo-HerdrAgentName -Name $Name
    $exe = Get-HerdrCommandPath
    if (-not $exe) { throw (Get-HerdrCommandHint) }
    (& $exe agent read $agentName --source recent-unwrapped --lines $Lines 2>&1 | Out-String)
}

# True when the worker's LIVE screen is showing an interactive prompt waiting on a human.
#
# This exists because herdr's classification failed in the dangerous direction, and the cause turned
# out to be the terminal it was reading. Observed on this machine, herdr 0.8.2 with manifest
# 2026.08.21.1, against a worker sitting on an unanswered AskUserQuestion menu:
#
#   agent explain -> state: idle, rule: live_prompt_box (priority 950)
#                    live_blocked_form (priority 980) evaluated and did NOT match.
#                    EVERY blocked rule failed.
#
# and moments later that same blocked worker read `done` while a genuinely finished worker read
# `idle`. Since `Wait-HerdrAgent` with no -Until matches idle, done or blocked, a worker waiting on
# a question would wake the Hand claiming completion - the original five-hour hang made worse,
# because it is reported as finished rather than merely left silent.
#
# The cause was width, not the manifest. Those panes were 3 to 6 columns wide, rendering one
# character per line, and herdr's rules are regexes over the rendered screen - they cannot match a
# UI that never renders. Re-tested at 94 columns, herdr classified the same blocked worker
# correctly. So this is not "herdr's detection is broken"; it is "detection of any kind needs a
# readable terminal", which is what Test-HerdrAgentReadable below exists to establish.
#
# The screen check stays regardless. One correct classification is not proof across a Claude Code
# UI change, herdr's rules are a network-fetched artifact that can lag one, and a screen read costs
# almost nothing next to a worker silently reported as finished.
#
# The screen is the authority instead, and it is read from the LIVE VIEWPORT only. `recent` and
# `recent-unwrapped` include scrollback, so a worker that answered a menu ten minutes ago still
# has the menu's text in its history and would be read as blocked forever.
#
# Verified to discriminate: on a genuinely blocked worker every phrase below is present in
# `--source visible`, and on a genuinely finished worker none of them is.
$script:AwaitingInputSignatures = @(
    'Enter to select',    # AskUserQuestion and every other selection menu
    'Enter to confirm',   # the FOLDER-TRUST dialog, which uses different wording to the menus
    'Chat about this',    # the standing last option on an AskUserQuestion menu
    'Type something',     # the free-text option on the same menu
    'Do you want to',     # permission prompts, when a worktree is not fully pre-authorised
    'Esc to cancel',      # shared footer of both dialog shapes
    'to navigate'         # the key hint, when the footer renders wide enough to include it
)

function Test-HerdrAgentAwaitingInput {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    $agentName = ConvertTo-HerdrAgentName -Name $Name
    $exe = Get-HerdrCommandPath
    if (-not $exe) { throw (Get-HerdrCommandHint) }

    $screen = (& $exe agent read $agentName --source visible 2>&1 | Out-String)
    if (-not $screen) { return $false }

    foreach ($sig in $script:AwaitingInputSignatures) {
        if ($screen.Contains($sig)) { return $true }
    }
    $false
}

# The state kingshand acts on: herdr's, corrected by the screen.
#
# Nothing downstream should read `agent_status` directly. A worker whose screen is showing a
# prompt is `blocked` whatever herdr calls it, and that correction has to happen in one place or
# it will be forgotten in one of them.
function Get-HerdrAgentState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    $agent = Get-HerdrAgent -Name $Name
    if (-not $agent) { return $null }

    if (Test-HerdrAgentAwaitingInput -Name $Name) { return 'blocked' }
    $agent.agent_status
}

# Waits for a worker to stop, and refuses to call a prompt-sitting worker finished.
#
# `Wait-HerdrAgent` alone is not safe as a completion signal for the reason above. This wraps it:
# when the wait returns, the screen is checked, and a worker that is actually waiting on a human
# comes back as `blocked` no matter what herdr said. A caller that wants the raw herdr behaviour
# can still use Wait-HerdrAgent directly, but nothing in kingshand should.
function Wait-HerdrAgentSettled {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [int]$TimeoutMs = $script:HerdrTimeoutMs
    )

    $agent = Wait-HerdrAgent -Name $Name -TimeoutMs $TimeoutMs
    if (-not $agent) {
        # A timeout and a herdr error are not the same thing, and both arrive here as $null. The
        # worker may still be alive and working, so this reports "not settled" rather than
        # inventing an outcome.
        return [pscustomobject]@{ settled = $false; state = $null; awaitingInput = $false }
    }

    $awaiting = Test-HerdrAgentAwaitingInput -Name $Name
    [pscustomobject]@{
        settled       = $true
        state         = if ($awaiting) { 'blocked' } else { $agent.agent_status }
        awaitingInput = $awaiting
    }
}

# ---------------------------------------------------------------------------------------------
# Progress, which is a different question from liveness.
#
# `Wait-HerdrAgentSettled` above asks whether a worker has stopped. That is the right question for
# waking on completion and it is the wrong question for noticing a worker that has quietly stopped
# getting anywhere. Both failure directions were observed on this machine on 2026-08-31 and
# 2026-09-01: a worker that handed its work to a background pipeline and returned to its prompt read
# `done` within seconds, so the wait fired and reported a completion that had not happened, and on
# the same night a worker whose work was genuinely finished read `working` because stray text was
# sitting in its input box. Neither state word says anything about whether the work is advancing.
#
# THE SIGNAL IS THE WORKER'S OWN SCREEN, NORMALISED. It was chosen over a pipeline's run status and
# over the worktree's git log for one reason: it needs no knowledge of what the worker was sent to
# do. The Hand waits on investigations, audits and plain edits as well as review-gate runs, and a
# watcher that only understands pipelines is blind to every other kind of work. It also subsumes the
# pipeline signal in practice - a review gate prints its own step transitions into the worker's
# terminal, so a step advancing IS a screen change, with nothing here having to know that a pipeline
# exists or which run id is the right one.
#
# Normalisation is what makes the screen usable at all. Claude Code redraws an elapsed timer and a
# token counter every second while it works, so the raw screen is never twice the same and a naive
# hash would report a worker frozen for an hour as making steady progress. Only those volatile
# shapes are removed - durations, token counts, spinner glyphs, trailing space. Digits in general
# are left alone, deliberately: a counter like `142/300` is real progress and must survive. The bias
# that leaves is toward MISSING a stall rather than inventing one, which is the correct direction -
# a false alarm reaching the King is worse than a silent one, and a missed stall is only as bad as
# today.
$script:StallMinutes   = 20
$script:SampleSeconds  = 60

# Durations, token counters and spinner glyphs: everything Claude Code repaints on its own while
# nothing is happening. Each pattern is anchored on its unit so it cannot eat ordinary numbers.
$script:VolatileScreenPatterns = @(
    '\x1b\[[0-9;?]*[a-zA-Z]'                  # ANSI escapes, if the reader ever stops stripping them
    '\b\d+h\s*\d*\s*m\b'                      # 1h 4m
    '\b\d+m\s*\d*\s*s\b'                      # 3m 20s
    '\b\d+(\.\d+)?\s*s\b'                     # 47s
    '\b\d+(\.\d+)?[kKmM]?\s*tokens?\b'        # 1.4k tokens
    '[✦✳✹✻✽∗·∙●○⠀-⣿]'         # spinner glyphs, braille block included
)

# One comparable fingerprint of what is on a worker's screen right now.
#
# .readable is the fail-closed half and it is not a detail: a screen that could not be read is not
# evidence of anything, and a caller that treats an unreadable screen as "unchanged" reports a
# healthy worker as stalled. A pane too narrow to render is the case that produced this - the same
# width defect that blinded the blocked-worker guard.
function Get-HerdrAgentProgressSignal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    $agentName = ConvertTo-HerdrAgentName -Name $Name
    $exe = Get-HerdrCommandPath
    if (-not $exe) { throw (Get-HerdrCommandHint) }

    # The live viewport, for the same reason the blocked guard reads it: scrollback never changes,
    # so a signal taken over `recent` would look static on a worker that is working perfectly.
    $screen = (& $exe agent read $agentName --source visible 2>&1 | Out-String)
    if (-not $screen -or -not $screen.Trim()) {
        return [pscustomobject]@{ readable = $false; signal = ''; lastActivity = '' }
    }

    $text = $screen
    foreach ($p in $script:VolatileScreenPatterns) { $text = $text -replace $p, ' ' }

    $lines = @($text -split "`r?`n" |
               ForEach-Object { ($_ -replace '\s+', ' ').Trim() } |
               Where-Object { $_ })
    $body = $lines -join "`n"

    $digest = if ($body) {
        [BitConverter]::ToString(
            [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($body))
        ).Replace('-', '').Substring(0, 16).ToLowerInvariant()
    } else { '' }

    # The last few meaningful lines, so an escalation can say what the worker was last seen doing
    # rather than only that it stopped. Evidence a person can act on is the whole deliverable of a
    # stall report.
    $tail = if ($lines.Count -gt 3) { $lines[-3..-1] } else { $lines }

    [pscustomobject]@{
        readable     = [bool]$digest
        signal       = $digest
        lastActivity = ($tail -join ' | ')
    }
}

# Waits for a worker to stop, and gives up on it when it stops advancing instead.
#
# This is ADDED BESIDE `Wait-HerdrAgentSettled` and changes nothing about it. That function is still
# correct for what it does and other callers depend on it; this one answers the second question.
#
# It is still an event rather than a poll. herdr's own wait is the blocking primitive - it returns
# the instant the worker settles - and the sample interval is only that wait's timeout, so nothing
# here sleeps and a finished worker still wakes the caller immediately. Sampling is unavoidable for
# the stall half: "nothing happened" is not an event anything can push.
#
# It never recovers anything. A stall is reported with its evidence and the response belongs to
# `rally` - a wrong automatic action on a stalled worker is worse than a late human one.
function Wait-HerdrAgentProgress {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [int]$TimeoutMs = $script:HerdrTimeoutMs,
        [int]$StallMinutes = $script:StallMinutes,
        [int]$SampleSeconds = $script:SampleSeconds
    )

    if ($SampleSeconds -lt 1) { $SampleSeconds = 1 }
    $sliceMs = $SampleSeconds * 1000

    $started    = Get-Date
    $deadline   = $started.AddMilliseconds($TimeoutMs)
    $first      = Get-HerdrAgentProgressSignal -Name $Name
    $signal     = $first.signal
    $activity   = $first.lastActivity
    $readable   = $first.readable
    $lastChange = $started
    $samples    = 1

    # A hard bound on iterations, set to the number of slices the timeout can legitimately hold. It
    # costs nothing in normal use and it is what stops a herdr that is answering instantly with an
    # error from turning this into a spin - which a wait built on someone else's timeout can
    # otherwise become without anyone noticing.
    $maxSamples = [Math]::Ceiling($TimeoutMs / [double]$sliceMs) + 2

    $report = {
        param($settled, $state, $awaiting, $stalled, $reason)
        $now = Get-Date
        [pscustomobject]@{
            settled        = $settled
            state          = $state
            awaitingInput  = $awaiting
            stalled        = $stalled
            reason         = $reason
            quietMinutes   = [Math]::Round(($now - $lastChange).TotalMinutes, 1)
            waitedMinutes  = [Math]::Round(($now - $started).TotalMinutes, 1)
            lastChangeUtc  = $lastChange.ToUniversalTime()
            lastActivity   = $activity
            signalReadable = $readable
            samples        = $samples
            stallMinutes   = $StallMinutes
        }
    }

    while ((Get-Date) -lt $deadline) {
        $remaining = [int]([Math]::Min($sliceMs, ($deadline - (Get-Date)).TotalMilliseconds))
        if ($remaining -lt 1) { break }

        $agent = Wait-HerdrAgent -Name $Name -TimeoutMs $remaining
        if ($agent) {
            $awaiting = Test-HerdrAgentAwaitingInput -Name $Name
            $state    = if ($awaiting) { 'blocked' } else { $agent.agent_status }
            return & $report $true $state $awaiting $false 'settled'
        }

        # Null is a timeout OR a herdr error, and the two are not the same. A worker herdr has never
        # heard of is gone rather than slow, and saying so is what sends the caller to `rally`
        # instead of leaving it waiting on a process that no longer exists.
        if (-not (Get-HerdrAgent -Name $Name)) {
            return & $report $false $null $false $false 'gone'
        }

        $samples++
        if ($samples -gt $maxSamples) {
            return & $report $false $null $false $false 'wait-failed'
        }

        $sample = Get-HerdrAgentProgressSignal -Name $Name
        if (-not $sample.readable) {
            # Fail closed. An unreadable screen is not a still one, so the clock is left where it is
            # and no stall is claimed - the caller is told the watch was blind instead.
            $readable = $false
            continue
        }

        $readable = $true
        $activity = $sample.lastActivity
        if ($sample.signal -ne $signal) {
            $signal     = $sample.signal
            $lastChange = Get-Date
            continue
        }

        if (((Get-Date) - $lastChange).TotalMinutes -ge $StallMinutes) {
            return & $report $false 'working' $false $true 'stalled'
        }
    }

    & $report $false $null $false $false 'timeout'
}

# Answers an interactive prompt one key at a time.
#
# ONE KEY PER CALL, deliberately, with a pause between. `agent send-keys <target> down enter` in
# a single invocation silently selects the WRONG option - the Enter is delivered before the TUI
# has processed the arrow - and it returns success while doing it. That is a wrong answer with no
# error, which is the worst failure shape available, so the batched form is not offered here at
# all.
function Send-HerdrKeys {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string[]]$Keys,
        [int]$DelayMs = 400
    )

    $agentName = ConvertTo-HerdrAgentName -Name $Name
    foreach ($k in $Keys) {
        $null = Invoke-Herdr -Arguments @('agent', 'send-keys', $agentName, $k)
        Start-Sleep -Milliseconds $DelayMs
    }
}

# Ends a worker cleanly and confirms it is gone.
#
# `/exit` rather than a kill, always. A force-killed claude never sends its terminal-mode reset,
# which leaves the pane stuck in Kitty keyboard protocol with bracketed paste on: every later
# keystroke is echoed as literal junk, `agent start` into that pane times out, and no herdr
# command recovers it. The worktree is never harmed - it is only a directory - but the pane must
# then be discarded. So this returns the pane id and whether it is safe to reuse.
function Stop-HerdrAgent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [int]$TimeoutSeconds = 30
    )

    $agentName = ConvertTo-HerdrAgentName -Name $Name
    $agent = Get-HerdrAgent -Name $agentName
    if (-not $agent) { return [pscustomobject]@{ stopped = $true; paneId = $null; paneReusable = $false } }

    $paneId = $agent.pane_id

    # A blocked worker cannot be told anything, including how to leave. Observed: `/exit` sent to a
    # worker sitting on an AskUserQuestion menu is swallowed by the menu rather than executed, and
    # the worker stays up. That matters more than it sounds - a teardown that cannot finish is what
    # makes someone reach for a force-kill, and a force-killed agent leaves its pane permanently
    # unusable. So the prompt is dismissed with a single Escape first.
    #
    # Escape, never Enter: Enter would SELECT whichever option is highlighted, which answers a
    # question on the King's behalf with whatever happened to be first. Escape cancels.
    if (Test-HerdrAgentAwaitingInput -Name $agentName) {
        Send-HerdrKeys -Name $agentName -Keys @('escape')
        Start-Sleep -Milliseconds 800
    }

    $null = Invoke-Herdr -AllowError -Arguments @('agent', 'prompt', $agentName, '/exit')

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        if (-not (Get-HerdrAgent -Name $agentName)) {
            return [pscustomobject]@{ stopped = $true; paneId = $paneId; paneReusable = $true }
        }
    }
    [pscustomobject]@{ stopped = $false; paneId = $paneId; paneReusable = $false }
}

function Remove-HerdrPane {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$PaneId)
    $null = Invoke-Herdr -AllowError -Arguments @('pane', 'close', $PaneId)
}

Export-ModuleMember -Function Get-HerdrCommandPath, Get-HerdrCommandHint, ConvertTo-HerdrAgentName,
                              Invoke-Herdr, Test-HerdrServer, Start-HerdrServer, New-HerdrPane,
                              Start-HerdrAgent, Get-HerdrAgent, Get-HerdrAgents, Send-HerdrPrompt,
                              Wait-HerdrAgent, Read-HerdrAgent, Send-HerdrKeys, Stop-HerdrAgent,
                              Remove-HerdrPane, Test-HerdrAgentAwaitingInput, Get-HerdrAgentState,
                              Wait-HerdrAgentSettled, Test-HerdrAgentReadable,
                              Get-HerdrAgentProgressSignal, Wait-HerdrAgentProgress
