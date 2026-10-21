#Requires -Version 7.0
Set-StrictMode -Version Latest

# Night's watch works the queue and merges while the King sleeps, so every floor that code can hold
# is held here, and each one is driven through the module's public functions with its failure
# forced. gh, tasks-axi and herdr are reached through one boundary function each, and those are
# what these cases mock - nothing here reaches a forge, the live queue or a real worker.

BeforeAll {
    Import-Module "$PSScriptRoot\..\bin\AwayJournal.psm1" -Force
    Import-Module "$PSScriptRoot\..\bin\NightsWatch.psm1" -Force

    function New-CaseDir {
        $d = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $d | Out-Null
        $d
    }

    $script:Sha  = 'a' * 40
    $script:Opts = New-WatchOptions

    function New-Project {
        param([string]$WatchMerge = 'on', [string]$Merge = 'off', [string]$Mode = 'direct-PR', [string]$Yolo = 'on')
        [pscustomobject]@{ name = 'acme-api'; mode = $Mode; yolo = $Yolo; merge = $Merge; watchMerge = $WatchMerge }
    }

    # A brief and a report with no parley marker, the ordinary case.
    function New-CleanFiles {
        $d = New-CaseDir
        Set-Content -LiteralPath (Join-Path $d 'brief.md')  -Value '# T-1001'
        Set-Content -LiteralPath (Join-Path $d 'report.md') -Value '# report'
        [pscustomobject]@{ Brief = (Join-Path $d 'brief.md'); Report = (Join-Path $d 'report.md') }
    }

    # gh pr view's JSON for one pull request.
    function New-PrJson {
        param([object[]]$Checks = @(), [string]$State = 'OPEN', [bool]$Draft = $false, [string]$Head = $script:Sha)
        @{ headRefOid = $Head; state = $State; isDraft = $Draft; statusCheckRollup = @($Checks) } |
            ConvertTo-Json -Depth 6
    }
    function New-GreenRun { @{ __typename = 'CheckRun'; status = 'COMPLETED'; conclusion = 'SUCCESS' } }

    function Get-Verdict {
        param($Project = (New-Project), $Options = $script:Opts, [string]$Mode = 'direct-PR',
              [string]$Gate = 'not-run', [string]$Ci = 'has-ci', [switch]$HoldOpen, $Files = (New-CleanFiles))
        Get-WatchMergeVerdict -Project $Project -Options $Options -PullRequest 'https://github.com/acme/acme-api/pull/7' `
            -BriefPath $Files.Brief -ReportPath $Files.Report -Mode $Mode -GateOutcome $Gate -CiStatus $Ci -HoldOpen:$HoldOpen
    }

    function Set-PrReply {
        param([string]$Json, [bool]$Ok = $true)
        $script:PrReply = [pscustomobject]@{ ok = $Ok; text = $Json; error = if ($Ok) { '' } else { 'gh exited 1.' } }
        Mock -ModuleName NightsWatch Invoke-WatchGh { $script:PrReply }
    }
}

Describe 'the invocation' {
    It 'defaults to 88 percent, two workers, and merging on where a project allows it' {
        $o = New-WatchOptions
        $o.thresholdPercent | Should -Be 88
        $o.maxWorkers       | Should -Be 2
        $o.merge            | Should -Be 'on'
    }

    It 'takes each of the three as an argument' {
        $o = New-WatchOptions -ThresholdPercent 90 -MaxWorkers 3 -NoMerge
        $o.thresholdPercent | Should -Be 90
        $o.maxWorkers       | Should -Be 3
        $o.merge            | Should -Be 'off'
    }

    It 'has no argument that turns merging on' {
        (Get-Command New-WatchOptions).Parameters.Keys | Should -Not -Contain 'Merge'
    }

    It 'allows another worker only below the limit' {
        Test-WatchDispatchSlot -Options $script:Opts -LiveWorkers 1 | Should -BeTrue
        Test-WatchDispatchSlot -Options $script:Opts -LiveWorkers 2 | Should -BeFalse
    }
}

Describe 'the pool is only work the queue can prove is decided' {
    It 'reads the ready list the queue tool printed' {
        $toon = "count: 2`nready[2]{id,state,kind,repo,title}:`n  T-1001,queued,task,acme-api,Fix the header`n  T-1002,queued,task,acme-web,Fix the footer"
        $r = Get-WatchReadyItems -ToonText $toon
        $r.readable     | Should -BeTrue
        @($r.items.id)  | Should -Be @('T-1001', 'T-1002')
        $r.items[0].repo | Should -Be 'acme-api'
    }

    It 'says the queue is unreadable rather than returning an empty pool' {
        $r = Get-WatchReadyItems -ToonText 'count: 1'
        $r.readable | Should -BeFalse
        $r.problem  | Should -BeLike '*no ready list*'
    }

    It 'refuses a queue whose item carries no id' {
        $r = Get-WatchReadyItems -ToonText "ready[1]{state,repo}:`n  queued,acme-api"
        $r.readable | Should -BeFalse
        $r.problem  | Should -BeLike '*no id*'
    }

    It 'says so when the queue tool cannot be run' {
        Mock -ModuleName NightsWatch Invoke-WatchTasksAxi { [pscustomobject]@{ ok = $false; text = ''; error = 'tasks-axi is not installed.' } }
        $r = Get-WatchReadyItems
        $r.readable | Should -BeFalse
        $r.problem  | Should -BeLike '*not installed*'
    }

    It 'keeps only items on a registered project that proceeds without asking' {
        $items = @(
            [pscustomobject]@{ id = 'T-1'; repo = 'acme-api' },
            [pscustomobject]@{ id = 'T-2'; repo = 'acme-web' },
            [pscustomobject]@{ id = 'T-3'; repo = 'acme-docs' },
            [pscustomobject]@{ id = 'T-4'; repo = '-' }
        )
        $projects = @(
            [pscustomobject]@{ name = 'acme-api'; yolo = 'on' },
            [pscustomobject]@{ name = 'acme-web'; yolo = 'off' }
        )
        $r = Select-WatchPool -Items $items -Projects $projects
        @($r.pool.id) | Should -Be @('T-1')
        ($r.excluded | Where-Object id -eq 'T-2').reason | Should -BeLike '*approval before a dispatch*'
        ($r.excluded | Where-Object id -eq 'T-3').reason | Should -BeLike '*not registered*'
        ($r.excluded | Where-Object id -eq 'T-4').reason | Should -BeLike '*names no project*'
    }

    It 'reads yolo as the string on, never for truthiness' {
        $r = Select-WatchPool -Items @([pscustomobject]@{ id = 'T-1'; repo = 'acme-api' }) `
                -Projects @([pscustomobject]@{ name = 'acme-api'; yolo = 'off' })
        @($r.pool).Count | Should -Be 0
    }

    It 'returns an empty pool for an empty queue, which is when the watch stops' {
        $r = Select-WatchPool -Items @() -Projects @()
        @($r.pool).Count | Should -Be 0
    }
}

Describe 'a merge happens only under every floor' {
    It 'allows a green pull request on a +watch-merge project and binds it to the live head' {
        Set-PrReply (New-PrJson -Checks @((New-GreenRun)))
        $v = Get-Verdict
        $v.allowed | Should -BeTrue
        $v.head    | Should -Be $script:Sha
    }

    It 'refuses a project with +merge but no +watch-merge' {
        Set-PrReply (New-PrJson -Checks @((New-GreenRun)))
        $v = Get-Verdict -Project (New-Project -WatchMerge 'off' -Merge 'on')
        $v.allowed | Should -BeFalse
        ($v.reasons -join ' ') | Should -BeLike '*does not declare +watch-merge*'
    }

    It 'refuses when this run turned merging off' {
        Set-PrReply (New-PrJson -Checks @((New-GreenRun)))
        (Get-Verdict -Options (New-WatchOptions -NoMerge)).allowed | Should -BeFalse
    }

    It 'never relocates a local-only landing' {
        Set-PrReply (New-PrJson -Checks @((New-GreenRun)))
        $v = Get-Verdict -Project (New-Project -Mode 'local-only') -Mode 'local-only'
        $v.allowed | Should -BeFalse
        ($v.reasons -join ' ') | Should -BeLike '*never relocated*'
    }

    It 'never merges red' {
        Set-PrReply (New-PrJson -Checks @((New-GreenRun), @{ __typename = 'CheckRun'; status = 'COMPLETED'; conclusion = 'FAILURE' }))
        $v = Get-Verdict
        $v.allowed | Should -BeFalse
        ($v.reasons -join ' ') | Should -BeLike '*red*Never merge red*'
    }

    It 'refuses a failed commit status as red too' {
        Set-PrReply (New-PrJson -Checks @(@{ __typename = 'StatusContext'; state = 'FAILURE' }))
        (Get-Verdict).allowed | Should -BeFalse
    }

    It 'refuses a check still pending at the live head' {
        Set-PrReply (New-PrJson -Checks @(@{ __typename = 'CheckRun'; status = 'IN_PROGRESS'; conclusion = '' }))
        ((Get-Verdict).reasons -join ' ') | Should -BeLike '*pending*'
    }

    It 'refuses a check in a shape it cannot read rather than counting it green' {
        Set-PrReply (New-PrJson -Checks @(@{ __typename = 'SomethingNew' }))
        ((Get-Verdict).reasons -join ' ') | Should -BeLike '*could not be read*'
    }

    It 'counts no checks as green only where the repository is settled as having none' {
        Set-PrReply (New-PrJson -Checks @())
        (Get-Verdict -Ci 'no-ci').allowed  | Should -BeTrue
        (Get-Verdict -Ci 'has-ci').allowed | Should -BeFalse
    }

    It 'refuses when whether anything reports a check is unknown' {
        Set-PrReply (New-PrJson -Checks @((New-GreenRun)))
        (Get-Verdict -Ci 'unknown').allowed | Should -BeFalse
    }

    It 'refuses a no-mistakes task whose gate did not complete' {
        Set-PrReply (New-PrJson -Checks @((New-GreenRun)))
        (Get-Verdict -Mode 'no-mistakes' -Gate 'incomplete').allowed | Should -BeFalse
        (Get-Verdict -Mode 'no-mistakes' -Gate 'complete').allowed   | Should -BeTrue
    }

    It 'refuses a run carrying the parley marker in its brief' {
        Set-PrReply (New-PrJson -Checks @((New-GreenRun)))
        $f = New-CleanFiles
        Add-Content -LiteralPath $f.Brief -Value '- PARLEY DISPATCH - NO REVIEW GATE RAN. Nothing has established this.'
        ((Get-Verdict -Files $f).reasons -join ' ') | Should -BeLike '*parley marker*'
    }

    It 'refuses when the report cannot be read, because the marker was not checked' {
        Set-PrReply (New-PrJson -Checks @((New-GreenRun)))
        $f = New-CleanFiles
        Remove-Item -LiteralPath $f.Report
        ((Get-Verdict -Files $f).reasons -join ' ') | Should -BeLike '*could not be read*marker*'
    }

    It 'refuses a worker parked on a decision that is still open' {
        Set-PrReply (New-PrJson -Checks @((New-GreenRun)))
        (Get-Verdict -HoldOpen).allowed | Should -BeFalse
    }

    It 'refuses a pull request that could not be read' {
        Set-PrReply -Json 'not json' -Ok $false
        $v = Get-Verdict
        $v.allowed | Should -BeFalse
        $v.head    | Should -Be ''
    }

    It 'refuses a closed pull request, a draft, and one with no head to bind to' {
        Set-PrReply (New-PrJson -Checks @((New-GreenRun)) -State 'MERGED')
        (Get-Verdict).allowed | Should -BeFalse
        Set-PrReply (New-PrJson -Checks @((New-GreenRun)) -Draft $true)
        (Get-Verdict).allowed | Should -BeFalse
        Set-PrReply (New-PrJson -Checks @((New-GreenRun)) -Head '')
        (Get-Verdict).allowed | Should -BeFalse
    }

    It 'merges with the repository''s strategy, bound to the head the checks were read at' {
        Set-PrReply (New-PrJson -Checks @((New-GreenRun)))
        $v = Get-Verdict
        $script:Merged = $null
        Mock -ModuleName NightsWatch Invoke-WatchGh { $script:Merged = $Arguments; [pscustomobject]@{ ok = $true; text = 'merged'; error = '' } }
        $r = Invoke-WatchMerge -Verdict $v -Strategy 'merge'
        $r.merged | Should -BeTrue
        @($script:Merged) | Should -Be @('pr', 'merge', 'https://github.com/acme/acme-api/pull/7', '--merge',
                                         '--match-head-commit', $script:Sha)
    }

    It 'never calls the forge for a verdict that refused' {
        Set-PrReply (New-PrJson -Checks @(@{ __typename = 'CheckRun'; status = 'COMPLETED'; conclusion = 'FAILURE' }))
        $v = Get-Verdict
        Mock -ModuleName NightsWatch Invoke-WatchGh { throw 'must not be called' }
        { Invoke-WatchMerge -Verdict $v -Strategy 'merge' } | Should -Throw '*may not merge*'
    }
}

Describe 'the usage window paces the night' {
    BeforeAll {
        function New-Reading {
            param($Percent, $Floor = $null, [string]$Status = 'has-usage', [string]$Window = 'five_hour',
                  [string]$ResetsAt = ([datetime]::UtcNow.AddHours(2).ToString('o')))
            [pscustomobject]@{ status = $Status; percent = $Percent; floorPercent = $Floor; window = $Window
                               resetsAt = $ResetsAt; detail = 'reading' }
        }
    }

    It 'carries on below the threshold, reading every seven minutes under 80' {
        $s = Get-WatchUsageStep -Reading (New-Reading 40) -Options $script:Opts
        $s.action          | Should -Be 'continue'
        $s.nextReadMinutes | Should -Be 7
    }

    It 'reads every five minutes from 80 percent' {
        (Get-WatchUsageStep -Reading (New-Reading 82) -Options $script:Opts).nextReadMinutes | Should -Be 5
    }

    It 'pauses at 88 percent, pinning the wake to the reset plus the margin' {
        $reset = [datetime]::UtcNow.AddHours(2)
        $s = Get-WatchUsageStep -Reading (New-Reading 88 -ResetsAt $reset.ToString('o')) -Options $script:Opts
        $s.action | Should -Be 'pause'
        ([datetimeoffset]::Parse($s.wakeAt).UtcDateTime - $reset).TotalMinutes | Should -BeGreaterOrEqual 4.9
    }

    It 'honours a different threshold given at invocation' {
        (Get-WatchUsageStep -Reading (New-Reading 88) -Options (New-WatchOptions -ThresholdPercent 90)).action |
            Should -Be 'continue'
    }

    It 'stops rather than sleeping when the weekly window is the one at the limit' {
        (Get-WatchUsageStep -Reading (New-Reading 91 -Window 'seven_day') -Options $script:Opts).action |
            Should -Be 'stop-weekly'
    }

    It 'stops when the reset time cannot be read, because there is nothing to sleep to' {
        $s = Get-WatchUsageStep -Reading (New-Reading 90 -ResetsAt '') -Options $script:Opts
        $s.action | Should -Be 'stop-weekly'
        $s.detail | Should -BeLike '*could not be read*'
    }

    It 'fails open on a reading it could not take, and says it could not see' {
        $s = Get-WatchUsageStep -Reading (New-Reading $null -Status 'unknown') -Options $script:Opts
        $s.action  | Should -Be 'blind'
        $s.percent | Should -BeNullOrEmpty
    }

    It 'pauses on a stale floor already at the threshold' {
        (Get-WatchUsageStep -Reading (New-Reading $null -Floor 89 -Status 'unknown') -Options $script:Opts).action |
            Should -Be 'pause'
    }

    It 'refuses a wake more than six hours away' {
        (Get-WatchWakeTime -ResetsAt ([datetime]::UtcNow.AddDays(3).ToString('o'))).ok | Should -BeFalse
        { Wait-WatchReset -WakeAt ([datetime]::UtcNow.AddDays(3).ToString('o')) } | Should -Throw '*not a five-hour window*'
    }

    It 'wakes at once for a pinned time already past' {
        $r = Wait-WatchReset -WakeAt ([datetime]::UtcNow.AddSeconds(-5).ToString('o'))
        $r.woke | Should -BeTrue
    }

    It 'confirms the window rolled only on a current reading below the threshold' {
        Test-WatchWindowRolled -Reading (New-Reading 3) -Options $script:Opts | Should -BeTrue
        Test-WatchWindowRolled -Reading (New-Reading 95) -Options $script:Opts | Should -BeFalse
        Test-WatchWindowRolled -Reading (New-Reading $null -Floor 3 -Status 'unknown') -Options $script:Opts | Should -BeFalse
    }
}

Describe 'a pause rescues the gate''s commits first, and a restart carries what survived' {
    BeforeAll {
        function New-Repo {
            $d = New-CaseDir
            git init -q -b main $d
            git -C $d config user.name 'Test'; git -C $d config user.email 'test@example.invalid'
            Set-Content -LiteralPath (Join-Path $d 'a.txt') -Value 'a'
            git -C $d add -A; git -C $d commit -q -m 'base'
            $d
        }
    }

    It 'fetches a commit only the gate mirror holds into a ref named for the task and the moment' {
        $repo = New-Repo
        $mirrors = New-CaseDir
        $mirror = Join-Path $mirrors 'abc123.git'
        git clone -q --bare $repo $mirror
        $work = New-CaseDir
        git clone -q $mirror $work
        git -C $work config user.name 'Test'; git -C $work config user.email 'test@example.invalid'
        Set-Content -LiteralPath (Join-Path $work 'b.txt') -Value 'fix'
        git -C $work add -A; git -C $work commit -q -m 'gate fix'
        git -C $work push -q origin HEAD:refs/heads/gate-run 2>&1 | Out-Null
        $head = (git -C $work rev-parse HEAD).Trim()

        $r = Save-WatchGateRescue -RepoPath $repo -Head $head -Task 'T-1001' -MirrorRoot $mirrors -At ([datetime]'2026-10-22T02:30:00Z')
        $r.ref  | Should -Be 'refs/gate/T-1001-20261022T0230'
        (git -C $repo rev-parse $r.ref).Trim() | Should -Be $head
    }

    It 'writes the ref directly when the repository already has the commit' {
        $repo = New-Repo
        $head = (git -C $repo rev-parse HEAD).Trim()
        (Save-WatchGateRescue -RepoPath $repo -Head $head -Task 'T-1001' -MirrorRoot (New-CaseDir)).from |
            Should -Be 'repository'
    }

    It 'never overwrites an earlier rescue' {
        $repo = New-Repo
        $head = (git -C $repo rev-parse HEAD).Trim()
        $at = [datetime]'2026-10-22T02:30:00Z'
        $null = Save-WatchGateRescue -RepoPath $repo -Head $head -Task 'T-1001' -At $at -MirrorRoot (New-CaseDir)
        { Save-WatchGateRescue -RepoPath $repo -Head $head -Task 'T-1001' -At $at -MirrorRoot (New-CaseDir) } |
            Should -Throw '*already exists*'
    }

    It 'refuses a commit nothing holds, and a head that is not a full commit id' {
        $repo = New-Repo
        { Save-WatchGateRescue -RepoPath $repo -Head ('b' * 40) -Task 'T-1001' -MirrorRoot (New-CaseDir) } |
            Should -Throw '*could not be rescued*'
        { Save-WatchGateRescue -RepoPath $repo -Head 'abc' -Task 'T-1001' -MirrorRoot (New-CaseDir) } |
            Should -Throw '*not a full commit id*'
    }

    It 'resumes a parked or running run, starts fresh after a failed one, and will not guess' {
        Get-WatchResumeChoice -GateState ([pscustomobject]@{ status = 'has-run'; isParked = $true; runStatus = 'running' }) | Should -Be 'resume'
        Get-WatchResumeChoice -GateState ([pscustomobject]@{ status = 'has-run'; isParked = $false; runStatus = 'failed' }) | Should -Be 'fresh'
        Get-WatchResumeChoice -GateState ([pscustomobject]@{ status = 'no-run'; isParked = $false; runStatus = '' }) | Should -Be 'fresh'
        Get-WatchResumeChoice -GateState ([pscustomobject]@{ status = 'unreadable'; isParked = $false; runStatus = '' }) | Should -Be 'unknown'
        Get-WatchResumeChoice -GateState ([pscustomobject]@{ status = 'has-run'; isParked = $false; runStatus = 'odd' }) | Should -Be 'unknown'
    }

    It 'builds a restart prompt carrying all four things' {
        $p = New-WatchRestartPrompt -RescueRef 'refs/gate/T-1001-20261022T0230' -Resume 'fresh' `
                -Directions @('Keep the header copy as the King wrote it.') -Settled @('The flaky test is a timing race.')
        $p | Should -BeLike '*refs/gate/T-1001-20261022T0230*'
        $p | Should -BeLike '*Start a fresh gate run*'
        $p | Should -BeLike '*Keep the header copy as the King wrote it.*'
        $p | Should -BeLike '*do not re-investigate: The flaky test is a timing race.*'
    }

    It 'refuses a restart prompt with a part left out unless it is said to be empty' {
        { New-WatchRestartPrompt -RescueRef 'refs/gate/x' -Resume 'fresh' -Settled @('x') } | Should -Throw '*standing direction*'
        { New-WatchRestartPrompt -RescueRef 'refs/gate/x' -Resume 'fresh' -Directions @('x') } | Should -Throw '*settled*'
        { New-WatchRestartPrompt -RescueRef '' -Resume 'fresh' -NoDirections -NothingSettled } | Should -Throw '*rescued*'
        { New-WatchRestartPrompt -RescueRef 'refs/gate/x' -Resume 'unknown' -NoDirections -NothingSettled } | Should -Throw '*not settled*'
        New-WatchRestartPrompt -RescueRef '' -Resume 'resume' -NoDirections -NothingSettled -NothingRescued |
            Should -BeLike '*resume it*'
    }

    It 'dismisses the usage-limit dialog with Escape and nothing else' {
        Mock -ModuleName NightsWatch Read-HerdrAgentScreen { [pscustomobject]@{ ok = $true; text = "What do you want to do?`n> 1. Stop and wait for limit to reset`n  2. Ask your admin" } }
        Mock -ModuleName NightsWatch Send-HerdrKeys { }
        (Clear-WatchLimitDialog -Name 'T-1001').dismissed | Should -BeTrue
        Should -Invoke -ModuleName NightsWatch Send-HerdrKeys -Times 1 -ParameterFilter { @($Keys) -join ',' -eq 'escape' }
    }

    It 'leaves any other prompt alone' {
        Mock -ModuleName NightsWatch Read-HerdrAgentScreen { [pscustomobject]@{ ok = $true; text = "> 1. Rewrite the parser`n  2. Chat about this`n  Enter to select" } }
        Mock -ModuleName NightsWatch Send-HerdrKeys { }
        (Clear-WatchLimitDialog -Name 'T-1001').dismissed | Should -BeFalse
        Should -Invoke -ModuleName NightsWatch Send-HerdrKeys -Times 0
    }

    It 'reads only the live screen, so a dialog left in scrollback is not dismissed' {
        Mock -ModuleName NightsWatch Read-HerdrAgent { "> 1. Stop and wait for limit to reset" }
        Mock -ModuleName NightsWatch Read-HerdrAgentScreen { [pscustomobject]@{ ok = $true; text = "Working on the parser" } }
        Mock -ModuleName NightsWatch Send-HerdrKeys { }
        (Clear-WatchLimitDialog -Name 'T-1001').dismissed | Should -BeFalse
        Should -Invoke -ModuleName NightsWatch Send-HerdrKeys -Times 0
    }

    It 'sends nothing when the live screen cannot be read' {
        Mock -ModuleName NightsWatch Read-HerdrAgentScreen { [pscustomobject]@{ ok = $false; text = '' } }
        Mock -ModuleName NightsWatch Send-HerdrKeys { }
        (Clear-WatchLimitDialog -Name 'T-1001').dismissed | Should -BeFalse
        Should -Invoke -ModuleName NightsWatch Send-HerdrKeys -Times 0
    }
}

Describe 'a parked lane is recorded once, not once per wait' {
    It 'writes a record the first time and nothing for the same fact again' {
        $root = New-CaseDir
        $flag = Join-Path $root 'state\.afk'
        New-Item -ItemType Directory -Force -Path (Split-Path $flag) | Out-Null
        Set-Content -LiteralPath $flag -Value "since: 2026-10-22T01:00:00Z`nnote: nights-watch"
        $data = Join-Path $root 'data'

        $a = Write-WatchRecordOnce -Kind waiting -Text 'T-1001 is parked on decision T-1001-hero-copy' -Worker 'T-1001' -FlagPath $flag -DataPath $data
        $b = Write-WatchRecordOnce -Kind waiting -Text 'T-1001 is parked on decision T-1001-hero-copy' -Worker 'T-1001' -FlagPath $flag -DataPath $data
        $c = Write-WatchRecordOnce -Kind waiting -Text 'T-1002 is parked on decision T-1002-x' -Worker 'T-1002' -FlagPath $flag -DataPath $data
        $a.written | Should -BeTrue
        $b.written | Should -BeFalse
        $c.written | Should -BeTrue
        (Get-AwayDigest -FlagPath $flag -DataPath $data).count | Should -Be 2
    }
}
