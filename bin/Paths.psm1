#Requires -Version 7.0
Set-StrictMode -Version Latest

# The two things every installation resolves differently, resolved in exactly one place.
#
# Everything else in this repo is portable already; these two were not, and each of them was a
# hardcoded absolute path belonging to one machine. A second copy of either rule is how they drift
# back apart, so `bin\` and the skills both come through here rather than deriving their own.

# This installation's root. `KINGSHAND_HOME` wins when it is set, because a user may keep the repo
# anywhere and the skills spell their commands with `$env:KINGSHAND_HOME`. Unset, the root is
# derived from this module's own location - `bin\` sits directly under the root - so a fresh clone
# works before anything has been configured at all. Absence of the variable is the ordinary state,
# never an error.
function Get-KingshandHome {
    [CmdletBinding()]
    param()

    $configured = $env:KINGSHAND_HOME
    if (-not [string]::IsNullOrWhiteSpace($configured)) {
        return $configured.TrimEnd('\', '/')
    }
    Split-Path $PSScriptRoot -Parent
}

# The absolute path of the real `claude.exe`, or the npm `.cmd` wrapper as a last resort, or $null.
#
# THE ORDER MATTERS AND THE WRAPPER IS THE WRONG ANSWER. npm's `claude.cmd` forwards with `%*`:
#
#     "%dp0%\node_modules\@anthropic-ai\claude-code\bin\claude.exe"   %*
#
# `%*` re-expands the raw command line, so cmd.exe parses any double quote inside an argument as a
# delimiter and the value is cut at the first one. Measured: passing a JSON schema through the
# wrapper delivered `{` and nothing else, and Claude Code answered "--json-schema is not valid
# JSON: JSON Parse error: Expected '}'" - not malformed JSON, one character of it. The same call to
# the real binary on the same machine returned correct output.
#
# So anything that shells out to Claude Code by name on Windows gets a wrapper that silently
# corrupts quoted arguments. This function exists to hand back the binary instead.
#
# `.ps1` is never returned. It works when a human types it, because PowerShell passes argv straight
# through, but it cannot be launched by a native caller.
#
# Resolved at run time through `Get-Command`. This used to be one machine's npm prefix written out
# in full, which is a path nobody else has.
function Get-ClaudeCommandPath {
    [CmdletBinding()]
    param()

    $exe = @(Get-Command 'claude.exe' -CommandType Application -ErrorAction SilentlyContinue)
    if ($exe.Count -gt 0 -and $exe[0].Source) { return $exe[0].Source }

    # Not on PATH by default: npm's bin directory holds `claude`, `claude.cmd` and `claude.ps1`,
    # and the binary lives one package directory down. Look there before settling for the wrapper.
    foreach ($candidate in @(Get-Command 'claude' -ErrorAction SilentlyContinue)) {
        $source = $candidate.Source
        if (-not $source) { continue }
        $dir = Split-Path $source -Parent
        $nested = Join-Path $dir 'node_modules\@anthropic-ai\claude-code\bin\claude.exe'
        if (Test-Path -LiteralPath $nested -PathType Leaf) { return $nested }
    }

    # Last resort. It will corrupt any argument containing a quote, so callers that pass one should
    # treat this as a degraded result rather than a working install.
    $cmd = @(Get-Command 'claude.cmd' -CommandType Application -ErrorAction SilentlyContinue)
    if ($cmd.Count -gt 0 -and $cmd[0].Source) { return $cmd[0].Source }

    foreach ($candidate in @(Get-Command 'claude' -ErrorAction SilentlyContinue)) {
        $source = $candidate.Source
        if (-not $source) { continue }
        if ($source.EndsWith('.cmd', [System.StringComparison]::OrdinalIgnoreCase)) { return $source }
        $sibling = Join-Path (Split-Path $source -Parent) 'claude.cmd'
        if (Test-Path -LiteralPath $sibling -PathType Leaf) { return $sibling }
    }

    $null
}

# True when the resolved Claude Code is the npm wrapper rather than the binary.
#
# Not fatal - kingshand itself passes no quoted arguments today, so a wrapper still dispatches
# workers fine. It matters for anything that does, which on this toolchain means the review gate:
# every one of its agent steps passes a JSON schema, so on a wrapper-only machine the whole
# pipeline fails instantly and the error names JSON rather than PATH.
function Test-ClaudeCommandIsWrapper {
    [CmdletBinding()]
    param([string]$Path)

    if (-not $Path) { $Path = Get-ClaudeCommandPath }
    if (-not $Path) { return $false }
    $Path.EndsWith('.cmd', [System.StringComparison]::OrdinalIgnoreCase)
}

# One message, so every caller tells the user the same actionable thing.
function Get-ClaudeCommandHint {
    [CmdletBinding()]
    param()

    'Claude Code was not found on PATH. Install it with: npm install -g @anthropic-ai/claude-code ' +
    '- then open a new shell so PATH is picked up.'
}

# The fix for a machine that only has the wrapper, said the same way everywhere.
function Get-ClaudeWrapperHint {
    [CmdletBinding()]
    param()

    'Claude Code resolves to npm''s claude.cmd wrapper, which corrupts any argument containing a ' +
    'quote - it forwards with %* and cmd.exe re-parses the quotes. Tools that pass JSON, including ' +
    'the no-mistakes review gate, fail with "--json-schema is not valid JSON" and never reach the ' +
    'model. Fix it by putting the real binary first on PATH: ' +
    '%APPDATA%\npm\node_modules\@anthropic-ai\claude-code\bin - PATHEXT prefers .EXE over .CMD, so ' +
    'it wins. install.ps1 does this for you.'
}

# The review gate, or $null. Optional by design: only projects registered `no-mistakes` or
# `no-mistakes-prod-only` need it, and a user who registers nothing that way never installs it.
#
# Two places, in this order: a copy the user manages themselves on PATH wins, then the one the
# installer drops in `tools\no-mistakes\`. Same rule as herdr, and for the same reason - nobody
# should end up with two copies because kingshand refused to see theirs.
function Get-NoMistakesCommandPath {
    [CmdletBinding()]
    param()

    $onPath = Get-Command 'no-mistakes' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($onPath -and $onPath.Source) { return $onPath.Source }

    $bundled = Join-Path (Get-KingshandHome) 'tools\no-mistakes\no-mistakes.exe'
    if (Test-Path -LiteralPath $bundled -PathType Leaf) { return $bundled }

    $null
}

# One message, so every caller says the same actionable thing - and names the right tool.
#
# `npm install -g no-mistakes` is the obvious guess and it is WRONG: that npm package is an
# unrelated static-analysis tool by a different author, and it installs cleanly, so the mistake is
# not discovered until the gate does not work. The review gate is a GitHub release, and it is worth
# saying so rather than leaving someone to guess.
function Get-NoMistakesHint {
    [CmdletBinding()]
    param()

    'no-mistakes was not found. Run: .\install.ps1 -WithReviewGate - which fetches the Windows ' +
    'build from github.com/kunchenguid/no-mistakes and checks it against the published SHA-256. ' +
    'Do NOT run `npm install -g no-mistakes`: that name on npm belongs to a different, unrelated ' +
    'tool. It is needed only by projects registered `no-mistakes` or `no-mistakes-prod-only`.'
}

Export-ModuleMember -Function Get-KingshandHome, Get-ClaudeCommandPath, Get-ClaudeCommandHint,
                              Test-ClaudeCommandIsWrapper, Get-ClaudeWrapperHint,
                              Get-NoMistakesCommandPath, Get-NoMistakesHint
