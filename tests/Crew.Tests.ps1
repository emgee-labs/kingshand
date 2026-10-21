BeforeAll {
    Import-Module "$PSScriptRoot\..\bin\Crew.psm1" -Force
}

Describe 'New-CrewState' {
    It 'creates an empty state' {
        $s = New-CrewState
        $s.workers.Count | Should -Be 0
    }
}

Describe 'Add-CrewWorker' {
    BeforeEach { $script:s = New-CrewState }

    It 'records a worker under its id' {
        Add-CrewWorker -State $script:s -WorkerId '94e2db21' -Ticket 'T-1001' -Kind 'ticket' `
                       -Repo 'acme-web' -Worktree 'C:/wt/T-1001' -Branch 'worktree-T-1001' -Brief 'data/T-1001/brief.md'
        $script:s.workers['94e2db21'].ticket | Should -Be 'T-1001'
        $script:s.workers['94e2db21'].repo   | Should -Be 'acme-web'
    }

    It 'defaults stage to dispatched and landed to false' {
        Add-CrewWorker -State $script:s -WorkerId 'a1' -Ticket 'x' -Kind 'adhoc' `
                       -Repo 'r' -Worktree 'w' -Branch 'b' -Brief 'f'
        $script:s.workers['a1'].stage  | Should -Be 'dispatched'
        $script:s.workers['a1'].landed | Should -BeFalse
    }

    It 'stamps dispatched_at as round-trippable UTC' {
        Add-CrewWorker -State $script:s -WorkerId 'a1' -Ticket 'x' -Kind 'adhoc' `
                       -Repo 'r' -Worktree 'w' -Branch 'b' -Brief 'f'
        { [datetime]::Parse($script:s.workers['a1'].dispatched_at) } | Should -Not -Throw
    }

    It 'records the base ref it was given' {
        Add-CrewWorker -State $script:s -WorkerId 'a1' -Ticket 'x' -Kind 'adhoc' `
                       -Repo 'r' -Worktree 'w' -Branch 'b' -Brief 'f' -Base 'origin/dev'
        $script:s.workers['a1'].base | Should -Be 'origin/dev'
    }

    It 'defaults base to the remote default branch, never the local one' {
        Add-CrewWorker -State $script:s -WorkerId 'a1' -Ticket 'x' -Kind 'adhoc' `
                       -Repo 'r' -Worktree 'w' -Branch 'b' -Brief 'f'
        $script:s.workers['a1'].base | Should -Be 'origin/main'
    }

    It 'rejects an invalid kind' {
        { Add-CrewWorker -State $script:s -WorkerId 'a1' -Ticket 'x' -Kind 'nonsense' `
                         -Repo 'r' -Worktree 'w' -Branch 'b' -Brief 'f' } | Should -Throw '*kind*'
    }

    It 'rejects a duplicate worker id' {
        Add-CrewWorker -State $script:s -WorkerId 'a1' -Ticket 'x' -Kind 'adhoc' -Repo 'r' -Worktree 'w' -Branch 'b' -Brief 'f'
        { Add-CrewWorker -State $script:s -WorkerId 'a1' -Ticket 'y' -Kind 'adhoc' -Repo 'r' -Worktree 'w' -Branch 'b' -Brief 'f' } |
            Should -Throw '*uplicate*'
    }
}

Describe 'Set-CrewStage' {
    BeforeEach {
        $script:s = New-CrewState
        Add-CrewWorker -State $script:s -WorkerId 'a1' -Ticket 'x' -Kind 'adhoc' -Repo 'r' -Worktree 'w' -Branch 'b' -Brief 'f'
    }

    It 'sets a valid stage' {
        Set-CrewStage -State $script:s -WorkerId 'a1' -Stage 'ready'
        $script:s.workers['a1'].stage | Should -Be 'ready'
    }

    It 'sets landed true when the stage becomes landed' {
        Set-CrewStage -State $script:s -WorkerId 'a1' -Stage 'landed'
        $script:s.workers['a1'].landed | Should -BeTrue
    }

    It 'rejects an invalid stage' {
        { Set-CrewStage -State $script:s -WorkerId 'a1' -Stage 'sideways' } | Should -Throw '*stage*'
    }

    It 'rejects an unknown worker id' {
        { Set-CrewStage -State $script:s -WorkerId 'nope' -Stage 'ready' } | Should -Throw '*not found*'
    }
}

# waiting_on records which tasks-axi hold a worker parked on. Null means no park has been recorded
# on this record - never that there is nothing to answer, since only a Hand who has read the report
# ever writes it; a key means it did, and whether that decision is still outstanding is the hold's
# own state in the queue, which this module does not read.
# It is deliberately not a stage: the six stages are a lifecycle a
# worker moves along, while waiting is a condition that can happen at any of them and resolves back
# to the one the worker was already at.
Describe 'waiting_on points at a hold and is never a stage' {
    BeforeEach {
        $script:s = New-CrewState
        Add-CrewWorker -State $script:s -WorkerId 'a1' -Ticket 'x' -Kind 'adhoc' -Repo 'r' -Worktree 'w' -Branch 'b' -Brief 'f'
    }

    It 'is null on a freshly dispatched worker' {
        $script:s.workers['a1'].waiting_on | Should -BeNullOrEmpty
    }

    It 'names the hold once the worker parks' {
        Set-CrewWaitingOn -State $script:s -WorkerId 'a1' -HoldKey 'T-1001-shorter-hero-copy'
        $script:s.workers['a1'].waiting_on | Should -Be 'T-1001-shorter-hero-copy'
    }

    # The module offers no way back to null, and that is the invariant the route rests on. A worker
    # that parked, was answered and carried on must not read the same as one that never parked: the
    # first is a finished delivery and the second has a question nobody has registered yet, and a
    # single null for both either loses the question or refuses delivered work and re-asks it.
    It 'exposes no verb that puts the field back to null' {
        $verbs = @((Get-Module Crew).ExportedFunctions.Keys)
        $verbs | Should -Contain 'Set-CrewWaitingOn'
        $verbs | Should -Not -Contain 'Clear-CrewWaitingOn' -Because 'a cleared pointer is a null with two opposite meanings'
        @($verbs | Where-Object { $_ -like '*WaitingOn' }) |
            Should -HaveCount 1 -Because 'one writer, and no second way to move this field'
    }

    It 'keeps naming the hold after the decision it names has been answered' {
        Set-CrewWaitingOn -State $script:s -WorkerId 'a1' -HoldKey 'T-1001-shorter-hero-copy'
        Set-CrewStage -State $script:s -WorkerId 'a1' -Stage 'gating'
        $script:s.workers['a1'].waiting_on |
            Should -Be 'T-1001-shorter-hero-copy' -Because 'the hold records the answer, so the pointer has nothing to give up'
    }

    # A second parking is the same field with a new key, not a second slot and not a history.
    # There is one worker, waiting on one decision, and nothing to enumerate.
    It 'a second parking replaces the key rather than adding to it' {
        Set-CrewWaitingOn -State $script:s -WorkerId 'a1' -HoldKey 'T-1001-shorter-hero-copy'
        Set-CrewWaitingOn -State $script:s -WorkerId 'a1' -HoldKey 'T-1001-drop-the-banner'
        $script:s.workers['a1'].waiting_on | Should -Be 'T-1001-drop-the-banner'
    }

    It 'leaves the stage where it was, because waiting is not a lifecycle position' {
        Set-CrewStage -State $script:s -WorkerId 'a1' -Stage 'implementing'
        Set-CrewWaitingOn -State $script:s -WorkerId 'a1' -HoldKey 'T-1001-shorter-hero-copy'
        $script:s.workers['a1'].stage | Should -Be 'implementing'
    }

    It 'is not a stage Set-CrewStage will accept' {
        { Set-CrewStage -State $script:s -WorkerId 'a1' -Stage 'waiting' } | Should -Throw '*stage*'
    }

    # tasks-axi ids have no spaces, so a key that could never name a hold is refused where it is
    # written rather than stored and found to match nothing a session later.
    It 'refuses a key that could not be a tasks-axi id' {
        { Set-CrewWaitingOn -State $script:s -WorkerId 'a1' -HoldKey 'shorter hero copy' } |
            Should -Throw '*hold key*'
    }

    # A key pasted in, or built from a here-string, arrives with the newline still on it. .NET's
    # `$` matches immediately before a single trailing newline, so an `^...$` guard accepts that
    # key and stores it - and it then matches no hold, which is the failure this guard exists to
    # prevent. Whitespace anywhere else is refused for the same reason.
    It 'refuses a key carrying trailing whitespace, which no hold was filed under' {
        foreach ($k in @("T-1001-hero-copy`n", "T-1001-hero-copy`r`n", "T-1001-hero-copy ", " T-1001-hero-copy")) {
            { Set-CrewWaitingOn -State $script:s -WorkerId 'a1' -HoldKey $k } |
                Should -Throw '*hold key*' -Because 'a key with whitespace on it names no hold'
        }
        $script:s.workers['a1'].waiting_on |
            Should -BeNullOrEmpty -Because 'a key with whitespace on it names no hold'
    }

    # tasks-axi's own validator requires the first character to be a letter or a digit - ID_CHARS is
    # `[A-Za-z0-9][A-Za-z0-9._-]*`. A work id that lost its leading character arrives as
    # '-1001-hero-copy', which the tool can never resolve, so the guard must refuse it here rather
    # than store a pointer that matches nothing and cannot be torn down without hand repair.
    It 'refuses a key whose first character is punctuation, which no hold can exist under' {
        foreach ($k in @('-1001-hero-copy', '.1001-hero-copy', '_1001-hero-copy')) {
            { Set-CrewWaitingOn -State $script:s -WorkerId 'a1' -HoldKey $k } |
                Should -Throw '*hold key*' -Because 'tasks-axi ids start with a letter or a digit'
        }
        $script:s.workers['a1'].waiting_on |
            Should -BeNullOrEmpty -Because 'a refused key must not have been stored on the way past'
    }

    It 'still saves a key that starts with a letter and one that starts with a digit' {
        Set-CrewWaitingOn -State $script:s -WorkerId 'a1' -HoldKey 'T-1001-hero-copy'
        $script:s.workers['a1'].waiting_on | Should -Be 'T-1001-hero-copy'
        Set-CrewWaitingOn -State $script:s -WorkerId 'a1' -HoldKey '1001-hero-copy'
        $script:s.workers['a1'].waiting_on | Should -Be '1001-hero-copy'
    }

    It 'refuses an unknown worker' {
        { Set-CrewWaitingOn -State $script:s -WorkerId 'nope' -HoldKey 'k' } | Should -Throw '*not found*'
    }

    It 'survives a save and reload, which is the point of storing it at all' {
        $p = Join-Path $TestDrive 'crew-waiting.json'
        Set-CrewWaitingOn -State $script:s -WorkerId 'a1' -HoldKey 'T-1001-shorter-hero-copy'
        Save-CrewState -State $script:s -Path $p
        (Import-CrewState -Path $p).workers['a1'].waiting_on | Should -Be 'T-1001-shorter-hero-copy'
    }

    # Absent and null must be the same thing on the way in. A record written before the field
    # existed would otherwise be a third case, and a third case is exactly what this field was
    # added to stop anyone having to enumerate.
    It 'reads a record written without the field as null rather than as absent' {
        $p = Join-Path $TestDrive 'crew-legacy.json'
        @{ workers = @{ old = @{ ticket = 'x'; stage = 'implementing' } } } |
            ConvertTo-Json -Depth 10 | Set-Content -Path $p -Encoding utf8

        $r = Import-CrewState -Path $p
        $r.workers['old'].ContainsKey('waiting_on') | Should -BeTrue
        $r.workers['old'].waiting_on | Should -BeNullOrEmpty
    }
}

Describe 'Get-CrewByStage' {
    It 'returns only workers in that stage, each carrying its id' {
        $s = New-CrewState
        Add-CrewWorker -State $s -WorkerId 'a1' -Ticket '1' -Kind 'ticket' -Repo 'r' -Worktree 'w' -Branch 'b' -Brief 'f'
        Add-CrewWorker -State $s -WorkerId 'a2' -Ticket '2' -Kind 'ticket' -Repo 'r' -Worktree 'w' -Branch 'b' -Brief 'f'
        Set-CrewStage -State $s -WorkerId 'a2' -Stage 'ready'
        $r = Get-CrewByStage -State $s -Stage 'ready'
        $r.Count | Should -Be 1
        $r[0].id | Should -Be 'a2'
    }

    It 'returns an empty array when nothing matches' {
        $s = New-CrewState
        (Get-CrewByStage -State $s -Stage 'ready').Count | Should -Be 0
    }
}

Describe 'Save and Import round-trip' {
    It 'preserves every field' {
        $p = Join-Path $TestDrive 'crew.json'
        $s = New-CrewState
        Add-CrewWorker -State $s -WorkerId '94e2db21' -Ticket 'T-1001' -Kind 'ticket' `
                       -Repo 'acme-web' -Worktree 'C:/wt/T-1001' -Branch 'worktree-T-1001' -Brief 'data/T-1001/brief.md'
        Set-CrewStage -State $s -WorkerId '94e2db21' -Stage 'ready'
        Save-CrewState -State $s -Path $p

        $r = Import-CrewState -Path $p
        $r.workers['94e2db21'].ticket   | Should -Be 'T-1001'
        $r.workers['94e2db21'].stage    | Should -Be 'ready'
        $r.workers['94e2db21'].worktree | Should -Be 'C:/wt/T-1001'
    }

    It 'returns an empty state when the file does not exist' {
        (Import-CrewState -Path (Join-Path $TestDrive 'missing.json')).workers.Count | Should -Be 0
    }
}

# A `fief` session's warm worker makes a run of fixes on one branch, so one record carries every id
# riding that branch, in order - the source for the commit and pull request titles. Every other
# record keeps the one-ticket shape it always had, untouched on the way in and on the way out.
Describe 'a session worker carries several items, and nothing else changes shape' {
    BeforeAll {
        function Add-SessionWorker {
            param([Parameter(Mandatory)][hashtable]$State, [switch]$InCheckout)
            $extra = @{}
            if ($InCheckout) {
                $extra = @{ InCheckout = $true
                            SettingsRecord = 'D:\data\acme-api-session\checkout-settings.json' }
            }
            Add-CrewWorker -State $State -WorkerId 'acme-api-session' -Ticket 'T-1001' -Kind 'ticket' `
                           -Repo 'acme-api' -Worktree 'C:/repos/acme-api' -Branch 'feature-x' `
                           -Brief 'data/acme-api-session/brief.md' -Session @extra
        }
    }

    BeforeEach { $script:s = New-CrewState }

    It 'adds no new key to an ordinary record' {
        Add-CrewWorker -State $script:s -WorkerId 'T-1001' -Ticket 'T-1001' -Kind 'ticket' `
                       -Repo 'acme-web' -Worktree 'w' -Branch 'worktree-T-1001' -Brief 'f'
        @($script:s.workers['T-1001'].Keys | Sort-Object) |
            Should -Be @('base', 'branch', 'brief', 'dispatched_at', 'kind', 'landed', 'repo', 'stage',
                         'ticket', 'waiting_on', 'worktree')
    }

    It 'reads an ordinary record as its one ticket' {
        Add-CrewWorker -State $script:s -WorkerId 'T-1001' -Ticket 'T-1001' -Kind 'ticket' `
                       -Repo 'acme-web' -Worktree 'w' -Branch 'worktree-T-1001' -Brief 'f'
        $items = @(Get-CrewItems -State $script:s -WorkerId 'T-1001')
        $items.Count   | Should -Be 1
        $items[0].id   | Should -Be 'T-1001'
        $items[0].kind | Should -Be 'ticket'
    }

    It 'starts a session worker with its first ticket as the first item' {
        Add-SessionWorker -State $script:s
        $script:s.workers['acme-api-session'].ticket | Should -Be 'T-1001'
        @(Get-CrewItems -State $script:s -WorkerId 'acme-api-session').id | Should -Be @('T-1001')
    }

    It 're-records a relaunched worker without losing its items or the hold it parked on' {
        Add-SessionWorker -State $script:s -InCheckout
        Add-CrewItem -State $script:s -WorkerId 'acme-api-session' -Item 'fix-header' -Kind 'adhoc'
        Set-CrewWaitingOn -State $script:s -WorkerId 'acme-api-session' -HoldKey 'T-1001-copy'
        Set-CrewStage -State $script:s -WorkerId 'acme-api-session' -Stage 'implementing'
        Set-CrewRelaunch -State $script:s -WorkerId 'acme-api-session' -Worktree 'C:/repos/acme-api' `
            -Branch 'feature-x' -Base 'origin/main' -SettingsRecord 'D:\data\acme-api-session\checkout-settings-2.json'
        $rec = $script:s.workers['acme-api-session']
        @(Get-CrewItems -State $script:s -WorkerId 'acme-api-session').id | Should -Be @('T-1001', 'fix-header')
        $rec.waiting_on      | Should -Be 'T-1001-copy'
        $rec.base            | Should -Be 'origin/main'
        $rec.stage           | Should -Be 'dispatched'
        $rec.settings_record | Should -Be 'D:\data\acme-api-session\checkout-settings-2.json'
    }

    It 'refuses a relaunch of a checkout worker with no new settings record, or of an unknown id' {
        Add-SessionWorker -State $script:s -InCheckout
        { Set-CrewRelaunch -State $script:s -WorkerId 'acme-api-session' -Worktree 'w' -Branch 'feature-x' `
              -Base 'main' } | Should -Throw '*needs -SettingsRecord*'
        { Set-CrewRelaunch -State $script:s -WorkerId 'T-9999' -Worktree 'w' -Branch 'b' -Base 'main' } |
            Should -Throw '*not found*'
    }

    It 'refuses a session started on an id that is not slug-shaped, and records nothing' {
        { Add-CrewWorker -State $script:s -WorkerId 'acme-api-session' -Ticket 'AB#1234' -Kind 'ticket' `
                         -Repo 'acme-api' -Worktree 'w' -Branch 'feature-x' -Brief 'f' -Session } |
            Should -Throw '*slug-shaped*'
        $script:s.workers.ContainsKey('acme-api-session') | Should -BeFalse
    }

    It 'appends items in the order they joined the branch, and keeps that order through a save' {
        Add-SessionWorker -State $script:s
        Add-CrewItem -State $script:s -WorkerId 'acme-api-session' -Item 'fix-header' -Kind 'adhoc'
        Add-CrewItem -State $script:s -WorkerId 'acme-api-session' -Item 'T-1003' -Kind 'ticket'
        $p = Join-Path $TestDrive 'session-crew.json'
        Save-CrewState -State $script:s -Path $p
        $r = Import-CrewState -Path $p
        $items = @(Get-CrewItems -State $r -WorkerId 'acme-api-session')
        $items.id   | Should -Be @('T-1001', 'fix-header', 'T-1003')
        $items.kind | Should -Be @('ticket', 'adhoc', 'ticket')
    }

    It 'survives a save with a single item, which JSON could otherwise unwrap' {
        Add-SessionWorker -State $script:s
        $p = Join-Path $TestDrive 'session-one.json'
        Save-CrewState -State $script:s -Path $p
        $r = Import-CrewState -Path $p
        Add-CrewItem -State $r -WorkerId 'acme-api-session' -Item 'T-1002' -Kind 'ticket'
        @(Get-CrewItems -State $r -WorkerId 'acme-api-session').id | Should -Be @('T-1001', 'T-1002')
    }

    It 'refuses an item joining a worker that is not a session worker' {
        Add-CrewWorker -State $script:s -WorkerId 'T-1001' -Ticket 'T-1001' -Kind 'ticket' `
                       -Repo 'acme-web' -Worktree 'w' -Branch 'worktree-T-1001' -Brief 'f'
        { Add-CrewItem -State $script:s -WorkerId 'T-1001' -Item 'T-1002' -Kind 'ticket' } |
            Should -Throw '*not a session worker*'
        $script:s.workers['T-1001'].ContainsKey('items') | Should -BeFalse
    }

    It 'refuses an id already on the branch' {
        Add-SessionWorker -State $script:s
        { Add-CrewItem -State $script:s -WorkerId 'acme-api-session' -Item 'T-1001' -Kind 'ticket' } |
            Should -Throw '*already on*'
    }

    It 'refuses an item id that is not slug-shaped, and a kind it does not know' {
        Add-SessionWorker -State $script:s
        { Add-CrewItem -State $script:s -WorkerId 'acme-api-session' -Item 'two words' -Kind 'ticket' } |
            Should -Throw '*Invalid item id*'
        { Add-CrewItem -State $script:s -WorkerId 'acme-api-session' -Item 'T-1002' -Kind 'story' } |
            Should -Throw '*Invalid kind*'
    }

    It 'refuses an item list it cannot read, by name, rather than guessing at one' {
        Add-SessionWorker -State $script:s
        $script:s.workers['acme-api-session'].items = @(@{ name = 'T-1001' })
        { Get-CrewItems -State $script:s -WorkerId 'acme-api-session' } | Should -Throw '*cannot be read*'
        $script:s.workers['acme-api-session'].items = @()
        { Get-CrewItems -State $script:s -WorkerId 'acme-api-session' } | Should -Throw '*empty item list*'
    }

    It 'records a checkout worker with the permission record its cleanup needs' {
        Add-SessionWorker -State $script:s -InCheckout
        $rec = $script:s.workers['acme-api-session']
        $rec.checkout        | Should -BeTrue
        $rec.settings_record | Should -Be 'D:\data\acme-api-session\checkout-settings.json'
    }

    It 'refuses a checkout worker with no record, because cleanup could not restore the file' {
        { Add-CrewWorker -State $script:s -WorkerId 'x' -Ticket 'T-1001' -Kind 'ticket' -Repo 'r' `
                         -Worktree 'w' -Branch 'feature-x' -Brief 'f' -InCheckout } |
            Should -Throw '*needs -SettingsRecord*'
        { Add-CrewWorker -State $script:s -WorkerId 'y' -Ticket 'T-1001' -Kind 'ticket' -Repo 'r' `
                         -Worktree 'w' -Branch 'feature-x' -Brief 'f' -SettingsRecord 'D:\x.json' } |
            Should -Throw '*pass -InCheckout*'
    }
}
