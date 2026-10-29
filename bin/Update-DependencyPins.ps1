#Requires -Version 7.0
<#
.SYNOPSIS
  The weekly pin refresh, as data: for each dependency in dependencies.json, the pinned version,
  the latest published version, and whether moving to it crosses a breaking line. Also the one
  owner of the record saying when that weekly check last ran.
.DESCRIPTION
  Run plainly it is read-only. It writes nothing - not the manifest, not a cache, not a report file
  - and installs nothing, so a look at the report does not count as the weekly check. It is for
  whoever maintains kingshand's releases; the `statute` skill owns the procedure that acts on its
  answer.

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

  THE RECORD. `-Record` is the caller saying this run is the weekly check: the same rows come back,
  and once the report has completed the date is written to state\dependency-check.json. A report
  that throws - a manifest that cannot be read - records nothing, because no check ran. The file is
  machine-local, under the gitignored state\, and owned by this script alone: it is JSON stamped
  with its owner, and a file already at that path that is not this record is refused untouched. The
  path must end in `dependency-check.json`, so a mistyped path cannot land on another file in
  state\. It is written whole to a temp file beside it and renamed over it, so a killed run never
  leaves half a record.

  `-Due` reads that record and nothing else - no report, no network - and returns one object:

    state    not-due | due | never | unreadable
    lastRun  when the check last ran, as a UTC DateTime, or $null when there is none to give
    days     whole days since then, or $null
    detail   why the record could not be read, empty when it was

  `due` is more than 7 days. A record that cannot be read - not JSON, not this script's own, no
  date in it, or a date in the future - is `unreadable`, never a date, and the session-start digest
  treats it as due. CLAUDE.md's `## Session start` owns what the Hand does with a due check.
.PARAMETER Root
  The kingshand checkout whose dependencies.json is read. Defaults to this installation.
.PARAMETER Record
  This run is the weekly check: record the date once the report has completed.
.PARAMETER Due
  Say whether the weekly check is due, from the record alone.
.PARAMETER RecordPath
  The record. Defaults to state\dependency-check.json under Root.
.EXAMPLE
  .\bin\Update-DependencyPins.ps1 | Format-Table name, pinned, latest, move, breaking
.EXAMPLE
  .\bin\Update-DependencyPins.ps1 -Record | Format-Table name, pinned, latest, move, breaking
.EXAMPLE
  .\bin\Update-DependencyPins.ps1 -Due
#>
[CmdletBinding(DefaultParameterSetName = 'Report')]
param(
    [string]$Root,
    [Parameter(ParameterSetName = 'Record', Mandatory)][switch]$Record,
    [Parameter(ParameterSetName = 'Due', Mandatory)][switch]$Due,
    [string]$RecordPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Paths.psm1') -Force

$RecordName  = 'dependency-check.json'
$RecordOwner = 'kingshand-dependency-check'
$DueAfter    = [timespan]::FromDays(7)

if (-not $Root)       { $Root = Get-KingshandHome }
if (-not $RecordPath) { $RecordPath = Join-Path $Root "state\$RecordName" }

# The record's date as a UTC DateTime, or a sentence saying why there is none. ConvertFrom-Json turns
# an ISO 8601 string into a DateTime on its own, so both shapes are accepted; anything else is not a
# date this script wrote.
function Read-CheckRecord {
    param([Parameter(Mandatory)][string]$Path)
    $text = [System.IO.File]::ReadAllText($Path, [System.Text.UTF8Encoding]::new($false))
    $doc = $null
    try { $doc = $text | ConvertFrom-Json -AsHashtable -ErrorAction Stop } catch { $doc = $null }
    if ($doc -isnot [System.Collections.IDictionary] -or "$($doc['owner'])" -ne $RecordOwner) {
        return [pscustomobject]@{
            ours = $false; lastRun = $null; problem = "$Path is not this check's own record"
        }
    }
    $v = $doc['lastRun']
    $when = $null
    if ($v -is [datetime]) {
        $when = $v.ToUniversalTime()
    } elseif ($v -is [string]) {
        $parsed = [datetimeoffset]::MinValue
        if ([datetimeoffset]::TryParseExact($v, 'o', [cultureinfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::None, [ref]$parsed)) {
            $when = $parsed.UtcDateTime
        }
    }
    if ($null -eq $when) {
        return [pscustomobject]@{
            ours = $true; lastRun = $null; problem = "$Path carries no date it was last run"
        }
    }
    [pscustomobject]@{ ours = $true; lastRun = $when; problem = '' }
}

if ($Due) {
    $out = [ordered]@{ state = 'unreadable'; lastRun = $null; days = $null; detail = '' }
    try {
        if (-not (Test-Path -LiteralPath $RecordPath)) {
            $out.state = 'never'
        } elseif (-not (Test-Path -LiteralPath $RecordPath -PathType Leaf)) {
            $out.detail = "$RecordPath is not a file"
        } else {
            $r = Read-CheckRecord -Path $RecordPath
            $age = if ($r.lastRun) { [datetime]::UtcNow - $r.lastRun } else { $null }
            if ($r.problem) {
                $out.detail = $r.problem
            } elseif ($age -lt [timespan]::Zero) {
                # A date ahead of the clock would read as not due for as long as it stays ahead.
                $out.detail = ("$RecordPath says the check last ran in the future, at " +
                               $r.lastRun.ToString('o'))
            } else {
                $out.lastRun = $r.lastRun
                $out.days    = [int][math]::Floor($age.TotalDays)
                $out.state   = if ($age -gt $DueAfter) { 'due' } else { 'not-due' }
            }
        }
    } catch {
        $out.state  = 'unreadable'
        $out.detail = "$RecordPath could not be read - $($_.Exception.Message)"
    }
    return [pscustomobject]$out
}

Import-Module (Join-Path $PSScriptRoot 'Dependencies.psm1') -Force

if (-not $Record) {
    Get-DependencyPinReport -Root $Root
    return
}

# Refused before the report runs, so a record that would be refused does not cost a network round.
if ((Split-Path -Path $RecordPath -Leaf) -ne $RecordName) {
    throw "The check's record has to be named $RecordName and $RecordPath is not, so nothing was run."
}
if (Test-Path -LiteralPath $RecordPath) {
    $existing = $null
    if (Test-Path -LiteralPath $RecordPath -PathType Leaf) { $existing = Read-CheckRecord -Path $RecordPath }
    if ($null -eq $existing -or -not $existing.ours) {
        throw ("$RecordPath holds something that is not this check's own record, so nothing was " +
               'run and it was left untouched.')
    }
}

# Collected whole before anything is written: a report that throws partway has not run.
$rows = @(Get-DependencyPinReport -Root $Root)

$dir = Split-Path -Path $RecordPath -Parent
if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
}
$body = [ordered]@{ owner = $RecordOwner; lastRun = [datetime]::UtcNow.ToString('o') } | ConvertTo-Json
$temp = "$RecordPath.$([guid]::NewGuid().ToString('N')).tmp"
try {
    [System.IO.File]::WriteAllText($temp, $body, [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::Move($temp, $RecordPath, $true)
    $temp = $null
} finally {
    if ($temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
}

$rows
