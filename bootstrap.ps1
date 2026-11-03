#Requires -Version 7.0
<#
.SYNOPSIS
  Installs kingshand from one URL: clones it into a folder, checks out the latest release, and
  runs install.ps1 there.
.DESCRIPTION
  This is the one file fetched before anything is cloned, so it carries nothing it could take from
  the repository instead. It does three things and then hands over:

    1. Checks for PowerShell 7 and git, and names whichever is missing.
    2. Clones the repository into -Path, unless -Path is already a kingshand clone.
    3. Checks out the latest release tag on the release branch, then runs install.ps1 from the
       clone - with -InstallMissing passed through when it was asked for.

  It never overwrites or deletes anything. -Path must be a folder that does not exist yet, an
  empty folder, or an existing kingshand clone; anything else is refused with the reason and
  nothing is written. An existing clone is left on whatever it has checked out, because that
  checkout may hold work - `/update` is what moves an installation to a newer release.

  Which tag is the latest release and which branch releases live on are read from the clone's own
  bin\Update.psm1, the one owner of both rules, so this script cannot pick a release `/update`
  would not.

  Run it piped or as a file:

    irm https://raw.githubusercontent.com/emgee-labs/kingshand/main/bootstrap.ps1 | iex
    .\bootstrap.ps1 -Path D:\tools\kingshand -InstallMissing

  Piped, it takes every default. It sends nothing anywhere but the git clone, and prints and stores
  no credential: a -Repository carrying a user name or token is shown with that part masked.
.PARAMETER Path
  The folder to install into. Defaults to a `kingshand` folder in your home directory.
.PARAMETER Repository
  Where to clone from. Defaults to the public repository; any URL or path git can clone works.
.PARAMETER InstallMissing
  Passed through to install.ps1, which then installs every missing prerequisite instead of only
  naming it. Off by default, as it is there.
.EXAMPLE
  irm https://raw.githubusercontent.com/emgee-labs/kingshand/main/bootstrap.ps1 | iex
.EXAMPLE
  .\bootstrap.ps1 -Path D:\tools\kingshand -InstallMissing
#>
[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()][string]$Path = (Join-Path $HOME 'kingshand'),
    [ValidateNotNullOrEmpty()][string]$Repository = 'https://github.com/emgee-labs/kingshand',
    [switch]$InstallMissing
)

# Run as a file, the installer's exit code is passed on. Piped through iex there is no script to
# exit, and `exit` would close the shell the user piped into, so the code is only reported.
$runAsFile = $MyInvocation.MyCommand.CommandType -eq 'ExternalScript'

# Everything runs in a child scope, so strict mode and the error preference set here never leak
# into a shell this was piped into.
#
# Nothing in this file may use syntax newer than Windows PowerShell 5.1 understands. Piped, the
# #Requires line above is not enforced, so on 5.1 the version check below is the only thing that
# stops the run - and it can only say so if the whole file parses there first.
$exitCode = & {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    $PSNativeCommandUseErrorActionPreference = $false

    function Stop-Bootstrap {
        param([Parameter(Mandatory)][string]$Reason)
        throw "kingshand was not installed: $Reason"
    }

    # The repository as it is safe to print. A URL can carry a user name or token, and that part is
    # masked rather than echoed. Anything that is not an absolute URI - a local path - has none.
    function Format-Repository {
        param([Parameter(Mandatory)][string]$Value)
        $uri = $null
        if ([uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri) -and $uri.UserInfo) {
            return $Value.Replace($uri.UserInfo, '***')
        }
        $Value
    }

    # Two remotes are the same repository when they differ only by a trailing slash or `.git`.
    function Get-RepositoryKey {
        param([Parameter(Mandatory)][string]$Value)
        $key = $Value.Trim().TrimEnd('/', '\')
        if ($key.EndsWith('.git', [StringComparison]::OrdinalIgnoreCase)) {
            $key = $key.Substring(0, $key.Length - 4)
        }
        $key
    }

    $shown = Format-Repository -Value $Repository

    if ($PSVersionTable.PSVersion.Major -lt 7) {
        Stop-Bootstrap ("it needs PowerShell 7 or newer, and this is PowerShell " +
                        "$($PSVersionTable.PSVersion). Install PowerShell 7 from " +
                        'https://aka.ms/powershell, start it with pwsh, and run this again there.')
    }

    if (-not (Get-Command 'git' -CommandType Application -ErrorAction SilentlyContinue)) {
        Stop-Bootstrap ('git is not on PATH, and it is needed to clone kingshand. Install it from ' +
                        'https://git-scm.com, open a new shell, and run this again.')
    }

    $target = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)

    # What is at the target decides everything after it, and only three answers let the run go on.
    $existing = $false
    if (Test-Path -LiteralPath $target -PathType Leaf) {
        Stop-Bootstrap "$target is a file, not a folder. Nothing was changed. Choose another -Path."
    }
    if (Test-Path -LiteralPath $target -PathType Container) {
        $first = Get-ChildItem -LiteralPath $target -Force | Select-Object -First 1
        if ($first) {
            $origin = $null
            if (Test-Path -LiteralPath (Join-Path $target '.git')) {
                $origin = (& git -C $target remote get-url origin 2>$null | Out-String).Trim()
                $global:LASTEXITCODE = 0
            }
            if (-not $origin -or (Get-RepositoryKey $origin) -ne (Get-RepositoryKey $Repository)) {
                $what = if ($origin) { "a clone of $(Format-Repository -Value $origin)" }
                        else { 'not a kingshand clone' }
                Stop-Bootstrap ("$target already exists, is not empty, and is $what. Nothing was " +
                                'changed - this never overwrites a folder. Choose an empty or new ' +
                                '-Path, or point it at an existing kingshand clone.')
            }
            $existing = $true
        }
    }

    # The release rules belong to the clone's own update module. Imported into this scope only,
    # so nothing is left loaded in the caller's session afterwards.
    $updateModule = Join-Path (Join-Path $target 'bin') 'Update.psm1'

    if ($existing) {
        Write-Host "$target is already a kingshand clone. Its checkout is left exactly as it is."
        if (-not (Test-Path -LiteralPath $updateModule -PathType Leaf)) {
            Write-Host 'Whether it is on a release could not be checked: it has no bin\Update.psm1.'
        } else {
            Import-Module $updateModule -Scope Local
            $headTags = @(& git -C $target tag --points-at HEAD 2>$null | ForEach-Object { "$_" })
            $code = $LASTEXITCODE
            $global:LASTEXITCODE = 0
            if ($code -ne 0) {
                Write-Host 'Whether it is on a release could not be checked: git could not read its tags.'
            } elseif (-not (Select-LatestReleaseTag -Tags $headTags)) {
                Write-Host 'It is not on a release; /update moves it to the latest release.'
            }
        }
    } else {
        Write-Host "Cloning $shown into $target"
        & git clone --quiet -- $Repository $target
        $code = $LASTEXITCODE
        $global:LASTEXITCODE = 0
        if ($code -ne 0) {
            Stop-Bootstrap ("git could not clone $shown into $target (exit code $code). See " +
                            "git's message above.")
        }

        if (-not (Test-Path -LiteralPath $updateModule -PathType Leaf)) {
            Stop-Bootstrap ("the clone at $target has no bin\Update.psm1, so its latest release " +
                            'could not be worked out. The clone is left in place.')
        }
        Import-Module $updateModule -Scope Local

        try {
            $tag = Get-LatestReleaseTag -RepoPath $target
        } catch {
            Stop-Bootstrap ("$target was cloned, but its latest release could not be read - " +
                            "$($_.Exception.Message) The clone is left in place.")
        }
        $branch = Get-ReleaseBranchName

        # -B puts the release branch at the tag rather than leaving a detached HEAD, because
        # `/update` refuses to run anywhere but on that branch. On a fresh clone nothing is lost.
        & git -C $target checkout --quiet -B $branch $tag
        $code = $LASTEXITCODE
        $global:LASTEXITCODE = 0
        if ($code -ne 0) {
            Stop-Bootstrap ("$target was cloned, but git could not check out $tag on $branch " +
                            "(exit code $code). The clone is left in place.")
        }
        Write-Host "Checked out $tag, the latest release, on $branch."
    }

    $installer = Join-Path $target 'install.ps1'
    if (-not (Test-Path -LiteralPath $installer -PathType Leaf)) {
        Stop-Bootstrap "there is no install.ps1 in $target, so there is nothing to run."
    }

    $installArgs = @{}
    if ($InstallMissing) { $installArgs['InstallMissing'] = $true }
    $flags = if ($InstallMissing) { ' -InstallMissing' } else { '' }
    Write-Host "Running $installer$flags"
    $global:LASTEXITCODE = 0
    # Out-Host keeps anything the installer writes to the pipeline on the screen, and out of the
    # exit code this block returns.
    & $installer @installArgs | Out-Host
    $code = $LASTEXITCODE
    $global:LASTEXITCODE = 0

    Write-Host ''
    if ($code -ne 0) {
        Write-Host ("install.ps1 finished with exit code $code. Its summary above says what " +
                    'still needs you.')
    }
    Write-Host "Next: open a new pwsh, cd to $target, and run claude. Then say: set it up"
    $code
}

if ($runAsFile) { exit $exitCode }
