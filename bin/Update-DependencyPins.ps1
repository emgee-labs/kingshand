#Requires -Version 7.0
<#
.SYNOPSIS
  The weekly pin refresh, as data: for each dependency in dependencies.json, the pinned version,
  the latest published version, and whether moving to it crosses a breaking line.
.DESCRIPTION
  Read-only. It writes nothing - not the manifest, not a cache, not a report file - and installs
  nothing. It is for whoever maintains kingshand's releases; the `statute` skill owns the procedure
  that acts on its answer.

  One row per pin, in manifest order:

    name            the dependency
    pinned          the pinned version, or the minimum for a dependency pinned by minimum
    latest          the latest published version, or $null when it could not be read
    pinnedProtocol  herdr only: the protocol the pinned version speaks
    latestProtocol  herdr only: the protocol the latest version speaks
    move            none | newer | older | unknown
    breaking        $true when the move crosses a breaking line, $false when it does not, $null
                    when it could not be told. bin\Dependencies.psm1 owns where that line is.
    detail          why `latest` could not be read, empty when it was

  A version that could not be read is never filled in. A row with `move` unknown is a row nobody
  can act on, and it says why.
.PARAMETER Root
  The kingshand checkout whose dependencies.json is read. Defaults to this installation.
.EXAMPLE
  .\bin\Update-DependencyPins.ps1 | Format-Table name, pinned, latest, move, breaking
#>
[CmdletBinding()]
param([string]$Root)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Paths.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Dependencies.psm1') -Force

if (-not $Root) { $Root = Get-KingshandHome }
Get-DependencyPinReport -Root $Root
