#Requires -Version 7.0
Set-StrictMode -Version Latest

# A stand-in program the code under test can find on PATH and launch, on whichever system runs the
# suite. Not a test file - Pester only runs *.Tests.ps1 - but the one place a test makes a fake
# executable, so the Windows and Unix shapes cannot drift apart file by file.
#
# Windows starts a `.cmd` natively, and nothing else without an extension. macOS and Linux do not
# know `.cmd` at all - a file named that is not executable, Get-Command does not find it as an
# Application, and an editor association can open it instead of running it - so there the stand-in
# is an extensionless `#!/bin/sh` script with its execute bit set.
#
# Each caller writes both bodies, because they are two languages: -Cmd is batch, -Sh is POSIX sh.
# The execute bit goes on through .NET rather than `chmod`, because a test may already have pointed
# PATH at a fixture directory that holds no chmod.

function New-TestExecutable {
    [CmdletBinding()]
    param(
        # The path WITHOUT an extension: `.cmd` is added on Windows and nothing elsewhere.
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Cmd,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Sh
    )

    if ($IsWindows) {
        $target = "$Path.cmd"
        Set-Content -LiteralPath $target -Encoding ascii -Value (@('@echo off') + @($Cmd))
        return $target
    }

    # LF line ends and no BOM: a shebang line ending in CR names an interpreter that is not there.
    $text = ((@('#!/bin/sh') + @($Sh)) -join "`n") + "`n"
    [IO.File]::WriteAllText($Path, $text, [Text.UTF8Encoding]::new($false))
    [IO.File]::SetUnixFileMode($Path, [IO.UnixFileMode]'UserRead, UserWrite, UserExecute')
    $Path
}

Export-ModuleMember -Function New-TestExecutable
