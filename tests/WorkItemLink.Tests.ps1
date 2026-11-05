#Requires -Version 7.0
Set-StrictMode -Version Latest

# bin\WorkItemLink.psm1 is every call that reaches the work item tracker when a pull request is
# attached to its work item and the item is moved to in-review. Each settled behaviour is a write
# that cannot be taken back, so each is tested here as a write that did or did not happen: the
# tracker is a mock, and what matters is whether it was called and with what.
#
# Nothing here reaches a real tracker. Invoke-RestMethod is mocked inside the module for every
# test, and the token is a fake one set for the run and put back afterwards.

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $script:Root 'bin\WorkItemLink.psm1') -Force

    $script:SavedToken = $env:ADO_MCP_AUTH_TOKEN
    $env:ADO_MCP_AUTH_TOKEN = 'fake-token-for-tests'

    $script:Guid  = '0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d'
    $script:Other = 'ffffffff-1111-4222-8333-444444444444'
    $script:PrUrl = 'https://github.com/acme/acme-api/pull/42'

    function New-Home {
        param([Parameter(Mandatory)][string]$Name, [hashtable]$Review, [switch]$NoReview)
        $d = Join-Path $TestDrive $Name
        New-Item -ItemType Directory -Force -Path (Join-Path $d 'config') | Out-Null
        $cfg = @{ organization = 'example-org'; project = 'Example Project' }
        if (-not $NoReview) {
            $cfg.review = if ($Review) { $Review } else {
                @{
                    types       = @('Task', 'Bug')
                    moveFrom    = @('New', 'Active')
                    target      = 'In Review'
                    alreadyDone = @('In Review', 'Resolved', 'Closed')
                }
            }
        }
        $cfg | ConvertTo-Json -Depth 4 |
            Set-Content -LiteralPath (Join-Path $d 'config' 'ado.json') -Encoding utf8
        $d
    }

    function New-Item-Response {
        param(
            [string]$Type = 'Task', [string]$State = 'Active', [int]$Rev = 7,
            [string[]]$Links = @()
        )
        $rels = @(foreach ($l in $Links) {
            [pscustomobject]@{ rel = 'ArtifactLink'; url = $l
                               attributes = [pscustomobject]@{ name = 'GitHub Pull Request' } }
        })
        [pscustomobject]@{
            id     = 101
            rev    = $Rev
            fields = [pscustomobject]@{
                'System.WorkItemType' = $Type; 'System.State' = $State; 'System.Title' = 'A title'
            }
            relations = $rels
        }
    }

    function Set-Cache {
        param([Parameter(Mandatory)][string]$Home_, [Parameter(Mandatory)][hashtable]$Map)
        $Map | ConvertTo-Json | Set-Content -LiteralPath (Get-RepoGuidCachePath -Root $Home_) -Encoding utf8
    }
}

AfterAll {
    $env:ADO_MCP_AUTH_TOKEN = $script:SavedToken
}

Describe 'the configuration names every type and state, and a gap is a refusal' {
    It 'reads the organization, project and review block' {
        $h = New-Home -Name 'cfg-ok'
        $c = Get-WorkItemConfig -Root $h
        $c.organization | Should -Be 'example-org'
        $c.target | Should -Be 'In Review'
        @($c.types) | Should -Be @('Task', 'Bug')
    }

    It 'says there is no config file rather than defaulting' {
        $d = Join-Path $TestDrive 'cfg-none'
        New-Item -ItemType Directory -Force -Path $d | Out-Null
        { Get-WorkItemConfig -Root $d } | Should -Throw -ExpectedMessage '*There is no config\ado.json*'
    }

    It 'says the review block is missing rather than inventing one' {
        $h = New-Home -Name 'cfg-noreview' -NoReview
        { Get-WorkItemConfig -Root $h } | Should -Throw -ExpectedMessage '*has no review block*'
    }

    It 'refuses a file that is not JSON' {
        $h = New-Home -Name 'cfg-bad'
        Set-Content -LiteralPath (Join-Path $h 'config' 'ado.json') -Value '{ not json' -Encoding utf8
        { Get-WorkItemConfig -Root $h } | Should -Throw -ExpectedMessage '*could not be read as JSON*'
    }

    It 'refuses a target that would not count as already done' {
        $h = New-Home -Name 'cfg-target' -Review @{
            types = @('Task'); moveFrom = @('New'); target = 'In Review'; alreadyDone = @('Closed') }
        { Get-WorkItemConfig -Root $h } | Should -Throw -ExpectedMessage '*must include review.target*'
    }

    It 'refuses a state named both as a start and as done' {
        $h = New-Home -Name 'cfg-overlap' -Review @{
            types = @('Task'); moveFrom = @('New', 'Closed'); target = 'In Review'
            alreadyDone = @('In Review', 'Closed') }
        { Get-WorkItemConfig -Root $h } | Should -Throw -ExpectedMessage '*in both review.moveFrom and*'
    }

    It 'refuses a single name where a list belongs' {
        $h = New-Home -Name 'cfg-scalar' -Review @{
            types = 'Task'; moveFrom = @('New'); target = 'In Review'; alreadyDone = @('In Review') }
        { Get-WorkItemConfig -Root $h } | Should -Throw -ExpectedMessage '*review.types must be a list*'
    }
}

Describe 'the plan never moves a state backward and never re-applies one' {
    BeforeAll { $script:Cfg = Get-WorkItemConfig -Root (New-Home -Name 'plan') }

    It 'refuses a type the configuration does not name, and names the type' {
        $p = Get-WorkItemReviewPlan -Config $script:Cfg -Type 'Feature' -State 'New'
        $p.action | Should -Be 'refuse'
        $p.reason | Should -BeLike '*is a Feature*'
    }

    It 'moves a starting state to the target' {
        $p = Get-WorkItemReviewPlan -Config $script:Cfg -Type 'Bug' -State 'Active'
        $p.action | Should -Be 'move'
        $p.target | Should -Be 'In Review'
    }

    It 'leaves the target itself alone' {
        (Get-WorkItemReviewPlan -Config $script:Cfg -Type 'Task' -State 'In Review').action |
            Should -Be 'already'
    }

    It 'leaves a state past the target alone' {
        (Get-WorkItemReviewPlan -Config $script:Cfg -Type 'Task' -State 'Closed').action |
            Should -Be 'already'
    }

    It 'leaves a state it does not know alone rather than guessing' {
        (Get-WorkItemReviewPlan -Config $script:Cfg -Type 'Task' -State 'Blocked').action |
            Should -Be 'unrecognised'
    }

    It 'reads an empty type or state as unreadable' {
        (Get-WorkItemReviewPlan -Config $script:Cfg -Type '' -State 'New').action |
            Should -Be 'unreadable'
        (Get-WorkItemReviewPlan -Config $script:Cfg -Type 'Task' -State '').action |
            Should -Be 'unreadable'
    }
}

Describe 'the two URL shapes are matched whole' {
    It 'reads owner, repo and number out of a pull request URL' {
        $p = ConvertFrom-PullRequestUrl -Url $script:PrUrl
        $p.key | Should -Be 'acme/acme-api'
        $p.number | Should -Be 42
    }

    It 'refuses anything that is not a pull request URL' {
        { ConvertFrom-PullRequestUrl -Url 'https://github.com/acme/acme-api/issues/42' } |
            Should -Throw -ExpectedMessage '*is not a GitHub pull request URL*'
        { ConvertFrom-PullRequestUrl -Url "$($script:PrUrl)/files" } |
            Should -Throw -ExpectedMessage '*is not a GitHub pull request URL*'
    }

    It 'reads a pull request artifact link and ignores every other link' {
        $a = ConvertFrom-PullRequestArtifactUrl -Url "vstfs:///GitHub/PullRequest/$($script:Guid)%2F42"
        $a.guid | Should -Be $script:Guid
        $a.number | Should -Be 42
        ConvertFrom-PullRequestArtifactUrl -Url 'vstfs:///Git/Commit/abc%2Fdef' | Should -BeNullOrEmpty
        ConvertFrom-PullRequestArtifactUrl -Url "vstfs:///GitHub/PullRequest/$($script:Guid)%2F42x" |
            Should -BeNullOrEmpty
    }

    It 'builds the link body the tracker expects' {
        $body = New-PullRequestLinkBody -RepoGuid $script:Guid -PrNumber 42 | ConvertFrom-Json
        @($body).Count | Should -Be 1
        $body[0].op | Should -Be 'add'
        $body[0].path | Should -Be '/relations/-'
        $body[0].value.rel | Should -Be 'ArtifactLink'
        $body[0].value.url | Should -Be "vstfs:///GitHub/PullRequest/$($script:Guid)%2F42"
        $body[0].value.attributes.name | Should -Be 'GitHub Pull Request'
    }

    It 'guards the state move with the revision it was planned against' {
        $body = New-WorkItemStateBody -Rev 7 -State 'In Review' | ConvertFrom-Json
        $body[0].op | Should -Be 'test'
        $body[0].path | Should -Be '/rev'
        $body[0].value | Should -Be 7
        $body[1].path | Should -Be '/fields/System.State'
        $body[1].value | Should -Be 'In Review'
    }
}

Describe 'the GUID cache writes only its own file' {
    It 'reads nothing cached from an absent file' {
        Get-RepoGuid -Root (New-Home -Name 'cache-none') -RepoKey 'acme/acme-api' | Should -BeNullOrEmpty
    }

    It 'saves a discovered GUID and reads it back' {
        $h = New-Home -Name 'cache-save'
        Save-RepoGuid -Root $h -RepoKey 'acme/acme-api' -Guid $script:Guid.ToUpperInvariant()
        Get-RepoGuid -Root $h -RepoKey 'acme/acme-api' | Should -Be $script:Guid
    }

    It 'refuses to write over a file that is not a GUID cache' {
        $h = New-Home -Name 'cache-foreign'
        $path = Get-RepoGuidCachePath -Root $h
        Set-Content -LiteralPath $path -Value '{"note": "somebody else''s file"}' -Encoding utf8
        { Save-RepoGuid -Root $h -RepoKey 'acme/acme-api' -Guid $script:Guid } |
            Should -Throw -ExpectedMessage '*is not a repository GUID cache*'
        (Get-Content -LiteralPath $path -Raw) | Should -BeLike '*somebody else*'
    }

    It 'refuses a second, different GUID for a repository already cached' {
        $h = New-Home -Name 'cache-conflict'
        Set-Cache -Home_ $h -Map @{ 'acme/acme-api' = $script:Guid }
        { Save-RepoGuid -Root $h -RepoKey 'acme/acme-api' -Guid $script:Other } |
            Should -Throw -ExpectedMessage '*is already cached as*'
        Get-RepoGuid -Root $h -RepoKey 'acme/acme-api' | Should -Be $script:Guid
    }

    It 'refuses a value that is not a GUID' {
        { Save-RepoGuid -Root (New-Home -Name 'cache-notguid') -RepoKey 'acme/acme-api' -Guid 'nope' } |
            Should -Throw -ExpectedMessage "*'nope' is not a GUID*"
    }
}

Describe 'reading a work item names its own failures' {
    It 'says the token is missing rather than calling the tracker' {
        $h = New-Home -Name 'read-notoken'
        Mock -ModuleName WorkItemLink Invoke-RestMethod { New-Item-Response }
        $saved = $env:ADO_MCP_AUTH_TOKEN
        try {
            $env:ADO_MCP_AUTH_TOKEN = ''
            { Get-WorkItemStatus -Root $h -TicketId 101 } |
                Should -Throw -ExpectedMessage '*ADO_MCP_AUTH_TOKEN is not set*'
        } finally { $env:ADO_MCP_AUTH_TOKEN = $saved }
        Should -Invoke -ModuleName WorkItemLink Invoke-RestMethod -Times 0 -Exactly
    }

    It 'says the item could not be read when the tracker refuses' {
        $h = New-Home -Name 'read-fail'
        Mock -ModuleName WorkItemLink Invoke-RestMethod { throw 'TF401232: not found' }
        { Get-WorkItemStatus -Root $h -TicketId 101 } |
            Should -Throw -ExpectedMessage '*Work item 101 could not be read*'
    }

    It 'reads a response with no fields as unreadable, never as an empty state' {
        $h = New-Home -Name 'read-nofields'
        Mock -ModuleName WorkItemLink Invoke-RestMethod { [pscustomobject]@{ id = 101 } }
        { Get-WorkItemStatus -Root $h -TicketId 101 } |
            Should -Throw -ExpectedMessage '*came back without its fields*'
    }

    It 'lists only pull request links among the relations' {
        $h = New-Home -Name 'read-links'
        Mock -ModuleName WorkItemLink Invoke-RestMethod {
            New-Item-Response -Links @("vstfs:///GitHub/PullRequest/$($script:Guid)%2F42",
                                       'vstfs:///GitHub/Commit/abc%2Fdef')
        }
        $s = Get-WorkItemStatus -Root $h -TicketId 101
        $s.pullRequests.Count | Should -Be 1
        $s.pullRequests[0].number | Should -Be 42
    }
}

Describe 'linking refuses before any write, and never writes a link twice' {
    It 'refuses a type the configuration does not name, with no write at all' {
        $h = New-Home -Name 'link-refuse'
        Set-Cache -Home_ $h -Map @{ 'acme/acme-api' = $script:Guid }
        Mock -ModuleName WorkItemLink Invoke-RestMethod { New-Item-Response -Type 'Epic' } `
            -ParameterFilter { $Method -eq 'Get' }
        Mock -ModuleName WorkItemLink Invoke-RestMethod { } -ParameterFilter { $Method -eq 'Patch' }
        $r = Add-PullRequestLink -Root $h -TicketId 101 -PullRequestUrl $script:PrUrl
        $r.outcome | Should -Be 'refused'
        $r.reason | Should -BeLike '*is a Epic*'
        Should -Invoke -ModuleName WorkItemLink Invoke-RestMethod -Times 0 -Exactly `
            -ParameterFilter { $Method -eq 'Patch' }
    }

    It 'says the GUID is not cached rather than writing anything' {
        $h = New-Home -Name 'link-noguid'
        Mock -ModuleName WorkItemLink Invoke-RestMethod { New-Item-Response } `
            -ParameterFilter { $Method -eq 'Get' }
        Mock -ModuleName WorkItemLink Invoke-RestMethod { } -ParameterFilter { $Method -eq 'Patch' }
        (Add-PullRequestLink -Root $h -TicketId 101 -PullRequestUrl $script:PrUrl).outcome |
            Should -Be 'guid-not-cached'
        Should -Invoke -ModuleName WorkItemLink Invoke-RestMethod -Times 0 -Exactly `
            -ParameterFilter { $Method -eq 'Patch' }
    }

    It 'skips the write where the item already carries this link' {
        $h = New-Home -Name 'link-already'
        Set-Cache -Home_ $h -Map @{ 'acme/acme-api' = $script:Guid }
        Mock -ModuleName WorkItemLink Invoke-RestMethod {
            New-Item-Response -Links @("vstfs:///GitHub/PullRequest/$($script:Guid)%2F42")
        } -ParameterFilter { $Method -eq 'Get' }
        Mock -ModuleName WorkItemLink Invoke-RestMethod { } -ParameterFilter { $Method -eq 'Patch' }
        (Add-PullRequestLink -Root $h -TicketId 101 -PullRequestUrl $script:PrUrl).outcome |
            Should -Be 'already-linked'
        Should -Invoke -ModuleName WorkItemLink Invoke-RestMethod -Times 0 -Exactly `
            -ParameterFilter { $Method -eq 'Patch' }
    }

    It 'sends one link, caching a discovered GUID first, and says only that it was sent' {
        $h = New-Home -Name 'link-send'
        Mock -ModuleName WorkItemLink Invoke-RestMethod { New-Item-Response } `
            -ParameterFilter { $Method -eq 'Get' }
        Mock -ModuleName WorkItemLink Invoke-RestMethod { } -ParameterFilter { $Method -eq 'Patch' }
        $r = Add-PullRequestLink -Root $h -TicketId 101 -PullRequestUrl $script:PrUrl `
                 -DiscoveredGuid $script:Guid
        $r.outcome | Should -Be 'link-sent'
        Get-RepoGuid -Root $h -RepoKey 'acme/acme-api' | Should -Be $script:Guid
        Should -Invoke -ModuleName WorkItemLink Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'Patch' -and $Body.Contains("$($script:Guid)%2F42") -and
            ([uri]$Uri).AbsoluteUri -like
                'https://dev.azure.com/example-org/Example%20Project/_apis/wit/workitems/101`?*'
        }
    }
}

Describe 'the state move happens only from a starting state' {
    BeforeEach {
        Mock -ModuleName WorkItemLink Invoke-RestMethod { } -ParameterFilter { $Method -eq 'Patch' }
    }

    It 'moves Active to the target, guarded by the revision it read' {
        $h = New-Home -Name 'move-active'
        Mock -ModuleName WorkItemLink Invoke-RestMethod { New-Item-Response -State 'Active' -Rev 9 } `
            -ParameterFilter { $Method -eq 'Get' }
        (Set-WorkItemInReview -Root $h -TicketId 101).outcome | Should -Be 'move-sent'
        Should -Invoke -ModuleName WorkItemLink Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'Patch' -and $Body.Contains('"value":9') -and $Body.Contains('In Review')
        }
    }

    It 'makes no call at all for an item already in review or past it' {
        foreach ($state in 'In Review', 'Resolved', 'Closed') {
            $h = New-Home -Name "move-skip-$($state -replace ' ', '')"
            Mock -ModuleName WorkItemLink Invoke-RestMethod { New-Item-Response -State $state } `
                -ParameterFilter { $Method -eq 'Get' }
            (Set-WorkItemInReview -Root $h -TicketId 101).outcome | Should -Be 'already'
        }
        Should -Invoke -ModuleName WorkItemLink Invoke-RestMethod -Times 0 -Exactly `
            -ParameterFilter { $Method -eq 'Patch' }
    }

    It 'refuses a type the configuration does not name, with no write' {
        $h = New-Home -Name 'move-refuse'
        Mock -ModuleName WorkItemLink Invoke-RestMethod { New-Item-Response -Type 'Story' } `
            -ParameterFilter { $Method -eq 'Get' }
        (Set-WorkItemInReview -Root $h -TicketId 101).outcome | Should -Be 'refuse'
        Should -Invoke -ModuleName WorkItemLink Invoke-RestMethod -Times 0 -Exactly `
            -ParameterFilter { $Method -eq 'Patch' }
    }

    It 'leaves a state it does not know alone, with no write' {
        $h = New-Home -Name 'move-unknown'
        Mock -ModuleName WorkItemLink Invoke-RestMethod { New-Item-Response -State 'Blocked' } `
            -ParameterFilter { $Method -eq 'Get' }
        (Set-WorkItemInReview -Root $h -TicketId 101).outcome | Should -Be 'unrecognised'
        Should -Invoke -ModuleName WorkItemLink Invoke-RestMethod -Times 0 -Exactly `
            -ParameterFilter { $Method -eq 'Patch' }
    }
}

Describe 'verified means the re-read found both the link and the state' {
    It 'passes only when this exact link and an in-review state are both there' {
        $h = New-Home -Name 'verify-pass'
        Set-Cache -Home_ $h -Map @{ 'acme/acme-api' = $script:Guid }
        Mock -ModuleName WorkItemLink Invoke-RestMethod {
            New-Item-Response -State 'In Review' -Links @("vstfs:///GitHub/PullRequest/$($script:Guid)%2F42")
        }
        $v = Test-WorkItemReview -Root $h -TicketId 101 -PullRequestUrl $script:PrUrl
        $v.verified | Should -BeTrue
    }

    It 'fails when the state did not move, and gives the page to follow up on' {
        $h = New-Home -Name 'verify-state'
        Set-Cache -Home_ $h -Map @{ 'acme/acme-api' = $script:Guid }
        Mock -ModuleName WorkItemLink Invoke-RestMethod {
            New-Item-Response -State 'Active' -Links @("vstfs:///GitHub/PullRequest/$($script:Guid)%2F42")
        }
        $v = Test-WorkItemReview -Root $h -TicketId 101 -PullRequestUrl $script:PrUrl
        $v.verified | Should -BeFalse
        $v.linked | Should -BeTrue
        $v.url | Should -Be 'https://dev.azure.com/example-org/Example%20Project/_workitems/edit/101'
    }

    It 'does not count a link to another pull request whose number merely starts the same' {
        $h = New-Home -Name 'verify-prefix'
        Set-Cache -Home_ $h -Map @{ 'acme/acme-api' = $script:Guid }
        Mock -ModuleName WorkItemLink Invoke-RestMethod {
            New-Item-Response -State 'In Review' -Links @("vstfs:///GitHub/PullRequest/$($script:Guid)%2F421")
        }
        (Test-WorkItemReview -Root $h -TicketId 101 -PullRequestUrl $script:PrUrl).linked |
            Should -BeFalse
    }

    It 'with no pull request named, counts any linked pull request, even one never cached' {
        $h = New-Home -Name 'verify-any'
        Mock -ModuleName WorkItemLink Invoke-RestMethod {
            New-Item-Response -State 'In Review' -Links @("vstfs:///GitHub/PullRequest/$($script:Other)%2F7")
        }
        $v = Test-WorkItemReview -Root $h -TicketId 101
        $v.linked | Should -BeTrue
        $v.verified | Should -BeTrue
    }

    It 'with no pull request named, fails when the item links none' {
        $h = New-Home -Name 'verify-none'
        Mock -ModuleName WorkItemLink Invoke-RestMethod { New-Item-Response -State 'In Review' }
        $v = Test-WorkItemReview -Root $h -TicketId 101
        $v.linked | Should -BeFalse
        $v.verified | Should -BeFalse
    }

    It 'does not count a link with the same number in another repository' {
        $h = New-Home -Name 'verify-otherrepo'
        Set-Cache -Home_ $h -Map @{ 'acme/acme-api' = $script:Guid }
        Mock -ModuleName WorkItemLink Invoke-RestMethod {
            New-Item-Response -State 'In Review' -Links @("vstfs:///GitHub/PullRequest/$($script:Other)%2F42")
        }
        (Test-WorkItemReview -Root $h -TicketId 101 -PullRequestUrl $script:PrUrl).linked |
            Should -BeFalse
    }
}

Describe 'GUID discovery reads existing links and never picks between disagreeing ones' {
    It 'finds the GUID on a work item that links a known pull request of the repository' {
        $h = New-Home -Name 'find-one'
        Mock -ModuleName WorkItemLink Invoke-RestMethod {
            New-Item-Response -Links @("vstfs:///GitHub/PullRequest/$($script:Guid)%2F7")
        }
        $r = Find-RepoGuid -Root $h -Candidates @(@{ ticketId = 55; prNumber = 7 })
        $r.guid | Should -Be $script:Guid
        $r.matched | Should -Be 1
    }

    It 'returns no GUID and counts nothing unreadable when nothing links the repository' {
        $h = New-Home -Name 'find-none'
        Mock -ModuleName WorkItemLink Invoke-RestMethod { New-Item-Response }
        $r = Find-RepoGuid -Root $h -Candidates @(@{ ticketId = 55; prNumber = 7 })
        $r.guid | Should -BeNullOrEmpty
        $r.unreadable | Should -Be 0
    }

    It 'counts a candidate it could not read, so absence is not claimed over a failure' {
        $h = New-Home -Name 'find-unreadable'
        Mock -ModuleName WorkItemLink Invoke-RestMethod { throw 'boom' }
        $r = Find-RepoGuid -Root $h -Candidates @(@{ ticketId = 55; prNumber = 7 })
        $r.guid | Should -BeNullOrEmpty
        $r.unreadable | Should -Be 1
    }

    It 'throws where two candidates disagree' {
        $h = New-Home -Name 'find-disagree'
        Mock -ModuleName WorkItemLink Invoke-RestMethod {
            if ($Uri -like '*/workitems/55?*') {
                New-Item-Response -Links @("vstfs:///GitHub/PullRequest/$($script:Guid)%2F7")
            } else {
                New-Item-Response -Links @("vstfs:///GitHub/PullRequest/$($script:Other)%2F8")
            }
        }
        { Find-RepoGuid -Root $h -Candidates @(@{ ticketId = 55; prNumber = 7 },
                                               @{ ticketId = 56; prNumber = 8 }) } |
            Should -Throw -ExpectedMessage '*disagree*'
    }
}
