#Requires -Version 7.0
Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'Paths.psm1') -Force

# The startup-memory budget: what the two curated memory files cost, against what is allowed.
#
# `data\king.md` holds how the King works and what the Hand has observed they prefer.
# `data\learnings.md` holds operational facts and gotchas kingshand has hit. Both are created
# lazily by the `stow` skill and are ABSENT until there is something to store - absence is a
# normal, meaningful result here, never an error, so a report over a fresh kingshand is a report
# of zero rather than a throw.
#
# `instructions.md` at the repo root is deliberately NOT accounted here. These two files are what
# the Hand learned and `stow` prunes them against this budget; `instructions.md` is what the King
# stated, nothing may rewrite it, and budgeting a file nobody is allowed to curate would only
# create pressure to break that rule.
#
# The token figure is an ESTIMATE: ceil(UTF-8 bytes / 3), ported byte-for-byte from firstmate's
# formula. It is a deliberately conservative, dependency-free, portable approximation for ordinary
# prose - not a real tokenizer, and it makes no claim to match any provider's accounting. Curation
# decisions want a stable number that never flatters the total, which this gives; anything needing
# exactness must ask the provider.
#
# The budget itself is read from `config\startup-memory-budget`, which must hold exactly one
# positive base-10 integer. Only ABSENCE means the default. A file that exists but does not parse
# is an actionable error, because a typo silently read as 7500 would let memory grow past a limit
# the user thought they had set.

$script:BudgetFileName = 'startup-memory-budget'
$script:DefaultBudget  = 7500
$script:MemoryFiles    = @('king.md', 'learnings.md')
$script:Estimator      = 'ceil(UTF-8 bytes / 3) - a conservative portable approximation, not a tokenizer'

function Get-DefaultBudgetPath {
    Join-Path (Get-KingshandHome) "config\$script:BudgetFileName"
}

function Get-DefaultMemoryDataPath {
    Join-Path (Get-KingshandHome) 'data'
}

# The one validated effective budget. An absent file is the materialized default; anything present
# and malformed throws a message naming the path, what was found, and what is required.
function Get-MemoryBudget {
    [CmdletBinding()]
    param([string]$BudgetPath = (Get-DefaultBudgetPath))

    if (-not (Test-Path -LiteralPath $BudgetPath)) { return $script:DefaultBudget }
    if (Test-Path -LiteralPath $BudgetPath -PathType Container) {
        throw "Startup-memory budget at $BudgetPath is a directory, not a file. It must hold exactly one positive whole number, such as 7500."
    }

    # Normalised so a CRLF file written on Windows reads identically to an LF one, then stripped of
    # a single trailing newline only - any newline left after that means more than one line.
    $raw     = [System.IO.File]::ReadAllText($BudgetPath) -replace "`r`n", "`n"
    $content = $raw -replace "`n$", ''

    if ($content.Contains("`n")) {
        throw "Startup-memory budget at $BudgetPath has more than one line. It must hold exactly one positive whole number, such as 7500."
    }
    if ($content -notmatch '^[1-9][0-9]*$') {
        $shown = if ($content.Trim()) { "'$content'" } else { 'nothing' }
        throw "Startup-memory budget at $BudgetPath reads $shown. It must hold exactly one positive whole number in base 10, such as 7500 - no sign, no separators, no leading zero."
    }

    $parsed = 0L
    if (-not [long]::TryParse($content, [ref]$parsed)) {
        throw "Startup-memory budget at $BudgetPath reads '$content', which is too large to be a budget. Use a positive whole number such as 7500."
    }
    $parsed
}

# ceil(UTF-8 bytes / 3) for one file. An absent file measures zero and reports itself absent,
# because that is the ordinary state of a memory file nothing has been stowed into yet.
function Measure-MemoryFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $result = @{
        path    = $Path
        name    = Split-Path -Leaf $Path
        present = $false
        bytes   = 0L
        tokens  = 0L
    }

    if (-not (Test-Path -LiteralPath $Path)) { return $result }
    if (Test-Path -LiteralPath $Path -PathType Container) {
        throw "Memory file $Path is a directory, not a file. It must be an ordinary file or absent."
    }

    $bytes = (Get-Item -LiteralPath $Path).Length
    $result.present = $true
    $result.bytes   = $bytes
    $result.tokens  = [long][Math]::Ceiling($bytes / 3.0)
    $result
}

# Both memory files accounted against the effective budget: each file's estimate, the total, the
# budget, and whether the total is over it. Either or both files being absent is normal and never
# throws; a malformed budget still does, because there is no honest total without one.
function Get-MemoryReport {
    [CmdletBinding()]
    param(
        [string]$DataPath   = (Get-DefaultMemoryDataPath),
        [string]$BudgetPath = (Get-DefaultBudgetPath)
    )

    $budget = Get-MemoryBudget -BudgetPath $BudgetPath
    $files  = foreach ($name in $script:MemoryFiles) {
        Measure-MemoryFile -Path (Join-Path $DataPath $name)
    }

    $total = 0L
    foreach ($f in $files) { $total += $f.tokens }

    @{
        estimator  = $script:Estimator
        budget     = $budget
        # @() survives the single-element unwrap that would otherwise hand a caller the bare
        # hashtable and make .Count report its key count instead of 1.
        files      = @($files)
        total      = $total
        overBudget = ($total -gt $budget)
    }
}

Export-ModuleMember -Function Get-MemoryBudget, Measure-MemoryFile, Get-MemoryReport
