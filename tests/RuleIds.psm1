#Requires -Version 7.0
Set-StrictMode -Version Latest

# The rule-id check behind tests\RuleIds.Tests.ps1. Not a test file - Pester only runs
# *.Tests.ps1 - but the one place that knows how a rule id is found, so the check on the real tree
# and the checks that prove it works run exactly the same code.
#
# The grammar is statute's, under "Rule ids", and it is closed: a declaration is the literal
# `<!-- rule:` then an id then ` -->`, a citation is `[rule:` then an id then `]`, and an id is
# lower-case letters, digits and '-' either side of one '/'. git does every match - which files
# are tracked, which are binary, and where each fixed-shape pattern sits - so nothing here parses
# Markdown or reads a heading, a fence or a code span. A form inside a code span counts exactly as
# it does anywhere else, and that is the point of a grammar matched literally.
#
# The one thing done on this side is counting. A line holding the literal opening `[rule:` or
# `<!-- rule:` more times than git found whole forms on it carries one that is malformed, and an
# allowed phrase is masked out of the line before the opening is counted. Both are literals.
#
# Every failure throws naming what failed. An unreadable list or a git grep that errors is never
# read as "nothing found".

$script:IdPattern = '[a-z0-9-]+/[a-z0-9-]+'
$script:DeclarePattern = "<!-- rule:$($script:IdPattern) -->"
$script:CitePattern = "\[rule:$($script:IdPattern)\]"
$script:DeclareOpen = '<!-- rule:'
$script:CiteOpen = '[rule:'

function Read-RuleIdList {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "The rule-id list '$Path' does not exist."
    }
    try {
        $data = Import-PowerShellDataFile -LiteralPath $Path -ErrorAction Stop
    } catch {
        throw "The rule-id list '$Path' could not be read: $($_.Exception.Message)"
    }

    foreach ($key in $data.Keys) {
        if ($key -notin 'Uncited', 'NotAnId') { throw "The rule-id list '$Path' has an unknown key '$key'." }
    }

    $uncited = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($entry in @(if ($data.ContainsKey('Uncited')) { $data.Uncited })) {
        if ($entry -isnot [hashtable]) { throw "An Uncited entry in '$Path' is not a @{ ... } entry." }
        foreach ($field in 'Id', 'Reason') {
            if (-not ($entry.ContainsKey($field) -and $entry[$field] -is [string] -and $entry[$field].Trim())) {
                throw "An Uncited entry in '$Path' has no $field."
            }
        }
        if ($entry.Id -cnotmatch "^$($script:IdPattern)$") {
            throw "The Uncited id '$($entry.Id)' in '$Path' is not a rule id: lower-case letters, digits and '-' either side of one '/'."
        }
        if (-not $seen.Add($entry.Id)) { throw "The Uncited id '$($entry.Id)' appears twice in '$Path'." }
        $uncited.Add([pscustomobject]@{ Id = $entry.Id; Reason = $entry.Reason })
    }

    $notAnId = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in @(if ($data.ContainsKey('NotAnId')) { $data.NotAnId })) {
        if ($entry -isnot [hashtable]) { throw "A NotAnId entry in '$Path' is not a @{ ... } entry." }
        foreach ($field in 'File', 'Phrase', 'Reason') {
            if (-not ($entry.ContainsKey($field) -and $entry[$field] -is [string] -and $entry[$field].Trim())) {
                throw "A NotAnId entry in '$Path' has no $field."
            }
        }
        if (-not ($entry.Phrase.Contains($script:DeclareOpen) -or $entry.Phrase.Contains($script:CiteOpen))) {
            throw "The NotAnId phrase '$($entry.Phrase)' in '$Path' holds neither '$($script:DeclareOpen)' nor '$($script:CiteOpen)', so it can never apply."
        }
        # git lists paths with '/', so a File written with '\' is turned round to match.
        $notAnId.Add([pscustomobject]@{ File = $entry.File.Replace('\', '/'); Phrase = $entry.Phrase })
    }

    [pscustomobject]@{ Uncited = $uncited.ToArray(); NotAnId = $notAnId.ToArray() }
}

# One git grep, its records split on NUL into file, line and the rest. Exit 1 with nothing on
# stderr is git's "no match"; anything else that is not 0 throws.
function Invoke-RuleIdGrep {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string[]]$GrepArgs,
        [Parameter(Mandatory)][string[]]$Pathspec,
        [Parameter(Mandatory)][string]$What
    )
    $all = @(& git -C $Root -c core.quotepath=off grep -z -n -I --no-color @GrepArgs -- @Pathspec 2>&1)
    $code = $LASTEXITCODE
    $errors = @($all | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] })
    $out = @($all | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })
    $records = [System.Collections.Generic.List[object]]::new()
    if ($code -eq 1 -and -not $errors) { return , $records }
    if ($code -ne 0) { throw "git grep for $What under '$Root' failed (exit $code): $($errors -join ' ')" }
    foreach ($record in $out) {
        $parts = "$record".Split([char]0, 3)
        if ($parts.Count -ne 3) { throw "git grep for $What returned a line it did not shape as file, line, text: $record" }
        $records.Add([pscustomobject]@{ File = $parts[0]; Line = [int]$parts[1]; Text = $parts[2].TrimEnd("`r") })
    }
    return , $records
}

# Where a declaration of this owner must sit. The owner is the part of the id before '/', and it
# names one file: `claude` is CLAUDE.md, a dated name is that design note, anything else is a
# skill.
function Get-RuleIdOwnerFile {
    param([Parameter(Mandatory)][string]$Owner)
    if ($Owner -ceq 'claude') { return 'CLAUDE.md' }
    if ($Owner -cmatch '^[0-9]{4}-[0-9]{2}-[0-9]{2}-') { return "docs/$Owner.md" }
    ".claude/skills/$Owner/SKILL.md"
}

<#
.SYNOPSIS
Finds every rule-id problem in the files git tracks under -Pathspec in the repository at -Root.

.OUTPUTS
One object per problem: File (as git lists it), Line, Id, Kind and Message - the sentence a
failing test shows. Kind is one of Undeclared, Duplicate, WrongOwner, Uncited, Malformed and
StaleList. Nothing at all when the tree is clean.
#>
function Find-RuleIdProblem {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ListPath,
        [Parameter(Mandatory)][string[]]$Pathspec
    )

    $list = Read-RuleIdList -Path $ListPath

    $declared = Invoke-RuleIdGrep -Root $Root -Pathspec $Pathspec -What 'rule-id declarations' `
        -GrepArgs @('-o', '-E', '-e', $script:DeclarePattern)
    $cited = Invoke-RuleIdGrep -Root $Root -Pathspec $Pathspec -What 'rule-id citations' `
        -GrepArgs @('-o', '-E', '-e', $script:CitePattern)
    $opened = Invoke-RuleIdGrep -Root $Root -Pathspec $Pathspec -What 'rule-id openings' `
        -GrepArgs @('-F', '-e', $script:DeclareOpen, '-e', $script:CiteOpen)

    $problems = [System.Collections.Generic.List[object]]::new()
    function Add-Problem($File, $Line, $Id, $Kind, $Message) {
        $problems.Add([pscustomobject]@{ File = $File; Line = $Line; Id = $Id; Kind = $Kind; Message = $Message })
    }

    # Each whole form found, keyed by file and line, for the malformed count below.
    $whole = @{}
    $first = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
    foreach ($d in $declared) {
        $whole["$($d.File):$($d.Line)"] = 1 + [int]$whole["$($d.File):$($d.Line)"]
        $id = $d.Text.Substring($script:DeclareOpen.Length, $d.Text.Length - $script:DeclareOpen.Length - ' -->'.Length)
        if ($first.ContainsKey($id)) {
            $at = $first[$id]
            Add-Problem $d.File $d.Line $id 'Duplicate' "$($d.File):$($d.Line): rule id '$id' is declared again - it is already declared at $($at.File):$($at.Line)"
            continue
        }
        $first[$id] = $d
        $owner = $id.Split('/')[0]
        $ownerFile = Get-RuleIdOwnerFile -Owner $owner
        if ($d.File -cne $ownerFile) {
            Add-Problem $d.File $d.Line $id 'WrongOwner' "$($d.File):$($d.Line): rule id '$id' names the owner '$owner', so it is declared in '$ownerFile' and nowhere else"
        }
    }

    $citedFrom = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
    foreach ($c in $cited) {
        $whole["$($c.File):$($c.Line)"] = 1 + [int]$whole["$($c.File):$($c.Line)"]
        $id = $c.Text.Substring($script:CiteOpen.Length, $c.Text.Length - $script:CiteOpen.Length - 1)
        if (-not $first.ContainsKey($id)) {
            Add-Problem $c.File $c.Line $id 'Undeclared' "$($c.File):$($c.Line): [rule:$id] cites a rule id nobody declares"
            continue
        }
        if ($c.File -cne $first[$id].File) { $citedFrom[$id] = $c }
    }

    $allowed = @($list.Uncited | ForEach-Object Id)
    foreach ($id in $first.Keys) {
        $d = $first[$id]
        if ($citedFrom.ContainsKey($id)) {
            if ($allowed -ccontains $id) {
                Add-Problem $d.File $d.Line $id 'StaleList' "$($d.File):$($d.Line): rule id '$id' is listed as uncited in '$ListPath' but is cited now - take it off the list"
            }
            continue
        }
        if ($allowed -ccontains $id) { continue }
        Add-Problem $d.File $d.Line $id 'Uncited' "$($d.File):$($d.Line): rule id '$id' is declared but nothing outside its own file cites it - cite it, drop the declaration, or list it with a reason in '$ListPath'"
    }
    foreach ($id in $allowed) {
        if (-not $first.ContainsKey($id)) {
            Add-Problem $ListPath 0 $id 'StaleList' "${ListPath}: rule id '$id' is listed as uncited but nothing declares it - take it off the list"
        }
    }

    foreach ($o in $opened) {
        $masked = $o.Text
        foreach ($allow in @($list.NotAnId | Where-Object { $_.File -ceq $o.File })) {
            $masked = $masked.Replace($allow.Phrase, ' ' * $allow.Phrase.Length)
        }
        $openings = 0
        foreach ($open in $script:DeclareOpen, $script:CiteOpen) {
            $at = $masked.IndexOf($open, [System.StringComparison]::Ordinal)
            while ($at -ge 0) {
                $openings++
                $at = $masked.IndexOf($open, $at + $open.Length, [System.StringComparison]::Ordinal)
            }
        }
        if ($openings -gt [int]$whole["$($o.File):$($o.Line)"]) {
            Add-Problem $o.File $o.Line $null 'Malformed' "$($o.File):$($o.Line): '$($script:CiteOpen)' or '$($script:DeclareOpen)' opens something that is not a whole rule id - '<!-- rule:owner/name -->' or '[rule:owner/name]', lower-case letters, digits and '-' only: $($o.Text.Trim())"
        }
    }

    return , $problems
}

<#
.SYNOPSIS
Throws one message listing every rule-id problem found, or returns nothing when the tree is clean.
#>
function Assert-RuleIdsResolve {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ListPath,
        [Parameter(Mandatory)][string[]]$Pathspec
    )

    $found = Find-RuleIdProblem -Root $Root -ListPath $ListPath -Pathspec $Pathspec
    if ($found.Count) {
        throw ("$($found.Count) rule-id problem(s) in tracked Markdown - statute's 'Rule ids' section " +
               "says how a rule is declared and cited:" + [Environment]::NewLine +
               (($found | ForEach-Object Message) -join [Environment]::NewLine))
    }
}

Export-ModuleMember -Function Read-RuleIdList, Find-RuleIdProblem, Assert-RuleIdsResolve
