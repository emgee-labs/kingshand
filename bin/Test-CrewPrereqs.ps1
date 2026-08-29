#Requires -Version 7.0
<#
.SYNOPSIS
  Verifies every dependency the dispatch layer needs. Exits 1 when one is missing.
.DESCRIPTION
  Detect-only. It installs nothing and configures nothing - `install.ps1` does that once, and this
  runs on every session start behind the digest, where a silent pass is the good outcome.

  Every failure line names the concrete command that fixes it. A check that reports "missing"
  without saying what to install is a check the reader learns to ignore.

  A failure is something dispatch cannot work without. Everything a working installation may
  legitimately never need is a NOTE, and a NOTE never changes the exit code: the review gate, the
  GitHub CLI, and Pester. Reporting FAILED on a machine where nothing is actually broken teaches
  the reader to ignore the whole report, which costs the failures that are real.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$failures = @()
$notes    = @()

Import-Module (Join-Path $PSScriptRoot 'Paths.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Herdr.psm1') -Force

function Test-Tool {
    param([string]$Name, [string]$Hint, [switch]$Optional)
    $found = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $found) {
        if ($Optional) { $script:notes += "$Name not found. $Hint" }
        else { $script:failures += "$Name not found. $Hint" }
        return
    }
    Write-Host ("  OK  {0,-14} {1}" -f $Name, $found.Source)
}

Write-Host "Checking crew prerequisites"

Test-Tool -Name 'claude'     -Hint 'Install Claude Code: npm install -g @anthropic-ai/claude-code'
Test-Tool -Name 'git'        -Hint 'Install Git for Windows: https://git-scm.com/download/win'
Test-Tool -Name 'lavish-axi' -Hint 'Run: npm install -g lavish-axi'
Test-Tool -Name 'tasks-axi'  -Hint 'Run: npm install -g tasks-axi'

# `gh` opens the pull request, and only a push-capable posture ever needs one. A user whose
# projects are all `local-only` - work that stops at a finished branch on this machine - never
# calls it, so its absence is a note rather than a failure, exactly like the review gate below.
# The gap that leaves is closed where it belongs: `annex` refuses to register `direct-PR`,
# `no-mistakes` or `no-mistakes-prod-only` against a machine with no `gh`, naming this command.
Test-Tool -Name 'gh' -Optional `
    -Hint ('Needed only by a push-capable posture - `direct-PR`, `no-mistakes` or ' +
           '`no-mistakes-prod-only`. Install with: winget install --id GitHub.cli - then run: ' +
           'gh auth login. Work that stops at a finished local branch never needs it.')

# The shim, resolved rather than assumed. Dispatch cannot spawn a worker without it, and the whole
# reason it is looked up by name is that its location differs per machine.
$claudeCmd = Get-ClaudeCommandPath
if ($claudeCmd) {
    Write-Host ("  OK  {0,-14} {1}" -f 'claude.cmd', $claudeCmd)
} else {
    $failures += (Get-ClaudeCommandHint)
}

# herdr, resolved through the module that owns its command line rather than through Get-Command.
# It is deliberately not on PATH - it lives in tools\herdr\ - so a name lookup would report it
# missing on a machine where it is installed and working, and a second copy of the discovery rule
# here is exactly how the two would drift apart.
#
# This is a failure, not a note. Every worker is now spawned and steered through herdr, so an
# absent herdr means nothing can be dispatched at all - the same class of problem as a missing
# claude.cmd, and reported the same way. The `claude` and `claude.cmd` checks above still stand:
# herdr launches `claude` inside its pane, so the shim's discovery still matters.
$herdr = Get-HerdrCommandPath

if ($herdr) {
    Write-Host ("  OK  {0,-14} {1}" -f 'herdr', $herdr)
} else {
    $failures += (Get-HerdrCommandHint)
}

# Only the `no-mistakes` posture needs the review gate, and a user who registers nothing that way
# never installs it. So it is a note rather than a failure - `muster` Step 1b already refuses to
# dispatch a `no-mistakes` task against a repo where the gate is not initialised.
$gate = Get-NoMistakesCommandPath
if ($gate) {
    Write-Host ("  OK  {0,-14} {1}" -f 'no-mistakes', $gate)
} else {
    $notes += (Get-NoMistakesHint)
}

# Pester runs kingshand's own test suite and nothing else. No script in bin\ and no skill imports
# it, so a user who never runs `Invoke-Pester -Path tests` has a completely working installation
# without it. That makes it a contributor dependency, and a note - it was a failure, which meant a
# perfectly good install reported FAILED for a test framework the user had no reason to want.
$pester = Get-Module -ListAvailable -Name Pester |
          Where-Object { $_.Version.Major -ge 6 } |
          Sort-Object Version -Descending | Select-Object -First 1
if ($pester) { Write-Host ("  OK  {0,-14} {1}" -f 'Pester', $pester.Version) }
else {
    $notes += ('Pester 6+ not found. It runs kingshand''s own test suite and nothing at runtime ' +
               'needs it. To contribute or verify this clone: Install-Module Pester ' +
               '-MinimumVersion 6.0.0 -Force -SkipPublisherCheck -Scope CurrentUser')
}

$port = [Environment]::GetEnvironmentVariable('LAVISH_AXI_PORT', 'User')
if ($port -eq '4388') { Write-Host "  OK   lavish port    4388" }
else { $failures += "LAVISH_AXI_PORT is '$port', expected 4388. Run: [Environment]::SetEnvironmentVariable('LAVISH_AXI_PORT','4388','User') - WSL's lavish on 4387 will otherwise hijack Windows requests." }

# This stays a failure, and it is now one a user can actually clear: `install.ps1` sets it up, the
# same way it sets LAVISH_AXI_PORT above. It used to fail on every fresh machine by definition,
# because nothing in the repository ever wrote the line and the only advice was to do it by hand.
$excludes = git config --global core.excludesFile
if ($excludes -and (Test-Path $excludes) -and (Select-String -Path $excludes -Pattern '\.claude/worktrees/' -Quiet)) {
    Write-Host ("  OK   gitignore     {0}" -f $excludes)
} else {
    $failures += 'Global gitignore does not cover .claude/worktrees/. Run: .\install.ps1 - it appends the line .claude/worktrees/ to the file named by core.excludesFile, and creates that file and points the config at it when the config is unset. Otherwise workers appear as untracked changes in your repos.'
}

if ($notes.Count -gt 0) {
    Write-Host ""
    $notes | ForEach-Object { Write-Host "  NOTE $_" }
}

if ($failures.Count -gt 0) {
    Write-Host ""; Write-Host "FAILED:"
    $failures | ForEach-Object { Write-Host "  - $_" }
    exit 1
}

Write-Host ""; Write-Host "All prerequisites satisfied."
exit 0
