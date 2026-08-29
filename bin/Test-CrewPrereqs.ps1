#Requires -Version 7.0
<#
.SYNOPSIS
  Verifies every dependency the dispatch layer needs. Exits 1 when one is missing.
.DESCRIPTION
  Detect-only. It installs nothing and configures nothing - `install.ps1` does that once, and this
  runs on every session start behind the digest, where a silent pass is the good outcome.

  Every failure line names the concrete command that fixes it. A check that reports "missing"
  without saying what to install is a check the reader learns to ignore.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$failures = @()
$notes    = @()

Import-Module (Join-Path $PSScriptRoot 'Paths.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Herdr.psm1') -Force

function Test-Tool {
    param([string]$Name, [string]$Hint)
    $found = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $found) { $script:failures += "$Name not found. $Hint"; return }
    Write-Host ("  OK  {0,-14} {1}" -f $Name, $found.Source)
}

Write-Host "Checking crew prerequisites"

Test-Tool -Name 'claude'     -Hint 'Install Claude Code: npm install -g @anthropic-ai/claude-code'
Test-Tool -Name 'git'        -Hint 'Install Git for Windows: https://git-scm.com/download/win'
Test-Tool -Name 'gh'         -Hint 'Install GitHub CLI (winget install GitHub.cli) and run: gh auth login'
Test-Tool -Name 'lavish-axi' -Hint 'Run: npm install -g lavish-axi'
Test-Tool -Name 'tasks-axi'  -Hint 'Run: npm install -g tasks-axi'

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

$pester = Get-Module -ListAvailable -Name Pester |
          Where-Object { $_.Version.Major -ge 6 } |
          Sort-Object Version -Descending | Select-Object -First 1
if ($pester) { Write-Host ("  OK  {0,-14} {1}" -f 'Pester', $pester.Version) }
else { $failures += 'Pester 6+ not found. Run: Install-Module Pester -MinimumVersion 6.0.0 -Force -SkipPublisherCheck -Scope CurrentUser' }

$port = [Environment]::GetEnvironmentVariable('LAVISH_AXI_PORT', 'User')
if ($port -eq '4388') { Write-Host "  OK   lavish port    4388" }
else { $failures += "LAVISH_AXI_PORT is '$port', expected 4388. Run: [Environment]::SetEnvironmentVariable('LAVISH_AXI_PORT','4388','User') - WSL's lavish on 4387 will otherwise hijack Windows requests." }

$excludes = git config --global core.excludesFile
if ($excludes -and (Test-Path $excludes) -and (Select-String -Path $excludes -Pattern '\.claude/worktrees/' -Quiet)) {
    Write-Host ("  OK   gitignore     {0}" -f $excludes)
} else {
    $failures += 'Global gitignore does not cover .claude/worktrees/. Add the line .claude/worktrees/ to the file named by: git config --global core.excludesFile - otherwise workers appear as untracked changes in your repos.'
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
