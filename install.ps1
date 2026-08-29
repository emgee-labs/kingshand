#Requires -Version 7.0
<#
.SYNOPSIS
  Sets up kingshand on this machine: checks prerequisites and writes the configuration that is
  one answer per machine.
  It writes at most four things outside this repository, and names each one as it does it: the two
  user environment variables KINGSHAND_HOME and LAVISH_AXI_PORT, the line `.claude/worktrees/` in
  your global gitignore, and - only on a machine where Claude Code resolves to npm's claude.cmd
  wrapper - the real claude.exe put first on your user PATH. Nothing else on the machine is touched. The
  skills live in this repository's own `.claude\skills\`, so nothing is linked into
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
.PARAMETER AddressAs
  How the Hand should address you, written into instructions.md as it is created - "my Queen",
  "my King", "boss", your own name, anything. Only ever applied when instructions.md is being
  created; a file you already wrote is never touched. The Hand cannot write this itself: the
  permission layer denies it edits to instructions.md, which is the point of that file.
.PARAMETER WithReviewGate
  Also install `no-mistakes`, the review gate the `no-mistakes` and `no-mistakes-prod-only`
  postures run their pull requests through. Off by default and deliberately a separate switch
  from -InstallMissing: it is a whole delivery flow, not a missing dependency, and someone who
  only ever wants work to stop at a clean local branch should never be made to install it.
.EXAMPLE
  .\install.ps1
.EXAMPLE
  .\install.ps1 -InstallMissing -ProjectRoot C:\repos
.EXAMPLE
  .\install.ps1 -InstallMissing -WithReviewGate
.EXAMPLE
  .\install.ps1 -ProjectRoot C:\repos -ProjectRoot 'D:\work projects'
#>
[CmdletBinding()]
param(
    [string[]]$ProjectRoot = @(),
    [string]$AddressAs,
    [switch]$Force,
    [switch]$InstallMissing,
    [switch]$WithReviewGate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Root = $PSScriptRoot
Import-Module (Join-Path $Root 'bin\Paths.psm1') -Force
# herdr is discovered through the module that owns its command line, never by a second copy of the
# rule written out here. It is not on PATH, so Get-Command would report it missing on a machine
# where it is installed and working perfectly.
Import-Module (Join-Path $Root 'bin\Herdr.psm1') -Force

# Set by Test-Prerequisite. Initialised here because StrictMode makes an unset variable an error,
# and this one is only assigned on the machines that have the problem.
$script:ClaudeIsWrapper = $false

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
#
#    A tool marked Optional is one a working installation may never need.
#    It is reported NOTE rather than MISS, and never sets this script's exit code.
#    Telling someone whose install is fine that it is broken is how a report stops
#    being read at all, and that costs the failures that are real.
#    -InstallMissing still installs them: the flag is consent to install what can be
#    installed, and neither gh nor Pester is a download anyone would notice. The
#    review gate is the one thing that stays behind its own switch, because it is
#    14 MB and a whole delivery flow rather than a missing dependency.
# --------------------------------------------------------------------------------
$tools = @(
    @{ Name = 'claude';     Manager = 'npm';    Install = 'npm install -g @anthropic-ai/claude-code'; What = 'Claude Code' }
    @{ Name = 'git';        Manager = 'winget'; Install = 'winget install --id Git.Git';              What = 'Git for Windows' }
    @{ Name = 'lavish-axi'; Manager = 'npm';    Install = 'npm install -g lavish-axi';                What = 'the review surface' }
    @{ Name = 'tasks-axi';  Manager = 'npm';    Install = 'npm install -g tasks-axi';                 What = 'the durable backlog' }
    # Only a push-capable posture opens a pull request, and only a pull request needs gh.
    # Someone whose work stops at a finished local branch never calls it, so it never blocks here.
    # `annex` closes the gap that leaves, by refusing a push-capable posture on a machine with no gh.
    @{ Name = 'gh';         Manager = 'winget'; Install = 'winget install --id GitHub.cli';           What = 'GitHub CLI - only push-capable postures need it, then: gh auth login'; Optional = $true }
)

$pesterInstall = 'Install-Module Pester -MinimumVersion 6.0.0 -Force -SkipPublisherCheck -Scope CurrentUser'

# Missing optional tools from the last detection pass. Kept beside $missing rather than inside it
# so that the summary at the end can list what is genuinely blocking dispatch and nothing else.
$optional = @()

# Detection is a function because -InstallMissing has to run it twice. Installing a thing is not
# evidence that it installed: the second call is what turns a claim into a check.
function Test-Prerequisite {
    $still     = [System.Collections.Generic.List[hashtable]]::new()
    $alsoLater = [System.Collections.Generic.List[hashtable]]::new()

    Write-Ok ("PowerShell {0}" -f $PSVersionTable.PSVersion)

    foreach ($t in $tools) {
        $found = Get-Command $t.Name -ErrorAction SilentlyContinue
        if ($found) { Write-Ok ("{0,-12} {1}" -f $t.Name, $found.Source) }
        elseif ($t.Contains('Optional') -and $t.Optional) {
            Write-Host ("  NOTE  {0,-12} {1} - not required. Add it with: {2}" -f $t.Name, $t.What, $t.Install)
            $alsoLater.Add($t)
        }
        else {
            Write-Miss ("{0,-12} {1} - install with: {2}" -f $t.Name, $t.What, $t.Install)
            $still.Add($t)
        }
    }

    # The executable, and specifically WHICH form of it. npm's claude.cmd wrapper forwards with %*,
    # which lets cmd.exe re-parse the quotes inside an argument, so anything carrying JSON arrives
    # truncated. The review gate passes a JSON schema on every agent step, so a wrapper-only machine
    # fails the whole pipeline instantly with an error about JSON and no clue that PATH is the cause.
    $claudeExe = Get-ClaudeCommandPath
    if ($claudeExe) {
        Write-Ok ("{0,-12} {1}" -f 'claude.exe', $claudeExe)
        if (Test-ClaudeCommandIsWrapper -Path $claudeExe) { $script:ClaudeIsWrapper = $true }
    }
    else {
        Write-Miss (Get-ClaudeCommandHint)
        $still.Add(@{
            Name = 'claude'; Manager = 'npm'
            Install = 'npm install -g @anthropic-ai/claude-code'; What = 'Claude Code itself'
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

    # Pester is a contributor dependency, not a runtime one.
    # It runs kingshand's own test suite; nothing under bin\ and no skill imports it, so an
    # installation without it dispatches, gates and lands exactly as well as one with it.
    # It was reported MISS and counted towards a non-zero exit, which told a brand-new user with a
    # perfectly working install that it was broken.
    $pester = Get-Module -ListAvailable -Name Pester |
              Where-Object { $_.Version.Major -ge 6 } |
              Sort-Object Version -Descending | Select-Object -First 1
    if ($pester) { Write-Ok ("{0,-12} {1}" -f 'Pester', $pester.Version) }
    else {
        Write-Host ("  NOTE  {0,-12} {1}" -f 'Pester', 'runs this repository''s own tests and nothing else - not needed to use kingshand.')
        Write-Host "        To verify this clone or contribute to it: $pesterInstall"
        # Pester comes from the PowerShell Gallery, not from a package manager, so -InstallMissing
        # handles it on its own path rather than shelling out to npm or winget.
        $alsoLater.Add(@{ Name = 'Pester'; Manager = 'psgallery'; Install = $pesterInstall; What = 'the test suite' })
    }

    $script:optional = @($alsoLater)
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

# The review gate, fetched from its GitHub release rather than a package manager.
#
# Its own published installer is a POSIX `sh` script that branches on `uname`, so it does not run
# here - but the release does carry a Windows build, which is what this uses. Verified against
# v1.57.0, whose assets are no-mistakes-v<tag>-windows-<arch>.zip alongside a checksums.txt of
# "<sha256>  <filename>" lines.
#
# Same contract as herdr: verify before extracting, and refuse rather than install something that
# does not match. This one downloads roughly 14 MB.
function Install-NoMistakes {
    param([Parameter(Mandatory)][string]$Destination)

    $arch = switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture) {
        'Arm64' { 'arm64' }
        default { 'amd64' }
    }

    Write-Host '  RUN   fetch https://api.github.com/repos/kunchenguid/no-mistakes/releases/latest'
    $release = $null
    try {
        $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/kunchenguid/no-mistakes/releases/latest' `
                                     -Headers @{ 'User-Agent' = 'kingshand-installer' } -TimeoutSec 30 -ErrorAction Stop
    } catch {
        Write-Miss 'the review gate was not installed: its release feed could not be reached.'
        Write-Host  '        This machine looks offline, or GitHub is unreachable. Nothing was downloaded.'
        Write-Host  '        Reconnect and run: .\install.ps1 -WithReviewGate'
        return $false
    }

    $asset = @($release.assets | Where-Object { $_.name -like "*windows-$arch.zip" }) | Select-Object -First 1
    $sums  = @($release.assets | Where-Object { $_.name -eq 'checksums.txt' })        | Select-Object -First 1
    if (-not $asset -or -not $sums) {
        # No digest means no way to verify, and an unverifiable binary is not installed at all.
        Write-Miss "the review gate was not installed: $($release.tag_name) publishes no windows-$arch build, or no checksums.txt for one."
        return $false
    }

    $temp = Join-Path ([IO.Path]::GetTempPath()) ('nm-' + [guid]::NewGuid().ToString('N') + '.zip')
    Write-Host "  RUN   download $($asset.name)"
    try {
        $sumText = Invoke-RestMethod -Uri $sums.browser_download_url -Headers @{ 'User-Agent' = 'kingshand-installer' } -TimeoutSec 60 -ErrorAction Stop
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $temp -TimeoutSec 600 -ErrorAction Stop
    } catch {
        Write-Miss "the review gate $($release.tag_name) was not installed: the download failed."
        Write-Host  '        This machine looks offline, or GitHub is unreachable. Nothing was extracted.'
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        return $false
    }

    $want = $null
    foreach ($line in ($sumText -split "`n")) {
        $parts = ($line.Trim() -split '\s+')
        if ($parts.Count -ge 2 -and $parts[-1] -eq $asset.name) { $want = $parts[0]; break }
    }
    if (-not $want) {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        Write-Miss "the review gate was not installed: checksums.txt names no digest for $($asset.name)."
        return $false
    }

    $actual = (Get-FileHash -LiteralPath $temp -Algorithm SHA256).Hash
    if (-not $actual.Equals($want, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        Write-Miss "the review gate $($release.tag_name) FAILED its SHA-256 check and was NOT extracted."
        Write-Host  "        expected $want"
        Write-Host  "        got      $actual"
        Write-Host  "        The download has been deleted and nothing was written to $Destination."
        return $false
    }
    Write-Ok "the review gate $($release.tag_name) matches its published SHA-256."

    if (-not (Test-Path -LiteralPath $Destination)) {
        New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    }
    Expand-Archive -LiteralPath $temp -DestinationPath $Destination -Force
    Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue

    # Flattened for the same reason herdr's is: Get-NoMistakesCommandPath looks for exactly
    # tools\no-mistakes\no-mistakes.exe and should not have to guess at an archive's shape.
    $exe = Join-Path $Destination 'no-mistakes.exe'
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
        $found = @(Get-ChildItem -Path $Destination -Filter 'no-mistakes.exe' -Recurse -File) | Select-Object -First 1
        if ($found) { Move-Item -LiteralPath $found.FullName -Destination $exe -Force }
    }
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
        Write-Miss "the review gate unpacked, but no no-mistakes.exe was found under $Destination."
        return $false
    }

    Write-Did "the review gate $($release.tag_name) installed to $Destination. It is deliberately not added to PATH."
    Write-Host '        Initialise it per repository before dispatching `no-mistakes` work there.'
    $true
}

Write-Step 'Prerequisites'
$missing = @(Test-Prerequisite)

# The review gate is optional and stays optional. It is gated on its own switch rather than on
# -InstallMissing, because wanting every prerequisite installed is not the same as wanting a review
# pipeline: someone whose projects all stop at a clean local branch never needs this, and a 14 MB
# download they did not ask for is not a favour. `setup` asks which flow they want and passes the
# switch accordingly, so the choice is made in words rather than in flags.
$reviewGate = Get-NoMistakesCommandPath
if ($reviewGate) {
    Write-Ok ("{0,-12} {1}" -f 'no-mistakes', $reviewGate)
} elseif ($WithReviewGate) {
    Write-Step 'Installing the review gate'
    if (Install-NoMistakes -Destination (Join-Path $Root 'tools\no-mistakes')) {
        $actions.Add('tools\no-mistakes\')
    }
} else {
    Write-Host ("  NOTE  no-mistakes is not installed, and nothing needs it unless you register a " +
                "project ``no-mistakes`` or ``no-mistakes-prod-only``. To add it: .\install.ps1 " +
                "-WithReviewGate - it is a GitHub release, checked against its published SHA-256. " +
                "Do NOT ``npm install -g no-mistakes``: that name belongs to a different, unrelated tool.")
}

if ($InstallMissing -and ($missing.Count + $optional.Count) -gt 0) {
    Write-Step 'Installing what is missing'

    # Blockers and optionals are installed by the same machinery, and only reported differently.
    # -InstallMissing is consent to install what can be installed, so gh and Pester go in here too;
    # what their Optional flag buys is that their absence never reads as a broken install and never
    # sets the exit code.
    $installable = @($missing) + @($optional)

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
        $names = @($installable | Where-Object { $_.Manager -eq $manager } | ForEach-Object { $_.Name })
        if ($names.Count -eq 0) { continue }
        Write-Miss ("{0} cannot be installed: {1} is not on PATH." -f ($names -join ', '), $manager)
        Write-Host ("        " + $blocked[$manager])
    }

    # One command per package, not one per tool: `claude` and `claude.cmd` are the same npm install
    # and running it twice would report a second success for work that already happened.
    $planned = [ordered]@{}
    foreach ($m in $installable) {
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
    if (@($installable | Where-Object { $_.Manager -eq 'herdr' }).Count -gt 0) {
        Write-Host '  FOR   herdr'
        # Recorded in $actions, not discarded. A run that downloads and extracts a binary and then
        # signs off with "changed: nothing - this installation was already set up" is telling the
        # reader something false about their own machine, and the summary is the part people keep.
        if (Install-Herdr -Destination (Join-Path $Root 'tools\herdr')) {
            $actions.Add('tools\herdr\')
        }
    }

    if (@($installable | Where-Object { $_.Manager -eq 'psgallery' }).Count -gt 0) {
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

# Put the real claude.exe ahead of npm's claude.cmd wrapper.
#
# The wrapper forwards with %*, so cmd.exe re-parses the quotes inside an argument and anything
# carrying JSON arrives cut at the first one. The review gate passes a JSON schema on every agent
# step, so on a wrapper-only machine every step dies instantly with "--json-schema is not valid
# JSON: JSON Parse error: Expected '}'" - an error that names JSON and never mentions PATH. That is
# a genuinely awful thing to debug, and this is one line of PATH.
#
# PATHEXT prefers .EXE over .CMD, so a directory holding claude.exe placed first wins outright.
# Only done when the resolved command really is the wrapper: a machine that already finds the
# binary is left completely alone.
if ($script:ClaudeIsWrapper) {
    $claudeBin = Join-Path $env:APPDATA 'npm\node_modules\@anthropic-ai\claude-code\bin'
    if (Test-Path -LiteralPath (Join-Path $claudeBin 'claude.exe')) {
        $userPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
        $already  = @(($userPath -split ';') | Where-Object { $_.TrimEnd('\') -ieq $claudeBin.TrimEnd('\') })
        if ($already.Count -gt 0) {
            Write-Ok 'claude.exe is already ahead of the npm wrapper on your PATH.'
        } else {
            [Environment]::SetEnvironmentVariable('PATH', ($claudeBin + ';' + $userPath), 'User')
            Write-Did "claude.exe put first on your PATH: $claudeBin"
            Write-Host '        npm''s claude.cmd wrapper corrupts arguments containing quotes, which breaks the review gate.'
            $actions.Add('PATH (claude.exe first)')
        }
    } else {
        Write-Host ('  NOTE  ' + (Get-ClaudeWrapperHint))
    }
}

# --------------------------------------------------------------------------------
# 3. The global gitignore. Workers live in <repo>\.claude\worktrees\ inside the user's
#    OWN repository, so without this line every dispatched worker shows up as untracked
#    changes in a repository kingshand does not own and must not commit to.
#
#    This is the third and last thing written outside this repository, and the header
#    says so. It used to be nowhere: the prereq check failed on the missing line and
#    nothing here ever wrote it, so every new machine failed that check by definition
#    with only "add it by hand" as the fix.
#
#    Three rules, and they are the whole of the care this needs.
#    Never duplicate the line: an installer run twice must leave exactly one.
#    Never rewrite or reorder a file the user already had - the only write to a file
#    that already exists is one appended line.
#    And print the file that was touched, because a script quietly editing a dotfile
#    in someone's home directory should at minimum say which one.
# --------------------------------------------------------------------------------
Write-Step 'Global gitignore'

$ignoreLine = '.claude/worktrees/'

if (-not (Get-Command 'git' -ErrorAction SilentlyContinue)) {
    Write-Miss 'git is not on PATH, so the global gitignore was left alone. Install git and run this again.'
} else {
    # `git config --global core.excludesFile` exits 1 and prints nothing when the key is unset,
    # which is the ordinary state on a fresh machine rather than an error. It is read into a local
    # and LASTEXITCODE is reset, so an unset key does not leak a failure into anything after it.
    $configured = & git config --global core.excludesFile 2>$null | Select-Object -First 1
    $global:LASTEXITCODE = 0
    if ($configured) { $configured = $configured.Trim() }

    # git writes this value with a literal `~` when it was set that way, and PowerShell's file
    # cmdlets do not expand it. Expanding here rather than at each use keeps one meaning of the path.
    $excludesPath = if ($configured) {
        if ($configured -eq '~') { $HOME }
        elseif ($configured -match '^~[\\/]') { Join-Path $HOME $configured.Substring(2) }
        else { $configured }
    } else {
        Join-Path $HOME '.gitignore_global'
    }

    if (-not (Test-Path -LiteralPath $excludesPath)) {
        $parent = Split-Path -Parent $excludesPath
        if ($parent -and -not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Force -Path $parent | Out-Null
        }
        Set-Content -LiteralPath $excludesPath -Value $ignoreLine -Encoding utf8
        Write-Did "created $excludesPath with the line $ignoreLine"
        $actions.Add('global gitignore')
    } elseif (@(Get-Content -LiteralPath $excludesPath | Where-Object { $_.Trim() -eq $ignoreLine }).Count -gt 0) {
        Write-Ok "$excludesPath already ignores $ignoreLine"
    } else {
        # A file that does not end in a newline would otherwise have this line glued onto its last
        # one, silently changing a pattern the user wrote. Add-Content with an empty string appends
        # the missing terminator and nothing else.
        $existing = Get-Content -LiteralPath $excludesPath -Raw
        if ($existing -and -not $existing.EndsWith("`n")) { Add-Content -LiteralPath $excludesPath -Value '' }
        Add-Content -LiteralPath $excludesPath -Value $ignoreLine
        Write-Did "appended $ignoreLine to $excludesPath - nothing else in that file was changed"
        $actions.Add('global gitignore')
    }

    if (-not $configured) {
        # Forward slashes on purpose: git treats a backslash in a config value as an escape, and a
        # Windows path written raw comes back out of `git config` mangled.
        $forGit = $excludesPath -replace '\\', '/'
        & git config --global core.excludesFile $forGit
        Write-Did "git config --global core.excludesFile now names $forGit"
        $actions.Add('core.excludesFile')
    }
}

# --------------------------------------------------------------------------------
# 4. instructions.md. The King's own standing word. Copied from the tracked template
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
    # The address is substituted HERE, by this script, and never by the Hand. `.claude\settings.json`
    # denies Edit on instructions.md - that rule is what keeps the King's own stated words out of the
    # Hand's reach - so the Hand physically cannot write down the answer it just asked for. It passes
    # -AddressAs and the installer does it, which keeps the deny rule intact rather than carving an
    # exception into it.
    $body = Get-Content -LiteralPath $template -Raw
    if ($AddressAs) {
        # Replace the quoted title only, so the surrounding paragraph - which explains that this is a
        # form of address and how to turn it off - survives whatever they chose.
        $body = $body -replace '(?<=\*\*Address me as ")your Highness(?="\.\*\*)', $AddressAs.Replace('$', '$$')
    }
    Set-Content -LiteralPath $instructions -Value $body -Encoding utf8 -NoNewline
    if ($AddressAs) {
        Write-Did "instructions.md created, addressing you as `"$AddressAs`". Change it whenever you like - the Hand reads this file and never writes it."
    } else {
        Write-Did "instructions.md created from the template. Edit it - the Hand reads it and never writes it."
    }
    $actions.Add('instructions.md')
}

# --------------------------------------------------------------------------------
# 5. Local directories and config. Everything here is gitignored on purpose.
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
#
# Azure DevOps is optional in full: the MCP server muster reaches for is not a prerequisite, is
# installed by nothing here, and needs an organization and a token nobody who does not use ADO has.
# Without it muster treats every request as adhoc, which is the ordinary path.
$ado = Join-Path $Root 'config\ado.json'
if (Test-Path -LiteralPath $ado) { Write-Ok 'config\ado.json exists' }
else { Write-Host '  NOTE  Azure DevOps integration is optional and nothing here needs it. config\ado.json is deliberately absent; describe work in your own words and it is handled as adhoc. If you do work ADO tickets, the Hand asks for your organization and project the first time it needs them and offers to write them here - and fetching a ticket by id also needs the ado-local-mcp server configured in Claude Code, which this script does not install.' }

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
    Write-Host '  NOTE  no -ProjectRoot given, and you probably do not need one. The Hand runs with bypassPermissions, which already reaches repositories on any drive - annex a path and it works. Pass -ProjectRoot <path> only if you narrow that permission mode.'
}

# --------------------------------------------------------------------------------
# 6. What happened, and what is left.
# --------------------------------------------------------------------------------
Write-Step 'Summary'

if ($actions.Count -gt 0) { Write-Host ("  changed: " + ($actions -join ', ')) }
else { Write-Host '  changed: nothing - this installation was already set up.' }

if ($skipped.Count -gt 0) {
    Write-Host ("  left alone: " + ($skipped -join ', '))
    Write-Host '  Nothing above was overwritten. Re-run with -Force where you meant to replace it.'
}

# Listed, never counted. These are things a working installation may never need, so they belong in
# the summary as a choice the reader can make later rather than in the blocking list below.
if ($optional.Count -gt 0) {
    Write-Host ""
    Write-Host "Optional, and nothing is broken without them:"
    $optional | ForEach-Object { Write-Host ("  - {0}: {1}" -f $_.Name, $_.Install) }
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
