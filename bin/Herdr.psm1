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
    # A worker has no human at its prompt, so a suggestion of what that human should type next has
    # no purpose and only creates the hazard the prompt-box guards above defend against. The
    # environment check is the FIRST branch of the harness's resolver, so this wins over the remote
    # flag and over any setting - and it is preferred to the settings key because that key is
    # written at user scope, so putting it in a worktree's settings.local.json may do nothing at all.
    $psi.Environment['CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION'] = '0'
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
# whatever environment it inherited. The prompt-suggestion variable rides the same route and for
# the same reason; the prompt-box section above owns why it is set at all.
function New-HerdrPane {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Cwd,
        [string]$Label = 'kingshand'
    )

    $r = Invoke-Herdr -Arguments @(
        'workspace', 'create', '--cwd', $Cwd, '--label', $Label, '--no-focus',
        '--env', 'CLAUDE_CODE_CHILD_SESSION=',
        '--env', 'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=0'
    )
    $r.root_pane.pane_id
}

# One read of a worker's LIVE screen, and whether that read actually succeeded.
#
# The success half is the whole reason this exists. `agent read` is invoked with `2>&1`, so herdr's
# own failure - a pane that has gone, a name it no longer knows - arrives as ordinary text on the
# success path. Every caller here then treats that error payload as the worker's screen: it is
# non-empty, so it reads as readable; it is constant, so it fingerprints identically every sample;
# and twenty minutes later the watch reports a stall whose evidence is herdr's error message dressed
# up as what the worker was last seen doing. A failed read is not a screen, and this is the one place
# that says so, because three functions read the same viewport and each would have to remember.
#
# .ok is false for an empty read, a non-zero exit and an error envelope. `$LASTEXITCODE` is unset
# rather than zero when nothing has run in the session, which is not a failure and must not be read
# as one.
function Read-HerdrAgentScreen {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    $agentName = ConvertTo-HerdrAgentName -Name $Name
    $exe = Get-HerdrCommandPath
    if (-not $exe) { throw (Get-HerdrCommandHint) }

    $raw  = & $exe agent read $agentName --source visible 2>&1
    $code = $LASTEXITCODE
    $text = ($raw | Out-String)

    $failed = [pscustomobject]@{ ok = $false; text = '' }

    if ($code) { return $failed }
    if (-not $text -or -not $text.Trim()) { return $failed }

    # herdr answers errors as JSON on stderr, which `2>&1` folds into the text above. A rendered
    # terminal does not parse as an object carrying an `error`, so this discriminates without
    # needing to know herdr's error codes.
    $parsed = $null
    try { $parsed = $text | ConvertFrom-Json } catch { }
    if ($parsed -and $parsed.PSObject.Properties.Name -contains 'error') { return $failed }

    [pscustomobject]@{ ok = $true; text = $text }
}

# ---------------------------------------------------------------------------------------------
# The prompt box, which is the one part of a worker's screen that can hold text nobody here wrote.
#
# Claude Code renders a generated *prompt suggestion* into an idle worker's empty input box between
# turns. It is app state rather than input, so it cannot concatenate onto anything - the first typed
# character displaces it - but a bare Enter ACCEPTS it, and a submission whose text equals the
# suggestion is recorded by the harness as accepted by `enter`. So `Send-HerdrKeys -Keys @('enter')`
# at an idle worker submits a model-generated instruction as though the Hand had written it.
# docs\2026-09-02-prompt-box-safety.md owns why this whole section is shaped the way it is; the
# fuller investigation it came from is deliberately not in this repository.
#
# CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=0 on the pane removes the cause and is set at both places
# below. The guards stay anyway: they also cover a herdr server kingshand did not start, and typing
# over a box the Hand did not fill was a defect before that feature existed.
# ---------------------------------------------------------------------------------------------

# `❯` followed by U+00A0 - a NO-BREAK space, not a plain one - is how the box line is drawn,
# measured off captured screens rather than guessed.
$script:PromptBoxCaret = [char]0x276F
$script:PromptBoxSpace = [char]0x00A0
$script:PromptBoxRule  = [char]0x2502   # the │ the box is drawn inside

# The harness's own placeholder text, which is dim-styled and drawn into an EMPTY box at exactly the
# position box content occupies - so on a rendered screen it is indistinguishable from a suggestion
# by position alone. It is not text an Enter would submit: the underlying value is the empty string,
# so an Enter at one submits nothing. Refusing on one makes a worker unsteerable on a hint the
# harness printed itself, which is the outcome the fail-open reasoning below exists to prevent.
#
# Quoted as Claude Code 2.1.200 emits them, read out of the shipped binary rather than paraphrased.
# THE LIST IS BOUND TO A HARNESS VERSION: a placeholder a later version adds is not on it, falls
# through to the refusal, and `-AllowNonEmptyBox` is the escape hatch until it is added here.
# Refusing an unknown string is the safe direction; letting one through is not.
#
# This is NOT the general rule "the value is empty, so Enter submits nothing". That is false for the
# generated prompt suggestion, which is the whole hazard the guard exists for - its value is empty
# too, and a submission whose text equals it is recorded by the harness as accepted by `enter`. Only
# the three named placeholders are excluded.
$script:PromptBoxPlaceholders = @(
    'Press up to edit queued messages'      # queued commands exist and the hint has shown < 3 times
)

# The two with a variable part: `Message @<name>…` while viewing a teammate, and `Try "<example>"`
# on a fresh session. Anchored on the invariant prefix and suffix, with the variable part required
# to be non-empty so the anchor cannot swallow an arbitrary line that merely opens the same way.
$script:PromptBoxPlaceholderAnchors = @(
    @{ Prefix = 'Message @'; Suffix = [string][char]0x2026 }
    @{ Prefix = 'Try "';     Suffix = '"' }
)

function Test-HerdrPromptBoxPlaceholder {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    if ($script:PromptBoxPlaceholders -contains $Text) { return $true }

    foreach ($a in $script:PromptBoxPlaceholderAnchors) {
        if (-not $Text.StartsWith($a.Prefix)) { continue }
        if (-not $Text.EndsWith($a.Suffix)) { continue }
        if ($Text.Length -le ($a.Prefix.Length + $a.Suffix.Length)) { continue }
        return $true
    }

    $false
}

# What the prompt box on this screen holds, or '' when it is empty or there is no box on it.
#
# ONLY `❯` COUNTS. A worker's own output lines start with a plain `>`, and treating one of those as
# a prompt box would refuse every send to a perfectly healthy worker.
#
# AND ONLY `❯` FOLLOWED BY U+00A0. The caret alone is not a box glyph - Claude Code draws the
# highlighted row of a numbered option menu with the same caret, as `❯ 1. Rewrite the parser`, and
# this returns the first match top-down, so a menu row above the box would win over the box itself.
# The box emits a no-break space after the caret and the menu emits a plain one, which is the only
# thing that separates them on a rendered screen. Anchoring on the pair is what keeps a worker
# blocked on a menu answerable: a bare Enter there is the one route to it, and refusing that Enter
# would leave the worker stuck with nobody able to deliver the answer the King already gave.
#
# AND A KNOWN PLACEHOLDER IS AN EMPTY BOX. The harness draws its own dim placeholder into the empty
# box in the same place, so position alone cannot tell one from box content - the named list above
# does, and a match returns '' so the send proceeds and the reported box reads empty.
function Get-HerdrPromptBoxText {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $anchor = "$($script:PromptBoxCaret)$($script:PromptBoxSpace)"

    foreach ($line in ($Text -split "`r?`n")) {
        $inner = $line.Trim().Trim($script:PromptBoxRule).TrimStart()
        if (-not $inner.StartsWith($anchor)) { continue }
        $box = $inner.Substring($anchor.Length).Trim($script:PromptBoxRule).Trim()
        if (Test-HerdrPromptBoxPlaceholder -Text $box) { return '' }
        return $box
    }
    ''
}

# What is sitting in a worker's prompt box right now, or '' when it is empty or could not be read.
#
# FAILS OPEN, and that is the opposite of Get-HerdrAgentProgressSignal below on purpose. There the
# cost of guessing is a false stall report; here it is a teardown or a corrective steer that cannot
# be delivered to a worker that may be wedged. A narrow pane must not make a worker unsteerable.
function Get-HerdrAgentPromptBox {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    $read = Read-HerdrAgentScreen -Name $Name
    if (-not $read.ok) { return '' }
    Get-HerdrPromptBoxText -Text $read.text
}

# Refuses to write into a box this call did not fill, and quotes what is in it.
#
# REFUSE, NEVER CLEAR. Clearing destroys the evidence of the very event worth noticing, and the
# caller may be about to send something that must not be mixed with whatever is already there. The
# exception IS the escalation: `rally` reports the quoted text and lets the King decide.
function Assert-HerdrPromptBoxWritable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Action
    )

    $box = Get-HerdrAgentPromptBox -Name $Name
    if (-not $box) { return }

    throw ("Refusing to $Action at worker '$Name': its prompt box already holds text this call " +
           "did not write - '$box'. Enter would submit that as though the Hand had written it. " +
           'Read it, decide what it is, then either re-send with -AllowNonEmptyBox or send ' +
           'escape first to dismiss it.')
}

# True when a worker's terminal is wide enough for the screen guard to work on it.
#
# The guard matches phrases like "Enter to select". A pane too narrow to render one of them cannot
# be read, and a read that cannot succeed must not be reported as "no prompt found" - that is the
# difference between "this worker is fine" and "I cannot tell". Callers that treat a false from
# Test-HerdrAgentAwaitingInput as proof of health need to know which one they have.
#
# A read that failed answers false here for the same reason, and it is not a nicety: this is the
# cross-check `rally` sends the Hand to when a stall is reported, so a wide error payload reading as
# a healthy pane is the one answer that would confirm the wrong story.
function Test-HerdrAgentReadable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [int]$MinimumColumns = 40
    )

    $read = Read-HerdrAgentScreen -Name $Name
    if (-not $read.ok) { return $false }

    $widest = 0
    foreach ($line in ($read.text -split "`n")) {
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
#
# -AllowNonEmptyBox is the deliberate override for a box the caller has already read and decided
# about. Without it a non-empty box is refused rather than typed over; see the prompt-box section.
function Send-HerdrPrompt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Text,
        [switch]$Wait,
        [switch]$AllowNonEmptyBox,
        [int]$TimeoutMs = $script:HerdrTimeoutMs
    )

    if (-not $AllowNonEmptyBox) {
        Assert-HerdrPromptBoxWritable -Name $Name -Action 'submit a prompt'
    }

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

    $read = Read-HerdrAgentScreen -Name $Name
    if (-not $read.ok) { return $false }

    foreach ($sig in $script:AwaitingInputSignatures) {
        if ($read.text.Contains($sig)) { return $true }
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

# How long to wait before believing that a worker herdr did not name is really gone. A read that
# comes back empty is "no such agent" OR "herdr could not answer", and one transient error must not
# end a watch on a worker that is alive and working - the same null-is-not-zero discipline the CI
# preflight applies to check counts.
$script:GoneConfirmMs  = 1500

# How many consecutive waits may come back without having consumed their slice before the watch
# gives up. A wait built on somebody else's timeout becomes a silent spin the moment that timeout
# stops being honoured, and only a return that was materially faster than the slice it asked for is
# evidence of that - a wait that blocked for its full minute has cost a minute of clock and is
# ordinary. The margin is wide because a herdr server restart or a single error envelope is not a
# spin, and it is bounded because twenty instant failures in a row are.
$script:MaxFastWaitReturns = 20

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
#
# .promptBox is here rather than anywhere else because this already reads the live viewport once per
# sample on every watched worker, so reporting the box costs one regex over text that is already in
# memory - no extra herdr call and no extra latency. It is an added FIELD and not a new state: a box
# with text in it is not an interactive prompt, and folding it into Test-HerdrAgentAwaitingInput
# would make every finished worker read `blocked`. All three sightings of an unexplained box were
# found by chance, which is what this exists to stop.
function Get-HerdrAgentProgressSignal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    # The live viewport, for the same reason the blocked guard reads it: scrollback never changes,
    # so a signal taken over `recent` would look static on a worker that is working perfectly.
    $read = Read-HerdrAgentScreen -Name $Name
    if (-not $read.ok) {
        return [pscustomobject]@{ readable = $false; signal = ''; lastActivity = ''; promptBox = '' }
    }

    # Read off the RAW screen, before the normalisation below folds the lines together.
    $promptBox = Get-HerdrPromptBoxText -Text $read.text

    $text = $read.text
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
        promptBox    = $promptBox
    }
}

# Waits for a worker to stop, and gives up on it when it stops advancing instead.
#
# This is ADDED BESIDE `Wait-HerdrAgentSettled` and changes nothing about it. That function is still
# correct for what it does and other callers depend on it; this one answers the second question.
#
# It is still an event rather than a poll. herdr's own wait is the blocking primitive - it returns
# the instant the worker settles - and the sample interval is only that wait's timeout, so nothing
# here sleeps on the ordinary path and a finished worker still wakes the caller immediately. The one
# sleep is the second read that confirms a worker herdr did not name is really gone. Sampling is
# unavoidable for the stall half: "nothing happened" is not an event anything can push.
#
# It never recovers anything. A stall is reported with its evidence and the response belongs to
# `rally` - a wrong automatic action on a stalled worker is worse than a late human one.
function Wait-HerdrAgentProgress {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [int]$TimeoutMs = 0,
        [int]$StallMinutes = $script:StallMinutes,
        [int]$SampleSeconds = $script:SampleSeconds
    )

    if ($SampleSeconds -lt 1) { $SampleSeconds = 1 }
    $sliceMs = $SampleSeconds * 1000

    # The default timeout is COMPUTED FROM THE STALL THRESHOLD, because a watch that ends before the
    # threshold can never reach it. Taking herdr's own four-minute default here made the two defaults
    # mutually exclusive: twenty minutes of silence cannot be observed inside four, so the stall
    # branch was unreachable for every caller that did not override the timeout. A caller that passes
    # a shorter timeout deliberately gets what it asked for - a watch for completion only.
    if ($TimeoutMs -le 0) {
        $TimeoutMs = [Math]::Max($script:HerdrTimeoutMs, ($StallMinutes + 1) * 60000)
    }

    $started    = Get-Date
    $deadline   = $started.AddMilliseconds($TimeoutMs)
    $first      = Get-HerdrAgentProgressSignal -Name $Name
    $signal     = $first.signal
    $activity   = $first.lastActivity
    $promptBox  = $first.promptBox
    $readable   = $first.readable
    $lastChange = $started
    $samples    = 1

    # Consecutive waits that returned without consuming their slice. Counting every iteration
    # instead would leave about three iterations of margin over a legitimate watch, so one herdr
    # restart or one error envelope on a healthy worker would end the watch as `wait-failed`; only a
    # return that cost no clock is evidence of the spin this guards against.
    $fastReturns = 0

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
            # Sampled at the same moment as lastActivity, on every report this makes - settled,
            # stalled, gone and timeout alike - so an unexplained box is seen on the wake the Hand
            # already handles rather than stumbled on later.
            promptBox      = $promptBox
            signalReadable = $readable
            samples        = $samples
            stallMinutes   = $StallMinutes
        }
    }

    while ((Get-Date) -lt $deadline) {
        $remaining = [int]([Math]::Min($sliceMs, ($deadline - (Get-Date)).TotalMilliseconds))
        if ($remaining -lt 1) { break }

        $sliceStarted = Get-Date
        $agent = Wait-HerdrAgent -Name $Name -TimeoutMs $remaining
        if ($agent) {
            $awaiting = Test-HerdrAgentAwaitingInput -Name $Name
            $state    = if ($awaiting) { 'blocked' } else { $agent.agent_status }

            # The final screen, carried out with the wake. A state word cannot tell a worker that
            # finished from one that handed its work to a background pipeline and returned to its
            # prompt - both read `done` within seconds - so what the wake can honestly do is hand
            # over what that worker's screen last said and let a person read it. Reporting stale
            # activity from before the worker stopped would be worse than reporting none.
            $final = Get-HerdrAgentProgressSignal -Name $Name
            $readable  = $final.readable
            $activity  = if ($final.readable) { $final.lastActivity } else { '' }
            $promptBox = if ($final.readable) { $final.promptBox }    else { '' }

            return & $report $true $state $awaiting $false 'settled'
        }

        if (((Get-Date) - $sliceStarted).TotalMilliseconds -lt ($remaining / 2)) {
            $fastReturns++
        } else {
            $fastReturns = 0
        }

        # Null is a timeout OR a herdr error, and the two are not the same. A worker herdr has never
        # heard of is gone rather than slow, and saying so is what sends the caller to `rally`
        # instead of leaving it waiting on a process that no longer exists.
        #
        # One empty read is not that answer, though: `Get-HerdrAgent` returns nothing for "no such
        # agent" AND for "herdr could not answer", so a single transient error would end the watch on
        # a worker that is alive and working. It is confirmed once, after a pause, before the watch
        # gives up on it.
        $live = Get-HerdrAgent -Name $Name
        if (-not $live) {
            Start-Sleep -Milliseconds $script:GoneConfirmMs
            $live = Get-HerdrAgent -Name $Name
            if (-not $live) {
                # A server that is down answers nothing for every agent, exactly as it does for one
                # that was never registered, and the confirm pause above is far shorter than the
                # thirty seconds a server takes to come back up. The difference matters to whoever
                # reads this: `gone` sends them to reconcile a worktree that may still be being
                # written to, while `wait-failed` sends them to the server and a re-armed wait.
                if (-not (Test-HerdrServer)) {
                    return & $report $false $null $false $false 'wait-failed'
                }
                return & $report $false $null $false $false 'gone'
            }
        }

        if ($fastReturns -gt $script:MaxFastWaitReturns) {
            return & $report $false $null $false $false 'wait-failed'
        }

        $samples++
        $sample = Get-HerdrAgentProgressSignal -Name $Name
        if (-not $sample.readable) {
            # Fail closed. An unreadable screen is not a still one, so the clock is left where it is
            # and no stall is claimed - the caller is told the watch was blind instead.
            $readable = $false
            continue
        }

        $readable  = $true
        $activity  = $sample.lastActivity
        $promptBox = $sample.promptBox
        if ($sample.signal -ne $signal) {
            $signal     = $sample.signal
            $lastChange = Get-Date
            continue
        }

        if (((Get-Date) - $lastChange).TotalMinutes -ge $StallMinutes) {
            # The state is READ, never assumed. A worker sitting on a dialog the screen guard did not
            # match looks exactly like a stalled one, and reporting that as `working` would send the
            # Hand looking for a stuck step when what is actually needed is the user's answer. The
            # screen outranks herdr's word here for the same reason it does on every other wake.
            $awaiting   = Test-HerdrAgentAwaitingInput -Name $Name
            $stallState = 'working'
            if (($live.PSObject.Properties.Name -contains 'agent_status') -and $live.agent_status) {
                $stallState = $live.agent_status
            }
            if ($awaiting) { $stallState = 'blocked' }

            return & $report $false $stallState $awaiting $true 'stalled'
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
#
# AN ENTER THAT OPENS THE CALL IS THE DANGEROUS ONE, and it is refused when the box is not empty.
# Nothing in this call has moved a selection yet, so the Enter lands on the input box and submits
# whatever is rendered there - which may be a suggestion the harness generated rather than anything
# the Hand wrote. A later Enter in the same call is answering the menu the earlier keys have moved
# through, so only the first key is checked.
#
# A WORKER SITTING ON A MENU IS STILL ANSWERABLE by a bare Enter, and has to be: that is the only
# route to it. The check runs there too, and passes, because the box detector anchors on the caret
# plus a no-break space and a menu row renders the same caret with a plain one. It is the glyph pair
# that keeps the two apart, not the absence of a box.
function Send-HerdrKeys {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string[]]$Keys,
        [switch]$AllowNonEmptyBox,
        [int]$DelayMs = 400
    )

    if (-not $AllowNonEmptyBox -and $Keys.Count -gt 0 -and $Keys[0] -eq 'enter') {
        Assert-HerdrPromptBoxWritable -Name $Name -Action 'send a bare Enter'
    }

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

    # -AllowNonEmptyBox, always. TEARDOWN MUST NEVER BE BLOCKED BY A SUGGESTION: `/exit` displaces
    # whatever is rendered in the box harmlessly, and a worker that cannot be stopped because of a
    # cosmetic render is a worse failure than the one the guard exists to prevent. It still goes
    # through the guarded path rather than round the side of it, so the exemption is stated once
    # here instead of being an accident of which function this happened to call.
    #
    # A herdr error on the way out is not the end of the teardown either - the agent may already
    # have gone - so the confirm loop below is what decides, not this call's outcome.
    try { $null = Send-HerdrPrompt -Name $agentName -Text '/exit' -AllowNonEmptyBox } catch { }

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
                              Get-HerdrAgentProgressSignal, Wait-HerdrAgentProgress,
                              Get-HerdrAgentPromptBox
