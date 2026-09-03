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
# `value` is the login. It is returned so a caller can type it into a page and for no other
# reason: never print it, never write it to a file, and never put it in a report. `summary` is
# the line the report gets and it carries no value at all.
function Get-BrowserCredentialStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Variable)

    $result = @{
        variable = $Variable
        found    = $false
        source   = 'none'
        value    = $null
        reason   = ''
        summary  = ''
    }

    $fromProcess = [Environment]::GetEnvironmentVariable($Variable)
    if ($fromProcess) {
        $result.found   = $true
        $result.source  = 'process'
        $result.value   = $fromProcess
        $result.reason  = "$Variable was set in this process's own environment."
        $result.summary = "$Variable - found in this worker's environment."
        return $result
    }

    # Reads the registry rather than any inherited block, which is what makes a variable set after
    # herdr started reachable at all.
    $fromUser = [Environment]::GetEnvironmentVariable($Variable, 'User')
    if ($fromUser) {
        $result.found   = $true
        $result.source  = 'user'
        $result.value   = $fromUser
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
#     it is the assertion this whole capability exists to replace;
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

    foreach ($c in @($Check)) {
        if (-not $c) { continue }

        $id       = if ($c.ContainsKey('id') -and $c.id) { [string]$c.id } else { '' }
        $what     = if ($c.ContainsKey('check') -and $c.check) { [string]$c.check } else { '' }
        $observed = if ($c.ContainsKey('observed') -and $c.observed) { [string]$c.observed } else { '' }
        $given    = if ($c.ContainsKey('outcome') -and $c.outcome) { [string]$c.outcome } else { '' }
        $stated   = if ($c.ContainsKey('reason') -and $c.reason) { [string]$c.reason } else { '' }

        $outcome = 'not checked'
        $reason  = ''

        if ($Unavailable) {
            $reason = $Unavailable
        } elseif (-not $given) {
            $reason = 'No outcome was recorded for this check.'
        } elseif ($script:Outcomes -notcontains $given) {
            $reason = ("'$given' is not one of $($script:Outcomes -join ', '), so this check " +
                       'has no outcome that can be read.')
        } elseif ($given -eq 'verified' -and -not $observed) {
            $reason = 'Recorded verified with nothing observed, so there is no evidence for it.'
        } else {
            $outcome = $given
            $reason  = $stated
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
                              Get-BrowserCredentialStatus, Get-BrowserVerificationRecord
