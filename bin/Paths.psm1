#Requires -Version 7.0
Set-StrictMode -Version Latest

# What every installation and every operating system resolves differently, resolved in exactly one
# place: this installation's root, where Claude Code and the review gate live, and the platform
# helpers below - home directory, executable names, launchable commands, how paths compare, how the
# installer is run and which system package manager installs git, gh and Node.js.
#
# Each of these was once a hardcoded answer belonging to one machine or one OS. A second copy of
# any rule is how they drift back apart, so `bin\` and the skills both come through here rather
# than deriving their own.

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
        return [IO.Path]::TrimEndingDirectorySeparator($configured)
    }
    Split-Path $PSScriptRoot -Parent
}

# ---------------------------------------------------------------------------------------------
# Platform helpers. Everything that differs between Windows, macOS and Linux is decided here and
# nowhere else, so a module above this one asks a question - "is this the same path", "where is the
# home directory", "what is herdr called here" - instead of testing $IsWindows itself and keeping a
# private copy of the answer. Tests fake the platform by mocking Get-KingshandPlatform and
# Get-KingshandArchitecture inside this module.
# ---------------------------------------------------------------------------------------------

# 'Windows', 'MacOS' or 'Linux'. Anything else throws, naming what it saw, rather than being
# treated as whichever of the three it looks closest to.
function Get-KingshandPlatform {
    [CmdletBinding()]
    param()

    if ($IsWindows) { return 'Windows' }
    if ($IsMacOS)   { return 'MacOS' }
    if ($IsLinux)   { return 'Linux' }
    throw ("This operating system ($([Runtime.InteropServices.RuntimeInformation]::OSDescription)) " +
           'is none of Windows, macOS or Linux, which are the only three kingshand runs on.')
}

# The process architecture as .NET names it: X64, Arm64, X86, Arm and so on. Its own function so a
# test can stand in for the machine it runs on.
function Get-KingshandArchitecture {
    [CmdletBinding()]
    param()

    "$([Runtime.InteropServices.RuntimeInformation]::OSArchitecture)"
}

# The user's home directory: USERPROFILE on Windows, HOME on macOS and Linux - the variable each
# system's own shells set. Unset or blank throws, naming the variable, because a home directory
# invented here is a path that reliably holds nothing, and every reader would take that for "there
# is nothing there". A caller that can carry on without a home catches the throw and says so.
function Get-UserHomePath {
    [CmdletBinding()]
    param()

    $name  = if ((Get-KingshandPlatform) -eq 'Windows') { 'USERPROFILE' } else { 'HOME' }
    $value = [Environment]::GetEnvironmentVariable($name)
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "No home directory: the $name environment variable is not set."
    }
    $value
}

# Claude Code's own global config file, where it keeps per-project state such as folder trust.
# CLAUDE_CONFIG_DIR moves it on every system, as Claude Code's own documentation says; otherwise it
# is .claude.json in the home directory. Throws where Get-UserHomePath does.
function Get-ClaudeGlobalConfigPath {
    [CmdletBinding()]
    param()

    $dir = $env:CLAUDE_CONFIG_DIR
    if ([string]::IsNullOrWhiteSpace($dir)) { $dir = Get-UserHomePath }
    Join-Path $dir '.claude.json'
}

# The file name a program has on this platform: `herdr.exe` on Windows, `herdr` elsewhere.
function Get-ExecutableName {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    if ((Get-KingshandPlatform) -eq 'Windows') { return "$Name.exe" }
    $Name
}

# herdr's name for this machine - the key its latest.json and a pin's sha256 both use.
#
# Windows is always windows-x86_64: herdr publishes no Arm build for Windows, and an Arm64 Windows
# machine runs the x64 one under emulation, which is what it has always been given. macOS and Linux
# have both architectures. Anything else throws, naming the platform and architecture, rather than
# being handed a binary that cannot run.
function Get-HerdrPlatformKey {
    [CmdletBinding()]
    param()

    $platform = Get-KingshandPlatform
    if ($platform -eq 'Windows') { return 'windows-x86_64' }

    $arch = switch (Get-KingshandArchitecture) {
        'X64'   { 'x86_64' }
        'Arm64' { 'aarch64' }
        default { $null }
    }
    if (-not $arch) {
        throw ("herdr publishes no build for $platform on $(Get-KingshandArchitecture) - only x64 " +
               'and Arm64.')
    }
    "$($platform.ToLowerInvariant())-$arch"
}

# How a person on this platform runs the installer, with whatever arguments follow it. On Windows
# `.\install.ps1`; on macOS and Linux the file has no execute bit and no shebang, so it is handed to
# pwsh by name. Every hint that tells someone to run the installer is built from this.
function Get-InstallerCommand {
    [CmdletBinding()]
    param([string]$Arguments)

    $command = if ((Get-KingshandPlatform) -eq 'Windows') { '.\install.ps1' } else { 'pwsh ./install.ps1' }
    if ($Arguments) { $command += " $Arguments" }
    $command
}

# The system package manager the installer uses for git, gh and Node.js on this machine, and
# whether it may run it rather than only print its commands.
#
#   name  'winget', 'brew', 'apt', 'dnf', 'pacman', 'zypper', or $null where none is recognised
#   runs  $true where the installer runs it under -InstallMissing; $false where it only prints
#
# Windows has winget and macOS has Homebrew, and the installer runs either - neither needs
# elevation. Every Linux manager needs sudo and the installer never elevates, so on Linux the
# command is printed for the person to run and nothing is run.
#
# The Linux manager is read from os-release's ID and ID_LIKE lines only, matched against a closed
# list of distribution families. Nothing else in that file is read, and a family outside the list
# is $null rather than a guess.
function Get-SystemPackageManager {
    [CmdletBinding()]
    param([string]$OsReleasePath = '/etc/os-release')

    switch (Get-KingshandPlatform) {
        'Windows' { return [pscustomobject]@{ name = 'winget'; runs = $true } }
        'MacOS'   { return [pscustomobject]@{ name = 'brew';   runs = $true } }
    }

    $ids = @()
    if (Test-Path -LiteralPath $OsReleasePath -PathType Leaf) {
        foreach ($line in [IO.File]::ReadAllLines($OsReleasePath)) {
            if ($line -match '^(ID|ID_LIKE)=(.*)$') {
                $ids += @($Matches[2].Trim().Trim('"', "'").ToLowerInvariant() -split '\s+' |
                          Where-Object { $_ })
            }
        }
    }
    $families = [ordered]@{
        apt    = @('debian', 'ubuntu')
        dnf    = @('fedora', 'rhel', 'centos')
        pacman = @('arch')
        zypper = @('suse', 'opensuse', 'opensuse-leap', 'opensuse-tumbleweed')
    }
    foreach ($id in $ids) {
        foreach ($manager in $families.Keys) {
            if ($families[$manager] -contains $id) {
                return [pscustomobject]@{ name = $manager; runs = $false }
            }
        }
    }
    [pscustomobject]@{ name = $null; runs = $false }
}

# The command that installs git, gh or Node.js with a given system package manager, as a person
# would type it, or $null where no manager was recognised. The one table both the installer and
# the toolchain check print from, so the two cannot name different commands.
function Get-SystemPackageCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('git', 'gh', 'node')][string]$Tool,
        [AllowNull()][AllowEmptyString()][string]$Manager
    )

    $table = @{
        winget = @{ git = 'winget install --id Git.Git'; gh = 'winget install --id GitHub.cli'
                    node = 'winget install --id OpenJS.NodeJS.LTS' }
        brew   = @{ git = 'brew install git'; gh = 'brew install gh'; node = 'brew install node' }
        apt    = @{ git = 'sudo apt-get install -y git'; gh = 'sudo apt-get install -y gh'
                    node = 'sudo apt-get install -y nodejs npm' }
        dnf    = @{ git = 'sudo dnf install -y git'; gh = 'sudo dnf install -y gh'
                    node = 'sudo dnf install -y nodejs npm' }
        pacman = @{ git = 'sudo pacman -S --needed git'; gh = 'sudo pacman -S --needed github-cli'
                    node = 'sudo pacman -S --needed nodejs npm' }
        zypper = @{ git = 'sudo zypper install -y git'; gh = 'sudo zypper install -y gh'
                    node = 'sudo zypper install -y nodejs npm' }
    }
    if (-not $Manager -or -not $table.ContainsKey($Manager)) { return $null }
    $table[$Manager][$Tool]
}

# How to install git, gh or Node.js on this machine, as the phrase after "Install with:" in a hint:
# the command where a package manager was recognised, and otherwise the plain direction to use the
# distribution's own - never a guessed command.
function Get-SystemPackageHint {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('git', 'gh', 'node')][string]$Tool)

    $command = Get-SystemPackageCommand -Tool $Tool -Manager (Get-SystemPackageManager).name
    if ($command) { return $command }
    "your distribution's own package manager"
}

# The one launchable copy of a program on PATH, or $null.
#
# On Windows only `.exe` and `.cmd` can be started by a native caller - a `.ps1` or an
# extensionless npm shim dies with "%1 is not a valid Win32 application" - so those two are the
# only answers, and `.exe` wins where both exist. On macOS and Linux an extensionless file with a
# shebang launches fine, so the first executable PATH holds is the answer.
function Resolve-LaunchableCommand {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    $found = @(Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue |
               Where-Object { $_.Source })
    if ((Get-KingshandPlatform) -ne 'Windows') {
        if ($found.Count -gt 0) { return $found[0].Source }
        return $null
    }
    foreach ($ext in @('.exe', '.cmd')) {
        foreach ($c in $found) {
            if ($c.Source.EndsWith($ext, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $c.Source
            }
        }
    }
    $null
}

# How two paths compare as text: case-insensitively on Windows, exactly on macOS and Linux. macOS
# volumes are usually case-insensitive too, but not always, and a false "different" costs less than
# a false "same" - the second is how one path's state gets read as another's.
function Get-PathComparison {
    [CmdletBinding()]
    param()

    if ((Get-KingshandPlatform) -eq 'Windows') { return [StringComparison]::OrdinalIgnoreCase }
    [StringComparison]::Ordinal
}

# The same rule as a comparer, for a HashSet or Dictionary keyed by path. Returned with the leading
# comma so PowerShell hands back the comparer itself.
function Get-PathComparer {
    [CmdletBinding()]
    param()

    if ((Get-KingshandPlatform) -eq 'Windows') { return , [StringComparer]::OrdinalIgnoreCase }
    , [StringComparer]::Ordinal
}

# A path made absolute and stripped of a trailing separator, in this platform's own separators.
# Relative paths resolve against the process working directory, as GetFullPath does. Throws on a
# path that cannot be normalised; the two tests below turn that into "not the same".
function ConvertTo-NormalPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($Path))
}

# True when two paths name the same place. Empty, or a path that will not normalise, is never the
# same as anything.
function Test-SamePath {
    [CmdletBinding()]
    param([AllowEmptyString()][AllowNull()][string]$A, [AllowEmptyString()][AllowNull()][string]$B)

    if ([string]::IsNullOrWhiteSpace($A) -or [string]::IsNullOrWhiteSpace($B)) { return $false }
    try { (ConvertTo-NormalPath $A).Equals((ConvertTo-NormalPath $B), (Get-PathComparison)) }
    catch { $false }
}

# True when $Path is $Root or inside it; with -ExcludeRoot, only strictly inside it. Compared as
# whole path segments, so C:\data2 is not inside C:\data. Empty or unnormalisable reads as outside.
function Test-PathWithin {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][AllowNull()][string]$Path,
        [AllowEmptyString()][AllowNull()][string]$Root,
        [switch]$ExcludeRoot
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($Root)) { return $false }
    try {
        $p   = ConvertTo-NormalPath $Path
        $r   = ConvertTo-NormalPath $Root
        $cmp = Get-PathComparison
        if ($p.Equals($r, $cmp)) { return -not $ExcludeRoot }
        # A root such as C:\ or / already ends in its separator, so it is not added twice.
        $prefix = if ([IO.Path]::EndsInDirectorySeparator($r)) { $r }
                  else { $r + [IO.Path]::DirectorySeparatorChar }
        $p.StartsWith($prefix, $cmp)
    } catch { $false }
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

    # Everything below is about Windows' wrapper. On macOS and Linux npm's `claude` is a symlink or
    # a shebang script that passes arguments through untouched, so whatever PATH holds is right.
    if ((Get-KingshandPlatform) -ne 'Windows') { return Resolve-LaunchableCommand -Name 'claude' }

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

    $bundled = Join-Path (Get-KingshandHome) 'tools' 'no-mistakes' (Get-ExecutableName 'no-mistakes')
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

    $system = @{ Windows = 'Windows'; MacOS = 'macOS'; Linux = 'Linux' }[(Get-KingshandPlatform)]
    "no-mistakes was not found. Run: $(Get-InstallerCommand '-WithReviewGate') - which fetches the $system " +
    'build from github.com/kunchenguid/no-mistakes and checks it against the published SHA-256. ' +
    'Do NOT run `npm install -g no-mistakes`: that name on npm belongs to a different, unrelated ' +
    'tool. It is needed only by projects registered `no-mistakes` or `no-mistakes-prod-only`.'
}

Export-ModuleMember -Function Get-KingshandHome, Get-ClaudeCommandPath, Get-ClaudeCommandHint,
                              Test-ClaudeCommandIsWrapper, Get-ClaudeWrapperHint,
                              Get-NoMistakesCommandPath, Get-NoMistakesHint,
                              Get-KingshandPlatform, Get-KingshandArchitecture, Get-UserHomePath,
                              Get-ClaudeGlobalConfigPath, Get-ExecutableName, Get-HerdrPlatformKey,
                              Get-InstallerCommand, Get-SystemPackageManager,
                              Get-SystemPackageCommand, Get-SystemPackageHint,
                              Resolve-LaunchableCommand, Get-PathComparison, Get-PathComparer,
                              ConvertTo-NormalPath, Test-SamePath, Test-PathWithin
