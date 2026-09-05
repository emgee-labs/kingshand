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
            [string]$FiveHourResets  = '2026-09-05T22:20:00.227705+00:00',
            [object]$EffectiveRemaining = 96,
            [string[]]$LimitingWindowIds = @('five_hour'),
            [switch]$WithSevenDay,
            [string]$SevenDayResets = '2026-09-12T10:00:00+00:00',
            [bool]$Stale = $false,
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
            $windows = @(
                @{ id = 'five_hour'; label = 'session'; kind = 'session'
                   percentUsed = $FiveHourPercent; resetsAt = $FiveHourResets
                   windowSeconds = 18000; percentRemaining = $fiveRemaining },
                # The spend cap sitting at 100 is real on this machine and it must NOT decide the
                # answer: taking the worst window would refuse every dispatch.
                @{ id = 'extra_usage'; label = 'extra usage'; kind = 'credits'
                   percentUsed = 100; spentUsd = 50.04; limitUsd = 50; percentRemaining = 0 }
            )
            if ($WithSevenDay) {
                $windows += @{ id = 'seven_day'; label = 'weekly'; kind = 'rolling'
                               percentUsed = 61; resetsAt = $SevenDayResets
                               windowSeconds = 604800; percentRemaining = 39 }
            }
        }

        $semantics = if ($null -eq $EffectiveRemaining) {
            @{ status = 'unknown'; description = 'not established' }
        } else {
            @{
                status = 'known'
                effectiveAvailability = @(@{
                    scope = 'all_models'; status = 'known'
                    effectivePercentRemaining = $EffectiveRemaining
                    boundedBy = @('five_hour', 'seven_day')
                    limitingWindowIds = $LimitingWindowIds
                })
            }
        }

        $report = @{
            generatedAt = '2026-09-05T17:40:31.826Z'
            providers   = @(@{
                provider = $Provider; label = 'Claude'; source = 'oauth'; plan = 'team'
                windows  = $windows
                state    = @{ status = if ($Stale) { 'stale' } else { 'fresh' }; stale = $Stale }
                quotaSemantics = $semantics
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
        It 'reads the percentage from what the tool says bounds every model' {
            Mock -ModuleName Usage Invoke-QuotaAxi { New-AxiOk (New-AxiReport -EffectiveRemaining 96) }

            $r = Get-UsageWindow
            $r.status  | Should -Be 'has-usage'
            $r.signal  | Should -Be 'effective-availability'
            $r.percent | Should -Be 4
            $r.window  | Should -Be 'five_hour'
        }

        # The spend cap in the fixture sits at 100 percent. Taking the worst window in the list
        # would report the window as full and refuse every dispatch on a machine whose session
        # window is barely touched, so the tool's own judgement about what bounds a model decides.
        It 'does not let a window that bounds nothing decide the answer' {
            Mock -ModuleName Usage Invoke-QuotaAxi { New-AxiOk (New-AxiReport -EffectiveRemaining 96) }
            (Get-UsageWindow).percent | Should -Be 4
        }

        It 'carries the reset time and says it in words a person can read' {
            Mock -ModuleName Usage Invoke-QuotaAxi { New-AxiOk (New-AxiReport -EffectiveRemaining 96) }

            $r = Get-UsageWindow
            $r.resetsAt | Should -Not -BeNullOrEmpty
            $r.detail   | Should -BeLike '*resets at*'
            $r.detail   | Should -BeLike '*session window*' -Because 'the detail is read out to a person'
        }

        # Narrower than the answer above and still a real reading. A tool that reports windows but
        # will not say what they add up to has still answered the question this asks.
        It 'falls back to the five-hour window when the tool will not total them' {
            Mock -ModuleName Usage Invoke-QuotaAxi {
                New-AxiOk (New-AxiReport -FiveHourPercent 37 -EffectiveRemaining $null)
            }

            $r = Get-UsageWindow
            $r.status  | Should -Be 'has-usage'
            $r.signal  | Should -Be 'five-hour-window'
            $r.percent | Should -Be 37
        }

        # A reset time that cannot be read is not evidence against a percentage that was read
        # perfectly well, so the answer survives and only the footnote is dropped.
        It 'keeps the percentage when the reset time will not parse' {
            Mock -ModuleName Usage Invoke-QuotaAxi {
                New-AxiOk (New-AxiReport -EffectiveRemaining 96 -FiveHourResets 'whenever')
            }

            $r = Get-UsageWindow
            $r.status   | Should -Be 'has-usage'
            $r.percent  | Should -Be 4
            $r.resetsAt | Should -Be ''
            $r.detail   | Should -Not -BeLike '*resets at*'
        }

        # Two ids is the case a single id hid. The list used to be handed to the window lookup
        # whole, which coerces to "seven_day five_hour" and matches no window at all - so the
        # reader lost the reset time and named a window that does not exist, silently, because
        # every fixture until now reported exactly one limiting window.
        It 'names the first limiting window when the tool reports more than one' {
            Mock -ModuleName Usage Invoke-QuotaAxi {
                New-AxiOk (New-AxiReport -EffectiveRemaining 12 -WithSevenDay `
                                         -LimitingWindowIds @('seven_day', 'five_hour') `
                                         -SevenDayResets '2026-09-12T10:00:00+00:00')
            }

            $r = Get-UsageWindow
            $r.status  | Should -Be 'has-usage'
            $r.percent | Should -Be 88
            $r.window  | Should -Be 'seven_day'
            ([datetimeoffset]$r.resetsAt).UtcDateTime |
                Should -Be ([datetimeoffset]'2026-09-12T10:00:00+00:00').UtcDateTime `
                -Because 'the reset time comes from the window that was named'
        }

        # By id and never by position. A window the tool has renamed or dropped is not known, and
        # reading whichever window happened to be first would report a spend cap as the session.
        It 'leaves the reset time unread when the limiting window is not in the list' {
            Mock -ModuleName Usage Invoke-QuotaAxi {
                New-AxiOk (New-AxiReport -EffectiveRemaining 12 -LimitingWindowIds @('renamed_window'))
            }

            $r = Get-UsageWindow
            $r.percent  | Should -Be 88
            $r.window   | Should -Be 'renamed_window'
            $r.resetsAt | Should -Be ''
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

        It 'reports unknown when windows are there and no percentage can be read from any of them' {
            Mock -ModuleName Usage Invoke-QuotaAxi {
                @{ providers = @(@{ provider = 'claude'
                                    windows  = @(@{ id = 'five_hour' })
                                    state    = @{ stale = $false } }) } |
                    ConvertTo-Json -Depth 8 | ForEach-Object { New-AxiOk $_ }
            }

            $r = Get-UsageWindow
            $r.status  | Should -Be 'unknown'
            $r.signal  | Should -Be 'no-percentage'
            $r.percent | Should -BeNullOrEmpty
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
                New-AxiOk (New-AxiReport -SchemaVersion 99 -EffectiveRemaining 96)
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

        It 'reads a percentage the tool wrote as a word as no percentage, not as an error' {
            Mock -ModuleName Usage Invoke-QuotaAxi {
                New-AxiOk (New-AxiReport -EffectiveRemaining 'plenty' -FiveHourPercent 37)
            }

            { Get-UsageWindow } | Should -Not -Throw

            $r = Get-UsageWindow
            $r.status  | Should -Be 'has-usage' -Because 'the five-hour window still answered'
            $r.signal  | Should -Be 'five-hour-window'
            $r.percent | Should -Be 37
        }

        It 'settles on unknown when no window carries a percentage that is a number' {
            Mock -ModuleName Usage Invoke-QuotaAxi {
                New-AxiOk (New-AxiReport -EffectiveRemaining 'plenty' -FiveHourPercent 'lots')
            }

            $r = Get-UsageWindow
            $r.status  | Should -Be 'unknown'
            $r.signal  | Should -Be 'no-percentage'
            $r.percent | Should -BeNullOrEmpty
        }

        It 'never reads a true as one percent spent' {
            Mock -ModuleName Usage Invoke-QuotaAxi {
                New-AxiOk (New-AxiReport -EffectiveRemaining $true -FiveHourPercent $true)
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

    It 'names the percentage, the count and what each worker is doing' {
        Mock -ModuleName Usage Get-UsageFleet {
            @((New-FleetRow -Ticket 'kh-usage-watch' -Stage 'gating'),
              (New-FleetRow -Ticket 'emgee-seo'      -Stage 'ready'))
        }

        Get-UsagePulse |
            Should -Be '62% used - 2 running: kh-usage-watch running checks, emgee-seo waiting on you'
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
        Get-UsagePulse | Should -Be '62% used - nothing running'
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
        Get-UsagePulse | Should -Be '71% used - nothing running'
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
        Get-UsagePulse | Should -Be '70% used - nothing running'

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
        Get-UsagePulse | Should -Be '69% used - nothing running'

        Mock -ModuleName Usage Get-UsageWindow {
            [pscustomobject]@{ status = 'has-usage'; signal = 's'; percent = 70.2; detail = 'x'
                               resetsAt = ''; window = 'five_hour'; takenAt = 'now' }
        }
        Get-UsagePulse | Should -Be '70% used - nothing running'
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
            Should -Be '5% used - nothing running'
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
        $out[0]    | Should -Be '5% used - nothing running'
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
