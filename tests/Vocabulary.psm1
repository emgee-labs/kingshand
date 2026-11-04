#Requires -Version 7.0
Set-StrictMode -Version Latest

# The vocabulary guard behind tests\Vocabulary.Tests.ps1. Not a test file - Pester only runs
# *.Tests.ps1 - but the one place that knows how a banned word is found, so the check on the real
# tree and the checks that prove it works run exactly the same code.
#
# The banned list is a PowerShell data file read by Import-PowerShellDataFile, and the search is
# `git grep`: git owns which files are tracked and which are binary, and a fixed string matched
# whole and case-insensitively is a closed question to ask it. Nothing here parses the files it
# searches. The one thing done on this side is masking an allowed phrase out of a matched line
# before looking for the word again, and both are literals.
#
# Every failure throws naming what failed. An unreadable list or a git grep that errors is never
# read as "nothing found".

function Read-BannedWordList {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "The banned-word list '$Path' does not exist."
    }
    try {
        $data = Import-PowerShellDataFile -LiteralPath $Path -ErrorAction Stop
    } catch {
        throw "The banned-word list '$Path' could not be read: $($_.Exception.Message)"
    }

    foreach ($key in $data.Keys) {
        if ($key -notin 'Banned', 'Allow') { throw "The banned-word list '$Path' has an unknown key '$key'." }
    }

    $wordShape = '^[A-Za-z0-9_-]+$'
    $banned = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in @(if ($data.ContainsKey('Banned')) { $data.Banned })) {
        if ($entry -isnot [hashtable]) { throw "A Banned entry in '$Path' is not a @{ ... } entry." }
        foreach ($field in 'Word', 'Use', 'Reason') {
            if (-not ($entry.ContainsKey($field) -and $entry[$field] -is [string] -and $entry[$field].Trim())) {
                throw "A Banned entry in '$Path' has no $field."
            }
        }
        if ($entry.Word -notmatch $wordShape) {
            throw "The banned word '$($entry.Word)' in '$Path' is not one word of letters, digits, '_' or '-'."
        }
        if (-not $seen.Add($entry.Word)) { throw "The banned word '$($entry.Word)' appears twice in '$Path'." }
        $banned.Add([pscustomobject]@{ Word = $entry.Word; Use = $entry.Use; Reason = $entry.Reason })
    }

    $allow = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in @(if ($data.ContainsKey('Allow')) { $data.Allow })) {
        if ($entry -isnot [hashtable]) { throw "An Allow entry in '$Path' is not a @{ ... } entry." }
        foreach ($field in 'Word', 'Reason') {
            if (-not ($entry.ContainsKey($field) -and $entry[$field] -is [string] -and $entry[$field].Trim())) {
                throw "An Allow entry in '$Path' has no $field."
            }
        }
        $hasFile = $entry.ContainsKey('File')
        $hasPhrase = $entry.ContainsKey('Phrase')
        if ($hasFile -eq $hasPhrase) {
            throw "The Allow entry for '$($entry.Word)' in '$Path' must name exactly one of File or Phrase."
        }
        $value = if ($hasFile) { $entry.File } else { $entry.Phrase }
        if (-not ($value -is [string] -and $value.Trim())) {
            throw "The Allow entry for '$($entry.Word)' in '$Path' has an empty $(if ($hasFile) { 'File' } else { 'Phrase' })."
        }
        if ($hasPhrase -and $value.IndexOf($entry.Word, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
            throw "The Allow phrase '$value' in '$Path' does not contain its word '$($entry.Word)', so it can never apply."
        }
        # git lists paths with '/', so a File written with '\' is turned round to match.
        $file = $null
        $phrase = $null
        if ($hasFile) { $file = $value.Replace('\', '/') } else { $phrase = $value }
        $allow.Add([pscustomobject]@{ Word = $entry.Word; File = $file; Phrase = $phrase })
    }

    [pscustomobject]@{ Banned = $banned.ToArray(); Allow = $allow.ToArray() }
}

<#
.SYNOPSIS
Finds every banned word in the files git tracks under -Pathspec in the repository at -Root.

.OUTPUTS
One object per offending line: File (as git lists it), Line, Word, Use, Reason, Text, and Message
- the sentence a failing test shows. Nothing at all when the tree is clean.
#>
function Find-BannedVocabulary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ListPath,
        [Parameter(Mandatory)][string[]]$Pathspec
    )

    $list = Read-BannedWordList -Path $ListPath
    $listFile = [System.IO.Path]::GetRelativePath((Resolve-Path -LiteralPath $Root).Path,
        (Resolve-Path -LiteralPath $ListPath).Path) -replace '\\', '/'

    # git's -w counts letters, digits and '_' as word characters, so the re-check after masking
    # uses the same ASCII set rather than .NET's Unicode \b.
    $wordChar = '[A-Za-z0-9_]'

    foreach ($ban in $list.Banned) {
        $all = @(& git -C $Root -c core.quotepath=off grep -z -n -I -i -w -F --no-color -e $ban.Word -- @Pathspec 2>&1)
        $code = $LASTEXITCODE
        $errors = @($all | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] })
        $out = @($all | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })
        if ($code -eq 1 -and -not $errors) { continue }
        if ($code -ne 0) {
            throw "git grep for '$($ban.Word)' under '$Root' failed (exit $code): $($errors -join ' ')"
        }

        $files = @($list.Allow | Where-Object { $_.Word -eq $ban.Word -and $_.File } | ForEach-Object File)
        $phrases = @($list.Allow | Where-Object { $_.Word -eq $ban.Word -and $_.Phrase } | ForEach-Object Phrase)
        $wordPattern = "(?i)(?<!$wordChar)$([regex]::Escape($ban.Word))(?!$wordChar)"

        foreach ($record in $out) {
            $parts = "$record".Split([char]0, 3)
            if ($parts.Count -ne 3) { throw "git grep for '$($ban.Word)' returned a line it did not shape as file, line, text: $record" }
            $file, $lineNo, $text = $parts
            $text = $text.TrimEnd("`r")
            if ($file -eq $listFile) { continue }
            if ($files -contains $file) { continue }
            if ($phrases.Count) {
                $masked = $text
                foreach ($phrase in $phrases) {
                    $masked = [regex]::Replace($masked, "(?i)$([regex]::Escape($phrase))", { param($m) ' ' * $m.Length })
                }
                if ($masked -notmatch $wordPattern) { continue }
            }
            [pscustomobject]@{
                File    = $file
                Line    = [int]$lineNo
                Word    = $ban.Word
                Use     = $ban.Use
                Reason  = $ban.Reason
                Text    = $text.Trim()
                Message = "${file}:${lineNo}: '$($ban.Word)' - use '$($ban.Use)' instead ($($ban.Reason))"
            }
        }
    }
}

<#
.SYNOPSIS
Throws one message listing every banned word found, or returns nothing when the tree is clean.
#>
function Assert-NoBannedVocabulary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ListPath,
        [Parameter(Mandatory)][string[]]$Pathspec
    )

    $found = @(Find-BannedVocabulary -Root $Root -ListPath $ListPath -Pathspec $Pathspec)
    if ($found.Count) {
        throw ("$($found.Count) banned word(s) in tracked material - edit the text, or add a literal " +
               "exception to '$ListPath':" + [Environment]::NewLine +
               (($found | ForEach-Object Message) -join [Environment]::NewLine))
    }
}

Export-ModuleMember -Function Read-BannedWordList, Find-BannedVocabulary, Assert-NoBannedVocabulary
