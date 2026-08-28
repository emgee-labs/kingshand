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

# The absolute path of the `claude.cmd` shim, or $null when it cannot be found.
#
# It has to be the `.cmd`, not `claude` and not the `.ps1`. On Windows `claude` resolves to a
# PowerShell script, and `Start-Process` cannot launch one - it fails with "%1 is not a valid Win32
# application". The shim is the only form the dispatcher can spawn.
#
# Resolved at run time through `Get-Command`. This used to be one machine's npm prefix written out
# in full, which is a path nobody else has.
function Get-ClaudeCommandPath {
    [CmdletBinding()]
    param()

    $direct = @(Get-Command 'claude.cmd' -CommandType Application -ErrorAction SilentlyContinue)
    if ($direct.Count -gt 0 -and $direct[0].Source) { return $direct[0].Source }

    # `claude` on PATH tells us where the install lives even when the shim itself is not resolvable
    # as a command name - the two sit side by side in the same npm bin directory.
    foreach ($candidate in @(Get-Command 'claude' -ErrorAction SilentlyContinue)) {
        $source = $candidate.Source
        if (-not $source) { continue }
        if ($source.EndsWith('.cmd', [System.StringComparison]::OrdinalIgnoreCase)) { return $source }

        $sibling = Join-Path (Split-Path $source -Parent) 'claude.cmd'
        if (Test-Path -LiteralPath $sibling -PathType Leaf) { return $sibling }
    }

    $null
}

# One message, so the dispatcher and the prerequisite check tell the user the same actionable
# thing. It names the tool, the install command, and the reason the shim specifically is required.
function Get-ClaudeCommandHint {
    [CmdletBinding()]
    param()

    'claude.cmd was not found on PATH. Install Claude Code with: npm install -g ' +
    '@anthropic-ai/claude-code - then open a new shell so PATH is picked up. Dispatch spawns the ' +
    '.cmd shim rather than `claude` itself, because Start-Process cannot launch the .ps1 that ' +
    '`claude` resolves to on Windows.'
}

Export-ModuleMember -Function Get-KingshandHome, Get-ClaudeCommandPath, Get-ClaudeCommandHint
