#Requires -Version 7.0
Set-StrictMode -Version Latest

# The pinned dependencies: what each kingshand release was verified with, what this machine has,
# and what has been published since.
#
# `dependencies.json` at the repo root is the one record of the pins. It is JSON because
# ConvertFrom-Json already reads it - nothing here parses a format of its own. Each entry is one
# dependency:
#
#   source      herdr | github | npm - where it comes from, and so how it is read and installed
#   version     the exact version this release was verified with
#   minimum     instead of `version`, for a dependency that updates itself: the oldest that works
#   package     npm only - the package name, which is not always the dependency's name
#   repository  github only - owner/name of the repository that publishes the release
#   protocol    herdr only - the protocol the pinned version speaks
#   sha256      herdr only - the digest of each platform's download, keyed by herdr's platform name
#
# Three readers, and none of them writes anything:
#
#   Get-DependencyPinStatus   pinned against installed, for install.ps1 to report and to sync
#   Get-DependencyPinReport   pinned against latest published, for the maintainers' weekly refresh
#   Get-DependencySyncCommand the command that moves one dependency to its pin
#
# EVERY VERSION IS READ FROM THE TOOL THAT OWNS IT, and an answer that could not be read stays
# unreadable. An installed version comes from npm's own JSON, herdr's own `status --json`, or the one
# version line no-mistakes and Claude Code print; a published one from npm's registry, herdr's
# latest.json or the GitHub release API. None is ever guessed, defaulted or carried over from a
# previous read, because a fabricated "current" is how a machine stays behind its pin unnoticed.
#
# NOT -Force on either import - a module never forces a nested import. The rule and the failure it
# prevents are in the `statute` skill's style rules.
Import-Module (Join-Path $PSScriptRoot 'Paths.psm1')
Import-Module (Join-Path $PSScriptRoot 'Herdr.psm1')

$script:ManifestName = 'dependencies.json'
$script:KnownSources = @('herdr', 'github', 'npm')

# herdr's platform name for this machine, which is the key its latest.json and the pin's sha256
# both use. Only Windows x64 is installed by install.ps1 today; the others are pinned so the record
# is whole for every platform herdr publishes.
$script:HerdrPlatform = 'windows-x86_64'

# A release version: three numbers and an optional leading `v`, nothing after them. Anything else
# is not a version this compares, and reads as unreadable rather than being coerced into one.
$script:VersionPattern = '^v?(\d+)\.(\d+)\.(\d+)$'

function Get-DependencyManifestPath {
    [CmdletBinding()]
    param([string]$Root = (Get-KingshandHome))

    Join-Path $Root $script:ManifestName
}

function Get-PinField {
    param($Object, [string]$Name)
    if ($null -ne $Object -and $Object.PSObject.Properties.Name -contains $Name) { return $Object.$Name }
    $null
}

# Every pin in the manifest, in file order, or a throw that names what is wrong with it.
#
# A manifest that cannot be read is never treated as "nothing is pinned": that would let a sync move
# nothing and report success. Each entry is checked for the fields its source needs, so a typo fails
# here, by name, rather than as a command run against a package called nothing.
function Read-DependencyPins {
    [CmdletBinding()]
    param([string]$Path = (Get-DependencyManifestPath))

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "There is no $($script:ManifestName) at $Path, so no dependency has a pin to check against."
    }

    $doc = $null
    try { $doc = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "$Path is not valid JSON - $($_.Exception.Message)" }
    if ($null -eq $doc -or $doc -isnot [pscustomobject]) {
        throw "$Path holds no object of pins."
    }

    $pins = foreach ($p in $doc.PSObject.Properties) {
        $name  = $p.Name
        $entry = $p.Value
        $where = "$($script:ManifestName) entry '$name'"

        if ($entry -isnot [pscustomobject]) { throw "$where is not an object." }

        $source = "$(Get-PinField $entry 'source')"
        if ($script:KnownSources -notcontains $source) {
            throw "$where names source '$source'; it must be one of $($script:KnownSources -join ', ')."
        }

        $version = Get-PinField $entry 'version'
        $minimum = Get-PinField $entry 'minimum'
        if ([bool]$version -eq [bool]$minimum) {
            throw "$where must carry exactly one of version or minimum."
        }
        $stated = if ($version) { "$version" } else { "$minimum" }
        if (-not (ConvertTo-DependencyVersion -Text $stated)) {
            throw "$where pins '$stated', which is not a version of three numbers."
        }

        $package    = "$(Get-PinField $entry 'package')"
        $repository = "$(Get-PinField $entry 'repository')"
        if ($source -eq 'npm' -and -not $package)    { throw "$where is an npm package with no package name." }
        if ($source -eq 'github' -and -not $repository) { throw "$where is a GitHub release with no repository." }

        $protocol = $null
        $sha256   = $null
        if ($source -eq 'herdr') {
            $protocol = Get-PinField $entry 'protocol'
            if (-not ($protocol -is [long] -or $protocol -is [int])) { throw "$where carries no protocol number." }
            $protocol = [int]$protocol
            $digests = Get-PinField $entry 'sha256'
            $mine    = Get-PinField $digests $script:HerdrPlatform
            if (-not $mine -or "$mine" -notmatch '^[0-9a-fA-F]{64}$') {
                throw "$where carries no SHA-256 for $($script:HerdrPlatform)."
            }
            $sha256 = $digests
        }

        [pscustomobject]@{
            name       = $name
            source     = $source
            version    = if ($version) { "$version" } else { $null }
            minimum    = if ($minimum) { "$minimum" } else { $null }
            package    = $package
            repository = $repository
            protocol   = $protocol
            sha256     = $sha256
        }
    }
    , @($pins)
}

# The SHA-256 a herdr pin carries for this platform, lower-cased.
function Get-HerdrPinnedDigest {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Pin)

    "$(Get-PinField $Pin.sha256 $script:HerdrPlatform)".ToLowerInvariant()
}

function ConvertTo-DependencyVersion {
    [CmdletBinding()]
    param([AllowEmptyString()][AllowNull()][string]$Text)

    if (-not $Text) { return $null }
    $m = [regex]::Match($Text.Trim(), $script:VersionPattern)
    if (-not $m.Success) { return $null }
    [version]::new([int]$m.Groups[1].Value, [int]$m.Groups[2].Value, [int]$m.Groups[3].Value)
}

# Whether moving from one version to another crosses a line that may break a caller.
#
# The leftmost part that is not zero is the one that may break: 1.x to 2.x, and while a project is
# still on 0.x, 0.9 to 0.10 - semantic versioning's own rule for a pre-1.0 line. For herdr a protocol
# change is a break on its own whatever the version says, because a binary and a server on two
# protocols cannot talk at all. $null when either version could not be read.
function Test-DependencyMoveBreaking {
    [CmdletBinding()]
    param(
        [string]$From,
        [string]$To,
        $FromProtocol = $null,
        $ToProtocol = $null
    )

    if ($null -ne $FromProtocol -and $null -ne $ToProtocol -and [int]$FromProtocol -ne [int]$ToProtocol) {
        return $true
    }

    $a = ConvertTo-DependencyVersion -Text $From
    $b = ConvertTo-DependencyVersion -Text $To
    if (-not $a -or -not $b) { return $null }

    if ($a.Major -ne $b.Major) { return $true }
    if ($a.Major -eq 0 -and $a.Minor -ne $b.Minor) { return $true }
    if ($a.Major -eq 0 -and $a.Minor -eq 0 -and $a.Build -ne $b.Build) { return $true }
    $false
}

# ---------------------------------------------------------------------------------------------
# The narrow readers. Each runs one tool and hands back what it said; the functions above them
# decide what it means. They are separate so a test can stand in for the tool.
# ---------------------------------------------------------------------------------------------

# The npm to run. `npm.cmd` first where it exists: a Node version manager's `npm.ps1` shim was
# measured on 2026-10-22 answering `& npm ls` with `Unknown command: "pm"`, because it re-derives its
# own arguments from how it was invoked. The .cmd shim takes its arguments as given.
function Get-NpmCommand {
    [CmdletBinding()]
    param()

    foreach ($name in 'npm.cmd', 'npm') {
        $c = Get-Command $name -CommandType Application, ExternalScript -ErrorAction SilentlyContinue |
             Select-Object -First 1
        if ($c) { return $c.Source }
    }
    $null
}

# What a machine with no npm is told, said the same way by install.ps1 and the toolchain check.
#
# A fresh Windows machine has no Node.js, and every npm install command printed beside it fails
# with "npm is not recognized" - so naming those commands without naming Node first hands a new
# user three fixes that cannot work.
function Get-NpmMissingHint {
    [CmdletBinding()]
    param()

    'npm was not found. It comes with Node.js, and Claude Code, lavish-axi and tasks-axi are all ' +
    'installed through it. Install Node.js LTS with: winget install --id OpenJS.NodeJS.LTS - or ' +
    'from https://nodejs.org - then open a new shell so PATH is picked up.'
}

# npm's JSON answer to one command, or $null when it printed nothing that parses.
function Invoke-NpmJson {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $npm = Get-NpmCommand
    if (-not $npm) { return $null }
    $PSNativeCommandUseErrorActionPreference = $false
    $text = (& $npm @Arguments 2>$null | Out-String).Trim()
    $global:LASTEXITCODE = 0
    if (-not $text) { return $null }
    try { $text | ConvertFrom-Json -ErrorAction Stop } catch { $null }
}

# The first line a binary prints for --version, or '' when it printed nothing.
function Read-VersionLine {
    param([Parameter(Mandatory)][string]$Path)

    $PSNativeCommandUseErrorActionPreference = $false
    $line = @(& $Path --version 2>&1 | ForEach-Object { "$_".Trim() } | Where-Object { $_ }) |
            Select-Object -First 1
    $global:LASTEXITCODE = 0
    "$line"
}

function Invoke-WebJson {
    param([Parameter(Mandatory)][string]$Uri)
    Invoke-RestMethod -Uri $Uri -Headers @{ 'User-Agent' = 'kingshand-dependencies' } -TimeoutSec 30 -ErrorAction Stop
}

function Test-SamePath {
    param([string]$A, [string]$B)
    if (-not $A -or -not $B) { return $false }
    try {
        [IO.Path]::GetFullPath($A).TrimEnd('\').Equals([IO.Path]::GetFullPath($B).TrimEnd('\'),
            [StringComparison]::OrdinalIgnoreCase)
    } catch { $false }
}

# What this machine has for one pin:
#
#   .found    $true when the dependency is installed, $false when it is not, and $null when that
#             could not be told - npm absent, or answering nothing readable
#   .version  the installed version, or $null when it is absent or could not be read
#   .path     the binary that answered, where there is one
#   .bundled  $true when that binary is the copy install.ps1 keeps under -Root's own tools\ - the
#             only copy a sync may replace. A copy on PATH belongs to whoever put it there, and a
#             copy under another installation's tools\ belongs to that installation.
#   .detail   why the version could not be read, empty when it was
function Get-InstalledDependencyVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Pin,
        [string]$Root = (Get-KingshandHome)
    )

    $home_ = $Root
    $out = [ordered]@{ found = $false; version = $null; path = $null; bundled = $false; detail = '' }

    switch ($Pin.source) {
        'herdr' {
            $v = Get-HerdrVersion
            if (-not $v.path) { $out.detail = 'herdr is not installed'; break }
            $out.found   = $true
            $out.path    = $v.path
            $out.bundled = Test-SamePath $v.path (Join-Path $home_ 'tools\herdr\herdr.exe')
            if ($v.version -and (ConvertTo-DependencyVersion -Text $v.version)) { $out.version = $v.version }
            else { $out.detail = "herdr's version could not be read - $($v.detail)" }
        }
        'github' {
            $path = Get-NoMistakesCommandPath
            if (-not $path) { $out.detail = "$($Pin.name) is not installed"; break }
            $out.found   = $true
            $out.path    = $path
            $out.bundled = Test-SamePath $path (Join-Path $home_ 'tools\no-mistakes\no-mistakes.exe')
            # One line, anchored at both ends of the version: `no-mistakes version v1.84.0 (sha) date`.
            $line = Read-VersionLine -Path $path
            $m = [regex]::Match($line, '^no-mistakes version (v?\d+\.\d+\.\d+)(\s|$)')
            if ($m.Success) { $out.version = $m.Groups[1].Value.TrimStart('v') }
            else { $out.detail = "$path --version printed '$line', which names no version" }
        }
        'npm' {
            if ($Pin.name -eq 'claude-code') {
                # Claude Code may be installed outside npm, so the binary is asked rather than npm:
                # `2.1.307 (Claude Code)`.
                $path = Get-ClaudeCommandPath
                if (-not $path) { $out.detail = 'Claude Code is not installed'; break }
                $out.found = $true
                $out.path  = $path
                $line = Read-VersionLine -Path $path
                $m = [regex]::Match($line, '^(\d+\.\d+\.\d+)(\s|$)')
                if ($m.Success) { $out.version = $m.Groups[1].Value }
                else { $out.detail = "$path --version printed '$line', which names no version" }
                break
            }

            if (-not (Get-NpmCommand)) {
                $out.found  = $null
                $out.detail = "npm is not on PATH, so whether $($Pin.package) is installed cannot be read"
                break
            }
            $doc  = Invoke-NpmJson -Arguments @('ls', '-g', $Pin.package, '--depth=0', '--json')
            $deps = Get-PinField $doc 'dependencies'
            $mine = Get-PinField $deps $Pin.package
            if ($null -eq $doc) {
                $out.found  = $null
                $out.detail = "npm ls answered nothing readable for $($Pin.package)"
            } elseif ($null -eq $mine) {
                $out.detail = "$($Pin.package) is not installed"
            } else {
                $out.found = $true
                $v = "$(Get-PinField $mine 'version')"
                if (ConvertTo-DependencyVersion -Text $v) { $out.version = $v }
                else { $out.detail = "npm ls named no version for $($Pin.package)" }
            }
        }
    }

    [pscustomobject]$out
}

# Whether the herdr binary may be replaced right now:
#
#   .ok      $true only when herdr's server is known to be stopped
#   .reason  why not, in words a person can act on; empty when .ok
#
# ONLY A STOPPED SERVER PASSES. A running server keeps every worker's pane, and a binary replaced
# under it leaves the two on different protocols, unable to read any worker - bin\Herdr.psm1 records
# that measurement. A server whose state could not be read is refused too, because "could not tell"
# is not "nothing is running". install.ps1 asks this before it touches tools\herdr\.
function Test-HerdrReplaceable {
    [CmdletBinding()]
    param()

    $server = Get-HerdrServerState
    if ($server.state -eq 'stopped') { return [pscustomobject]@{ ok = $true; reason = '' } }

    $why = if ($server.state -eq 'running') { "herdr's server is running" }
           else { "whether herdr's server is running could not be read - $($server.detail)" }
    [pscustomobject]@{
        ok     = $false
        reason = ("$why. Replacing herdr under a running server leaves the two on different " +
                  'versions, unable to read any worker. With no worker live, stop the server with ' +
                  '`herdr server stop` - this ends every pane - then run .\install.ps1 -SyncPins.')
    }
}

# The one command that moves a dependency to its pin, as the person running it would type it.
function Get-DependencySyncCommand {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Pin)

    if ($Pin.minimum) {
        # A dependency pinned by minimum updates itself; its own updater is the honest command.
        if ($Pin.name -eq 'claude-code') { return 'claude update' }
        return "npm install -g $($Pin.package)@latest"
    }
    switch ($Pin.source) {
        'npm'    { return "npm install -g $($Pin.package)@$($Pin.version)" }
        default  { return '.\install.ps1 -SyncPins' }
    }
}

# Every pin against what this machine has. One row per pin:
#
#   .name .pinned .minimum .installed .path .bundled .command .detail
#   .state  current    installed at exactly the pinned version
#           satisfied  a minimum pin, met
#           behind     installed below the pin or the minimum
#           ahead      installed above an exact pin
#           missing    not installed
#           unreadable installed, or maybe installed, and its version could not be read
function Get-DependencyPinStatus {
    [CmdletBinding()]
    param([string]$Root = (Get-KingshandHome))

    $pins = Read-DependencyPins -Path (Get-DependencyManifestPath -Root $Root)

    foreach ($pin in $pins) {
        $have  = Get-InstalledDependencyVersion -Pin $pin -Root $Root
        $want  = if ($pin.version) { $pin.version } else { $pin.minimum }
        $state = if ($have.found -eq $false) {
            'missing'
        } elseif (-not $have.version) {
            'unreadable'
        } else {
            $cmp = (ConvertTo-DependencyVersion -Text $have.version).CompareTo((ConvertTo-DependencyVersion -Text $want))
            if ($pin.minimum) { if ($cmp -ge 0) { 'satisfied' } else { 'behind' } }
            elseif ($cmp -eq 0) { 'current' }
            elseif ($cmp -lt 0) { 'behind' }
            else { 'ahead' }
        }

        [pscustomobject]@{
            name      = $pin.name
            source    = $pin.source
            pinned    = $pin.version
            minimum   = $pin.minimum
            installed = $have.version
            state     = $state
            path      = $have.path
            bundled   = $have.bundled
            command   = Get-DependencySyncCommand -Pin $pin
            detail    = $have.detail
        }
    }
}

# The latest version the publisher offers for one pin, with herdr's protocol where it has one.
#
#   .version   the latest published version, or $null when it could not be read
#   .protocol  herdr only: the protocol that version speaks
#   .detail    why it could not be read, empty when it was
function Get-PublishedDependencyVersion {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Pin)

    $out = [ordered]@{ version = $null; protocol = $null; detail = '' }
    try {
        switch ($Pin.source) {
            'herdr' {
                $doc = Invoke-WebJson -Uri 'https://herdr.dev/latest.json'
                $v = "$(Get-PinField $doc 'version')"
                $p = Get-PinField $doc 'protocol'
                if (ConvertTo-DependencyVersion -Text $v) { $out.version = $v }
                else { $out.detail = 'herdr.dev/latest.json named no version' }
                if ($p -is [long] -or $p -is [int]) { $out.protocol = [int]$p }
            }
            'github' {
                $doc = Invoke-WebJson -Uri "https://api.github.com/repos/$($Pin.repository)/releases/latest"
                $tag = "$(Get-PinField $doc 'tag_name')"
                if (ConvertTo-DependencyVersion -Text $tag) { $out.version = $tag.TrimStart('v') }
                else { $out.detail = "the latest $($Pin.repository) release is tagged '$tag', which is not a version" }
            }
            'npm' {
                $v = Invoke-NpmJson -Arguments @('view', $Pin.package, 'version', '--json')
                if ($v -is [string] -and (ConvertTo-DependencyVersion -Text $v)) { $out.version = $v }
                else { $out.detail = "npm view answered no version for $($Pin.package)" }
            }
        }
    } catch {
        $out.detail = "the latest $($Pin.name) could not be read - $($_.Exception.Message)"
    }
    [pscustomobject]$out
}

# Every pin against the latest published version, for the weekly refresh. Writes nothing.
#
#   .name .pinned .latest .pinnedProtocol .latestProtocol .detail
#   .move      none | newer | older | unknown - where the latest stands against the pin
#   .breaking  $true when the move crosses a breaking line (Test-DependencyMoveBreaking owns which),
#              $false when it does not, $null when either version could not be read
function Get-DependencyPinReport {
    [CmdletBinding()]
    param([string]$Root = (Get-KingshandHome))

    $pins = Read-DependencyPins -Path (Get-DependencyManifestPath -Root $Root)

    foreach ($pin in $pins) {
        $want = if ($pin.version) { $pin.version } else { $pin.minimum }
        $pub  = Get-PublishedDependencyVersion -Pin $pin

        $move = 'unknown'
        $breaking = $null
        if ($pub.version) {
            $cmp = (ConvertTo-DependencyVersion -Text $pub.version).CompareTo((ConvertTo-DependencyVersion -Text $want))
            $move = if ($cmp -eq 0) { 'none' } elseif ($cmp -gt 0) { 'newer' } else { 'older' }
            $breaking = Test-DependencyMoveBreaking -From $want -To $pub.version `
                            -FromProtocol $pin.protocol -ToProtocol $pub.protocol
        }

        [pscustomobject]@{
            name           = $pin.name
            pinned         = $want
            latest         = $pub.version
            pinnedProtocol = $pin.protocol
            latestProtocol = $pub.protocol
            move           = $move
            breaking       = $breaking
            detail         = $pub.detail
        }
    }
}

Export-ModuleMember -Function Get-DependencyManifestPath, Read-DependencyPins, Get-HerdrPinnedDigest,
                              Get-NpmCommand, Get-NpmMissingHint,
                              ConvertTo-DependencyVersion, Test-DependencyMoveBreaking,
                              Get-InstalledDependencyVersion, Get-DependencySyncCommand,
                              Test-HerdrReplaceable,
                              Get-DependencyPinStatus, Get-PublishedDependencyVersion,
                              Get-DependencyPinReport
