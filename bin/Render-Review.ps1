#Requires -Version 7.0
<#
.SYNOPSIS
  Renders structured review data to a self-contained HTML page for lavish.
.DESCRIPTION
  Every item carries data-item-id so a lavish annotation anchors to one requirement or file
  rather than to the whole document. Shared by the crew layer and story coverage.

  Sections are hashtables of the shape:
    @{ heading = 'Requirements'; items = @(
         @{ id='R-001'; text='...'; detail='...'; badges=@('explicit'); flag=$false } ) }
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Title,
    [string]$Subtitle = '',
    [Parameter(Mandatory)][AllowEmptyCollection()][hashtable[]]$Sections,
    [Parameter(Mandatory)][string]$OutputPath
)

$ErrorActionPreference = 'Stop'

function ConvertTo-HtmlText {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    [System.Net.WebUtility]::HtmlEncode($Text)
}

$css = Get-Content "$PSScriptRoot\assets\review.css" -Raw

$sb = [System.Text.StringBuilder]::new()
$null = $sb.AppendLine('<!doctype html>')
$null = $sb.AppendLine('<html lang="en"><head><meta charset="utf-8">')
$null = $sb.AppendLine('<meta name="viewport" content="width=device-width,initial-scale=1">')
$null = $sb.AppendLine("<title>$(ConvertTo-HtmlText $Title)</title>")
$null = $sb.AppendLine("<style>$css</style>")
$null = $sb.AppendLine('</head><body>')

$null = $sb.AppendLine('<header>')
$null = $sb.AppendLine("<h1>$(ConvertTo-HtmlText $Title)</h1>")
if ($Subtitle) { $null = $sb.AppendLine("<div class=""sub"">$(ConvertTo-HtmlText $Subtitle)</div>") }
$null = $sb.AppendLine('</header>')

foreach ($section in $Sections) {
    $items = @($section.items)
    if ($items.Count -eq 0) { continue }

    $null = $sb.AppendLine("<h2>$(ConvertTo-HtmlText $section.heading)</h2>")

    foreach ($item in $items) {
        $cls = if ($item.flag) { ' class="flagged"' } else { '' }
        $null = $sb.AppendLine("<article id=""item-$($item.id)"" data-item-id=""$($item.id)""$cls>")
        $null = $sb.AppendLine("<div class=""iid"">$(ConvertTo-HtmlText $item.id)</div>")
        $null = $sb.AppendLine("<div class=""text"">$(ConvertTo-HtmlText $item.text)</div>")
        if ($item.detail) { $null = $sb.AppendLine("<div class=""detail"">$(ConvertTo-HtmlText $item.detail)</div>") }

        $badges = @($item.badges)
        if ($badges.Count -gt 0 -or $item.flag) {
            $null = $sb.AppendLine('<div class="badges">')
            foreach ($b in $badges) { $null = $sb.AppendLine("<span class=""badge"">$(ConvertTo-HtmlText $b)</span>") }
            if ($item.flag) { $null = $sb.AppendLine('<span class="badge">flagged</span>') }
            $null = $sb.AppendLine('</div>')
        }

        $null = $sb.AppendLine('</article>')
    }
}

$null = $sb.AppendLine('</body></html>')

$dir = Split-Path -Parent $OutputPath
if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
$sb.ToString() | Set-Content -Path $OutputPath -Encoding utf8

Write-Host "Rendered to $OutputPath"
