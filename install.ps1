#Requires -Version 7.0
<#
.SYNOPSIS
  Sets up kingshand on this machine - Windows, macOS or Linux: checks prerequisites and writes the
  configuration that is one answer per machine.
  It writes at most four things outside this repository, and names each one as it does it: on
  Windows the two user environment variables KINGSHAND_HOME and LAVISH_AXI_PORT, the lines
  `.claude/worktrees/` and `.claude/settings.local.json` in your global gitignore, and - only on a
  Windows machine where Claude Code resolves to npm's claude.cmd wrapper - the real claude.exe put
  first on your user PATH. macOS and Linux have no user environment variables, so there the same
  two values go into the `env` block of this repository's own gitignored
  `.claude/settings.local.json`, which Claude Code puts into every session started here. Nothing
  else on the machine is touched. The skills live in this repository's own `.claude\skills\`, so
  nothing is linked into `~\.claude\skills\` and a Claude Code session in any other directory is
  unaffected.

  Run it as `.\install.ps1` on Windows and `pwsh ./install.ps1` on macOS and Linux.
.DESCRIPTION
  Idempotent. Running it twice does nothing the second time except say so. It never overwrites an
  existing `instructions.md` or an existing config value without telling you which file it left
  alone and what it would have written.

  It installs nothing by default. A missing prerequisite is reported with the exact command that
  installs it, because a script that silently `npm install -g`s things into a user's machine is a
  script nobody should run. `-InstallMissing` is the opt-in that runs those commands: the flag is
  the consent, and every command is printed before it runs so nothing happens off-screen.
  `-SyncPins` is the same kind of consent for one narrower thing: moving what is already installed
  to the versions dependencies.json pins.

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
  is reported with the command to run in an elevated shell. git, gh and Node.js come from the
  system package manager: winget on Windows and Homebrew on macOS are run; on Linux every package
  manager needs sudo, so the exact command for the distribution found is printed and nothing is
  run.
.PARAMETER AddressAs
  How the Hand should address you, written into instructions.md as it is created - "my Queen",
  "my King", "boss", your own name, anything. Only ever applied when instructions.md is being
  created; a file you already wrote is never touched. The Hand cannot write this itself: the
  permission layer denies it edits to instructions.md, which is the point of that file.
.PARAMETER SyncPins
  Move every installed dependency to the version dependencies.json pins for this release, and
  report each move. `/update` runs this after it fast-forwards, so nobody has to. It never moves a
  dependency past its pin, only replaces the copies this installer put under tools\ - a copy you
  manage on PATH is reported with the command and left alone - and never replaces herdr while its
  server is running. -InstallMissing does the same moves as well as installing what is missing.
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
.EXAMPLE
  pwsh ./install.ps1 -InstallMissing
  The same on macOS or Linux, where the file is handed to pwsh by name.
#>
[CmdletBinding()]
param(
    [string[]]$ProjectRoot = @(),
    [string]$AddressAs,
    [switch]$Force,
    [switch]$InstallMissing,
    [switch]$SyncPins,
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
# The pinned versions every dependency is installed at. bin\Dependencies.psm1 owns the manifest and
# every version read; this script only acts on what it answers.
Import-Module (Join-Path $Root 'bin\Dependencies.psm1') -Force
# The env block macOS and Linux keep their per-machine values in. bin\ClaudeWorkspace.psm1 owns how
# that file is read and edited.
Import-Module (Join-Path $Root 'bin\ClaudeWorkspace.psm1') -Force
$pins = @{}
foreach ($p in (Read-DependencyPins -Path (Get-DependencyManifestPath -Root $Root))) { $pins[$p.name] = $p }

# Everything below that differs by operating system asks bin\Paths.psm1 rather than testing the
# platform itself: which system package manager installs git, gh and Node.js, and whether this
# script may run it or only print its commands.
$platform      = Get-KingshandPlatform
$packages      = Get-SystemPackageManager
$systemManager = if ($packages.name) { $packages.name } else { 'system' }
$rerun         = Get-InstallerCommand

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
    @{ Name = 'git';        Manager = $systemManager; Install = (Get-SystemPackageHint -Tool git); What = $(if ($platform -eq 'Windows') { 'Git for Windows' } else { 'git' }) }
    @{ Name = 'lavish-axi'; Manager = 'npm';    Install = (Get-DependencySyncCommand -Pin $pins['lavish-axi']); What = 'the review surface' }
    @{ Name = 'tasks-axi';  Manager = 'npm';    Install = (Get-DependencySyncCommand -Pin $pins['tasks-axi']);  What = 'the durable backlog' }
    # Only a push-capable posture opens a pull request, and only a pull request needs gh.
    # Someone whose work stops at a finished local branch never calls it, so it never blocks here.
    # `annex` closes the gap that leaves, by refusing a push-capable posture on a machine with no gh.
    @{ Name = 'gh';         Manager = $systemManager; Install = (Get-SystemPackageHint -Tool gh); What = 'GitHub CLI - only push-capable postures need it, then: gh auth login'; Optional = $true }
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

    # Every npm command above fails on a machine with no Node.js, which is every fresh Windows
    # machine, so Node is named first rather than left for "npm is not recognized" to reveal.
    # Its manager is its own: -InstallMissing installs it on its own path, before anything npm
    # installs, and the generic loop must not run it a second time.
    $needsNpm = @($still | Where-Object { $_.Manager -eq 'npm' }).Count -gt 0
    if ($needsNpm -and -not (Get-NpmCommand)) {
        Write-Miss ("{0,-12} {1}" -f 'npm', (Get-NpmMissingHint))
        $still.Insert(0, @{
            Name = 'Node.js'; Manager = 'nodejs'
            Install = (Get-SystemPackageHint -Tool node); What = 'npm, which the tools above install through'
        })
    }

    # The executable, and specifically WHICH form of it. npm's claude.cmd wrapper forwards with %*,
    # which lets cmd.exe re-parse the quotes inside an argument, so anything carrying JSON arrives
    # truncated. The review gate passes a JSON schema on every agent step, so a wrapper-only machine
    # fails the whole pipeline instantly with an error about JSON and no clue that PATH is the cause.
    $claudeExe = Get-ClaudeCommandPath
    if ($claudeExe) {
        Write-Ok ("{0,-12} {1}" -f (Get-ExecutableName 'claude'), $claudeExe)
        if (Test-ClaudeCommandIsWrapper -Path $claudeExe) { $script:ClaudeIsWrapper = $true }
    }
    elseif (@($still | Where-Object { $_.Name -eq 'claude' }).Count -eq 0) {
        # Only where `claude` itself resolved and neither form of it did. Where `claude` is missing
        # outright the loop above has already said so, and saying it twice reads as two problems.
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
        Write-Miss ("{0,-12} {1} - install with: {2}" -f 'herdr', 'the worker spawner', (Get-InstallerCommand '-InstallMissing'))
        # Manager 'herdr' is its own thing on purpose. It has no package manager behind it - the
        # download and the SHA-256 check below are the install - and giving it a manager name that
        # the generic loop understood would have that loop run `.\install.ps1 -InstallMissing` from
        # inside `.\install.ps1 -InstallMissing`.
        $still.Add(@{
            Name = 'herdr'; Manager = 'herdr'
            Install = (Get-InstallerCommand '-InstallMissing'); What = 'the worker spawner'
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
#
# Windows only. macOS and Linux keep no machine or user PATH for .NET to read - the shell profile
# builds PATH - and Homebrew installs into a directory its own setup already put on it.
function Update-PathFromRegistry {
    if ($platform -ne 'Windows') { return }
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
    # npm runs through the shim bin\Dependencies.psm1 picks, which is the one that keeps its
    # arguments; the command printed above stays the one a person would type.
    $run = $Command
    if ($Command.StartsWith('npm ')) {
        $npm = Get-NpmCommand
        if ($npm) { $run = "& '$($npm.Replace("'", "''"))' " + $Command.Substring(4) }
    }
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $global:LASTEXITCODE = 0
    try {
        & ([scriptblock]::Create($run)) 2>&1 | ForEach-Object { Write-Host "        $_" }
        return ($LASTEXITCODE -eq 0)
    } catch {
        Write-Host "        $($_.Exception.Message)"
        return $false
    } finally {
        $ErrorActionPreference = $previous
    }
}

# Why `npm install -g` would fail for this user on macOS or Linux, as the line that fixes it, or
# $null where nothing stands in its way. A Node.js from a system package puts npm's global prefix
# under a root-owned directory, so every global install fails with EACCES; pointing the prefix at a
# directory in the user's home is the fix npm itself documents, and needs no sudo. A prefix npm will
# not report is $null rather than a guess - the install then runs and says for itself what failed.
function Get-NpmGlobalProblem {
    $npm = Get-NpmCommand
    if (-not $npm) { return $null }
    $prefix = (& $npm prefix -g 2>$null | Select-Object -First 1)
    $global:LASTEXITCODE = 0
    if (-not $prefix) { return $null }
    $prefix = "$prefix".Trim()
    $target = Join-Path $prefix 'lib' 'node_modules'
    if (-not (Test-Path -LiteralPath $target -PathType Container)) { $target = $prefix }
    $probe = Join-Path $target ('.kingshand-write-' + [guid]::NewGuid().ToString('N'))
    try {
        [IO.File]::WriteAllText($probe, '')
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        return $null
    } catch {
        ("npm installs global packages under $prefix, which this user cannot write, so every " +
         'npm install -g would fail with EACCES. Point npm at your home instead: ' +
         'npm config set prefix ~/.npm-global - add ~/.npm-global/bin to PATH in your shell ' +
         'profile, open a new shell, then run this again. No sudo needed.')
    }
}

# Adds the execute bit for owner, group and others to a file on macOS or Linux, keeping the rest of
# its mode. Through .NET rather than `chmod`, so it does not depend on what PATH holds.
function Set-ExecutableBit {
    param([Parameter(Mandatory)][string]$Path)
    $exec = [IO.UnixFileMode]::UserExecute -bor [IO.UnixFileMode]::GroupExecute -bor
            [IO.UnixFileMode]::OtherExecute
    [IO.File]::SetUnixFileMode($Path, [IO.File]::GetUnixFileMode($Path) -bor $exec)
}

# Fetches the pinned herdr into tools\herdr\ and proves it is the file herdr.dev published before
# unpacking it.
#
# THE PIN DECIDES WHICH HERDR, AND latest.json SAYS WHERE IT IS. dependencies.json names the version
# and protocol bin\Herdr.psm1 was verified against - herdr 0.9.5, protocol 22 - and the SHA-256 of
# each platform's download. https://herdr.dev/latest.json carries a `releases` map keyed by version,
# and the pinned version's entry there gives the download. A newer herdr published since is never
# installed by this: moving the pin is a maintainer's change, made in dependencies.json after
# bin\Herdr.psm1 has been re-verified against it.
#
# THE SHA-256 IS COMPARED BEFORE ANYTHING IS EXTRACTED, against the pin and against latest.json both.
# This is an executable being put onto a user's machine from the network, and a truncated download
# and a substituted one are indistinguishable until the digest is checked. An archive that has
# already been unpacked cannot be un-unpacked, so the download lands in a temp file, the digest is
# compared there, and a mismatch deletes the file and returns without writing a single byte into
# tools\herdr\. A latest.json whose digest for the pinned version differs from the pin is refused
# too: one of the two records is wrong, and installing would mean guessing which.
#
# A HERDR ALREADY IN tools\herdr\ IS REPLACED ONLY WITH ITS SERVER STOPPED. A running server keeps
# every worker's pane, and a binary swapped underneath it leaves a client and server on two
# protocols that cannot talk - so a running server, or one whose state cannot be read, is a refusal
# that says what to do. The new build is unpacked beside the old one first, under a name only this
# run uses, and the old one is only removed once the new one is known to be whole.
function Install-Herdr {
    param(
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)]$Pin
    )

    # StrictMode turns a missing property into an exception, so every field of a file fetched over
    # the network is read through this rather than dereferenced and hoped for.
    function Get-ManifestValue {
        param($Object, [string]$Name)
        if ($Object -and $Object.PSObject.Properties.Name -contains $Name) { return $Object.$Name }
        $null
    }

    $version = $Pin.version

    # Which build, and what it is called once it is here, come from bin\Paths.psm1: windows-x86_64
    # as herdr.exe, or macos-/linux-<arch> as a bare herdr. A machine herdr publishes nothing for
    # is a refusal naming it, before anything is fetched.
    try { $key = Get-HerdrPlatformKey }
    catch {
        Write-Miss "herdr $version was not installed: $($_.Exception.Message)"
        return $false
    }
    $exeName = Get-ExecutableName 'herdr'
    $pinned  = Get-HerdrPinnedDigest -Pin $Pin
    if (-not $pinned) {
        Write-Miss "herdr $version was not installed: dependencies.json pins no SHA-256 for $key."
        Write-Host  '        Nothing was downloaded. An unverifiable binary is not installed at all.'
        return $false
    }

    $exe = Join-Path $Destination $exeName
    if (Test-Path -LiteralPath $exe -PathType Leaf) {
        $replace = Test-HerdrReplaceable
        if (-not $replace.ok) {
            Write-Miss "herdr $version was not installed over the herdr in $Destination."
            Write-Host  "        $($replace.reason)"
            return $false
        }
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
        Write-Host  "        Reconnect and run: $(Get-InstallerCommand '-InstallMissing')"
        return $false
    }

    # The pinned version's own entry. The top level describes whatever is newest, which is the
    # pinned version only until herdr publishes another.
    $release = Get-ManifestValue (Get-ManifestValue $manifest 'releases') $version
    if (-not $release -and "$(Get-ManifestValue $manifest 'version')" -eq $version) { $release = $manifest }
    if (-not $release) {
        Write-Miss "herdr $version was not installed: $manifestUrl no longer lists it."
        Write-Host  '        Nothing was downloaded. The pin in dependencies.json needs a maintainer to move it.'
        return $false
    }

    $protocol = Get-ManifestValue $release 'protocol'
    $asset    = Get-ManifestValue (Get-ManifestValue $release 'assets') $key
    $expected = Get-ManifestValue (Get-ManifestValue $release 'sha256') $key

    if (-not $asset -or -not $expected) {
        # No digest means no way to verify, and an unverifiable binary is not installed at all.
        Write-Miss "herdr $version was not installed: latest.json named no $key build, or no SHA-256 for one."
        Write-Host  "        Nothing was downloaded. Put $exeName in $Destination by hand if you have it, then re-run this."
        return $false
    }

    if ($asset -notmatch '^https?://') { $asset = 'https://herdr.dev/' + $asset.TrimStart('/') }
    $want = ($expected -replace '^sha256:', '').Trim().ToLowerInvariant()
    if ($want -ne $pinned) {
        Write-Miss "herdr $version was not installed: latest.json publishes a different SHA-256 for it than dependencies.json pins."
        Write-Host  "        pinned    $pinned"
        Write-Host  "        published $want"
        Write-Host  '        Nothing was downloaded. One of the two records is wrong, and installing would mean guessing which.'
        return $false
    }
    if ("$protocol" -ne "$($Pin.protocol)") {
        Write-Miss "herdr $version was not installed: latest.json says it speaks protocol $protocol, and dependencies.json pins protocol $($Pin.protocol)."
        return $false
    }

    $temp = Join-Path ([IO.Path]::GetTempPath()) (
        'herdr-' + [guid]::NewGuid().ToString('N') + [IO.Path]::GetExtension(([uri]$asset).AbsolutePath))

    Write-Host "  RUN   download $asset"
    try {
        Invoke-WebRequest -Uri $asset -OutFile $temp -TimeoutSec 300 -ErrorAction Stop
    } catch {
        Write-Miss "herdr $version was not installed: $asset could not be downloaded."
        Write-Host  '        This machine looks offline, or herdr.dev is down. Nothing was extracted.'
        Write-Host  "        Reconnect and run: $(Get-InstallerCommand '-InstallMissing')"
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
    Write-Ok "herdr $version matches the pinned and published SHA-256: $want"

    $parent = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    $staging = Join-Path $parent ('herdr.new-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $staging | Out-Null

    # Windows gets a zip; macOS and Linux get the binary itself, which is copied in under its bare
    # name and given its execute bit - a download never carries one.
    try {
        if ([IO.Path]::GetExtension($temp) -eq '.zip') {
            Expand-Archive -LiteralPath $temp -DestinationPath $staging -Force
        } else {
            Copy-Item -LiteralPath $temp -Destination (Join-Path $staging $exeName) -Force
        }
    } finally {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
    }

    # bin\Herdr.psm1 looks for tools\herdr\<herdr.exe or herdr> and nothing else, so an archive that
    # nests the binary one directory down is flattened here rather than left for the discovery rule
    # to guess. The directory it sits in moves with it: 0.9.x ships its console host beside the
    # binary.
    $found = @(Get-ChildItem -Path $staging -Filter $exeName -Recurse -File) | Select-Object -First 1
    if (-not $found) {
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
        Write-Miss "herdr $version unpacked, but no $exeName was in it. Nothing in $Destination was changed."
        return $false
    }
    if ($platform -ne 'Windows') { Set-ExecutableBit -Path $found.FullName }
    $unpacked = Split-Path -Parent $found.FullName

    # The old copy is moved aside rather than deleted first, so a move that fails part way puts it
    # back and the machine is never left with no herdr at all.
    $old = $null
    try {
        if (Test-Path -LiteralPath $Destination) {
            $old = Join-Path $parent ('herdr.old-' + [guid]::NewGuid().ToString('N'))
            Move-Item -LiteralPath $Destination -Destination $old -ErrorAction Stop
        }
        Move-Item -LiteralPath $unpacked -Destination $Destination -ErrorAction Stop
        if ($old) { Remove-Item -LiteralPath $old -Recurse -Force -ErrorAction SilentlyContinue }
    } catch {
        if ($old -and (Test-Path -LiteralPath $old) -and -not (Test-Path -LiteralPath $Destination)) {
            Move-Item -LiteralPath $old -Destination $Destination -ErrorAction SilentlyContinue
        }
        Write-Miss "herdr $version was verified but could not replace $Destination - $($_.Exception.Message)"
        Write-Host  '        A herdr process is probably still using it. The herdr that was there is still there.'
        return $false
    } finally {
        if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue }
    }

    Write-Did "herdr $version, protocol $protocol, installed to $Destination. It is deliberately not added to PATH."
    $true
}

# The review gate, fetched from its GitHub release rather than a package manager.
#
# Its own published installer is a POSIX `sh` script that branches on `uname`, so it does not run
# on Windows - and is not used anywhere, so every system takes one path. The release carries a build
# per system: no-mistakes-v<tag>-windows-<arch>.zip, and -darwin-<arch>.tar.gz and
# -linux-<arch>.tar.gz, alongside a checksums.txt of "<sha256>  <filename>" lines. Verified against
# v1.84.0. A tar.gz is unpacked with the `tar` macOS and Linux both ship, which Expand-Archive cannot
# read.
#
# Same contract as herdr: verify before extracting, and refuse rather than install something that
# does not match. This one downloads roughly 14 MB.
#
# The release fetched is the one dependencies.json pins, by its tag, never whatever is latest - from
# the repository the pin names, which is kunchenguid/no-mistakes.
function Install-NoMistakes {
    param(
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)]$Pin
    )

    $arch = switch (Get-KingshandArchitecture) {
        'Arm64' { 'arm64' }
        default { 'amd64' }
    }
    $os, $archive = switch ($platform) {
        'Windows' { 'windows', 'zip' }
        'MacOS'   { 'darwin',  'tar.gz' }
        default   { 'linux',   'tar.gz' }
    }
    $exeName = Get-ExecutableName 'no-mistakes'

    $releaseUrl = "https://api.github.com/repos/$($Pin.repository)/releases/tags/v$($Pin.version)"
    Write-Host "  RUN   fetch $releaseUrl"
    $release = $null
    try {
        $release = Invoke-RestMethod -Uri $releaseUrl `
                                     -Headers @{ 'User-Agent' = 'kingshand-installer' } -TimeoutSec 30 -ErrorAction Stop
    } catch {
        Write-Miss 'the review gate was not installed: its release feed could not be reached.'
        Write-Host  '        This machine looks offline, or GitHub is unreachable. Nothing was downloaded.'
        Write-Host  "        Reconnect and run: $(Get-InstallerCommand '-WithReviewGate')"
        return $false
    }

    $asset = @($release.assets | Where-Object { $_.name -like "*$os-$arch.$archive" }) | Select-Object -First 1
    $sums  = @($release.assets | Where-Object { $_.name -eq 'checksums.txt' })        | Select-Object -First 1
    if (-not $asset -or -not $sums) {
        # No digest means no way to verify, and an unverifiable binary is not installed at all.
        Write-Miss "the review gate was not installed: $($release.tag_name) publishes no $os-$arch build, or no checksums.txt for one."
        return $false
    }

    $temp = Join-Path ([IO.Path]::GetTempPath()) ('nm-' + [guid]::NewGuid().ToString('N') + ".$archive")
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
    # Replacing a copy that is already there fails while a gate run holds its binary open, and that
    # is reported rather than allowed to end the whole install.
    try {
        if ($archive -eq 'zip') {
            Expand-Archive -LiteralPath $temp -DestinationPath $Destination -Force -ErrorAction Stop
        } else {
            $tar = Get-Command 'tar' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $tar) { throw 'tar is not on PATH' }
            $out = & $tar.Source -xzf $temp -C $Destination 2>&1
            if ($LASTEXITCODE -ne 0) { throw "tar exited $LASTEXITCODE - $($out -join ' ')" }
        }
    } catch {
        Write-Miss "the review gate $($release.tag_name) was verified but could not be unpacked into $Destination - $($_.Exception.Message)"
        Write-Host  "        A gate run is probably still using it. Let it finish, then run: $(Get-InstallerCommand '-SyncPins')"
        return $false
    } finally {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
    }

    # Flattened for the same reason herdr's is: Get-NoMistakesCommandPath looks for exactly
    # tools\no-mistakes\<no-mistakes.exe or no-mistakes> and should not have to guess at an
    # archive's shape.
    $exe = Join-Path $Destination $exeName
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
        $found = @(Get-ChildItem -Path $Destination -Filter $exeName -Recurse -File) | Select-Object -First 1
        if ($found) { Move-Item -LiteralPath $found.FullName -Destination $exe -Force }
    }
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
        Write-Miss "the review gate unpacked, but no $exeName was found under $Destination."
        return $false
    }
    # tar keeps the mode the archive recorded, which should already be executable; set anyway, so a
    # build packed without it still runs.
    if ($platform -ne 'Windows') { Set-ExecutableBit -Path $exe }

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
    if (Install-NoMistakes -Destination (Join-Path $Root 'tools' 'no-mistakes') -Pin $pins['no-mistakes']) {
        $actions.Add('tools\no-mistakes\')
    }
} else {
    Write-Host ("  NOTE  no-mistakes is not installed, and nothing needs it unless you register a " +
                "project ``no-mistakes`` or ``no-mistakes-prod-only``. To add it: " +
                "$(Get-InstallerCommand '-WithReviewGate') - it is a GitHub release, checked against its published SHA-256. " +
                "Do NOT ``npm install -g no-mistakes``: that name belongs to a different, unrelated tool.")
}

if ($InstallMissing -and ($missing.Count + $optional.Count) -gt 0) {
    Write-Step 'Installing what is missing'

    # Blockers and optionals are installed by the same machinery, and only reported differently.
    # -InstallMissing is consent to install what can be installed, so gh and Pester go in here too;
    # what their Optional flag buys is that their absence never reads as a broken install and never
    # sets the exit code.
    $installable = @($missing) + @($optional)

    # The system package manager is the floor: it cannot install itself. On Windows that is winget,
    # which ships with Windows as part of App Installer; on macOS it is Homebrew, which does not ship
    # with macOS. npm is not a floor - it comes with Node.js, which the package manager installs - so
    # where the manager is present and may be run, an absent npm is a step to take, not a wall to
    # stop at. On Linux the manager is never run, because every one of them needs sudo and this
    # script never elevates: what it would have run is printed for the person to run instead.
    #
    # Each blocked entry is the line saying why, and the line saying what to do about it.
    $blocked = [ordered]@{}
    $hasManager = [bool]($packages.name -and (Get-Command $packages.name -ErrorAction SilentlyContinue))
    $runsManager = $packages.runs -and $hasManager

    if (-not (Get-Command 'npm' -ErrorAction SilentlyContinue)) {
        $nodeCommand = if ($platform -eq 'Windows') {
            'winget install --id OpenJS.NodeJS.LTS --silent --accept-package-agreements --accept-source-agreements'
        } else { Get-SystemPackageCommand -Tool node -Manager $packages.name }
        if ($runsManager) {
            Write-Host '  npm is missing. Installing Node.js, which provides it.'
            $nodeOk = Invoke-InstallCommand $nodeCommand
            if ($nodeOk) { Update-PathFromRegistry }
            if (-not $nodeOk) {
                # Node.js installs for the whole machine, so on an account without administrator
                # rights this is the step that fails - and saying it "installed" sent people to
                # open a new shell for a Node that was never there.
                $retry = if ($platform -eq 'Windows') { "run this in an elevated PowerShell: $nodeCommand" }
                         else { "fix that and run: $nodeCommand" }
                $blocked['npm'] = @('npm is not on PATH.',
                                    ('Node.js did not install. If that was for want of administrator ' +
                                     'rights, ' + $retry + ' - or install it from https://nodejs.org - ' +
                                     'then open a new shell and run this again.'))
            } elseif (-not (Get-Command 'npm' -ErrorAction SilentlyContinue)) {
                $blocked['npm'] = @('npm is not on PATH.', 'Node.js installed but npm is still not on PATH. Open a new shell and run this script again.')
            } else {
                Write-Did 'npm is available.'
            }
        } elseif ($nodeCommand -and -not $packages.runs) {
            $blocked['npm'] = @("npm is not on PATH, and Node.js needs sudo to install, which this script never uses.",
                                ("Run: $nodeCommand - then open a new shell and run this again. A " +
                                 "distribution's Node.js can be older than Claude Code needs; " +
                                 'https://nodejs.org has current builds.'))
        } else {
            $blocked['npm'] = @('npm is not on PATH.', 'Install Node.js from https://nodejs.org, open a new shell so PATH picks it up, then run this again.')
        }
    }

    # npm on macOS and Linux installs global packages under its own prefix, which for a Node.js from
    # a system package is a root-owned directory - so every `npm install -g` fails with EACCES. Said
    # before anything is run, with the fix that needs no sudo.
    if (-not $blocked.Contains('npm') -and $platform -ne 'Windows') {
        $npmProblem = Get-NpmGlobalProblem
        if ($npmProblem) { $blocked['npm'] = @("npm cannot install global packages for this user.", $npmProblem) }
    }

    if (-not $runsManager) {
        $blocked[$systemManager] = switch ($platform) {
            'Windows' { @('winget is not on PATH.',
                          'Install App Installer from the Microsoft Store, then run this again. It carries winget, which cannot install itself.') }
            'MacOS'   { @('Homebrew is not on PATH.',
                          'Install it from https://brew.sh, open a new shell, then run this again. It installs git, gh and Node.js here, and cannot install itself.') }
            default   {
                if ($packages.name) {
                    @("$($packages.name) needs sudo, which this script never uses.",
                      'Run the command named for each of them above yourself, then run this again.')
                } else {
                    @("this distribution's package manager was not recognised.",
                      'Install them with it yourself, then run this again.')
                }
            }
        }
    }
    foreach ($manager in @($blocked.Keys)) {
        $names = @($installable | Where-Object { $_.Manager -eq $manager } | ForEach-Object { $_.Name })
        if ($names.Count -eq 0) { continue }
        Write-Miss ("{0} cannot be installed: {1}" -f ($names -join ', '), $blocked[$manager][0])
        Write-Host ("        " + $blocked[$manager][1])
    }

    # One command per package, not one per tool: `claude` and `claude.cmd` are the same npm install
    # and running it twice would report a second success for work that already happened.
    $planned = [ordered]@{}
    foreach ($m in $installable) {
        if ($m.Manager -in 'psgallery', 'herdr', 'nodejs' -or $blocked.Contains($m.Manager)) { continue }
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
            if ($platform -eq 'Windows') {
                Write-Host "        If that failed for want of administrator rights, run this in an elevated PowerShell: $command"
            } else {
                Write-Host "        If that failed for want of rights, run it yourself: $command"
            }
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
        if (Install-Herdr -Destination (Join-Path $Root 'tools' 'herdr') -Pin $pins['herdr']) {
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
# 1b. Pinned versions. dependencies.json names the version of each dependency this
#     release was verified with. Every one is reported against what is installed;
#     with -SyncPins or -InstallMissing, each that is off its pin is moved to it.
#
#     A move goes TO the pin, never past it, and only touches what this installer
#     owns: an npm global, or a copy under tools\. A herdr or review gate the user
#     put on PATH themselves is reported with the command and left alone, and Claude
#     Code is pinned by minimum only, because it updates itself.
#
#     herdr is never replaced under a running server - Install-Herdr owns that
#     refusal. A pin that a requested sync could not reach makes this script exit 1,
#     so `/update` reports it rather than claiming a clean install.
# --------------------------------------------------------------------------------
Write-Step 'Pinned versions'

$syncing  = $SyncPins -or $InstallMissing
$offPin   = [System.Collections.Generic.List[string]]::new()
$reportedAbove = @($tools | ForEach-Object { $_.Name }) + @('claude-code', 'herdr', 'no-mistakes')

foreach ($s in @(Get-DependencyPinStatus -Root $Root)) {
    $label = "{0,-12}" -f $s.name
    if ($s.state -eq 'current') { Write-Ok "$label $($s.installed), as pinned"; continue }
    if ($s.state -eq 'satisfied') {
        Write-Ok "$label $($s.installed), at least the $($s.minimum) this release needs"
        continue
    }
    if ($s.state -eq 'missing') {
        # Reported, and installed at its pin, by the prerequisite pass above - all but an optional
        # tool that pass does not check, which nothing installs and only this line names.
        if ($reportedAbove -notcontains $s.name) {
            Write-Host "  NOTE  $label not installed - optional. Add it at its pin with: $($s.command)"
        }
        continue
    }
    if ($s.state -eq 'unreadable' -and $s.source -eq 'npm' -and $s.name -ne 'claude-code' -and -not (Get-NpmCommand)) {
        # No npm, so no npm version can be read at all. The prerequisite pass above has already
        # named Node.js and every required npm tool as missing, so repeating each here as a MISS
        # only lengthens the list a new user has to read; an optional one is said once, as optional.
        if ($reportedAbove -notcontains $s.name) {
            Write-Host "  NOTE  $label optional, and not checked - npm is not on PATH. Once it is, add it with: $($s.command)"
        }
        continue
    }
    if ($s.state -eq 'unreadable') {
        Write-Miss "$label its version could not be read - $($s.detail)"
        if ($syncing) { $offPin.Add($s.name) }
        continue
    }

    # behind or ahead from here on.
    $want = if ($s.pinned) { $s.pinned } else { $s.minimum }
    $what = "$label $($s.installed) installed, this release is verified with $want"

    if ($s.minimum) {
        # Updates itself; never moved by this script.
        Write-Host "  NOTE  $what or newer. Update it with: $($s.command)"
        continue
    }
    if (-not $syncing) {
        Write-Host "  NOTE  $what. Move it with: $($s.command)"
        continue
    }
    if ($s.source -ne 'npm' -and -not $s.bundled) {
        Write-Miss "$what. It is at $($s.path), which you manage rather than this installer - move it to $want yourself."
        $offPin.Add($s.name)
        continue
    }

    Write-Host "  FOR   $($s.name) $($s.installed) -> $want"
    $moved = switch ($s.source) {
        'npm'    { Invoke-InstallCommand -Command $s.command }
        'herdr'  { Install-Herdr -Destination (Join-Path $Root 'tools' 'herdr') -Pin $pins[$s.name] }
        'github' { Install-NoMistakes -Destination (Join-Path $Root 'tools' 'no-mistakes') -Pin $pins[$s.name] }
    }
    if ($moved) {
        Write-Did "$($s.name) moved from $($s.installed) to $want."
        $actions.Add("$($s.name) $want")
    } else {
        $offPin.Add($s.name)
    }
}

# --------------------------------------------------------------------------------
# 2. KINGSHAND_HOME and LAVISH_AXI_PORT - the two per-machine values.
#
#    On Windows they are user environment variables. macOS and Linux have no user
#    scope - .NET ignores a set there and a read returns nothing, so the old code
#    reported DONE while nothing changed - so there they go into the `env` block of
#    this repository's own .claude/settings.local.json, which Claude Code puts into
#    every session started here and every command that session runs. Gitignored, and
#    only that one key of the file is touched: bin\ClaudeWorkspace.psm1 owns the edit.
# --------------------------------------------------------------------------------
$settingsFile = Get-HandSettingsPath -Root $Root

# The value already stored, through whichever of the two places this system keeps it in.
function Get-MachineSetting {
    param([Parameter(Mandatory)][string]$Name)
    if ($platform -eq 'Windows') { return [Environment]::GetEnvironmentVariable($Name, 'User') }
    Get-HandSettingsEnvValue -Name $Name -Path $settingsFile
}

function Set-MachineSetting {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Value)
    if ($platform -eq 'Windows') { [Environment]::SetEnvironmentVariable($Name, $Value, 'User'); return }
    $null = Set-HandSettingsEnvValue -Name $Name -Value $Value -Path $settingsFile
}

$where = if ($platform -eq 'Windows') { 'for your user' } else { "in $settingsFile" }

# A settings file that is there and cannot be read is reported and left exactly as it is: writing
# either value would mean rewriting a file whose other keys were never read.
$settingsReadable = $true
if ($platform -ne 'Windows') {
    try { $null = Get-HandSettingsEnvValue -Name 'KINGSHAND_HOME' -Path $settingsFile }
    catch {
        $settingsReadable = $false
        Write-Step 'KINGSHAND_HOME and LAVISH_AXI_PORT'
        Write-Miss "neither was written: $($_.Exception.Message)"
        $skipped.Add('KINGSHAND_HOME'); $skipped.Add('LAVISH_AXI_PORT')
    }
}

if ($settingsReadable) {
    Write-Step 'KINGSHAND_HOME'

    $currentHome = Get-MachineSetting 'KINGSHAND_HOME'
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
        Set-MachineSetting 'KINGSHAND_HOME' $Root
        $env:KINGSHAND_HOME = $Root
        if ($platform -eq 'Windows') {
            Write-Did "KINGSHAND_HOME set to $Root for your user. Open a new shell for it to take effect."
        } else {
            Write-Did "KINGSHAND_HOME set to $Root $where. Claude Code sessions started here pick it up."
        }
        $actions.Add('KINGSHAND_HOME')
    }

    # Windows lavish must own 4388; WSL's lavish on 4387 answers Windows requests silently and fails
    # with an opaque 500, which looks like a broken review surface rather than a wrong port. Nothing
    # competes for the port on macOS or Linux, and it is 4388 there too so there is one answer.
    $port = Get-MachineSetting 'LAVISH_AXI_PORT'
    if ($port -eq '4388') {
        Write-Ok 'LAVISH_AXI_PORT is 4388'
    } elseif ($port -and -not $Force) {
        Write-Kept "LAVISH_AXI_PORT is '$port', expected 4388. Left alone - re-run with -Force to change it."
        $skipped.Add('LAVISH_AXI_PORT')
    } else {
        Set-MachineSetting 'LAVISH_AXI_PORT' '4388'
        Write-Did "LAVISH_AXI_PORT set to 4388 $where."
        $actions.Add('LAVISH_AXI_PORT')
    }
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
# binary is left completely alone. Windows only - on macOS and Linux npm's `claude` is a symlink or
# a shebang script that passes arguments through untouched, so there is no wrapper to get ahead of.
if ($platform -eq 'Windows' -and $script:ClaudeIsWrapper) {
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
#    There are two lines, not one, and the second is not optional. Each worktree is
#    its own working tree, so inside it the permission grant kingshand writes before
#    the worker starts is at `.claude/settings.local.json` relative to that tree's own
#    root - a path the repo's `.claude/worktrees/` pattern does not match. Without the
#    second line every dispatched worker's tree is dirty from the moment it is created,
#    and the review gate refuses to run in a dirty tree. This repository ignores both
#    for itself; these lines are what make that true in the user's own repos too.
#
#    Three rules, and they are the whole of the care this needs.
#    Never duplicate a line: an installer run twice must leave exactly one of each.
#    Never rewrite or reorder a file the user already had - the only write to a file
#    that already exists is an appended line.
#    And print the file that was touched, because a script quietly editing a dotfile
#    in someone's home directory should at minimum say which one.
# --------------------------------------------------------------------------------
Write-Step 'Global gitignore'

$ignoreLines = @('.claude/worktrees/', '.claude/settings.local.json')

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
        Set-Content -LiteralPath $excludesPath -Value $ignoreLines -Encoding utf8
        Write-Did "created $excludesPath with the lines $($ignoreLines -join ' and ')"
        $actions.Add('global gitignore')
    } else {
        # Each line is decided on its own, so a file that already has one gets only the other and
        # a file that has both is left completely alone.
        $present = @(Get-Content -LiteralPath $excludesPath | ForEach-Object { $_.Trim() })
        $wanted  = @($ignoreLines | Where-Object { $present -notcontains $_ })

        if ($wanted.Count -eq 0) {
            Write-Ok "$excludesPath already ignores $($ignoreLines -join ' and ')"
        } else {
            # A file that does not end in a newline would otherwise have the first of these glued
            # onto its last one, silently changing a pattern the user wrote. Add-Content with an
            # empty string appends the missing terminator and nothing else.
            $existing = Get-Content -LiteralPath $excludesPath -Raw
            if ($existing -and -not $existing.EndsWith("`n")) { Add-Content -LiteralPath $excludesPath -Value '' }
            Add-Content -LiteralPath $excludesPath -Value $wanted
            Write-Did "appended $($wanted -join ' and ') to $excludesPath - nothing else in that file was changed"
            $actions.Add('global gitignore')
        }
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

$budget = Join-Path $Root 'config' 'startup-memory-budget'
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
$ado = Join-Path $Root 'config' 'ado.json'
if (Test-Path -LiteralPath $ado) { Write-Ok 'config\ado.json exists' }
else { Write-Host '  NOTE  Azure DevOps integration is optional and nothing here needs it. config\ado.json is deliberately absent; describe work in your own words and it is handled as adhoc. If you do work ADO tickets, the Hand asks for your organization and project the first time it needs them and offers to write them here - and fetching a ticket by id also needs the ado-local-mcp server configured in Claude Code, which this script does not install.' }

if ($ProjectRoot.Count -gt 0) {
    $settingsPath = Join-Path $Root '.claude' 'settings.json'
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

if ($offPin.Count -gt 0) {
    Write-Host ""
    Write-Host ("Not moved to the version this release pins: " + ($offPin -join ', ') +
                ". Each says why under Pinned versions above.")
    if ($missing.Count -eq 0) { exit 1 }
}

if ($missing.Count -gt 0) {
    Write-Host ""
    Write-Host "Install these before dispatching anything:"
    $missing | ForEach-Object { Write-Host ("  - {0}: {1}" -f $_.Name, $_.Install) }
    Write-Host ""
    Write-Host "Then open a new shell, so PATH picks up what you installed, and re-run: $rerun"
    if (-not $InstallMissing) { Write-Host "Or let this script install them for you: $(Get-InstallerCommand '-InstallMissing')" }
    exit 1
}

Write-Host ""
Write-Host "Ready. Open a new shell, start Claude Code in $Root, and run /annex on a repo."
exit 0
