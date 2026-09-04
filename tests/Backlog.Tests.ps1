# The durable queue is `tasks-axi` writing `data\backlog.md`, and `CLAUDE.md`'s Backlog contract
# deliberately refuses to restate its flags - `.tasks.toml` and `tasks-axi --help` own those. So
# what is worth pinning here is not the syntax but the three facts the contract and both skills
# actually depend on: an added item comes back from `list`, a held item keeps its reason AND its
# kind, and the file on disk carries the line shape that `survey` reads and a human skims.
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
        # muster uses the work item id verbatim as the backlog id, and an ADO id is bare digits, so
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
        $review.Contains('queue-hold-probe')  | Should -BeTrue -Because 'survey reads held work through this command'
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
        $inFlight.Contains('queue-add-probe') | Should -BeTrue -Because 'muster Step 4 marks a dispatched item started'
    }

    It 'a closed item leaves In flight for Done' -Skip:(-not $HasTasksAxi) {
        Invoke-TasksAxi 'done' 'queue-add-probe' | Out-Null

        $text = Get-Content -Path $script:BacklogFile -Raw
        $done = ($text -split '(?m)^## ' | Where-Object { $_.StartsWith('Done') })
        $done.Contains('queue-add-probe') | Should -BeTrue -Because 'muster Step 8 closes a landed item'

        $inFlight = ($text -split '(?m)^## ' | Where-Object { $_.StartsWith('In flight') })
        $inFlight.Contains('queue-add-probe') | Should -BeFalse -Because 'a done item is not still in flight'
    }

    # The cases below are decree's mechanics, not new backlog syntax. That skill
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
        $held.Contains('dhl-decision')  | Should -BeTrue -Because 'survey reads the open decision through this command'
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
        # so decree states the constraint rather than letting a reason be dropped.
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
    }

    # A parked decision's answer lives in its closed hold and nowhere else, and `tasks-axi done`
    # prunes past this number into the archive, where no tasks-axi command reads it back. So the
    # retention is how long the route can answer "was this already decided" from the tool alone,
    # and at ten it was under a day of ordinary fleet churn - after which delivered work reads as
    # a worker that answered its own question. The archive fallback in muster covers the rest;
    # this keeps the cliff a year out rather than an afternoon.
    It 'keeps enough closed items that an answered decision outlives ordinary churn' {
        $text = Get-Content -Path $script:TasksToml -Raw
        $m = [regex]::Match($text, '(?m)^\s*done_keep\s*=\s*(\d+)\s*$')
        $m.Success | Should -BeTrue -Because 'retention has to be set explicitly, not left to the tool default'
        [int]$m.Groups[1].Value |
            Should -BeGreaterOrEqual 200 -Because 'a closed decision hold pruned out of the backlog reads as a decision nobody made'
    }
}

# The route now rests on a closed hold still being findable, and `tasks-axi` itself is what removes
# it: `done` prunes past `done_keep` into the archive file, and no `list`, `show` or `ready` reads
# that file back. This reproduces the loss on purpose, with retention turned down to 1 so it takes
# two closures rather than two hundred, and pins both halves - the tool goes blind, and the record
# with its `answered:` note is still on disk where muster's fallback looks.
Describe 'a pruned decision hold leaves the tool but not the disk' {
    BeforeAll {
        $script:PruneRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("kingshand-prune-" + [guid]::NewGuid().ToString('N').Substring(0, 12))
        New-Item -ItemType Directory -Path (Join-Path $script:PruneRoot 'data') -Force | Out-Null
        Set-Content -Path (Join-Path $script:PruneRoot '.tasks.toml') -Encoding utf8 -Value @(
            'backend = "markdown"'
            ''
            '[markdown]'
            'path = "data/backlog.md"'
            'archive = "data/done-archive.md"'
            'done_keep = 1'
        )
        $script:ArchiveFile = Join-Path $script:PruneRoot 'data\done-archive.md'

        function Invoke-PruneAxi {
            param([Parameter(Mandatory, ValueFromRemainingArguments)][string[]]$Arguments)
            Push-Location $script:PruneRoot
            try { (& tasks-axi @Arguments 2>&1 | Out-String) }
            finally { Pop-Location }
        }
    }

    AfterAll {
        if ($script:PruneRoot -and (Test-Path $script:PruneRoot)) {
            Remove-Item -Path $script:PruneRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'archives the older answered hold and stops returning it from the tool' -Skip:(-not $HasTasksAxi) {
        Invoke-PruneAxi 'add' 't-1001-hero-copy' 'which hero wording' | Out-Null
        Invoke-PruneAxi 'hold' 't-1001-hero-copy' '--reason' 'his to choose' '--kind' 'captain' | Out-Null
        Invoke-PruneAxi 'done' 't-1001-hero-copy' '--note' 'answered: the shorter wording' | Out-Null

        Invoke-PruneAxi 'add' 't-2002-unrelated' 'something else entirely' | Out-Null
        Invoke-PruneAxi 'done' 't-2002-unrelated' '--note' 'shipped' | Out-Null

        # The blindness itself: neither lookup the route runs can see the answered hold any more.
        (Invoke-PruneAxi 'list' '--state' 'done').Contains('t-1001-hero-copy') |
            Should -BeFalse -Because 'this is the loss the archive fallback exists for'
        $shown = Invoke-PruneAxi 'show' 't-1001-hero-copy' '--full'
        $shown.Contains('NOT_FOUND') |
            Should -BeTrue -Because 'a pruned key reads as NOT_FOUND, which is not the same as never decided'
        $shown.Contains('answered: the shorter wording') |
            Should -BeFalse -Because 'the answer is gone from the tool even though the key is echoed in the error'

        # And the other half: the record and its answer are still on disk, so the fallback works.
        Test-Path $script:ArchiveFile | Should -BeTrue
        $archive = Get-Content -Path $script:ArchiveFile -Raw
        $archive.Contains('t-1001-hero-copy') | Should -BeTrue
        $archive.Contains('answered: the shorter wording') |
            Should -BeTrue -Because 'the closing note is what says what was decided'
    }

    # The archive is read with Select-String, so the match is written by hand and a bare substring
    # says "answered" over any longer key that merely starts the same way. At the teardown guard
    # that turns a record which has gone missing - explicitly "a cause to establish, never a pass" -
    # into permission to stop a worker. This drives the two patterns against the real archived line.
    It 'a bare archive match claims a longer key''s answer, and the anchored one does not' -Skip:(-not $HasTasksAxi) {
        Invoke-PruneAxi 'add' 't-100-copy-length' 'the longer sibling key' | Out-Null
        Invoke-PruneAxi 'hold' 't-100-copy-length' '--reason' 'his to choose' '--kind' 'captain' | Out-Null
        Invoke-PruneAxi 'done' 't-100-copy-length' '--note' 'answered: went long' | Out-Null
        Invoke-PruneAxi 'add' 'filler-to-force-a-prune' 'filler' | Out-Null
        Invoke-PruneAxi 'done' 'filler-to-force-a-prune' '--note' 'shipped' | Out-Null

        # `t-100-copy` was never registered at all, so every read of it must come back empty.
        $missing = 't-100-copy'
        @(Select-String -Path $script:ArchiveFile -SimpleMatch -Pattern $missing).Count |
            Should -BeGreaterThan 0 -Because 'this is the false positive: the bare match finds the longer key'
        @(Select-String -Path $script:ArchiveFile -Pattern "(?m)^\s*-\s*\[x\]\s*$([regex]::Escape($missing))\s+-").Count |
            Should -Be 0 -Because 'anchored to a whole entry, an unregistered key is correctly absent'

        # And the anchor still finds the key that really is there, or it would fail closed on every
        # answered decision instead.
        $real = 't-100-copy-length'
        @(Select-String -Path $script:ArchiveFile -Pattern "(?m)^\s*-\s*\[x\]\s*$([regex]::Escape($real))\s+-").Count |
            Should -Be 1 -Because 'the archived entry renders as `- [x] <key> - <title>`'
    }
}

# Two facts the route's instructions state about the tool and the shell. Both were wrong once, and
# both fail silently rather than loudly: a lookup that errors reads as "no hold covers this", and a
# replayed hold reads as inert while it overwrites the reason the whole discriminator rests on.
Describe 'the tool facts the parked-decision route depends on' {
    BeforeAll {
        $script:FactRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("kingshand-facts-" + [guid]::NewGuid().ToString('N').Substring(0, 12))
        New-Item -ItemType Directory -Path (Join-Path $script:FactRoot 'data') -Force | Out-Null
        Set-Content -Path (Join-Path $script:FactRoot '.tasks.toml') -Encoding utf8 -Value @(
            'backend = "markdown"'
            ''
            '[markdown]'
            'path = "data/backlog.md"'
            'archive = "data/done-archive.md"'
            'done_keep = 200'
        )

        function Invoke-FactAxi {
            param([Parameter(Mandatory, ValueFromRemainingArguments)][string[]]$Arguments)
            Push-Location $script:FactRoot
            try { (& tasks-axi @Arguments 2>&1 | Out-String) }
            finally { Pop-Location }
        }
    }

    AfterAll {
        if ($script:FactRoot -and (Test-Path $script:FactRoot)) {
            Remove-Item -Path $script:FactRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'refuses an unquoted comma-separated field list, which PowerShell splits' -Skip:(-not $HasTasksAxi) {
        Invoke-FactAxi 'add' 'fk-1' 'a decision' | Out-Null
        Invoke-FactAxi 'hold' 'fk-1' '--reason' 'the question is with him' '--kind' 'captain' | Out-Null

        # What PowerShell hands the native command for a bare `hold_kind,hold_reason`: one
        # space-joined token. Sent as that literal token so the assertion cannot be satisfied by
        # some other validation error - measured against tasks-axi 0.2.5, the tool answers this
        # exact form with `Unknown field(s): hold_kind hold_reason`.
        $unquoted = Invoke-FactAxi 'list' '--state' 'held' '--fields' 'hold_kind hold_reason'
        $unquoted.Contains('Unknown field(s): hold_kind hold_reason') |
            Should -BeTrue -Because 'this is the tool''s actual answer to the space-joined token, not any validation error'
        $unquoted.Contains('VALIDATION_ERROR') |
            Should -BeTrue -Because 'the fence must quote the field list or this lookup returns no rows at all'
        $unquoted.Contains('fk-1') |
            Should -BeFalse -Because 'a validation error reads to the Hand as no hold covering the decision'

        # And the token really is what a bare comma list becomes: `[string[]]` coerces the array
        # PowerShell parses it into back to a single space-joined element, so the two forms are
        # indistinguishable by the time the tool sees them. This is the step that makes the case
        # above the documented gotcha rather than a hand-built lookalike.
        $viaBareList = Invoke-FactAxi 'list' '--state' 'held' '--fields' @('hold_kind', 'hold_reason')
        $viaBareList | Should -Be $unquoted -Because 'the bare comma list reaches the tool as that one token'

        $quoted = Invoke-FactAxi 'list' '--state' 'held' '--fields' 'hold_kind,hold_reason'
        $quoted.Contains('fk-1') | Should -BeTrue
        $quoted.Contains('the question is with him') |
            Should -BeTrue -Because 'hold_reason is the whole point of asking for these fields'
    }

    It 'leaves add inert on replay but rewrites a hold''s reason and kind' -Skip:(-not $HasTasksAxi) {
        Invoke-FactAxi 'add' 'fk-2' 'first title' | Out-Null
        Invoke-FactAxi 'hold' 'fk-2' '--reason' 'the question is with him: shorter or longer' '--kind' 'captain' | Out-Null

        $addAgain = Invoke-FactAxi 'add' 'fk-2' 'a completely different title'
        $addAgain.Contains('already: true') | Should -BeTrue -Because 'add is the half that really is idempotent'
        $addAgain.Contains('a completely different title') |
            Should -BeFalse -Because 'a replayed add must not even change the title'

        $holdAgain = Invoke-FactAxi 'hold' 'fk-2' '--reason' 'boilerplate second reason' '--kind' 'external'
        $holdAgain.Contains('already: true') |
            Should -BeFalse -Because 'hold reports a write, and the instructions must not call it inert'

        # This fixture holds more than one item, so read the row for this key rather than the
        # whole listing - another item's reason would otherwise satisfy the absence assertion.
        $after = Invoke-FactAxi 'list' '--state' 'held' '--fields' 'hold_kind,hold_reason'
        $row = @($after -split "`r?`n" | Where-Object { $_ -match '^\s*fk-2,' })[0]
        $row | Should -Not -BeNullOrEmpty -Because 'the replay must leave the item held, not unhold it'
        $row.Contains('boilerplate second reason') |
            Should -BeTrue -Because 'this is the overwrite: the replay replaced the reason in place'
        $row.Contains('the question is with him') |
            Should -BeFalse -Because 'and the discriminator the route reads is what it destroyed'
        $row.Contains('external') |
            Should -BeTrue -Because 'the kind is overwritten with it, so a captain hold stops being one'
    }

    # decree's repair row re-runs `hold` to restate an ambiguous reason. It used to omit --kind on
    # the belief that the replay moved nothing else, which is the one path the test above cannot
    # reach because it always passes --kind explicitly. Passing nothing passes `-`, and a captain
    # hold that stops being one drops out of King's Call and out of muster's orphan lookup.
    It 'clears the captain kind when a hold replay omits --kind' -Skip:(-not $HasTasksAxi) {
        Invoke-FactAxi 'add' 'fk-3' 'an ambiguous reason to repair' | Out-Null
        Invoke-FactAxi 'hold' 'fk-3' '--reason' 'the question is with him' '--kind' 'captain' | Out-Null

        $before = @((Invoke-FactAxi 'list' '--state' 'held' '--fields' 'hold_kind,hold_reason') -split "`r?`n" |
            Where-Object { $_ -match '^\s*fk-3,' })[0]
        $before.Contains('captain') | Should -BeTrue -Because 'the fixture starts as a captain hold'

        Invoke-FactAxi 'hold' 'fk-3' '--reason' 'restated reason, no kind passed' | Out-Null
        $after = @((Invoke-FactAxi 'list' '--state' 'held' '--fields' 'hold_kind,hold_reason') -split "`r?`n" |
            Where-Object { $_ -match '^\s*fk-3,' })[0]
        $after.Contains('restated reason, no kind passed') |
            Should -BeTrue -Because 'the repair did rewrite the reason, which is what the row is for'
        $after.Contains('captain') |
            Should -BeFalse -Because 'and it erased the kind, which is what the row failed to say'

        # The corrected row carries the kind, and that restores it.
        Invoke-FactAxi 'hold' 'fk-3' '--reason' 'restated reason, kind carried' '--kind' 'captain' | Out-Null
        $repaired = @((Invoke-FactAxi 'list' '--state' 'held' '--fields' 'hold_kind,hold_reason') -split "`r?`n" |
            Where-Object { $_ -match '^\s*fk-3,' })[0]
        $repaired.Contains('captain') |
            Should -BeTrue -Because 'passing the kind alongside the reason is what the fixed row does'
        $repaired.Contains('restated reason, kind carried') |
            Should -BeTrue -Because 'and it still rewrites the reason it was run for'
    }
}
