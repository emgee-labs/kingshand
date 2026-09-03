#Requires -Version 7.0
Set-StrictMode -Version Latest

# The `VERSION` file at the repository root: this installation's version, and the only place it is
# written down.
#
# One file, one line, nothing else in it. No script, skill, manifest or document carries a second
# copy of the number - a version stated twice is a version that disagrees with itself the first
# time somebody edits one of them, and neither copy says which is right.
#
# Reading it is deliberately fussy, because everything downstream reports what it returns. An
# absent file, an empty file and a file holding prose are three different failures and each says
# which one it is; none of them returns a version. That matters most on the paths that print the
# answer to a person: "unreadable" is a fact they can act on, where a fabricated `0.0.0` is a
# fact they would trust.
#
# Takes the root as a parameter and resolves nothing itself, so it imports nothing: the caller
# already knows which installation it is asking about, and `bin\Paths.psm1` is the one place that
# decision is made.

# Semantic version, optionally with a pre-release or build suffix. Anchored, so a line with a `v`
# prefix, a stray comment or a second word on it is refused rather than half-read: the file's whole
# job is to hold the version and nothing else, and the tag that names a release is where the `v`
# lives.
$script:VersionPattern = '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$'

# Where the file lives, said once. Every caller comes through here rather than joining 'VERSION'
# onto a root of its own, so moving the file is one edit rather than a search.
function Get-VersionFilePath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)

    Join-Path $Root 'VERSION'
}

# The one validator, shared by the file read and the git read below, so both refuse the same
# content for the same reason. $Source names what was read, because "the VERSION file at C:\..."
# and "tag v0.2.0" are the two things a reader needs told apart.
function Assert-VersionText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][string]$Source
    )

    $trimmed = $Text.Trim()
    if (-not $trimmed) { throw "$Source holds no version." }

    if ($trimmed -match '[\r\n]') {
        throw "$Source holds more than one line. It must hold the version and nothing else."
    }
    if ($trimmed -notmatch $script:VersionPattern) {
        $shown = if ($trimmed.Length -gt 60) { $trimmed.Substring(0, 60) + '...' } else { $trimmed }
        throw "$Source does not hold a version: '$shown'. Expected a version like 0.1.0."
    }
    $trimmed
}

# This installation's version, or a throw naming which of the three failures happened.
#
# Never returns a placeholder. A caller that wants to survive the failure catches it and says so -
# `bin\Get-SessionStart.ps1` prints one `VERSION: unreadable` line and carries on with the rest of
# the digest - and a caller that cannot proceed without a version stops.
function Get-KingshandVersion {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "There is no VERSION file at $Path, so this installation's version is not known."
    }

    $raw = $null
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    } catch {
        throw "The VERSION file at $Path could not be read - $($_.Exception.Message)"
    }
    if ($null -eq $raw) { $raw = '' }

    Assert-VersionText -Text $raw -Source "The VERSION file at $Path"
}

# The version a git ref holds, read out of that ref's own tree rather than out of the checkout.
#
# This is what makes "the version you would move to" answerable BEFORE anything is touched. A ref
# cut before the file existed has no version at all, and that is a refusal rather than a guess:
# updating to a release whose version cannot be read would report a move it could not describe.
function Get-KingshandVersionAtRef {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [Parameter(Mandatory)][string]$Ref
    )

    # Every git call here is a PROBE: a non-zero exit is an answer this function turns into its own
    # message, not an error for the caller's preference to terminate on. Scoped to this function.
    $PSNativeCommandUseErrorActionPreference = $false

    $out = & git -C $RepoPath show "${Ref}:VERSION" 2>&1
    $code = $LASTEXITCODE
    $global:LASTEXITCODE = 0
    if ($code -ne 0) {
        throw "$Ref has no readable VERSION file, so the version it holds is not known."
    }

    Assert-VersionText -Text (($out | Out-String)) -Source "$Ref's VERSION file"
}

Export-ModuleMember -Function Get-VersionFilePath, Assert-VersionText, Get-KingshandVersion,
                              Get-KingshandVersionAtRef
