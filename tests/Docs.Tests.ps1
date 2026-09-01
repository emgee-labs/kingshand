# The rules that decide whether a background worker pushes, lands, merges or is torn down live
# in prose, not in code - CLAUDE.md and the two skills. Nothing in the suite failed if someone
# reintroduced the `yolo` truthiness bug or deleted a push prohibition, which is exactly where
# an irreversible action on a real repository comes from. These assert on the specific wording
# that carries each rule, so deleting the rule fails the test; a check for a word common enough
# to survive the rule's deletion would be worthless.
#
# Containment is asserted with .Contains, not `Should -BeLike`. Every phrase below is thick with
# backticks, and the backtick is the escape character in a PowerShell wildcard - a -BeLike
# pattern quietly stops matching the literal text it was copied from.

BeforeAll {
    $script:Root      = Split-Path $PSScriptRoot -Parent
    $script:HandMd = Join-Path $script:Root 'CLAUDE.md'
    $script:MusterMd    = Join-Path $script:Root '.claude\skills\muster\SKILL.md'
    $script:ImportMd  = Join-Path $script:Root '.claude\skills\annex\SKILL.md'
    $script:SurveyMd = Join-Path $script:Root '.claude\skills\survey\SKILL.md'
    $script:DiagnosticMd = Join-Path $script:Root '.claude\skills\inquest\SKILL.md'
    $script:AskUserMd    = Join-Path $script:Root '.claude\skills\petition\SKILL.md'
    $script:GuidelinesMd = Join-Path $script:Root '.claude\skills\statute\SKILL.md'
    $script:AudienceMd       = Join-Path $script:Root '.claude\skills\audience\SKILL.md'
    $script:StuckMd      = Join-Path $script:Root '.claude\skills\rally\SKILL.md'
    $script:ChronicleMd       = Join-Path $script:Root '.claude\skills\chronicle\SKILL.md'
    $script:HoldMd       = Join-Path $script:Root '.claude\skills\decree\SKILL.md'

    # The bootstrap skill and the script it runs. Both are read as text here and neither is ever
    # executed: a test that ran the installer would install software onto whatever machine the
    # suite happens to be on.
    $script:SetupMd      = Join-Path $script:Root '.claude\skills\setup\SKILL.md'
    $script:InstallPs1   = Join-Path $script:Root 'install.ps1'

    # The three ported reference skills carry no code fences, so their frontmatter is the only
    # machine-read part of them. A skill whose frontmatter does not parse is silently not a skill
    # at all - it never loads, and nothing else in the suite would notice.
    function Get-Frontmatter {
        param([Parameter(Mandatory)][string]$Path)
        $lines = @(Get-Content -Path $Path)
        if ($lines.Count -lt 2 -or $lines[0].Trim() -ne '---') { throw "$Path has no opening frontmatter fence." }
        $end = -1
        for ($i = 1; $i -lt $lines.Count; $i++) {
            if ($lines[$i].Trim() -eq '---') { $end = $i; break }
        }
        if ($end -lt 0) { throw "$Path has no closing frontmatter fence." }
        $map = @{}
        foreach ($line in $lines[1..($end - 1)]) {
            if ($line -match '^([A-Za-z][A-Za-z0-9_-]*):\s*(.*)$') { $map[$Matches[1]] = $Matches[2].Trim() }
            elseif ($line.Trim()) { throw "$Path frontmatter line is not a key: value pair: $line" }
        }
        $map
    }

    # Every assertion runs against normalised text, so a rule stays found when a sentence is
    # re-wrapped across lines or set as a blockquote, and stays lost when its words are actually
    # removed. Blockquote markers go first: a `> ` at a wrapped line's head would otherwise land
    # in the middle of the sentence.
    function ConvertTo-NormalisedText {
        param([Parameter(Mandatory)][string]$Text)
        (($Text -replace '(?m)^[ \t]*>[ \t]?', '') -replace '\s+', ' ')
    }

    function Get-DocText {
        param([Parameter(Mandatory)][string]$Path)
        ConvertTo-NormalisedText (Get-Content -Path $Path -Raw)
    }

    # Fenced code blocks are what a reader copies and runs. A rule may be argued against in
    # prose; it must never appear as an instruction inside a fence.
    function Get-CodeFence {
        param([Parameter(Mandatory)][string]$Path)
        $blocks = [System.Collections.Generic.List[string]]::new()
        $inside = $false
        $buffer = [System.Collections.Generic.List[string]]::new()
        foreach ($line in (Get-Content -Path $Path)) {
            if ($line -match '^\s*```') {
                if ($inside) { $blocks.Add(($buffer -join "`n")); $buffer.Clear() }
                $inside = -not $inside
                continue
            }
            if ($inside) { $buffer.Add($line) }
        }
        # Returned WITHOUT the leading-comma idiom on purpose. That idiom stops the pipeline
        # unrolling the array, so `Get-CodeFence ... | Where-Object { $_.Contains(...) }` would
        # hand Where-Object the whole array as one item and .Contains would silently become an
        # element-equality test that never matches. Call sites wrap in @() instead.
        $blocks.ToArray()
    }

    # The muster skill split on its own step headings, so a gate is asserted at its own site
    # rather than anywhere in the file.
    function Get-MusterStep {
        param([Parameter(Mandatory)][string]$Heading)
        $parts = (Get-Content -Path $script:MusterMd -Raw) -split '(?m)^## '
        $hit   = @($parts | Where-Object { $_.StartsWith($Heading) })
        if ($hit.Count -ne 1) { throw "Expected exactly one '## $Heading' section, found $($hit.Count)." }
        ConvertTo-NormalisedText $hit[0]
    }

    # CLAUDE.md loads on every turn, so a rule that survives only as a stray sentence elsewhere in
    # the file is not the rule any more. The four ported sections are asserted at their own
    # headings, the same way a muster gate is asserted at its own step.
    function Get-HandSection {
        param([Parameter(Mandatory)][string]$Heading)
        $parts = (Get-Content -Path $script:HandMd -Raw) -split '(?m)^## '
        $hit   = @($parts | Where-Object { $_.StartsWith($Heading) })
        if ($hit.Count -ne 1) { throw "Expected exactly one '## $Heading' section in CLAUDE.md, found $($hit.Count)." }
        ConvertTo-NormalisedText $hit[0]
    }

    function Assert-Phrase {
        param(
            [Parameter(Mandatory)][string]$Text,
            [Parameter(Mandatory)][string]$Phrase,
            [string]$Where = 'the document'
        )
        $Text.Contains($Phrase) | Should -BeTrue -Because "$Where must still say: $Phrase"
    }
}

Describe 'yolo is tested as a string, never for truthiness' {
    It 'CLAUDE.md rule 2 names the exact comparison' {
        Assert-Phrase -Text (Get-DocText $script:HandMd) -Where 'CLAUDE.md rule 2' `
            -Phrase "``yolo`` is the string ``'on'`` or ``'off'``, never a boolean - test it with ``-eq 'on'``"
    }

    It 'the muster skill states the comparison where the project is resolved' {
        Assert-Phrase -Text (Get-MusterStep 'Step 1 - Intake') -Where 'muster Step 1' `
            -Phrase "Always test it as ```$proj.yolo -eq 'on'``"
    }

    It 'the dispatch gate decides on -eq ''on''' {
        $step = Get-MusterStep 'Step 3 - Gate one'
        Assert-Phrase -Text $step -Where 'the dispatch gate' `
            -Phrase "The test is ```$proj.yolo -eq 'on'``, and nothing else"
        Assert-Phrase -Text $step -Where 'the dispatch gate' `
            -Phrase "When ```$proj.yolo -eq 'off'``, dispatch nothing until they approve"
    }

    It 'the landing gate decides on -eq ''on''' {
        $step = Get-MusterStep 'Step 7 - Gate two'
        Assert-Phrase -Text $step -Where 'the landing gate' `
            -Phrase "The test is ```$proj.yolo -eq 'on'``, and nothing else"
        Assert-Phrase -Text $step -Where 'the landing gate' `
            -Phrase "When ```$proj.yolo -eq 'off'``, **render the evidence and wait**"
        Assert-Phrase -Text $step -Where 'the landing gate' `
            -Phrase "When ```$proj.yolo -eq 'on'``, the waiting is skipped"
    }

    # The gate said "render the diff and poll lavish" and nothing ran it. Gate one carried a
    # concrete Render-Review command; gate two carried a sentence, and a sentence is not a step.
    # Measured: lavish was invoked zero times across a full working session, with the landing
    # decision delivered as chat prose instead.
    It 'the landing gate carries a runnable render, not a description of one' {
        $step = Get-MusterStep 'Step 7 - Gate two'
        $step | Should -Match 'Render-Review\.ps1' -Because 'gate one has the command and gate two needs it too'
        $step | Should -Match 'lavish-axi poll' -Because 'rendering without polling waits on nothing'
        # The first draft of this block said -OutPath. Render-Review takes -OutputPath, so it would
        # have thrown the first time anyone ran the landing gate. Documented commands are not
        # exercised by anything, which is exactly why the parameter name is pinned here.
        $step | Should -Match '-OutputPath' -Because 'the real parameter name, verified by running it'
        $step | Should -Not -Match '-OutPath\b' -Because 'that name does not exist and fails at the gate'
        Assert-Phrase -Text $step -Where 'the landing gate' `
            -Phrase 'do not summarise a diff into chat and ask for a yes'
    }

    It 'no bare truthiness test appears in a runnable code block in <file>' -ForEach @(
        # minFences guards each case against passing vacuously if fence parsing ever breaks.
        # CLAUDE.md carries no code blocks at all, so it is covered by the next test instead.
        @{ file = 'CLAUDE.md';                      minFences = 0 }
        @{ file = '.claude\skills\muster\SKILL.md';           minFences = 20 }
        @{ file = '.claude\skills\annex\SKILL.md'; minFences = 5 }
    ) {
        $blocks = @(Get-CodeFence (Join-Path $script:Root $file))
        $blocks.Count |
            Should -BeGreaterOrEqual $minFences -Because "fence parsing must still find $file's code blocks"
        foreach ($block in $blocks) {
            $block.Contains('if ($proj.yolo)') |
                Should -BeFalse -Because "$file must never instruct a bare truthiness test"
        }
    }

    It 'CLAUDE.md does not show the bare test anywhere, even as prose' {
        (Get-DocText $script:HandMd).Contains('if ($proj.yolo)') |
            Should -BeFalse -Because 'rule 2 states the comparison to use and nothing else'
    }

    It 'every prose mention of the bare test is there to refute it' {
        $text = Get-DocText $script:MusterMd
        $hits = [regex]::Matches($text, 'if \(\$proj\.yolo\)')
        $hits.Count | Should -BeGreaterThan 0 -Because 'the trap itself must stay documented'
        foreach ($h in $hits) {
            $tail = $text.Substring($h.Index, [Math]::Min(160, $text.Length - $h.Index))
            $tail | Should -Match 'is true for|treats every project' `
                -Because 'a bare test may only ever be mentioned in order to reject it'
        }
    }
}

Describe 'the push-capable set is stated consistently' {
    It 'the muster skill names all three push-capable modes where a worker may push' {
        Assert-Phrase -Text (Get-MusterStep 'Step 8 - Land') -Where 'muster Step 8' `
            -Phrase ("push-capable - ``direct-PR``, ``no-mistakes``, or a " +
                     "``no-mistakes-prod-only`` project resolved to one of those")
    }

    It 'close-out is restricted to the same three modes' {
        Assert-Phrase -Text (Get-MusterStep 'Step 8a') -Where 'muster Step 8a' `
            -Phrase ("Only for ``direct-PR`` and ``no-mistakes`` (including " +
                     "``no-mistakes-prod-only`` resolved to either)")
    }

    It 'the import skill requires an origin remote for a push-capable mode' {
        Assert-Phrase -Text (Get-DocText $script:ImportMd) -Where 'the import skill' `
            -Phrase 'a push-capable mode requiring an `origin` remote'
    }

    It 'local-only is never counted as push-capable' {
        Assert-Phrase -Text (Get-MusterStep 'Step 8 - Land') -Where 'muster Step 8' `
            -Phrase ("Never for ``local-only``, whose brief forbids it outright, and never " +
                     "for a project that is not registered at all")
    }
}

Describe 'the local-only push prohibition survives' {
    It 'the local-only Done-means block forbids push, PR and merge' {
        $fences = @(Get-CodeFence $script:MusterMd | Where-Object { $_.Contains('Stop on the branch') })
        $fences.Count | Should -Be 1
        $fences[0].Contains('Stop on the branch. Do not push. Do not open a PR. Do not merge.') |
            Should -BeTrue -Because 'the local-only Done-means block carries the whole prohibition'
    }

    It 'the skill forbids removing that prohibition' {
        Assert-Phrase -Text (Get-DocText $script:MusterMd) -Where 'the muster skill' `
            -Phrase 'never remove the push prohibition from the `local-only` variant'
    }

    It 'an unregistered project is never pushed' {
        Assert-Phrase -Text (Get-MusterStep 'Step 7 - Gate two') -Where 'the landing gate floors' `
            -Phrase 'Never push a project that is not registered with a push-capable posture'
        Assert-Phrase -Text (Get-DocText $script:HandMd) -Where 'CLAUDE.md rule 2' `
            -Phrase 'never pushes a project that is not registered with a push-capable posture'
    }
}

Describe 'muster never merges on the forge' {
    It 'the landing gate lists it as a floor no posture relaxes' {
        Assert-Phrase -Text (Get-MusterStep 'Step 7 - Gate two') -Where 'the landing gate floors' `
            -Phrase ('Never merge on the forge. `direct-PR` and `no-mistakes` work ends ' +
                     'at a pull request the user merges')
    }

    It 'CLAUDE.md rule 2 states it' {
        Assert-Phrase -Text (Get-DocText $script:HandMd) -Where 'CLAUDE.md rule 2' `
            -Phrase 'Muster never merges on the forge'
    }

    It 'the local merge step disclaims the push-capable modes' {
        Assert-Phrase -Text (Get-MusterStep 'Step 8 - Land') -Where 'muster Step 8' `
            -Phrase ('`direct-PR` and `no-mistakes` work ends at a pull request that the ' +
                     'user merges on the forge; `muster` never merges there')
    }

    It 'close-out refuses to make the merge true itself' {
        Assert-Phrase -Text (Get-MusterStep 'Step 8a') -Where 'muster Step 8a' `
            -Phrase 'never merge it to make it true'
    }
}

Describe 'work that is neither landed nor pushed is never torn down' {
    It 'the teardown step states the rule' {
        Assert-Phrase -Text (Get-MusterStep 'Step 8b') -Where 'muster Step 8b' `
            -Phrase 'Work that is neither landed nor pushed is never torn down'
    }

    It 'and names what removing the worktree would cost' {
        Assert-Phrase -Text (Get-MusterStep 'Step 8b') -Where 'muster Step 8b' `
            -Phrase 'the worktree is the only copy of the work and removing it destroys it'
    }
}

Describe 'the anti-attribution rule is in every Done-means variant' {
    BeforeAll {
        # The Done-means blocks are exactly the fences that open with the commit line.
        $script:DoneBlocks = @(Get-CodeFence $script:MusterMd |
            Where-Object { $_.Contains("Implemented and committed on this worktree's branch.") })
    }

    # Four, not three: the `no-mistakes` variant split in two when the CI preflight arrived, because
    # a repository where nothing can report a check needs a worker told to stop at the pull request
    # rather than one told to wait for a green that cannot come. The count is pinned so that adding a
    # fifth variant without carrying the prohibitions into it fails here.
    It 'there are exactly four Done-means blocks' {
        $script:DoneBlocks.Count | Should -Be 4
    }

    It 'each one forbids mentioning Claude, AI or an assistant' {
        foreach ($block in $script:DoneBlocks) {
            $block.Contains('Never mention Claude, AI, or an assistant in any commit message') |
                Should -BeTrue -Because 'every Done-means variant carries the rule 3 prohibition'
        }
    }

    It 'the three push-capable variants extend it to the PR title and body' {
        $pr = @($script:DoneBlocks | Where-Object { $_.Contains('PR title, PR body') })
        $pr.Count | Should -Be 3
    }

    It 'CLAUDE.md rule 3 covers anything reaching a remote or Azure DevOps' {
        Assert-Phrase -Text (Get-DocText $script:HandMd) -Where 'CLAUDE.md rule 3' `
            -Phrase ('Never mention Claude, AI, an assistant, or a model** in anything that ' +
                     'reaches Azure DevOps or a git remote: ticket text, commit messages, PR bodies')
    }

    It 'the landing gate scans the commits for attribution before showing anything' {
        Assert-Phrase -Text (Get-MusterStep 'Step 7 - Gate two') -Where 'the landing gate' `
            -Phrase 'Any hit is a rule 3 violation - report it and do not land until it is fixed'
    }
}

Describe 'the worker writes findings to a file that outlives the session' {
    BeforeAll {
        # Same identification as the anti-attribution block: the Done-means blocks are exactly
        # the fences opening with the commit line.
        $script:ReportBlocks = @(Get-CodeFence $script:MusterMd |
            Where-Object { $_.Contains("Implemented and committed on this worktree's branch.") })
    }

    It 'each of the four Done-means blocks requires report.md at an exact path' {
        $script:ReportBlocks.Count | Should -Be 4
        foreach ($block in $script:ReportBlocks) {
            $block.Contains('Write your findings to `$env:KINGSHAND_HOME\data\<id>\report.md` before you finish.') |
                Should -BeTrue -Because 'every Done-means variant must name the exact report path'
        }
    }

    It 'and requires it even when the work succeeded plainly' {
        foreach ($block in $script:ReportBlocks) {
            $block.Contains('required every time, including when the work succeeded plainly') |
                Should -BeTrue -Because 'a plain success is not an exemption from the report'
        }
    }

    It 'Step 6 reads the report as the primary record' {
        Assert-Phrase -Text (Get-MusterStep 'Step 6 - Completion') -Where 'muster Step 6' `
            -Phrase ('Read `$env:KINGSHAND_HOME\data\<id>\report.md` first. It is the primary ' +
                     'record of what the worker found')
    }

    It 'Step 6 keeps the screen read only as the fallback, and reports a missing file' {
        $step = Get-MusterStep 'Step 6 - Completion'
        Assert-Phrase -Text $step -Where 'muster Step 6' `
            -Phrase 'A missing report is itself worth reporting'
        Assert-Phrase -Text $step -Where 'muster Step 6' `
            -Phrase 'the fallback when `report.md` is missing'
    }

    It 'Step 8b states the report survives teardown and is never deleted' {
        Assert-Phrase -Text (Get-MusterStep 'Step 8b') -Where 'muster Step 8b' `
            -Phrase '`report.md` survives teardown, and must never be deleted as part of cleanup'
    }

    It 'CLAUDE.md owns it beside the brief' {
        Assert-Phrase -Text (Get-DocText $script:HandMd) -Where 'CLAUDE.md What you own' `
            -Phrase '`data\<id>\report.md` - the worker''s durable findings, written by the worker'
    }
}

Describe 'a background worker never opens an interactive prompt' {
    # Worker 7372d875 called AskUserQuestion, drew a menu, and waited over an hour for a keypress
    # nobody could give it, and nothing was watching. herdr now reports that state as `blocked`,
    # but noticing a hang is not permission to cause one, and answering costs the user a decision.
    # The prohibition lives in the brief itself, which is the only text the worker ever reads -
    # a rule anywhere else in this skill would not reach it. Normalised so the sentence stays
    # found when the bullet is re-wrapped.
    BeforeAll {
        $script:PromptBlocks = @(Get-CodeFence $script:MusterMd |
            Where-Object { $_.Contains("Implemented and committed on this worktree's branch.") } |
            ForEach-Object { ConvertTo-NormalisedText $_ })
    }

    It 'the prohibition is in all four Done-means blocks, not just one' {
        $script:PromptBlocks.Count | Should -Be 4
    }

    It 'each one forbids AskUserQuestion and every other interactive surface' {
        foreach ($block in $script:PromptBlocks) {
            $block.Contains('Never call `AskUserQuestion`, and never open any interactive prompt, menu or confirmation of any kind.') |
                Should -BeTrue -Because 'every Done-means variant must forbid asking outright'
            $block.Contains('You are a background agent with nobody attached: there is no one to answer, and the run hangs until it is killed.') |
                Should -BeTrue -Because 'the worker must be told why it cannot ask, or it will read the rule as advice'
        }
    }

    It 'each one sends an unsettled decision to report.md instead of a menu' {
        foreach ($block in $script:PromptBlocks) {
            $block.Contains('write the question into `$env:KINGSHAND_HOME\data\<id>\report.md` - the question, the options you can see, and what you would need in order to choose - then stop and say so in your final message.') |
                Should -BeTrue -Because 'a question that reaches the user is a written one'
        }
    }

    It 'each one prefers a recorded assumption over stopping' {
        foreach ($block in $script:PromptBlocks) {
            $block.Contains('Where you can proceed on a stated assumption instead, do that: record the assumption in `report.md` and continue rather than stopping.') |
                Should -BeTrue -Because 'stopping is the fallback, not the first move'
        }
    }

    It 'Step 2 keeps the incident that stops a future editor softening it' {
        # Asserted against the whole document rather than through Get-MusterStep: the brief template
        # in Step 2 contains its own `## Goal`, `## Scope` and `## Done means` headings, so the
        # step splitter cuts Step 2 off at the first of them.
        $step = Get-DocText $script:MusterMd
        Assert-Phrase -Text $step -Where 'muster Step 2' `
            -Phrase 'The no-interactive-prompts rule is absolute, and it is there because a worker hung on it for hours.'
        Assert-Phrase -Text $step -Where 'muster Step 2' `
            -Phrase 'workers never address the user'
        Assert-Phrase -Text $step -Where 'muster Step 2' `
            -Phrase 'do not soften this back into advice'
    }
}

Describe 'the Hand arms a wait so a finished worker actually wakes it' {
    # Three workers reached stage `ready` and wrote their reports after the Hand said it would
    # report when they were done. Nothing in the skill woke it, so nothing did, and the user found
    # out by asking hours later. The promise needed a mechanism behind it. That mechanism is now
    # an event rather than a loop - herdr blocks until the worker moves - so the assertions pin
    # both the arming discipline and the fact that it is not a poll.
    BeforeAll { $script:Step4 = Get-MusterStep 'Step 4 - Dispatch' }

    It 'arms the wait at dispatch, before anything is said to the user' {
        Assert-Phrase -Text $script:Step4 -Where 'muster Step 4' `
            -Phrase 'Then arm a wait for that worker, before you say anything to the user.'
    }

    It 'requires a harness-tracked background job rather than a detached one' {
        Assert-Phrase -Text $script:Step4 -Where 'muster Step 4' `
            -Phrase 'Run it as a **harness-tracked background job**, never with `&` and never as a detached process.'
        Assert-Phrase -Text $script:Step4 -Where 'muster Step 4' `
            -Phrase 'an untracked process wakes nothing'
    }

    It 'arms one wait per dispatched worker' {
        Assert-Phrase -Text $script:Step4 -Where 'muster Step 4' `
            -Phrase 'Arm **one wait per dispatched worker**.'
    }

    It 'is an event and never a loop' {
        Assert-Phrase -Text $script:Step4 -Where 'muster Step 4' `
            -Phrase 'This is an event, not a poll.'
        Assert-Phrase -Text $script:Step4 -Where 'muster Step 4' `
            -Phrase ('if you find yourself writing a `while` loop around `Get-HerdrAgent`, you ' +
                     'have rebuilt the thing this replaced')
    }

    It 'treats blocked as a wake reason rather than a working state' {
        Assert-Phrase -Text $script:Step4 -Where 'muster Step 4' `
            -Phrase '`blocked` is a wake reason, not a working state.'
        Assert-Phrase -Text $script:Step4 -Where 'muster Step 4' `
            -Phrase ('A worker that goes `blocked` is sitting on an interactive prompt it cannot ' +
                     'get past on its own, and it needs the user - surface it immediately and ' +
                     'load `rally`.')
    }

    # `agent prompt` returns before the state machine moves, so a worker that is about to work
    # still reads `idle` for a moment. A wait armed on that reports a completion that never
    # happened, which is the same silence in a different costume.
    It 'refuses to read a just-submitted worker as finished' {
        Assert-Phrase -Text $script:Step4 -Where 'muster Step 4' `
            -Phrase ('**Never arm the wait immediately after submitting a prompt without ' +
                     'accounting for stale state.**')
        Assert-Phrase -Text $script:Step4 -Where 'muster Step 4' `
            -Phrase 'if you submit anything further yourself, wait for `working` first'
    }

    It 're-arms a timed-out wait rather than assuming the worker is fine' {
        Assert-Phrase -Text $script:Step4 -Where 'muster Step 4' `
            -Phrase 'If the wait times out without the worker finishing, re-arm it.'
    }

    It 'never promises to report back without arming it first' {
        Assert-Phrase -Text $script:Step4 -Where 'muster Step 4' `
            -Phrase '**Never promise to report back without arming this first.**'
        Assert-Phrase -Text $script:Step4 -Where 'muster Step 4' `
            -Phrase 'tell the user plainly that they will need to ask'
    }

    It 'the wake is stated once, as runnable text, and blocks in herdr' {
        $fences = @(Get-CodeFence $script:MusterMd | Where-Object { $_.Contains('WAKE <worker id>') })
        $fences.Count | Should -Be 1 -Because 'the wake is stated once, as runnable text'
        $fences[0].Contains('Wait-HerdrAgentProgress') |
            Should -BeTrue -Because 'the armed wait watches progress as well as liveness'
        # The raw wait, not the guarded ones whose names begin with it. It returns on a
        # classification that was measured wrong in both directions.
        $fences[0] | Should -Not -Match 'Wait-HerdrAgent\s+-Name' -Because 'the raw wait is never armed directly'
        $fences[0].Contains('Start-Sleep') |
            Should -BeFalse -Because 'a sleep in the wake is the polling loop coming back'
    }

    # A stall is a wake reason of its own: the worker is alive, `working` by every state word herdr
    # has, and getting nowhere. Reporting it is the deliverable - acting on it belongs to rally,
    # because a wrong automatic action on a stalled worker is worse than a late human one.
    It 'treats a stall as a wake reason and refuses to act on one' {
        Assert-Phrase -Text $script:Step4 -Where 'muster Step 4' `
            -Phrase '**`stalled` is a wake reason too, and it is not a completion.**'
        Assert-Phrase -Text $script:Step4 -Where 'muster Step 4' `
            -Phrase '**Do not act on a stall on your own**'
        Assert-Phrase -Text $script:Step4 -Where 'muster Step 4' `
            -Phrase ('a wrong automatic action on a stalled worker is worse than a late human one, ' +
                     'and nothing in the wait recovers anything by design')
    }

    It 'names the threshold, allows raising it, and refuses to lower it into false alarms' {
        Assert-Phrase -Text $script:Step4 -Where 'muster Step 4' `
            -Phrase 'against a threshold of twenty'
        Assert-Phrase -Text $script:Step4 -Where 'muster Step 4' `
            -Phrase ('Raise the threshold with `-StallMinutes` for work that is genuinely quiet for ' +
                     'longer; never lower it under fifteen')
        Assert-Phrase -Text $script:Step4 -Where 'muster Step 4' `
            -Phrase 'a false alarm reaching the King costs more than a silent one'
    }

    # Fail closed. An unreadable screen is not a still one, and a worker herdr has lost is not a
    # slow one. Both were reported as "fine" by everything that came before.
    It 'refuses to read an unreadable screen or a missing worker as health' {
        Assert-Phrase -Text $script:Step4 -Where 'muster Step 4' `
            -Phrase ('**`$w.signalReadable` being `$false` means the watch was blind, not that the ' +
                     'worker is fine.**')
        Assert-Phrase -Text $script:Step4 -Where 'muster Step 4' `
            -Phrase 'say plainly that you cannot see the worker rather than reporting it healthy'
        Assert-Phrase -Text $script:Step4 -Where 'muster Step 4' `
            -Phrase '**`reason` of `gone` means herdr has no such worker any more.**'
    }

    It 'says why liveness alone was the wrong question' {
        Assert-Phrase -Text $script:Step4 -Where 'muster Step 4' `
            -Phrase ('**`Wait-HerdrAgentProgress` also watches whether the work is advancing, which ' +
                     'is a different question from whether the worker is alive.**')
        Assert-Phrase -Text $script:Step4 -Where 'muster Step 4' `
            -Phrase ('a worker whose work was genuinely finished read `working` because stray text ' +
                     'sat in its input box')
        Assert-Phrase -Text $script:Step4 -Where 'muster Step 4' `
            -Phrase 'because "nothing happened" is not an event anything can push at you'
    }

    It 'Step 5 counts a stalled worker among the things worth breaking quiet for' {
        Assert-Phrase -Text (Get-MusterStep 'Step 5 - Quiet, and status on request') -Where 'muster Step 5' `
            -Phrase 'say nothing unless a worker is blocked, a worker has stopped advancing'
    }

    # herdr called a worker sitting on an unanswered menu `idle`, and called that same still-blocked
    # worker `done` minutes later while a genuinely finished one read `idle`. A wait with no -Until
    # returns on any of idle, done or blocked, so the raw wait wakes the Hand claiming completion
    # for a worker that is waiting on a person.
    It 'uses the guarded wake and says why the raw one is unsafe' {
        Assert-Phrase -Text $script:Step4 -Where 'muster Step 4' `
            -Phrase ('**Use a guarded wake - `Wait-HerdrAgentProgress` here, or ' +
                     '`Wait-HerdrAgentSettled` where only completion matters - and never ' +
                     '`Wait-HerdrAgent` directly.**')
        Assert-Phrase -Text $script:Step4 -Where 'muster Step 4' `
            -Phrase ('a worker sitting on an unanswered menu was measured reporting `idle`, then ' +
                     '`done` minutes later while a genuinely finished worker reported `idle`')
        Assert-Phrase -Text $script:Step4 -Where 'muster Step 4' `
            -Phrase ('Both guarded wakes re-read that worker''s live screen before they answer, so ' +
                     '`awaitingInput` is the screen and not herdr''s word for it, and `settled`, ' +
                     '`state` and `awaitingInput` mean the same thing in either.')
    }

    It 'lets the screen outrank the state word, and keeps not-settled from becoming one' {
        Assert-Phrase -Text $script:Step4 -Where 'muster Step 4' `
            -Phrase ('`awaitingInput` being `$true` says the same thing off the worker''s own ' +
                     'screen, and it wins over whatever `state` says.')
        Assert-Phrase -Text $script:Step4 -Where 'muster Step 4' `
            -Phrase 'not settled is the absence of an outcome, never an outcome of its own'
    }

    It 'Step 5 keeps quiet from meaning unmonitored' {
        Assert-Phrase -Text (Get-MusterStep 'Step 5 - Quiet, and status on request') -Where 'muster Step 5' `
            -Phrase '**Quiet means no narration, not no monitoring.**'
    }
}

Describe 'completion is evidence, not a state, and there is no transcript to fall back to' {
    # herdr's classification was measured calling a worker on an unanswered menu `idle`, then
    # calling that same still-blocked worker `done` while a genuinely finished worker read `idle`.
    # So a state read as completion tells the Hand a worker waiting on a person has finished - the
    # original five-hour hang made worse, because it is now actively reported as done. What makes
    # the difference is kingshand's own evidence: the report.md every brief requires.
    BeforeAll { $script:Step6 = Get-MusterStep 'Step 6 - Completion' }

    It 'refuses to read any state alone as completion' {
        Assert-Phrase -Text $script:Step6 -Where 'muster Step 6' `
            -Phrase '**No state is proof that a worker finished.**'
        Assert-Phrase -Text $script:Step6 -Where 'muster Step 6' `
            -Phrase '**`idle` alone is not a completion signal, and neither is `done`.**'
    }

    It 'requires all three facts, including kingshand''s own positive evidence' {
        Assert-Phrase -Text $script:Step6 -Where 'muster Step 6' `
            -Phrase '**A worker is finished when all three of these hold, and never on fewer:**'
        Assert-Phrase -Text $script:Step6 -Where 'muster Step 6' `
            -Phrase 'the guarded wake from Step 4 came back settled - `$w.settled` is `$true`'
        Assert-Phrase -Text $script:Step6 -Where 'muster Step 6' `
            -Phrase ('it is not awaiting input - `$w.awaitingInput` is `$false`, which is read off ' +
                     'the worker''s live screen rather than taken from herdr''s word for it')
        Assert-Phrase -Text $script:Step6 -Where 'muster Step 6' `
            -Phrase '`$env:KINGSHAND_HOME\data\<id>\report.md` exists.'
    }

    It 'treats a settled worker with no report as suspicious rather than finished' {
        Assert-Phrase -Text $script:Step6 -Where 'muster Step 6' `
            -Phrase '**A settled worker with no report is suspicious, not finished.**'
        Assert-Phrase -Text $script:Step6 -Where 'muster Step 6' `
            -Phrase 'Do not advance it, do not tear it down, and do not summarise it as complete.'
    }

    It 'refuses to run completion against a blocked worker, and never answers it blindly' {
        Assert-Phrase -Text $script:Step6 -Where 'muster Step 6' `
            -Phrase '**`blocked` is not finished, and it reaches the user immediately.**'
        Assert-Phrase -Text $script:Step6 -Where 'muster Step 6' `
            -Phrase '**never answer that prompt blindly**'
        Assert-Phrase -Text $script:Step6 -Where 'muster Step 6' `
            -Phrase 'surface it to the user now and load `rally`'
    }

    It 'rereads the corrected state rather than trusting a wake that may be minutes old' {
        $fences = @(Get-CodeFence $script:MusterMd | Where-Object { $_.Contains('Get-HerdrAgentState') })
        $fences.Count | Should -BeGreaterOrEqual 1 -Because 'the completion check is stated as runnable text'
        @($fences | Where-Object { $_.Contains('report.md') }).Count |
            Should -BeGreaterOrEqual 1 -Because 'the state and the report are checked together, or the state gets read alone'
    }

    It 'reads the worker''s screen as the fallback, through the module' {
        Assert-Phrase -Text $script:Step6 -Where 'muster Step 6' `
            -Phrase 'the fallback when `report.md` is missing'
        $fences = @(Get-CodeFence $script:MusterMd | Where-Object { $_.Contains('Read-HerdrAgent') })
        $fences.Count | Should -BeGreaterOrEqual 1 -Because 'the screen read is stated as runnable text'
    }

    It 'states plainly that the transcript is not a fallback any more' {
        Assert-Phrase -Text $script:Step6 -Where 'muster Step 6' `
            -Phrase '**There is no transcript to fall back to when it is not.**'
        Assert-Phrase -Text $script:Step6 -Where 'muster Step 6' `
            -Phrase ('Workers inherit `CLAUDE_CODE_CHILD_SESSION` from the Hand''s own session, so ' +
                     'they run with transcript saving off')
        Assert-Phrase -Text $script:Step6 -Where 'muster Step 6' `
            -Phrase ('Do not go looking for a `.jsonl` that will not be there and do not report an ' +
                     'empty search as an empty report.')
    }
}

Describe 'teardown exits the worker cleanly and never kills it' {
    # A force-killed worker leaves its pane echoing every keystroke as literal junk, permanently,
    # and can leave a handle open on the directory about to be removed. Both failures are silent
    # at the moment they are caused, so the prohibition has to be in the step that does it.
    BeforeAll { $script:Step8b = Get-MusterStep 'Step 8b' }

    It 'says an idle worker is still a live process holding the worktree' {
        Assert-Phrase -Text $script:Step8b -Where 'muster Step 8b' `
            -Phrase '**A worker that reads `idle` is not a dead worker.**'
    }

    It 'stops with /exit and forbids reaching for the pid' {
        Assert-Phrase -Text $script:Step8b -Where 'muster Step 8b' `
            -Phrase ('**`Stop-HerdrAgent` exits the worker with `/exit`, and that is not a ' +
                     'formality.**')
        Assert-Phrase -Text $script:Step8b -Where 'muster Step 8b' `
            -Phrase ('A worker killed with `Stop-Process` never sends its terminal-mode reset, ' +
                     'which leaves its pane echoing every later keystroke as literal junk and ' +
                     'unusable for anything, permanently.')
        Assert-Phrase -Text $script:Step8b -Where 'muster Step 8b' `
            -Phrase 'Never reach for the pid.'
    }

    It 'leaves the worktree alone when the stop did not take' {
        Assert-Phrase -Text $script:Step8b -Where 'muster Step 8b' `
            -Phrase ('`$stop.stopped` being false means the worker did not exit. Stop there, ' +
                     'report it, and leave the worktree alone')
    }

    It 'refuses to force a dirty worktree away' {
        Assert-Phrase -Text $script:Step8b -Where 'muster Step 8b' `
            -Phrase ('If `worktree remove` refuses because the tree is dirty, that is unlanded ' +
                     'work you were about to destroy - stop and read it rather than reaching for ' +
                     '`--force`.')
    }
}

Describe 'a blocked worker is never reported as healthy' {
    # survey put a live worker at stage `dispatched` into Underway - "live work progressing on
    # its own" - while its agentState was `blocked` and it had been sitting on a menu for an hour.
    # The one tool that should have surfaced the hang called it fine.
    BeforeAll { $script:SurveyText = Get-DocText $script:SurveyMd }

    It 'routes a blocked worker to King''s Call whatever its stage' {
        Assert-Phrase -Text $script:SurveyText -Where 'the survey bucket mapping' `
            -Phrase ('A worker whose `agentState` is `blocked`, whatever its stage. It cannot ' +
                     'proceed on its own, so it is never Underway.')
    }

    # There are two stopped states and they need opposite advice. `blocked` is a worker sitting on
    # a prompt herdr recognised, and it stays there until somebody answers. `idle` is a worker
    # whose turn ended - usually finished, sometimes stopped by design with its question already
    # written into report.md. Calling the second one hung sends the user chasing a decision that
    # is written down; calling the first one finished loses the hang entirely.
    It 'splits the two stopped states and says they need opposite advice' {
        Assert-Phrase -Text $script:SurveyText -Where 'the survey bucket mapping' `
            -Phrase ('**`blocked` and `idle` are the two stopped states and they need opposite ' +
                     'advice.** Read the state, not the stage.')
    }

    It 'names a blocked worker as sitting on a prompt, and routes the answer through rally' {
        Assert-Phrase -Text $script:SurveyText -Where 'the survey blocked case' `
            -Phrase '`blocked` means the worker is sitting on an interactive prompt.'
        Assert-Phrase -Text $script:SurveyText -Where 'the survey blocked case' `
            -Phrase ('Say what it is waiting on and that the decision is the user''s; `rally` ' +
                     'owns getting their answer into it.')
        Assert-Phrase -Text $script:SurveyText -Where 'the survey blocked case' `
            -Phrase ('A worker''s brief forbids opening such a prompt, so this also means that ' +
                     'brief was not followed.')
    }

    It 'sends an idle worker to its report rather than calling it hung' {
        Assert-Phrase -Text $script:SurveyText -Where 'the survey idle case' `
            -Phrase '`idle` means the worker''s turn ended.'
        Assert-Phrase -Text $script:SurveyText -Where 'the survey idle case' `
            -Phrase ('Point at the report - an `idle` worker has already said what it needed to, ' +
                     'and describing it as hung sends the user chasing a decision that is written ' +
                     'down.')
        Assert-Phrase -Text $script:SurveyText -Where 'the survey idle case' `
            -Phrase ('Never describe an `idle` worker as hung, and never describe a `blocked` one ' +
                     'as having finished.')
    }

    It 'excludes it from Underway at the Underway bucket too' {
        Assert-Phrase -Text $script:SurveyText -Where 'the survey Underway bucket' `
            -Phrase ('A live worker at stage `dispatched`, `implementing` or `gating` **whose ' +
                     '`agentState` is not `blocked`**')
        Assert-Phrase -Text $script:SurveyText -Where 'the survey Underway bucket' `
            -Phrase '`working` is the state that means genuinely progressing.'
        Assert-Phrase -Text $script:SurveyText -Where 'the survey Underway bucket' `
            -Phrase ('A worker whose `agentState` is `blocked` is never Underway, whatever its ' +
                     'stage says.')
    }

    It 'keeps the existing rule that a dead worker recorded as working also needs the user' {
        Assert-Phrase -Text $script:SurveyText -Where 'the survey Underway bucket' `
            -Phrase ('A worker whose intent says it is working but whose `live` is `$false` has ' +
                     'stopped without landing. That is not Underway - it needs the user, so it ' +
                     'goes to King''s Call with what its stage was.')
    }
}

Describe 'the import skill does not write the added date itself' {
    It 'says Add-ProjectEntry stamps it' {
        Assert-Phrase -Text (Get-DocText $script:ImportMd) -Where 'the import skill' `
            -Phrase 'Do not put the date in the description. `Add-ProjectEntry` stamps `(added <date>)` itself'
    }
}

Describe 'an unresolvable base ref is refused, not read as clean' {
    It 'the landing gate verifies the base before gathering evidence' {
        Assert-Phrase -Text (Get-MusterStep 'Step 7 - Gate two') -Where 'the landing gate' `
            -Phrase 'rev-parse --verify --quiet "$base^{commit}"'
    }

    It 'and says empty evidence is never clean evidence' {
        Assert-Phrase -Text (Get-MusterStep 'Step 7 - Gate two') -Where 'the landing gate' `
            -Phrase 'Empty evidence is never clean evidence'
    }
}

Describe 'an entry line is one line' {
    It 'the import skill says so where it shows a posture change' {
        Assert-Phrase -Text (Get-DocText $script:ImportMd) -Where 'the import skill' `
            -Phrase ('An entry line must be exactly one line, however long, with the indented ' +
                     '`path:` line immediately after it')
    }

    It 'and its own example entry is a single line' {
        $fences = @(Get-CodeFence $script:ImportMd | Where-Object { $_.Contains('- acme-api [') })
        $fences.Count | Should -Be 1
        $lines = @($fences[0] -split "`n" | Where-Object { $_.Trim() })
        $lines.Count  | Should -Be 2 -Because 'an entry is one line plus its indented path: line'
        $lines[1].Trim() | Should -BeLike 'path:*'
    }
}

Describe 'the survey digest is four sections, always all four' {
    # A section that renders only when it has something in it is a delta, and a delta cannot be
    # read as a current snapshot. The empty-state sentence is what makes an empty section an
    # answer rather than an omission, so each one is pinned to its exact wording.
    It 'names all four sections in the chat-response contract' {
        $text = Get-DocText $script:SurveyMd
        foreach ($section in @('**King''s Call**', '**Recently Landed**', '**Underway**', '**Charted Next**')) {
            Assert-Phrase -Text $text -Where 'the survey skill' -Phrase $section
        }
    }

    It 'carries the exact empty-state sentence for <section>' -ForEach @(
        @{ section = 'King''s Call';  sentence = 'Empty-state: "Nothing needs your action right now."' }
        @{ section = 'Recently Landed'; sentence = 'Empty-state: "No recent completions are in the current baseline."' }
        @{ section = 'Underway';        sentence = 'Empty-state: "Nothing is underway."' }
        @{ section = 'Charted Next';    sentence = 'Empty-state: "Nothing is queued."' }
    ) {
        Assert-Phrase -Text (Get-DocText $script:SurveyMd) -Where "the survey $section section" -Phrase $sentence
    }

    It 'requires every section to render even when empty' {
        Assert-Phrase -Text (Get-DocText $script:SurveyMd) -Where 'the survey skill' `
            -Phrase 'Every section ALWAYS renders, even when empty, with its short empty-state sentence.'
    }
}

Describe 'survey reads the fleet and never acts on it' {
    It 'states that it is operationally read-only in both modes' {
        Assert-Phrase -Text (Get-DocText $script:SurveyMd) -Where 'the survey skill' `
            -Phrase ('This skill is operationally read-only in both modes. It never dispatches, ' +
                     'steers, lands, merges, tears down, answers a decision, or mutates `state\` ' +
                     'or `data\` other than that single dated report, and its one line in the ' +
                     'index, in explicit file mode.')
    }

    It 'leaves any implied action to muster' {
        Assert-Phrase -Text (Get-DocText $script:SurveyMd) -Where 'the survey skill' `
            -Phrase 'name it in its section and leave the action to `muster`'
    }
}

Describe 'the ported reference skills are loadable and keep their load-bearing rules' {
    # These three are prose procedures with no scripts behind them, so the text IS the mechanism.
    # Each case below pins one sentence that carries the whole point of its section: the rule that
    # a diagnosis does not authorise a change, the rule that the worker does not answer its own
    # finding, and the rule that a prose rule gets a test. Delete any of them and a test fails.

    It '<name> has frontmatter that parses, with a name and a non-empty description' -ForEach @(
        @{ name = 'inquest' }
        @{ name = 'petition' }
        @{ name = 'statute' }
        @{ name = 'audience' }
        @{ name = 'rally' }
        @{ name = 'decree' }
    ) {
        $fm = Get-Frontmatter (Join-Path $script:Root ".claude\skills\$name\SKILL.md")
        $fm['name']        | Should -Be $name -Because 'the frontmatter name must match the skill directory'
        $fm['version']     | Should -Be '1.0.0'
        $fm['description'] | Should -Not -BeNullOrEmpty -Because 'a skill with no description never gets loaded'
        $fm['description'].Length |
            Should -BeGreaterThan 40 -Because 'the description is the trigger, and it must name the situation'
    }

    It 'inquest keeps the three-way causal separation' {
        $text = Get-DocText $script:DiagnosticMd
        Assert-Phrase -Text $text -Where 'inquest' -Phrase 'The **initiating trigger** is'
        Assert-Phrase -Text $text -Where 'inquest' -Phrase 'The **masking condition** is'
        Assert-Phrase -Text $text -Where 'inquest' -Phrase 'The **visible symptom** is'
        Assert-Phrase -Text $text -Where 'inquest' `
            -Phrase 'Do not collapse those facts into one label'
    }

    It 'inquest says a diagnosis is not authorisation to change code' {
        Assert-Phrase -Text (Get-DocText $script:DiagnosticMd) -Where 'inquest' `
            -Phrase ('A diagnosis or implementation-ready recommendation is evidence, not ' +
                     'authorization to change code.')
    }

    It 'inquest turns the reproduction into the regression test' {
        Assert-Phrase -Text (Get-DocText $script:DiagnosticMd) -Where 'inquest' `
            -Phrase 'the reproduction should become the regression test when a fix is authorized'
    }

    It 'petition forbids the worker answering its own finding' {
        Assert-Phrase -Text (Get-DocText $script:AskUserMd) -Where 'petition' `
            -Phrase 'The implementation worker never decides or answers its own ask-user finding.'
    }

    It 'petition keeps all eight authority steps and all five escalation elements' {
        $raw = Get-Content -Path $script:AskUserMd -Raw
        $steps = ($raw -split '(?m)^## ' | Where-Object { $_.StartsWith('Decide who has authority') })
        @([regex]::Matches($steps, '(?m)^\d+\. ')).Count |
            Should -Be 8 -Because 'the authority procedure is eight steps'
        $esc = ($raw -split '(?m)^## ' | Where-Object { $_.StartsWith('User-facing escalation') })
        @([regex]::Matches($esc, '(?m)^\d+\. ')).Count |
            Should -Be 5 -Because 'an escalation states all five elements'
    }

    It 'petition scopes itself to the no-mistakes gate and nothing wider' {
        Assert-Phrase -Text (Get-DocText $script:AskUserMd) -Where 'petition' `
            -Phrase ('A project registered `local-only` or `direct-PR` has no review gate, so it ' +
                     'never produces an ask-user finding')
    }

    It 'petition tests yolo as a string here too' {
        Assert-Phrase -Text (Get-DocText $script:AskUserMd) -Where 'petition' `
            -Phrase "test it as ``-eq 'on'`` and never for bare truthiness"
    }

    It 'statute requires a test for a new prose rule' {
        $text = Get-DocText $script:GuidelinesMd
        Assert-Phrase -Text $text -Where 'statute' `
            -Phrase ('A new rule that matters gets an assertion there in the same change that ' +
                     'introduces it.')
        Assert-Phrase -Text $text -Where 'statute' -Phrase 'tests\Docs.Tests.ps1'
    }

    It 'statute keeps the one-owner rule intact' {
        Assert-Phrase -Text (Get-DocText $script:GuidelinesMd) -Where 'statute' `
            -Phrase ('Every contract - a data format, a state machine, a decision procedure - is ' +
                     'stated in full exactly once.')
    }

    It 'statute carries the anti-attribution rule undiluted' {
        Assert-Phrase -Text (Get-DocText $script:GuidelinesMd) -Where 'statute' `
            -Phrase ('Never mention Claude, AI, an assistant, or a model in anything that reaches ' +
                     'a git remote or Azure DevOps: ticket text, commit messages, PR bodies.')
    }

    It 'statute names the checkpoint that must pass' {
        Assert-Phrase -Text (Get-DocText $script:GuidelinesMd) -Where 'statute' `
            -Phrase 'Invoke-Pester -Path $env:KINGSHAND_HOME\tests'
    }
}

Describe 'audience recaps the session and touches nothing else' {
    # audience's whole value is what it refuses to do: it reads the visible history and nothing on
    # disk, and it does not let a later unrelated message bury a decision nobody answered. Both
    # of those are one sentence each, so both are pinned.
    It 'treats only an ordinary user-role message as a boundary, and never infers authorship' {
        $text = Get-DocText $script:AudienceMd
        Assert-Phrase -Text $text -Where 'audience step 2' `
            -Phrase ('A user boundary is an ordinary user-role message. System, tool, and other ' +
                     'injected operational messages are not user messages.')
        Assert-Phrase -Text $text -Where 'audience step 2' `
            -Phrase ('Never infer user authorship merely because a synthetic message appears in ' +
                     'the user-role transcript.')
    }

    It 'keeps an older open decision open across a later unrelated message' {
        Assert-Phrase -Text (Get-DocText $script:AudienceMd) -Where 'audience step 5' `
            -Phrase ('A later unrelated user message establishes a recap boundary but does not ' +
                     'close an earlier decision.')
    }

    It 'gathers nothing and persists nothing' {
        $text = Get-DocText $script:AudienceMd
        Assert-Phrase -Text $text -Where 'audience step 6' `
            -Phrase 'The normal recap branch is session-history-only.'
        Assert-Phrase -Text $text -Where 'audience step 6' `
            -Phrase ('Do not call Survey, shell commands, fleet snapshots, status readers, ' +
                     'GitHub or browser APIs, tools, or file reads or writes. Create no report, ' +
                     'persist nothing')
    }

    It 'leaves the Survey contract to Survey' {
        Assert-Phrase -Text (Get-DocText $script:AudienceMd) -Where 'audience step 3' `
            -Phrase ('Survey alone owns its gathering, artifact, and response contract. Do not ' +
                     'restate that contract or combine a session recap with Survey output.')
    }

    It 'clears decisions one at a time, ordered by judgement rather than a score' {
        $text = Get-DocText $script:AudienceMd
        Assert-Phrase -Text $text -Where 'audience step 8' `
            -Phrase ('Make clear that impact ordering is the Hand''s judgement rather than a ' +
                     'mechanical score.')
        Assert-Phrase -Text $text -Where 'audience step 9' `
            -Phrase 'Continue one decision at a time until none remain'
    }
}

Describe 'rally states what steering can and cannot do, and protects unlanded work' {
    # Two sentences in this file stand between a stuck worker and a destroyed worktree: the one
    # saying removal takes the work with it, and the one saying a low context reading is not a
    # reason to relaunch anything. Deleting either must fail here.
    It 'says a running worker can now be steered, through the module' {
        $text = Get-DocText $script:StuckMd
        Assert-Phrase -Text $text -Where 'rally' `
            -Phrase '**A running worker can now be steered, and that is new.**'
        Assert-Phrase -Text $text -Where 'rally' `
            -Phrase ('The control plane is herdr, reached only through `bin\Herdr.psm1`. Nothing ' +
                     'here composes a herdr command line by hand')
    }

    # The state herdr reports is wrong in both directions, and the dangerous direction is the one
    # that says a worker on a menu has finished. Nothing in this playbook may decide from it.
    It 'says herdr''s own state is wrong in both directions' {
        $text = Get-DocText $script:StuckMd
        Assert-Phrase -Text $text -Where 'rally' `
            -Phrase '**Do not decide anything here from herdr''s classification.**'
        Assert-Phrase -Text $text -Where 'rally' `
            -Phrase ('minutes later that same still-blocked worker reported `done` while a ' +
                     'genuinely finished worker reported `idle`. The two states inverted.')
        Assert-Phrase -Text $text -Where 'rally' `
            -Phrase ('a worker reading `idle` or `done` may be waiting on a person, and one ' +
                     'reading `blocked` may not be')
    }

    It 'makes the live-viewport check the authority, and never the scrollback' {
        $text = Get-DocText $script:StuckMd
        Assert-Phrase -Text $text -Where 'rally' `
            -Phrase '`Test-HerdrAgentAwaitingInput` is the authority.'
        Assert-Phrase -Text $text -Where 'rally' `
            -Phrase 'Never read `agent_status` yourself.'
        Assert-Phrase -Text $text -Where 'rally' `
            -Phrase ('`recent` and `recent-unwrapped` carry scrollback, so a worker that answered ' +
                     'a menu an hour ago still has that text in its history and would read as ' +
                     'blocked forever')
        Assert-Phrase -Text $text -Where 'the rally escalation' `
            -Phrase ('Confirm it with `Test-HerdrAgentAwaitingInput` rather than herdr''s state ' +
                     'word, and confirm the same way before concluding a worker is *not* blocked')
    }

    It 'keeps steering from being mistaken for a conversation' {
        $text = Get-DocText $script:StuckMd
        Assert-Phrase -Text $text -Where 'rally' `
            -Phrase '**Steering is still not a conversation.**'
        Assert-Phrase -Text $text -Where 'rally' `
            -Phrase ('do not describe a steer as done without checking `Read-HerdrAgent` ' +
                     'afterwards to see that it landed')
    }

    It 'warns that removing the worktree destroys the work, and gives the safe order' {
        $text = Get-DocText $script:StuckMd
        Assert-Phrase -Text $text -Where 'the removal hazard' `
            -Phrase ('Stopping a worker never touches it: `Stop-HerdrAgent` exits the process and ' +
                     'leaves the directory exactly where it was')
        Assert-Phrase -Text $text -Where 'the removal hazard' `
            -Phrase ('Running `git worktree remove` on a stuck worker that holds uncommitted ' +
                     'changes or unpushed commits destroys that work')
        Assert-Phrase -Text $text -Where 'the removal hazard' `
            -Phrase 'Use `Stop-HerdrAgent -Name <worker id>` while anything is unlanded.'
        Assert-Phrase -Text $text -Where 'the removal hazard' `
            -Phrase ('Remove the worktree only once the work is committed and either landed or ' +
                     'pushed, or the user has explicitly authorised discarding it.')
    }

    # A force-killed worker leaves a pane that echoes every keystroke as literal text and cannot
    # take a new agent at all. Nothing recovers it, so the only correct response is to throw the
    # pane away - and the worktree, which is only a directory, is always fine.
    It 'always exits cleanly and never force-kills' {
        $text = Get-DocText $script:StuckMd
        Assert-Phrase -Text $text -Where 'the kill hazard' `
            -Phrase ('`Stop-HerdrAgent` sends `/exit` and waits for the worker to disappear. Never ' +
                     'substitute `Stop-Process` or any other force-kill.')
        Assert-Phrase -Text $text -Where 'the kill hazard' `
            -Phrase '**A force-killed worker leaves its pane permanently unusable.**'
        Assert-Phrase -Text $text -Where 'the kill hazard' `
            -Phrase 'No herdr command recovers it'
    }

    It 'discards an unusable pane and keeps the worktree' {
        $text = Get-DocText $script:StuckMd
        Assert-Phrase -Text $text -Where 'the pane hazard' `
            -Phrase '**When a pane is not reusable, discard it and keep the worktree.**'
        Assert-Phrase -Text $text -Where 'the pane hazard' `
            -Phrase ('`Stop-HerdrAgent` returns `paneReusable`, and it is `$true` only after a ' +
                     'clean exit.')
        Assert-Phrase -Text $text -Where 'the pane hazard' `
            -Phrase 'never assume a relaunch into the old pane will work'
    }

    # Arrow-then-Enter in one call answers the wrong option and reports success. A wrong answer
    # with no error is the worst failure shape available, and the thing being answered wrongly is
    # the user's own decision.
    It 'never batches an arrow and an Enter at a blocked prompt' {
        $text = Get-DocText $script:StuckMd
        Assert-Phrase -Text $text -Where 'the send-keys hazard' `
            -Phrase ('Sending an arrow and Enter in a single herdr invocation **silently selects ' +
                     'the wrong option**')
        Assert-Phrase -Text $text -Where 'the send-keys hazard' `
            -Phrase ('move the cursor, read the screen back with `Read-HerdrAgent` to see where ' +
                     'it actually landed, and only then send Enter')
        Assert-Phrase -Text $text -Where 'the send-keys hazard' `
            -Phrase ('Never compose the two into one call, and never answer a prompt whose ' +
                     'options you have not read.')
    }

    It 'gets the user''s answer before answering a blocked prompt' {
        $text = Get-DocText $script:StuckMd
        Assert-Phrase -Text $text -Where 'the rally escalation' `
            -Phrase '**A blocked worker is the user''s decision, not yours.**'
        Assert-Phrase -Text $text -Where 'the rally escalation' `
            -Phrase ('**Never answer a blocked prompt on the user''s behalf**, and never guess at ' +
                     'an option you have not read.')
    }

    It 'keeps the rule that a low context reading is not wedging' {
        $text = Get-DocText $script:StuckMd
        Assert-Phrase -Text $text -Where 'the wedging definition' `
            -Phrase ('A low context reading is not wedging; modern harnesses auto-compact and ' +
                     'keep going.')
        Assert-Phrase -Text $text -Where 'the wedging definition' `
            -Phrase ('Genuine wedging means looping, unresponsive, repeating the same obstacle, ' +
                     'or truly dead.')
    }

    It 'never lets one task occupy two worktrees' {
        $text = Get-DocText $script:StuckMd
        Assert-Phrase -Text $text -Where 'rally' `
            -Phrase ('Never allocate a second worktree for one task**, because that splits it ' +
                     'across two copies')
        Assert-Phrase -Text $text -Where 'rally' `
            -Phrase ('If the worktree or the ownership cannot be reconciled safely, leave all ' +
                     'state intact and report the task failed or blocked with the conflicting ' +
                     'evidence.')
    }

    It 'reads liveness as presence, not as proof the work is gone' {
        Assert-Phrase -Text (Get-DocText $script:StuckMd) -Where 'rally' `
            -Phrase ('Treat a liveness result as a presence signal, not proof that the worker''s ' +
                     'work is gone.')
    }

    It 'names the six valid stages and sets failed through Set-CrewStage' {
        Assert-Phrase -Text (Get-DocText $script:StuckMd) -Where 'rally' `
            -Phrase ("Set-CrewStage -Stage 'failed'``; the valid stages are exactly " +
                     "``dispatched``, ``implementing``, ``gating``, ``ready``, ``landed``, ``failed``")
    }
}

Describe 'CLAUDE.md declares a load trigger for every reference skill' {
    It 'names <name> with the situation that loads it' -ForEach @(
        @{ name = 'inquest'
           phrase = '`inquest` - load before writing a brief for a reported bug' }
        @{ name = 'petition'
           phrase = '`petition` - load before deciding any ask-user finding' }
        @{ name = 'statute'
           # Single-quoted on purpose: in a double-quoted string the backtick is PowerShell's
           # escape character and the backticks around the skill name silently disappear.
           phrase = '`statute` - load before changing kingshand''s own tracked material' }
        @{ name = 'rally'
           phrase = ('`rally` - load when a worker reads dead or has no live ' +
                     'process') }
        @{ name = 'decree'
           phrase = ('`decree` - load before treating a worker''s investigation ' +
                     'or review as complete') }
    ) {
        Assert-Phrase -Text (Get-DocText $script:HandMd) -Where 'the CLAUDE.md Skills section' -Phrase $phrase
    }

    It 'names audience as a command, and keeps worktree removal behind the recovery skill' {
        $text = Get-DocText $script:HandMd
        Assert-Phrase -Text $text -Where 'the CLAUDE.md Skills section' `
            -Phrase 'Invoke `audience` when the user invokes `/audience` or asks what they missed'
        Assert-Phrase -Text $text -Where 'the CLAUDE.md Skills section' `
            -Phrase 'Never remove a stuck worker''s worktree before loading it.'
    }

    It 'keeps the routing rule and hard rule 1 exactly as they were' {
        $text = Get-DocText $script:HandMd
        Assert-Phrase -Text $text -Where 'CLAUDE.md' -Phrase '**You do not do project work. You route it.**'
        Assert-Phrase -Text $text -Where 'CLAUDE.md rule 1' `
            -Phrase '**You never do a project''s work yourself - a worker does.**'
    }
}

Describe 'the four ported contract sections are present' {
    # Every phrase below is single-quoted on purpose: a backtick is PowerShell's escape character
    # inside a double-quoted string, and these sections are thick with backticked identifiers.
    It 'CLAUDE.md carries exactly one <section> heading' -ForEach @(
        @{ section = 'Intake judgement' }
        @{ section = 'Recovery' }
        @{ section = 'Escalation and etiquette' }
        @{ section = 'Instruction precedence' }
    ) {
        { Get-HandSection $section } | Should -Not -Throw -Because "the $section contract must be its own section"
    }
}

Describe 'intake resolves the project and refuses to read a diagnosis as authority' {
    It 'resolves the project independently and asks once when it cannot' {
        $s = Get-HandSection 'Intake judgement'
        Assert-Phrase -Text $s -Where 'CLAUDE.md intake' `
            -Phrase 'Resolve the project independently for every request.'
        Assert-Phrase -Text $s -Where 'CLAUDE.md intake' `
            -Phrase ('Proceed on one confident match while naming the project in plain language; ' +
                     'ask one concise question when several projects or none plausibly match.')
    }

    It 'says a diagnosis is evidence, not authorization to change code' {
        Assert-Phrase -Text (Get-HandSection 'Intake judgement') -Where 'CLAUDE.md intake' `
            -Phrase ('A diagnostic request, a report, a recommendation or an implementation-ready ' +
                     'finding is evidence, not authorization to change code.')
    }

    It 'keeps the simplest-direct-path rule and refuses a parallel design exercise' {
        $s = Get-HandSection 'Intake judgement'
        Assert-Phrase -Text $s -Where 'CLAUDE.md intake' `
            -Phrase ('Do not build wrappers, control planes, policy layers, custom verifiers or ' +
                     'automation unless the direct path exposes a concrete blocker')
        Assert-Phrase -Text $s -Where 'CLAUDE.md intake' `
            -Phrase ('Never both present a likely-enough solution and launch a parallel design ' +
                     'exercise that is not expected to change it.')
    }

    It 'points at the project''s own memory file rather than restating its contents' {
        # Deliberately not a path. Naming one machine's project directory here is what made this
        # file unusable by anyone else, and the rule it carries - conventions belong to the
        # project, and are read rather than reconstructed - is what actually has to survive.
        $s = Get-HandSection 'Intake judgement'
        Assert-Phrase -Text $s -Where 'CLAUDE.md intake' `
            -Phrase ("Per-project conventions - a project's shorthand, its tagging, the vocabulary " +
                     'its tickets use - live in that project''s own memory file, not here and not ' +
                     'in the registry.')
        Assert-Phrase -Text $s -Where 'CLAUDE.md intake' `
            -Phrase 'copy tag casing rather than reconstructing it'
    }
}

Describe 'recovery reconciles records against reality before taking new work' {
    It 'reconciles before dispatching, and only this machine''s own workers' {
        $s = Get-HandSection 'Recovery'
        Assert-Phrase -Text $s -Where 'CLAUDE.md recovery' `
            -Phrase 'Reconcile durable records against reality before taking new work.'
        Assert-Phrase -Text $s -Where 'CLAUDE.md recovery' `
            -Phrase ('Reconcile only the workers this machine recorded - never claim a worker, ' +
                     'worktree or branch that kingshand did not dispatch.')
    }

    It 'makes a restart a non-event on durable state rather than memory' {
        $s = Get-HandSection 'Recovery'
        Assert-Phrase -Text $s -Where 'CLAUDE.md recovery' -Phrase 'A restart must be a non-event'
        Assert-Phrase -Text $s -Where 'CLAUDE.md recovery' `
            -Phrase ('durable state and the live process inventory - not conversation memory - ' +
                     'are authoritative')
    }

    # Observed on a real restart. Everything durable survived - the server, both workers, crew.json,
    # the report on disk - and the digest reported all of it correctly. What did not survive was the
    # armed wait, because it is a background job owned by the session that armed it. The worker
    # carried on with nothing watching it, and no amount of digest accuracy shows that, because a
    # live worker looks the same whether or not something is waiting on it.
    It 'requires every live worker to have its wait re-armed after a restart' {
        $s = Get-HandSection 'Recovery'
        Assert-Phrase -Text $s -Where 'CLAUDE.md recovery' `
            -Phrase ('**Every live worker needs its wait re-armed at session start, before you do ' +
                     'anything else.**')
        Assert-Phrase -Text $s -Where 'CLAUDE.md recovery' `
            -Phrase 'a restart kills it silently'
        $s | Should -Match 'Wait-HerdrAgentProgress' -Because 'the guarded wait is the one to re-arm, not the raw one'
    }

    # Re-arming after a restart restores the watch, and it also restarts the stall clock from zero.
    # A worker already stuck for an hour looks brand new to a fresh wait, so the recovery section
    # says so rather than letting a reader assume the elapsed silence carried over.
    It 'says a live worker is not necessarily one that is getting anywhere' {
        $s = Get-HandSection 'Recovery'
        Assert-Phrase -Text $s -Where 'CLAUDE.md recovery' `
            -Phrase '**A worker that is alive is not necessarily getting anywhere**'
        Assert-Phrase -Text $s -Where 'CLAUDE.md recovery' `
            -Phrase ('reports a stall with its evidence rather than acting on one - `rally` owns ' +
                     'the response')
        Assert-Phrase -Text $s -Where 'CLAUDE.md recovery' `
            -Phrase ('a worker already stuck before the restart takes the full threshold to be ' +
                     'noticed again')
    }

    It 'routes a dead worker to the recovery skill and a catch-up to survey' {
        $s = Get-HandSection 'Recovery'
        Assert-Phrase -Text $s -Where 'CLAUDE.md recovery' `
            -Phrase ('load `rally` and preserve its worktree and unlanded work ' +
                     'while you reconcile ownership')
        Assert-Phrase -Text $s -Where 'CLAUDE.md recovery' `
            -Phrase '`survey` is the on-demand way to see where everything stands'
    }
}

Describe 'escalation talks in outcomes and leads with evidence' {
    It 'requires outcomes over mechanics, in the user''s own nouns' {
        $s = Get-HandSection 'Escalation and etiquette'
        Assert-Phrase -Text $s -Where 'CLAUDE.md escalation' -Phrase 'Talk in outcomes, not mechanics.'
        Assert-Phrase -Text $s -Where 'CLAUDE.md escalation' `
            -Phrase ('Use the user''s nouns: the ticket, the bug, the fix, the pull request, the ' +
                     'review, the decision, the blocker, the repo, the branch.')
    }

    It 'forbids relaying a report, tool output or a stage label verbatim' {
        Assert-Phrase -Text (Get-HandSection 'Escalation and etiquette') -Where 'CLAUDE.md escalation' `
            -Phrase ('Never relay a worker''s report, tool output, a stage label or a raw command ' +
                     'result verbatim into chat. Read them as evidence, then send the outcome.')
    }

    It 'lets a private evidence file keep the exact identifiers the chat summary may not' {
        Assert-Phrase -Text (Get-HandSection 'Escalation and etiquette') -Where 'CLAUDE.md escalation' `
            -Phrase ('A private evidence file may keep exact identifiers, paths and stage labels ' +
                     'where they are useful; the chat summary that points at it still translates.')
    }

    It 'keeps the evidence-first escalation shape, and uses it for objections too' {
        $s = Get-HandSection 'Escalation and etiquette'
        Assert-Phrase -Text $s -Where 'CLAUDE.md escalation' `
            -Phrase ('Every escalation stands alone and stays concise. Lead directly with the ' +
                     'concrete evidence, then the consequence, then the options where there are ' +
                     'any, then a recommendation.')
        Assert-Phrase -Text $s -Where 'CLAUDE.md escalation' `
            -Phrase ('Use that same evidence-first form for an objection or a clarifying challenge ' +
                     'rather than unsupported deference.')
    }

    It 'names what reaches the user immediately, and what does not' {
        $s = Get-HandSection 'Escalation and etiquette'
        Assert-Phrase -Text $s -Where 'CLAUDE.md escalation' `
            -Phrase 'Work ready for their review or their merge, with the full `https://...` URL.'
        Assert-Phrase -Text $s -Where 'CLAUDE.md escalation' `
            -Phrase 'Anything destructive, irreversible or security-sensitive.'
        Assert-Phrase -Text $s -Where 'CLAUDE.md escalation' `
            -Phrase ('Automatic fixes, retries, routine progress and internal mechanics do not ' +
                     'reach them.')
    }

    It 'translates kingshand''s own internals, including teardown and worktree' {
        $s = Get-HandSection 'Escalation and etiquette'
        Assert-Phrase -Text $s -Where 'the translation table' `
            -Phrase '| `teardown`, stopping a worker, discarding a pane, removing a worktree | cleanup |'
        Assert-Phrase -Text $s -Where 'the translation table' `
            -Phrase ('| `worktree`, base ref, branch | the isolated copy, or the branch, only if ' +
                     'the location matters |')
    }
}

Describe 'rule 5 routes by what the user does with the output, not by its length' {
    # The line-count half of the old rule 5 was unfollowable and therefore ignored: a ten-line
    # dispatch announcement went to chat and nobody noticed the violation, because rendering it
    # would have been worse. A rule that is ignored stops constraining the cases that need it, so
    # the test is what the user DOES with the output - decide and compare, or read once and act.
    # Every phrase is single-quoted on purpose: a backtick is PowerShell's escape character inside
    # a double-quoted string.
    BeforeAll { $script:Rule5 = Get-DocText $script:HandMd }

    It 'is still rule 5, with no hard rule renumbered around it' {
        Assert-Phrase -Text $script:Rule5 -Where 'CLAUDE.md rule 5' `
            -Phrase '5. **Chat is short. When it cannot be short, render it instead of growing the message.**'
        Assert-Phrase -Text $script:Rule5 -Where 'CLAUDE.md rule 6' `
            -Phrase '6. **Escalate real decisions only.**'
    }

    # This rule has swung twice, and the middle version is why the current one is worded as it is.
    # Version one had a line-count threshold and was ignored: "more than 5-6 lines" is unfollowable,
    # and rendering a ten-line dispatch note would have been worse than leaving it. Version two
    # over-corrected into "length is never the test, a long answer is allowed to be a long answer",
    # which read as a permission slip - measured result: lavish was invoked zero times across an
    # entire working session while decisions piled up in chat.
    #
    # Version three is short-by-default with NO number in it. The bright line is that every decision
    # renders; the judgement is whether it still helps at a few sentences. Anyone tempted to put a
    # threshold back should read version one first.
    It 'is short by default without reintroducing a line count' {
        $script:Rule5.Contains('More than 5-6 lines') |
            Should -BeFalse -Because 'a mechanical threshold was tried, was unfollowable, and was ignored'
        $script:Rule5.Contains('a long answer is allowed to be a long answer') |
            Should -BeFalse -Because 'that sentence read as permission, and nothing ever rendered'
        Assert-Phrase -Text $script:Rule5 -Where 'CLAUDE.md rule 5' `
            -Phrase 'That is the default and it needs no asking for.'
    }

    It 'renders every decision, however short it looks' {
        Assert-Phrase -Text $script:Rule5 -Where 'CLAUDE.md rule 5' `
            -Phrase ('**Every decision renders**, however short it looks; a choice buried in a ' +
                     'paragraph is a choice they have to reconstruct.')
    }

    It 'names a long chat message as the failure and rendering as the fix' {
        Assert-Phrase -Text $script:Rule5 -Where 'CLAUDE.md rule 5' `
            -Phrase ('A long chat message is the failure this rule names, not an allowed outcome - ' +
                     'the fix is always to render, never to trim out what matters.')
    }

    It 'leaves everything read once and acted on in chat' {
        Assert-Phrase -Text $script:Rule5 -Where 'CLAUDE.md rule 5' `
            -Phrase ('Chat carries what is read once and acted on: answers, updates, pauses, ' +
                     'notifications.')
    }

    # The shape used to stop at the edge of chat, and outward text is where it matters most: a PR
    # body or a ticket comment is read by somebody with none of the Hand's context.
    It 'applies the same shape to everything written for a person' {
        $s = Get-HandSection 'Escalation and etiquette'
        Assert-Phrase -Text $s -Where 'CLAUDE.md escalation' `
            -Phrase '**Everything written for a person obeys this, not just chat.**'
        $s | Should -Match 'a Teams or Slack\s+reply'
        Assert-Phrase -Text $s -Where 'CLAUDE.md escalation' `
            -Phrase '**Never paste internal shape outward.**'
        Assert-Phrase -Text $s -Where 'CLAUDE.md escalation' `
            -Phrase '**Shorter is not vaguer.**'
    }

    It 'keeps the port trap that 4387 answers silently' {
        Assert-Phrase -Text $script:Rule5 -Where 'CLAUDE.md rule 5' `
            -Phrase ('Windows lavish runs on port 4388; 4387 belongs to WSL and will silently ' +
                     'answer instead, failing with an opaque 500.')
    }

    It 'refuses to render to a surface the user cannot reach' {
        Assert-Phrase -Text $script:Rule5 -Where 'CLAUDE.md rule 5' `
            -Phrase ('Lavish binds to `127.0.0.1`, so it is unreachable when the user is away ' +
                     'from the machine: if they say they cannot open a link, do not render ' +
                     'another one - put short content in chat and ask which surface they want ' +
                     'for long content.')
        Assert-Phrase -Text $script:Rule5 -Where 'CLAUDE.md rule 5' `
            -Phrase 'Rendering to a surface the user cannot reach is worse than not rendering at all.'
    }
}

Describe 'chat is shaped by the kind of message it is' {
    # The Hand said "I'll go quiet and report when they're done" and left the user with nothing
    # to act on for 5-6 hours. An update, an answer and an escalation fail in different ways, so
    # each carries its own shape here rather than one generic brevity rule.
    BeforeAll { $script:Shape = Get-HandSection 'Escalation and etiquette' }

    It 'scopes the shaping to the kind of message' {
        Assert-Phrase -Text $script:Shape -Where 'CLAUDE.md escalation' `
            -Phrase '**Shape a chat message by what kind of message it is.**'
    }

    # Brevity and plain words are the default for everyone, not a per-user preference. They were
    # briefly written into instructions.example.md, which would have made a reader who never edits
    # that file live with walls of reference-style text. The rendered surface is where length is
    # allowed; the terminal is read once.
    It 'requires plain words over file-and-line references' {
        Assert-Phrase -Text $script:Shape -Where 'CLAUDE.md escalation' `
            -Phrase '**Write like a person, and write less.**'
        Assert-Phrase -Text $script:Shape -Where 'CLAUDE.md escalation' `
            -Phrase 'Not `rev4, point 3, src/thing.ts:43:46`'
    }

    It 'puts length on the rendered surface and brevity in chat' {
        Assert-Phrase -Text $script:Shape -Where 'CLAUDE.md escalation' `
            -Phrase 'Length belongs to the rendered surface, not to chat.'
        Assert-Phrase -Text $script:Shape -Where 'CLAUDE.md escalation' `
            -Phrase 'if it fits in two sentences, it is two sentences'
    }

    It 'gives an update or a pause state, what is owed, and one next action' {
        Assert-Phrase -Text $script:Shape -Where 'the update shape' `
            -Phrase ('**An update or a pause** leads with current state, then what the user owes, ' +
                     'then one concrete next action.')
        Assert-Phrase -Text $script:Shape -Where 'the update shape' `
            -Phrase 'Going quiet without all three leaves them nothing to act on.'
    }

    It 'leads an answer with the answer and never bolts a task onto it' {
        Assert-Phrase -Text $script:Shape -Where 'the answer shape' `
            -Phrase ('**An answer to a question** leads with the answer - no preamble, and no ' +
                     'restating the question.')
        Assert-Phrase -Text $script:Shape -Where 'the answer shape' `
            -Phrase 'Cap a list at five items and split it by priority beyond that.'
        Assert-Phrase -Text $script:Shape -Where 'the answer shape' `
            -Phrase ('**Do not append a next action to a plain answer**; if the user asks what ' +
                     'something does, ending with a task is noise.')
    }

    It 'leaves an escalation on the evidence-first order, and says so' {
        Assert-Phrase -Text $script:Shape -Where 'the escalation shape' `
            -Phrase ('**An escalation keeps the evidence-first order above, unchanged**: ' +
                     'evidence, then consequence, then options, then a recommendation.')
        Assert-Phrase -Text $script:Shape -Where 'the escalation shape' `
            -Phrase ('That order exists so the user can judge before being steered, and it wins ' +
                     'over leading with an action.')
    }

    # This one reversed deliberately, and it is the only place the default shape and the old
    # wording actually conflicted. The old rule was "never restate on every turn, because unchanged
    # state repeated is noise" - written for a reader who still has the last message on screen. The
    # shape is now on by default for a reader who does not, so the bias flips: restate unless it is
    # a fast exchange where nothing moved. Noise costs a skim; a lost reader costs the thread.
    It 'restates state by default, biasing toward restating rather than assuming' {
        Assert-Phrase -Text $script:Shape -Where 'CLAUDE.md escalation' `
            -Phrase ('**Restate where things stand in any message the user might act on**, and ' +
                     'after any gap.')
        Assert-Phrase -Text $script:Shape -Where 'CLAUDE.md escalation' `
            -Phrase 'Assume the last message is no longer on screen, because usually it is not.'
        Assert-Phrase -Text $script:Shape -Where 'CLAUDE.md escalation' `
            -Phrase ('When in doubt, restate - a reader who already knew skims one line, a reader ' +
                     'who did not was otherwise lost.')
        $script:Shape | Should -Not -Match 'never on\s+every turn' `
            -Because 'the old rule said the opposite and both cannot stand'
    }

    It 'gives every estimate in concrete units' {
        Assert-Phrase -Text $script:Shape -Where 'CLAUDE.md escalation' `
            -Phrase ('Give every estimate in concrete units - minutes, hours, file counts, test ' +
                     'counts - and never "quick", "shortly" or "a bit".')
    }

    It 'keeps the etiquette that already held, and leaves survey its own contract' {
        Assert-Phrase -Text $script:Shape -Where 'CLAUDE.md escalation' `
            -Phrase 'No preamble and no closing pleasantries.'
        Assert-Phrase -Text $script:Shape -Where 'CLAUDE.md escalation' `
            -Phrase 'Batch non-urgent updates into the next natural reply.'
        Assert-Phrase -Text $script:Shape -Where 'CLAUDE.md escalation' `
            -Phrase ('A skill that owns its own chat contract, such as `survey`, keeps that ' +
                     'contract.')
    }
}

Describe 'a current explicit instruction overrides a standing rule, within its exact scope' {
    It 'states the override and requires it to name what it governs' {
        $s = Get-HandSection 'Instruction precedence'
        Assert-Phrase -Text $s -Where 'CLAUDE.md precedence' `
            -Phrase ('A current, explicit, concrete instruction from the user overrides any ' +
                     'conflicting standing rule written above.')
        Assert-Phrase -Text $s -Where 'CLAUDE.md precedence' `
            -Phrase 'it must identify the concrete action, object, or bounded set it governs'
    }

    It 'refuses to infer, broaden, or bank the override' {
        $s = Get-HandSection 'Instruction precedence'
        Assert-Phrase -Text $s -Where 'CLAUDE.md precedence' `
            -Phrase ('Never infer an override, broaden its scope, apply it by analogy, carry it to ' +
                     'another object or action, or convert one request into standing authority.')
        Assert-Phrase -Text $s -Where 'CLAUDE.md precedence' `
            -Phrase 'Ambiguous scope or conflict still requires one concise clarification before action.'
    }

    It 'keeps the destructive-action boundary and refuses to rigidly block a stated one' {
        $s = Get-HandSection 'Instruction precedence'
        Assert-Phrase -Text $s -Where 'CLAUDE.md precedence' `
            -Phrase ('Destructive, irreversible, security-sensitive, discard and merge actions ' +
                     'still require the user to state that concrete action explicitly')
        Assert-Phrase -Text $s -Where 'CLAUDE.md precedence' `
            -Phrase 'a rule written here must not rigidly block the action'
    }

    It 'denies +yolo the standing of an explicit instruction' {
        Assert-Phrase -Text (Get-HandSection 'Instruction precedence') -Where 'CLAUDE.md precedence' `
            -Phrase ('A project''s registered `+yolo` posture is standing routine authority only, ' +
                     'and is never a substitute for a current explicit instruction where an ' +
                     'explicit action is required.')
    }
}

Describe 'the backlog is a durable queue of work items, never of workers' {
    # Before the backlog existed, a unit of work was only a brief on disk plus a row in
    # crew.json, so anything not yet dispatched was invisible and nothing could carry a
    # dependency or a hold. The queue fixes that only while it stays a queue of WORK: the moment
    # a worker is filed as a backlog item, crew.json and the backlog both claim to own workers
    # and neither can be trusted. Every phrase here is single-quoted on purpose - a backtick is
    # PowerShell's escape character inside a double-quoted string.
    BeforeAll { $script:Backlog = Get-HandSection 'Backlog contract' }

    It 'CLAUDE.md carries exactly one Backlog contract section' {
        { Get-HandSection 'Backlog contract' } |
            Should -Not -Throw -Because 'the backlog contract must be its own section, not a new hard rule'
    }

    It 'does not renumber the hard rules to make room for it' {
        $text = Get-DocText $script:HandMd
        Assert-Phrase -Text $text -Where 'CLAUDE.md rule 1' `
            -Phrase '1. **You never do a project''s work yourself - a worker does.**'
        Assert-Phrase -Text $text -Where 'CLAUDE.md rule 3' `
            -Phrase '3. **Never mention Claude, AI, an assistant, or a model**'
        Assert-Phrase -Text $text -Where 'CLAUDE.md rule 6' `
            -Phrase '6. **Escalate real decisions only.**'
    }

    It 'names data\backlog.md as the durable queue, kept with tasks-axi' {
        Assert-Phrase -Text $script:Backlog -Where 'CLAUDE.md backlog contract' `
            -Phrase '`data\backlog.md` is the durable queue, maintained with `tasks-axi` run from `$env:KINGSHAND_HOME`.'
    }

    It 'tracks work items only and never workers, with crew.json owning workers' {
        Assert-Phrase -Text $script:Backlog -Where 'CLAUDE.md backlog contract' `
            -Phrase ('**It tracks work items only, never workers - `state\crew.json` owns ' +
                     'workers, and the two must not be confused.**')
        Assert-Phrase -Text $script:Backlog -Where 'CLAUDE.md backlog contract' `
            -Phrase ('a backlog item is the unit of work itself, and it exists before any worker ' +
                     'does and after every worker is torn down')
    }

    It 'updates on every dispatch, completion and decision' {
        Assert-Phrase -Text $script:Backlog -Where 'CLAUDE.md backlog contract' `
            -Phrase 'Update the backlog on every dispatch, completion and decision for a work item.'
    }

    It 're-evaluates the queue after a completion, dispatching only on cleared holds' {
        Assert-Phrase -Text $script:Backlog -Where 'CLAUDE.md backlog contract' `
            -Phrase ('Re-evaluate queued work after every completion, dispatching only when ' +
                     'dependencies and holds have cleared.')
    }

    It 'files a pending user decision as its own held item, with the exact hold command' {
        Assert-Phrase -Text $script:Backlog -Where 'CLAUDE.md backlog contract' `
            -Phrase 'A pending user decision worth tracking is filed as its own work item and held with'
        Assert-Phrase -Text $script:Backlog -Where 'CLAUDE.md backlog contract' `
            -Phrase '`tasks-axi hold <id> --reason "<reason>" --kind captain`'
    }

    It 'keeps notes free of state that rots, and inspects before replacing a body' {
        Assert-Phrase -Text $script:Backlog -Where 'CLAUDE.md backlog contract' `
            -Phrase ('Keep free-form notes free of temporary paths, moving versions and copied ' +
                     'state that will rot.')
        Assert-Phrase -Text $script:Backlog -Where 'CLAUDE.md backlog contract' `
            -Phrase 'Inspect a task''s note before replacing its considered body'
    }

    It 'leaves the schema and the flags to .tasks.toml and tasks-axi --help' {
        Assert-Phrase -Text $script:Backlog -Where 'CLAUDE.md backlog contract' `
            -Phrase ('`.tasks.toml` and current `tasks-axi --help` own the backlog schema, ' +
                     'retention and command syntax.')
        Assert-Phrase -Text $script:Backlog -Where 'CLAUDE.md backlog contract' `
            -Phrase 'Do not restate flags here; read the help.'
    }

    It 'is listed among what the Hand owns' {
        Assert-Phrase -Text (Get-DocText $script:HandMd) -Where 'CLAUDE.md What you own' `
            -Phrase '`data\backlog.md` - the durable work queue. Maintained via `tasks-axi`'
    }
}

Describe 'muster keeps the backlog current across the whole lifecycle' {
    # A queue is only durable if every lifecycle step writes to it. Intake is the load-bearing
    # one: filing the item BEFORE the brief is what makes work that never gets dispatched
    # visible at all, which is the whole reason the queue exists.
    It 'Step 1 files the item before the brief is written' {
        $step = Get-MusterStep 'Step 1 - Intake'
        Assert-Phrase -Text $step -Where 'muster Step 1' `
            -Phrase '**Record the unit of work in the backlog before its brief is written.**'
        Assert-Phrase -Text $step -Where 'muster Step 1' `
            -Phrase ('Filing the item here is what makes a unit of work visible before anything ' +
                     'is dispatched, so do it even when the dispatch gate is about to refuse it.')
        Assert-Phrase -Text $step -Where 'muster Step 1' `
            -Phrase 'Ids are slug-shaped - letters, digits, `.`, `_` and `-`, with no spaces.'
    }

    It 'Step 1 points at the contract rather than restating it' {
        Assert-Phrase -Text (Get-MusterStep 'Step 1 - Intake') -Where 'muster Step 1' `
            -Phrase ('`CLAUDE.md`''s Backlog contract owns why, and `tasks-axi --help` owns ' +
                     'the flags.')
    }

    It 'Step 4 marks the item started after the dispatch is recorded' {
        Assert-Phrase -Text (Get-MusterStep 'Step 4 - Dispatch') -Where 'muster Step 4' `
            -Phrase 'Then mark the backlog item started, so the queue and the workers agree on what is under way'
    }

    It 'Step 6 records the outcome and refuses to close the item there' {
        $step = Get-MusterStep 'Step 6 - Completion'
        Assert-Phrase -Text $step -Where 'muster Step 6' `
            -Phrase '**Record the outcome on the backlog item**, pointing at the report rather than restating it'
        Assert-Phrase -Text $step -Where 'muster Step 6' `
            -Phrase ('Do not mark it done here. The item closes at Step 8 or Step 8a, when the ' +
                     'work has actually landed.')
    }

    It 'Step 8 closes the item once the local merge has landed' {
        Assert-Phrase -Text (Get-MusterStep 'Step 8 - Land') -Where 'muster Step 8' `
            -Phrase 'The work has landed, so close the backlog item'
    }

    It 'Step 8a records the pull request and leaves the item open until the merge' {
        $step = Get-MusterStep 'Step 8a'
        Assert-Phrase -Text $step -Where 'muster Step 8a' `
            -Phrase 'Record the outcome on the backlog item as well - the pull request is what this work produced'
        Assert-Phrase -Text $step -Where 'muster Step 8a' `
            -Phrase ('Leave the item open at `ready`. Nothing has landed yet, and an item closed ' +
                     'here would report a merge the user has not made.')
        Assert-Phrase -Text $step -Where 'muster Step 8a' `
            -Phrase 'close the backlog item in the same breath'
    }

    It 'every backlog command in muster runs from $env:KINGSHAND_HOME' {
        # tasks-axi resolves .tasks.toml from the current directory, so a command run from
        # anywhere else silently reads or writes a different backlog, or none.
        $fences = @(Get-CodeFence $script:MusterMd | Where-Object { $_.Contains('tasks-axi ') })
        $fences.Count | Should -BeGreaterOrEqual 6 -Because 'intake, dispatch, completion and both landing paths each write to the queue'
        foreach ($fence in $fences) {
            $fence.Contains('Set-Location $env:KINGSHAND_HOME') |
                Should -BeTrue -Because 'tasks-axi resolves .tasks.toml from the current directory'
        }
    }
}

Describe 'survey Charted Next reads the real queue' {
    # Charted Next was empty by construction - the skill said kingshand kept no backlog. Now it
    # has one, and the section that was permanently empty must actually read it.
    BeforeAll { $script:SurveyQueue = Get-DocText $script:SurveyMd }

    It 'no longer claims kingshand keeps no backlog' {
        $script:SurveyQueue.Contains('Kingshand keeps no backlog') |
            Should -BeFalse -Because 'the queue exists now, and Charted Next reads it'
    }

    It 'names the three kinds of queued work it surfaces' {
        Assert-Phrase -Text $script:SurveyQueue -Where 'the survey Charted Next bucket' `
            -Phrase ('Real queued work read from `data\backlog.md`: an item not yet dispatched, ' +
                     'an item whose dependencies have not cleared, and an item held for ' +
                     'something other than the user')
    }

    It 'keeps an un-dispatched brief and its queued item in exactly one bucket' {
        Assert-Phrase -Text $script:SurveyQueue -Where 'the survey Charted Next bucket' `
            -Phrase 'the two never both render for the same unit of work'
    }

    It 'still surfaces diagnostics there, and still keeps the empty state' {
        Assert-Phrase -Text $script:SurveyQueue -Where 'the survey Charted Next bucket' `
            -Phrase 'Any `$snap.diagnostics` entry, as an action-free integrity warning'
        Assert-Phrase -Text $script:SurveyQueue -Where 'the survey Charted Next bucket' `
            -Phrase ('When the queue really is empty and there is nothing else to warn about, ' +
                     'render "Nothing is queued." rather than dropping the section.')
    }

    It 'reads the queue with its own reader and never hand-scans the file' {
        Assert-Phrase -Text $script:SurveyQueue -Where 'the survey gather step' `
            -Phrase 'The snapshot covers the fleet; it does not cover the queue.'
        Assert-Phrase -Text $script:SurveyQueue -Where 'the survey gather step' `
            -Phrase ('`tasks-axi` is `data\backlog.md`''s own reader, and hand-scanning that file ' +
                     'instead is exactly what the rule does forbid')
    }

    It 'stays read-only against the queue' {
        Assert-Phrase -Text $script:SurveyQueue -Where 'the survey read-only section' `
            -Phrase ('**Reading the backlog is a read.** Never add, start, hold, unhold, update ' +
                     'or close a backlog item from this skill')
    }

    It 'treats an unreadable queue as a diagnostic rather than an empty one' {
        Assert-Phrase -Text $script:SurveyQueue -Where 'the survey gather step' `
            -Phrase ('say the queue could not be read and do not render Charted Next as though ' +
                     'it were empty')
    }
}

Describe 'chronicle keeps the description that is its only trigger' {
    # Nothing runs chronicle. There is no hook, no timer and no scheduled pass - it fires because the
    # Hand reads this description in the skill listing every turn and recognises the situation
    # in it. Delete the situation from the description and the skill still loads on /chronicle and
    # otherwise never runs again, silently. That is why the trigger clause is pinned verbatim
    # rather than checked for a keyword.
    BeforeAll {
        $script:ChronicleFm   = Get-Frontmatter $script:ChronicleMd
        $script:ChronicleText = Get-DocText $script:ChronicleMd
    }

    It 'has frontmatter that parses, with a name and a non-empty description' {
        $script:ChronicleFm['name']        | Should -Be 'chronicle'
        $script:ChronicleFm['version']     | Should -Be '1.0.0'
        $script:ChronicleFm['description'] | Should -Not -BeNullOrEmpty
        $script:ChronicleFm['description'].Length | Should -BeGreaterThan 40
    }

    It 'is invocable by the user as a command' {
        $script:ChronicleFm['user-invocable'] | Should -Be 'true'
        $script:ChronicleFm['description'].Contains('when the user invokes /chronicle') |
            Should -BeTrue -Because 'the command form must stay in the description'
    }

    It 'keeps the self-trigger clause that makes it fire without anything calling it' {
        $script:ChronicleFm['description'].Contains(
            'before a session reset or context compaction, or periodically to keep operational memory current') |
            Should -BeTrue -Because 'that clause is the entire mechanism by which chronicle ever runs'
    }

    It 'CLAUDE.md declares the same trigger inline, and says nothing runs it' {
        $text = Get-DocText $script:HandMd
        Assert-Phrase -Text $text -Where 'the CLAUDE.md Skills section' `
            -Phrase ('Invoke `chronicle` when the user invokes `/chronicle`, before a session reset or ' +
                     'context compaction, or periodically to keep operational memory current.')
        Assert-Phrase -Text $text -Where 'the CLAUDE.md Skills section' `
            -Phrase 'Nothing runs it on your behalf either.'
    }
}

Describe 'chronicle curates memory rather than accumulating it' {
    BeforeAll { $script:ChronicleText = Get-DocText $script:ChronicleMd }

    It 'treats an absent memory file as meaningful rather than as an error' {
        Assert-Phrase -Text $script:ChronicleText -Where 'chronicle' `
            -Phrase ('Both are created lazily and are absent until there is something to store. ' +
                     'Absence is meaningful, not an error, and it is never an invitation to ' +
                     'manufacture content or write a placeholder.')
    }

    It 'counts its own marker bytes against the budget' {
        Assert-Phrase -Text $script:ChronicleText -Where 'chronicle' `
            -Phrase ('marker bytes are counted content: they are measured against the ' +
                     'startup-memory budget exactly like prose')
    }

    It 'names both tier clocks and exempts pinned from them' {
        Assert-Phrase -Text $script:ChronicleText -Where 'the chronicle tier table' `
            -Phrase 'An entry whose age is 30 days or more since its last-reinforced date is stale'
        Assert-Phrase -Text $script:ChronicleText -Where 'the chronicle tier table' `
            -Phrase 'An entry whose age is 7 days or more since its last-reinforced date is stale'
        Assert-Phrase -Text $script:ChronicleText -Where 'the chronicle tier table' `
            -Phrase 'no clock is ever read for it'
    }

    It 'requires evidence from this session before an entry is reinforced' {
        Assert-Phrase -Text $script:ChronicleText -Where 'chronicle step 4' `
            -Phrase ('Reinforcement requires independent evidence from this session that you can ' +
                     'name in the receipt. Plausibility, importance, prior knowledge and the ' +
                     "entry's own text are not evidence")
    }

    It 'retires stale material to a cold archive instead of deleting it' {
        Assert-Phrase -Text $script:ChronicleText -Where 'the chronicle cold tier' -Phrase 'Stale never means deleted.'
        Assert-Phrase -Text $script:ChronicleText -Where 'the chronicle cold tier' `
            -Phrase ('Pruning an entry from a memory file always means moving it to ' +
                     '`$env:KINGSHAND_HOME\data\memory-archive.md`')
        Assert-Phrase -Text $script:ChronicleText -Where 'chronicle' `
            -Phrase 'A stale unique fact is never deleted, only archived.'
    }

    It 'reads before it writes, and rewrites rather than appending forever' {
        Assert-Phrase -Text $script:ChronicleText -Where 'chronicle step 2' `
            -Phrase ('Read-before-write is not optional: a rewrite decided without the current ' +
                     'text is an append in disguise.')
        Assert-Phrase -Text $script:ChronicleText -Where 'chronicle' `
            -Phrase 'Rewrite and prune rather than appending forever.'
    }

    It 'leaves the routing table to CLAUDE.md rather than restating it' {
        Assert-Phrase -Text $script:ChronicleText -Where 'chronicle' `
            -Phrase "Route each finding using ``CLAUDE.md``'s Knowledge routing section."
        Assert-Phrase -Text $script:ChronicleText -Where 'chronicle' `
            -Phrase 'That section owns the mapping; this skill owns the pass. Do not restate the routing rules here.'
    }

    It 'never writes a project itself, and never ends a pass over budget' {
        Assert-Phrase -Text $script:ChronicleText -Where 'chronicle' `
            -Phrase ('It never touches a project, and hard rule 1 is not suspended for a ' +
                     'curation pass.')
        Assert-Phrase -Text $script:ChronicleText -Where 'chronicle step 8' `
            -Phrase ('Never end a pass over budget as an accepted exception, and never describe ' +
                     'the session as reset-safe while the total is over budget or an exception is ' +
                     'unresolved.')
    }

    It 'refuses to make a skill the destination for a finding' {
        Assert-Phrase -Text $script:ChronicleText -Where 'the chronicle scope exclusion' `
            -Phrase ('The chronicle pass itself must never create or edit a skill as a destination for ' +
                     'a finding.')
        Assert-Phrase -Text $script:ChronicleText -Where 'the chronicle scope exclusion' `
            -Phrase '`statute`'
    }

    It 'measures the budget through the module rather than by eye' {
        $fences = @(Get-CodeFence $script:ChronicleMd | Where-Object { $_.Contains('Get-MemoryReport') })
        $fences.Count | Should -Be 1 -Because 'the measurement is stated once, as runnable text'
        $fences[0].Contains('Import-Module .\bin\Memory.psm1') |
            Should -BeTrue -Because 'the estimate has one owner, and it is the module'
        $fences[0].Contains('Set-Location $env:KINGSHAND_HOME') |
            Should -BeTrue -Because 'the module path is resolved from kingshand, not from a worktree'
    }
}

Describe 'a correction is written the moment it happens, into an inbox chronicle drains' {
    # Two halves of one mechanism, and neither works alone. Nothing made a learning get written when
    # it was learned - chronicle only ever runs when the King asks for it, which is the "if someone
    # remembers" they rejected - and the offload sweep had no destination the Hand could write, so a
    # sweep that ran could never actually offload anything. The obligation is prose in an
    # always-loaded file and the drain is prose in a skill, so the text IS the mechanism here.
    BeforeAll {
        $script:CorrectionOwned    = Get-HandSection 'What you own'
        $script:CorrectionRule     = Get-HandSection 'When the King corrects you'
        $script:ChronicleText      = Get-DocText $script:ChronicleMd
    }

    It 'CLAUDE.md obliges the write in the same turn as the correction' {
        Assert-Phrase -Text $script:CorrectionRule -Where 'CLAUDE.md When the King corrects you' `
            -Phrase ('**When the King corrects something you got wrong, append one entry to ' +
                     '`data\corrections.md` in that same turn**')
        Assert-Phrase -Text $script:CorrectionRule -Where 'CLAUDE.md When the King corrects you' `
            -Phrase 'the date, what you did, what they said, and the rule that follows from it'
    }

    It 'CLAUDE.md defines it as an inbox rather than a third memory file' {
        Assert-Phrase -Text $script:CorrectionRule -Where 'CLAUDE.md When the King corrects you' `
            -Phrase ('an append-only inbox, created on its first entry, never loaded at session ' +
                     'start and never budgeted, and the next `chronicle` pass drains each entry to ' +
                     'its owner')
        Assert-Phrase -Text $script:CorrectionRule -Where 'CLAUDE.md When the King corrects you' `
            -Phrase ('curating it now is the cost that stops the write happening at all, and ' +
                     'leaving it for whenever somebody remembers to chronicle is how the ' +
                     'correction is lost')
    }

    It 'CLAUDE.md names the inbox among what the Hand owns' {
        Assert-Phrase -Text $script:CorrectionOwned -Where 'CLAUDE.md What you own' `
            -Phrase ('`data\corrections.md` - the correction inbox, appended to the moment the King ' +
                     'corrects you and drained by the next `chronicle` pass. An inbox, not a third ' +
                     'memory file')
    }

    It 'chronicle drains that inbox on every invocation' {
        Assert-Phrase -Text $script:ChronicleText -Where 'the chronicle drain step' `
            -Phrase '**It is an inbox and not a third memory file:**'
        Assert-Phrase -Text $script:ChronicleText -Where 'the chronicle drain step' `
            -Phrase '**Every invocation drains it, before the knowledge sweep below**'
        Assert-Phrase -Text $script:ChronicleText -Where 'the chronicle drain step' `
            -Phrase ('Route each entry to its most specific owner**, using `CLAUDE.md`''s Knowledge ' +
                     'routing section, which owns that mapping')
    }

    # Pinned before step 2's read, not merely before the sweep. A drain landing between steps 7 and 8
    # arrives with archival, consolidation, offload and eviction already spent, so the pass ends over
    # budget and step 8 opens a decision the reduction rungs could have absorbed. And a drain between
    # step 2 and step 3 is the other end of the same problem: step 3 plans "before editing" against a
    # read the drain's own writes have already made stale.
    It 'the drain runs before the mandatory read, not after the reduction rungs' {
        Assert-Phrase -Text $script:ChronicleText -Where 'the chronicle drain step' `
            -Phrase ('**Every invocation drains it, before the knowledge sweep below** and before ' +
                     'step 2 reads the memory files')
        Assert-Phrase -Text $script:ChronicleText -Where 'the chronicle drain step' `
            -Phrase ('step 3 plans before editing, and it plans against text that already holds ' +
                     'every routed correction rather than against a read the drain has since made ' +
                     'stale')
        Assert-Phrase -Text $script:ChronicleText -Where 'the chronicle drain step' `
            -Phrase ('A drain that lands after step 7 has spent archival, consolidation, offload ' +
                     'and eviction pushes the total over budget with every reduction rung already ' +
                     'gone')
    }

    # Both the step that must act on it and the step that consumes its output name the same order, so
    # a reader working top-down drains at the right moment rather than learning about it afterwards.
    It 'steps 2 and 3 agree on when the drain runs' {
        Assert-Phrase -Text $script:ChronicleText -Where 'the chronicle mandatory read' `
            -Phrase ('**Drain the correction inbox before this read**, under Draining the ' +
                     'correction inbox below, so what you read here is already the text every ' +
                     'routed correction has landed in')
        Assert-Phrase -Text $script:ChronicleText -Where 'the chronicle retention plan' `
            -Phrase ('**The drained correction inbox is an input to this plan**, and the drain has ' +
                     'already run under step 2')
    }

    # CLAUDE.md indexes a durable data\ file as it is written, and the correction obligation is the
    # one deliberate deferral - an obligation that also has to index is the one skipped mid-turn. So
    # the deferral has to name the pass that pays the debt, or the inbox stays drift until some later
    # session happens to chronicle.
    It 'the drain itself indexes the inbox, and says why the write defers it' {
        Assert-Phrase -Text $script:ChronicleText -Where 'the chronicle drain step' `
            -Phrase ('in the knowledge sweep''s index step below alongside the memory files this ' +
                     'pass touched')
        Assert-Phrase -Text $script:ChronicleText -Where 'the chronicle drain step' `
            -Phrase ('a mid-turn correction write that also has to index is the cost that stops ' +
                     'the write happening at all')
        Assert-Phrase -Text $script:ChronicleText -Where 'the chronicle index step' `
            -Phrase ('`learnings.md`, `memory-archive.md` and the drained `corrections.md` are ' +
                     'durable files under `data\` like any other')
    }

    # The archive schema is source file, tier and last-reinforced date, and an inbox entry has none
    # of the three. With no shape of its own the drain either invents a tier nothing ever measured
    # or writes a malformed archive line.
    It 'a drained correction archives under its own provenance shape' {
        Assert-Phrase -Text $script:ChronicleText -Where 'the chronicle cold tier' `
            -Phrase ('**A correction drained from the inbox keeps its own provenance shape**, ' +
                     'because it has no source memory file, no tier and no last-reinforced date to ' +
                     'record: source `corrections.md`, the date recorded in the entry itself, and ' +
                     'what superseded it')
        Assert-Phrase -Text $script:ChronicleText -Where 'the chronicle drain step' `
            -Phrase ('`data\memory-archive.md` for an entry a later correction already superseded, ' +
                     'under the drained-correction provenance shape the cold tier section above owns')
        $shape = @(Get-CodeFence $script:ChronicleMd |
            Where-Object { $_.Contains('(from corrections.md, recorded:') })
        $shape.Count | Should -Be 1 -Because 'the drained shape is shown where the archive shape lives'
        $shape[0].Contains('[archived: superseded by the 2026-08-27 correction]') |
            Should -BeTrue -Because 'the reason still names what superseded the entry'
    }

    It 'the drain curates rather than appending, and empties only once the routing is written' {
        Assert-Phrase -Text $script:ChronicleText -Where 'the chronicle drain step' `
            -Phrase '**Draining is inspect-then-update, never an append.**'
        Assert-Phrase -Text $script:ChronicleText -Where 'the chronicle drain step' `
            -Phrase ('**Empty the inbox only once the routing is actually written.** An entry ' +
                     'leaves the file after its destination holds it, or after its work item exists')
    }

    It 'an entry belonging to a project becomes a work item rather than a write' {
        Assert-Phrase -Text $script:ChronicleText -Where 'the chronicle drain step' `
            -Phrase ("**An entry whose destination is a project's memory file cannot be written by " +
                     'the Hand**, so it becomes a work item instead')
        Assert-Phrase -Text $script:ChronicleText -Where 'the chronicle drain step' `
            -Phrase 'Hard rule 1 is not suspended here'
    }

    # The routing section this step defers to has five owners and the enumeration listed four. The
    # missing one is the likeliest correction there is - the King correcting a standing behaviour of
    # kingshand's own - and with no route for it the entry gets forced into learnings.md, where a
    # curated line quietly competes with the tracked contract that actually governs.
    It 'a correction about kingshand''s own rules routes to statute, as a work item' {
        Assert-Phrase -Text $script:ChronicleText -Where 'the chronicle drain step' `
            -Phrase ('kingshand''s own tracked material under `statute` for a rule about how ' +
                     'kingshand itself behaves')
        Assert-Phrase -Text $script:ChronicleText -Where 'the chronicle drain step' `
            -Phrase ('**A correction about kingshand''s own rules is not filed into `learnings.md` ' +
                     'for want of a route**')
        Assert-Phrase -Text $script:ChronicleText -Where 'the chronicle drain step' `
            -Phrase ('**A rule about kingshand itself is the same case** - tracked material under ' +
                     '`statute` is a deliberate scoped change with its own test obligation, and ' +
                     'this pass never makes one - so it becomes a work item too')
        Assert-Phrase -Text $script:ChronicleText -Where 'the chronicle drain step' `
            -Phrase 'intending to file a work item is not the same as having filed it'
    }

    # Add-IndexEntry does no existence check on its target, so both ends of the inbox's life can
    # produce a line for a file that is not there: deleting the drained file, and indexing an inbox
    # kingshand was never corrected into having. Either way the digest prints STALE on every session
    # until somebody runs Remove-IndexEntry -Missing, which is what stops a drift count being read.
    It 'the inbox is indexed only when it is actually on disk' {
        Assert-Phrase -Text $script:ChronicleText -Where 'the chronicle drain step' `
            -Phrase ('The drained inbox itself stays on disk, emptied of entries rather than ' +
                     'deleted, so the index line this pass writes for it never becomes stale drift')
        Assert-Phrase -Text $script:ChronicleText -Where 'the chronicle drain step' `
            -Phrase ('**this pass is what lists it - but only when the drain found an inbox and it ' +
                     'is still on disk afterwards**')
        Assert-Phrase -Text $script:ChronicleText -Where 'the chronicle drain step' `
            -Phrase ('An inbox that never existed is indexed by nothing: `Add-IndexEntry` checks no ' +
                     'target, so a line for a file that is not there is the stale drift the digest ' +
                     'counts')
    }

    # The unconditional call in the index fence was the live hazard: a routine pass on a kingshand
    # that has never been corrected would index a file that does not exist. The guard has to be in
    # the runnable text, not only in the prose, so this parses the fence and checks the call sits
    # inside a Test-Path branch.
    It 'the index fence guards the inbox call behind an existence check' {
        $fences = @(Get-CodeFence $script:ChronicleMd |
            Where-Object { $_.Contains('Add-IndexEntry -Path "data\corrections.md"') })
        $fences.Count | Should -Be 1 -Because 'the inbox is indexed in one stated place'

        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput(
            $fences[0], [ref]$tokens, [ref]$errors)
        @($errors).Count | Should -Be 0 -Because 'a fence framed as runnable text has to parse'

        $guarded = @($ast.FindAll({
            $args[0] -is [System.Management.Automation.Language.IfStatementAst] -and
            $args[0].Clauses[0].Item1.Extent.Text -match 'Test-Path' -and
            $args[0].Clauses[0].Item1.Extent.Text -match 'corrections\.md'
        }, $true))
        $guarded.Count | Should -Be 1 -Because 'the inbox call needs its own existence check'

        $inside = @($guarded[0].Clauses[0].Item2.FindAll({
            $args[0] -is [System.Management.Automation.Language.CommandAst] -and
            $args[0].GetCommandName() -eq 'Add-IndexEntry'
        }, $true))
        $inside.Count | Should -Be 1 -Because 'the guarded branch is where the inbox is listed'
        $inside[0].Extent.Text | Should -Match 'corrections\.md' `
            -Because 'the guard has to cover the inbox call, not one of the memory files'

        $unguarded = @($ast.FindAll({
            $args[0] -is [System.Management.Automation.Language.CommandAst] -and
            $args[0].GetCommandName() -eq 'Add-IndexEntry' -and
            $args[0].Extent.Text -match 'corrections\.md'
        }, $true))
        $unguarded.Count | Should -Be 1 `
            -Because 'a second unconditional inbox call anywhere in the fence reopens the drift'
    }

    It 'the offload sweep has a destination the Hand can actually write' {
        Assert-Phrase -Text $script:ChronicleText -Where 'the chronicle offload destinations' `
            -Phrase ('into a topic file of its own, `$env:KINGSHAND_HOME\data\<topic>.md`, indexed ' +
                     'on write in the same pass that offloads to it so the index points at it')
        Assert-Phrase -Text $script:ChronicleText -Where 'the chronicle offload destinations' `
            -Phrase '**This is the destination that is live at the moment it is proposed**'
        Assert-Phrase -Text $script:ChronicleText -Where 'the chronicle offload destinations' `
            -Phrase ("it sits inside the Hand's own write boundary, so it needs no worker and no " +
                     '`statute` change')
        Assert-Phrase -Text $script:ChronicleText -Where 'the chronicle offload destinations' `
            -Phrase 'a sweep with only those two can never actually offload anything'
    }

    It 'the topic file is indexed through the module, as runnable text' {
        $fences = @(Get-CodeFence $script:ChronicleMd | Where-Object { $_.Contains('data\<topic>.md') })
        $fences.Count | Should -Be 1 -Because 'the offload destination is indexed in one stated place'
        $fences[0].Contains('Import-Module $env:KINGSHAND_HOME\bin\Index.psm1 -Force') |
            Should -BeTrue -Because 'the module is the one place that knows the index format'
        $fences[0].Contains('Add-IndexEntry -Path "data\<topic>.md"') |
            Should -BeTrue -Because 'an offloaded detail file no index lists cannot be found again'
    }

    # Write-DataFile is an unconditional Set-Content, so an unconstrained topic name silently
    # overwrites whatever already sits at that path - backlog.md among the candidates a pass would
    # plausibly name - and the flow's "does the destination hold the entry" check runs after the
    # write and passes on the clobbered file. The name is the only thing standing in front of that.
    It 'the topic name must be free, and never one of kingshand''s own files' {
        Assert-Phrase -Text $script:ChronicleText -Where 'the chronicle offload destinations' `
            -Phrase ('**Test the path first, and what the check finds decides the branch: ' +
                     '`Write-DataFile` never runs against a path that exists.**')
        Assert-Phrase -Text $script:ChronicleText -Where 'the chronicle offload destinations' `
            -Phrase '`Write-DataFile` overwrites whatever sits at that path without reading it first'
        Assert-Phrase -Text $script:ChronicleText -Where 'the chronicle offload destinations' `
            -Phrase ('**Kingshand''s own operational files are never a topic name** - `backlog.md`, ' +
                     '`king.md`, `learnings.md`, `corrections.md`, `memory-archive.md`, ' +
                     '`done-archive.md`, `projects.md` and `index.md`')
        Assert-Phrase -Text $script:ChronicleText -Where 'the chronicle offload destinations' `
            -Phrase ('and neither is any other name already in use for something else under `data\`')
    }

    # Two rules for a taken path in one paragraph, in the wrong order, sent a second pass on the same
    # topic off to a fresh name - one topic split across two files with two index entries, which is
    # the opposite of accumulating detail where the reader already looks for it. So the precedence is
    # stated rather than implied: reuse for this topic's own file, a new name only for anything else.
    It 'reuse beats renaming when the path holds this topic''s own earlier file' {
        Assert-Phrase -Text $script:ChronicleText -Where 'the chronicle offload destinations' `
            -Phrase ('**The path is free**, meaning nothing is there at all - write it with ' +
                     '`Write-DataFile`, which writes and indexes in one call. A file that exists but ' +
                     'reads empty is not a free path')
        Assert-Phrase -Text $script:ChronicleText -Where 'the chronicle offload destinations' `
            -Phrase ('**The path holds this same topic''s file from an earlier pass** - **reuse it ' +
                     'rather than renaming around it**: read it whole, rewrite it in place with the ' +
                     'new detail folded in, and index it with `Add-IndexEntry`')
        Assert-Phrase -Text $script:ChronicleText -Where 'the chronicle offload destinations' `
            -Phrase ('a fresh name for a topic that already has a file fragments one topic across ' +
                     'two files with two index entries')
        Assert-Phrase -Text $script:ChronicleText -Where 'the chronicle offload destinations' `
            -Phrase ('**The path holds anything that is not this topic** - **write nothing and ' +
                     'index nothing**: pick another topic name and check that path in turn')
        Assert-Phrase -Text $script:ChronicleText -Where 'the chronicle offload destinations' `
            -Phrase ('Indexing here rewrites another file''s index line to describe this topic, so ' +
                     'the table of contents starts lying about a file nobody edited')
    }

    # Add-IndexEntry does no content check, so an index line written ahead of the file's own rewrite
    # claims detail that is not there yet - and the index is what a later session reads to decide
    # whether the file is worth opening at all.
    It 'the reuse case writes the file before the index line describes it' {
        Assert-Phrase -Text $script:ChronicleText -Where 'the chronicle offload destinations' `
            -Phrase ('**The write comes first and the index line last**: an index entry claiming ' +
                     'what the file now holds, written before the file holds it, points a later ' +
                     'session at content that is not there')
        Assert-Phrase -Text $script:ChronicleText -Where 'the chronicle offload destinations' `
            -Phrase ('**Existence alone does not tell the second case from the third**, so read ' +
                     'what is already at the path and decide which of the two it is before writing ' +
                     'or indexing anything')
    }

    # The topic file is a live destination for a fact CLAUDE.md's map already routes to kingshand's
    # own memory, not a sixth owner in that map. Saying otherwise would put this skill in the
    # business of extending a mapping it also declares it does not duplicate.
    It 'the topic file is a move within one owner, not a new entry in the routing map' {
        Assert-Phrase -Text $script:ChronicleText -Where 'the chronicle offload destinations' `
            -Phrase ('is the source of truth for where a fact belongs, and nothing here re-derives ' +
                     'or duplicates that mapping. Two of its owners bind this pass in particular, ' +
                     'and the third item below adds no owner at all - it is the form one of them takes')
        Assert-Phrase -Text $script:ChronicleText -Where 'the chronicle offload destinations' `
            -Phrase ('**Detail that is current and durable but needed only in a nameable context ' +
                     'stays kingshand''s own knowledge, and offloading changes only where it lives**')
        Assert-Phrase -Text $script:ChronicleText -Where 'the chronicle offload destinations' `
            -Phrase ('this is a move within one owner rather than a sixth entry in the mapping - ' +
                     'which is why nothing has to be added to `CLAUDE.md` for it')
    }

    # The fence is framed as the runnable text an agent copies, and it kept drifting from the prose in
    # ways no substring check could see. First it was three consecutive statements with a Test-Path
    # whose result nothing consumed. Then it branched, but on existence alone - so "a file that is not
    # this topic" fell into the reuse branch and reached Add-IndexEntry, rewriting an unrelated file's
    # index line to describe this topic, silently. And that branch indexed without writing, so the
    # index claimed detail the file did not hold. So the fence is parsed and each of the three prose
    # cases asserted as reachability: what runs, what cannot run, and in which order.
    It 'the fence carries the three exclusive cases the prose states' {
        $fences = @(Get-CodeFence $script:ChronicleMd | Where-Object { $_.Contains('data\<topic>.md') })
        $fences.Count | Should -Be 1 -Because 'the offload destination is written in one stated place'

        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput(
            $fences[0], [ref]$tokens, [ref]$errors)
        @($errors).Count | Should -Be 0 -Because 'a fence framed as runnable text has to parse'

        $dispatch = @($ast.FindAll({
            $args[0] -is [System.Management.Automation.Language.IfStatementAst] -and
            $args[0].Clauses.Count -eq 2
        }, $true))
        $dispatch.Count | Should -Be 1 -Because 'three exclusive cases need one two-clause dispatch'

        $branch = $dispatch[0]
        $branch.ElseClause | Should -Not -BeNullOrEmpty -Because 'the third case is the else branch'

        $namesIn = {
            param($node)
            if (-not $node) { return @() }
            @($node.FindAll(
                { $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true) |
                ForEach-Object { $_.GetCommandName() })
        }
        $writesIn = {
            param($node)
            if (-not $node) { return @() }
            @($node.FindAll({
                $args[0] -is [System.Management.Automation.Language.CommandAst] -and
                $args[0].GetCommandName() -in @('Set-Content', 'Write-DataFile', 'Out-File')
            }, $true))
        }
        $indexesIn = {
            param($node)
            if (-not $node) { return @() }
            @($node.FindAll({
                $args[0] -is [System.Management.Automation.Language.CommandAst] -and
                $args[0].GetCommandName() -eq 'Add-IndexEntry'
            }, $true))
        }

        # The file is read before the dispatch, because nothing else can tell case 2 from case 3.
        $read = @($ast.FindAll({
            $args[0] -is [System.Management.Automation.Language.CommandAst] -and
            $args[0].GetCommandName() -eq 'Get-Content'
        }, $true))
        $read.Count | Should -BeGreaterThan 0 -Because 'the identity check needs the file read first'
        $read[0].Extent.StartOffset | Should -BeLessThan $branch.Extent.StartOffset `
            -Because 'a read after the branch cannot inform it'

        # Case 1, the free path: written and indexed in one call.
        $free = & $namesIn $branch.Clauses[0].Item2
        $free | Should -Contain 'Write-DataFile' `
            -Because 'the free path is the one case Write-DataFile may run in'

        # And "free" has to mean the path is absent, not that the file reads empty. Gating case 1 on
        # the content read let Get-Content -Raw on a zero-length file look identical to no file at
        # all, so Write-DataFile's unconditional Set-Content would overwrite a file that exists -
        # the precise call the sentence above the fence forbids.
        $assignments = @($ast.FindAll(
            { $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true))
        $existence = @($assignments | Where-Object {
            $_.Right.Extent.Text -match 'Test-Path' -and $_.Right.Extent.Text -notmatch 'Get-Content' })
        $content = @($assignments | Where-Object { $_.Right.Extent.Text -match 'Get-Content' })
        $existence.Count | Should -Be 1 -Because 'one variable records whether the path exists'
        $content.Count | Should -Be 1 -Because 'one variable holds the read that decides identity'

        $freeCondition = $branch.Clauses[0].Item1.Extent.Text
        $freeCondition | Should -Match ([regex]::Escape($existence[0].Left.Extent.Text)) `
            -Because 'the free case is decided by the path being absent'
        $freeCondition | Should -Not -Match ([regex]::Escape($content[0].Left.Extent.Text)) `
            -Because 'an existing but empty file must not read as a free path'

        # Case 2, this topic's own file: gated on what the file is, and it writes before it indexes.
        $branch.Clauses[1].Item1.Extent.Text | Should -Not -Match 'Test-Path' `
            -Because 'existence cannot tell this topic''s file from an unrelated one'
        $reuseWrites  = & $writesIn $branch.Clauses[1].Item2
        $reuseIndexes = & $indexesIn $branch.Clauses[1].Item2
        $reuseWrites.Count | Should -BeGreaterThan 0 `
            -Because 'the reuse branch has to write the folded detail, never index alone'
        $reuseIndexes.Count | Should -BeGreaterThan 0 -Because 'a reused topic file is re-indexed'
        $reuseWrites[0].Extent.StartOffset | Should -BeLessThan $reuseIndexes[0].Extent.StartOffset `
            -Because 'an index line ahead of the write describes content the file does not hold'

        # Case 3, somebody else's file: nothing is written and nothing is indexed.
        @(& $namesIn $branch.ElseClause).Count | Should -Be 0 `
            -Because 'a file that is not this topic is left alone, its index line included'

        @($ast.FindAll({
            $args[0] -is [System.Management.Automation.Language.CommandAst] -and
            $args[0].GetCommandName() -eq 'Write-DataFile'
        }, $true)).Count | Should -Be 1 `
            -Because 'a second unguarded Write-DataFile anywhere in the fence reopens the clobber'
    }

    # Two clauses survived from the rule this change replaced - "an already-existing owner" and "an
    # owner that already exists" - which between them forbade the one destination the change adds,
    # since case 1 of the fence creates the file. A pass reading them skips the offload rung entirely
    # and lands on eviction or a user decision, which is the outcome the change exists to remove.
    It 'liveness is what this pass can write, never that the file already exists' {
        Assert-Phrase -Text $script:ChronicleText -Where 'the chronicle offload flow' `
            -Phrase ('Relocate it only to a destination that is live in this pass, then confirm ' +
                     'that destination holds the quoted entry before removing the memory entry.')
        Assert-Phrase -Text $script:ChronicleText -Where 'the chronicle offload flow' `
            -Phrase ('**What makes a destination live is that this pass can write it and confirm it ' +
                     'holds the entry before the memory line goes, never that the file already ' +
                     'exists** - a free `data\<topic>.md` path this pass creates qualifies')
        Assert-Phrase -Text $script:ChronicleText -Where 'the chronicle reduction rungs' `
            -Phrase ('relocate every eligible non-pinned conditional entry to a destination that ' +
                     'is live in this pass, but only after it actually holds it')
        $script:ChronicleText | Should -Not -Match 'already-existing owner' `
            -Because 'that phrasing forbids the one destination this pass can write'
        $script:ChronicleText | Should -Not -Match 'owner that already exists' `
            -Because 'liveness is about who writes it, not about the file pre-existing'
    }

    # The sweep's refusals are what keep an offload honest, and the new destination has to pass them
    # rather than be excused from them. Softening this back into "creation is fine" would let a pass
    # count a file it never wrote as budget relief.
    It 'the sweep still refuses a destination whose write belongs to somebody else' {
        Assert-Phrase -Text $script:ChronicleText -Where 'the chronicle offload flow' `
            -Phrase ('A destination whose write belongs to somebody else - an undelivered project ' +
                     'change, a `statute` change, or any other future work - is not live and cannot ' +
                     'count as relief')
        Assert-Phrase -Text $script:ChronicleText -Where 'the chronicle offload flow' `
            -Phrase ('Writing a `data\<topic>.md` in this pass is not future work and is no ' +
                     'exception to that rule')
    }

    It 'the ordered outcome and the eligibility filter are unchanged' {
        Assert-Phrase -Text $script:ChronicleText -Where 'the chronicle offload sweep' `
            -Phrase '**Archive** - the time outcome, always evaluated first.'
        Assert-Phrase -Text $script:ChronicleText -Where 'the chronicle offload sweep' `
            -Phrase '**Offload** - the scope outcome, asked only of current durable entries'
        Assert-Phrase -Text $script:ChronicleText -Where 'the chronicle offload sweep' `
            -Phrase '**Fat enough to matter** - roughly 50 estimated tokens or more'
    }
}

Describe 'the ADO organization and project are configuration, and absence asks' {
    # These were two hardcoded names belonging to one employer. Any default at all is the wrong
    # shape here: a wrong organization does not fail loudly, it returns "work item not found" -
    # indistinguishable from a mistyped ticket - or, worse, a real work item from somewhere else.
    BeforeAll { $script:MusterIntake = Get-MusterStep 'Step 1 - Intake' }

    It 'reads them from a config file rather than carrying a built-in default' {
        Assert-Phrase -Text $script:MusterIntake -Where 'muster Step 1' `
            -Phrase '**The ADO organization and project are configuration, never built in.**'
        Assert-Phrase -Text $script:MusterIntake -Where 'muster Step 1' `
            -Phrase '`$env:KINGSHAND_HOME\config\ado.json`, which is absent by default'
    }

    It 'asks rather than guessing when the config is absent' {
        Assert-Phrase -Text $script:MusterIntake -Where 'muster Step 1' `
            -Phrase ('**With no config file, ask the King for the organization and project. Do not ' +
                     'guess, and do not carry over a value from an earlier session.**')
    }

    It 'ships placeholders in the example, and no built-in default to fall back on' {
        # Deliberately not written as a list of the names that used to be here. A distributed repo
        # that spells out the exact strings it must never contain has not removed them.
        $text = Get-DocText $script:MusterMd
        Assert-Phrase -Text $text -Where 'the muster ADO config example' -Phrase '"organization": "your-ado-organization"'
        Assert-Phrase -Text $text -Where 'the muster ADO config example' -Phrase '"project": "Your ADO Project"'
        $text.Contains('Do not ask.') |
            Should -BeFalse -Because 'the form this replaced asserted a built-in default and forbade asking about it'
    }

    It 'records that the hold kind is the external tool''s spelling, not ours' {
        # The one place `captain` survives the rename. It is a validated enum in tasks-axi, so a
        # tidy-up that renamed it to `king` would make every hold fail VALIDATION_ERROR - and a
        # hold that fails is a decision recorded nowhere at all.
        Assert-Phrase -Text (Get-DocText $script:HoldMd) -Where 'decree' `
            -Phrase '**`captain` here is `tasks-axi`''s spelling, not ours, and it is not free text.**'
        Assert-Phrase -Text (Get-DocText $script:HoldMd) -Where 'decree' `
            -Phrase 'Do not "correct" it to `king`'
    }

    It 'keeps the config directory out of version control' {
        $ignore = Get-Content -Path (Join-Path $script:Root '.gitignore') -Raw
        $ignore.Contains('/config/') |
            Should -BeTrue -Because 'the answer to that question is one machine''s, and stays on it'
    }
}

Describe 'Azure DevOps is optional and muster degrades to adhoc without it' {
    # The `ado-local-mcp` tools were reached for unconditionally, and nothing anywhere said they
    # were optional or installed them. That server needs an Azure DevOps organization and a token,
    # which most users do not have, so the very first "work ticket 1234" hit an undeclared
    # dependency with no stated fallback - the shape that either fails or hangs.
    BeforeAll { $script:MusterIntake = Get-MusterStep 'Step 1 - Intake' }

    It 'says plainly that the MCP server is not a prerequisite and nothing installs it' {
        Assert-Phrase -Text $script:MusterIntake -Where 'muster Step 1' `
            -Phrase ('Azure DevOps is an optional integration: the `ado-local-mcp` server is not a ' +
                     'kingshand prerequisite, `install.ps1` does not install it')
    }

    It 'falls back to adhoc rather than failing or retrying when the tools are absent' {
        Assert-Phrase -Text $script:MusterIntake -Where 'muster Step 1' `
            -Phrase ('**If those tools do not come back, say so plainly and carry on as adhoc. Never ' +
                     'fail here, and never retry in a loop.**')
        Assert-Phrase -Text $script:MusterIntake -Where 'muster Step 1' `
            -Phrase ('ask them to paste the ticket text or describe the work in their own words, ' +
                     'and treat what they give you as adhoc')
        Assert-Phrase -Text $script:MusterIntake -Where 'muster Step 1' `
            -Phrase 'Do not stop the dispatch, do not tell them to install anything'
    }

    It 'the setup skill tells the user Azure DevOps needs nothing unless they use it' {
        Assert-Phrase -Text (Get-DocText $script:SetupMd) -Where 'the setup skill' `
            -Phrase ('**Azure DevOps integration is optional and needs nothing unless they work ADO ' +
                     'tickets**')
    }

    It 'the README says the same, and names adhoc as the ordinary path' {
        $readme = Get-DocText (Join-Path $script:Root 'README.md')
        Assert-Phrase -Text $readme -Where 'the README requirements' `
            -Phrase '**Azure DevOps, only if you work ADO tickets.**'
        Assert-Phrase -Text $readme -Where 'the README requirements' `
            -Phrase 'handles it as adhoc - which is the ordinary path and works exactly as well'
    }
}

Describe 'annex refuses a push-capable posture on a machine with no gh' {
    # `gh` was demoted from a prerequisite failure to a note, because a user whose work always
    # stops at a finished local branch never calls it - the same reasoning that already makes the
    # review gate optional. That demotion opens a gap: a `direct-PR` project registered on a
    # machine with no gh looks importable and dies at its first dispatch. This is where it closes,
    # and it is the assertion that stops the refusal being quietly softened back into a warning.
    BeforeAll { $script:ImportPreflight = Get-DocText $script:ImportMd }

    It 'names the check and treats an empty result as a refusal' {
        Assert-Phrase -Text $script:ImportPreflight -Where 'annex Step 3' `
            -Phrase ('The fourth is `gh`. A push-capable mode - `direct-PR`, `no-mistakes`, ' +
                     '`no-mistakes-prod-only` - ends at a pull request, and nothing here opens one ' +
                     'without the GitHub CLI')
        Assert-Phrase -Text $script:ImportPreflight -Where 'annex Step 3' `
            -Phrase ('**Nothing back is a refusal, on exactly the terms above: report the condition ' +
                     'and stop.**')
    }

    It 'names the exact install command and offers local-only instead' {
        Assert-Phrase -Text $script:ImportPreflight -Where 'annex Step 3' `
            -Phrase 'winget install --id GitHub.cli`, then `gh auth login`'
        Assert-Phrase -Text $script:ImportPreflight -Where 'annex Step 3' `
            -Phrase 'offer `local-only` instead, which needs no forge at all'
    }

    It 'the refusal is still counted among the preflight refusals rather than left loose' {
        Assert-Phrase -Text $script:ImportPreflight -Where 'annex Step 3' `
            -Phrase '`Test-ProjectImportable` owns three of the six refusals'
        Assert-Phrase -Text $script:ImportPreflight -Where 'annex Step 3' `
            -Phrase 'The fifth is uniqueness.'
    }

    # The count is what a Hand plans Step 4 around. Add-ProjectEntry throws on a non-slug name as
    # well as on a duplicate, and uniqueness is counted here precisely because it is enforced by
    # that same call - so leaving the name shape out understated what Step 4 refuses.
    It 'counts the name-shape refusal Add-ProjectEntry makes alongside uniqueness' {
        Assert-Phrase -Text $script:ImportPreflight -Where 'annex Step 3' `
            -Phrase ('The sixth is the name''s shape, from Step 1: a name the index cannot turn ' +
                     'into a file name is refused by that same `Add-ProjectEntry` call')
    }
}

Describe 'the King''s stated instructions are read and never rewritten' {
    # Two files that both hold preferences, one curated and one not, is a distinction that erodes
    # the moment nobody restates it. If `instructions.md` is ever treated as a memory file, a chronicle
    # pass will decay and archive a preference the King stated out loud - silently, and with the
    # receipt reading like an ordinary prune. Both owners have to say it, which is why it is
    # asserted at both.

    It 'CLAUDE.md declares the file off-limits to the Hand''s own writes' {
        $s = Get-HandSection 'What you own'
        Assert-Phrase -Text $s -Where 'CLAUDE.md What you own' `
            -Phrase '**`instructions.md` at the repo root is not yours.**'
        Assert-Phrase -Text $s -Where 'CLAUDE.md What you own' `
            -Phrase '**Read it and never edit it**'
    }

    It 'CLAUDE.md names what conflating it with the memory file would cost' {
        Assert-Phrase -Text (Get-HandSection 'What you own') -Where 'CLAUDE.md What you own' `
            -Phrase ('`king.md` is what you inferred and `chronicle` prunes it against a budget, while ' +
                     '`instructions.md` is what the King stated and nothing may rewrite it. ' +
                     'Conflating the two would let a curation pass silently delete a preference ' +
                     'the King actually stated.')
    }

    It 'CLAUDE.md routes nothing into it' {
        Assert-Phrase -Text (Get-HandSection 'Knowledge routing') -Where 'CLAUDE.md Knowledge routing' `
            -Phrase 'Nothing at all is routed into `instructions.md`.'
    }

    It 'chronicle disclaims it as a destination and as a curation target' {
        $text = Get-DocText $script:ChronicleMd
        Assert-Phrase -Text $text -Where 'chronicle' `
            -Phrase ('**`$env:KINGSHAND_HOME\instructions.md` is not a memory file and this pass ' +
                     'never touches it.**')
        Assert-Phrase -Text $text -Where 'chronicle' `
            -Phrase ('no curation decision may edit, reformat, summarise, fold, prune or archive a ' +
                     'line of it')
    }

    It 'the digest reads it, and says so as a parameter it owns' {
        $digest = Get-Content -Path (Join-Path $script:Root 'bin\Get-SessionStart.ps1') -Raw
        $digest.Contains('.PARAMETER InstructionsPath') |
            Should -BeTrue -Because 'the path is a parameter, so a test can point it at a fixture'
        $digest.Contains("-AbsentMeans 'the King has stated no standing instructions. Read it, never write it.'") |
            Should -BeTrue -Because 'absence is a stated fact here, exactly as it is for a memory file'
    }

    It 'the budget module excludes it, and records why' {
        $memory = Get-Content -Path (Join-Path $script:Root 'bin\Memory.psm1') -Raw
        $memory.Contains("@('king.md', 'learnings.md')") |
            Should -BeTrue -Because 'the accounted set is exactly the two curated files'
        $memory.Contains('instructions.md') |
            Should -BeTrue -Because 'the exclusion is deliberate and the reason belongs beside it'
    }

    It 'the example template ships tracked while the real file is ignored' {
        Test-Path (Join-Path $script:Root 'instructions.example.md') |
            Should -BeTrue -Because 'the installer copies a tracked template into place'
        $ignore = Get-Content -Path (Join-Path $script:Root '.gitignore') -Raw
        $ignore.Contains('/instructions.md') |
            Should -BeTrue -Because 'a user publishing their own standing preferences is the failure this prevents'
    }

    # The two live defaults in the template reach every user who never edits it, so they are the
    # ones worth pinning. Everything else in that file is commented out and deliberately inert.
    # The default is deliberately neutral. It used to be "my King", which assumed something about
    # every person who installed this - and the tool has no way to know, so the only honest default
    # is one that does not guess. `setup` asks, and install.ps1 substitutes the answer, because the
    # permission layer denies the Hand any edit to instructions.md.
    It 'the template default form of address assumes nothing, and says how to change it' {
        $template = ConvertTo-NormalisedText (Get-Content -Path (Join-Path $script:Root 'instructions.example.md') -Raw)
        $template.Contains('**Address me as "your Highness".**') | Should -BeTrue
        $template.Contains('assumes nothing about you') |
            Should -BeTrue -Because 'the reason for the neutral default belongs beside it'
        $template.Contains('my Queen') |
            Should -BeTrue -Because 'the alternatives are offered rather than left to be discovered'
        $template.Contains('Once in a reply is enough') |
            Should -BeTrue -Because 'a form of address repeated every sentence stops being one'
        $template.Contains('Drop it entirely when the news is bad') |
            Should -BeTrue -Because 'a flourish on a failure report costs more than it gives'
    }

    It 'the template keeps a project''s own rules above kingshand''s' {
        $template = ConvertTo-NormalisedText (Get-Content -Path (Join-Path $script:Root 'instructions.example.md') -Raw)
        $template.Contains("**A repository's own rules beat these.**") | Should -BeTrue
    }
}

Describe 'CLAUDE.md routes durable knowledge to its most specific owner' {
    # The two memory files are new always-loaded state. Without a routing rule the Hand writes
    # a preference into a backlog note, a project fact into learnings.md, and a worker finding into
    # both - and every session after that pays for the duplicate.
    BeforeAll { $script:Routing = Get-HandSection 'Knowledge routing' }

    It 'CLAUDE.md carries exactly one Knowledge routing section, and no new hard rule' {
        { Get-HandSection 'Knowledge routing' } |
            Should -Not -Throw -Because 'routing is its own section, never a renumbered hard rule'
        Assert-Phrase -Text (Get-DocText $script:HandMd) -Where 'CLAUDE.md rule 6' `
            -Phrase '6. **Escalate real decisions only.**'
    }

    It 'sends user preferences to king.md after inspect-then-update' {
        Assert-Phrase -Text $script:Routing -Where 'CLAUDE.md knowledge routing' `
            -Phrase ('How the user works and what they prefer belongs in `data\king.md`, after ' +
                     'inspect-then-update')
        Assert-Phrase -Text $script:Routing -Where 'CLAUDE.md knowledge routing' `
            -Phrase 'rewrite that statement rather than adding a second one beside it'
    }

    It 'sends operational facts to learnings.md, dated and evidence-backed' {
        Assert-Phrase -Text $script:Routing -Where 'CLAUDE.md knowledge routing' `
            -Phrase ('Operational facts and gotchas kingshand itself has hit belong in curated ' +
                     '`data\learnings.md`, each one dated and backed by evidence from the session ' +
                     'that produced it.')
        Assert-Phrase -Text $script:Routing -Where 'CLAUDE.md knowledge routing' `
            -Phrase 'Rewrite and prune rather than appending forever.'
    }

    It 'keeps task notes on the backlog item and findings in the report' {
        Assert-Phrase -Text $script:Routing -Where 'CLAUDE.md knowledge routing' `
            -Phrase ('Task-scoped notes belong with the backlog item, and investigation findings ' +
                     'belong in that worker''s `data\<id>\report.md`.')
    }

    It 'keeps the Hand out of a project''s own memory file' {
        Assert-Phrase -Text $script:Routing -Where 'CLAUDE.md knowledge routing' `
            -Phrase ("Knowledge useful to every contributor to one project belongs in that " +
                     "project's own memory file, written by a worker through its delivery path, " +
                     'never by you.')
        Assert-Phrase -Text $script:Routing -Where 'CLAUDE.md knowledge routing' `
            -Phrase 'Hard rule 1 is not relaxed for a memory file.'
    }

    It 'sends knowledge about kingshand itself to its tracked material' {
        Assert-Phrase -Text $script:Routing -Where 'CLAUDE.md knowledge routing' `
            -Phrase ('Knowledge general to kingshand itself belongs in its tracked material - ' +
                     '`statute` owns which file, and the test that has to come with it.')
    }

    It 'states that an absent memory file is meaningful, not an error' {
        Assert-Phrase -Text $script:Routing -Where 'CLAUDE.md knowledge routing' `
            -Phrase ('Both memory files are created lazily and stay absent until there is ' +
                     'something to store.')
        Assert-Phrase -Text $script:Routing -Where 'CLAUDE.md knowledge routing' `
            -Phrase 'Absence is meaningful, not an error**, and never a reason to write a placeholder.'
    }

    It 'points at the owners of the pass and of the measurement' {
        Assert-Phrase -Text $script:Routing -Where 'CLAUDE.md knowledge routing' `
            -Phrase ('`chronicle` owns the curation pass, the tiers and the budget; `bin\Memory.psm1` ' +
                     'measures what the two files cost.')
    }

    It 'lists both memory files among what the Hand owns' {
        $text = Get-DocText $script:HandMd
        Assert-Phrase -Text $text -Where 'CLAUDE.md What you own' `
            -Phrase ('`data\king.md` - what you have observed about how the King works and what ' +
                     'they prefer.')
        Assert-Phrase -Text $text -Where 'CLAUDE.md What you own' `
            -Phrase ('`data\learnings.md` - kingshand''s own operational facts and gotchas, dated ' +
                     'and evidence-backed.')
    }
}

Describe 'the session-start digest is read once and not read again' {
    # The digest costs a fixed budget at session open, and every one of its sources re-read
    # afterwards is that budget spent twice. The read-once sentence is the entire reason the digest
    # is worth printing, so it is pinned verbatim rather than checked for a keyword; without it the
    # section degrades into an expensive preamble to the same reads it just did.
    BeforeAll { $script:SessionStart = Get-HandSection 'Session start' }

    It 'CLAUDE.md carries exactly one Session start section, and no new hard rule' {
        { Get-HandSection 'Session start' } |
            Should -Not -Throw -Because 'session start is its own section, never a renumbered hard rule'
        Assert-Phrase -Text (Get-DocText $script:HandMd) -Where 'CLAUDE.md rule 1' `
            -Phrase '1. **You never do a project''s work yourself - a worker does.**'
        Assert-Phrase -Text (Get-DocText $script:HandMd) -Where 'CLAUDE.md rule 6' `
            -Phrase '6. **Escalate real decisions only.**'
    }

    It 'names the hook and the script behind it' {
        Assert-Phrase -Text $script:SessionStart -Where 'CLAUDE.md session start' `
            -Phrase ('A `SessionStart` hook runs `bin\Get-SessionStart.ps1` and injects its digest ' +
                     'as this session''s first input.')
    }

    # A first launch shows a completely blank screen. The digest is injected as context, never
    # printed, and Claude Code emits nothing until the user types - so the one thing a new user sees
    # after installing is silence, which reads as a broken install. It was reported as exactly that.
    # The digest itself was verified reaching the model at the same time, so the fix is the Hand
    # opening with orientation rather than anything in the hook.
    It 'requires the Hand to open a session with orientation, because the digest is invisible' {
        Assert-Phrase -Text $script:SessionStart -Where 'CLAUDE.md session start' `
            -Phrase ('**The digest is invisible to the King.**')
        Assert-Phrase -Text $script:SessionStart -Where 'CLAUDE.md session start' `
            -Phrase ('**Open your first reply of a session with one or two lines of orientation ' +
                     'drawn from the digest**')
    }

    It 'states the read-once rule and forbids re-reading what the digest printed' {
        Assert-Phrase -Text $script:SessionStart -Where 'CLAUDE.md session start' `
            -Phrase ('**Read the digest once and trust it as this turn''s startup input. Do not ' +
                     'separately re-read the registry, the queue, the fleet or the context files ' +
                     'it just printed.**')
    }

    It 'keeps the two exceptions narrow and names both' {
        Assert-Phrase -Text $script:SessionStart -Where 'CLAUDE.md session start' `
            -Phrase ('The exceptions are narrow: a source the digest reported absent or corrupt, ' +
                     'and a targeted piece of work that must inspect a file before writing to it.')
    }

    It 'leaves liveness to the live process inventory rather than the digest' {
        Assert-Phrase -Text $script:SessionStart -Where 'CLAUDE.md session start' `
            -Phrase 'The digest is orientation and durable record, not a live feed.'
        # The source of liveness moved from `claude agents --json` to herdr; the principle that
        # it is never the Hand's to assume did not.
        Assert-Phrase -Text $script:SessionStart -Where 'CLAUDE.md session start' `
            -Phrase '**Liveness still comes from herdr**'
        Assert-Phrase -Text $script:SessionStart -Where 'CLAUDE.md session start' `
            -Phrase ('a worker''s current state is read when it matters rather than assumed from ' +
                     'a line printed at session open')
    }

    It 'reads absence as a state rather than an error' {
        Assert-Phrase -Text $script:SessionStart -Where 'CLAUDE.md session start' `
            -Phrase 'Absence in the digest is a state, never an error.'
        Assert-Phrase -Text $script:SessionStart -Where 'CLAUDE.md session start' `
            -Phrase ('`ABSENT` against `king.md` or `learnings.md` means nothing has been ' +
                     'recorded there yet, which is not the same as a file that exists and holds ' +
                     'nothing, and neither is a reason to write a placeholder.')
        Assert-Phrase -Text $script:SessionStart -Where 'CLAUDE.md session start' `
            -Phrase ('An empty registry means nothing can be dispatched until `/annex` ' +
                     'runs.')
    }

    It 'routes a budget overrun to chronicle without treating it as a gate' {
        Assert-Phrase -Text $script:SessionStart -Where 'CLAUDE.md session start' `
            -Phrase ('A `STARTUP_MEMORY_BUDGET:` line means the two memory files have outgrown ' +
                     'their budget - invoke `chronicle` to curate them back down, and read them anyway, ' +
                     'because the budget is a signal and not a gate.')
    }

    It 'keeps the digest and survey separate, with neither calling the other' {
        Assert-Phrase -Text $script:SessionStart -Where 'CLAUDE.md session start' `
            -Phrase ('The digest is not `survey` and neither runs the other. This is mechanical ' +
                     'startup input nobody asked for; `survey` is a curated answer to "what ' +
                     'needs me" that only the user ever asks for.')
    }

    It 'keeps survey'' own rule that nothing runs it on the Hand''s behalf' {
        Assert-Phrase -Text (Get-DocText $script:HandMd) -Where 'the CLAUDE.md Skills section' `
            -Phrase 'Nothing runs it on your behalf.'
    }

    It 'lists the digest script in the Tooling table' {
        Assert-Phrase -Text (Get-DocText $script:HandMd) -Where 'the CLAUDE.md Tooling table' `
            -Phrase ('| `bin\Get-SessionStart.ps1` | the once-per-session digest behind the ' +
                     '`SessionStart` hook')
    }
}

Describe 'every durable file is indexed, and the brief names the ones its task touches' {
    # A settled brand spec sat in data\ naming itself the input to the website brief, and the site
    # shipped without its logo, favicon, tagline or palette. Nothing was lost and nothing was
    # overruled - the file was never read, because no brief named it.
    #
    # The first fix drafted was a "settled decision" category with its own home. It was rejected:
    # classifying a file as important at write time is a guess about work nobody has scoped yet, and
    # a wrong guess is silent, which is the same failure in a different hat. What shipped is an
    # index - everything is listed, nothing is judged, and the gap is counted. These pin the four
    # sentences that carry that, because a future editor tidying the routing section back into a
    # category is exactly how this returns.
    BeforeAll {
        $script:IndexRouting = Get-HandSection 'Knowledge routing'
        $script:IndexOwned   = Get-HandSection 'What you own'
        $script:IndexStart   = Get-HandSection 'Session start'
        $script:MusterText   = Get-DocText $script:MusterMd
    }

    It 'CLAUDE.md owns the index beside the other durable state' {
        Assert-Phrase -Text $script:IndexOwned -Where 'CLAUDE.md What you own' `
            -Phrase ('`data\index\<project>.md`, and `data\index.md` for kingshand''s own ' +
                     'operational files - one line per durable file so a later session can find it.')
        Assert-Phrase -Text $script:IndexOwned -Where 'CLAUDE.md What you own' `
            -Phrase ('Written through `bin\Index.psm1` as the file itself is written, never as a ' +
                     'separate act of remembering.')
    }

    # The index-on-write rule is stated as absolute, and the correction obligation breaks it on
    # purpose. With the reason living only in the chronicle skill - which an ordinary turn never loads
    # - the Hand follows the rule it can see, pays the mid-turn cost the design exists to avoid, and
    # the deferral never happens. So the exception is declared next to the rule it excepts.
    It 'the one index-on-write exception is declared where the rule is' {
        Assert-Phrase -Text $script:IndexRouting -Where 'CLAUDE.md knowledge routing' `
            -Phrase ('**`data\corrections.md` is the one exception, and it is deliberate:** it is ' +
                     'appended mid-turn and not indexed in that turn, because a write that also has ' +
                     'to index is the write that does not happen, and the `chronicle` drain lists it.')
    }

    # The session-start line told the reader to index every unindexed file as they touched it, which
    # is the exact mid-turn cost the exception above exists to defer. Both lines are always loaded, so
    # the unqualified one wins by being read first. The qualifier points at the owner rather than
    # restating it - a second copy of the reason is how the two drift apart again.
    It 'the session-start unindexed line defers to that exception rather than overriding it' {
        Assert-Phrase -Text $script:IndexStart -Where 'CLAUDE.md session start' `
            -Phrase ('index each as you touch it rather than in a sweep, except ' +
                     '`data\corrections.md`, which Knowledge routing exempts.')
    }

    It 'routing indexes everything at write time rather than judging what is worth listing' {
        Assert-Phrase -Text $script:IndexRouting -Where 'CLAUDE.md knowledge routing' `
            -Phrase '**Every durable file written under `data\` is indexed as it is written**'
        Assert-Phrase -Text $script:IndexRouting -Where 'CLAUDE.md knowledge routing' `
            -Phrase ('Nothing is judged important enough to list at write time: that is a guess ' +
                     'about work nobody has scoped yet, and a wrong guess is silent')
    }

    It 'routing moves the judgement to read time and counts what nothing lists' {
        Assert-Phrase -Text $script:IndexRouting -Where 'CLAUDE.md knowledge routing' `
            -Phrase ('The index is a table of contents, so the reader decides at read time which ' +
                     'files their own task touches, and a file no index lists is drift the ' +
                     'session-start digest counts.')
    }

    # An older backlog line said the accent was amber while the spec file said teal and recorded
    # amber as rejected. A worker handed both and told nothing picks wrong half the time.
    It 'routing says which source wins when two disagree' {
        Assert-Phrase -Text $script:IndexRouting -Where 'CLAUDE.md knowledge routing' `
            -Phrase ('**Where two sources disagree the brief says which one wins**, and a settled ' +
                     'file beats an older backlog line, ticket text or report')
    }

    It 'the digest carries the index as counts, and absence still means absence' {
        Assert-Phrase -Text $script:IndexStart -Where 'CLAUDE.md session start' `
            -Phrase ('the data index as counts alone - how much it covers and how many files under ' +
                     '`data\` it has lost track of')
        Assert-Phrase -Text $script:IndexStart -Where 'CLAUDE.md session start' `
            -Phrase ('No `INDEX` section means there is nothing indexed and nothing to index yet, ' +
                     'while an `UNINDEXED:` count means durable files exist that no index lists')
    }

    It 'the module is listed in the Tooling table' {
        Assert-Phrase -Text (Get-DocText $script:HandMd) -Where 'the CLAUDE.md Tooling table' `
            -Phrase ('| `bin\Index.psm1` | the data index: write a file and index it in one call')
    }

    It 'muster reads the index before a brief is written' {
        Assert-Phrase -Text $script:MusterText -Where 'muster Step 2' `
            -Phrase '**Read the index for this project before you write anything.**'
    }

    It 'muster names the files in the brief by absolute path, to be read in full' {
        Assert-Phrase -Text $script:MusterText -Where 'muster Step 2' `
            -Phrase ('**name in the brief, by absolute path and with an instruction to read it in ' +
                     'full, every file this task plausibly touches**, and say which source wins ' +
                     'where two disagree')
    }

    It 'muster says why naming it is the only delivery there is' {
        Assert-Phrase -Text $script:MusterText -Where 'muster Step 2' `
            -Phrase ('a worker sees exactly one thing, its brief, so "it is recorded" is not a ' +
                     'delivery mechanism')
        Assert-Phrase -Text $script:MusterText -Where 'muster Step 2' `
            -Phrase ('A fully settled brand spec sat in `data\` naming itself the input to the ' +
                     'website brief while the site shipped without its logo, its favicon, its ' +
                     'tagline or its palette, because no brief ever named the file.')
    }

    It 'muster indexes the brief in the step that writes it, and the report in the step that reads it' {
        Assert-Phrase -Text $script:MusterText -Where 'muster Step 2' `
            -Phrase 'Index the brief in the same step that writes it, so the two cannot come apart'
        Assert-Phrase -Text $script:MusterText -Where 'muster Step 6' `
            -Phrase '**index the report in the same breath**'
        Assert-Phrase -Text $script:MusterText -Where 'muster Step 6' `
            -Phrase 'a report no index lists is a finding the next brief will not find'
    }

    It 'both index calls are stated as runnable text, through the module' {
        $fences = @(Get-CodeFence $script:MusterMd | Where-Object { $_.Contains('Add-IndexEntry') })
        $fences.Count | Should -Be 2 -Because 'the brief and the report are each indexed where they are handled'
        @($fences | Where-Object { $_.Contains('brief.md') }).Count  | Should -Be 1
        @($fences | Where-Object { $_.Contains('report.md') }).Count | Should -Be 1
        foreach ($fence in $fences) {
            $fence.Contains('Import-Module $env:KINGSHAND_HOME\bin\Index.psm1 -Force') |
                Should -BeTrue -Because 'the module is the one place that knows the index format'
        }
    }

    # The requirement to name the files lived only in the instructions for filling the template in,
    # and the template itself asked for repo paths to change and nothing to read. A worker sees one
    # thing, its brief, so the slot has to be in the artefact - the same fix the landing gate needed
    # when "render the diff and poll lavish" was prose and lavish ran zero times in a full session.
    It 'the brief template carries the slot those paths go in' {
        $template = @(Get-CodeFence $script:MusterMd |
            Where-Object { $_.Contains('## Goal') -and $_.Contains('## Done means') })
        $template.Count | Should -Be 1 -Because 'the brief template is one fence and the worker gets what it says'
        $template[0].Contains('## Read first') |
            Should -BeTrue -Because 'a requirement with no field in the template reaches no brief'
        $template[0].IndexOf('## Read first') |
            Should -BeLessThan $template[0].IndexOf('## Scope') -Because 'what to read comes before what to change'
        $template[0] | Should -Match 'Read it in full before you start'
        $template[0] | Should -Match 'disagree'
    }

    # Naming the path in the brief is half of it. A worker's only grants are its worktree and the
    # brief's own directory, so a settled file one level up is named but unreachable unless
    # dispatch carries it in - the original failure with one extra hop.
    It 'muster hands the originals to the dispatcher and names the copies in the brief' {
        Assert-Phrase -Text $script:MusterText -Where 'muster Step 2' `
            -Phrase '**Name the copy, not the original.**'
        Assert-Phrase -Text $script:MusterText -Where 'muster Step 2' `
            -Phrase ('dispatch copies it to ' +
                     '`$env:KINGSHAND_HOME\data\<id>\read-first\<filename>`, keeping the file ' +
                     'name exactly')
        $step = Get-MusterStep 'Step 4 - Dispatch'
        Assert-Phrase -Text $step -Where 'muster Step 4' `
            -Phrase '**`-ReadPath` takes the ORIGINALS of exactly the files that brief''s `Read first` section names, and nothing else.**'
    }

    # The paths reach dispatch as a list, never by being read back out of the brief. An earlier
    # version parsed that prose and it took six review rounds without reaching a last bug, two of
    # them refusing correct briefs over paths nobody had written. The prohibition has to be written
    # where the next round of the same idea would be, or it comes back: the finding that prompts it
    # is always true, and only this says the answer is not another parser.
    It 'muster forbids reading the Read first paths back out of the brief' {
        $step = Get-MusterStep 'Step 4 - Dispatch'
        Assert-Phrase -Text $step -Where 'muster Step 4' `
            -Phrase ('**Dispatch does not read the paths out of the brief''s prose, and nothing ' +
                     'may make it start.**')
        Assert-Phrase -Text $step -Where 'muster Step 4' `
            -Phrase 'You write the brief and you make this call, so you already hold the list'
    }

    # Nothing enforces the pairing any more, so the skill has to say who does. Left unsaid, the
    # Hand goes on believing dispatch will catch a section that names the original.
    It 'muster says the Hand is what keeps the section and -ReadPath together' {
        Assert-Phrase -Text $script:MusterText -Where 'muster Step 2' `
            -Phrase '**Nothing checks that those two agree, so you are the one who has to.**'
        Assert-Phrase -Text $script:MusterText -Where 'muster Step 2' `
            -Phrase 'Write the section and the parameter together, in one go'
    }

    # The refusals are what a caller plans around, so their count and their subjects are pinned.
    # Each one knows its path exactly because the caller handed it over - that is what separates
    # this list from the parsed cross-check it replaced.
    It 'muster states the five refusals dispatch still makes' {
        $step = Get-MusterStep 'Step 4 - Dispatch'
        Assert-Phrase -Text $step -Where 'muster Step 4' `
            -Phrase ('There are five, and each is refused by name: a brief with no ' +
                     '`## Read first` section at all, a brief that passes no `-ReadPath` and does ' +
                     'not say the index was checked when anything at all is indexed, a path that ' +
                     'does not exist, a directory where a file was meant, and two different files ' +
                     'whose names would land on top of each other in the staging directory.')
    }

    # A single quoted placeholder is filled in with two paths in one string, which names no file
    # and costs a round trip. The list shape has to be visible in the runnable text.
    It 'the dispatch fence shows -ReadPath as a comma-separated list' {
        $fences = @(Get-CodeFence $script:MusterMd | Where-Object { $_.Contains('-ReadPath') })
        $fences.Count | Should -Be 1 -Because 'Step 4 is the one place that calls the dispatcher'
        $fences[0] | Should -Match '-ReadPath "[^"]+", "[^"]+"'
    }

    # Granting the containing directory is the shorter route and the wrong one: the canonical
    # settled file sits directly under data\, so that grant is the whole data root, writable.
    It 'muster says not to ask for the original''s own directory, and why' {
        Assert-Phrase -Text $script:MusterText -Where 'muster Step 2' `
            -Phrase ('the canonical settled file sits directly under `data\`, so that grant hands ' +
                     'the worker every other worker''s brief and report, `king.md`, `learnings.md`, ' +
                     '`backlog.md` and `projects.md`, and hands them writable')
    }

    It 'muster requires the slot even when nothing is named in it' {
        Assert-Phrase -Text $script:MusterText -Where 'muster Step 2' `
            -Phrase '**`Read first` is a mandatory section of every brief**'
        Assert-Phrase -Text $script:MusterText -Where 'muster Step 2' `
            -Phrase ('Where the index turns up nothing this task touches, say `- Nothing beyond ' +
                     'this brief - the index was checked and nothing in it applies.` rather than ' +
                     'dropping the section')
    }

    # The index was built, written to as files are written, and nothing obliged anyone to open it.
    # Dispatch-Worker.ps1 is what closes that, and this is where the Hand finds out before it writes
    # a brief - a refusal discovered at the dispatch is a brief rewritten, not a rule learned.
    It 'muster says an indexed project needs a ReadPath or the stated line' {
        Assert-Phrase -Text $script:MusterText -Where 'muster Step 2' `
            -Phrase ('**Where anything at all is indexed, that line is not optional, and it has to ' +
                     'state both halves: that the index was checked, and that nothing in it ' +
                     'applies.**')
        Assert-Phrase -Text $script:MusterText -Where 'muster Step 2' `
            -Phrase ('reads both indexes that could cover the work - the root `data\index.md` and ' +
                     'the project''s own `data\index\<project>.md` - and refuses unless either a ' +
                     'file is passed to `-ReadPath` at Step 4 or the section states in one line ' +
                     'that the index was checked and nothing in it applies')
        Assert-Phrase -Text $script:MusterText -Where 'muster Step 2' `
            -Phrase ('An empty section does not pass and neither does `- Nothing beyond this ' +
                     'brief.` on its own')
    }

    # The brief was indexed above the line that wrote it, so an abandoned brief left an entry for a
    # file that never existed - drift the digest reports as STALE.
    It 'muster indexes the brief only once it is on disk' {
        # The whole document, not Get-MusterStep: the brief template's own `## ` headings split
        # Step 2 apart, so the step-scoped text stops before the fence being ordered here.
        $write = $script:MusterText.IndexOf('Write `$env:KINGSHAND_HOME\data\<id>\brief.md`')
        $index = $script:MusterText.IndexOf('Add-IndexEntry -Project "<project>" -Path "data\<id>\brief.md"')
        $write | Should -BeGreaterThan -1
        $index | Should -BeGreaterThan $write -Because 'indexing a file before writing it can index a file that never appears'
        Assert-Phrase -Text $script:MusterText -Where 'muster Step 2' `
            -Phrase 'never before it is written, or the index carries a line for a file that was abandoned'
    }

    # Every other kingshand writer of a durable data\ file needs the same call, or the drift count
    # the digest prints grows from kingshand's own routine writes and stops being read. The dated
    # status report is the one that grows without bound: a new unindexed file on every /survey file.
    It '<skill> indexes the durable file it writes, through the module' -ForEach @(
        @{ skill = 'survey';    file = '.claude\skills\survey\SKILL.md'
           paths = @('data\status-report-<YYYY-MM-DD>.md') }
        @{ skill = 'chronicle'; file = '.claude\skills\chronicle\SKILL.md'
           paths = @('data\king.md', 'data\learnings.md', 'data\memory-archive.md',
                     'data\corrections.md') }
        @{ skill = 'annex';     file = '.claude\skills\annex\SKILL.md'
           paths = @('data\projects.md') }
    ) {
        $fences = @(Get-CodeFence (Join-Path $script:Root $file) |
            Where-Object { $_.Contains('Add-IndexEntry') })
        $fences.Count | Should -BeGreaterOrEqual 1 -Because "$skill writes a durable data\ file and must list it"
        foreach ($fence in $fences) {
            $fence.Contains('Import-Module $env:KINGSHAND_HOME\bin\Index.psm1 -Force') |
                Should -BeTrue -Because 'the module is the one place that knows the index format'
        }
        foreach ($named in $paths) {
            @($fences | Where-Object { $_.Contains($named) }).Count |
                Should -BeGreaterOrEqual 1 -Because "$named is written here and nothing else lists it"
        }
    }

    It 'routing covers the durable file another tool writes' {
        Assert-Phrase -Text $script:IndexRouting -Where 'CLAUDE.md knowledge routing' `
            -Phrase ('`data\backlog.md` is `tasks-axi`''s own file, and `Add-IndexEntry` lists it ' +
                     'the first time the digest reports it unindexed')
    }
}

Describe 'no long dash' {
    It 'does not appear in <file>' -ForEach @(
        @{ file = 'CLAUDE.md' }
        @{ file = '.claude\skills\muster\SKILL.md' }
        @{ file = '.claude\skills\annex\SKILL.md' }
        @{ file = '.claude\skills\survey\SKILL.md' }
        @{ file = '.claude\skills\inquest\SKILL.md' }
        @{ file = '.claude\skills\petition\SKILL.md' }
        @{ file = '.claude\skills\statute\SKILL.md' }
        @{ file = '.claude\skills\audience\SKILL.md' }
        @{ file = '.claude\skills\rally\SKILL.md' }
        @{ file = '.claude\skills\chronicle\SKILL.md' }
        @{ file = '.claude\skills\decree\SKILL.md' }
        @{ file = '.claude\skills\setup\SKILL.md' }
        @{ file = 'install.ps1' }
        @{ file = 'docs\2026-08-28-worker-control-plane-decision.md' }
        @{ file = 'docs\2026-08-29-herdr-worker-control-plane.md' }
        @{ file = 'docs\2026-08-30-data-index.md' }
        @{ file = 'docs\2026-08-31-read-first-declared-not-parsed.md' }
        @{ file = 'docs\2026-09-01-stall-detection.md' }
    ) {
        $emDash = [char]0x2014
        $raw = Get-Content -Path (Join-Path $script:Root $file) -Raw
        $raw.IndexOf($emDash) | Should -Be -1 -Because "$file must use '-', never the long dash"
    }
}

Describe 'one file owns herdr''s command line, and the record says why' {
    # The last spawn layer was spelled out in four scripts and three skills, so replacing it meant
    # editing all seven. Keeping the command line in one module is what makes the next migration a
    # single file, and the rule only holds while something asserts it.
    It 'CLAUDE.md lists the module as the only place that knows herdr' {
        Assert-Phrase -Text (Get-DocText $script:HandMd) -Where 'the CLAUDE.md Tooling table' `
            -Phrase '| `bin\Herdr.psm1` | the only place that knows herdr''s command line'
    }

    It 'CLAUDE.md lists the workspace module that replaces the missing arguments' {
        Assert-Phrase -Text (Get-DocText $script:HandMd) -Where 'the CLAUDE.md Tooling table' `
            -Phrase ('| `bin\ClaudeWorkspace.psm1` | writes a worktree''s `settings.local.json` ' +
                     'and pre-seeds folder trust, because no arguments can be passed to a worker |')
    }

    It 'statute states the one-owner rule for the spawn layer' {
        $text = Get-DocText $script:GuidelinesMd
        Assert-Phrase -Text $text -Where 'statute' `
            -Phrase '**`bin\Herdr.psm1` is the only place that knows herdr''s command line.**'
        Assert-Phrase -Text $text -Where 'statute' `
            -Phrase ('none of them composes a herdr argument list')
    }

    It 'the superseded record says so at the top and is not deleted' {
        $old = Join-Path $script:Root 'docs\2026-08-28-worker-control-plane-decision.md'
        Test-Path -LiteralPath $old |
            Should -BeTrue -Because 'the reasoning that held the line for as long as it did is still worth reading'
        $text = Get-DocText $old
        Assert-Phrase -Text $text -Where 'the superseded record' `
            -Phrase 'Status: **superseded on 2026-08-29 by `2026-08-29-herdr-worker-control-plane.md`**'
        Assert-Phrase -Text $text -Where 'the superseded record' `
            -Phrase '**This record''s own revisit trigger fired.**'
        Assert-Phrase -Text $text -Where 'the superseded record' `
            -Phrase 'Do not follow its instructions'
    }

    It 'the new record states the decision, the evidence and the costs' {
        $text = Get-DocText (Join-Path $script:Root 'docs\2026-08-29-herdr-worker-control-plane.md')
        Assert-Phrase -Text $text -Where 'the herdr record' `
            -Phrase 'Supersedes: `2026-08-28-worker-control-plane-decision.md`'
        Assert-Phrase -Text $text -Where 'the herdr record' `
            -Phrase '`bin\Herdr.psm1` is the only place that knows herdr''s command line.'
        Assert-Phrase -Text $text -Where 'the herdr record' `
            -Phrase '**No arguments can be passed to a worker, at all.**'
        Assert-Phrase -Text $text -Where 'the herdr record' `
            -Phrase '**A force-killed worker costs its pane permanently.**'
        Assert-Phrase -Text $text -Where 'the herdr record' `
            -Phrase '**Workers run with transcript saving off.**'
        Assert-Phrase -Text $text -Where 'the herdr record' `
            -Phrase ('The wait is an event, not a poll. Reintroducing a sleep-and-check loop ' +
                     'rebuilds the thing this replaced')
    }

    # The record claimed blocked detection worked, on trial evidence that was real, and listed the
    # fragility moving as a future risk. It had already materialised. A decision record that keeps
    # claiming a capability the system does not have is worse than no record, so the correction is
    # asserted - and so is the trial evidence it corrects, which is not deleted.
    It 'the record corrects the blocked-detection claim with what was observed' {
        $text = Get-DocText (Join-Path $script:Root 'docs\2026-08-29-herdr-worker-control-plane.md')
        Assert-Phrase -Text $text -Where 'the herdr record' `
            -Phrase 'Correction: blocked detection does not hold'
        Assert-Phrase -Text $text -Where 'the herdr record' `
            -Phrase ('`live_blocked_form` at priority 980 - the one that fired in the trial - ' +
                     'evaluated and did not match. Every blocked rule failed.')
        Assert-Phrase -Text $text -Where 'the herdr record' `
            -Phrase ('Minutes later the same still-blocked worker reported `done`, while a ' +
                     'genuinely finished worker reported `idle`.')
    }

    It 'says what kingshand relies on instead, and what the guard does' {
        $text = Get-DocText (Join-Path $script:Root 'docs\2026-08-29-herdr-worker-control-plane.md')
        Assert-Phrase -Text $text -Where 'the herdr record' `
            -Phrase ('**Kingshand therefore no longer relies on herdr''s classification for the ' +
                     'blocked case.**')
        Assert-Phrase -Text $text -Where 'the herdr record' `
            -Phrase ('`Test-HerdrAgentAwaitingInput` reads the LIVE VIEWPORT - `agent read ' +
                     '--source visible`')
        Assert-Phrase -Text $text -Where 'the herdr record' `
            -Phrase ('`Wait-HerdrAgentSettled` is the guarded wake.')
        Assert-Phrase -Text $text -Where 'the herdr record' `
            -Phrase ('a worker is done when it settled, is not awaiting input, and left the ' +
                     '`report.md` its brief required')
    }

    It 'stops listing the moved fragility as a future risk, and keeps the trial evidence' {
        $text = Get-DocText (Join-Path $script:Root 'docs\2026-08-29-herdr-worker-control-plane.md')
        Assert-Phrase -Text $text -Where 'the herdr record' `
            -Phrase '**The fragility moved rather than went away, and it has already cost us.**'
        Assert-Phrase -Text $text -Where 'the herdr record' `
            -Phrase ('A worker made to open an `AskUserQuestion` menu read `blocked` twelve ' +
                     'seconds later')
        Assert-Phrase -Text $text -Where 'the herdr record' `
            -Phrase '**This held in the trial and does not hold generally**'
    }

    It 'puts the screen check among the things that must not be undone' {
        $text = Get-DocText (Join-Path $script:Root 'docs\2026-08-29-herdr-worker-control-plane.md')
        Assert-Phrase -Text $text -Where 'the herdr record' `
            -Phrase ('The screen check stays, and it reads the live viewport. Deleting it, or ' +
                     'pointing it at `recent` or `recent-unwrapped`, restores a control plane ' +
                     'that reports a worker waiting on a person as finished.')
        Assert-Phrase -Text $text -Where 'the herdr record' `
            -Phrase 'No state is ever proof of completion on its own.'
    }
}

Describe 'decree keeps an unresolved decision durable' {
    # This skill has no script behind it at all - kingshand has no teardown gate to enforce it - so
    # the text IS the whole mechanism, and every clause below is load-bearing. A decision that is
    # never registered leaves no trace once the worker, its session and its transcript are gone.
    # Every phrase is single-quoted on purpose: a backtick is PowerShell's escape character inside
    # a double-quoted string, and these clauses are thick with backticked identifiers.
    BeforeAll { $script:HoldText = Get-DocText $script:HoldMd }

    It 'requires the decision to be durable before the work counts as complete' {
        Assert-Phrase -Text $script:HoldText -Where 'decree' `
            -Phrase ('must become a durable backlog item in `data\backlog.md` **before that work ' +
                     'may be treated as complete**')
    }

    It 'leaves the inventory to the agent because no script can infer a decision from prose' {
        Assert-Phrase -Text $script:HoldText -Where 'decree' `
            -Phrase ('You perform the inventory yourself, because no script can infer a decision ' +
                     'from report prose, chat or terminal output.')
    }

    It 'keeps the stable-key rule, with the slug shape a tasks-axi id needs' {
        Assert-Phrase -Text $script:HoldText -Where 'the stable-key rule' `
            -Phrase ('Give each distinct unresolved decision a **stable, privacy-safe key**, and ' +
                     'register it under that key, so registering it a second time on a retry is ' +
                     'idempotent while two different decisions keep two different durable ' +
                     'identities.')
        Assert-Phrase -Text $script:HoldText -Where 'the stable-key rule' `
            -Phrase ('`tasks-axi` ids are slug-shaped - letters, digits, `.`, `_` and `-`, with ' +
                     'no spaces - so the key must be too.')
        Assert-Phrase -Text $script:HoldText -Where 'the stable-key rule' `
            -Phrase ('A key that changes between retries files the same decision twice; a key ' +
                     'shared by two decisions loses one of them.')
    }

    It 'refuses to let an empty inventory be silence' {
        Assert-Phrase -Text $script:HoldText -Where 'the inventory declaration' `
            -Phrase ('either every unresolved key is registered, or you state plainly that the ' +
                     'reviewed surface contains no unresolved decision')
        Assert-Phrase -Text $script:HoldText -Where 'the inventory declaration' `
            -Phrase '**Do not let "I found nothing" be silence.**'
    }

    It 'never closes a hold because the work that found it finished' {
        Assert-Phrase -Text $script:HoldText -Where 'decree' `
            -Phrase ('**Do not close a hold merely because the work that found it finished**, its ' +
                     'report was archived, or its worker was torn down. Those are unrelated ' +
                     'events.')
        Assert-Phrase -Text $script:HoldText -Where 'decree' `
            -Phrase ('A completed investigation, a closed backlog item for the investigation ' +
                     'itself, a confirmed push and a removed worktree say nothing whatsoever ' +
                     'about whether the user has answered.')
    }

    It 'keeps an authorised answer routed before the hold may close' {
        Assert-Phrase -Text $script:HoldText -Where 'decree' `
            -Phrase ('the hold stays the authoritative item until the answer is durably recorded, ' +
                     'the dependent work exists as its own backlog item, and that item is blocked ' +
                     'by the hold. Only then does the hold close.')
    }

    It 'records a declined answer without letting it stand in for routing' {
        Assert-Phrase -Text $script:HoldText -Where 'decree' `
            -Phrase ('When the answer routes no work at all - a declined proposal - record that ' +
                     'answer and close it. That never substitutes for routing work the user did ' +
                     'authorise.')
    }

    It 'keeps the exclusions that stop noise becoming holds' {
        Assert-Phrase -Text $script:HoldText -Where 'the exclusions' `
            -Phrase ('Resolved findings, recommendations that need no choice, and prose that ' +
                     'merely sounds decision-like do not create holds.')
        Assert-Phrase -Text $script:HoldText -Where 'the exclusions' `
            -Phrase ('A question the worker answered itself, a recommendation the user can take ' +
                     'or leave with no consequence either way, and a sentence shaped like a ' +
                     'question but settled in the next paragraph are all noise')
    }

    It 'forbids survey compensating by scraping prose' {
        Assert-Phrase -Text $script:HoldText -Where 'decree' `
            -Phrase ('`survey` reads the resulting structured state through `tasks-axi` and must ' +
                     'never compensate by scraping reports, chat or terminal output.')
    }

    It 'maps the four missing verbs onto what tasks-axi actually has, without a wrapper' {
        Assert-Phrase -Text $script:HoldText -Where 'the tasks-axi mapping' `
            -Phrase ('It has **no** `complete`, `resolve`, `decline` or `repair` verb, so each of ' +
                     'those states is expressed with what does exist.')
        Assert-Phrase -Text $script:HoldText -Where 'the tasks-axi mapping' `
            -Phrase 'Do not build a wrapper script for the missing ones'
        Assert-Phrase -Text $script:HoldText -Where 'the tasks-axi mapping' `
            -Phrase '`tasks-axi hold <key> --reason "<reason>" --kind captain`'
        Assert-Phrase -Text $script:HoldText -Where 'the tasks-axi mapping' `
            -Phrase '`tasks-axi block <work-id> --by <key>`'
    }

    It 'states the close order that routing depends on' {
        Assert-Phrase -Text $script:HoldText -Where 'the tasks-axi mapping' `
            -Phrase ('That is why the order below is load-bearing: block first, close second. ' +
                     'Close first and there is nothing left to route')
    }

    It 'keeps a declined answer distinguishable from an answered-and-routed one' {
        Assert-Phrase -Text $script:HoldText -Where 'the note convention' `
            -Phrase ('`answered: <the user''s decision, in their terms>` - the answer authorised ' +
                     'work. A dependent backlog item exists and was blocked by this key before ' +
                     'the hold closed.')
        Assert-Phrase -Text $script:HoldText -Where 'the note convention' `
            -Phrase ('`declined: <the user''s decision, in their terms>` - the answer routed no ' +
                     'work at all.')
        Assert-Phrase -Text $script:HoldText -Where 'the note convention' `
            -Phrase '**A hold closed with no note leaves no durable answer**'
    }

    It 'says honestly that no script enforces the gate' {
        Assert-Phrase -Text $script:HoldText -Where 'the enforcement section' `
            -Phrase ('Firstmate blocks its teardown on this gate. **Kingshand has nothing ' +
                     'equivalent, and this skill will not pretend otherwise.**')
        Assert-Phrase -Text $script:HoldText -Where 'the enforcement section' `
            -Phrase ('`muster` Step 8b tears a worker down on landing or push evidence alone and ' +
                     'reads no decision state, `bin\` contains no check that looks for an open ' +
                     'hold before cleanup')
        Assert-Phrase -Text $script:HoldText -Where 'the enforcement section' `
            -Phrase ('So this is a discipline the Hand follows, not a check a script performs.')
    }

    It 'is the Hand''s to load, never a worker''s' {
        Assert-Phrase -Text $script:HoldText -Where 'decree' `
            -Phrase 'The Hand loads it; nobody invokes it by name.'
        Assert-Phrase -Text $script:HoldText -Where 'decree' `
            -Phrase 'A worker never loads it.'
    }
}

Describe 'muster loads the decision lifecycle before it calls work complete' {
    # A worker's report.md is required to name any decision its brief did not settle, so the two
    # moments that read it - completion and close-out - are exactly where a decision is lost if
    # nothing picks it up. Neither of them may treat a finished worker as an answered question.
    It 'Step 6 loads it before treating the work as complete' {
        $step = Get-MusterStep 'Step 6 - Completion'
        Assert-Phrase -Text $step -Where 'muster Step 6' `
            -Phrase ('**Before you treat this worker''s work as complete, load ' +
                     '`decree`.**')
        Assert-Phrase -Text $step -Where 'muster Step 6' `
            -Phrase ('A worker finishing is not an answer, and nothing here closes a decision.')
    }

    It 'Step 8a loads it before close-out, and keeps the hold open through teardown' {
        $step = Get-MusterStep 'Step 8a'
        Assert-Phrase -Text $step -Where 'muster Step 8a' `
            -Phrase '**Load `decree` before closing this work out.**'
        Assert-Phrase -Text $step -Where 'muster Step 8a' `
            -Phrase ('A hold opened from this work''s report stays open through `gating`, through ' +
                     '`ready`, through `landed`, and through the teardown at Step 8b, because ' +
                     'none of those events is an answer.')
    }
}

Describe 'survey puts an open decision in King''s Call and only there' {
    # King's Call is the bucket for what needs the user's own action, and an unanswered decision
    # is the purest case of it. Rendering it in Charted Next instead buries it among work that is
    # merely waiting, and rendering it in both breaks the exclusivity that makes the digest a
    # snapshot rather than a list.
    BeforeAll { $script:SurveyHold = Get-DocText $script:SurveyMd }

    It 'reads the hold kind rather than the hold alone' {
        Assert-Phrase -Text $script:SurveyHold -Where 'the survey gather step' `
            -Phrase ('**The hold kind is what decides the bucket, so read it rather than the hold ' +
                     'alone.** A hold of kind `captain` waits on the user''s own answer and ' +
                     'belongs in King''s Call; `external`, `load`, `parked` and `future` wait ' +
                     'on something else and belong in Charted Next.')
    }

    It 'renders a captain hold in King''s Call with its reason' {
        Assert-Phrase -Text $script:SurveyHold -Where 'the survey King''s Call bucket' `
            -Phrase ('A backlog item held with a hold kind of `captain` - an open decision waiting ' +
                     'on the user''s own answer, read from `tasks-axi ready --include-held`.')
        Assert-Phrase -Text $script:SurveyHold -Where 'the survey King''s Call bucket' `
            -Phrase ('This is what King''s Call is for, so it renders here and in no other ' +
                     'section.')
    }

    It 'never duplicates it into Charted Next' {
        Assert-Phrase -Text $script:SurveyHold -Where 'the survey Charted Next bucket' `
            -Phrase ('A hold of kind `captain` is the one queued item that does not belong here.')
        Assert-Phrase -Text $script:SurveyHold -Where 'the survey Charted Next bucket' `
            -Phrase ('Never duplicate it into this section to keep the queue looking complete: ' +
                     'the four buckets are mutually exclusive, and one decision rendered twice ' +
                     'reads as two.')
    }

    It 'keeps the four buckets mutually exclusive' {
        Assert-Phrase -Text $script:SurveyHold -Where 'the survey chat-response contract' `
            -Phrase 'The four buckets are mutually exclusive, so every item lands in exactly one'
    }

    It 'still leaves closing a hold to its owner rather than doing it here' {
        Assert-Phrase -Text $script:SurveyHold -Where 'the survey read-only section' `
            -Phrase ('`muster` owns every one of those, and `decree` owns the only ' +
                     'way a captain hold may close')
    }
}

Describe 'the setup skill ships inside the repo so a fresh clone can bootstrap itself' {
    # Every skill is project-local, under .claude\skills\, so all thirteen are readable the moment
    # someone opens Claude Code in this directory and none of them is reachable from anywhere
    # else on the machine. That is what lets "set it up" be the first thing anyone types.
    BeforeAll { $script:SetupText = Get-DocText $script:SetupMd }

    It 'lives in .claude\skills\, and no top-level skills\ directory exists' {
        Test-Path -LiteralPath $script:SetupMd |
            Should -BeTrue -Because 'a fresh clone installs nothing, so the setup skill must be project-level'
        Test-Path -LiteralPath (Join-Path $script:Root 'skills') |
            Should -BeFalse -Because 'a second skills root would load only for whoever linked it into their profile'
    }

    It 'has frontmatter that parses, with a name and a non-empty description' {
        $fm = Get-Frontmatter $script:SetupMd
        $fm['name']    | Should -Be 'setup' -Because 'the frontmatter name must match the skill directory'
        $fm['version'] | Should -Be '1.0.0'
        $fm['description'] | Should -Not -BeNullOrEmpty -Because 'a skill with no description never gets loaded'
        $fm['description'].Length |
            Should -BeGreaterThan 40 -Because 'the description is the trigger, and it must name the situation'
    }

    It 'the description carries the natural-language trigger <trigger>' -ForEach @(
        @{ trigger = '"set it up"' }
        @{ trigger = '"setup"' }
        @{ trigger = '"install"' }
        @{ trigger = '"get started"' }
        @{ trigger = '"first run"' }
        @{ trigger = '"/setup"' }
    ) {
        $description = (Get-Frontmatter $script:SetupMd)['description']
        $description.Contains($trigger) |
            Should -BeTrue -Because "nobody reads the README first, so $trigger must fire the skill"
    }

    It 'runs install.ps1 with -InstallMissing, from the repository root' {
        Assert-Phrase -Text $script:SetupText -Where 'the setup skill' -Phrase '.\install.ps1 -InstallMissing'
        Assert-Phrase -Text $script:SetupText -Where 'the setup skill' `
            -Phrase 'Then run it from the repository root'
    }

    It 'translates the output instead of pasting it' {
        Assert-Phrase -Text $script:SetupText -Where 'the setup skill' `
            -Phrase '**Never paste the script''s output into chat.**'
    }

    It 'points at instructions.md as the user''s own file that nothing rewrites' {
        Assert-Phrase -Text $script:SetupText -Where 'the setup skill' `
            -Phrase '**Write `instructions.md`.** It was just created from the template.'
        Assert-Phrase -Text $script:SetupText -Where 'the setup skill' `
            -Phrase 'nothing here ever rewrites it'
    }

    It 'names both things the installer deliberately does not do' {
        Assert-Phrase -Text $script:SetupText -Where 'the setup skill' `
            -Phrase '**`no-mistakes` was not installed.**'
        Assert-Phrase -Text $script:SetupText -Where 'the setup skill' `
            -Phrase '**`config\ado.json` was not written.**'
        Assert-Phrase -Text $script:SetupText -Where 'the setup skill' `
            -Phrase ('When that file is absent, `muster` asks for the Azure DevOps organization and ' +
                     'project the first time it needs them, rather than inventing values')
    }

    # The installer now separates "dispatch cannot work without this" from "you may never need
    # this". That distinction is worthless if the skill reading the output reports every NOTE as
    # something the user has to go and fix, which is the first-run experience this replaced.
    It 'reads a NOTE as a choice rather than as a problem' {
        Assert-Phrase -Text $script:SetupText -Where 'the setup skill' `
            -Phrase '**A `NOTE` line is not a problem and must never be reported as one.**'
        Assert-Phrase -Text $script:SetupText -Where 'the setup skill' `
            -Phrase ('Read the exit code and the `MISS` lines for what is wrong; everything else is ' +
                     'a choice they can make later.')
    }

    It 'says permission prompts are off and names the README section that explains it' {
        Assert-Phrase -Text $script:SetupText -Where 'the setup skill' `
            -Phrase 'neither the Hand nor its workers will ask them to approve a tool call'
        Assert-Phrase -Text $script:SetupText -Where 'the setup skill' `
            -Phrase 'Permissions, and what you are agreeing to'
    }

    It 'sends them to a new shell and then to /annex' {
        Assert-Phrase -Text $script:SetupText -Where 'the setup skill' `
            -Phrase '**Open a new shell.** `KINGSHAND_HOME` is set for the user'
        Assert-Phrase -Text $script:SetupText -Where 'the setup skill' `
            -Phrase '**Register a repository** with `/annex <path>`'
    }

    # The claim this used to pin was false, and false in the direction that costs a new user their
    # first ten minutes: it told them to declare their repository roots before annex would work.
    # Measured directly - a Hand session with additionalDirectories empty read a file, WROTE a file,
    # globbed and ran git against another drive, because bypassPermissions already covers it.
    # Registering a repository in place is pointless if its root has to be declared first.
    It 'does not claim a repository root must be added before annex works' {
        Assert-Phrase -Text $script:SetupText -Where 'the setup skill' `
            -Phrase ('Do not tell the user they must add their repository roots first. They ' +
                     'almost certainly do not.')
        $script:SetupText.Contains('cannot be reached until its root is added') |
            Should -BeFalse -Because 'that was measured to be untrue'
    }

    It 'does no project work of its own' {
        Assert-Phrase -Text $script:SetupText -Where 'the setup skill' `
            -Phrase 'No project work, no dispatch, no registration'
    }

    It 'is named in the README as the first route in' {
        $readme = Get-DocText (Join-Path $script:Root 'README.md')
        Assert-Phrase -Text $readme -Where 'the README Install section' `
            -Phrase 'Then type **`set it up`** - or `setup`, or `/setup`.'
        Assert-Phrase -Text $readme -Where 'the README Install section' `
            -Phrase '**`-InstallMissing` is opt-in.**'
    }
}

Describe 'install.ps1 reports rather than installs unless it is told to' {
    # Asserted against the source text, never by running it. Executing the installer inside the
    # suite would put software on the machine running the tests, which is the exact behaviour the
    # default this test guards was written to avoid.
    BeforeAll { $script:InstallSource = Get-Content -Path $script:InstallPs1 -Raw }

    It 'says in its own header that it installs nothing by default' {
        Assert-Phrase -Text (Get-DocText $script:InstallPs1) -Where 'the install.ps1 header' `
            -Phrase 'It installs nothing by default.'
        Assert-Phrase -Text (Get-DocText $script:InstallPs1) -Where 'the install.ps1 header' `
            -Phrase ('a script that silently `npm install -g`s things into a user''s machine is a ' +
                     'script nobody should run')
    }

    # This pinned `$missing.Count -gt 0` until optional prerequisites got their own list. The rule
    # being guarded never changed - nothing installs without the switch - but the condition it is
    # spelled with now has to see the optional list too, or -InstallMissing would silently stop
    # installing gh and Pester the moment they stopped counting as blockers.
    It 'guards the whole install pass behind the switch' {
        Assert-Phrase -Text $script:InstallSource -Where 'install.ps1' `
            -Phrase 'if ($InstallMissing -and ($missing.Count + $optional.Count) -gt 0) {'
    }

    # A brand-new user with nothing installed got a MISS line and a non-zero exit for Pester, a
    # test framework nothing at runtime uses, and for gh, which only a push-capable posture needs.
    # A report that calls a working install broken is a report the reader stops trusting, which
    # costs the failures that are real.
    # Phrases here stay inside a single comment line on purpose. Get-DocText normalises whitespace
    # but leaves the `#` markers where they are, so a sentence spanning two comment lines comes
    # back with a stray `#` in the middle of it and is never found.
    It 'reports an optional dependency as a note, never as a miss' {
        $text = Get-DocText $script:InstallPs1
        Assert-Phrase -Text $text -Where 'install.ps1' `
            -Phrase 'A tool marked Optional is one a working installation may never need.'
        Assert-Phrase -Text $text -Where 'install.ps1' `
            -Phrase 'It is reported NOTE rather than MISS, and never sets this script''s exit code.'
        Assert-Phrase -Text $script:InstallSource -Where 'install.ps1' `
            -Phrase 'elseif ($t.Contains(''Optional'') -and $t.Optional) {'
    }

    It 'keeps Pester out of the blocking list and says why' {
        $text = Get-DocText $script:InstallPs1
        Assert-Phrase -Text $text -Where 'install.ps1' `
            -Phrase 'Pester is a contributor dependency, not a runtime one.'
        Assert-Phrase -Text $text -Where 'install.ps1' `
            -Phrase 'no skill imports it, so an'
        Assert-Phrase -Text $script:InstallSource -Where 'install.ps1' `
            -Phrase '$alsoLater.Add(@{ Name = ''Pester''; Manager = ''psgallery'''
        $script:InstallSource | Should -Not -Match '\$still\.Add\(@\{ Name = ''Pester''' `
            -Because 'a missing test framework must never set the exit code of a working install'
    }

    It 'keeps gh out of the blocking list and points at annex for the gap that leaves' {
        $text = Get-DocText $script:InstallPs1
        Assert-Phrase -Text $text -Where 'install.ps1' `
            -Phrase 'Only a push-capable posture opens a pull request, and only a pull request needs gh.'
        Assert-Phrase -Text $text -Where 'install.ps1' `
            -Phrase ('`annex` closes the gap that leaves, by refusing a push-capable posture on a ' +
                     'machine with no gh.')
        $script:InstallSource | Should -Match "Name = 'gh';[^\r\n]*Optional = \`$true" `
            -Because 'gh is installed by -InstallMissing but never blocks a run'
    }

    It 'lists optional things separately from what actually blocks a dispatch' {
        Assert-Phrase -Text $script:InstallSource -Where 'install.ps1' `
            -Phrase 'Write-Host "Optional, and nothing is broken without them:"'
        Assert-Phrase -Text (Get-DocText $script:InstallPs1) -Where 'install.ps1' `
            -Phrase 'Listed, never counted.'
    }

    # Nothing wrote this line, and the prereq check failed without it - so every new machine failed
    # a check by definition, with "add it by hand" as the only fix. It is written outside the
    # repository, which is why the header claim below had to be corrected rather than kept.
    It 'writes the global gitignore line, once, without rewriting the user''s file' {
        $text = Get-DocText $script:InstallPs1
        Assert-Phrase -Text $text -Where 'install.ps1' `
            -Phrase 'Never duplicate a line: an installer run twice must leave exactly one of each.'
        Assert-Phrase -Text $text -Where 'install.ps1' `
            -Phrase 'Never rewrite or reorder a file the user already had'
        Assert-Phrase -Text $script:InstallSource -Where 'install.ps1' `
            -Phrase "`$ignoreLines = @('.claude/worktrees/', '.claude/settings.local.json')"
        Assert-Phrase -Text $script:InstallSource -Where 'install.ps1' `
            -Phrase '$wanted  = @($ignoreLines | Where-Object { $present -notcontains $_ })'
        Assert-Phrase -Text $script:InstallSource -Where 'install.ps1' `
            -Phrase '& git config --global core.excludesFile $forGit'
    }

    It 'prints every command before running it' {
        Assert-Phrase -Text $script:InstallSource -Where 'install.ps1' `
            -Phrase 'Write-Host "  RUN   $Command"'
        Assert-Phrase -Text (Get-DocText $script:InstallPs1) -Where 'install.ps1' `
            -Phrase 'the flag is the consent, and every command is printed before it runs'
    }

    # Only winget is a true floor. npm was treated as one too, which stopped the installer dead on
    # a machine that had winget and could therefore have installed Node in one command. A user who
    # asks for setup in one word should not be handed a manual step the machine could take itself.
    It 'treats only winget as a floor, and installs Node itself when winget is present' {
        $text = Get-DocText $script:InstallPs1
        Assert-Phrase -Text $text -Where 'install.ps1' `
            -Phrase 'Only winget is a true floor'
        Assert-Phrase -Text $text -Where 'install.ps1' `
            -Phrase 'winget install --id OpenJS.NodeJS.LTS --silent --accept-package-agreements --accept-source-agreements'
    }

    It 'gives a short instruction for each thing it genuinely cannot install' {
        $text = Get-DocText $script:InstallPs1
        Assert-Phrase -Text $text -Where 'install.ps1' `
            -Phrase 'Install Node.js from https://nodejs.org, then run this again.'
        Assert-Phrase -Text $text -Where 'install.ps1' `
            -Phrase 'Install App Installer from the Microsoft Store, then run this again.'
    }

    It 'refreshes PATH from the registry after installing, without discarding session entries' {
        Assert-Phrase -Text $script:InstallSource -Where 'install.ps1' `
            -Phrase 'function Update-PathFromRegistry'
        Assert-Phrase -Text (Get-DocText $script:InstallPs1) -Where 'install.ps1' `
            -Phrase 'Add what the registry now has rather than replacing PATH'
    }

    It 'installs Pester through the gallery, scoped to the current user' {
        Assert-Phrase -Text $script:InstallSource -Where 'install.ps1' `
            -Phrase 'Install-Module Pester -MinimumVersion 6.0.0 -Force -SkipPublisherCheck -Scope CurrentUser -ErrorAction Stop'
        Assert-Phrase -Text (Get-DocText $script:InstallPs1) -Where 'install.ps1' `
            -Phrase '-Scope CurrentUser needs no elevation'
    }

    # The rule this guards has not changed: -InstallMissing must never drag in the review gate.
    # Wanting every prerequisite present is not the same as wanting a review pipeline, and it is a
    # 14 MB download for someone whose work may only ever stop at a local branch. What changed is
    # that the gate is now installable at all - previously kingshand told people to "put it in
    # tools\no-mistakes" and never said where to get it, while the obvious guess installs an
    # unrelated npm package of the same name.
    It 'gates the review gate on its own switch, never on -InstallMissing' {
        $text = Get-DocText $script:InstallPs1
        Assert-Phrase -Text $text -Where 'install.ps1' `
            -Phrase 'It is gated on its own switch rather than on'
        $script:InstallSource | Should -Match '\$WithReviewGate' -Because 'the switch is what installs it'
        $script:InstallSource | Should -Not -Match 'InstallMissing[^\r\n]*Install-NoMistakes' `
            -Because '-InstallMissing alone must never pull down a review pipeline'
    }

    It 'names the real source and warns off the npm package of the same name' {
        $text = Get-DocText $script:InstallPs1
        Assert-Phrase -Text $text -Where 'install.ps1' -Phrase 'kunchenguid/no-mistakes'
        $script:InstallSource | Should -Match 'Do NOT ``npm install -g no-mistakes``' `
            -Because 'that name on npm is a different tool that installs cleanly and then does not work'
    }

    It 're-checks afterwards rather than assuming the install worked' {
        $text = Get-DocText $script:InstallPs1
        Assert-Phrase -Text $text -Where 'install.ps1' `
            -Phrase 'the second call is what turns a claim into a check.'
        Assert-Phrase -Text $text -Where 'install.ps1' -Phrase "Write-Step 'Prerequisites, re-checked'"
    }

    It 'still exits non-zero listing whatever is missing at the end' {
        Assert-Phrase -Text $script:InstallSource -Where 'install.ps1' `
            -Phrase 'if ($missing.Count -gt 0) {'
        Assert-Phrase -Text (Get-DocText $script:InstallPs1) -Where 'install.ps1' `
            -Phrase 'Install these before dispatching anything:'
    }

    It 'refuses to elevate itself and names the elevated command instead' {
        $text = Get-DocText $script:InstallPs1
        Assert-Phrase -Text $text -Where 'install.ps1' `
            -Phrase 'If that failed for want of administrator rights, run this in an elevated PowerShell:'
        Assert-Phrase -Text $text -Where 'install.ps1' -Phrase 'This script does not elevate itself.'
    }
}

Describe 'the skills are project-local and nothing reaches into the user profile' {
    # Linking the skills into ~\.claude\skills\ changed how Claude Code behaved in every unrelated
    # project on the machine, and a name that already existed there was reported KEPT so the newer
    # copy silently never took effect. Both go away only if no script creates a link at all, which
    # is a rule about absence - so it is asserted as absence, over the whole repository.
    BeforeAll {
        # The shipped code only: install.ps1 and bin\. The suite itself is excluded because these
        # very assertions have to spell the forbidden strings out to search for them.
        $script:AllSource = @(
            Get-Item -LiteralPath $script:InstallPs1
            Get-ChildItem -Path (Join-Path $script:Root 'bin') -Recurse -File -Include '*.ps1', '*.psm1'
        )
        $script:InstallText = Get-Content -Path $script:InstallPs1 -Raw
    }

    # herald changes how the Hand writes, and the danger in an output-shaping skill is that "keep
    # it short" quietly becomes "leave things out". Its rules - suppress tangents, cap lists at
    # five, no recap - could each be read as licence to drop a blocker or a failure. So the skill
    # has to say out loud which contract it owns and which it does not, and these pin that.
    # regency runs the fleet while nobody is watching, which makes it the worst place in this
    # repository for a rule to be implied rather than written. Every case below is something that
    # would be tempting at 2am with a worker sitting on a menu and nobody to ask.
    Context 'regency grants no authority the King has not already given' {
        BeforeAll {
            $script:Regency = Get-Content -Path (Join-Path $script:Root '.claude\skills\regency\SKILL.md') -Raw
        }

        It 'states up front that being away is not consent' {
            $script:Regency | Should -Match 'Being away is not consent'
            $script:Regency | Should -Match 'holds no new powers'
        }

        It 'never answers a question a worker asked' {
            $script:Regency | Should -Match 'Record it, never answer it'
            $script:Regency | Should -Match 'Do \*\*not\*\* send it keys'
            $script:Regency | Should -Match 'record the question verbatim'
        }

        It 'adds nothing to the landing authority the posture already carries' {
            $script:Regency | Should -Match 'Regency adds nothing to it'
            $script:Regency | Should -Match 'A\s+project without `\+yolo` lands nothing while they are away'
        }

        It 'keeps destructive, irreversible and security-sensitive actions out of reach' {
            $script:Regency | Should -Match 'Anything destructive or irreversible'
            $script:Regency | Should -Match 'Anything security-sensitive'
            $script:Regency | Should -Match 'A red merge'
        }

        It 'refuses to start a regency over a worker it cannot see' {
            $script:Regency | Should -Match 'cannot be watched'
            $script:Regency | Should -Match 'Do not\s+enter a regency silently over a worker you cannot see'
        }

        It 'admits it stops supervising if the session ends' {
            $script:Regency | Should -Match 'Nothing supervises the fleet if this Claude Code session ends'
            $script:Regency | Should -Match 'a promise you cannot keep'
        }

        It 'ends on any ordinary message, and biases ambiguity toward ending' {
            $script:Regency | Should -Match 'Bias every ambiguous case toward ending'
            $script:Regency | Should -Match 'a present King\s+outranks a durable flag'
        }
    }

    Context 'herald owns output shape and nothing else' {
        BeforeAll {
            $script:Herald = Get-Content -Path (Join-Path $script:Root '.claude\skills\herald\SKILL.md') -Raw
        }

        # The shape is on by default, so its rules have to live where they apply unloaded. A rule
        # that exists only in a skill nobody loaded is not in force, and "it is the default" would
        # be a claim rather than a fact. These two pin both halves.
        It 'says the shape is already on without the skill being loaded' {
            $script:Herald | Should -Match '\*\*This shape is the default\. It is already on'
            $script:Herald | Should -Match 'a rule that only exists in an unloaded skill is not in force'
        }

        It 'the rules that must apply unloaded are actually in CLAUDE.md' {
            $hand = Get-Content -Path (Join-Path $script:Root 'CLAUDE.md') -Raw
            $hand | Should -Match 'This shape is \*\*the default and always on\*\*'
            $hand | Should -Match 'Number multi-step work'
            $hand | Should -Match 'Cap a list at five items'
            $hand | Should -Match 'Restate where things stand'
        }

        It 'states that it never suppresses an escalation' {
            $script:Herald | Should -Match 'It never suppresses an escalation'
            $script:Herald | Should -Match 'shaped differently'
        }

        It 'does not relax the hard rules, attribution, or the metaphor boundary' {
            $script:Herald | Should -Match 'It relaxes no hard rule'
            $script:Herald | Should -Match 'never puts an assistant or a model'
            $script:Herald | Should -Match 'metaphor words stay out of anything posted outward'
        }

        It 'says plainly that shaping is not permission to omit' {
            $script:Herald | Should -Match 'Shaping output is not permission to omit'
            $script:Herald | Should -Match 'never shortens a report by leaving out what failed'
        }

        It 'turning it off changes shape only, and does not survive the session' {
            $script:Herald | Should -Match 'only the shape changes'
            $script:Herald | Should -Match 'Every new session starts shaped, because that is the default'
        }

        It 'credits the MIT-licensed source the rules came from' {
            $script:Herald | Should -Match 'github\.com/ayghri/i-have-adhd'
            (Get-Content -Path (Join-Path $script:Root 'LICENSE') -Raw) |
                Should -Match 'i-have-adhd' -Because 'adapted MIT work belongs in the licence, not only in a skill'
        }
    }

    It 'every skill directory lives under .claude\skills\' {
        $skills = @(Get-ChildItem (Join-Path $script:Root '.claude\skills') -Directory)
        $skills.Count | Should -Be 13 -Because 'twelve skills plus setup, all project-local'
        @($skills.Name) | Should -Contain 'herald' -Because 'output shape has an owner the user can turn on'
        foreach ($s in $skills) {
            Test-Path -LiteralPath (Join-Path $s.FullName 'SKILL.md') |
                Should -BeTrue -Because "$($s.Name) must carry a SKILL.md"
        }
    }

    It 'no script creates a junction or a symlink' {
        foreach ($f in $script:AllSource) {
            $text = Get-Content -Path $f.FullName -Raw
            $text.Contains('-ItemType Junction') |
                Should -BeFalse -Because "$($f.Name) must not link anything into the user's profile"
            $text.Contains('-ItemType SymbolicLink') |
                Should -BeFalse -Because "$($f.Name) must not link anything into the user's profile"
        }
    }

    # Asserted as an absence of overlap rather than of a literal path: a script that cannot reach
    # the profile cannot install a skill into it, whatever it says about skills, and a script that
    # can reach the profile must have no business with skills at all.
    It 'no script writes to the user profile skills directory' {
        foreach ($f in $script:AllSource) {
            $text = Get-Content -Path $f.FullName -Raw
            ($text.Contains('USERPROFILE') -and $text -match '(?i)skills') |
                Should -BeFalse -Because "$($f.Name) must leave ~\.claude\skills\ alone entirely"
        }
    }

    # The blanket ban on touching the profile at all was the right proxy while nothing needed to.
    # Folder trust changed that: herdr launches a worker in a worktree Claude Code has never seen,
    # and the trust registry is a single file in the profile with no per-project alternative. So
    # the exception is named here, and it is exactly one file in exactly one module - anything
    # else reaching into the profile is still the failure this guards.
    It 'the only script that touches the profile is the trust one, and only for .claude.json' {
        $reaching = @($script:AllSource | Where-Object {
            (Get-Content -Path $_.FullName -Raw).Contains('USERPROFILE')
        })
        (@($reaching | ForEach-Object { $_.Name }) -join ', ') |
            Should -Be 'ClaudeWorkspace.psm1' -Because 'folder trust is the one thing that has nowhere else to live'
        $text = Get-Content -Path $reaching[0].FullName -Raw
        $text.Contains('.claude.json') |
            Should -BeTrue -Because 'the trust registry is one file, not a directory to write into'
    }

    It 'install.ps1 has no Skills step and no -SkipSkills switch' {
        $script:InstallText.Contains('SkipSkills') |
            Should -BeFalse -Because 'the switch existed only to opt out of the junctions'
        $script:InstallText.Contains("Write-Step 'Skills'") |
            Should -BeFalse -Because 'there is no skills step left to run'
    }

    It 'install.ps1 says in its header that it writes nothing outside this repository' {
        Assert-Phrase -Text (Get-DocText $script:InstallPs1) -Where 'the install.ps1 header' `
            -Phrase ('The skills live in this repository''s own `.claude\skills\`, so nothing is ' +
                     'linked into `~\.claude\skills\` and a Claude Code session in any other ' +
                     'directory is unaffected.')
    }

    # This used to pin "except the two user environment variables". That claim became false the
    # moment install.ps1 started writing the global gitignore line, so the claim was corrected
    # rather than the write hidden - a header promising less than the script does is worse than no
    # promise at all, because it is the thing a reader checks instead of reading the code. The
    # count is pinned deliberately: adding a fourth write without saying so fails here.
    It 'install.ps1 names all four things it writes outside this repository, and the README agrees' {
        Assert-Phrase -Text (Get-DocText $script:InstallPs1) -Where 'the install.ps1 header' `
            -Phrase ('It writes at most four things outside this repository, and names each one as ' +
                     'it does it: the two user environment variables KINGSHAND_HOME and ' +
                     'LAVISH_AXI_PORT, the lines `.claude/worktrees/` and ' +
                     '`.claude/settings.local.json` in your global gitignore, and - ' +
                     'only on a machine where Claude Code resolves to npm''s claude.cmd wrapper - the ' +
                     'real claude.exe put first on your user PATH.')

        $readme = Get-DocText (Join-Path $script:Root 'README.md')
        Assert-Phrase -Text $readme -Where 'the README Layout block' `
            -Phrase ('writes at most four things outside this repository: KINGSHAND_HOME, ' +
                     'LAVISH_AXI_PORT, two lines in your global gitignore, and claude.exe ahead of ' +
                     'npm''s wrapper on PATH when your machine only has the wrapper')
        $readme.Contains('writes nothing outside this repository except KINGSHAND_HOME') |
            Should -BeFalse -Because 'the installer writes more than that, and the README must not deny it'
        $readme.Contains('writes exactly three things outside this repository') |
            Should -BeFalse -Because 'the count moved to four and the README must not still say three'
    }

    It 'the setup skill tells the user about the writes before they happen' {
        $setup = Get-DocText $script:SetupMd
        Assert-Phrase -Text $setup -Where 'the setup skill' `
            -Phrase ('Say too that it adds two lines, `.claude/worktrees/` and ' +
                     '`.claude/settings.local.json`, to their global gitignore, because workers ' +
                     'run inside their own repositories')
        Assert-Phrase -Text $setup -Where 'the setup skill' `
            -Phrase ('And say, only when it actually happens, that it put `claude.exe` ahead of ' +
                     'npm''s `claude.cmd` on their PATH')
    }
}


# ---------------------------------------------------------------------------------------------
# Leftover vocabulary from the tool this was rebuilt from.
#
# "crew" reached a user through a rendered review surface - "nothing can be dispatched into a
# project the crew does not know about". Kingshand's words are King, Hand and the King's men; crew
# belongs to the predecessor and to nothing here. Prose drifts, and the only thing that catches it
# is a test that reads the prose.
#
# The identifiers are exempt on purpose: crew.json, Crew.psm1 and Get-CrewStatus.ps1 are code, and
# CLAUDE.md's translation table already forbids naming a script at the user. Renaming them is a
# separate decision with a large blast radius, and it is not what leaked.
# ---------------------------------------------------------------------------------------------
Describe 'no predecessor vocabulary survives in prose the user can see' {

    It 'no skill, CLAUDE.md or README says crew outside a code identifier' -ForEach @(
        @{ Area = 'CLAUDE.md' }
        @{ Area = 'README.md' }
        @{ Area = '.claude\skills' }
    ) {
        $root = Split-Path $PSScriptRoot -Parent
        $files = if ($Area -like '*skills*') {
            @(Get-ChildItem (Join-Path $root $Area) -Recurse -Filter 'SKILL.md' -File)
        } else {
            @(Get-Item (Join-Path $root $Area))
        }

        $offences = foreach ($file in $files) {
            $n = 0
            foreach ($line in (Get-Content -LiteralPath $file.FullName)) {
                $n++
                # Strip the identifiers first, then look for the bare word.
                $stripped = $line -replace 'crew\.json|Crew\.psm1|Get-CrewStatus(\.ps1)?|Test-CrewPrereqs(\.ps1)?|(New|Add|Set|Get|Save|Import)-Crew\w*', ''
                if ($stripped -match '(?i)\bcrew\b') { "$($file.Name):${n}: $($line.Trim())" }
            }
        }

        @($offences) | Should -BeNullOrEmpty -Because 'the words are King, Hand and the King''s men - crew is the predecessor''s'
    }
}


# ---------------------------------------------------------------------------------------------
# CI is established before a worker is promised a wait for it.
#
# A review-gate run on this repository sat on its `ci` step for over an hour waiting for checks that
# could never arrive, and was found only because the King asked. The gate cannot tell "checks have
# not started yet" from "checks will never exist", so the question has to be settled before the
# dispatch - which is the last moment it costs nothing.
# ---------------------------------------------------------------------------------------------
Describe 'the review gate is never promised a check that cannot come' {
    BeforeAll { $script:Step1b = Get-MusterStep 'Step 1b' }

    It 'preflights CI in the step that dispatches, as runnable text' {
        $fences = @(Get-CodeFence $script:MusterMd | Where-Object { $_.Contains('Get-RepoCiStatus') })
        $fences.Count | Should -BeGreaterOrEqual 1 -Because 'a check nobody runs is worthless'
        $fences[0].Contains('Ci.psm1') | Should -BeTrue -Because 'the module is imported where it is used'
        $fences[0].Contains('briefLine') |
            Should -BeTrue -Because 'the answer has to reach the brief, which is the only thing a worker reads'
    }

    It 'names the failure it prevents, so nobody deletes it as a formality' {
        Assert-Phrase -Text $script:Step1b -Where 'muster Step 1b' `
            -Phrase ('it cannot tell "checks have not started yet" from "checks will never exist" - ' +
                     'so on a repository with no CI it waits forever')
    }

    It 'routes all three answers, and keeps unknown from becoming an answer' {
        Assert-Phrase -Text $script:Step1b -Where 'muster Step 1b' `
            -Phrase ('**Never substitute your own reading for the three answers, and never treat ' +
                     '`unknown` as `no-ci` when you report it.**')
        Assert-Phrase -Text $script:Step1b -Where 'muster Step 1b' `
            -Phrase 'a failed lookup stays visibly a failed lookup'
    }

    It 'tells the user at dispatch time rather than an hour later' {
        Assert-Phrase -Text $script:Step1b -Where 'muster Step 1b' `
            -Phrase '**say so in one plain line when you tell the user what you are dispatching**'
        Assert-Phrase -Text $script:Step1b -Where 'muster Step 1b' `
            -Phrase '**Say which, in one line, at dispatch time.**'
    }

    # The King's standing instruction: the absence of CI here is deliberate, and this task makes it
    # safe rather than removing it.
    It 'never offers to add CI to a repository that has none' {
        Assert-Phrase -Text $script:Step1b -Where 'muster Step 1b' `
            -Phrase ('Do not offer to add CI to the repository: an absence is a decision somebody ' +
                     'made, and this step makes it safe rather than reversing it.')
    }

    It 'carries the answer into the brief rather than leaving it to be retyped' {
        Assert-Phrase -Text $script:Step1b -Where 'muster Step 1b' `
            -Phrase ('A preflight whose answer never reaches the brief changes nothing at all, ' +
                     'because the worker reads its brief and nothing else.')
    }

    # The two `no-mistakes` variants differ in one line, and the difference is the whole preflight.
    It 'has one no-mistakes Done-means block per answer, keyed on the preflight' {
        $text = Get-DocText $script:MusterMd
        Assert-Phrase -Text $text -Where 'muster Step 2' `
            -Phrase '`no-mistakes`, where Step 1b answered `has-ci`:'
        Assert-Phrase -Text $text -Where 'muster Step 2' `
            -Phrase '`no-mistakes`, where Step 1b answered `no-ci` or `unknown`.'
        Assert-Phrase -Text $text -Where 'muster Step 2' `
            -Phrase ('**Do not decide between the two blocks yourself** - a repository with no ' +
                     'workflow file may still get checks from outside it')
    }

    # The line is shared by `no-ci` and `unknown`, so it says what both support and no more. An
    # `unknown` lookup never established that nothing reports here, and a worker told it had would
    # report a repository as CI-less on the strength of an expired token.
    It 'the no-CI variant ends the wait instead of leaving it open' {
        $blocks = @(Get-CodeFence $script:MusterMd |
            Where-Object { $_.Contains('Checks may not report on this repository at all') })
        $blocks.Count | Should -Be 1 -Because 'the terminating line is stated once, in its own Done-means block'
        $blocks[0].Contains('waiting more than fifteen minutes') |
            Should -BeTrue -Because 'an open-ended wait is exactly the failure this removes'
        $blocks[0].Contains('Do not sit on it.') | Should -BeTrue
        $blocks[0].Contains('Do not merge it.') | Should -BeTrue
    }

    It 'CLAUDE.md lists the module that answers the question' {
        Assert-Phrase -Text (Get-DocText $script:HandMd) -Where 'the CLAUDE.md Tooling table' `
            -Phrase ('| `bin\Ci.psm1` | whether a repository has any CI that could report a check, ' +
                     'before a task is promised a wait for one |')
    }
}

Describe 'rally owns a stalled worker, and the wait only reports one' {
    # A stalled worker is alive, `working` by every state word herdr has, and getting nowhere. It is
    # a different fact from every liveness signal in this playbook, so it needs its own entry - and
    # the response stays human, because a wrong automatic action on a stalled worker is worse than a
    # late human one.
    BeforeAll { $script:StuckText = Get-DocText $script:StuckMd }

    It 'names the situation in the description, which is its only trigger' {
        $fm = Get-Frontmatter $script:StuckMd
        $fm['description'].Contains('one reported stalled because nothing on its screen has moved') |
            Should -BeTrue -Because 'a reference skill is reached by recognising the situation, not by name'
    }

    It 'says what a stall is and why no liveness check shows it' {
        Assert-Phrase -Text $script:StuckText -Where 'rally' `
            -Phrase ('the worker is running, its state reads `working`, and none of the liveness ' +
                     'checks above will show anything wrong with it')
        Assert-Phrase -Text $script:StuckText -Where 'rally' `
            -Phrase '**A stall is a report, never a trigger for an automatic action.**'
    }

    It 'refuses to read an unreadable screen as a stall' {
        Assert-Phrase -Text $script:StuckText -Where 'rally' `
            -Phrase '**A `signalReadable` of `$false` is not a stall.**'
        Assert-Phrase -Text $script:StuckText -Where 'rally' `
            -Phrase 'You do not know that worker''s state rather than knowing it is stuck'
    }

    It 'lists the three things a stall usually turns out to be' {
        Assert-Phrase -Text $script:StuckText -Where 'rally' `
            -Phrase '**Waiting for something that cannot arrive.**'
        Assert-Phrase -Text $script:StuckText -Where 'rally' `
            -Phrase '**A prompt the screen guard did not match.**'
        Assert-Phrase -Text $script:StuckText -Where 'rally' `
            -Phrase '**Genuinely slow work.**'
    }
}

Describe 'the stall-detection record states what must not be undone' {
    # The design note is the only place the rejected alternatives live: a future editor who deletes
    # the screen normalisation or widens it to strip digits would be reintroducing a failure this
    # already had, and the record is what tells them so.
    BeforeAll { $script:StallDoc = Get-DocText (Join-Path $script:Root 'docs\2026-09-01-stall-detection.md') }

    It 'says why the screen was chosen over the pipeline and the git log' {
        Assert-Phrase -Text $script:StallDoc -Where 'the stall record' `
            -Phrase ('The screen won because the Hand waits on investigations, audits and plain ' +
                     'edits as well as pipeline runs')
        Assert-Phrase -Text $script:StallDoc -Where 'the stall record' `
            -Phrase 'Not knowing about runs at all cannot get the run id wrong.'
    }

    It 'pins the normalisation from both directions' {
        Assert-Phrase -Text $script:StallDoc -Where 'the stall record' `
            -Phrase ('Delete it and every frozen worker reports as progressing. Widen it to strip ' +
                     'digits wholesale and every counter-printing job reports as stalled.')
    }

    It 'keeps the threshold and its floor' {
        Assert-Phrase -Text $script:StallDoc -Where 'the stall record' `
            -Phrase 'Twenty minutes is the default on'
        Assert-Phrase -Text $script:StallDoc -Where 'the stall record' `
            -Phrase 'Under about fifteen minutes, slow steps start reporting as stalls'
    }

    It 'keeps the two-signal CI rule and the refusal to guess' {
        Assert-Phrase -Text $script:StallDoc -Where 'the stall record' `
            -Phrase '**Two signals, and the second one is why this is not a directory test.**'
        Assert-Phrase -Text $script:StallDoc -Where 'the stall record' `
            -Phrase '**`unknown` is never rewritten into an answer.**'
    }

    It 'says the settled wake keeps its behaviour' {
        Assert-Phrase -Text $script:StallDoc -Where 'the stall record' `
            -Phrase ('**`Wait-HerdrAgentSettled` keeps its behaviour.** The progress wait was added ' +
                     'beside it, not over it.')
    }
}

# The largest measured blocks of review waste in this system's own history were not defects the
# review gate should have caught earlier - they were mechanisms chosen before anybody listed the
# cases they had to hold over. Six consecutive rounds on a path parser, ten on a hand-rolled
# Markdown renderer, every finding in both correct. Two rounds in `emgee-theme-toggle` on lifecycle
# re-entry, where the same worker got the origin question right first time because its brief named
# that dimension and nothing named the other one. The rules below are the front end of that: they
# fire before a line is written, and they are pinned here because they live in prose and nothing
# else would notice them going.
Describe 'a mechanism is chosen against the case space it has to cover' {
    BeforeAll {
        # The brief template is the one fence carrying both the Goal and the Done-means headings,
        # identified the same way the Read-first slot test identifies it.
        $script:Template = @(Get-CodeFence $script:MusterMd |
            Where-Object { $_.Contains('## Goal') -and $_.Contains('## Done means') })
        $script:CaseSpace = if ($script:Template.Count -eq 1) {
            ConvertTo-NormalisedText $script:Template[0]
        } else { '' }
        $script:MusterAll = Get-DocText $script:MusterMd
        # The Done-means blocks, so the section can be shown NOT to have been folded into them.
        $script:DoneFences = @(Get-CodeFence $script:MusterMd |
            Where-Object { $_.Contains("Implemented and committed on this worktree's branch.") })
    }

    It 'the brief template carries a Case space section, after the requirements and before Done means' {
        $script:Template.Count | Should -Be 1 -Because 'the brief template is one fence'
        $t = $script:Template[0]
        $t.Contains('## Case space') |
            Should -BeTrue -Because 'a discipline with no slot in the template reaches no brief'
        $t.IndexOf('## Case space') | Should -BeGreaterThan $t.IndexOf('## Requirements') `
            -Because 'the cases belong to the requirements, so they come after them'
        $t.IndexOf('## Case space') | Should -BeLessThan $t.IndexOf('## Done means') `
            -Because 'it is worked before the work is judged, not as part of judging it'
    }

    # A discipline that demands enumeration everywhere is a discipline skipped everywhere. The
    # limiter is what keeps it affordable, and it is the first thing an editor would cut.
    It 'the section applies only to a choice that would be expensive to undo' {
        Assert-Phrase -Text $script:CaseSpace -Where 'the Case space section' `
            -Phrase 'whose choice would be expensive to undo'
        Assert-Phrase -Text $script:CaseSpace -Where 'the Case space section' `
            -Phrase 'A choice a later commit could reverse in minutes needs none of this.'
    }

    # The list is closed and each line is one measured finding. A dimension deleted here is a
    # dimension that has already cost review rounds once.
    It 'names the dimension <dimension>' -ForEach @(
        @{ dimension = '**Origins and hosts**' }
        @{ dimension = '**Callers, and the arguments they actually pass**' }
        @{ dimension = '**Re-entry**' }
        @{ dimension = '**Environments and versions**' }
        @{ dimension = '**The live installation''s own state**' }
        @{ dimension = '**How its inputs fail**' }
    ) {
        Assert-Phrase -Text $script:CaseSpace -Where 'the Case space section' -Phrase $dimension
    }

    # Each dimension's tail is the finding it came from, and the tail is what makes it checkable.
    # A bare dimension word is a heading; these clauses are the rule.
    It 'keeps the finding behind a dimension: <clause>' -ForEach @(
        # A default TimeoutMs of four minutes against a StallMinutes of twenty made the stall
        # branch unreachable for every caller that did not override it.
        @{ clause = 'including a default nobody overrides' }
        # A page restored from the back/forward cache kept the theme it was frozen with.
        @{ clause = 'after reading its state once' }
        # An unprefixed `mask-image` with a guarded sibling 900 lines above it, and a
        # `MediaQueryList.addEventListener` that throws on Safari 13.1.
        @{ clause = 'matching any guarded precedent already in the' }
        # The index gate built to its brief's literal words against an index that does not exist.
        @{ clause = 'check what is actually there rather than what this brief says is there' }
        # A fail-closed path that fingerprinted herdr's own error text as though it were a screen.
        @{ clause = 'or an error where a value was expected' }
    ) {
        Assert-Phrase -Text $script:CaseSpace -Where 'the Case space section' -Phrase $clause
    }

    # This is the line that stops the section becoming a reason to stop or a silent omission. A
    # worker cannot ask, so an uncovered case has exactly one destination: written down as a gap.
    It 'sends an uncovered case to report.md as a stated gap rather than anywhere else' {
        Assert-Phrase -Text $script:CaseSpace -Where 'the Case space section' `
            -Phrase 'record in `report.md` which mechanism covers all of it and what the rejected ones fail on'
        Assert-Phrase -Text $script:CaseSpace -Where 'the Case space section' `
            -Phrase 'Mark every line `covered`, `a stated gap`, or `not applicable`'
    }

    # The biggest block of waste in the evidence, and the only line here that pays for itself on
    # its own. Both instances were correct at every round; what was wrong was that the mechanism
    # had no last round. Deleting this sentence is what lets the next parser be written.
    It 'states the open-ended-input decision as a decision, not as another case to enumerate' {
        Assert-Phrase -Text $script:CaseSpace -Where 'the Case space section' `
            -Phrase ('Where the list of cases has no end - anything hand-written that parses, ' +
                     'renders or normalises an open-ended text format - that is the answer rather ' +
                     'than a case to enumerate: take an existing library, or change the requirement ' +
                     'so the input is not open-ended.')
    }

    # If the list can be tailored per dispatch, the Hand supplies the dimensions it can already see
    # and the one nobody thought of stays missing - the same failure one level up.
    It 'Step 2 forbids tailoring the list, and keeps the instance that shows why' {
        Assert-Phrase -Text $script:MusterAll -Where 'muster Step 2' `
            -Phrase '**Paste the `## Case space` section unchanged, and do not tailor its list.**'
        Assert-Phrase -Text $script:MusterAll -Where 'muster Step 2' `
            -Phrase 'the script reads its state once and I had not asked what happens when the page comes back'
        Assert-Phrase -Text $script:MusterAll -Where 'muster Step 2' `
            -Phrase 'a dimension you pick out for the worker is a dimension you could already see'
    }

    It 'Step 2 keeps the sixteen rounds behind the open-ended-input line' {
        Assert-Phrase -Text $script:MusterAll -Where 'muster Step 2' `
            -Phrase 'cost 16 review rounds between them, every finding correct in both'
        Assert-Phrase -Text $script:MusterAll -Where 'muster Step 2' `
            -Phrase 'there is no round after which the parser is finished'
        Assert-Phrase -Text $script:MusterAll -Where 'muster Step 2' `
            -Phrase 'enumerating is what ends both, by showing the list has no end'
    }

    # The index gate is the one instance that is not a thinking failure at all: the brief asserted
    # a fact about the live installation and the fact was wrong. Hard rule 1 splits the check in
    # two, and the split is the rule - without it this reads as licence for the Hand to go looking
    # inside a project itself.
    It 'Step 2 makes a requirement that names a mechanism carry the fact it rests on' {
        Assert-Phrase -Text $script:MusterAll -Where 'muster Step 2' `
            -Phrase '**A requirement that names a mechanism carries the fact it rests on.**'
        Assert-Phrase -Text $script:MusterAll -Where 'muster Step 2' `
            -Phrase 'would have refused nothing, ever'
        Assert-Phrase -Text $script:MusterAll -Where 'muster Step 2' `
            -Phrase 'hard rule 1 says a worker checks it, so write the requirement as a premise to verify before building to it'
    }

    It 'the section is dropped only where the dispatch writes no mechanism at all' {
        Assert-Phrase -Text $script:MusterAll -Where 'muster Step 2' `
            -Phrase ('Drop the section only for a dispatch that writes no mechanism at all - an ' +
                     'investigation, an audit, a documentation pass')
    }

    # Stated once, in the template, and not multiplied into the four mode blocks. Those blocks are
    # near-copies by design and every line added to them is added four times; the count of exactly
    # four is pinned elsewhere and this change deliberately leaves them alone.
    It 'lives in the template rather than being copied into the four Done-means blocks' {
        $script:DoneFences.Count | Should -Be 4 -Because 'the four mode blocks are untouched by this'
        foreach ($fence in $script:DoneFences) {
            $fence.Contains('Case space') |
                Should -BeFalse -Because 'one owner: the template states it once'
        }
    }
}
