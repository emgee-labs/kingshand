#Requires -Version 7.0
Set-StrictMode -Version Latest

# Prepares a directory so Claude Code can run in it unattended.
#
# This module exists because herdr cannot pass arguments to claude on Windows. `claude --bg` took
# `--permission-mode bypassPermissions --add-dir <briefdir>` on the command line; herdr's
# equivalent (`agent start ... -- <args>`) launches through Start-Process against a .ps1 and
# fails with "%1 is not a valid Win32 application". So both grants have to be in place on disk
# before the agent starts, and a worker whose directory was not prepared will stop at the first
# permission prompt with nobody there to answer it.
#
# Everything here is a grant. Each one is written where the user can read it back, and each is
# scoped to a single worktree that kingshand created itself from a repo the King registered -
# never to the repo, never to the machine.

# The two grants that used to be command-line flags, written into the worktree.
#
#   defaultMode: bypassPermissions   was --permission-mode bypassPermissions
#   additionalDirectories: [...]     was --add-dir <briefdir>
#
# It must be written INTO THE WORKTREE, not the repo. A worktree is a fresh checkout with no
# .claude directory of its own, and settings.local.json is untracked, so nothing carries across
# from the main checkout.
#
# Verified end to end: a worker launched this way read a brief from a directory outside its repo
# and ran a shell command with no prompt, and the session footer showed "bypass permissions on".
function Set-WorkerWorkspaceSettings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorktreePath,
        [string[]]$AdditionalDirectories = @()
    )

    if (-not (Test-Path -LiteralPath $WorktreePath)) {
        throw "Worktree not found, so its settings cannot be written: $WorktreePath"
    }

    $claudeDir = Join-Path $WorktreePath '.claude'
    if (-not (Test-Path -LiteralPath $claudeDir)) {
        New-Item -ItemType Directory -Force -Path $claudeDir | Out-Null
    }

    $settings = [ordered]@{
        permissions = [ordered]@{
            defaultMode           = 'bypassPermissions'
            additionalDirectories = @($AdditionalDirectories)
        }
    }

    $target = Join-Path $claudeDir 'settings.local.json'
    $settings | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $target -Encoding utf8
    $target
}

# Records that one worktree path is trusted, so an unattended worker does not stop on Claude
# Code's folder-trust dialog.
#
# `claude --bg --worktree` never met this dialog - it spawned inside an already-trusted session
# and the worktree never got an entry of its own. Confirmed: no worktree-shaped key exists in a
# ~\.claude.json with 41 projects in it. Under herdr the worker is a fresh launch in a directory
# Claude Code has never seen, so it stops and asks, and herdr reports agent_not_ready while the
# agent sits blocked.
#
# The alternative was to let dispatch answer the dialog with a synthetic keystroke. This is
# preferred because it is a written, inspectable record made before launch rather than a blind
# key sent at a security prompt, and because it cannot race. It is still a real grant, so it is
# deliberately narrow: exactly the worktree kingshand just created, never its parent repo.
#
# THE FILE IS EDITED THROUGH JsonNode, NOT ConvertFrom-Json -AsHashtable. A real ~\.claude.json
# on this machine contains both 'D:/code' and 'd:/code'. PowerShell hashtables
# are case-insensitive, so an -AsHashtable round trip merges those two keys and writes back a
# file with one of them silently gone - it would destroy a user's project history to save four
# lines. Plain ConvertFrom-Json refuses outright with "keys with different casing", which is the
# same hazard announcing itself.
function Grant-ClaudeFolderTrust {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$ConfigPath
    )

    if (-not $ConfigPath) { $ConfigPath = Join-Path $env:USERPROFILE '.claude.json' }
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        # No config yet means Claude Code has never run here. Writing a trust file on its behalf
        # would be guessing at a schema we have not seen, so leave it: the worker will stop at
        # the dialog and dispatch reports that plainly.
        return [pscustomobject]@{ granted = $false; reason = 'no-config'; key = $null }
    }

    # Keys are stored with forward slashes and the drive letter preserved.
    $key = ($Path -replace '\\', '/').TrimEnd('/')

    $text = Get-Content -LiteralPath $ConfigPath -Raw
    $root = [System.Text.Json.Nodes.JsonNode]::Parse($text)
    if (-not $root['projects']) {
        return [pscustomobject]@{ granted = $false; reason = 'no-projects'; key = $key }
    }

    $before = $root['projects'].Count
    if ($root['projects'][$key]) {
        return [pscustomobject]@{ granted = $true; reason = 'already'; key = $key }
    }

    $root['projects'][$key] = [System.Text.Json.Nodes.JsonNode]::Parse('{"hasTrustDialogAccepted":true}')

    $opts = [System.Text.Json.JsonSerializerOptions]::new()
    $opts.WriteIndented = $true

    # Written through a temp file and moved into place. This is the user's own Claude Code
    # config; a partial write from an interrupted dispatch would take their whole project list
    # with it.
    $tmp = "$ConfigPath.kingshand-tmp"
    [IO.File]::WriteAllText($tmp, $root.ToJsonString($opts))

    $check = [System.Text.Json.Nodes.JsonNode]::Parse([IO.File]::ReadAllText($tmp))
    if ($check['projects'].Count -ne ($before + 1)) {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        throw ("Refusing to write $ConfigPath - project count would go from $before to " +
               "$($check['projects'].Count) instead of $($before + 1). Nothing was changed.")
    }

    Move-Item -LiteralPath $tmp -Destination $ConfigPath -Force
    [pscustomobject]@{ granted = $true; reason = 'written'; key = $key }
}

Export-ModuleMember -Function Set-WorkerWorkspaceSettings, Grant-ClaudeFolderTrust
