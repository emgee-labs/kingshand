#Requires -Version 7.0
<#
.SYNOPSIS
  Sets up kingshand on this machine: checks prerequisites and writes the configuration that is
  one answer per machine.
  It never writes anything outside this repository except the two user environment variables
  below. The skills live in this repository's own `.claude\skills\`, so nothing is linked into
  `~\.claude\skills\` and a Claude Code session in any other directory is unaffected.
.DESCRIPTION
  Idempotent. Running it twice does nothing the second time except say so. It never overwrites an
  existing `instructions.md` or an existing config value without telling you which file it left
  alone and what it would have written.

  It installs nothing by default. A missing prerequisite is reported with the exact command that
  installs it, because a script that silently `npm install -g`s things into a user's machine is a
  script nobody should run. `-InstallMissing` is the opt-in that runs those commands: the flag is
  the consent, and every command is printed before it runs so nothing happens off-screen.

.PARAMETER ProjectRoot
  A directory your repositories live under. Repeatable. Added to .claude\settings.json so the
  session can reach them - nothing is dispatched into a directory the session cannot read.
.PARAMETER Force
  Overwrite an existing instructions.md and existing config values. Off by default, and the only
  way this script replaces something you wrote.
.PARAMETER InstallMissing
  Run the install command for every missing prerequisite instead of only naming it. Off by
  default. Each command is printed before it runs, every tool is re-checked afterwards rather
  than assumed installed, and nothing self-elevates: an install that needs administrator rights
  is reported with the command to run in an elevated shell.
.EXAMPLE
  .\install.ps1
.EXAMPLE
  .\install.ps1 -InstallMissing -ProjectRoot C:\repos
.EXAMPLE
  .\install.ps1 -ProjectRoot C:\repos -ProjectRoot 'D:\work projects'
#>
[CmdletBinding()]
param(
    [string[]]$ProjectRoot = @(),
    [switch]$Force,
    [switch]$InstallMissing
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Root = $PSScriptRoot
Import-Module (Join-Path $Root 'bin\Paths.psm1') -Force
# herdr is discovered through the module that owns its command line, never by a second copy of the
# rule written out here. It is not on PATH, so Get-Command would report it missing on a machine
# where it is installed and working perfectly.
Import-Module (Join-Path $Root 'bin\Herdr.psm1') -Force

$actions = [System.Collections.Generic.List[string]]::new()
$skipped = [System.Collections.Generic.List[string]]::new()

function Write-Step { param([string]$Text) Write-Host ""; Write-Host "== $Text" }
function Write-Ok   { param([string]$Text) Write-Host "  OK    $Text" }
function Write-Miss { param([string]$Text) Write-Host "  MISS  $Text" }
function Write-Kept { param([string]$Text) Write-Host "  KEPT  $Text" }
function Write-Did  { param([string]$Text) Write-Host "  DONE  $Text" }

# --------------------------------------------------------------------------------
# 1. Prerequisites. Detect only by default - every miss names the command that fixes
#    it. With -InstallMissing, run those commands, printing each before it runs.
# --------------------------------------------------------------------------------
$tools = @(
    @{ Name = 'claude';     Manager = 'npm';    Install = 'npm install -g @anthropic-ai/claude-code'; What = 'Claude Code' }
    @{ Name = 'git';        Manager = 'winget'; Install = 'winget install --id Git.Git';              What = 'Git for Windows' }
    @{ Name = 'gh';         Manager = 'winget'; Install = 'winget install --id GitHub.cli';           What = 'GitHub CLI, then: gh auth login' }
    @{ Name = 'lavish-axi'; Manager = 'npm';    Install = 'npm install -g lavish-axi';                What = 'the review surface' }
    @{ Name = 'tasks-axi';  Manager = 'npm';    Install = 'npm install -g tasks-axi';                 What = 'the durable backlog' }
)

$pesterInstall = 'Install-Module Pester -MinimumVersion 6.0.0 -Force -SkipPublisherCheck -Scope CurrentUser'

# Detection is a function because -InstallMissing has to run it twice. Installing a thing is not
# evidence that it installed: the second call is what turns a claim into a check.
function Test-Prerequisite {
    $still = [System.Collections.Generic.List[hashtable]]::new()

    Write-Ok ("PowerShell {0}" -f $PSVersionTable.PSVersion)

    foreach ($t in $tools) {
        $found = Get-Command $t.Name -ErrorAction SilentlyContinue
        if ($found) { Write-Ok ("{0,-12} {1}" -f $t.Name, $found.Source) }
        else {
            Write-Miss ("{0,-12} {1} - install with: {2}" -f $t.Name, $t.What, $t.Install)
            $still.Add($t)
        }
    }

    # The shim specifically, not `claude`. Start-Process cannot launch the .ps1 that `claude`
    # resolves to on Windows, so dispatch spawns claude.cmd - and a `claude` that resolves without
    # a .cmd beside it is a toolchain that passes every other check and still cannot dispatch a
    # worker.
    $claudeCmd = Get-ClaudeCommandPath
    if ($claudeCmd) { Write-Ok ("{0,-12} {1}" -f 'claude.cmd', $claudeCmd) }
    else {
        Write-Miss (Get-ClaudeCommandHint)
        $still.Add(@{
            Name = 'claude.cmd'; Manager = 'npm'
            Install = 'npm install -g @anthropic-ai/claude-code'; What = 'the shim dispatch spawns'
        })
    }

    # herdr, which every worker is spawned and steered through. It is deliberately NOT put on PATH:
    # it lives in tools\herdr\ so that installing kingshand cannot change what `herdr` means in any
    # other shell on this machine, and nothing outside this repository starts depending on it.
    # A herdr the user already has on PATH is honoured first - Get-HerdrCommandPath owns both halves
    # of that rule, and this only reports what it found.
    $herdr = Get-HerdrCommandPath

    if ($herdr) { Write-Ok ("{0,-12} {1}" -f 'herdr', $herdr) }
    else {
        Write-Miss ("{0,-12} {1} - install with: .\install.ps1 -InstallMissing" -f 'herdr', 'the worker spawner')
        # Manager 'herdr' is its own thing on purpose. It has no package manager behind it - the
        # download and the SHA-256 check below are the install - and giving it a manager name that
        # the generic loop understood would have that loop run `.\install.ps1 -InstallMissing` from
        # inside `.\install.ps1 -InstallMissing`.
        $still.Add(@{
            Name = 'herdr'; Manager = 'herdr'
            Install = '.\install.ps1 -InstallMissing'; What = 'the worker spawner'
        })
    }

    $pester = Get-Module -ListAvailable -Name Pester |
              Where-Object { $_.Version.Major -ge 6 } |
              Sort-Object Version -Descending | Select-Object -First 1
    if ($pester) { Write-Ok ("{0,-12} {1}" -f 'Pester', $pester.Version) }
    else {
        Write-Miss "Pester       6+ not found - install with: $pesterInstall"
        # Pester comes from the PowerShell Gallery, not from a package manager, so -InstallMissing
        # handles it on its own path rather than shelling out to npm or winget.
        $still.Add(@{ Name = 'Pester'; Manager = 'psgallery'; Install = $pesterInstall; What = 'the test suite' })
    }

    $still
}

# A winget install writes the machine PATH, which this process was started with and will not see.
# Add what the registry now has rather than replacing PATH, so nothing set for this session is
# lost. Called after any install that may have put a new tool on disk.
function Update-PathFromRegistry {
    $fromRegistry = @(
        [Environment]::GetEnvironmentVariable('PATH', 'Machine')
        [Environment]::GetEnvironmentVariable('PATH', 'User')
    ) -join ';'
    $current   = @($env:PATH -split ';')
    $additions = @($fromRegistry -split ';' | Where-Object { $_ -and $_ -notin $current })
    if ($additions.Count -gt 0) { $env:PATH = $env:PATH.TrimEnd(';') + ';' + ($additions -join ';') }
}

# Printed, then run, then reported. The flag is the consent; a command nobody saw is not consent,
# so the command goes to the screen before anything executes.
function Invoke-InstallCommand {
    param([Parameter(Mandatory)][string]$Command)
    Write-Host "  RUN   $Command"
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $global:LASTEXITCODE = 0
    try {
        & ([scriptblock]::Create($Command)) 2>&1 | ForEach-Object { Write-Host "        $_" }
        return ($LASTEXITCODE -eq 0)
    } catch {
        Write-Host "        $($_.Exception.Message)"
        return $false
    } finally {
        $ErrorActionPreference = $previous
    }
}

# Fetches herdr into tools\herdr\ and proves it is the file herdr.dev published before unpacking it.
#
# https://herdr.dev/latest.json is the source of truth. It carries `version`, `protocol`, the
# download under `assets.windows-x86_64` and its digest under `sha256.windows-x86_64`, so a newer
# herdr installs without editing this script. kingshand's command line was verified against
# herdr 0.8.2, protocol 20 - a different protocol still installs, and says so, because
# bin\Herdr.psm1 was proven against that one and nothing else.
#
# THE SHA-256 IS COMPARED BEFORE ANYTHING IS EXTRACTED. This is an executable being put onto a
# user's machine from the network, and a truncated download and a substituted one are
# indistinguishable until the digest is checked. An archive that has already been unpacked cannot
# be un-unpacked, so the download lands in a temp file, the digest is compared there, and a
# mismatch deletes the file and returns without writing a single byte into tools\herdr\.
function Install-Herdr {
    param([Parameter(Mandatory)][string]$Destination)

    # StrictMode turns a missing property into an exception, so every field of a file fetched over
    # the network is read through this rather than dereferenced and hoped for.
    function Get-ManifestValue {
        param($Object, [string]$Name)
        if ($Object -and $Object.PSObject.Properties.Name -contains $Name) { return $Object.$Name }
        $null
    }

    $manifestUrl = 'https://herdr.dev/latest.json'
    Write-Host "  RUN   fetch $manifestUrl"

    $manifest = $null
    try {
        $manifest = Invoke-RestMethod -Uri $manifestUrl -TimeoutSec 30 -ErrorAction Stop
    } catch {
        # Being offline is an ordinary state for a laptop, not a crash. A raw web exception here
        # prints a stack of .NET type names over a fact the user can act on in one line, so the
        # fact is what gets printed and the exception is not rethrown.
        Write-Miss "herdr was not installed: $manifestUrl could not be reached."
        Write-Host  "        This machine looks offline, or herdr.dev is down. Nothing was downloaded and nothing was changed."
        Write-Host  "        Reconnect and run: .\install.ps1 -InstallMissing"
        return $false
    }

    $version  = Get-ManifestValue $manifest 'version'
    $protocol = Get-ManifestValue $manifest 'protocol'
    $asset    = Get-ManifestValue (Get-ManifestValue $manifest 'assets') 'windows-x86_64'
    $expected = Get-ManifestValue (Get-ManifestValue $manifest 'sha256') 'windows-x86_64'

    if (-not $asset -or -not $expected) {
        # No digest means no way to verify, and an unverifiable binary is not installed at all.
        Write-Miss 'herdr was not installed: latest.json named no windows-x86_64 build, or no SHA-256 for one.'
        Write-Host  "        Nothing was downloaded. Put herdr.exe in $Destination by hand if you have it, then re-run this."
        return $false
    }

    if ($asset -notmatch '^https?://') { $asset = 'https://herdr.dev/' + $asset.TrimStart('/') }
    $want = ($expected -replace '^sha256:', '').Trim()

    $temp = Join-Path ([IO.Path]::GetTempPath()) (
        'herdr-' + [guid]::NewGuid().ToString('N') + [IO.Path]::GetExtension(([uri]$asset).AbsolutePath))

    Write-Host "  RUN   download $asset"
    try {
        Invoke-WebRequest -Uri $asset -OutFile $temp -TimeoutSec 300 -ErrorAction Stop
    } catch {
        Write-Miss "herdr $version was not installed: $asset could not be downloaded."
        Write-Host  '        This machine looks offline, or herdr.dev is down. Nothing was extracted.'
        Write-Host  '        Reconnect and run: .\install.ps1 -InstallMissing'
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        return $false
    }

    $actual = (Get-FileHash -LiteralPath $temp -Algorithm SHA256).Hash
    if (-not $actual.Equals($want, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        Write-Miss "herdr $version FAILED its SHA-256 check and was NOT extracted."
        Write-Host  "        expected $want"
        Write-Host  "        got      $actual"
        Write-Host  "        The download has been deleted and nothing was written to $Destination."
        Write-Host  '        A mismatch is either a corrupted download or a file that is not the one herdr.dev published. Do not install it by hand until you know which.'
        return $false
    }
    Write-Ok "herdr $version matches the published SHA-256: $want"

    if (-not (Test-Path -LiteralPath $Destination)) {
        New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    }

    if ([IO.Path]::GetExtension($temp) -eq '.zip') {
        Expand-Archive -LiteralPath $temp -DestinationPath $Destination -Force
    } else {
        Copy-Item -LiteralPath $temp -Destination (Join-Path $Destination 'herdr.exe') -Force
    }
    Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue

    # bin\Herdr.psm1 looks for tools\herdr\herdr.exe and nothing else, so an archive that nests the
    # binary one directory down is flattened here rather than left for the discovery rule to guess.
    $exe = Join-Path $Destination 'herdr.exe'
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
        $found = @(Get-ChildItem -Path $Destination -Filter 'herdr.exe' -Recurse -File) | Select-Object -First 1
        if ($found) { Move-Item -LiteralPath $found.FullName -Destination $exe -Force }
    }
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
        Write-Miss "herdr $version unpacked, but no herdr.exe was found under $Destination."
        return $false
    }

    Write-Did "herdr $version installed to $Destination. It is deliberately not added to PATH."
    if ("$protocol" -ne '20') {
        Write-Host ("        NOTE  kingshand was verified against herdr 0.8.2, protocol 20; this build reports " +
                    "protocol $protocol. It is installed anyway - if dispatch misbehaves, suspect this first.")
    }
    $true
}

Write-Step 'Prerequisites'
$missing = @(Test-Prerequisite)

# Optional: only projects registered `no-mistakes` need the review gate, and muster refuses to
# dispatch such a task against a repo where it is not initialised. So this is a note, never a stop,
# and -InstallMissing never installs it - it has no package-manager source in this list.
if (Get-Command 'no-mistakes' -ErrorAction SilentlyContinue) {
    Write-Ok ("{0,-12} {1}" -f 'no-mistakes', (Get-Command 'no-mistakes').Source)
} else {
    Write-Host ("  NOTE  no-mistakes is not on PATH and is never installed by -InstallMissing. Only " +
                "projects registered ``no-mistakes`` need it; put it in $(Join-Path $Root 'tools\no-mistakes') " +
                "if you want that posture.")
}

if ($InstallMissing -and $missing.Count -gt 0) {
    Write-Step 'Installing what is missing'

    # Only winget is a true floor: it ships with Windows as part of App Installer and cannot
    # install itself. npm is not - it comes with Node.js, which winget installs - so when winget
    # is present an absent npm is a step to take, not a wall to stop at.
    $blocked = [ordered]@{}
    $hasWinget = [bool](Get-Command 'winget' -ErrorAction SilentlyContinue)

    if (-not (Get-Command 'npm' -ErrorAction SilentlyContinue)) {
        if ($hasWinget) {
            Write-Host '  npm is missing. Installing Node.js, which provides it.'
            if (Invoke-InstallCommand 'winget install --id OpenJS.NodeJS.LTS --silent --accept-package-agreements --accept-source-agreements') {
                Update-PathFromRegistry
            }
            if (-not (Get-Command 'npm' -ErrorAction SilentlyContinue)) {
                $blocked['npm'] = 'Node.js installed but npm is still not on PATH. Open a new shell and run this script again.'
            } else {
                Write-Did 'npm is available.'
            }
        } else {
            $blocked['npm'] = 'Install Node.js from https://nodejs.org, then run this again.'
        }
    }

    if (-not $hasWinget) {
        $blocked['winget'] = 'Install App Installer from the Microsoft Store, then run this again. It carries winget, which cannot install itself.'
    }
    foreach ($manager in @($blocked.Keys)) {
        $names = @($missing | Where-Object { $_.Manager -eq $manager } | ForEach-Object { $_.Name })
        if ($names.Count -eq 0) { continue }
        Write-Miss ("{0} cannot be installed: {1} is not on PATH." -f ($names -join ', '), $manager)
        Write-Host ("        " + $blocked[$manager])
    }

    # One command per package, not one per tool: `claude` and `claude.cmd` are the same npm install
    # and running it twice would report a second success for work that already happened.
    $planned = [ordered]@{}
    foreach ($m in $missing) {
        if ($m.Manager -eq 'psgallery' -or $m.Manager -eq 'herdr' -or $blocked.Contains($m.Manager)) { continue }
        if ($planned.Contains($m.Install)) { $planned[$m.Install] = "$($planned[$m.Install]), $($m.Name)" }
        else { $planned[$m.Install] = $m.Name }
    }

    foreach ($command in @($planned.Keys)) {
        $for = $planned[$command]
        Write-Host "  FOR   $for"
        if (Invoke-InstallCommand -Command $command) {
            Write-Did "$for reported success."
        } else {
            Write-Miss "$for did not install."
            # Never self-elevate. Re-launching this script as administrator would install into a
            # different user's profile than the one being set up here.
            Write-Host "        If that failed for want of administrator rights, run this in an elevated PowerShell: $command"
            Write-Host "        This script does not elevate itself."
        }
    }

    # herdr comes from herdr.dev rather than a package manager, so it runs on its own path the same
    # way Pester does. It goes into this copy's tools\herdr\, which is gitignored: an 8.4 MB binary
    # does not belong in a repository people clone.
    if (@($missing | Where-Object { $_.Manager -eq 'herdr' }).Count -gt 0) {
        Write-Host '  FOR   herdr'
        $null = Install-Herdr -Destination (Join-Path $Root 'tools\herdr')
    }

    if (@($missing | Where-Object { $_.Manager -eq 'psgallery' }).Count -gt 0) {
        Write-Host "  FOR   Pester"
        Write-Host "  RUN   $pesterInstall"
        try {
            Install-Module Pester -MinimumVersion 6.0.0 -Force -SkipPublisherCheck -Scope CurrentUser -ErrorAction Stop
            Write-Did 'Pester reported success.'
        } catch {
            Write-Miss "Pester did not install: $($_.Exception.Message)"
            Write-Host "        -Scope CurrentUser needs no elevation, so this is the gallery or the network rather than rights."
        }
    }

    Update-PathFromRegistry

    # Re-check rather than assume success, and let the rest of the script run with whatever is
    # now present.
    Write-Step 'Prerequisites, re-checked'
    $missing = @(Test-Prerequisite)
}

# --------------------------------------------------------------------------------
# 2. KINGSHAND_HOME. Skills spell their commands with it; bin\ derives it when unset,
#    so this is a convenience rather than a requirement.
# --------------------------------------------------------------------------------
Write-Step 'KINGSHAND_HOME'

$currentHome = [Environment]::GetEnvironmentVariable('KINGSHAND_HOME', 'User')
if ($currentHome -eq $Root) {
    Write-Ok "KINGSHAND_HOME is already $Root"
} elseif ($currentHome -and -not $Force) {
    Write-Kept "KINGSHAND_HOME is set to $currentHome, not $Root. Left alone - re-run with -Force to change it."
    # Naming the variable is not enough. It wins over a script's own location, so this copy runs
    # its own code against the other installation's registry, workers and queue - which reads as
    # data appearing from nowhere rather than as a misconfiguration.
    Write-Host "        Until then this copy reads its projects, workers and queue from $currentHome, not from here."
    $skipped.Add('KINGSHAND_HOME')
} else {
    [Environment]::SetEnvironmentVariable('KINGSHAND_HOME', $Root, 'User')
    $env:KINGSHAND_HOME = $Root
    Write-Did "KINGSHAND_HOME set to $Root for your user. Open a new shell for it to take effect."
    $actions.Add('KINGSHAND_HOME')
}

# Windows lavish must own 4388; WSL's lavish on 4387 answers Windows requests silently and fails
# with an opaque 500, which looks like a broken review surface rather than a wrong port.
$port = [Environment]::GetEnvironmentVariable('LAVISH_AXI_PORT', 'User')
if ($port -eq '4388') {
    Write-Ok 'LAVISH_AXI_PORT is 4388'
} elseif ($port -and -not $Force) {
    Write-Kept "LAVISH_AXI_PORT is '$port', expected 4388. Left alone - re-run with -Force to change it."
    $skipped.Add('LAVISH_AXI_PORT')
} else {
    [Environment]::SetEnvironmentVariable('LAVISH_AXI_PORT', '4388', 'User')
    Write-Did 'LAVISH_AXI_PORT set to 4388 for your user.'
    $actions.Add('LAVISH_AXI_PORT')
}

# --------------------------------------------------------------------------------
# 3. instructions.md. The King's own standing word. Copied from the tracked template
#    once, then never touched again by anything - including this script.
# --------------------------------------------------------------------------------
Write-Step 'Standing instructions'

$instructions = Join-Path $Root 'instructions.md'
$template     = Join-Path $Root 'instructions.example.md'

if (Test-Path -LiteralPath $instructions) {
    if ($Force) {
        Write-Kept "instructions.md exists and holds your own words. NOT overwritten, even with -Force."
    } else {
        Write-Kept 'instructions.md already exists. Left exactly as it is.'
    }
    $skipped.Add('instructions.md')
} elseif (-not (Test-Path -LiteralPath $template)) {
    Write-Miss "instructions.example.md is missing from $Root, so nothing was copied."
} else {
    Copy-Item -LiteralPath $template -Destination $instructions
    Write-Did "instructions.md created from the template. Edit it - the Hand reads it and never writes it."
    $actions.Add('instructions.md')
}

# --------------------------------------------------------------------------------
# 4. Local directories and config. Everything here is gitignored on purpose.
# --------------------------------------------------------------------------------
Write-Step 'Local state and config'

foreach ($dir in @('data', 'state', 'config')) {
    $path = Join-Path $Root $dir
    if (Test-Path -LiteralPath $path) { Write-Ok "$dir\ exists" }
    else { New-Item -ItemType Directory -Force -Path $path | Out-Null; Write-Did "created $dir\"; $actions.Add("$dir\") }
}

$budget = Join-Path $Root 'config\startup-memory-budget'
if (Test-Path -LiteralPath $budget) {
    Write-Kept ("startup-memory-budget already reads {0}. Left alone." -f (Get-Content $budget -Raw).Trim())
    $skipped.Add('startup-memory-budget')
} else {
    Set-Content -LiteralPath $budget -Value '7500' -NoNewline -Encoding utf8
    Write-Did 'startup-memory-budget written as 7500.'
    $actions.Add('startup-memory-budget')
}

# Deliberately NOT created. muster asks for the organization and project when this file is absent,
# and a file full of placeholders would be answered as though it were configured.
$ado = Join-Path $Root 'config\ado.json'
if (Test-Path -LiteralPath $ado) { Write-Ok 'config\ado.json exists' }
else { Write-Host '  NOTE  config\ado.json is deliberately absent. The Hand will ask for your Azure DevOps organization and project the first time it needs them, and offer to write them here.' }

if ($ProjectRoot.Count -gt 0) {
    $settingsPath = Join-Path $Root '.claude\settings.json'
    $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
    $current = @($settings.permissions.additionalDirectories)
    $added = @($ProjectRoot | Where-Object { $_ -and $_ -notin $current })
    if ($added.Count -eq 0) {
        Write-Ok 'every -ProjectRoot is already in .claude\settings.json'
    } else {
        $settings.permissions.additionalDirectories = @($current + $added)
        $settings | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $settingsPath -Encoding utf8
        Write-Did ("added to .claude\settings.json: {0}" -f ($added -join ', '))
        $actions.Add('additionalDirectories')
    }
} else {
    Write-Host '  NOTE  no -ProjectRoot given. Add the roots your repositories live under to .claude\settings.json, or re-run with -ProjectRoot <path>.'
}

# --------------------------------------------------------------------------------
# 5. What happened, and what is left.
# --------------------------------------------------------------------------------
Write-Step 'Summary'

if ($actions.Count -gt 0) { Write-Host ("  changed: " + ($actions -join ', ')) }
else { Write-Host '  changed: nothing - this installation was already set up.' }

if ($skipped.Count -gt 0) {
    Write-Host ("  left alone: " + ($skipped -join ', '))
    Write-Host '  Nothing above was overwritten. Re-run with -Force where you meant to replace it.'
}

if ($missing.Count -gt 0) {
    Write-Host ""
    Write-Host "Install these before dispatching anything:"
    $missing | ForEach-Object { Write-Host ("  - {0}: {1}" -f $_.Name, $_.Install) }
    Write-Host ""
    Write-Host "Then re-run: .\install.ps1"
    exit 1
}

Write-Host ""
Write-Host "Ready. Open a new shell, start Claude Code in $Root, and run /annex on a repo."
exit 0
