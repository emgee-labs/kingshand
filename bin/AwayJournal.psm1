#Requires -Version 7.0
Set-StrictMode -Version Latest

# NOT -Force - a module never forces a nested import, because the removal takes the copy the
# calling script already had. The rule is in the `statute` skill's style rules.
Import-Module (Join-Path $PSScriptRoot 'Paths.psm1')
Import-Module (Join-Path $PSScriptRoot 'Index.psm1')

# The away journal: one durable record per outcome while the King is away, and the one source the
# return digest is rendered from.
#
# THE FAILURE THIS REMOVES. Everything that happened during an away period used to be accumulated
# in the Hand's session, and the digest was composed from that. A restart before the King came back
# took the account with it while the work itself survived - so he got a thinner report and nothing
# anywhere said it was thinner. That is the whole reason this file exists, and it is why an
# unreadable journal is reported as unreadable rather than rendering as an empty one: a silent
# fallback to whatever the session happens to remember is the same failure in a new place.
#
# WHERE IT LIVES: data\away\<stamp>.jsonl, one file per away period. `state\` holds what the Hand
# owns and reconciles against reality - crew.json against herdr, the .afk flag against whether the
# King is at the machine - and every one of those is about the present. A journal is about the past,
# is never reconciled, and is read after the period it describes has ended, which is what data\ is
# for. It is kept rather than cleared on return: the decisions it records are exactly the ones
# `petition` requires to be reviewable, and deleting the record at the moment it becomes reviewable
# is the wrong direction. docs\2026-09-25-away-journal.md argues both decisions in full.
#
# THE FILE NAME comes from the `since:` line of `state\.afk`, re-rendered from a parsed timestamp.
# Two consequences, both deliberate. A second away period has a different `since:` and so cannot
# touch the first one's file; a session that restarts mid-period reads the same `since:` and appends
# to the same file. And because the stamp is re-rendered rather than copied, no byte of file content
# reaches the path - the name can only ever be digits, `T` and `Z`.
#
# THE FORMAT is JSON Lines: one JSON object per line, written by ConvertTo-Json and read back by
# ConvertFrom-Json, so nothing here parses an open-ended text format by hand. Appending one line is
# atomic enough to be safe at any moment, which is what lets an outcome be recorded as it happens
# rather than assembled at the end. A line that does not parse is counted and named, never skipped.

$script:JournalDirName  = 'away'
$script:JournalExt      = '.jsonl'
$script:HeaderRecord    = 'away-journal'
$script:EntryRecord     = 'away-entry'
$script:FormatVersion   = 1

# The closed set of kinds. It is closed on purpose: the writer refuses anything else, which is what
# keeps the reader's case space bounded, and a kind read back that is not in this set is reported
# under its own name rather than dropped into a bucket that hides it.
$script:Kinds = @('dispatched', 'landed', 'failed', 'blocked', 'decided', 'waiting', 'closed-out', 'note')

# Whether a decision taken in the King's stead rested on something he had already said, or on the
# Hand's own judgement. `regency`'s return digest and `petition` both require that flag; recording
# it is what makes the digest reviewable rather than merely informative.
$script:Bases = @('recorded', 'judgement')

# Digits, T and Z, and nothing else. Asserted after the stamp is built, so a later change to the
# format cannot introduce a separator and let a journal be written outside data\away\.
$script:StampPattern = '^[0-9]{8}T[0-9]{6}Z$'

$script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function Get-DefaultAwayFlagPath {
    Join-Path (Get-KingshandHome) 'state\.afk'
}

function Get-DefaultAwayDataPath {
    Join-Path (Get-KingshandHome) 'data'
}

# `state\.afk`'s `since:` value, verbatim. `regency` writes that file and owns its shape; this is
# the one place anything reads it, so the flag and the journal name cannot drift apart. Throws with
# the path in the message rather than returning a blank, because a `since:` nobody can read must
# never become a journal nobody can find.
function Read-AwaySince {
    param([Parameter(Mandatory)][string]$FlagPath)

    if (-not (Test-Path -LiteralPath $FlagPath)) {
        throw "No regency is in force: there is no away flag at $FlagPath."
    }
    if (Test-Path -LiteralPath $FlagPath -PathType Container) {
        throw "The away flag at $FlagPath is a directory, not a file. The regency skill writes it as a file with a since: line."
    }

    $text  = [System.IO.File]::ReadAllText($FlagPath) -replace "`r`n", "`n"
    $value = ''
    foreach ($line in $text.Split("`n")) {
        if ($line -match '^since:\s*(?<v>\S.*)$') { $value = $Matches['v'].Trim(); break }
    }
    if (-not $value) {
        throw "The away flag at $FlagPath has no since: line, so the away period has no start and its journal has no name. Rewrite the flag as regency step 1 does."
    }
    $value
}

# One timestamp string as the instant it names, or $null when it names none. The single parse point
# for everything in this file that has to decide whether two `since:` values are the same period.
function ConvertTo-AwayInstant {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)

    $parsed = [datetimeoffset]::MinValue
    $styles = [System.Globalization.DateTimeStyles]::AllowWhiteSpaces -bor
              [System.Globalization.DateTimeStyles]::AssumeUniversal
    $ok = [datetimeoffset]::TryParse(
            $Value, [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)
    if (-not $ok) { return $null }
    $parsed.ToUniversalTime()
}

# Whether two `since:` values name the same away period. THE INSTANT, NEVER THE BYTES: the header's
# value has been through ConvertFrom-Json, which recognises an ISO timestamp and hands back a
# DateTime that re-renders with seven fraction digits, while the flag holds whatever regency wrote -
# so `2026-09-25T00:59:24Z` on disk came back as `2026-09-25T00:59:24.0000000Z` and a perfectly good
# journal was refused from its second record on, with the return digest calling it unreadable. Two
# spellings of one instant are one period, and an offset form is the same period as its UTC form.
# Where either side does not parse there is no instant to compare, so the literal text decides and a
# header holding something that is not a timestamp is still refused.
function Test-SameAwayPeriod {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Left,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Right
    )

    $l = ConvertTo-AwayInstant -Value $Left
    $r = ConvertTo-AwayInstant -Value $Right
    if ($null -eq $l -or $null -eq $r) { return $Left -eq $Right }
    $l -eq $r
}

# The `since:` value re-rendered as the journal's file name. RE-RENDERED, not copied: the value is
# parsed as a timestamp first and the name is built from the result, so whatever the flag holds, the
# name is digits, `T` and `Z`. A value that does not parse is refused rather than sanitised, because
# a sanitised name is a name pointing at the wrong period.
function ConvertTo-AwayStamp {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Since)

    $parsed = ConvertTo-AwayInstant -Value $Since
    if ($null -eq $parsed) {
        throw "The away flag's since: value reads '$Since', which is not a timestamp. Regency writes it as (Get-Date).ToUniversalTime().ToString('o')."
    }

    $stamp = $parsed.ToString(
                "yyyyMMdd'T'HHmmss'Z'", [System.Globalization.CultureInfo]::InvariantCulture)
    if ($stamp -notmatch $script:StampPattern) {
        throw "Refusing to build a journal name from '$Since': the stamp '$stamp' is not of the form 20260925T005924Z, and only that form is allowed to become a file name."
    }
    $stamp
}

# What the away flag says, without ever throwing. The digest reads it at return and the session
# digest reads it at startup, and neither can afford an exception from a file the King wrote by
# hand. An unreadable flag comes back with `problem` set and `since` empty - never with a guessed
# start, and never as "no regency in force", which is a different fact entirely.
function Get-AwayFlag {
    [CmdletBinding()]
    param(
        [string]$FlagPath = (Get-DefaultAwayFlagPath),
        [string]$DataPath = (Get-DefaultAwayDataPath)
    )

    $result = @{
        path        = $FlagPath
        present     = [bool](Test-Path -LiteralPath $FlagPath)
        since       = ''
        stamp       = ''
        journalPath = ''
        problem     = $null
    }
    if (-not $result.present) { return $result }

    try {
        $result.since       = Read-AwaySince -FlagPath $FlagPath
        $result.stamp       = ConvertTo-AwayStamp -Since $result.since
        $result.journalPath = Join-Path $DataPath "$script:JournalDirName\$($result.stamp)$script:JournalExt"
    } catch {
        $result.problem = $_.Exception.Message
    }
    $result
}

function Read-JournalLines {
    param([Parameter(Mandatory)][string]$Path)

    $text = [System.IO.File]::ReadAllText($Path) -replace "`r`n", "`n"
    @($text.Split("`n") | Where-Object { $_.Trim() })
}

# One JSON line as a dictionary, or $null when it is not a JSON object at all. Nothing downstream
# indexes into the result without checking, because a line holding `5` or `"text"` is valid JSON
# and is still not a record.
function ConvertFrom-JournalLine {
    param([Parameter(Mandatory)][string]$Line)

    $obj = $null
    try { $obj = $Line | ConvertFrom-Json -AsHashtable } catch { return $null }
    if ($obj -is [System.Collections.IDictionary]) { return $obj }
    $null
}

# One field, always as the string that was written. The normalisation is not cosmetic:
# ConvertFrom-Json recognises an ISO-8601 string and hands back a DateTime, so `since` and `at` come
# out of the reader as objects and [string] renders them in the machine's own culture - which made
# a journal's own header disagree with the flag that named it, and every away period after the first
# unreadable on a machine whose short date format is not ISO. Re-rendering round-trip restores the
# exact bytes that were written.
function Get-RecordField {
    param($Record, [Parameter(Mandatory)][string]$Name)

    if ($null -eq $Record) { return '' }
    if (-not $Record.Contains($Name)) { return '' }
    $v = $Record[$Name]
    if ($null -eq $v) { return '' }
    $invariant = [System.Globalization.CultureInfo]::InvariantCulture
    if ($v -is [datetime])       { return $v.ToUniversalTime().ToString('o', $invariant) }
    if ($v -is [datetimeoffset]) { return $v.ToUniversalTime().ToString('o', $invariant) }
    [string]$v
}

# Refuses to append to a file this module did not write. The first line of every journal is its
# header, and it has to be this format, this version and this away period - so a file that happens
# to land on the same name, or a journal belonging to a different period, is named in an error
# instead of being appended to.
function Assert-JournalHeader {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Since
    )

    $lines = @(Read-JournalLines -Path $Path)
    if ($lines.Count -eq 0) {
        throw "$Path exists but is empty, so nothing proves it is an away journal. Move it aside; the journal for this period cannot be written over it."
    }

    $header = ConvertFrom-JournalLine -Line $lines[0]
    if (-not $header -or (Get-RecordField -Record $header -Name 'record') -ne $script:HeaderRecord) {
        throw "$Path is not an away journal - its first line is not a $script:HeaderRecord header. Refusing to write over a file this did not create."
    }

    $version = Get-RecordField -Record $header -Name 'version'
    if ($version -ne [string]$script:FormatVersion) {
        throw "$Path is an away journal of version '$version' and this reads version $script:FormatVersion. Refusing to append a record the reader of that file would not understand."
    }

    $itsSince = Get-RecordField -Record $header -Name 'since'
    if (-not (Test-SameAwayPeriod -Left $itsSince -Right $Since)) {
        throw "$Path is the journal of the away period beginning $itsSince, and the flag says this period began $Since. Refusing to write one period's outcomes into another's record."
    }
}

function Add-JournalLine {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][hashtable]$Record
    )

    $line = ConvertTo-Json -InputObject $Record -Compress -Depth 4
    [System.IO.File]::AppendAllText($Path, $line + "`n", $script:Utf8NoBom)
    $line
}

# Opens the journal for the away period the flag names, and lists it in the data index. Idempotent:
# a session that restarts mid-period opens the same file again, finds its header, and leaves the
# existing records alone - which is what makes a restart append rather than start over.
#
# The file is created BEFORE the index entry, and an index failure is reported rather than thrown.
# The journal is the thing that must survive; losing a record because a table of contents could not
# be updated would trade the whole point of the file for a line in another one.
#
# The index entry is re-asserted on EVERY open, not only on the one that creates the file. An index
# write that failed once would otherwise never be retried, and the journal would sit in the
# session-start unindexed count for good with no path that clears it. Add-IndexEntry rewrites an
# existing entry in place and keeps the date it first entered the index, so a reopen costs a line
# rewritten rather than a file that looks newly added.
function Open-AwayJournal {
    [CmdletBinding()]
    param(
        [string]$FlagPath = (Get-DefaultAwayFlagPath),
        [string]$DataPath = (Get-DefaultAwayDataPath)
    )

    $since = Read-AwaySince -FlagPath $FlagPath
    $stamp = ConvertTo-AwayStamp -Since $since
    $dir   = Join-Path $DataPath $script:JournalDirName
    $path  = Join-Path $dir "$stamp$script:JournalExt"

    $result = @{
        path         = $path
        since        = $since
        stamp        = $stamp
        created      = $false
        indexed      = $false
        indexProblem = $null
    }

    if (Test-Path -LiteralPath $path -PathType Container) {
        throw "$path is a directory, not a journal. The away journal for this period cannot be written."
    }

    if (Test-Path -LiteralPath $path -PathType Leaf) {
        Assert-JournalHeader -Path $path -Since $since
    } else {
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
        }

        $null = Add-JournalLine -Path $path -Record @{
            record  = $script:HeaderRecord
            version = $script:FormatVersion
            since   = $since
            opened  = (Get-Date).ToUniversalTime().ToString('o')
        }
        $result.created = $true
    }

    try {
        $null = Add-IndexEntry -Path $path -DataPath $DataPath `
            -Summary "away journal for the regency beginning $since - one record per outcome; the return digest is rendered from it"
        $result.indexed = $true
    } catch {
        $result.indexProblem = $_.Exception.Message
    }
    $result
}

# Records one outcome, now. Every field a digest needs comes from here and nothing is added later:
# `at` is stamped by this function and cannot be supplied, so a journal assembled at the end of an
# away period is visibly assembled at the end rather than passing as a contemporaneous record.
#
# It also cannot be written outside an away period at all - the path comes from the flag, and with
# no flag there is no regency, no journal and an error saying so. That is the floor under "written
# as each thing happens": once the King is back and the flag is gone, nothing more can be added.
#
# -Basis is required for a decision and refused for anything else. `regency` and `petition` both
# require every call taken in his stead to record whether it rested on a position he had already
# stated or on the Hand's own judgement; this is that requirement with something behind it.
function Write-AwayJournalEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('dispatched', 'landed', 'failed', 'blocked', 'decided', 'waiting', 'closed-out', 'note')]
        [string]$Kind,

        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Text,

        [string]$Worker,
        [ValidateSet('recorded', 'judgement')][string]$Basis,
        [string]$Evidence,

        [string]$FlagPath = (Get-DefaultAwayFlagPath),
        [string]$DataPath = (Get-DefaultAwayDataPath)
    )

    if ($Kind -eq 'decided' -and -not $Basis) {
        throw "A decided entry needs -Basis 'recorded' or 'judgement': the return digest has to say whether the call rested on a position the King had already stated or on your own judgement."
    }
    if ($Kind -ne 'decided' -and $Basis) {
        throw "-Basis belongs to a decided entry and nothing else. A '$Kind' entry records what happened, not on what authority."
    }

    $opened = Open-AwayJournal -FlagPath $FlagPath -DataPath $DataPath

    $record = @{
        record = $script:EntryRecord
        at     = (Get-Date).ToUniversalTime().ToString('o')
        kind   = $Kind
        text   = $Text
    }
    if ($Worker)   { $record['worker']   = $Worker }
    if ($Basis)    { $record['basis']    = $Basis }
    if ($Evidence) { $record['evidence'] = $Evidence }

    $line = Add-JournalLine -Path $opened.path -Record $record

    @{
        path         = $opened.path
        since        = $opened.since
        at           = $record['at']
        kind         = $Kind
        line         = $line
        indexed      = $opened.indexed
        indexProblem = $opened.indexProblem
    }
}

function New-EmptyByKind {
    $byKind = @{}
    foreach ($k in $script:Kinds) { $byKind[$k] = @() }
    $byKind
}

# Everything the return digest is made of, read from the journal - or a plain statement that it
# could not be read. Never throws, and never returns a digest-shaped success it did not read off
# disk: `readable` is $false exactly when there is no account to give, and `summary` is then a
# sentence saying so, so the words the King sees come from here rather than being composed over an
# absence. An away period that produced nothing is a different answer entirely - readable, zero
# entries, and "Nothing needed you."
#
# -Path reads one named journal directly, for a period whose flag has already been removed. With no
# -Path the journal is the one the flag names, which is why the return digest is read BEFORE the
# flag comes off.
function Get-AwayDigest {
    [CmdletBinding()]
    param(
        [string]$Path,
        [string]$FlagPath = (Get-DefaultAwayFlagPath),
        [string]$DataPath = (Get-DefaultAwayDataPath)
    )

    $result = @{
        path         = $Path
        since        = ''
        opened       = ''
        readable     = $false
        problem      = $null
        summary      = ''
        count        = 0
        entries      = @()
        byKind       = (New-EmptyByKind)
        damaged      = 0
        damagedLines = @()
        unknownKinds = @()
    }

    $unreadable = {
        param([string]$Problem)
        $result.problem = $Problem
        $result.summary = "The away journal could not be read: $Problem There is no account of this away period, " +
                          "and nothing here was reconstructed from memory."
        $result
    }

    if (-not $Path) {
        try {
            $since = Read-AwaySince -FlagPath $FlagPath
            $stamp = ConvertTo-AwayStamp -Since $since
            $result.since = $since
            $result.path  = Join-Path $DataPath "$script:JournalDirName\$stamp$script:JournalExt"
        } catch {
            return (& $unreadable $_.Exception.Message)
        }
    }

    if (-not (Test-Path -LiteralPath $result.path -PathType Leaf)) {
        return (& $unreadable "no journal was opened at $($result.path).")
    }

    $lines = @()
    try { $lines = @(Read-JournalLines -Path $result.path) }
    catch { return (& $unreadable "$($result.path) could not be read - $($_.Exception.Message)") }

    if ($lines.Count -eq 0) {
        return (& $unreadable "$($result.path) is empty, so it carries no header and no records.")
    }

    $header = ConvertFrom-JournalLine -Line $lines[0]
    if (-not $header -or (Get-RecordField -Record $header -Name 'record') -ne $script:HeaderRecord) {
        return (& $unreadable "$($result.path) does not begin with an away-journal header, so it is not a journal this can read.")
    }

    $headerSince = Get-RecordField -Record $header -Name 'since'
    if ($result.since -and $headerSince -and -not (Test-SameAwayPeriod -Left $headerSince -Right $result.since)) {
        return (& $unreadable "$($result.path) is the journal of the period beginning $headerSince, and the flag says this period began $($result.since).")
    }
    if (-not $result.since) { $result.since = $headerSince }
    $result.opened = Get-RecordField -Record $header -Name 'opened'

    $entries      = [System.Collections.Generic.List[hashtable]]::new()
    $damagedLines = [System.Collections.Generic.List[int]]::new()
    $unknown      = [System.Collections.Generic.List[string]]::new()

    for ($i = 1; $i -lt $lines.Count; $i++) {
        $rec = ConvertFrom-JournalLine -Line $lines[$i]
        if (-not $rec -or (Get-RecordField -Record $rec -Name 'record') -ne $script:EntryRecord) {
            $damagedLines.Add($i + 1)
            continue
        }

        $kind  = Get-RecordField -Record $rec -Name 'kind'
        $entry = @{
            at       = Get-RecordField -Record $rec -Name 'at'
            kind     = $kind
            text     = Get-RecordField -Record $rec -Name 'text'
            worker   = Get-RecordField -Record $rec -Name 'worker'
            basis    = Get-RecordField -Record $rec -Name 'basis'
            evidence = Get-RecordField -Record $rec -Name 'evidence'
        }
        $entries.Add($entry)

        if ($script:Kinds -contains $kind) {
            $result.byKind[$kind] = @($result.byKind[$kind]) + @($entry)
        } elseif (-not $unknown.Contains($kind)) {
            $unknown.Add($kind)
        }
    }

    $result.readable     = $true
    $result.entries      = @($entries.ToArray())
    $result.count        = $entries.Count
    $result.damaged      = $damagedLines.Count
    $result.damagedLines = @($damagedLines.ToArray())
    $result.unknownKinds = @($unknown.ToArray())

    $result.summary = if ($result.count -eq 0) {
        'Nothing needed you.'
    } elseif ($result.count -eq 1) {
        'One thing was recorded while you were away.'
    } else {
        "$($result.count) things were recorded while you were away."
    }
    if ($result.damaged -eq 1) {
        $result.summary += " One further record, on line $($result.damagedLines[0]), could not be read, so this account is incomplete."
    } elseif ($result.damaged -gt 1) {
        $result.summary += " $($result.damaged) further records, on lines $($result.damagedLines -join ', '), could not be read, so this account is incomplete."
    }
    if ($result.unknownKinds.Count -gt 0) {
        $result.summary += " Some records use a kind this version does not group: $($result.unknownKinds -join ', ')."
    }
    $result
}

Export-ModuleMember -Function Get-AwayFlag, Open-AwayJournal, Write-AwayJournalEntry, Get-AwayDigest
