#Requires -Version 7.0
Set-StrictMode -Version Latest

# Browser verification: whether the browser can be driven at all, whether a login can be found,
# and what the record of a verification run says. The `witness` skill owns the procedure; this
# module owns the three answers that must not be given from memory.
#
# Nothing here drives a browser. The browser tools are MCP tools the agent calls directly, and
# they are deferred, so which of them loaded is something only the agent can see. It passes what
# it saw to Get-BrowserToolStatus rather than this module going looking.
#
# Nothing here reads the brief either, and nothing may start. A brief is prose written by a
# person, so its checks arrive as a list the caller has already read and structured - see the
# `statute` skill on hand-written parsers of open formats, and every check below takes bounded
# input for that reason: a closed set of outcome words, a list of tool names, one variable name.
#
# Nothing here writes a file. The record goes into the worker's own `report.md`, which already
# has an owner, so this module adds no write destination and can collide with nothing.
#
# Windows-scoped, like the rest of kingshand. Get-BrowserCredentialStatus reads the user
# environment out of the Windows registry; on any other platform that read finds nothing and the
# result is an honest not-found rather than a fabricated one.

# The minimum for a verification to produce evidence at all: reach a tab, go somewhere, read the
# page, and read the console and network traces the record is built from. Stated once, here.
#
# Deliberately NOT required: `computer`, `find`, `form_input`, `javascript_tool` and
# `gif_creator`. Each is needed by some checks and by no others, so requiring them would fail a
# run of read-only checks that would have worked. A check needing one that did not load is
# recorded `not checked` naming the tool - which is Get-BrowserVerificationRecord's job, per check,
# rather than this list's.
$script:RequiredTools = @(
    'tabs_context_mcp'
    'tabs_create_mcp'
    'navigate'
    'get_page_text'
    'read_console_messages'
    'read_network_requests'
)

# The three outcomes a check can have, and nothing else is one. `verified` is deliberately the
# only one that asserts anything, and Get-BrowserVerificationRecord is the only thing that awards
# it.
$script:Outcomes = @('verified', 'failed', 'not checked')

function Get-BrowserRequiredTools {
    [CmdletBinding()]
    param()
    , @($script:RequiredTools)
}

# Whether the browser can be driven, from the tool names the agent actually saw come back.
#
# Fails closed in every direction that is not a full set: nothing loaded, some loaded, or the
# server answering with names nobody asked for. `reason` is the sentence the report carries, and
# it says verification did not happen - never that a check passed, and never that one was skipped.
function Get-BrowserToolStatus {
    [CmdletBinding()]
    param(
        [string[]]$Loaded,
        [string[]]$Required = $script:RequiredTools
    )

    # The MCP tools are namespaced when they load - mcp__claude-in-chrome__navigate - and the
    # agent may report either form. Compared on the last segment so both read the same.
    $seen = @{}
    foreach ($name in @($Loaded)) {
        if (-not $name) { continue }
        $short = ($name -split '__')[-1]
        $seen[$short] = $true
    }

    $missing = @(foreach ($r in @($Required)) { if (-not $seen.ContainsKey($r)) { $r } })

    $result = @{
        required  = @($Required)
        loaded    = @($seen.Keys | Sort-Object)
        missing   = @($missing)
        available = ($missing.Count -eq 0)
        reason    = ''
    }

    if ($result.available) {
        $result.reason = 'The browser tools are loaded and verification can run.'
    } elseif ($seen.Count -eq 0) {
        $result.reason = ('Browser verification did not happen: no browser tools loaded, so ' +
                          'nothing was exercised in a browser. This is not a pass.')
    } else {
        $result.reason = ('Browser verification did not happen: ' +
                          ($missing -join ', ') +
                          ' did not load, so nothing was exercised in a browser. This is not a pass.')
    }

    $result
}

# The two places a login can be, read in the one order that works, and the only place that order
# is written down. Not exported: the two functions below are the interface, and they differ only
# in whether the caller gets the login or a line it can print.
#
# The second read is the registry rather than any inherited block, which is what makes a variable
# set after herdr started reachable at all.
function Read-BrowserCredential {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Variable)

    $fromProcess = [Environment]::GetEnvironmentVariable($Variable)
    if ($fromProcess) { return @{ value = $fromProcess; source = 'process' } }

    $fromUser = [Environment]::GetEnvironmentVariable($Variable, 'User')
    if ($fromUser) { return @{ value = $fromUser; source = 'user' } }

    @{ value = $null; source = 'none' }
}

# The login itself and nothing else, for typing into a page with `form_input`. Never print it,
# never echo it into a command line, never write it to a file, and never put it in a report -
# `$null` where the variable is set in neither place, which Get-BrowserCredentialStatus is the
# thing to report on.
function Get-BrowserCredentialValue {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Variable)

    (Read-BrowserCredential -Variable $Variable).value
}

# Where a login lives, without ever putting it in a file.
#
# Two places are read, in order, and the second one is why this function exists. Workers are
# started by a long-running herdr server, and a process inherits its environment block from its
# parent at the moment it is created - so a variable set today is invisible to every worker herdr
# starts, however long afterwards, until herdr itself is restarted. Measured on 2026-09-03: a
# variable set at User scope was absent from `$env:` in the process that set it AND in a child
# spawned after the set, while a registry read returned it from both.
#
# So the process block is read first and the user environment second, and the second read is the
# one that usually answers. `source` says which, because "found in the user environment" is also
# the tell that this worker's environment is stale.
#
# The login itself is deliberately NOT in this result, and Get-BrowserCredentialValue below is the
# only way to it. A hashtable evaluated on its own prints every key it holds, so a worker typing
# `$cred` to see whether one was found would put the login into its pane and its on-disk
# transcript - which no amount of prose warning it not to would stop. Everything here is safe to
# print, and `summary` is the line the report gets.
function Get-BrowserCredentialStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Variable)

    $result = @{
        variable = $Variable
        found    = $false
        source   = 'none'
        reason   = ''
        summary  = ''
    }

    $read = Read-BrowserCredential -Variable $Variable

    if ($read.source -eq 'process') {
        $result.found   = $true
        $result.source  = 'process'
        $result.reason  = "$Variable was set in this process's own environment."
        $result.summary = "$Variable - found in this worker's environment."
        return $result
    }

    if ($read.source -eq 'user') {
        $result.found   = $true
        $result.source  = 'user'
        $result.reason  = ("$Variable was not in this process's environment but is set for the " +
                           'user. This worker was started from an older environment; the user ' +
                           'setting is authoritative and was used.')
        $result.summary = "$Variable - found in the user environment, not in this worker's own."
        return $result
    }

    $result.reason  = ("$Variable is not set in this process's environment or for the user, so " +
                       'no login is available and nothing was signed in to. Set it for the user ' +
                       'and, if a later worker still cannot see it, restart the worker server so ' +
                       'a fresh environment is inherited. Never put the value in a brief, a ' +
                       'report or any file.')
    $result.summary = "$Variable - not set, so no login was available."
    $result
}

# The record of one verification run: every declared check with an explicit outcome, and one
# verdict over the lot.
#
# Every rule here exists to stop a check reading as a pass it did not earn:
#
#   - a check with no outcome recorded is `not checked`, never dropped and never assumed;
#   - an outcome word outside the three is `not checked` naming the word, so a typo or an
#     invented state word can never read as `verified`;
#   - `verified` with nothing observed is `not checked`, because a pass with no evidence behind
#     it is the assertion this whole capability exists to replace. Whitespace is nothing: every
#     field is trimmed as it is read, so a space cannot stand in for evidence;
#   - `failed` or `not checked` with no text behind it carries a stated reason, because an
#     outcome word alone says less than a check nobody recorded anything against;
#   - no checks at all is `not verified`, not an empty pass;
#   - -Unavailable makes every check `not checked` for that reason, whatever was recorded
#     against it. That is the browser-absent path, and it cannot come back verified.
#
# The verdict is `verified` only when every check is; `failed` if any failed; `not verified`
# otherwise, which means something was not checked and the run does not stand as a pass.
function Get-BrowserVerificationRecord {
    [CmdletBinding()]
    param(
        [hashtable[]]$Check,
        [string]$Unavailable
    )

    # Built into a list rather than collected from the loop: a loop that yields nothing assigns
    # $null, and @($null) is a one-element array holding $null - so an empty check list would
    # report one check and then read a property off nothing. Null entries are dropped here for
    # the same reason, before anything counts them: an empty slot in the list is not a check
    # anybody declared, and treating it as one would invent a check to report.
    $items = [System.Collections.Generic.List[hashtable]]::new()

    # Trimmed once, for the same reason every check field is: this reason overrides every item, so
    # a caller passing whitespace would put a bare outcome word on all of them at once.
    $absent = ([string]$Unavailable).Trim()

    foreach ($c in @($Check)) {
        if (-not $c) { continue }

        # Trimmed at the point of capture, so every truthiness test below sees an empty string
        # where a field held only whitespace. A space is not evidence and not a reason.
        $id       = if ($c.ContainsKey('id') -and $c.id) { ([string]$c.id).Trim() } else { '' }
        $what     = if ($c.ContainsKey('check') -and $c.check) { ([string]$c.check).Trim() } else { '' }
        $observed = if ($c.ContainsKey('observed') -and $c.observed) { ([string]$c.observed).Trim() } else { '' }
        $given    = if ($c.ContainsKey('outcome') -and $c.outcome) { ([string]$c.outcome).Trim() } else { '' }
        $stated   = if ($c.ContainsKey('reason') -and $c.reason) { ([string]$c.reason).Trim() } else { '' }

        $outcome = 'not checked'
        $reason  = ''

        if ($absent) {
            $reason = $absent
        } elseif (-not $given) {
            $reason = 'No outcome was recorded for this check.'
        } elseif ($script:Outcomes -notcontains $given) {
            $reason = ("'$given' is not one of $($script:Outcomes -join ', '), so this check " +
                       'has no outcome that can be read.')
        } elseif ($given -eq 'verified' -and -not $observed) {
            $reason = 'Recorded verified with nothing observed, so there is no evidence for it.'
        } elseif ($given -eq 'not checked' -and -not $stated -and -not $observed) {
            $reason = ('Recorded not checked with nothing recorded against it, so why it was ' +
                       'not checked is unknown.')
        } elseif ($given -eq 'failed' -and -not $stated -and -not $observed) {
            $outcome = $given
            $reason  = ('Recorded failed with nothing observed and no reason given, so there is ' +
                        'no account of what went wrong.')
        } else {
            $outcome = $given
            $reason  = $stated
        }

        # A substituted reason says why the outcome could not stand, and the worker's own words
        # are the evidence for whatever it did see. Both are kept: the item is the only account
        # of this check that survives, so nothing written against it is dropped on the way to a
        # refused outcome. -Unavailable is the exception, and deliberately overrides.
        if (-not $absent -and $stated -and $reason -ne $stated) {
            $reason = "$reason The reason recorded against it: $stated"
        }

        $items.Add(@{
            id       = $id
            check    = $what
            outcome  = $outcome
            observed = $observed
            reason   = $reason
        })
    }

    $counts = @{ verified = 0; failed = 0; 'not checked' = 0 }
    foreach ($i in $items) { $counts[$i.outcome]++ }

    $verdict = if ($items.Count -eq 0) {
        'not verified'
    } elseif ($counts.failed -gt 0) {
        'failed'
    } elseif ($counts['not checked'] -gt 0) {
        'not verified'
    } else {
        'verified'
    }

    $summary = if ($items.Count -eq 0) {
        'not verified - no checks were declared, so nothing was verified.'
    } else {
        ("$verdict - $($items.Count) checks: $($counts.verified) verified, " +
         "$($counts.failed) failed, $($counts['not checked']) not checked.")
    }

    @{
        # @() survives the single-element unwrap that would otherwise hand a caller the bare
        # hashtable and make .Count report its key count instead of 1.
        items    = @($items)
        counts   = $counts
        verdict  = $verdict
        summary  = $summary
        verified = ($verdict -eq 'verified')
    }
}

Export-ModuleMember -Function Get-BrowserRequiredTools, Get-BrowserToolStatus,
                              Get-BrowserCredentialStatus, Get-BrowserCredentialValue,
                              Get-BrowserVerificationRecord
