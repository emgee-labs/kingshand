#Requires -Version 7.0
Set-StrictMode -Version Latest

# The work item half of closing out a pull request: attach the pull request to its Azure DevOps work
# item as a link, and move the item to its in-review state. The `writ` skill owns when this runs and
# what the King is asked first; this module owns every call that reaches the tracker, so nothing
# above it hand-builds a request body, an auth header or a cache write.
#
# Four things are enforced here rather than left to whoever calls it, because each is a write that
# reaches a server and none can be taken back by a sentence:
#
#   - A work item whose type the configuration does not name is refused before any write, by both
#     write functions, with the type named in the refusal.
#   - The state only ever moves from a state the configuration says it starts from. An item already
#     in or past the in-review state is left exactly as it is, and so is one in a state the
#     configuration does not mention at all - that could be backward, so it is never guessed at.
#     The move carries a `test` on the revision it was planned against, so an item someone changed
#     in between is refused by the tracker rather than overwritten.
#   - Nothing here posts a comment. There is no function that could.
#   - A write function's outcome says what was sent, never that it worked. Test-WorkItemReview
#     re-reads the item and is the only thing that says the link and the state are both there.
#
# Configuration is read from `config\ado.json` under the root the caller passes - the organization
# and project `muster` already reads, plus the `review` block the `writ` skill documents. Nothing in
# this file names a real organization, project, work item type or state: every one comes from that
# file, and a file that does not say is a refusal naming what is missing, never a default.
#
# The token is ADO_MCP_AUTH_TOKEN, the one the Azure DevOps MCP server already reads, so a machine
# set up for that is set up for this. It is read at the moment of each call and never stored.
#
# The repository GUID cache is `config\ado-repo-guids.json`, keyed `owner/repo`. It is the one file
# this module writes, and it refuses to write over a file that is not its own shape. A GUID reaches
# it only from Find-RepoGuid's discovery, never typed in, because a wrong one links a pull request
# nobody can open.
#
# Takes the root as a parameter and imports nothing, the same way bin\Version.psm1 does.

$script:GuidPattern = '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}'

# A GitHub pull request URL and the artifact link the tracker stores for one are both closed shapes,
# so each is matched whole and anchored rather than searched for inside free text.
$script:PullRequestUrlPattern =
    '\Ahttps://github\.com/([A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)/([A-Za-z0-9._-]+)/pull/([1-9][0-9]*)/?\z'
$script:ArtifactUrlPattern =
    "\Avstfs:///GitHub/PullRequest/($($script:GuidPattern))%2F([1-9][0-9]*)\z"

# ---------------------------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------------------------

function Get-WorkItemConfigPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)

    Join-Path $Root 'config' 'ado.json'
}

# A list of non-empty strings out of the parsed file, or a throw naming the key. A single string
# where a list belongs is refused rather than wrapped, because it is as likely to be a typo as a
# list of one.
function Get-ConfigStringList {
    param(
        [Parameter(Mandatory)][hashtable]$Block,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Source
    )

    if (-not $Block.ContainsKey($Key)) { throw "$Source has no review.$Key." }
    $value = $Block[$Key]
    if ($value -isnot [array]) { throw "$Source review.$Key must be a list of names." }
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($v in $value) {
        if ($v -isnot [string] -or [string]::IsNullOrWhiteSpace($v)) {
            throw "$Source review.$Key holds an entry that is not a name."
        }
        $out.Add($v.Trim())
    }
    if ($out.Count -eq 0) { throw "$Source review.$Key is empty." }
    , $out
}

# The organization, the project and the review block, validated together. Every failure names the
# file and what it lacks, and none returns a partial answer.
function Get-WorkItemConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)

    $path   = Get-WorkItemConfigPath -Root $Root
    $source = "config\ado.json at $path"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "There is no $source, so the organization and project are not known."
    }
    $data = $null
    try {
        $data = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable
    } catch {
        throw "The $source could not be read as JSON - $($_.Exception.Message)"
    }
    if ($data -isnot [hashtable]) { throw "The $source does not hold a JSON object." }

    foreach ($key in 'organization', 'project') {
        if (-not $data.ContainsKey($key) -or $data[$key] -isnot [string] -or
            [string]::IsNullOrWhiteSpace($data[$key])) {
            throw "The $source has no $key."
        }
    }
    if (-not $data.ContainsKey('review') -or $data['review'] -isnot [hashtable]) {
        throw ("The $source has no review block, so which work item types and states the " +
               'in-review move applies to is not known.')
    }
    $review = $data['review']

    $types       = Get-ConfigStringList -Block $review -Key 'types'       -Source "The $source"
    $moveFrom    = Get-ConfigStringList -Block $review -Key 'moveFrom'    -Source "The $source"
    $alreadyDone = Get-ConfigStringList -Block $review -Key 'alreadyDone' -Source "The $source"
    if (-not $review.ContainsKey('target') -or $review['target'] -isnot [string] -or
        [string]::IsNullOrWhiteSpace($review['target'])) {
        throw "The $source has no review.target."
    }
    $target = $review['target'].Trim()

    # The target has to count as already done, or an item sitting in it would be moved into it
    # again - the re-applied state this whole block exists to prevent.
    if ($target -notin $alreadyDone) {
        throw "The $source review.alreadyDone must include review.target ('$target')."
    }
    $overlap = @($moveFrom | Where-Object { $_ -in $alreadyDone })
    if ($overlap.Count -gt 0) {
        throw ("The $source names '$($overlap -join "', '")' in both review.moveFrom and " +
               'review.alreadyDone, so whether to move it is not settled.')
    }

    [pscustomobject]@{
        organization = $data['organization'].Trim()
        project      = $data['project'].Trim()
        types        = $types
        moveFrom     = $moveFrom
        target       = $target
        alreadyDone  = $alreadyDone
    }
}

# ---------------------------------------------------------------------------------------------
# The decision, with no I/O
# ---------------------------------------------------------------------------------------------

# What the in-review move should do for an item of this type in this state. One of:
#   refuse       - the type is not one the configuration names; nothing is written at all
#   move         - the state is one the move starts from
#   already      - the state is the target or past it; the state call is skipped
#   unrecognised - the state is in neither list, so it is left alone rather than guessed at
#   unreadable   - the type or the state came back empty
function Get-WorkItemReviewPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Config,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Type,
        [Parameter(Mandatory)][AllowEmptyString()][string]$State
    )

    if ([string]::IsNullOrWhiteSpace($Type) -or [string]::IsNullOrWhiteSpace($State)) {
        return [pscustomobject]@{
            action = 'unreadable'; target = $null
            reason = 'The work item''s type or state could not be read, so nothing is written.'
        }
    }
    if ($Type -notin $Config.types) {
        return [pscustomobject]@{
            action = 'refuse'; target = $null
            reason = ("Only $($Config.types -join ', ') items are moved to in-review - this one " +
                      "is a $Type.")
        }
    }
    if ($State -in $Config.alreadyDone) {
        return [pscustomobject]@{
            action = 'already'; target = $null
            reason = "It is already $State, so its state is left as it is."
        }
    }
    if ($State -in $Config.moveFrom) {
        return [pscustomobject]@{
            action = 'move'; target = $Config.target
            reason = "$State moves to $($Config.target)."
        }
    }
    [pscustomobject]@{
        action = 'unrecognised'; target = $null
        reason = ("Its state '$State' is neither one the move starts from nor one past it, so it is " +
                  'left alone.')
    }
}

# ---------------------------------------------------------------------------------------------
# The two closed URL shapes
# ---------------------------------------------------------------------------------------------

# owner, repo and number out of a GitHub pull request URL, or a throw quoting what was given.
function ConvertFrom-PullRequestUrl {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Url)

    $m = [regex]::Match($Url.Trim(), $script:PullRequestUrlPattern)
    if (-not $m.Success) {
        throw "'$Url' is not a GitHub pull request URL of the form https://github.com/<owner>/<repo>/pull/<number>."
    }
    [pscustomobject]@{
        owner  = $m.Groups[1].Value
        repo   = $m.Groups[2].Value
        key    = "$($m.Groups[1].Value)/$($m.Groups[2].Value)"
        number = [int]$m.Groups[3].Value
    }
}

# guid and number out of a pull request artifact link, or $null for any other link - a work item
# carries many relations, and a link of another kind is not an error.
function ConvertFrom-PullRequestArtifactUrl {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Url)

    $m = [regex]::Match($Url, $script:ArtifactUrlPattern, 'IgnoreCase')
    if (-not $m.Success) { return $null }
    [pscustomobject]@{ guid = $m.Groups[1].Value.ToLowerInvariant(); number = [int]$m.Groups[2].Value }
}

# The artifact link URL for one pull request. Built here and nowhere else.
function Get-PullRequestArtifactUrl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoGuid,
        [Parameter(Mandatory)][int]$PrNumber
    )

    if ($RepoGuid -notmatch "\A$($script:GuidPattern)\z") { throw "'$RepoGuid' is not a GUID." }
    "vstfs:///GitHub/PullRequest/$($RepoGuid.ToLowerInvariant())%2F$PrNumber"
}

# The JSON-patch body that adds one pull request link. Returned as the exact string sent, so it can
# be inspected without sending it.
function New-PullRequestLinkBody {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoGuid,
        [Parameter(Mandatory)][int]$PrNumber
    )

    $op = @{
        op    = 'add'
        path  = '/relations/-'
        value = @{
            rel        = 'ArtifactLink'
            url        = (Get-PullRequestArtifactUrl -RepoGuid $RepoGuid -PrNumber $PrNumber)
            attributes = @{ name = 'GitHub Pull Request' }
        }
    }
    ConvertTo-Json -InputObject @($op) -Depth 6 -Compress
}

# The JSON-patch body that moves the state, guarded by the revision it was planned against.
function New-WorkItemStateBody {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$Rev,
        [Parameter(Mandatory)][string]$State
    )

    $ops = @(
        @{ op = 'test'; path = '/rev'; value = $Rev }
        @{ op = 'add'; path = '/fields/System.State'; value = $State }
    )
    ConvertTo-Json -InputObject $ops -Depth 4 -Compress
}

# ---------------------------------------------------------------------------------------------
# The repository GUID cache
# ---------------------------------------------------------------------------------------------

function Get-RepoGuidCachePath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)

    Join-Path $Root 'config' 'ado-repo-guids.json'
}

# The cache as a hashtable. Absent is empty. Anything that is not an object of `owner/repo` keys to
# GUID strings is not this module's file and is refused, so a later write cannot replace it.
function Read-RepoGuidCache {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @{} }
    $data = $null
    try {
        $data = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable
    } catch {
        throw "The repository GUID cache at $Path could not be read as JSON - $($_.Exception.Message)"
    }
    if ($null -eq $data) { return @{} }
    if ($data -isnot [hashtable]) {
        throw "The file at $Path is not a repository GUID cache, so it is left alone."
    }
    foreach ($k in @($data.Keys)) {
        if ($k -notmatch '\A[^/\s]+/[^/\s]+\z' -or $data[$k] -isnot [string] -or
            $data[$k] -notmatch "\A$($script:GuidPattern)\z") {
            throw "The file at $Path is not a repository GUID cache, so it is left alone."
        }
    }
    $data
}

# The cached GUID for owner/repo, or $null when none is cached.
function Get-RepoGuid {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$RepoKey
    )

    $cache = Read-RepoGuidCache -Path (Get-RepoGuidCachePath -Root $Root)
    if ($cache.ContainsKey($RepoKey)) { return $cache[$RepoKey] }
    $null
}

# Records a discovered GUID. A repository already cached under a different GUID is refused rather
# than overwritten - two answers for one repository means one of them is wrong, and the cache cannot
# say which.
function Save-RepoGuid {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$RepoKey,
        [Parameter(Mandatory)][string]$Guid
    )

    if ($RepoKey -notmatch '\A[^/\s]+/[^/\s]+\z') { throw "'$RepoKey' is not an owner/repo key." }
    if ($Guid -notmatch "\A$($script:GuidPattern)\z") { throw "'$Guid' is not a GUID." }
    $Guid = $Guid.ToLowerInvariant()

    $path  = Get-RepoGuidCachePath -Root $Root
    $cache = Read-RepoGuidCache -Path $path
    if ($cache.ContainsKey($RepoKey)) {
        if ($cache[$RepoKey] -eq $Guid) { return }
        throw ("$RepoKey is already cached as $($cache[$RepoKey]), not $Guid. The cache is left as " +
               'it is; settle which is right before linking.')
    }
    $cache[$RepoKey] = $Guid

    $dir = Split-Path $path -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $tmp = "$path.tmp"
    ($cache | ConvertTo-Json -Depth 2) | Set-Content -LiteralPath $tmp -Encoding utf8
    Move-Item -LiteralPath $tmp -Destination $path -Force
}

# ---------------------------------------------------------------------------------------------
# Calls that reach the tracker
# ---------------------------------------------------------------------------------------------

function Get-AdoHeaders {
    param([string]$ContentType = 'application/json')

    $pat = $env:ADO_MCP_AUTH_TOKEN
    if ([string]::IsNullOrWhiteSpace($pat)) {
        throw 'ADO_MCP_AUTH_TOKEN is not set, so the work item tracker cannot be reached.'
    }
    $b64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$pat"))
    @{ Authorization = "Basic $b64"; 'Content-Type' = $ContentType }
}

function Get-WorkItemApiUri {
    param(
        [Parameter(Mandatory)][pscustomobject]$Config,
        [Parameter(Mandatory)][int]$TicketId,
        [string]$Query = ''
    )

    $org  = [uri]::EscapeDataString($Config.organization)
    $proj = [uri]::EscapeDataString($Config.project)
    "https://dev.azure.com/$org/$proj/_apis/wit/workitems/$TicketId`?$($Query)api-version=7.1"
}

# The work item's page, for a reader to open when the re-check did not pass.
function Get-WorkItemWebUrl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Config,
        [Parameter(Mandatory)][int]$TicketId
    )

    $org  = [uri]::EscapeDataString($Config.organization)
    $proj = [uri]::EscapeDataString($Config.project)
    "https://dev.azure.com/$org/$proj/_workitems/edit/$TicketId"
}

function Get-OptionalProperty {
    param($Object, [Parameter(Mandatory)][string]$Name)

    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    $null
}

# The work item as this module needs it: type, state, title, revision, and every pull request
# linked to it. A response missing its fields reads as unreadable, never as an empty state.
function Get-WorkItemStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][int]$TicketId
    )

    $config  = Get-WorkItemConfig -Root $Root
    $headers = Get-AdoHeaders
    $uri     = Get-WorkItemApiUri -Config $config -TicketId $TicketId -Query '$expand=relations&'
    $resp    = $null
    try {
        $resp = Invoke-RestMethod -Method Get -Uri $uri -Headers $headers -ErrorAction Stop
    } catch {
        throw "Work item $TicketId could not be read - $($_.Exception.Message)"
    }

    $fields = Get-OptionalProperty $resp 'fields'
    $rev    = Get-OptionalProperty $resp 'rev'
    $type   = Get-OptionalProperty $fields 'System.WorkItemType'
    $state  = Get-OptionalProperty $fields 'System.State'
    if ($null -eq $fields -or $null -eq $rev) {
        throw "Work item $TicketId came back without its fields, so its type and state are not known."
    }

    $prs = [System.Collections.Generic.List[object]]::new()
    foreach ($rel in @(Get-OptionalProperty $resp 'relations')) {
        if ($null -eq $rel) { continue }
        if ((Get-OptionalProperty $rel 'rel') -ne 'ArtifactLink') { continue }
        $parsed = ConvertFrom-PullRequestArtifactUrl -Url "$(Get-OptionalProperty $rel 'url')"
        if ($parsed) { $prs.Add($parsed) }
    }

    [pscustomobject]@{
        id           = $TicketId
        rev          = [int]$rev
        type         = "$type"
        state        = "$state"
        title        = "$(Get-OptionalProperty $fields 'System.Title')"
        pullRequests = $prs
    }
}

function Test-HasPullRequest {
    param($Status, [string]$Guid, [int]$Number)

    if (-not $Guid) { return $false }
    foreach ($p in $Status.pullRequests) {
        if ($p.guid -eq $Guid.ToLowerInvariant() -and $p.number -eq $Number) { return $true }
    }
    $false
}

# Attaches the pull request as a link. Outcomes:
#   link-sent       - the write was sent; Test-WorkItemReview says whether it took
#   already-linked  - the item already carries this exact link; nothing was written
#   guid-not-cached - the repository's GUID is not known; run Find-RepoGuid, then call again with
#                     -DiscoveredGuid
#   refused         - the type is not one the configuration names, or could not be read
function Add-PullRequestLink {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][int]$TicketId,
        [Parameter(Mandatory)][string]$PullRequestUrl,
        [string]$DiscoveredGuid = ''
    )

    $pr     = ConvertFrom-PullRequestUrl -Url $PullRequestUrl
    $config = Get-WorkItemConfig -Root $Root
    $status = Get-WorkItemStatus -Root $Root -TicketId $TicketId
    $plan   = Get-WorkItemReviewPlan -Config $config -Type $status.type -State $status.state
    if ($plan.action -in 'refuse', 'unreadable') {
        return [pscustomobject]@{ outcome = 'refused'; reason = $plan.reason; guid = $null }
    }

    if ($DiscoveredGuid) { Save-RepoGuid -Root $Root -RepoKey $pr.key -Guid $DiscoveredGuid }
    $guid = Get-RepoGuid -Root $Root -RepoKey $pr.key
    if (-not $guid) {
        return [pscustomobject]@{
            outcome = 'guid-not-cached'; guid = $null
            reason  = "No GUID is cached for $($pr.key)."
        }
    }
    if (Test-HasPullRequest -Status $status -Guid $guid -Number $pr.number) {
        return [pscustomobject]@{
            outcome = 'already-linked'; guid = $guid
            reason  = "Work item $TicketId already links $($pr.key)#$($pr.number)."
        }
    }

    $headers = Get-AdoHeaders -ContentType 'application/json-patch+json'
    $uri     = Get-WorkItemApiUri -Config $config -TicketId $TicketId
    $body    = New-PullRequestLinkBody -RepoGuid $guid -PrNumber $pr.number
    try {
        Invoke-RestMethod -Method Patch -Uri $uri -Headers $headers -Body $body -ErrorAction Stop |
            Out-Null
    } catch {
        throw "Linking $($pr.key)#$($pr.number) to work item $TicketId failed - $($_.Exception.Message)"
    }
    [pscustomobject]@{
        outcome = 'link-sent'; guid = $guid
        reason  = "Sent the link for $($pr.key)#$($pr.number) to work item $TicketId."
    }
}

# Moves the item to the in-review state, only where the plan says move. Outcomes are the plan's
# own action words - refuse, already, unrecognised, unreadable - for every case where nothing was
# written, and move-sent where the write was sent.
function Set-WorkItemInReview {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][int]$TicketId
    )

    $config = Get-WorkItemConfig -Root $Root
    $status = Get-WorkItemStatus -Root $Root -TicketId $TicketId
    $plan   = Get-WorkItemReviewPlan -Config $config -Type $status.type -State $status.state
    if ($plan.action -ne 'move') {
        return [pscustomobject]@{ outcome = $plan.action; from = $status.state; reason = $plan.reason }
    }

    $headers = Get-AdoHeaders -ContentType 'application/json-patch+json'
    $uri     = Get-WorkItemApiUri -Config $config -TicketId $TicketId
    $body    = New-WorkItemStateBody -Rev $status.rev -State $plan.target
    try {
        Invoke-RestMethod -Method Patch -Uri $uri -Headers $headers -Body $body -ErrorAction Stop |
            Out-Null
    } catch {
        throw "Moving work item $TicketId to $($plan.target) failed - $($_.Exception.Message)"
    }
    [pscustomobject]@{ outcome = 'move-sent'; from = $status.state; reason = $plan.reason }
}

# The re-check that is the only meaning of "verified": re-read the item and confirm both that the
# pull request is linked and that the state is the target or one already past it. With a pull
# request URL, that exact pull request must be linked; without one - the item already linked a pull
# request nobody named - any pull request link counts.
function Test-WorkItemReview {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][int]$TicketId,
        [string]$PullRequestUrl = ''
    )

    $config = Get-WorkItemConfig -Root $Root
    $status = Get-WorkItemStatus -Root $Root -TicketId $TicketId
    if ($PullRequestUrl) {
        $pr     = ConvertFrom-PullRequestUrl -Url $PullRequestUrl
        $guid   = Get-RepoGuid -Root $Root -RepoKey $pr.key
        $linked = Test-HasPullRequest -Status $status -Guid $guid -Number $pr.number
    } else {
        $linked = @($status.pullRequests).Count -gt 0
    }
    $stateOk = $status.state -in $config.alreadyDone

    [pscustomobject]@{
        verified = ($linked -and $stateOk)
        linked   = $linked
        stateOk  = $stateOk
        state    = $status.state
        type     = $status.type
        title    = $status.title
        url      = (Get-WorkItemWebUrl -Config $config -TicketId $TicketId)
    }
}

# Discovers a repository's GUID from work items that already link one of its pull requests. Each
# candidate is a work item id and the number of a pull request in the same repository that it is
# known to carry. A candidate counts only where exactly one linked GUID carries that number; the
# candidates that count must all agree, and a disagreement throws rather than picking one.
#
# Returns guid ($null where none was found), matched, and unreadable - the candidates that could
# not be read at all, so "nothing has ever linked this repository" is said only when nothing failed.
function Find-RepoGuid {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Candidates
    )

    $found      = [System.Collections.Generic.List[string]]::new()
    $unreadable = 0
    foreach ($c in $Candidates) {
        $status = $null
        try {
            $status = Get-WorkItemStatus -Root $Root -TicketId ([int](Get-OptionalProperty $c 'ticketId'))
        } catch {
            $unreadable++
            continue
        }
        $number = [int](Get-OptionalProperty $c 'prNumber')
        $guids  = @($status.pullRequests | Where-Object { $_.number -eq $number } |
                    ForEach-Object { $_.guid } | Select-Object -Unique)
        if ($guids.Count -eq 1) { $found.Add($guids[0]) }
    }

    $distinct = @($found | Select-Object -Unique)
    if ($distinct.Count -gt 1) {
        throw "Work items disagree about this repository's GUID: $($distinct -join ', ')."
    }
    [pscustomobject]@{
        guid       = if ($distinct.Count -eq 1) { $distinct[0] } else { $null }
        matched    = $found.Count
        unreadable = $unreadable
    }
}

Export-ModuleMember -Function Get-WorkItemConfigPath, Get-WorkItemConfig, Get-WorkItemReviewPlan,
                              ConvertFrom-PullRequestUrl, ConvertFrom-PullRequestArtifactUrl,
                              Get-PullRequestArtifactUrl, New-PullRequestLinkBody,
                              New-WorkItemStateBody, Get-RepoGuidCachePath, Get-RepoGuid,
                              Save-RepoGuid, Get-WorkItemWebUrl, Get-WorkItemStatus,
                              Add-PullRequestLink, Set-WorkItemInReview, Test-WorkItemReview,
                              Find-RepoGuid
