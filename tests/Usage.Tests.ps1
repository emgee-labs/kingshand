#Requires -Version 7.0
Set-StrictMode -Version Latest

# bin\Usage.psm1 is exercised here against a mocked quota-axi. Nothing below reaches the network,
# needs a subscription, or writes anywhere at all - the module keeps no file, and one of the cases
# below is there to keep it that way.
#
# `Invoke-QuotaAxi` is the module's single boundary to the outside world - every lookup goes through
# that one function - so mocking it is what makes the whole answer testable, including the cases
# that matter most: the ones where nothing answers at all.
#
# The rule most of these defend is one line: an unanswered question is `unknown` and `percent` stays
# unset. Zero is the fabrication that costs the most here, because it reads as a wide open window
# and would wave through the dispatch this module exists to refuse.

BeforeAll {
    Import-Module "$PSScriptRoot\..\bin\Usage.psm1" -Force

    $script:TempFixtures = [System.Collections.Generic.List[string]]::new()

    function New-TempFixtureDir {
        param([string]$Prefix = 'usage-')
        $p = Join-Path ([System.IO.Path]::GetTempPath()) ($Prefix + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $p | Out-Null
        $script:TempFixtures.Add($p)
        $p
    }

    # quota-axi's two reply shapes, and nothing invented: a success carrying its stdout as text, and
    # a failure carrying its own message.
    function New-AxiOk   { param([string]$Value = '')  [pscustomobject]@{ ok = $true;  value = $Value; error = '' } }
    function New-AxiFail { param([string]$Error = 'quota-axi exited 1 with no output.') [pscustomobject]@{ ok = $false; value = ''; error = $Error } }

    # One provider report in the shape quota-axi actually emits, built from the live tool's own
    # output rather than from a guess. Every case below varies one thing about it.
    function New-AxiReport {
        param(
            # Typed as an object rather than a double so a field the tool wrote as a word can be
            # put through the same reader. A fixture that could only hold a number could not
            # exercise the case where the number is not one.
            [object]$FiveHourPercent = 4,
            # RELATIVE, NEVER A FIXED DATE. A window only counts while its reset is still ahead, so
            # a fixture pinned to a literal timestamp passes until that moment arrives and then
            # fails for everyone afterwards, describing a window that has already rolled.
            #
            # AN EMPTY STRING OMITS THE FIELD ENTIRELY, which is the shape the tool really produces
            # for a window it has no reset time for - not a key written as empty text.
            [string]$FiveHourResets  = ([datetimeoffset]::UtcNow.AddHours(3).ToString('o')),
            [switch]$WithSevenDay,
            [object]$SevenDayPercent = 61,
            [string]$SevenDayResets = ([datetimeoffset]::UtcNow.AddDays(4).ToString('o')),
            [bool]$Stale = $false,
            # What the tool says its own last attempt failed on. Absent unless a case is about it.
            [string]$StateError = '',
            [switch]$NoWindows,
            # $null omits the field, which is the answer of a tool that stamps no version at all.
            [object]$SchemaVersion = 3,
            [string]$Provider = 'claude'
        )

        $fiveRemaining = if ($FiveHourPercent -is [string]) { $null } else { 100 - $FiveHourPercent }

        # Assigned in two statements rather than out of an `if`. `$x = if ($true) { @() }` is $null,
        # not an empty array - the expression emits nothing to the pipeline - and a fixture that
        # wrote `"windows": null` would exercise a case no tool produces.
        $windows = @()
        if (-not $NoWindows) {
            $five = @{ id = 'five_hour'; label = 'session'; kind = 'session'
                       percentUsed = $FiveHourPercent
                       windowSeconds = 18000; percentRemaining = $fiveRemaining }
            if ($FiveHourResets) { $five['resetsAt'] = $FiveHourResets }
            $windows = @(
                $five,
                # The spend cap sitting at 100 is real on this machine and it must NOT decide the
                # answer: taking the worst window would refuse every dispatch.
                @{ id = 'extra_usage'; label = 'extra usage'; kind = 'credits'
                   percentUsed = 100; spentUsd = 50.04; limitUsd = 50; percentRemaining = 0 }
            )
            if ($WithSevenDay) {
                $seven = @{ id = 'seven_day'; label = 'weekly'; kind = 'rolling'
                            percentUsed = $SevenDayPercent; windowSeconds = 604800 }
                if ($SevenDayResets) { $seven['resetsAt'] = $SevenDayResets }
                $windows += $seven
            }
        }

        $state = @{ status = if ($Stale) { 'stale' } else { 'fresh' }; stale = $Stale }
        if ($StateError) { $state['error'] = $StateError }

        $report = @{
            generatedAt = '2026-09-05T17:40:31.826Z'
            providers   = @(@{
                provider = $Provider; label = 'Claude'; source = 'oauth'; plan = 'team'
                windows  = $windows
                state    = $state
            })
        }
        if ($null -ne $SchemaVersion) { $report['schemaVersion'] = $SchemaVersion }
        $report | ConvertTo-Json -Depth 12
    }

    # One Claude provider and nothing else, so a test about the shape of the report can write only
    # the part it is about. Every field the reader looks for is one the tool is allowed to leave
    # out, which is the whole reason these cases have to be told apart.
    function New-AxiProviderJson {
        param([string]$Body, [string]$Schema = '"schemaVersion": 3, ')
        '{ ' + $Schema + '"providers": [ { "provider": "claude", ' +
        '"state": { "stale": false }' + $(if ($Body) { ", $Body" } else { '' }) + ' } ] }'
    }

    # A fleet row in the shape Get-CrewStatus.ps1 emits. Only the fields the pulse reads are set,
    # because a fixture carrying fields nothing looks at proves nothing about either.
    function New-FleetRow {
        param(
            [string]$Ticket,
            [string]$Stage = 'implementing',
            [bool]$Live = $true,
            [string]$AgentState = 'working',
            [string]$Id = ''
        )
        [pscustomobject]@{
            id = if ($Id) { $Id } else { "w-$Ticket" }
            ticket = $Ticket; repo = 'C:\repo'; stage = $Stage
            live = $Live; agentState = $AgentState; agentStatus = ''; waitingOn = ''
        }
    }
}

AfterAll {
    foreach ($p in $script:TempFixtures) {
        if (Test-Path -LiteralPath $p) {
            Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    $script:TempFixtures.Clear()
}

Describe 'Get-UsageWindow answers, or says plainly that it cannot' {

    Context 'when quota-axi reports the account' {
        It 'reads the percentage from the account window nearest its limit' {
            Mock -ModuleName Usage Invoke-QuotaAxi { New-AxiOk (New-AxiReport -FiveHourPercent 4) }

            $r = Get-UsageWindow
            $r.status  | Should -Be 'has-usage'
            $r.signal  | Should -Be 'driving-window'
            $r.percent | Should -Be 4
            $r.window  | Should -Be 'five_hour'
        }

        # THE MEASURED TRAP, AND THE ONE CASE THE KING ASKED FOR BY NAME. `extra_usage` on this
        # machine reports 100 percent used with no reset time at all. Take the worst percentage
        # across the whole list and the answer is 100 for ever, which blocks every dispatch
        # permanently - the hard block this guard is written never to perform.
        It 'never lets a hundred-percent window with no reset time decide the answer' {
            Mock -ModuleName Usage Invoke-QuotaAxi { New-AxiOk (New-AxiReport -FiveHourPercent 4) }

            $r = Get-UsageWindow
            $r.percent | Should -Be 4 -Because 'the spend cap in the fixture sits at 100 with no reset'
            $r.window  | Should -Not -Be 'extra_usage'
            $r.percent | Should -BeLessThan 90 -Because 'this reading must not refuse a dispatch'
        }

        It 'carries the reset time and says it in words a person can read' {
            Mock -ModuleName Usage Invoke-QuotaAxi { New-AxiOk (New-AxiReport -FiveHourPercent 4) }

            $r = Get-UsageWindow
            $r.resetsAt | Should -Not -BeNullOrEmpty
            $r.detail   | Should -BeLike '*resets at*'
            $r.detail   | Should -BeLike '*session window*' -Because 'the detail is read out to a person'
        }

        # THE SESSION WINDOW AND THE WEEK ARE CONSIDERED TOGETHER. An overnight run sits comfortably
        # inside a five-hour window while burning the week, and the weekly window resets in days
        # rather than hours, so tripping that one costs far more.
        It 'is driven by the week when the week is nearer its limit than the session' {
            Mock -ModuleName Usage Invoke-QuotaAxi {
                New-AxiOk (New-AxiReport -FiveHourPercent 12 -WithSevenDay)
            }

            $r = Get-UsageWindow
            $r.status  | Should -Be 'has-usage'
            $r.percent | Should -Be 61 -Because 'the weekly window in the fixture sits at 61'
            $r.window  | Should -Be 'seven_day'
            $r.detail  | Should -BeLike '*weekly window*'
            $r.detail  | Should -BeLike '*nearest its limit*'
        }

        It 'is driven by the session when the session is nearer its limit than the week' {
            Mock -ModuleName Usage Invoke-QuotaAxi {
                New-AxiOk (New-AxiReport -FiveHourPercent 77 -WithSevenDay)
            }

            $r = Get-UsageWindow
            $r.percent | Should -Be 77
            $r.window  | Should -Be 'five_hour'
        }

        # A window whose reset has already passed describes a pool that has rolled, so its
        # percentage is about a window that is over rather than the one running now. It is the one
        # thing still discarded, and even this one is discarded out loud.
        It 'ignores a window whose reset time has already passed, and says it did' {
            Mock -ModuleName Usage Invoke-QuotaAxi {
                New-AxiOk (New-AxiReport -FiveHourPercent 95 -WithSevenDay `
                                         -FiveHourResets ([datetimeoffset]::UtcNow.AddHours(-1).ToString('o')))
            }

            $r = Get-UsageWindow
            $r.percent | Should -Be 61 -Because 'the spent session window has rolled and does not count'
            $r.window  | Should -Be 'seven_day'
            $r.detail  | Should -BeLike '*session window was left out*'
            $r.detail  | Should -BeLike '*already passed*'
        }

        # THE FAILURE THIS CLOSES, IN THE SHAPE IT WAS FOUND IN. An account window with a readable
        # percentage and no reset time used to be dropped whole, so a session window at 95 percent
        # vanished and the reader answered a confident 30 from the week - and a worker was
        # dispatched into a window that was nearly spent. The percentage is what bounds the
        # dispatch and it was read perfectly well; only the claim about when it clears was lost.
        It 'keeps an account window that reports a percentage with no reset time' {
            Mock -ModuleName Usage Invoke-QuotaAxi {
                New-AxiOk (New-AxiReport -FiveHourPercent 95 -FiveHourResets '' `
                                         -WithSevenDay -SevenDayPercent 30)
            }

            $r = Get-UsageWindow
            $r.status   | Should -Be 'has-usage'
            $r.percent  | Should -Be 95 -Because 'the window nearest its limit still decides'
            $r.window   | Should -Be 'five_hour'
            $r.resetsAt | Should -Be '' -Because 'only when it clears was unreadable'
            $r.detail   | Should -BeLike '*no reset time this could read*'
        }

        # The same rule from the other side, and the direction that actually costs something: the
        # weekly window at 95 percent with no reset must not disappear behind a comfortable 10
        # percent from the session.
        It 'is still driven by the week when the week has no reset time and is nearer its limit' {
            Mock -ModuleName Usage Invoke-QuotaAxi {
                New-AxiOk (New-AxiReport -FiveHourPercent 10 -WithSevenDay `
                                         -SevenDayPercent 95 -SevenDayResets '')
            }

            $r = Get-UsageWindow
            $r.percent | Should -Be 95
            $r.window  | Should -Be 'seven_day'
            $r.detail  | Should -BeLike '*weekly window carries no reset time this could read*'
        }

        # An unreadable reset time is the same fact as an absent one: the number stands and only
        # the time is lost.
        It 'keeps the percentage when the reset time is there and cannot be parsed' {
            Mock -ModuleName Usage Invoke-QuotaAxi {
                New-AxiOk (New-AxiReport -FiveHourPercent 4 -FiveHourResets 'whenever')
            }

            $r = Get-UsageWindow
            $r.status   | Should -Be 'has-usage'
            $r.percent  | Should -Be 4
            $r.resetsAt | Should -Be ''
            $r.detail   | Should -BeLike '*no reset time this could read*'
            $r.detail   | Should -Not -BeLike '*resets at*'
        }

        # A spend cap at 100 percent with no reset is STILL excluded, and by the id filter rather
        # than by the reset rule - which is what keeps the rule above from reintroducing the
        # permanent block. The session or weekly window is the one that really bounds a worker, so
        # that one at 100 with no reset does count.
        It 'still ignores the spend cap once a missing reset no longer disqualifies a window' {
            Mock -ModuleName Usage Invoke-QuotaAxi { New-AxiOk (New-AxiReport -FiveHourPercent 4) }

            $r = Get-UsageWindow
            $r.percent | Should -Be 4
            $r.window  | Should -Be 'five_hour'
        }

        It 'reports unknown when every account window has already reset' {
            Mock -ModuleName Usage Invoke-QuotaAxi {
                New-AxiOk (New-AxiReport -FiveHourPercent 4 `
                                         -FiveHourResets ([datetimeoffset]::UtcNow.AddHours(-1).ToString('o')))
            }

            $r = Get-UsageWindow
            $r.status  | Should -Be 'unknown'
            $r.signal  | Should -Be 'no-applicable-window'
            $r.percent | Should -BeNullOrEmpty
            $r.detail  | Should -BeLike '*session window was left out*'
        }

        It 'records the schema version the tool stamped, and never refuses on it' {
            Mock -ModuleName Usage Invoke-QuotaAxi {
                New-AxiOk (New-AxiReport -FiveHourPercent 4 -SchemaVersion 99)
            }

            $r = Get-UsageWindow
            $r.status        | Should -Be 'has-usage' -Because 'an unfamiliar version must not take the reader out'
            $r.schemaVersion | Should -Be '99'
        }
    }

    Context 'when nothing answers - one case per failure path, with the failure forced' {
        It 'reports unknown with no percentage when quota-axi is not installed' {
            Mock -ModuleName Usage Invoke-QuotaAxi { New-AxiFail 'quota-axi was not found.' }

            $r = Get-UsageWindow
            $r.status  | Should -Be 'unknown'
            $r.signal  | Should -Be 'lookup-failed'
            $r.percent | Should -BeNullOrEmpty
            $r.detail  | Should -BeLike '*quota-axi was not found*' -Because 'the reader must see which failure it was'
        }

        It 'reports unknown when the answer is not the JSON it reads' {
            Mock -ModuleName Usage Invoke-QuotaAxi { New-AxiOk 'quota-axi: something went wrong' }

            $r = Get-UsageWindow
            $r.status  | Should -Be 'unknown'
            $r.signal  | Should -Be 'unreadable-answer'
            $r.percent | Should -BeNullOrEmpty
        }

        It 'reports unknown when the answer says nothing about this account' {
            Mock -ModuleName Usage Invoke-QuotaAxi { New-AxiOk (New-AxiReport -Provider 'codex') }

            $r = Get-UsageWindow
            $r.status  | Should -Be 'unknown'
            $r.signal  | Should -Be 'no-provider'
            $r.percent | Should -BeNullOrEmpty
        }

        # A stale reading describes an earlier moment. Presenting it as current is the exact
        # fabrication that would wave through a dispatch near the limit: an old low percentage.
        It 'refuses a reading the tool itself calls stale, rather than passing it off as current' {
            Mock -ModuleName Usage Invoke-QuotaAxi {
                New-AxiOk (New-AxiReport -FiveHourPercent 4 -Stale $true)
            }

            $r = Get-UsageWindow
            $r.status  | Should -Be 'unknown'
            $r.signal  | Should -Be 'stale-reading'
            $r.percent | Should -BeNullOrEmpty
        }

        # THE MEASURED FAILURE THIS WHOLE BRANCH EXISTS FOR. The tool answered 10 percent from a
        # cache taken before four workers ran for ninety minutes; the true figure was 42. Its live
        # fetch had been rate limited, and the reading looked exactly like a current one.
        It 'keeps the cached number as a floor rather than as the answer' {
            Mock -ModuleName Usage Invoke-QuotaAxi {
                New-AxiOk (New-AxiReport -FiveHourPercent 10 -Stale $true)
            }

            $r = Get-UsageWindow
            $r.status       | Should -Be 'unknown' -Because 'a stale reading is never a number'
            $r.percent      | Should -BeNullOrEmpty
            $r.floorPercent | Should -Be 10
            $r.stale        | Should -BeTrue
            $r.detail       | Should -BeLike '*At least 10 percent*'
            $r.detail       | Should -BeLike '*floor rather than a reading*'
        }

        # A FLOOR IS SHOWN ROUNDED DOWN, WHICH IS WHAT KEEPS "AT LEAST" TRUE. At a real 89.2 the
        # sentence "at least 90 percent is spent" asserts a percentage point the reading never
        # measured. Nothing is guarded by these digits: the dispatch refusal compares the raw
        # floorPercent against the threshold, so understating the shown figure cannot let work
        # through - Dispatch-Worker.Tests.ps1 pins that comparison from the other end.
        It 'rounds a floor down, never up, so "at least" claims only what was measured' {
            Mock -ModuleName Usage Invoke-QuotaAxi {
                New-AxiOk (New-AxiReport -FiveHourPercent 89.2 -Stale $true)
            }

            $r = Get-UsageWindow
            $r.detail       | Should -BeLike '*At least 89 percent*'
            $r.detail       | Should -Not -BeLike '*At least 90 percent*'
            $r.floorPercent | Should -Be 89.2 -Because 'the exact figure is what the refusal compares'
        }

        # The refusal this detail is pasted into ends by telling the user to wait for the window,
        # and on this machine the floor refusal is the one that fires most - the tool's live fetch
        # is rate limited most of the time. A refusal that does not say when the window clears
        # leaves out the one thing wanted next.
        It 'says when the window resets on a stale floor, not just on a measured reading' {
            Mock -ModuleName Usage Invoke-QuotaAxi {
                New-AxiOk (New-AxiReport -FiveHourPercent 95 -Stale $true)
            }

            (Get-UsageWindow).detail | Should -BeLike '*It resets at *'
        }

        It 'surfaces when the tool generated the answer, so a cached one is visibly cached' {
            Mock -ModuleName Usage Invoke-QuotaAxi {
                New-AxiOk (New-AxiReport -FiveHourPercent 10 -Stale $true)
            }

            $r = Get-UsageWindow
            $r.generatedAt | Should -Not -BeNullOrEmpty
            $r.detail      | Should -BeLike '*generated at*'
        }

        # A failed refresh is a normal condition here - the quota endpoint rate limits by design -
        # so the reason travels with the reading rather than being escalated as an error.
        It 'carries the reason the tool could not refresh' {
            Mock -ModuleName Usage Invoke-QuotaAxi {
                New-AxiOk (New-AxiReport -FiveHourPercent 10 -Stale $true `
                                         -StateError 'Claude quota endpoint rate limited')
            }

            (Get-UsageWindow).detail | Should -BeLike '*rate limited*'
        }

        # A stale reading with no applicable window gives no floor either, and must not invent one.
        # The window here has genuinely rolled, which is the one thing still discarded.
        It 'gives no floor when the stale answer has no applicable window' {
            Mock -ModuleName Usage Invoke-QuotaAxi {
                New-AxiOk (New-AxiReport -FiveHourPercent 10 -Stale $true `
                                         -FiveHourResets ([datetimeoffset]::UtcNow.AddHours(-1).ToString('o')))
            }

            $r = Get-UsageWindow
            $r.status       | Should -Be 'unknown'
            $r.floorPercent | Should -BeNullOrEmpty
        }

        # The floor is the only guard there is while the tool's live fetch is rate limited, so a
        # missing reset time must not take it away as well - that would leave the dispatch with
        # nothing at all, from a reading that carried a perfectly good number.
        It 'still gives a floor when a stale window reports a percentage with no reset time' {
            Mock -ModuleName Usage Invoke-QuotaAxi {
                New-AxiOk (New-AxiReport -FiveHourPercent 95 -Stale $true -FiveHourResets '')
            }

            $r = Get-UsageWindow
            $r.status       | Should -Be 'unknown'
            $r.floorPercent | Should -Be 95
            $r.detail       | Should -BeLike '*At least 95 percent*'
            $r.detail       | Should -BeLike '*no reset time this could read*'
        }

        It 'reports unknown when windows are there and no percentage can be read from any of them' {
            Mock -ModuleName Usage Invoke-QuotaAxi {
                @{ providers = @(@{ provider = 'claude'
                                    windows  = @(@{ id = 'five_hour' })
                                    state    = @{ stale = $false } }) } |
                    ConvertTo-Json -Depth 8 | ForEach-Object { New-AxiOk $_ }
            }

            $r = Get-UsageWindow
            $r.status  | Should -Be 'unknown'
            $r.signal  | Should -Be 'no-percentage' -Because 'the window applies; it is the number that is missing'
            $r.percent | Should -BeNullOrEmpty
            $r.detail  | Should -BeLike '*session window reported a used percentage this could not read*'
        }

        # The third answer, and the one that must not be collapsed into either of the others. An
        # account that genuinely reports no windows is a settled fact about this machine, not a
        # lookup that failed - and the dispatch refusal treats the two differently.
        It 'settles on no-usage when the account reports no windows at all' {
            Mock -ModuleName Usage Invoke-QuotaAxi { New-AxiOk (New-AxiReport -NoWindows) }

            $r = Get-UsageWindow
            $r.status  | Should -Be 'no-usage'
            $r.signal  | Should -Be 'no-windows'
            $r.percent | Should -BeNullOrEmpty
        }

        # `@($null)` is an array of one, so a field written as `null` used to arrive looking like a
        # window that exists and then failed every test of what was in it - which fell through to
        # the wrong answer rather than to an answer at all.
        It 'reads a null window list as none rather than as one phantom window' {
            Mock -ModuleName Usage Invoke-QuotaAxi { New-AxiOk (New-AxiProviderJson '"windows": null') }

            $r = Get-UsageWindow
            $r.status  | Should -Be 'unknown'
            $r.percent | Should -BeNullOrEmpty
        }

        It 'never reports zero percent as a stand-in for not knowing' {
            foreach ($reply in @(
                { New-AxiFail },
                { New-AxiOk 'not json' },
                { New-AxiOk (New-AxiReport -Stale $true) },
                { New-AxiOk (New-AxiReport -NoWindows) }
            )) {
                Mock -ModuleName Usage Invoke-QuotaAxi $reply
                $r = Get-UsageWindow
                $r.status  | Should -Not -Be 'has-usage'
                $r.percent | Should -BeNullOrEmpty -Because 'a fabricated 0 reads as a wide open window'
            }
        }
    }

    Context 'what the tool said about windows, told apart from what it did not say' {
        # THREE FACTS THAT USED TO COLLAPSE INTO ONE, and only one of them is settled. `no-usage` is
        # the single answer that neither refuses a dispatch nor warns on one, so reading "the tool
        # never mentioned windows" as "there are none here" switches the guard off on every dispatch
        # from then on and tells nobody. A field the tool renamed is exactly how that would arrive.

        It 'settles on no-usage only where the tool affirmatively lists none' {
            Mock -ModuleName Usage Invoke-QuotaAxi { New-AxiOk (New-AxiProviderJson '"windows": []') }

            $r = Get-UsageWindow
            $r.status | Should -Be 'no-usage'
            $r.signal | Should -Be 'no-windows'
        }

        It 'reports unknown when the windows field is not in the answer at all' {
            Mock -ModuleName Usage Invoke-QuotaAxi { New-AxiOk (New-AxiProviderJson '') }

            $r = Get-UsageWindow
            $r.status  | Should -Be 'unknown'
            $r.signal  | Should -Be 'no-windows-field'
            $r.percent | Should -BeNullOrEmpty
        }

        It 'reports unknown when the windows field is there and says nothing' {
            Mock -ModuleName Usage Invoke-QuotaAxi { New-AxiOk (New-AxiProviderJson '"windows": null') }

            $r = Get-UsageWindow
            $r.status  | Should -Be 'unknown'
            $r.signal  | Should -Be 'windows-not-reported'
            $r.percent | Should -BeNullOrEmpty
        }

        # The consequence, in the words the King reads. `usage unknown` is the one that says the
        # question could not be settled; `usage not reported here` is a fact about the machine, and
        # a reader shown it for a renamed field would never look again.
        It 'says the usage is unknown rather than that this machine reports none' {
            Mock -ModuleName Usage Invoke-QuotaAxi { New-AxiOk (New-AxiProviderJson '') }
            Mock -ModuleName Usage Get-UsageFleet { @() }

            Get-UsagePulse | Should -Be 'usage unknown - nothing running'
        }
    }

    Context 'the schema the answer was stamped with' {
        # Recorded so a later reader can see which format produced an answer this could not use,
        # and never compared against a version this was written for: a compatible bump must not
        # take the reader out on a machine where it worked the day before.

        It 'carries the version the tool stamped on its answer' {
            Mock -ModuleName Usage Invoke-QuotaAxi { New-AxiOk (New-AxiReport -SchemaVersion 3) }
            (Get-UsageWindow).schemaVersion | Should -Be '3'
        }

        It 'reads an answer stamped with a version it has never seen rather than refusing it' {
            Mock -ModuleName Usage Invoke-QuotaAxi {
                New-AxiOk (New-AxiReport -SchemaVersion 99)
            }

            $r = Get-UsageWindow
            $r.status        | Should -Be 'has-usage'
            $r.percent       | Should -Be 4
            $r.schemaVersion | Should -Be '99'
        }

        It 'names the version in the detail of an answer that is not a percentage' {
            Mock -ModuleName Usage Invoke-QuotaAxi {
                New-AxiOk (New-AxiProviderJson '' -Schema '"schemaVersion": 7, ')
            }

            $r = Get-UsageWindow
            $r.schemaVersion | Should -Be '7'
            $r.detail        | Should -BeLike '*schema version 7*'
        }

        It 'says the answer carried no version rather than inventing one' {
            Mock -ModuleName Usage Invoke-QuotaAxi {
                New-AxiOk (New-AxiProviderJson '"windows": []' -Schema '')
            }

            $r = Get-UsageWindow
            $r.status        | Should -Be 'no-usage'
            $r.schemaVersion | Should -Be ''
            $r.detail        | Should -BeLike '*no schema version*'
        }
    }

    Context 'when the answer is malformed - the guard fails open and never throws' {
        # THE FAILURE THESE PIN. Dispatch-Worker.ps1 calls Get-UsageWindow as the first check of a
        # dispatch, under $ErrorActionPreference = 'Stop'. An exception out of the reader therefore
        # does not degrade to a warning - it stops the dispatch outright, which turns a guard
        # written to fail OPEN into the hard block the design rules out. A reading nobody could
        # take must come back as `unknown`, whatever it was that could not be read.

        # The word goes on the field the reader actually consumes - the window's own percentUsed -
        # so this reproduces the failure its name claims. The other account window still answers,
        # which is the tolerance being demonstrated, and the one that could not be read is named
        # rather than quietly skipped.
        It 'reads a percentage the tool wrote as a word as no percentage, not as an error' {
            Mock -ModuleName Usage Invoke-QuotaAxi {
                New-AxiOk (New-AxiReport -FiveHourPercent 'plenty' -WithSevenDay)
            }

            { Get-UsageWindow } | Should -Not -Throw

            $r = Get-UsageWindow
            $r.status  | Should -Be 'has-usage' -Because 'the weekly window still answered'
            $r.signal  | Should -Be 'driving-window'
            $r.percent | Should -Be 61
            $r.window  | Should -Be 'seven_day'
            $r.detail  | Should -BeLike '*session window reported a used percentage this could not read*'
        }

        It 'settles on unknown when no window carries a percentage that is a number' {
            Mock -ModuleName Usage Invoke-QuotaAxi {
                New-AxiOk (New-AxiReport -FiveHourPercent 'lots')
            }

            $r = Get-UsageWindow
            $r.status  | Should -Be 'unknown'
            $r.signal  | Should -Be 'no-percentage'
            $r.percent | Should -BeNullOrEmpty
        }

        It 'never reads a true as one percent spent' {
            Mock -ModuleName Usage Invoke-QuotaAxi {
                New-AxiOk (New-AxiReport -FiveHourPercent $true)
            }

            $r = Get-UsageWindow
            $r.status  | Should -Be 'unknown'
            $r.percent | Should -BeNullOrEmpty
        }

        # The catch-all, tested by making the one boundary itself fail in a way nothing below
        # anticipates. Whatever breaks in there, the dispatch gets an answer rather than a throw.
        It 'answers unknown rather than throwing when the boundary itself fails unexpectedly' {
            Mock -ModuleName Usage Invoke-QuotaAxi { throw 'the temp directory is gone' }

            { Get-UsageWindow } | Should -Not -Throw

            $r = Get-UsageWindow
            $r.status  | Should -Be 'unknown'
            $r.signal  | Should -Be 'lookup-failed'
            $r.percent | Should -BeNullOrEmpty
            $r.window  | Should -Be ''
            $r.detail  | Should -BeLike '*the temp directory is gone*'
        }
    }
}

Describe 'A number that is not one is no number, and never a percentage' {
    It 'reads the numbers a JSON report actually carries' {
        ConvertTo-UsageNumber 4      | Should -Be 4
        ConvertTo-UsageNumber 96.5   | Should -Be 96.5
        ConvertTo-UsageNumber '37.5' | Should -Be 37.5
        ConvertTo-UsageNumber 0      | Should -Be 0
    }

    It 'refuses everything a percentage cannot be, rather than throwing on it' {
        foreach ($v in @($null, '', '   ', 'plenty', $true, $false, @(1, 2), @{ a = 1 },
                         'NaN', 'Infinity')) {
            ConvertTo-UsageNumber $v | Should -BeNullOrEmpty
        }
    }
}

Describe 'A timestamp carries its offset, and is never read as local' {
    # THE FAILURE THIS PINS COST A MEASURED RUN ELSEWHERE. Timestamps in this toolchain are UTC, and
    # reading one as if it were local time fails SILENTLY - it does not throw, it just describes a
    # different moment. In the run that found it, a UTC timestamp compared against a local cutoff
    # returned zero rows, which looks exactly like no usage at all.
    #
    # This module's own exposure to it is the reset time, so that is where it is tested: the same
    # instant written in two offsets must come back as one instant, not two.

    It 'reads one instant written in two offsets as the same instant' {
        $utc   = ConvertTo-UsageResetTime '2026-09-05T22:20:00+00:00'
        $other = ConvertTo-UsageResetTime '2026-09-06T03:50:00+05:30'
        ([datetimeoffset]$utc).UtcDateTime | Should -Be ([datetimeoffset]$other).UtcDateTime
    }

    It 'keeps the offset rather than pinning a bare time to whatever zone the machine is in' {
        $iso = ConvertTo-UsageResetTime '2026-09-05T22:20:00+00:00'
        ([datetimeoffset]$iso).UtcDateTime |
            Should -Be ([datetime]::SpecifyKind([datetime]'2026-09-05T22:20:00', 'Utc'))
    }

    It 'says the time to a person in their own zone, from that same instant' {
        $expected = ([datetimeoffset]'2026-09-05T22:20:00+00:00').ToLocalTime().ToString('HH:mm')
        Format-UsageResetTime -IsoTime (ConvertTo-UsageResetTime '2026-09-05T22:20:00+00:00') |
            Should -BeLike "*$expected local time*"
    }

    It 'says nothing at all rather than a wrong time when it cannot be read' {
        Format-UsageResetTime -IsoTime 'whenever' | Should -Be ''
        ConvertTo-UsageResetTime 'whenever'       | Should -Be ''
    }

    # THE SENTENCE THE USER ACTS ON. This is pasted into the dispatch refusal right before "Wait
    # for the window to reset", and the limiting window is not always the five-hour one - a weekly
    # window six days out used to read as a bare "10:00", so the reader waited for this morning and
    # found the window still spent. Nothing errored and no number was wrong, only the sentence.
    It 'says the day as well when the window does not reset today' {
        $days = (Get-Date).Date.AddDays(6).AddHours(10)
        $s = Format-UsageResetTime -IsoTime (([datetimeoffset]$days).ToString('o'))

        $s | Should -BeLike '*10:00 local time*'
        $s | Should -BeLike "*$($days.ToString('MMM'))*" -Because 'the reader has to see which day'
        $s | Should -Not -Be (Format-UsageResetTime `
                -IsoTime (([datetimeoffset]((Get-Date).Date.AddHours(10))).ToString('o')))
    }

    # Decided against the local day rather than a number of hours out, so a reset a few hours from
    # now that lands after midnight still says which day it lands on.
    It 'says the day for a reset that is hours away but on tomorrow' {
        $tomorrow = (Get-Date).Date.AddDays(1).AddHours(1)
        Format-UsageResetTime -IsoTime (([datetimeoffset]$tomorrow).ToString('o')) |
            Should -BeLike '*01:00 local time on *'
    }

    # Shortest in the common case: the five-hour window always resets inside the day, and a date
    # there is noise in a line that is read out loud.
    It 'says only the time when the window resets later today' {
        $today = (Get-Date).Date.AddHours(23).AddMinutes(15)
        $s = Format-UsageResetTime -IsoTime (([datetimeoffset]$today).ToString('o'))

        $s | Should -Be ' It resets at 23:15 local time.'
    }

    # End to end, because the refusal quotes `detail` verbatim and that is where it reached a
    # person. Dated from now rather than from a fixture literal, so this keeps testing what it says
    # it tests as the calendar moves.
    It 'carries the day into the detail a refusal quotes' {
        $days = (Get-Date).Date.AddDays(6).AddHours(10)
        Mock -ModuleName Usage Invoke-QuotaAxi {
            New-AxiOk (New-AxiReport -FiveHourResets (([datetimeoffset]$days).ToString('o')))
        }

        $r = Get-UsageWindow
        $r.status | Should -Be 'has-usage'
        $r.detail | Should -BeLike "*10:00 local time on *$($days.ToString('MMM'))*"
    }
}

Describe 'Which account the reading belongs to' {
    # The reading follows whichever account is active, and on this machine that is swapped by a
    # script of the King's own - so a percentage with no name on it is one the reader cannot place.
    # Everything here reads ONE FILE HOLDING ONE WORD. No credential file is opened, and the
    # fixtures below deliberately put one beside it to prove nothing goes near it.
    # Defined in BeforeAll, not in the Describe body. A Describe body runs at discovery, so a
    # function declared there does not exist when the cases actually run.
    BeforeAll {
        $script:SavedProfile = $env:USERPROFILE

        function New-AccountsHome {
            param([string]$Active, [switch]$NoActiveFile, [string]$ActiveText)
            $root = New-TempFixtureDir -Prefix 'usage-home-'
            $dir  = Join-Path $root '.claude\accounts'
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
            # A credential file, present exactly so the tests can show it is never read.
            '{ "accessToken": "SECRET-TOKEN-MARKER", "refreshToken": "SECRET-REFRESH-MARKER" }' |
                Set-Content -LiteralPath (Join-Path $dir 'personal.json') -Encoding utf8
            if (-not $NoActiveFile) {
                $text = if ($PSBoundParameters.ContainsKey('ActiveText')) { $ActiveText } else { $Active }
                Set-Content -LiteralPath (Join-Path $dir '.active') -Value $text -Encoding utf8
            }
            $env:USERPROFILE = $root
            $root
        }
    }
    AfterAll { $env:USERPROFILE = $script:SavedProfile }

    It 'reads the active account name' {
        New-AccountsHome -Active 'personal' | Out-Null
        Get-ActiveAccountName | Should -Be 'personal'
    }

    It 'reads no account rather than failing when there is no such file' {
        New-AccountsHome -NoActiveFile | Out-Null
        Get-ActiveAccountName | Should -Be ''
    }

    # Whatever is in that file goes into a line the King reads, so it is vouched for or dropped.
    It 'reports no account rather than passing through text that is not a name' {
        New-AccountsHome -ActiveText "not a name`nwith a newline" | Out-Null
        Get-ActiveAccountName | Should -Be ''
    }

    It 'never reads anything out of a credential file' {
        New-AccountsHome -Active 'personal' | Out-Null
        Mock -ModuleName Usage Invoke-QuotaAxi { New-AxiOk (New-AxiReport -FiveHourPercent 4) }

        $r = Get-UsageWindow
        $r.account | Should -Be 'personal'
        ($r | ConvertTo-Json -Depth 6) | Should -Not -BeLike '*SECRET-TOKEN-MARKER*'
        ($r | ConvertTo-Json -Depth 6) | Should -Not -BeLike '*SECRET-REFRESH-MARKER*'
    }
}

Describe 'The launchable quota-axi, and why a .ps1 is never it' {
    BeforeAll { $script:SavedPath = $env:PATH }
    AfterAll  { $env:PATH = $script:SavedPath }

    # npm installs a .ps1 alongside the .cmd, and a native launch of a .ps1 dies with
    # "%1 is not a valid Win32 application" - the same failure Paths.psm1 records for Claude Code.
    It 'prefers a launchable wrapper over the PowerShell script npm installs beside it' {
        $dir = New-TempFixtureDir -Prefix 'quota-shim-'
        Set-Content -Path (Join-Path $dir 'quota-axi.ps1') -Value 'exit 0' -Encoding ascii
        Set-Content -Path (Join-Path $dir 'quota-axi.cmd') -Value '@echo off' -Encoding ascii
        $env:PATH = $dir + [IO.Path]::PathSeparator + $script:SavedPath

        $p = Get-QuotaAxiCommandPath
        $p | Should -BeLike '*quota-axi.cmd'
        $p | Should -Not -BeLike '*.ps1'
    }

    It 'reports nothing rather than a script it cannot start' {
        $dir = New-TempFixtureDir -Prefix 'quota-shim-'
        Set-Content -Path (Join-Path $dir 'quota-axi.ps1') -Value 'exit 0' -Encoding ascii
        $env:PATH = $dir

        Get-QuotaAxiCommandPath | Should -BeNullOrEmpty
    }

    It 'names the install command when it is missing, rather than failing silently' {
        $env:PATH = New-TempFixtureDir -Prefix 'quota-empty-'
        $r = Invoke-QuotaAxi -Arguments @('--json')
        $r.ok    | Should -BeFalse
        $r.error | Should -BeLike '*npm install -g quota-axi*'
    }

    # This function promises it never throws, and the whole fail-open guard rests on that promise.
    # The scratch files it redirects the tool's output into were created above the try, so a temp
    # directory that is not there took the promise with it - and the exception surfaced inside a
    # dispatch running under ErrorActionPreference Stop.
    It 'reports a temp directory it cannot use rather than throwing out of the boundary' {
        $shim = New-TempFixtureDir -Prefix 'quota-shim-'
        Set-Content -Path (Join-Path $shim 'quota-axi.cmd') -Value '@echo off' -Encoding ascii
        $gone = Join-Path (New-TempFixtureDir -Prefix 'quota-notemp-') 'no-such-directory'

        $savedTmp  = $env:TMP
        $savedTemp = $env:TEMP
        try {
            $env:PATH = $shim + [IO.Path]::PathSeparator + $script:SavedPath
            $env:TMP  = $gone
            $env:TEMP = $gone

            $r = $null
            { $script:NoTempResult = Invoke-QuotaAxi -Arguments @('--json') } | Should -Not -Throw
            $r = $script:NoTempResult
            $r.ok    | Should -BeFalse
            $r.error | Should -BeLike '*quota-axi could not be run*'
        } finally {
            $env:TMP  = $savedTmp
            $env:TEMP = $savedTemp
        }
    }
}

Describe 'The pulse is one line, and it says nothing when nothing has changed' {
    BeforeEach {
        Mock -ModuleName Usage Get-UsageWindow {
            [pscustomobject]@{ status = 'has-usage'; signal = 'effective-availability'
                               percent = 62; detail = 'x'; resetsAt = ''; window = 'five_hour'
                               takenAt = '2026-09-05T00:00:00.0000000Z' }
        }
        Mock -ModuleName Usage Get-UsageFleet { @() }

        # The baseline the pulse compares against is one variable inside the module, living for the
        # life of the process - so each case starts from a pulse that has never spoken, the way a
        # freshly armed job does.
        InModuleScope Usage { $script:LastSpoken = $null }
    }

    # The account is named beside the percentage because the reading silently follows whichever one
    # is active, and a number with no pool attached is one the reader cannot place.
    It 'names the account beside the percentage' {
        Mock -ModuleName Usage Get-UsageWindow {
            [pscustomobject]@{ status = 'has-usage'; signal = 'driving-window'; percent = 62
                               floorPercent = $null; stale = $false; detail = 'x'; resetsAt = ''
                               window = 'seven_day'; account = 'personal'; generatedAt = ''
                               schemaVersion = '3'; takenAt = 'now' }
        }
        Get-UsagePulse | Should -Be '62% used (week, personal) - nothing running'
    }

    # TWO READINGS EITHER SIDE OF A SWITCH ARE PERCENTAGES OF TWO DIFFERENT POOLS. Silence would
    # say they were one quota sitting still, so a change of account is always worth a line.
    It 'speaks again when the account changed, even with the same number and fleet' {
        $reading = {
            param($account)
            [pscustomobject]@{ status = 'has-usage'; signal = 'driving-window'; percent = 62
                               floorPercent = $null; stale = $false; detail = 'x'; resetsAt = ''
                               window = 'five_hour'; account = $account; generatedAt = ''
                               schemaVersion = '3'; takenAt = 'now' }
        }
        Mock -ModuleName Usage Get-UsageWindow { & $reading 'personal' }
        Get-UsagePulse | Should -Be '62% used (session, personal) - nothing running'
        Get-UsagePulse | Should -BeNullOrEmpty -Because 'nothing moved within that account'

        Mock -ModuleName Usage Get-UsageWindow { & $reading 'office' }
        Get-UsagePulse | Should -Be '62% used (session, office) - nothing running'
    }

    # A floor is never printed as a bare percentage, because a bare percentage reads as a
    # measurement - which is exactly how a cached 10 was taken for a current one. It is rounded
    # DOWN, so "at least" claims only what the cached reading actually measured: at a true 41.2,
    # "at least 42%" would assert a point nobody measured. No guard rests on the printed digits.
    It 'says a floor as a floor, rounded down, and marks it stale' {
        Mock -ModuleName Usage Get-UsageWindow {
            [pscustomobject]@{ status = 'unknown'; signal = 'stale-reading'; percent = $null
                               floorPercent = 41.2; stale = $true; detail = 'x'; resetsAt = ''
                               window = 'five_hour'; account = 'personal'; generatedAt = ''
                               schemaVersion = '3'; takenAt = 'now' }
        }
        Get-UsagePulse | Should -Be 'at least 41% used (stale, session, personal) - nothing running'
    }

    # The same number decaying from a measurement into a floor is a change worth saying, because
    # what the reader can rely on has changed even though the digits have not.
    It 'speaks when a reading decays into a floor at the same number' {
        Mock -ModuleName Usage Get-UsageWindow {
            [pscustomobject]@{ status = 'has-usage'; signal = 'driving-window'; percent = 40
                               floorPercent = $null; stale = $false; detail = 'x'; resetsAt = ''
                               window = 'five_hour'; account = 'a'; generatedAt = ''
                               schemaVersion = '3'; takenAt = 'now' }
        }
        Get-UsagePulse | Should -Be '40% used (session, a) - nothing running'

        Mock -ModuleName Usage Get-UsageWindow {
            [pscustomobject]@{ status = 'unknown'; signal = 'stale-reading'; percent = $null
                               floorPercent = 40; stale = $true; detail = 'x'; resetsAt = ''
                               window = 'five_hour'; account = 'a'; generatedAt = ''
                               schemaVersion = '3'; takenAt = 'now' }
        }
        Get-UsagePulse | Should -Be 'at least 40% used (stale, session, a) - nothing running'
    }

    # The same 62 percent, session one tick and week the next, is a different fact about what is
    # about to run out.
    It 'speaks when the driving window changes at the same percentage' {
        Mock -ModuleName Usage Get-UsageWindow {
            [pscustomobject]@{ status = 'has-usage'; signal = 'driving-window'; percent = 62
                               floorPercent = $null; stale = $false; detail = 'x'; resetsAt = ''
                               window = 'five_hour'; account = 'a'; generatedAt = ''
                               schemaVersion = '3'; takenAt = 'now' }
        }
        Get-UsagePulse | Should -BeLike '*(session, a)*'

        Mock -ModuleName Usage Get-UsageWindow {
            [pscustomobject]@{ status = 'has-usage'; signal = 'driving-window'; percent = 62
                               floorPercent = $null; stale = $false; detail = 'x'; resetsAt = ''
                               window = 'seven_day'; account = 'a'; generatedAt = ''
                               schemaVersion = '3'; takenAt = 'now' }
        }
        Get-UsagePulse | Should -BeLike '*(week, a)*'
    }

    It 'names the percentage, the count and what each worker is doing' {
        Mock -ModuleName Usage Get-UsageFleet {
            @((New-FleetRow -Ticket 'kh-usage-watch' -Stage 'gating'),
              (New-FleetRow -Ticket 'emgee-seo'      -Stage 'ready'))
        }

        Get-UsagePulse |
            Should -Be '62% used (session) - 2 running: kh-usage-watch running checks, emgee-seo waiting on you'
    }

    # ONE LINE, hard cap, however many workers are live. A second line is the thing the King ruled
    # out in as many words, and a pulse that wraps is a pulse he has to read twice.
    It 'stays on one line and summarises the tail as a count' {
        Mock -ModuleName Usage Get-UsageFleet {
            @(1..6 | ForEach-Object { New-FleetRow -Ticket "task-$_" })
        }

        $line = Get-UsagePulse
        $line | Should -Not -BeNullOrEmpty
        $line.Contains("`n") | Should -BeFalse -Because 'the pulse is one line, hard cap'
        $line.Contains("`r") | Should -BeFalse -Because 'the pulse is one line, hard cap'
        $line | Should -BeLike '*6 running:*'
        $line | Should -BeLike '*+3 more'
    }

    It 'stays on one line when a worker name carries a newline' {
        Mock -ModuleName Usage Get-UsageFleet { @(New-FleetRow -Ticket "one`ntwo") }

        $line = Get-UsagePulse
        $line.Contains("`n") | Should -BeFalse
    }

    It 'counts only the workers that are actually live' {
        Mock -ModuleName Usage Get-UsageFleet {
            @((New-FleetRow -Ticket 'live-one'), (New-FleetRow -Ticket 'gone' -Live $false))
        }

        Get-UsagePulse | Should -BeLike '*1 running: live-one*'
    }

    It 'says so when there is nothing running' {
        Get-UsagePulse | Should -Be '62% used (session) - nothing running'
    }

    # A line every interval regardless is the progress narration hard rule 6 forbids, and the King
    # asked for this so he would not have to ask for updates - not so he would get a heartbeat.
    It 'says nothing at all on a second tick with nothing moved' {
        Get-UsagePulse | Should -Not -BeNullOrEmpty
        Get-UsagePulse | Should -BeNullOrEmpty
    }

    It 'speaks again when a worker changes what it is doing' {
        Mock -ModuleName Usage Get-UsageFleet { @(New-FleetRow -Ticket 'kh' -Stage 'implementing') }
        Get-UsagePulse | Should -BeLike '*kh working*'

        Mock -ModuleName Usage Get-UsageFleet { @(New-FleetRow -Ticket 'kh' -Stage 'gating') }
        Get-UsagePulse | Should -BeLike '*kh running checks*'
    }

    It 'stays quiet on a percentage that moves inside its band, and speaks when it crosses one' {
        Get-UsagePulse | Should -Not -BeNullOrEmpty

        Mock -ModuleName Usage Get-UsageWindow {
            [pscustomobject]@{ status = 'has-usage'; signal = 's'; percent = 67; detail = 'x'
                               resetsAt = ''; window = 'five_hour'; takenAt = 'now' }
        }
        Get-UsagePulse | Should -BeNullOrEmpty

        Mock -ModuleName Usage Get-UsageWindow {
            [pscustomobject]@{ status = 'has-usage'; signal = 's'; percent = 71; detail = 'x'
                               resetsAt = ''; window = 'five_hour'; takenAt = 'now' }
        }
        Get-UsagePulse | Should -Be '71% used (session) - nothing running'
    }

    # THE SAME SENTENCE TWICE IS NOT A CHANGE. The band that decides whether the pulse speaks and
    # the number it prints used to round differently - the band floored the raw percentage and the
    # line rounded it - so 69.6 printed "70% used" in band b6 and 70.2 printed "70% used" again in
    # band b7, for a change the reader could not see anywhere in the line.
    It 'never prints the identical line twice for a number that has not moved' {
        Mock -ModuleName Usage Get-UsageWindow {
            [pscustomobject]@{ status = 'has-usage'; signal = 's'; percent = 69.6; detail = 'x'
                               resetsAt = ''; window = 'five_hour'; takenAt = 'now' }
        }
        Get-UsagePulse | Should -Be '70% used (session) - nothing running'

        Mock -ModuleName Usage Get-UsageWindow {
            [pscustomobject]@{ status = 'has-usage'; signal = 's'; percent = 70.2; detail = 'x'
                               resetsAt = ''; window = 'five_hour'; takenAt = 'now' }
        }
        Get-UsagePulse | Should -BeNullOrEmpty
    }

    It 'still speaks when the number it prints crosses into the next ten' {
        Mock -ModuleName Usage Get-UsageWindow {
            [pscustomobject]@{ status = 'has-usage'; signal = 's'; percent = 69.2; detail = 'x'
                               resetsAt = ''; window = 'five_hour'; takenAt = 'now' }
        }
        Get-UsagePulse | Should -Be '69% used (session) - nothing running'

        Mock -ModuleName Usage Get-UsageWindow {
            [pscustomobject]@{ status = 'has-usage'; signal = 's'; percent = 70.2; detail = 'x'
                               resetsAt = ''; window = 'five_hour'; takenAt = 'now' }
        }
        Get-UsagePulse | Should -Be '70% used (session) - nothing running'
    }

    # Losing the number is itself a change worth one line. Reported as the same silence as
    # "nothing happened", a reader could not tell a quiet fleet from a broken reader.
    It 'says the usage is unknown rather than inventing one, and speaks when the reading is lost' {
        Get-UsagePulse | Should -Not -BeNullOrEmpty

        Mock -ModuleName Usage Get-UsageWindow {
            [pscustomobject]@{ status = 'unknown'; signal = 'lookup-failed'; percent = $null
                               detail = 'x'; resetsAt = ''; window = ''; takenAt = 'now' }
        }
        $line = Get-UsagePulse
        $line | Should -Be 'usage unknown - nothing running'
        $line | Should -Not -BeLike '*0%*'
    }

    It 'says a phase it cannot work out rather than guessing at one' {
        Mock -ModuleName Usage Get-UsageFleet {
            @(New-FleetRow -Ticket 'odd' -Stage 'something-nobody-recognises')
        }
        Get-UsagePulse | Should -BeLike '*odd phase not known*'
    }

    It 'says a worker is stuck on a question whatever stage it was recorded at' {
        Mock -ModuleName Usage Get-UsageFleet {
            @(New-FleetRow -Ticket 'kh' -Stage 'implementing' -AgentState 'blocked')
        }
        Get-UsagePulse | Should -BeLike '*kh stuck on a question*'
    }

    It 'falls back to the worker id where there is no ticket to name' {
        Mock -ModuleName Usage Get-UsageFleet {
            @(New-FleetRow -Ticket '' -Id 'T-9001' -Stage 'implementing')
        }
        Get-UsagePulse | Should -BeLike '*T-9001 working*'
    }

    # THE PULSE KEEPS NOTHING ON DISK, and that is the property this pins rather than a detail of
    # how it remembers. A record living in state\ was the whole of a data-loss hazard - it sits
    # beside crew.json, and the guard that stopped a mistyped path replacing the fleet read a
    # half-written crew.json as a half-written record of its own and overwrote it. There is nothing
    # left to mistype: the baseline is a variable, and every tick below leaves the installation's
    # own directory exactly as empty as it found it.
    It 'writes nothing anywhere, however many times it pulses' {
        $root  = New-TempFixtureDir -Prefix 'usage-home-'
        $saved = $env:KINGSHAND_HOME
        try {
            $env:KINGSHAND_HOME = $root
            Get-UsagePulse | Should -Not -BeNullOrEmpty
            Get-UsagePulse | Should -BeNullOrEmpty
            Get-UsagePulse | Should -BeNullOrEmpty

            @(Get-ChildItem -LiteralPath $root -Recurse -Force).Count |
                Should -Be 0 -Because 'the pulse has no on-disk store at all'
        } finally {
            $env:KINGSHAND_HOME = $saved
        }
    }
}

Describe 'The pulse takes the fleet from the reader that already joins intent to liveness' {
    # No -Fleet seam here on purpose: this is the caller path the documented background job takes,
    # so it runs the real Get-CrewStatus.ps1 against a crew record of its own. An empty one asks
    # herdr nothing, which is what keeps this case free of an external dependency.
    It 'runs the crew reader itself when nothing hands it a fleet' {
        Mock -ModuleName Usage Get-UsageWindow {
            [pscustomobject]@{ status = 'has-usage'; signal = 's'; percent = 5; detail = 'x'
                               resetsAt = ''; window = 'five_hour'; takenAt = 'now' }
        }
        InModuleScope Usage { $script:LastSpoken = $null }
        $dir = New-TempFixtureDir
        $crew = Join-Path $dir 'crew.json'
        '{ "workers": {} }' | Set-Content -LiteralPath $crew -Encoding utf8

        Get-UsagePulse -CrewStatePath $crew |
            Should -Be '5% used (session) - nothing running'
    }

    # A RECORD WITH A FIELD MISSING USED TO END THE PULSE FOR THE SESSION. This module runs under
    # StrictMode Latest and a script invoked with `&` inherits it, so a crew record written before
    # `stage` existed - or a herdr agent with no `title` - turned an optional read inside the crew
    # reader into an exception. The tick threw, the loop turned it into a warning, and it did the
    # same again every interval, which is indistinguishable from a pulse that has nothing to say.
    #
    # Run against the real crew reader with a worker in the record, so the loop body that does
    # those reads actually executes - the empty-record case above never enters it. herdr is a shim
    # on PATH answering with no agents, the same way CrewStatus.Tests.ps1 stubs it, so the real
    # argument list and JSON parsing are exercised without a server.
    It 'survives a crew record that is missing a field the reader treats as optional' {
        Mock -ModuleName Usage Get-UsageWindow {
            [pscustomobject]@{ status = 'has-usage'; signal = 's'; percent = 5; detail = 'x'
                               resetsAt = ''; window = 'five_hour'; takenAt = 'now' }
        }
        InModuleScope Usage { $script:LastSpoken = $null }

        $shim = New-TempFixtureDir -Prefix 'herdr-shim-'
        Set-Content -Path (Join-Path $shim 'herdr.cmd') -Encoding ascii -Value @(
            '@echo off',
            'type "%KINGSHAND_TEST_USAGE_HERDR%"'
        )
        $reply = Join-Path $shim 'agents.json'
        '{ "agents": [] }' | Set-Content -LiteralPath $reply -Encoding utf8

        $dir  = New-TempFixtureDir
        $crew = Join-Path $dir 'crew.json'
        # No `stage`, which is what an older writer left behind and what Import-CrewState does not
        # backfill.
        '{ "workers": { "T-1": { "ticket": "T-1", "repo": "C:\\repo" } } }' |
            Set-Content -LiteralPath $crew -Encoding utf8

        $savedPath = $env:PATH
        $savedVar  = $env:KINGSHAND_TEST_USAGE_HERDR
        try {
            $env:PATH = $shim + [IO.Path]::PathSeparator + $savedPath
            $env:KINGSHAND_TEST_USAGE_HERDR = $reply

            { Get-UsageFleet -CrewStatePath $crew } | Should -Not -Throw
            Get-UsagePulse -CrewStatePath $crew | Should -Be '5% used (session) - nothing running'
        } finally {
            $env:PATH = $savedPath
            $env:KINGSHAND_TEST_USAGE_HERDR = $savedVar
        }
    }
}

Describe 'The pulse on a timer' {
    BeforeEach {
        Mock -ModuleName Usage Get-UsageWindow {
            [pscustomobject]@{ status = 'has-usage'; signal = 's'; percent = 5; detail = 'x'
                               resetsAt = ''; window = 'five_hour'; takenAt = 'now' }
        }
        Mock -ModuleName Usage Get-UsageFleet { @() }
        InModuleScope Usage { $script:LastSpoken = $null }
    }

    # The default is what the documented background job takes - it passes no interval at all - so
    # the cadence is read off the wait the loop actually performs rather than off a note about it.
    It 'waits ten minutes between ticks when nobody says otherwise' {
        $global:UsageSleeps = @()
        Mock -ModuleName Usage Start-Sleep { $global:UsageSleeps += $Milliseconds }

        Watch-UsagePulse -Count 2 | Out-Null
        @($global:UsageSleeps) | Should -Be @(600000)
        Remove-Variable -Name UsageSleeps -Scope Global -ErrorAction SilentlyContinue
    }

    It 'takes a different cadence when a session asks for one' {
        $global:UsageSleeps = @()
        Mock -ModuleName Usage Start-Sleep { $global:UsageSleeps += $Milliseconds }

        Watch-UsagePulse -Count 3 -IntervalMinutes 2 | Out-Null
        @($global:UsageSleeps) | Should -Be @(120000, 120000)
        Remove-Variable -Name UsageSleeps -Scope Global -ErrorAction SilentlyContinue
    }

    It 'speaks on the first tick without waiting out an interval' {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $out = @(Watch-UsagePulse -Count 1)
        $sw.Stop()
        $out.Count | Should -Be 1
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 60 -Because 'arming the pulse costs nothing'
    }

    It 'waits between ticks rather than spinning' {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        Watch-UsagePulse -Count 2 -IntervalMinutes 0.05 | Out-Null
        $sw.Stop()
        $sw.Elapsed.TotalSeconds | Should -BeGreaterThan 2
    }

    It 'refuses a negative cadence rather than looping on one' {
        { Watch-UsagePulse -Count 1 -IntervalMinutes -1 } |
            Should -Throw '*cannot be negative*'
    }

    # A GUARD THAT ONLY REFUSED NEGATIVES LET THE WORST CASE THROUGH. No interval and no end is a
    # busy loop that starts quota-axi, reads the fleet and rewrites the record as fast as the
    # machine allows, for the life of the session - and it does it in silence, because after the
    # first tick nothing has changed and silence is what a working pulse looks like. A session that
    # asked for a constant pulse would have got exactly this. It has to refuse instead of spinning,
    # and the refusal has to say what to pass instead.
    It 'refuses an interval of nothing on a run with no end' {
        $err = { Watch-UsagePulse -IntervalMinutes 0 } |
            Should -Throw -PassThru
        "$($err.Exception.Message)" | Should -BeLike '*needs an interval to wait out*'
        "$($err.Exception.Message)" | Should -BeLike '*-Count*'
    }

    # Bounded is the case zero was written for: a caller that wants two ticks back to back should
    # not sit through a wait, and there is no loop to run away with.
    It 'still runs a bounded set of ticks with no wait between them' {
        $out = @(Watch-UsagePulse -Count 2 -IntervalMinutes 0)
        $out.Count | Should -Be 1 -Because 'the second tick has nothing new to say'
    }

    # A DEAD PULSE LOOKS EXACTLY LIKE A HEALTHY ONE, because saying nothing is the documented
    # normal case. So a tick that fails must cost that tick and nothing more - crew.json is
    # written without a temp-and-rename, and a tick that reads it mid-write is the ordinary way
    # this happens. Before this was contained, the first such tick ended the pulse for the session
    # and the King would have found out by noticing he had heard nothing all afternoon.
    It 'keeps pulsing after a tick that failed' {
        $global:UsageTickCount = 0
        Mock -ModuleName Usage Get-UsageFleet {
            $global:UsageTickCount++
            if ($global:UsageTickCount -eq 1) { throw 'crew.json was half written' }
            @()
        }

        $out = @(Watch-UsagePulse -Count 2 -IntervalMinutes 0 `
                                  -WarningAction SilentlyContinue)
        $global:UsageTickCount | Should -Be 2 -Because 'the second tick has to happen at all'
        $out.Count | Should -Be 1
        $out[0]    | Should -Be '5% used (session) - nothing running'
        Remove-Variable -Name UsageTickCount -Scope Global -ErrorAction SilentlyContinue
    }

    It 'says which tick failed rather than dying silently' {
        $global:UsageTickCount = 0
        Mock -ModuleName Usage Get-UsageFleet {
            $global:UsageTickCount++
            throw 'crew.json was half written'
        }

        $warnings = @()
        Watch-UsagePulse -Count 1 -IntervalMinutes 0 `
                         -WarningVariable warnings -WarningAction SilentlyContinue | Out-Null
        "$warnings" | Should -BeLike '*crew.json was half written*'
        Remove-Variable -Name UsageTickCount -Scope Global -ErrorAction SilentlyContinue
    }
}
