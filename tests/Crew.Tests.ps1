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
