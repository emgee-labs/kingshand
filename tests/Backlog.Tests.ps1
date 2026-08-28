# The durable queue is `tasks-axi` writing `data\backlog.md`, and `CLAUDE.md`'s Backlog contract
# deliberately refuses to restate its flags - `.tasks.toml` and `tasks-axi --help` own those. So
# what is worth pinning here is not the syntax but the three facts the contract and both skills
# actually depend on: an added item comes back from `list`, a held item keeps its reason AND its
# kind, and the file on disk carries the line shape that `bearings` reads and a human skims.
#
# Every case runs against a THROWAWAY `.tasks.toml` in a temp directory. `tasks-axi` resolves its
# config from the current directory, so running these from the repo root would add, hold and
# close items in the user's live `$env:KINGSHAND_HOME\data\backlog.md`. The temp root is asserted to
# be outside the repo before anything writes to it.

BeforeDiscovery {
    $HasTasksAxi = [bool](Get-Command tasks-axi -ErrorAction SilentlyContinue)
}

Describe 'tasks-axi backs the durable queue' {

    BeforeAll {
        $script:Root = Split-Path $PSScriptRoot -Parent
        $script:Temp = Join-Path ([System.IO.Path]::GetTempPath()) ("kingshand-backlog-" + [guid]::NewGuid().ToString('N').Substring(0, 12))
        New-Item -ItemType Directory -Path $script:Temp -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:Temp 'data') -Force | Out-Null

        $script:BacklogFile = Join-Path $script:Temp 'data\backlog.md'

        # Same shape as the repo's own .tasks.toml, pointed at the temp data directory.
        Set-Content -Path (Join-Path $script:Temp '.tasks.toml') -Encoding utf8 -Value @(
            'backend = "markdown"'
            ''
            '[markdown]'
            'path = "data/backlog.md"'
            'archive = "data/done-archive.md"'
            'done_keep = 10'
        )

        function Invoke-TasksAxi {
            param([Parameter(Mandatory, ValueFromRemainingArguments)][string[]]$Arguments)
            Push-Location $script:Temp
            try { (& tasks-axi @Arguments 2>&1 | Out-String) }
            finally { Pop-Location }
        }
    }

    AfterAll {
        if ($script:Temp -and (Test-Path $script:Temp)) {
            Remove-Item -Path $script:Temp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'tasks-axi is on PATH, or every case below skips with a reason' {
        # Resolved at run time on purpose. The -Skip: switches below are evaluated during
        # discovery, where $HasTasksAxi lives; a discovery-time variable read inside an It body
        # is $null, which would make this case report a missing tool that is plainly installed.
        $onPath = [bool](Get-Command tasks-axi -ErrorAction SilentlyContinue)
        if (-not $onPath) {
            Set-ItResult -Skipped -Because 'tasks-axi is not on PATH, so the backlog cases cannot run. Install it and re-run; nothing else in the suite depends on it.'
        }
        $onPath | Should -BeTrue
    }

    It 'never points at the live kingshand backlog' {
        # The one failure this whole file exists to prevent.
        $script:Temp.StartsWith($script:Root, [StringComparison]::OrdinalIgnoreCase) |
            Should -BeFalse -Because 'these cases must never write to the user''s live data\backlog.md'
    }

    It 'writes the queue file itself rather than needing one by hand' -Skip:(-not $HasTasksAxi) {
        Invoke-TasksAxi 'render' | Out-Null
        Test-Path $script:BacklogFile | Should -BeTrue

        $text = Get-Content -Path $script:BacklogFile -Raw
        foreach ($heading in @('# Backlog', '## In flight', '## Queued', '## Done')) {
            $text.Contains($heading) | Should -BeTrue -Because "a rendered backlog carries the $heading heading"
        }
    }

    It 'an added item comes back from list' -Skip:(-not $HasTasksAxi) {
        Invoke-TasksAxi 'add' 'queue-add-probe' 'Adds to the queue' | Out-Null

        $list = Invoke-TasksAxi 'list'
        $list.Contains('queue-add-probe')  | Should -BeTrue -Because 'list must report an item that was added'
        $list.Contains('Adds to the queue') | Should -BeTrue -Because 'list must report the item title'
        $list.Contains('queued')            | Should -BeTrue -Because 'a new item lands in Queued'
    }

    It 'a numeric ticket id is accepted as a slug' -Skip:(-not $HasTasksAxi) {
        # crew uses the work item id verbatim as the backlog id, and an ADO id is bare digits, so
        # digits alone must work. The id here stays numeric on purpose - a T- prefix would make
        # this pass for the wrong reason and quietly stop covering the shape it exists to cover.
        Invoke-TasksAxi 'add' '4242' 'A ticket-shaped id' | Out-Null
        (Invoke-TasksAxi 'list').Contains('4242') | Should -BeTrue
    }

    It 'a held item records its reason and its kind' -Skip:(-not $HasTasksAxi) {
        Invoke-TasksAxi 'add' 'queue-hold-probe' 'Waits on the Hand' | Out-Null
        $held = Invoke-TasksAxi 'hold' 'queue-hold-probe' '--reason' 'waiting on the user' '--kind' 'captain'

        $held.Contains('waiting on the user') | Should -BeTrue -Because 'the hold reason is what the user has to answer'
        $held.Contains('captain')             | Should -BeTrue -Because 'a captain hold must be distinguishable from any other hold'

        # And it is durable, not just echoed back by the mutation.
        $review = Invoke-TasksAxi 'ready' '--include-held'
        $review.Contains('queue-hold-probe')  | Should -BeTrue -Because 'bearings reads held work through this command'
        $review.Contains('waiting on the user') | Should -BeTrue
        $review.Contains('captain')             | Should -BeTrue
    }

    It 'a held item is not offered as ready to dispatch' -Skip:(-not $HasTasksAxi) {
        $ready = Invoke-TasksAxi 'ready'
        $ready.Contains('queue-add-probe')   | Should -BeTrue  -Because 'an unheld queued item is dispatchable'
        $ready.Contains('queue-hold-probe')  | Should -BeFalse -Because 'a held item waits until the hold clears'
    }

    It 'the written markdown matches the documented line shape' -Skip:(-not $HasTasksAxi) {
        $lines = @(Get-Content -Path $script:BacklogFile)

        $plain = @($lines | Where-Object { $_.Contains('queue-add-probe') })
        $plain.Count | Should -Be 1
        $plain[0] | Should -Match '^- \[ \] queue-add-probe - Adds to the queue \(since \d{4}-\d{2}-\d{2}\)$'

        $held = @($lines | Where-Object { $_.Contains('queue-hold-probe') })
        $held.Count | Should -Be 1
        $held[0] | Should -Match ('^- \[ \] queue-hold-probe - Waits on the Hand \(since \d{4}-\d{2}-\d{2}\)' +
                                 ' \(hold: waiting on the user\) \(hold-kind: captain\)$')
    }

    It 'a started item leaves Queued for In flight' -Skip:(-not $HasTasksAxi) {
        Invoke-TasksAxi 'start' 'queue-add-probe' | Out-Null

        $text  = Get-Content -Path $script:BacklogFile -Raw
        $inFlight = ($text -split '(?m)^## ' | Where-Object { $_.StartsWith('In flight') })
        $inFlight.Contains('queue-add-probe') | Should -BeTrue -Because 'crew Step 4 marks a dispatched item started'
    }

    It 'a closed item leaves In flight for Done' -Skip:(-not $HasTasksAxi) {
        Invoke-TasksAxi 'done' 'queue-add-probe' | Out-Null

        $text = Get-Content -Path $script:BacklogFile -Raw
        $done = ($text -split '(?m)^## ' | Where-Object { $_.StartsWith('Done') })
        $done.Contains('queue-add-probe') | Should -BeTrue -Because 'crew Step 8 closes a landed item'

        $inFlight = ($text -split '(?m)^## ' | Where-Object { $_.StartsWith('In flight') })
        $inFlight.Contains('queue-add-probe') | Should -BeFalse -Because 'a done item is not still in flight'
    }

    # The cases below are decision-hold-lifecycle's mechanics, not new backlog syntax. That skill
    # has no script behind it and no teardown gate enforcing it, so what it can promise is bounded
    # entirely by what tasks-axi actually does: whether a stable key replays cleanly, whether a
    # blocked item names its blocker, and whether closing the hold is what releases the work the
    # user's answer authorised. Every id here is deliberately distinct from the probes above,
    # which assert exact line counts by substring.

    It 'registering the same decision key twice is idempotent' -Skip:(-not $HasTasksAxi) {
        Invoke-TasksAxi 'add' 'dhl-retry' 'Registered twice on a retry' | Out-Null
        Invoke-TasksAxi 'hold' 'dhl-retry' '--reason' 'user decision pending' '--kind' 'captain' | Out-Null

        $again = Invoke-TasksAxi 'hold' 'dhl-retry' '--reason' 'user decision pending' '--kind' 'captain'
        $again.Contains('already') | Should -BeTrue -Because 'a replayed registration must not be a second decision'

        $lines = @(Get-Content -Path $script:BacklogFile | Where-Object { $_.Contains('dhl-retry') })
        $lines.Count | Should -Be 1 -Because 'a stable key registered twice is one durable item, not two'
    }

    It 'a captain hold and the work it blocks model an unresolved decision' -Skip:(-not $HasTasksAxi) {
        Invoke-TasksAxi 'add' 'dhl-decision' 'Which retry policy applies' | Out-Null
        Invoke-TasksAxi 'hold' 'dhl-decision' '--reason' 'user decision pending on the retry policy' '--kind' 'captain' | Out-Null
        Invoke-TasksAxi 'add' 'dhl-followup' 'Implement the chosen retry policy' | Out-Null
        Invoke-TasksAxi 'block' 'dhl-followup' '--by' 'dhl-decision' | Out-Null

        $held = Invoke-TasksAxi 'ready' '--include-held'
        $held.Contains('dhl-decision')  | Should -BeTrue -Because 'bearings reads the open decision through this command'
        $held.Contains('user decision pending on the retry policy') |
            Should -BeTrue -Because 'the reason is the decision the user has to make'
        $held.Contains('captain')       | Should -BeTrue -Because 'the hold kind is what routes it to King''s Call'
        $held.Contains('dhl-followup')  | Should -BeFalse -Because 'work blocked by the hold is not dispatchable'

        $blocked = Invoke-TasksAxi 'list' '--blocked' '--fields' 'blocked_by'
        $blocked.Contains('dhl-followup') | Should -BeTrue  -Because 'the routed work is visible as blocked'
        $blocked.Contains('dhl-decision') | Should -BeTrue  -Because 'a blocked item must name the hold blocking it'
    }

    It 'closing the hold records the answer and releases the routed work' -Skip:(-not $HasTasksAxi) {
        Invoke-TasksAxi 'done' 'dhl-decision' '--note' 'answered: exponential backoff capped at five attempts' | Out-Null

        $show = Invoke-TasksAxi 'show' 'dhl-decision' '--full'
        $show.Contains('answered: exponential backoff capped at five attempts') |
            Should -BeTrue -Because 'the note on the closing done is the durable answer'

        $blocked = Invoke-TasksAxi 'list' '--blocked'
        $blocked.Contains('dhl-followup') | Should -BeFalse -Because 'closing the hold clears the dependency edge'

        $ready = Invoke-TasksAxi 'ready'
        $ready.Contains('dhl-followup') | Should -BeTrue -Because 'the work the answer authorised is dispatchable now'
        $ready.Contains('dhl-decision') | Should -BeFalse -Because 'an answered decision is closed, not queued'
    }

    It 'a hold reason may not carry parentheses' -Skip:(-not $HasTasksAxi) {
        # tasks-axi reserves parentheses for its own markdown hold tags and refuses the command,
        # so decision-hold-lifecycle states the constraint rather than letting a reason be dropped.
        Invoke-TasksAxi 'add' 'dhl-paren' 'Parenthesised reason probe' | Out-Null
        $out = Invoke-TasksAxi 'hold' 'dhl-paren' '--reason' 'a (parenthesised) reason' '--kind' 'captain'

        $out.Contains('parentheses') | Should -BeTrue -Because 'the refusal must name the reason it refused'

        $lines = @(Get-Content -Path $script:BacklogFile | Where-Object { $_.Contains('dhl-paren') })
        $lines.Count | Should -Be 1
        $lines[0].Contains('hold:') | Should -BeFalse -Because 'a refused hold must not be half-recorded'
    }
}

Describe 'the repo config points the queue at kingshand''s own data directory' {
    # This one needs no tasks-axi: it is the config the contract names, read as text.
    #
    # There is deliberately no case here asserting that `data\backlog.md` exists. It asserted this
    # machine's state rather than any behaviour: a fresh clone has no data\ directory at all, by
    # design, so the case failed for every user who was not the one who wrote it. What it was
    # reaching for - that this exact config produces a queue file with tasks-axi's own headings -
    # is covered above by 'writes the queue file itself rather than needing one by hand', which
    # renders the same config in a temp directory and asserts the same four headings.
    BeforeAll {
        $script:Root       = Split-Path $PSScriptRoot -Parent
        $script:TasksToml  = Join-Path $script:Root '.tasks.toml'
    }

    It 'exists at the repo root, where tasks-axi resolves it from' {
        Test-Path $script:TasksToml | Should -BeTrue
    }

    It 'selects the markdown backend and kingshand''s own paths' {
        $text = Get-Content -Path $script:TasksToml -Raw
        $text.Contains('backend = "markdown"')            | Should -BeTrue
        $text.Contains('path = "data/backlog.md"')        | Should -BeTrue
        $text.Contains('archive = "data/done-archive.md"') | Should -BeTrue
        $text.Contains('done_keep = 10')                  | Should -BeTrue
    }
}
