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
    $script:CrewMd    = Join-Path $script:Root 'skills\crew\SKILL.md'
    $script:ImportMd  = Join-Path $script:Root 'skills\import-project\SKILL.md'
    $script:BearingsMd = Join-Path $script:Root 'skills\bearings\SKILL.md'
    $script:DiagnosticMd = Join-Path $script:Root 'skills\diagnostic-reasoning\SKILL.md'
    $script:AskUserMd    = Join-Path $script:Root 'skills\ask-user-authority\SKILL.md'
    $script:GuidelinesMd = Join-Path $script:Root 'skills\kingshand-guidelines\SKILL.md'
    $script:AhoyMd       = Join-Path $script:Root 'skills\ahoy\SKILL.md'
    $script:StuckMd      = Join-Path $script:Root 'skills\stuck-worker-recovery\SKILL.md'
    $script:StowMd       = Join-Path $script:Root 'skills\stow\SKILL.md'
    $script:HoldMd       = Join-Path $script:Root 'skills\decision-hold-lifecycle\SKILL.md'

    # The one skill that ships inside the repo rather than through a junction, and the script it
    # runs. Both are read as text here and neither is ever executed: a test that ran the installer
    # would install software onto whatever machine the suite happens to be on.
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

    # The crew skill split on its own step headings, so a gate is asserted at its own site
    # rather than anywhere in the file.
    function Get-CrewStep {
        param([Parameter(Mandatory)][string]$Heading)
        $parts = (Get-Content -Path $script:CrewMd -Raw) -split '(?m)^## '
        $hit   = @($parts | Where-Object { $_.StartsWith($Heading) })
        if ($hit.Count -ne 1) { throw "Expected exactly one '## $Heading' section, found $($hit.Count)." }
        ConvertTo-NormalisedText $hit[0]
    }

    # CLAUDE.md loads on every turn, so a rule that survives only as a stray sentence elsewhere in
    # the file is not the rule any more. The four ported sections are asserted at their own
    # headings, the same way a crew gate is asserted at its own step.
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

    It 'the crew skill states the comparison where the project is resolved' {
        Assert-Phrase -Text (Get-CrewStep 'Step 1 - Intake') -Where 'crew Step 1' `
            -Phrase "Always test it as ```$proj.yolo -eq 'on'``"
    }

    It 'the dispatch gate decides on -eq ''on''' {
        $step = Get-CrewStep 'Step 3 - Gate one'
        Assert-Phrase -Text $step -Where 'the dispatch gate' `
            -Phrase "The test is ```$proj.yolo -eq 'on'``, and nothing else"
        Assert-Phrase -Text $step -Where 'the dispatch gate' `
            -Phrase "When ```$proj.yolo -eq 'off'``, dispatch nothing until they approve"
    }

    It 'the landing gate decides on -eq ''on''' {
        $step = Get-CrewStep 'Step 7 - Gate two'
        Assert-Phrase -Text $step -Where 'the landing gate' `
            -Phrase "The test is ```$proj.yolo -eq 'on'``, and nothing else"
        Assert-Phrase -Text $step -Where 'the landing gate' `
            -Phrase "When ```$proj.yolo -eq 'off'``, render the diff"
        Assert-Phrase -Text $step -Where 'the landing gate' `
            -Phrase "When ```$proj.yolo -eq 'on'``, the waiting is skipped"
    }

    It 'no bare truthiness test appears in a runnable code block in <file>' -ForEach @(
        # minFences guards each case against passing vacuously if fence parsing ever breaks.
        # CLAUDE.md carries no code blocks at all, so it is covered by the next test instead.
        @{ file = 'CLAUDE.md';                      minFences = 0 }
        @{ file = 'skills\crew\SKILL.md';           minFences = 20 }
        @{ file = 'skills\import-project\SKILL.md'; minFences = 5 }
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
        $text = Get-DocText $script:CrewMd
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
    It 'the crew skill names all three push-capable modes where a worker may push' {
        Assert-Phrase -Text (Get-CrewStep 'Step 8 - Land') -Where 'crew Step 8' `
            -Phrase ("push-capable - ``direct-PR``, ``no-mistakes``, or a " +
                     "``no-mistakes-prod-only`` project resolved to one of those")
    }

    It 'close-out is restricted to the same three modes' {
        Assert-Phrase -Text (Get-CrewStep 'Step 8a') -Where 'crew Step 8a' `
            -Phrase ("Only for ``direct-PR`` and ``no-mistakes`` (including " +
                     "``no-mistakes-prod-only`` resolved to either)")
    }

    It 'the import skill requires an origin remote for a push-capable mode' {
        Assert-Phrase -Text (Get-DocText $script:ImportMd) -Where 'the import skill' `
            -Phrase 'a push-capable mode requiring an `origin` remote'
    }

    It 'local-only is never counted as push-capable' {
        Assert-Phrase -Text (Get-CrewStep 'Step 8 - Land') -Where 'crew Step 8' `
            -Phrase ("Never for ``local-only``, whose brief forbids it outright, and never " +
                     "for a project that is not registered at all")
    }
}

Describe 'the local-only push prohibition survives' {
    It 'the local-only Done-means block forbids push, PR and merge' {
        $fences = @(Get-CodeFence $script:CrewMd | Where-Object { $_.Contains('Stop on the branch') })
        $fences.Count | Should -Be 1
        $fences[0].Contains('Stop on the branch. Do not push. Do not open a PR. Do not merge.') |
            Should -BeTrue -Because 'the local-only Done-means block carries the whole prohibition'
    }

    It 'the skill forbids removing that prohibition' {
        Assert-Phrase -Text (Get-DocText $script:CrewMd) -Where 'the crew skill' `
            -Phrase 'never remove the push prohibition from the `local-only` variant'
    }

    It 'an unregistered project is never pushed' {
        Assert-Phrase -Text (Get-CrewStep 'Step 7 - Gate two') -Where 'the landing gate floors' `
            -Phrase 'Never push a project that is not registered with a push-capable posture'
        Assert-Phrase -Text (Get-DocText $script:HandMd) -Where 'CLAUDE.md rule 2' `
            -Phrase 'never pushes a project that is not registered with a push-capable posture'
    }
}

Describe 'crew never merges on the forge' {
    It 'the landing gate lists it as a floor no posture relaxes' {
        Assert-Phrase -Text (Get-CrewStep 'Step 7 - Gate two') -Where 'the landing gate floors' `
            -Phrase ('Never merge on the forge. `direct-PR` and `no-mistakes` work ends ' +
                     'at a pull request the user merges')
    }

    It 'CLAUDE.md rule 2 states it' {
        Assert-Phrase -Text (Get-DocText $script:HandMd) -Where 'CLAUDE.md rule 2' `
            -Phrase 'Crew never merges on the forge'
    }

    It 'the local merge step disclaims the push-capable modes' {
        Assert-Phrase -Text (Get-CrewStep 'Step 8 - Land') -Where 'crew Step 8' `
            -Phrase ('`direct-PR` and `no-mistakes` work ends at a pull request that the ' +
                     'user merges on the forge; crew never merges there')
    }

    It 'close-out refuses to make the merge true itself' {
        Assert-Phrase -Text (Get-CrewStep 'Step 8a') -Where 'crew Step 8a' `
            -Phrase 'never merge it to make it true'
    }
}

Describe 'work that is neither landed nor pushed is never torn down' {
    It 'the teardown step states the rule' {
        Assert-Phrase -Text (Get-CrewStep 'Step 8b') -Where 'crew Step 8b' `
            -Phrase 'Work that is neither landed nor pushed is never torn down'
    }

    It 'and names what removing the worktree would cost' {
        Assert-Phrase -Text (Get-CrewStep 'Step 8b') -Where 'crew Step 8b' `
            -Phrase 'the worktree is the only copy of the work and removing it destroys it'
    }
}

Describe 'the anti-attribution rule is in every Done-means variant' {
    BeforeAll {
        # The Done-means blocks are exactly the fences that open with the commit line.
        $script:DoneBlocks = @(Get-CodeFence $script:CrewMd |
            Where-Object { $_.Contains("Implemented and committed on this worktree's branch.") })
    }

    It 'there are exactly three Done-means blocks' {
        $script:DoneBlocks.Count | Should -Be 3
    }

    It 'each one forbids mentioning Claude, AI or an assistant' {
        foreach ($block in $script:DoneBlocks) {
            $block.Contains('Never mention Claude, AI, or an assistant in any commit message') |
                Should -BeTrue -Because 'every Done-means variant carries the rule 3 prohibition'
        }
    }

    It 'the two push-capable variants extend it to the PR title and body' {
        $pr = @($script:DoneBlocks | Where-Object { $_.Contains('PR title, PR body') })
        $pr.Count | Should -Be 2
    }

    It 'CLAUDE.md rule 3 covers anything reaching a remote or Azure DevOps' {
        Assert-Phrase -Text (Get-DocText $script:HandMd) -Where 'CLAUDE.md rule 3' `
            -Phrase ('Never mention Claude, AI, an assistant, or a model** in anything that ' +
                     'reaches Azure DevOps or a git remote: ticket text, commit messages, PR bodies')
    }

    It 'the landing gate scans the commits for attribution before showing anything' {
        Assert-Phrase -Text (Get-CrewStep 'Step 7 - Gate two') -Where 'the landing gate' `
            -Phrase 'Any hit is a rule 3 violation - report it and do not land until it is fixed'
    }
}

Describe 'the worker writes findings to a file that outlives the session' {
    BeforeAll {
        # Same identification as the anti-attribution block: the Done-means blocks are exactly
        # the fences opening with the commit line.
        $script:ReportBlocks = @(Get-CodeFence $script:CrewMd |
            Where-Object { $_.Contains("Implemented and committed on this worktree's branch.") })
    }

    It 'each of the three Done-means blocks requires report.md at an exact path' {
        $script:ReportBlocks.Count | Should -Be 3
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
        Assert-Phrase -Text (Get-CrewStep 'Step 6 - Completion') -Where 'crew Step 6' `
            -Phrase ('Read `$env:KINGSHAND_HOME\data\<id>\report.md` first. It is the primary ' +
                     'record of what the worker found')
    }

    It 'Step 6 keeps claude logs only as the fallback, and reports a missing file' {
        $step = Get-CrewStep 'Step 6 - Completion'
        Assert-Phrase -Text $step -Where 'crew Step 6' `
            -Phrase 'A missing report is itself worth reporting'
        Assert-Phrase -Text $step -Where 'crew Step 6' `
            -Phrase 'the fallback when `report.md` is missing'
    }

    It 'Step 8b states the report survives teardown and is never deleted' {
        Assert-Phrase -Text (Get-CrewStep 'Step 8b') -Where 'crew Step 8b' `
            -Phrase '`report.md` survives teardown, and must never be deleted as part of cleanup'
    }

    It 'CLAUDE.md owns it beside the brief' {
        Assert-Phrase -Text (Get-DocText $script:HandMd) -Where 'CLAUDE.md What you own' `
            -Phrase '`data\<id>\report.md` - the worker''s durable findings, written by the worker'
    }
}

Describe 'a background worker never opens an interactive prompt' {
    # Worker 7372d875 called AskUserQuestion, drew a menu, and waited over an hour for a keypress
    # nobody could give it. There is no `claude send`, so the only exit was to kill the dispatch.
    # The prohibition lives in the brief itself, which is the only text the worker ever reads -
    # a rule anywhere else in this skill would not reach it. Normalised so the sentence stays
    # found when the bullet is re-wrapped.
    BeforeAll {
        $script:PromptBlocks = @(Get-CodeFence $script:CrewMd |
            Where-Object { $_.Contains("Implemented and committed on this worktree's branch.") } |
            ForEach-Object { ConvertTo-NormalisedText $_ })
    }

    It 'the prohibition is in all three Done-means blocks, not just one' {
        $script:PromptBlocks.Count | Should -Be 3
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
        # Asserted against the whole document rather than through Get-CrewStep: the brief template
        # in Step 2 contains its own `## Goal`, `## Scope` and `## Done means` headings, so the
        # step splitter cuts Step 2 off at the first of them.
        $step = Get-DocText $script:CrewMd
        Assert-Phrase -Text $step -Where 'crew Step 2' `
            -Phrase 'The no-interactive-prompts rule is absolute, and it is there because a worker hung on it for hours.'
        Assert-Phrase -Text $step -Where 'crew Step 2' `
            -Phrase 'workers never address the user'
        Assert-Phrase -Text $step -Where 'crew Step 2' `
            -Phrase 'do not soften this back into advice'
    }
}

Describe 'the Hand arms a poll so a finished worker actually wakes it' {
    # Three workers reached stage `ready` and wrote their reports after the Hand said it would
    # report when they were done. Nothing in the skill woke it, so nothing did, and the user found
    # out by asking hours later. The promise needed a mechanism behind it.
    BeforeAll { $script:Step4 = Get-CrewStep 'Step 4 - Dispatch' }

    It 'arms the poll at dispatch, before anything is said to the user' {
        Assert-Phrase -Text $script:Step4 -Where 'crew Step 4' `
            -Phrase 'Then arm a poll for that worker, before you say anything to the user.'
    }

    It 'requires a harness-tracked background job rather than a detached one' {
        Assert-Phrase -Text $script:Step4 -Where 'crew Step 4' `
            -Phrase 'Run it as a **harness-tracked background job**, never with `&` and never as a detached process.'
        Assert-Phrase -Text $script:Step4 -Where 'crew Step 4' `
            -Phrase 'an untracked process wakes nothing'
    }

    It 'arms one poll per dispatched worker' {
        Assert-Phrase -Text $script:Step4 -Where 'crew Step 4' `
            -Phrase 'Arm **one poll per dispatched worker**.'
    }

    It 'treats blocked as a wake reason rather than a working state' {
        Assert-Phrase -Text $script:Step4 -Where 'crew Step 4' `
            -Phrase '`blocked` is a wake reason, not a working state.'
        Assert-Phrase -Text $script:Step4 -Where 'crew Step 4' `
            -Phrase 'A worker that goes `blocked` needs the user and must surface immediately'
    }

    It 're-arms a timed-out poll rather than assuming the worker is fine' {
        Assert-Phrase -Text $script:Step4 -Where 'crew Step 4' `
            -Phrase 'If the poll times out without the worker finishing, re-arm it.'
    }

    It 'never promises to report back without arming it first' {
        Assert-Phrase -Text $script:Step4 -Where 'crew Step 4' `
            -Phrase '**Never promise to report back without arming this first.**'
        Assert-Phrase -Text $script:Step4 -Where 'crew Step 4' `
            -Phrase 'tell the user plainly that they will need to ask'
    }

    It 'the poll itself wakes on done, blocked and failed' {
        $fences = @(Get-CodeFence $script:CrewMd | Where-Object { $_.Contains('WAKE <worker id>') })
        $fences.Count | Should -Be 1 -Because 'the poll is stated once, as runnable text'
        $fences[0].Contains("@('done','blocked','failed')") |
            Should -BeTrue -Because 'a blocked worker must break the loop, not be waited out'
    }

    It 'Step 5 keeps quiet from meaning unmonitored' {
        Assert-Phrase -Text (Get-CrewStep 'Step 5 - Quiet, and status on request') -Where 'crew Step 5' `
            -Phrase '**Quiet means no narration, not no monitoring.**'
    }
}

Describe 'a blocked worker is never reported as healthy' {
    # bearings put a live worker at stage `dispatched` into Underway - "live work progressing on
    # its own" - while its agentState was `blocked` and it had been sitting on a menu for an hour.
    # The one tool that should have surfaced the hang called it fine.
    BeforeAll { $script:BearingsText = Get-DocText $script:BearingsMd }

    It 'routes a blocked worker to King''s Call whatever its stage' {
        Assert-Phrase -Text $script:BearingsText -Where 'the bearings bucket mapping' `
            -Phrase ('A worker whose `agentState` is `blocked`, whatever its stage. It cannot ' +
                     'proceed on its own, so it is never Underway.')
    }

    # Both shapes report `blocked`, and they need opposite advice. Observed side by side on
    # 2026-08-28: a worker hung on an interactive menu read `blocked`/`waiting`, while one that
    # stopped correctly and wrote its question to report.md read `blocked`/`idle`. Telling the
    # user to attach the second one sends them to a terminal to answer a question that is already
    # written down, and reads a correct stop as a failure.
    It 'splits the two blocked shapes on agentStatus' {
        Assert-Phrase -Text $script:BearingsText -Where 'the bearings bucket mapping' `
            -Phrase '**`agentStatus` decides what you tell the user, and the two cases need opposite advice.**'
    }

    It 'sends a waiting worker to claude attach, naming it as hung' {
        Assert-Phrase -Text $script:BearingsText -Where 'the bearings blocked-waiting case' `
            -Phrase ('`blocked` with `agentStatus` of `waiting` means it is sitting on an ' +
                     'interactive prompt that nobody can answer')
        Assert-Phrase -Text $script:BearingsText -Where 'the bearings blocked-waiting case' `
            -Phrase 'point at `claude attach <id>` as the only way in'
    }

    It 'sends an idle worker to its report, never to claude attach' {
        Assert-Phrase -Text $script:BearingsText -Where 'the bearings blocked-idle case' `
            -Phrase ('`blocked` with `agentStatus` of `idle` means it stopped by design')
        Assert-Phrase -Text $script:BearingsText -Where 'the bearings blocked-idle case' `
            -Phrase 'Point at the report, not at `claude attach`'
        Assert-Phrase -Text $script:BearingsText -Where 'the bearings blocked-idle case' `
            -Phrase ('Never give the `claude attach` line for an `idle` worker, and never ' +
                     'describe a `waiting` one as having finished.')
    }

    It 'excludes it from Underway at the Underway bucket too' {
        Assert-Phrase -Text $script:BearingsText -Where 'the bearings Underway bucket' `
            -Phrase ('A live worker at stage `dispatched`, `implementing` or `gating` **whose ' +
                     '`agentState` is not `blocked`**')
        Assert-Phrase -Text $script:BearingsText -Where 'the bearings Underway bucket' `
            -Phrase ('A worker whose `agentState` is `blocked` is never Underway, whatever its ' +
                     'stage says.')
    }

    It 'keeps the existing rule that a dead worker recorded as working also needs the user' {
        Assert-Phrase -Text $script:BearingsText -Where 'the bearings Underway bucket' `
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
        Assert-Phrase -Text (Get-CrewStep 'Step 7 - Gate two') -Where 'the landing gate' `
            -Phrase 'rev-parse --verify --quiet "$base^{commit}"'
    }

    It 'and says empty evidence is never clean evidence' {
        Assert-Phrase -Text (Get-CrewStep 'Step 7 - Gate two') -Where 'the landing gate' `
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

Describe 'the bearings digest is four sections, always all four' {
    # A section that renders only when it has something in it is a delta, and a delta cannot be
    # read as a current snapshot. The empty-state sentence is what makes an empty section an
    # answer rather than an omission, so each one is pinned to its exact wording.
    It 'names all four sections in the chat-response contract' {
        $text = Get-DocText $script:BearingsMd
        foreach ($section in @('**King''s Call**', '**Recently Landed**', '**Underway**', '**Charted Next**')) {
            Assert-Phrase -Text $text -Where 'the bearings skill' -Phrase $section
        }
    }

    It 'carries the exact empty-state sentence for <section>' -ForEach @(
        @{ section = 'King''s Call';  sentence = 'Empty-state: "Nothing needs your action right now."' }
        @{ section = 'Recently Landed'; sentence = 'Empty-state: "No recent completions are in the current baseline."' }
        @{ section = 'Underway';        sentence = 'Empty-state: "Nothing is underway."' }
        @{ section = 'Charted Next';    sentence = 'Empty-state: "Nothing is queued."' }
    ) {
        Assert-Phrase -Text (Get-DocText $script:BearingsMd) -Where "the bearings $section section" -Phrase $sentence
    }

    It 'requires every section to render even when empty' {
        Assert-Phrase -Text (Get-DocText $script:BearingsMd) -Where 'the bearings skill' `
            -Phrase 'Every section ALWAYS renders, even when empty, with its short empty-state sentence.'
    }
}

Describe 'bearings reads the fleet and never acts on it' {
    It 'states that it is operationally read-only in both modes' {
        Assert-Phrase -Text (Get-DocText $script:BearingsMd) -Where 'the bearings skill' `
            -Phrase ('This skill is operationally read-only in both modes. It never dispatches, ' +
                     'steers, lands, merges, tears down, answers a decision, or mutates `state\` ' +
                     'or `data\` other than that single dated report in explicit file mode.')
    }

    It 'leaves any implied action to crew' {
        Assert-Phrase -Text (Get-DocText $script:BearingsMd) -Where 'the bearings skill' `
            -Phrase 'name it in its section and leave the action to `crew`'
    }
}

Describe 'the ported reference skills are loadable and keep their load-bearing rules' {
    # These three are prose procedures with no scripts behind them, so the text IS the mechanism.
    # Each case below pins one sentence that carries the whole point of its section: the rule that
    # a diagnosis does not authorise a change, the rule that the worker does not answer its own
    # finding, and the rule that a prose rule gets a test. Delete any of them and a test fails.

    It '<name> has frontmatter that parses, with a name and a non-empty description' -ForEach @(
        @{ name = 'diagnostic-reasoning' }
        @{ name = 'ask-user-authority' }
        @{ name = 'kingshand-guidelines' }
        @{ name = 'ahoy' }
        @{ name = 'stuck-worker-recovery' }
        @{ name = 'decision-hold-lifecycle' }
    ) {
        $fm = Get-Frontmatter (Join-Path $script:Root "skills\$name\SKILL.md")
        $fm['name']        | Should -Be $name -Because 'the frontmatter name must match the skill directory'
        $fm['version']     | Should -Be '1.0.0'
        $fm['description'] | Should -Not -BeNullOrEmpty -Because 'a skill with no description never gets loaded'
        $fm['description'].Length |
            Should -BeGreaterThan 40 -Because 'the description is the trigger, and it must name the situation'
    }

    It 'diagnostic-reasoning keeps the three-way causal separation' {
        $text = Get-DocText $script:DiagnosticMd
        Assert-Phrase -Text $text -Where 'diagnostic-reasoning' -Phrase 'The **initiating trigger** is'
        Assert-Phrase -Text $text -Where 'diagnostic-reasoning' -Phrase 'The **masking condition** is'
        Assert-Phrase -Text $text -Where 'diagnostic-reasoning' -Phrase 'The **visible symptom** is'
        Assert-Phrase -Text $text -Where 'diagnostic-reasoning' `
            -Phrase 'Do not collapse those facts into one label'
    }

    It 'diagnostic-reasoning says a diagnosis is not authorisation to change code' {
        Assert-Phrase -Text (Get-DocText $script:DiagnosticMd) -Where 'diagnostic-reasoning' `
            -Phrase ('A diagnosis or implementation-ready recommendation is evidence, not ' +
                     'authorization to change code.')
    }

    It 'diagnostic-reasoning turns the reproduction into the regression test' {
        Assert-Phrase -Text (Get-DocText $script:DiagnosticMd) -Where 'diagnostic-reasoning' `
            -Phrase 'the reproduction should become the regression test when a fix is authorized'
    }

    It 'ask-user-authority forbids the worker answering its own finding' {
        Assert-Phrase -Text (Get-DocText $script:AskUserMd) -Where 'ask-user-authority' `
            -Phrase 'The implementation worker never decides or answers its own ask-user finding.'
    }

    It 'ask-user-authority keeps all eight authority steps and all five escalation elements' {
        $raw = Get-Content -Path $script:AskUserMd -Raw
        $steps = ($raw -split '(?m)^## ' | Where-Object { $_.StartsWith('Decide who has authority') })
        @([regex]::Matches($steps, '(?m)^\d+\. ')).Count |
            Should -Be 8 -Because 'the authority procedure is eight steps'
        $esc = ($raw -split '(?m)^## ' | Where-Object { $_.StartsWith('User-facing escalation') })
        @([regex]::Matches($esc, '(?m)^\d+\. ')).Count |
            Should -Be 5 -Because 'an escalation states all five elements'
    }

    It 'ask-user-authority scopes itself to the no-mistakes gate and nothing wider' {
        Assert-Phrase -Text (Get-DocText $script:AskUserMd) -Where 'ask-user-authority' `
            -Phrase ('A project registered `local-only` or `direct-PR` has no review gate, so it ' +
                     'never produces an ask-user finding')
    }

    It 'ask-user-authority tests yolo as a string here too' {
        Assert-Phrase -Text (Get-DocText $script:AskUserMd) -Where 'ask-user-authority' `
            -Phrase "test it as ``-eq 'on'`` and never for bare truthiness"
    }

    It 'kingshand-guidelines requires a test for a new prose rule' {
        $text = Get-DocText $script:GuidelinesMd
        Assert-Phrase -Text $text -Where 'kingshand-guidelines' `
            -Phrase ('A new rule that matters gets an assertion there in the same change that ' +
                     'introduces it.')
        Assert-Phrase -Text $text -Where 'kingshand-guidelines' -Phrase 'tests\Docs.Tests.ps1'
    }

    It 'kingshand-guidelines keeps the one-owner rule intact' {
        Assert-Phrase -Text (Get-DocText $script:GuidelinesMd) -Where 'kingshand-guidelines' `
            -Phrase ('Every contract - a data format, a state machine, a decision procedure - is ' +
                     'stated in full exactly once.')
    }

    It 'kingshand-guidelines carries the anti-attribution rule undiluted' {
        Assert-Phrase -Text (Get-DocText $script:GuidelinesMd) -Where 'kingshand-guidelines' `
            -Phrase ('Never mention Claude, AI, an assistant, or a model in anything that reaches ' +
                     'a git remote or Azure DevOps: ticket text, commit messages, PR bodies.')
    }

    It 'kingshand-guidelines names the checkpoint that must pass' {
        Assert-Phrase -Text (Get-DocText $script:GuidelinesMd) -Where 'kingshand-guidelines' `
            -Phrase 'Invoke-Pester -Path $env:KINGSHAND_HOME\tests'
    }
}

Describe 'ahoy recaps the session and touches nothing else' {
    # ahoy's whole value is what it refuses to do: it reads the visible history and nothing on
    # disk, and it does not let a later unrelated message bury a decision nobody answered. Both
    # of those are one sentence each, so both are pinned.
    It 'treats only an ordinary user-role message as a boundary, and never infers authorship' {
        $text = Get-DocText $script:AhoyMd
        Assert-Phrase -Text $text -Where 'ahoy step 2' `
            -Phrase ('A user boundary is an ordinary user-role message. System, tool, and other ' +
                     'injected operational messages are not user messages.')
        Assert-Phrase -Text $text -Where 'ahoy step 2' `
            -Phrase ('Never infer user authorship merely because a synthetic message appears in ' +
                     'the user-role transcript.')
    }

    It 'keeps an older open decision open across a later unrelated message' {
        Assert-Phrase -Text (Get-DocText $script:AhoyMd) -Where 'ahoy step 5' `
            -Phrase ('A later unrelated user message establishes a recap boundary but does not ' +
                     'close an earlier decision.')
    }

    It 'gathers nothing and persists nothing' {
        $text = Get-DocText $script:AhoyMd
        Assert-Phrase -Text $text -Where 'ahoy step 6' `
            -Phrase 'The normal recap branch is session-history-only.'
        Assert-Phrase -Text $text -Where 'ahoy step 6' `
            -Phrase ('Do not call Bearings, shell commands, fleet snapshots, status readers, ' +
                     'GitHub or browser APIs, tools, or file reads or writes. Create no report, ' +
                     'persist nothing')
    }

    It 'leaves the Bearings contract to Bearings' {
        Assert-Phrase -Text (Get-DocText $script:AhoyMd) -Where 'ahoy step 3' `
            -Phrase ('Bearings alone owns its gathering, artifact, and response contract. Do not ' +
                     'restate that contract or combine a session recap with Bearings output.')
    }

    It 'clears decisions one at a time, ordered by judgement rather than a score' {
        $text = Get-DocText $script:AhoyMd
        Assert-Phrase -Text $text -Where 'ahoy step 8' `
            -Phrase ('Make clear that impact ordering is the Hand''s judgement rather than a ' +
                     'mechanical score.')
        Assert-Phrase -Text $text -Where 'ahoy step 9' `
            -Phrase 'Continue one decision at a time until none remain'
    }
}

Describe 'stuck-worker-recovery states the capability gap and protects unlanded work' {
    # Two sentences in this file stand between a stuck worker and a destroyed worktree: the one
    # saying rm takes the worktree with the session, and the one saying a low context reading is
    # not a reason to relaunch anything. Deleting either must fail here.
    It 'says plainly that no scriptable steer exists' {
        Assert-Phrase -Text (Get-DocText $script:StuckMd) -Where 'stuck-worker-recovery' `
            -Phrase 'There is no `claude send`, and no scriptable way to steer a running worker.'
    }

    It 'hands an attach to the user rather than faking a steer' {
        $text = Get-DocText $script:StuckMd
        Assert-Phrase -Text $text -Where 'stuck-worker-recovery' `
            -Phrase ('The only way to talk to a running worker is `claude attach`, which is ' +
                     'interactive and belongs to the user, not the Hand.')
    }

    It 'warns that `claude rm` destroys the worktree, and gives the safe order' {
        $text = Get-DocText $script:StuckMd
        Assert-Phrase -Text $text -Where 'the rm hazard' `
            -Phrase '`claude rm` deletes the session and its worktree together.'
        Assert-Phrase -Text $text -Where 'the rm hazard' `
            -Phrase ('Running it on a stuck worker that holds uncommitted changes or unpushed ' +
                     'commits destroys that work')
        Assert-Phrase -Text $text -Where 'the rm hazard' `
            -Phrase 'Use `claude stop <worker id>` while anything is unlanded.'
        Assert-Phrase -Text $text -Where 'the rm hazard' `
            -Phrase ('Use `claude rm <worker id>` only once the work is committed and either ' +
                     'landed or pushed, or the user has explicitly authorised discarding it.')
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
        Assert-Phrase -Text $text -Where 'stuck-worker-recovery' `
            -Phrase ('Never allocate a second worktree for one task**, because that splits it ' +
                     'across two copies')
        Assert-Phrase -Text $text -Where 'stuck-worker-recovery' `
            -Phrase ('If the worktree or the ownership cannot be reconciled safely, leave all ' +
                     'state intact and report the task failed or blocked with the conflicting ' +
                     'evidence.')
    }

    It 'reads liveness as presence, not as proof the work is gone' {
        Assert-Phrase -Text (Get-DocText $script:StuckMd) -Where 'stuck-worker-recovery' `
            -Phrase ('Treat a liveness result as a presence signal, not proof that the worker''s ' +
                     'work is gone.')
    }

    It 'names the six valid stages and sets failed through Set-CrewStage' {
        Assert-Phrase -Text (Get-DocText $script:StuckMd) -Where 'stuck-worker-recovery' `
            -Phrase ("Set-CrewStage -Stage 'failed'``; the valid stages are exactly " +
                     "``dispatched``, ``implementing``, ``gating``, ``ready``, ``landed``, ``failed``")
    }
}

Describe 'CLAUDE.md declares a load trigger for every reference skill' {
    It 'names <name> with the situation that loads it' -ForEach @(
        @{ name = 'diagnostic-reasoning'
           phrase = '`diagnostic-reasoning` - load before writing a brief for a reported bug' }
        @{ name = 'ask-user-authority'
           phrase = '`ask-user-authority` - load before deciding any ask-user finding' }
        @{ name = 'kingshand-guidelines'
           # Single-quoted on purpose: in a double-quoted string the backtick is PowerShell's
           # escape character and the backticks around the skill name silently disappear.
           phrase = '`kingshand-guidelines` - load before changing kingshand''s own tracked material' }
        @{ name = 'stuck-worker-recovery'
           phrase = ('`stuck-worker-recovery` - load when a worker reads dead or has no live ' +
                     'process') }
        @{ name = 'decision-hold-lifecycle'
           phrase = ('`decision-hold-lifecycle` - load before treating a worker''s investigation ' +
                     'or review as complete') }
    ) {
        Assert-Phrase -Text (Get-DocText $script:HandMd) -Where 'the CLAUDE.md Skills section' -Phrase $phrase
    }

    It 'names ahoy as a command, and keeps rm behind the recovery skill' {
        $text = Get-DocText $script:HandMd
        Assert-Phrase -Text $text -Where 'the CLAUDE.md Skills section' `
            -Phrase 'Invoke `ahoy` when the user invokes `/ahoy` or asks what they missed'
        Assert-Phrase -Text $text -Where 'the CLAUDE.md Skills section' `
            -Phrase 'Never run `claude rm` on a stuck worker before loading it.'
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

    It 'routes a dead worker to the recovery skill and a catch-up to bearings' {
        $s = Get-HandSection 'Recovery'
        Assert-Phrase -Text $s -Where 'CLAUDE.md recovery' `
            -Phrase ('load `stuck-worker-recovery` and preserve its worktree and unlanded work ' +
                     'while you reconcile ownership')
        Assert-Phrase -Text $s -Where 'CLAUDE.md recovery' `
            -Phrase '`bearings` is the on-demand way to see where everything stands'
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
            -Phrase '| `teardown`, `claude rm`, `claude stop` | cleanup |'
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
            -Phrase '5. **Route by what the user does with the output, never by how long it is.**'
        Assert-Phrase -Text $script:Rule5 -Where 'CLAUDE.md rule 6' `
            -Phrase '6. **Escalate real decisions only.**'
    }

    It 'no longer decides by line count' {
        $script:Rule5.Contains('More than 5-6 lines') |
            Should -BeFalse -Because 'the line-count threshold is the half of rule 5 that was ignored'
        Assert-Phrase -Text $script:Rule5 -Where 'CLAUDE.md rule 5' `
            -Phrase 'Length alone is not the test, and a long answer is allowed to be a long answer.'
    }

    It 'sends deciding and scanning to a rendered surface' {
        Assert-Phrase -Text $script:Rule5 -Where 'CLAUDE.md rule 5' `
            -Phrase ('A rendered surface carries anything the user must decide on, and any ' +
                     'structured artifact they scan and compare - a diff, a requirement list, a ' +
                     'review gate.')
    }

    It 'leaves everything read once and acted on in chat' {
        Assert-Phrase -Text $script:Rule5 -Where 'CLAUDE.md rule 5' `
            -Phrase ('Chat carries everything else: answers, updates, pauses and notifications - ' +
                     'things read once and acted on.')
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

    It 'restates state on a change or a return, never on every turn' {
        Assert-Phrase -Text $script:Shape -Where 'CLAUDE.md escalation' `
            -Phrase ('Restate state when it changed, or when the user has been away - never on ' +
                     'every turn, because unchanged state repeated every message is noise, and ' +
                     'over a long session it is a lot of noise.')
    }

    It 'gives every estimate in concrete units' {
        Assert-Phrase -Text $script:Shape -Where 'CLAUDE.md escalation' `
            -Phrase ('Give every estimate in concrete units - minutes, hours, file counts, test ' +
                     'counts - and never "quick", "shortly" or "a bit".')
    }

    It 'keeps the etiquette that already held, and leaves bearings its own contract' {
        Assert-Phrase -Text $script:Shape -Where 'CLAUDE.md escalation' `
            -Phrase 'No preamble and no closing pleasantries.'
        Assert-Phrase -Text $script:Shape -Where 'CLAUDE.md escalation' `
            -Phrase 'Batch non-urgent updates into the next natural reply.'
        Assert-Phrase -Text $script:Shape -Where 'CLAUDE.md escalation' `
            -Phrase ('A skill that owns its own chat contract, such as `bearings`, keeps that ' +
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

Describe 'crew keeps the backlog current across the whole lifecycle' {
    # A queue is only durable if every lifecycle step writes to it. Intake is the load-bearing
    # one: filing the item BEFORE the brief is what makes work that never gets dispatched
    # visible at all, which is the whole reason the queue exists.
    It 'Step 1 files the item before the brief is written' {
        $step = Get-CrewStep 'Step 1 - Intake'
        Assert-Phrase -Text $step -Where 'crew Step 1' `
            -Phrase '**Record the unit of work in the backlog before its brief is written.**'
        Assert-Phrase -Text $step -Where 'crew Step 1' `
            -Phrase ('Filing the item here is what makes a unit of work visible before anything ' +
                     'is dispatched, so do it even when the dispatch gate is about to refuse it.')
        Assert-Phrase -Text $step -Where 'crew Step 1' `
            -Phrase 'Ids are slug-shaped - letters, digits, `.`, `_` and `-`, with no spaces.'
    }

    It 'Step 1 points at the contract rather than restating it' {
        Assert-Phrase -Text (Get-CrewStep 'Step 1 - Intake') -Where 'crew Step 1' `
            -Phrase ('`CLAUDE.md`''s Backlog contract owns why, and `tasks-axi --help` owns ' +
                     'the flags.')
    }

    It 'Step 4 marks the item started after the dispatch is recorded' {
        Assert-Phrase -Text (Get-CrewStep 'Step 4 - Dispatch') -Where 'crew Step 4' `
            -Phrase 'Then mark the backlog item started, so the queue and the crew agree on what is under way'
    }

    It 'Step 6 records the outcome and refuses to close the item there' {
        $step = Get-CrewStep 'Step 6 - Completion'
        Assert-Phrase -Text $step -Where 'crew Step 6' `
            -Phrase '**Record the outcome on the backlog item**, pointing at the report rather than restating it'
        Assert-Phrase -Text $step -Where 'crew Step 6' `
            -Phrase ('Do not mark it done here. The item closes at Step 8 or Step 8a, when the ' +
                     'work has actually landed.')
    }

    It 'Step 8 closes the item once the local merge has landed' {
        Assert-Phrase -Text (Get-CrewStep 'Step 8 - Land') -Where 'crew Step 8' `
            -Phrase 'The work has landed, so close the backlog item'
    }

    It 'Step 8a records the pull request and leaves the item open until the merge' {
        $step = Get-CrewStep 'Step 8a'
        Assert-Phrase -Text $step -Where 'crew Step 8a' `
            -Phrase 'Record the outcome on the backlog item as well - the pull request is what this work produced'
        Assert-Phrase -Text $step -Where 'crew Step 8a' `
            -Phrase ('Leave the item open at `ready`. Nothing has landed yet, and an item closed ' +
                     'here would report a merge the user has not made.')
        Assert-Phrase -Text $step -Where 'crew Step 8a' `
            -Phrase 'close the backlog item in the same breath'
    }

    It 'every backlog command in crew runs from $env:KINGSHAND_HOME' {
        # tasks-axi resolves .tasks.toml from the current directory, so a command run from
        # anywhere else silently reads or writes a different backlog, or none.
        $fences = @(Get-CodeFence $script:CrewMd | Where-Object { $_.Contains('tasks-axi ') })
        $fences.Count | Should -BeGreaterOrEqual 6 -Because 'intake, dispatch, completion and both landing paths each write to the queue'
        foreach ($fence in $fences) {
            $fence.Contains('Set-Location $env:KINGSHAND_HOME') |
                Should -BeTrue -Because 'tasks-axi resolves .tasks.toml from the current directory'
        }
    }
}

Describe 'bearings Charted Next reads the real queue' {
    # Charted Next was empty by construction - the skill said kingshand kept no backlog. Now it
    # has one, and the section that was permanently empty must actually read it.
    BeforeAll { $script:BearingsQueue = Get-DocText $script:BearingsMd }

    It 'no longer claims kingshand keeps no backlog' {
        $script:BearingsQueue.Contains('Kingshand keeps no backlog') |
            Should -BeFalse -Because 'the queue exists now, and Charted Next reads it'
    }

    It 'names the three kinds of queued work it surfaces' {
        Assert-Phrase -Text $script:BearingsQueue -Where 'the bearings Charted Next bucket' `
            -Phrase ('Real queued work read from `data\backlog.md`: an item not yet dispatched, ' +
                     'an item whose dependencies have not cleared, and an item held for ' +
                     'something other than the user')
    }

    It 'keeps an un-dispatched brief and its queued item in exactly one bucket' {
        Assert-Phrase -Text $script:BearingsQueue -Where 'the bearings Charted Next bucket' `
            -Phrase 'the two never both render for the same unit of work'
    }

    It 'still surfaces diagnostics there, and still keeps the empty state' {
        Assert-Phrase -Text $script:BearingsQueue -Where 'the bearings Charted Next bucket' `
            -Phrase 'Any `$snap.diagnostics` entry, as an action-free integrity warning'
        Assert-Phrase -Text $script:BearingsQueue -Where 'the bearings Charted Next bucket' `
            -Phrase ('When the queue really is empty and there is nothing else to warn about, ' +
                     'render "Nothing is queued." rather than dropping the section.')
    }

    It 'reads the queue with its own reader and never hand-scans the file' {
        Assert-Phrase -Text $script:BearingsQueue -Where 'the bearings gather step' `
            -Phrase 'The snapshot covers the fleet; it does not cover the queue.'
        Assert-Phrase -Text $script:BearingsQueue -Where 'the bearings gather step' `
            -Phrase ('`tasks-axi` is `data\backlog.md`''s own reader, and hand-scanning that file ' +
                     'instead is exactly what the rule does forbid')
    }

    It 'stays read-only against the queue' {
        Assert-Phrase -Text $script:BearingsQueue -Where 'the bearings read-only section' `
            -Phrase ('**Reading the backlog is a read.** Never add, start, hold, unhold, update ' +
                     'or close a backlog item from this skill')
    }

    It 'treats an unreadable queue as a diagnostic rather than an empty one' {
        Assert-Phrase -Text $script:BearingsQueue -Where 'the bearings gather step' `
            -Phrase ('say the queue could not be read and do not render Charted Next as though ' +
                     'it were empty')
    }
}

Describe 'stow keeps the description that is its only trigger' {
    # Nothing runs stow. There is no hook, no timer and no scheduled pass - it fires because the
    # Hand reads this description in the skill listing every turn and recognises the situation
    # in it. Delete the situation from the description and the skill still loads on /stow and
    # otherwise never runs again, silently. That is why the trigger clause is pinned verbatim
    # rather than checked for a keyword.
    BeforeAll {
        $script:StowFm   = Get-Frontmatter $script:StowMd
        $script:StowText = Get-DocText $script:StowMd
    }

    It 'has frontmatter that parses, with a name and a non-empty description' {
        $script:StowFm['name']        | Should -Be 'stow'
        $script:StowFm['version']     | Should -Be '1.0.0'
        $script:StowFm['description'] | Should -Not -BeNullOrEmpty
        $script:StowFm['description'].Length | Should -BeGreaterThan 40
    }

    It 'is invocable by the user as a command' {
        $script:StowFm['user-invocable'] | Should -Be 'true'
        $script:StowFm['description'].Contains('when the user invokes /stow') |
            Should -BeTrue -Because 'the command form must stay in the description'
    }

    It 'keeps the self-trigger clause that makes it fire without anything calling it' {
        $script:StowFm['description'].Contains(
            'before a session reset or context compaction, or periodically to keep operational memory current') |
            Should -BeTrue -Because 'that clause is the entire mechanism by which stow ever runs'
    }

    It 'CLAUDE.md declares the same trigger inline, and says nothing runs it' {
        $text = Get-DocText $script:HandMd
        Assert-Phrase -Text $text -Where 'the CLAUDE.md Skills section' `
            -Phrase ('Invoke `stow` when the user invokes `/stow`, before a session reset or ' +
                     'context compaction, or periodically to keep operational memory current.')
        Assert-Phrase -Text $text -Where 'the CLAUDE.md Skills section' `
            -Phrase 'Nothing runs it on your behalf either.'
    }
}

Describe 'stow curates memory rather than accumulating it' {
    BeforeAll { $script:StowText = Get-DocText $script:StowMd }

    It 'treats an absent memory file as meaningful rather than as an error' {
        Assert-Phrase -Text $script:StowText -Where 'stow' `
            -Phrase ('Both are created lazily and are absent until there is something to store. ' +
                     'Absence is meaningful, not an error, and it is never an invitation to ' +
                     'manufacture content or write a placeholder.')
    }

    It 'counts its own marker bytes against the budget' {
        Assert-Phrase -Text $script:StowText -Where 'stow' `
            -Phrase ('marker bytes are counted content: they are measured against the ' +
                     'startup-memory budget exactly like prose')
    }

    It 'names both tier clocks and exempts pinned from them' {
        Assert-Phrase -Text $script:StowText -Where 'the stow tier table' `
            -Phrase 'An entry whose age is 30 days or more since its last-reinforced date is stale'
        Assert-Phrase -Text $script:StowText -Where 'the stow tier table' `
            -Phrase 'An entry whose age is 7 days or more since its last-reinforced date is stale'
        Assert-Phrase -Text $script:StowText -Where 'the stow tier table' `
            -Phrase 'no clock is ever read for it'
    }

    It 'requires evidence from this session before an entry is reinforced' {
        Assert-Phrase -Text $script:StowText -Where 'stow step 4' `
            -Phrase ('Reinforcement requires independent evidence from this session that you can ' +
                     'name in the receipt. Plausibility, importance, prior knowledge and the ' +
                     "entry's own text are not evidence")
    }

    It 'retires stale material to a cold archive instead of deleting it' {
        Assert-Phrase -Text $script:StowText -Where 'the stow cold tier' -Phrase 'Stale never means deleted.'
        Assert-Phrase -Text $script:StowText -Where 'the stow cold tier' `
            -Phrase ('Pruning an entry from a memory file always means moving it to ' +
                     '`$env:KINGSHAND_HOME\data\memory-archive.md`')
        Assert-Phrase -Text $script:StowText -Where 'stow' `
            -Phrase 'A stale unique fact is never deleted, only archived.'
    }

    It 'reads before it writes, and rewrites rather than appending forever' {
        Assert-Phrase -Text $script:StowText -Where 'stow step 2' `
            -Phrase ('Read-before-write is not optional: a rewrite decided without the current ' +
                     'text is an append in disguise.')
        Assert-Phrase -Text $script:StowText -Where 'stow' `
            -Phrase 'Rewrite and prune rather than appending forever.'
    }

    It 'leaves the routing table to CLAUDE.md rather than restating it' {
        Assert-Phrase -Text $script:StowText -Where 'stow' `
            -Phrase "Route each finding using ``CLAUDE.md``'s Knowledge routing section."
        Assert-Phrase -Text $script:StowText -Where 'stow' `
            -Phrase 'That section owns the mapping; this skill owns the pass. Do not restate the routing rules here.'
    }

    It 'never writes a project itself, and never ends a pass over budget' {
        Assert-Phrase -Text $script:StowText -Where 'stow' `
            -Phrase ('It never touches a project, and hard rule 1 is not suspended for a ' +
                     'curation pass.')
        Assert-Phrase -Text $script:StowText -Where 'stow step 8' `
            -Phrase ('Never end a pass over budget as an accepted exception, and never describe ' +
                     'the session as reset-safe while the total is over budget or an exception is ' +
                     'unresolved.')
    }

    It 'refuses to make a skill the destination for a finding' {
        Assert-Phrase -Text $script:StowText -Where 'the stow scope exclusion' `
            -Phrase ('The stow pass itself must never create or edit a skill as a destination for ' +
                     'a finding.')
        Assert-Phrase -Text $script:StowText -Where 'the stow scope exclusion' `
            -Phrase '`kingshand-guidelines`'
    }

    It 'measures the budget through the module rather than by eye' {
        $fences = @(Get-CodeFence $script:StowMd | Where-Object { $_.Contains('Get-MemoryReport') })
        $fences.Count | Should -Be 1 -Because 'the measurement is stated once, as runnable text'
        $fences[0].Contains('Import-Module .\bin\Memory.psm1') |
            Should -BeTrue -Because 'the estimate has one owner, and it is the module'
        $fences[0].Contains('Set-Location $env:KINGSHAND_HOME') |
            Should -BeTrue -Because 'the module path is resolved from kingshand, not from a worktree'
    }
}

Describe 'the ADO organization and project are configuration, and absence asks' {
    # These were two hardcoded names belonging to one employer. Any default at all is the wrong
    # shape here: a wrong organization does not fail loudly, it returns "work item not found" -
    # indistinguishable from a mistyped ticket - or, worse, a real work item from somewhere else.
    BeforeAll { $script:CrewIntake = Get-CrewStep 'Step 1 - Intake' }

    It 'reads them from a config file rather than carrying a built-in default' {
        Assert-Phrase -Text $script:CrewIntake -Where 'crew Step 1' `
            -Phrase '**The ADO organization and project are configuration, never built in.**'
        Assert-Phrase -Text $script:CrewIntake -Where 'crew Step 1' `
            -Phrase '`$env:KINGSHAND_HOME\config\ado.json`, which is absent by default'
    }

    It 'asks rather than guessing when the config is absent' {
        Assert-Phrase -Text $script:CrewIntake -Where 'crew Step 1' `
            -Phrase ('**With no config file, ask the King for the organization and project. Do not ' +
                     'guess, and do not carry over a value from an earlier session.**')
    }

    It 'ships placeholders in the example, and no built-in default to fall back on' {
        # Deliberately not written as a list of the names that used to be here. A distributed repo
        # that spells out the exact strings it must never contain has not removed them.
        $text = Get-DocText $script:CrewMd
        Assert-Phrase -Text $text -Where 'the crew ADO config example' -Phrase '"organization": "your-ado-organization"'
        Assert-Phrase -Text $text -Where 'the crew ADO config example' -Phrase '"project": "Your ADO Project"'
        $text.Contains('Do not ask.') |
            Should -BeFalse -Because 'the form this replaced asserted a built-in default and forbade asking about it'
    }

    It 'records that the hold kind is the external tool''s spelling, not ours' {
        # The one place `captain` survives the rename. It is a validated enum in tasks-axi, so a
        # tidy-up that renamed it to `king` would make every hold fail VALIDATION_ERROR - and a
        # hold that fails is a decision recorded nowhere at all.
        Assert-Phrase -Text (Get-DocText $script:HoldMd) -Where 'decision-hold-lifecycle' `
            -Phrase '**`captain` here is `tasks-axi`''s spelling, not ours, and it is not free text.**'
        Assert-Phrase -Text (Get-DocText $script:HoldMd) -Where 'decision-hold-lifecycle' `
            -Phrase 'Do not "correct" it to `king`'
    }

    It 'keeps the config directory out of version control' {
        $ignore = Get-Content -Path (Join-Path $script:Root '.gitignore') -Raw
        $ignore.Contains('/config/') |
            Should -BeTrue -Because 'the answer to that question is one machine''s, and stays on it'
    }
}

Describe 'the King''s stated instructions are read and never rewritten' {
    # Two files that both hold preferences, one curated and one not, is a distinction that erodes
    # the moment nobody restates it. If `instructions.md` is ever treated as a memory file, a stow
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
            -Phrase ('`king.md` is what you inferred and `stow` prunes it against a budget, while ' +
                     '`instructions.md` is what the King stated and nothing may rewrite it. ' +
                     'Conflating the two would let a curation pass silently delete a preference ' +
                     'the King actually stated.')
    }

    It 'CLAUDE.md routes nothing into it' {
        Assert-Phrase -Text (Get-HandSection 'Knowledge routing') -Where 'CLAUDE.md Knowledge routing' `
            -Phrase 'Nothing at all is routed into `instructions.md`.'
    }

    It 'stow disclaims it as a destination and as a curation target' {
        $text = Get-DocText $script:StowMd
        Assert-Phrase -Text $text -Where 'stow' `
            -Phrase ('**`$env:KINGSHAND_HOME\instructions.md` is not a memory file and this pass ' +
                     'never touches it.**')
        Assert-Phrase -Text $text -Where 'stow' `
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
    It 'the template asks for the King form of address, and says how to stop it' {
        $template = ConvertTo-NormalisedText (Get-Content -Path (Join-Path $script:Root 'instructions.example.md') -Raw)
        $template.Contains('**Address me as "my King".**') | Should -BeTrue
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
                     '`kingshand-guidelines` owns which file, and the test that has to come with it.')
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
            -Phrase ('`stow` owns the curation pass, the tiers and the budget; `bin\Memory.psm1` ' +
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
        Assert-Phrase -Text $script:SessionStart -Where 'CLAUDE.md session start' `
            -Phrase '**Liveness still comes from `claude agents --json`**'
    }

    It 'reads absence as a state rather than an error' {
        Assert-Phrase -Text $script:SessionStart -Where 'CLAUDE.md session start' `
            -Phrase 'Absence in the digest is a state, never an error.'
        Assert-Phrase -Text $script:SessionStart -Where 'CLAUDE.md session start' `
            -Phrase ('`ABSENT` against `king.md` or `learnings.md` means nothing has been ' +
                     'recorded there yet, which is not the same as a file that exists and holds ' +
                     'nothing, and neither is a reason to write a placeholder.')
        Assert-Phrase -Text $script:SessionStart -Where 'CLAUDE.md session start' `
            -Phrase ('An empty registry means nothing can be dispatched until `/import-project` ' +
                     'runs.')
    }

    It 'routes a budget overrun to stow without treating it as a gate' {
        Assert-Phrase -Text $script:SessionStart -Where 'CLAUDE.md session start' `
            -Phrase ('A `STARTUP_MEMORY_BUDGET:` line means the two memory files have outgrown ' +
                     'their budget - invoke `stow` to curate them back down, and read them anyway, ' +
                     'because the budget is a signal and not a gate.')
    }

    It 'keeps the digest and bearings separate, with neither calling the other' {
        Assert-Phrase -Text $script:SessionStart -Where 'CLAUDE.md session start' `
            -Phrase ('The digest is not `bearings` and neither runs the other. This is mechanical ' +
                     'startup input nobody asked for; `bearings` is a curated answer to "what ' +
                     'needs me" that only the user ever asks for.')
    }

    It 'keeps bearings'' own rule that nothing runs it on the Hand''s behalf' {
        Assert-Phrase -Text (Get-DocText $script:HandMd) -Where 'the CLAUDE.md Skills section' `
            -Phrase 'Nothing runs it on your behalf.'
    }

    It 'lists the digest script in the Tooling table' {
        Assert-Phrase -Text (Get-DocText $script:HandMd) -Where 'the CLAUDE.md Tooling table' `
            -Phrase ('| `bin\Get-SessionStart.ps1` | the once-per-session digest behind the ' +
                     '`SessionStart` hook')
    }
}

Describe 'no long dash' {
    It 'does not appear in <file>' -ForEach @(
        @{ file = 'CLAUDE.md' }
        @{ file = 'skills\crew\SKILL.md' }
        @{ file = 'skills\import-project\SKILL.md' }
        @{ file = 'skills\bearings\SKILL.md' }
        @{ file = 'skills\diagnostic-reasoning\SKILL.md' }
        @{ file = 'skills\ask-user-authority\SKILL.md' }
        @{ file = 'skills\kingshand-guidelines\SKILL.md' }
        @{ file = 'skills\ahoy\SKILL.md' }
        @{ file = 'skills\stuck-worker-recovery\SKILL.md' }
        @{ file = 'skills\stow\SKILL.md' }
        @{ file = 'skills\decision-hold-lifecycle\SKILL.md' }
        @{ file = '.claude\skills\setup\SKILL.md' }
        @{ file = 'install.ps1' }
    ) {
        $emDash = [char]0x2014
        $raw = Get-Content -Path (Join-Path $script:Root $file) -Raw
        $raw.IndexOf($emDash) | Should -Be -1 -Because "$file must use '-', never the long dash"
    }
}

Describe 'decision-hold-lifecycle keeps an unresolved decision durable' {
    # This skill has no script behind it at all - kingshand has no teardown gate to enforce it - so
    # the text IS the whole mechanism, and every clause below is load-bearing. A decision that is
    # never registered leaves no trace once the worker, its session and its transcript are gone.
    # Every phrase is single-quoted on purpose: a backtick is PowerShell's escape character inside
    # a double-quoted string, and these clauses are thick with backticked identifiers.
    BeforeAll { $script:HoldText = Get-DocText $script:HoldMd }

    It 'requires the decision to be durable before the work counts as complete' {
        Assert-Phrase -Text $script:HoldText -Where 'decision-hold-lifecycle' `
            -Phrase ('must become a durable backlog item in `data\backlog.md` **before that work ' +
                     'may be treated as complete**')
    }

    It 'leaves the inventory to the agent because no script can infer a decision from prose' {
        Assert-Phrase -Text $script:HoldText -Where 'decision-hold-lifecycle' `
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
        Assert-Phrase -Text $script:HoldText -Where 'decision-hold-lifecycle' `
            -Phrase ('**Do not close a hold merely because the work that found it finished**, its ' +
                     'report was archived, or its worker was torn down. Those are unrelated ' +
                     'events.')
        Assert-Phrase -Text $script:HoldText -Where 'decision-hold-lifecycle' `
            -Phrase ('A completed investigation, a closed backlog item for the investigation ' +
                     'itself, a confirmed push and a removed worktree say nothing whatsoever ' +
                     'about whether the user has answered.')
    }

    It 'keeps an authorised answer routed before the hold may close' {
        Assert-Phrase -Text $script:HoldText -Where 'decision-hold-lifecycle' `
            -Phrase ('the hold stays the authoritative item until the answer is durably recorded, ' +
                     'the dependent work exists as its own backlog item, and that item is blocked ' +
                     'by the hold. Only then does the hold close.')
    }

    It 'records a declined answer without letting it stand in for routing' {
        Assert-Phrase -Text $script:HoldText -Where 'decision-hold-lifecycle' `
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

    It 'forbids bearings compensating by scraping prose' {
        Assert-Phrase -Text $script:HoldText -Where 'decision-hold-lifecycle' `
            -Phrase ('`bearings` reads the resulting structured state through `tasks-axi` and must ' +
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
            -Phrase ('`crew` Step 8b tears a worker down on landing or push evidence alone and ' +
                     'reads no decision state, `bin\` contains no check that looks for an open ' +
                     'hold before cleanup')
        Assert-Phrase -Text $script:HoldText -Where 'the enforcement section' `
            -Phrase ('So this is a discipline the Hand follows, not a check a script performs.')
    }

    It 'is the Hand''s to load, never a worker''s' {
        Assert-Phrase -Text $script:HoldText -Where 'decision-hold-lifecycle' `
            -Phrase 'The Hand loads it; nobody invokes it by name.'
        Assert-Phrase -Text $script:HoldText -Where 'decision-hold-lifecycle' `
            -Phrase 'A worker never loads it.'
    }
}

Describe 'crew loads the decision lifecycle before it calls work complete' {
    # A worker's report.md is required to name any decision its brief did not settle, so the two
    # moments that read it - completion and close-out - are exactly where a decision is lost if
    # nothing picks it up. Neither of them may treat a finished worker as an answered question.
    It 'Step 6 loads it before treating the work as complete' {
        $step = Get-CrewStep 'Step 6 - Completion'
        Assert-Phrase -Text $step -Where 'crew Step 6' `
            -Phrase ('**Before you treat this worker''s work as complete, load ' +
                     '`decision-hold-lifecycle`.**')
        Assert-Phrase -Text $step -Where 'crew Step 6' `
            -Phrase ('A worker finishing is not an answer, and nothing here closes a decision.')
    }

    It 'Step 8a loads it before close-out, and keeps the hold open through teardown' {
        $step = Get-CrewStep 'Step 8a'
        Assert-Phrase -Text $step -Where 'crew Step 8a' `
            -Phrase '**Load `decision-hold-lifecycle` before closing this work out.**'
        Assert-Phrase -Text $step -Where 'crew Step 8a' `
            -Phrase ('A hold opened from this work''s report stays open through `gating`, through ' +
                     '`ready`, through `landed`, and through the teardown at Step 8b, because ' +
                     'none of those events is an answer.')
    }
}

Describe 'bearings puts an open decision in King''s Call and only there' {
    # King's Call is the bucket for what needs the user's own action, and an unanswered decision
    # is the purest case of it. Rendering it in Charted Next instead buries it among work that is
    # merely waiting, and rendering it in both breaks the exclusivity that makes the digest a
    # snapshot rather than a list.
    BeforeAll { $script:BearingsHold = Get-DocText $script:BearingsMd }

    It 'reads the hold kind rather than the hold alone' {
        Assert-Phrase -Text $script:BearingsHold -Where 'the bearings gather step' `
            -Phrase ('**The hold kind is what decides the bucket, so read it rather than the hold ' +
                     'alone.** A hold of kind `captain` waits on the user''s own answer and ' +
                     'belongs in King''s Call; `external`, `load`, `parked` and `future` wait ' +
                     'on something else and belong in Charted Next.')
    }

    It 'renders a captain hold in King''s Call with its reason' {
        Assert-Phrase -Text $script:BearingsHold -Where 'the bearings King''s Call bucket' `
            -Phrase ('A backlog item held with a hold kind of `captain` - an open decision waiting ' +
                     'on the user''s own answer, read from `tasks-axi ready --include-held`.')
        Assert-Phrase -Text $script:BearingsHold -Where 'the bearings King''s Call bucket' `
            -Phrase ('This is what King''s Call is for, so it renders here and in no other ' +
                     'section.')
    }

    It 'never duplicates it into Charted Next' {
        Assert-Phrase -Text $script:BearingsHold -Where 'the bearings Charted Next bucket' `
            -Phrase ('A hold of kind `captain` is the one queued item that does not belong here.')
        Assert-Phrase -Text $script:BearingsHold -Where 'the bearings Charted Next bucket' `
            -Phrase ('Never duplicate it into this section to keep the queue looking complete: ' +
                     'the four buckets are mutually exclusive, and one decision rendered twice ' +
                     'reads as two.')
    }

    It 'keeps the four buckets mutually exclusive' {
        Assert-Phrase -Text $script:BearingsHold -Where 'the bearings chat-response contract' `
            -Phrase 'The four buckets are mutually exclusive, so every item lands in exactly one'
    }

    It 'still leaves closing a hold to its owner rather than doing it here' {
        Assert-Phrase -Text $script:BearingsHold -Where 'the bearings read-only section' `
            -Phrase ('`crew` owns every one of those, and `decision-hold-lifecycle` owns the only ' +
                     'way a captain hold may close')
    }
}

Describe 'the setup skill ships inside the repo so a fresh clone can bootstrap itself' {
    # The ten skills under skills\ reach Claude Code only through the junctions install.ps1
    # creates, so in a clone where the installer has not run none of them exists. A project-level
    # skill in .claude\skills\ is readable immediately, which is the only way "set it up" can be
    # the first thing anyone types. Moving this file into skills\ would put it back behind the
    # very install it is meant to trigger.
    BeforeAll { $script:SetupText = Get-DocText $script:SetupMd }

    It 'lives in .claude\skills\, not skills\' {
        Test-Path -LiteralPath $script:SetupMd |
            Should -BeTrue -Because 'a fresh clone has no junctions, so the setup skill must be project-level'
        Test-Path -LiteralPath (Join-Path $script:Root 'skills\setup\SKILL.md') |
            Should -BeFalse -Because 'a copy under skills\ would only load after the install it triggers'
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
            -Phrase ('When that file is absent, `crew` asks for the Azure DevOps organization and ' +
                     'project the first time it needs them, rather than inventing values')
    }

    It 'says permission prompts are off and names the README section that explains it' {
        Assert-Phrase -Text $script:SetupText -Where 'the setup skill' `
            -Phrase 'neither the Hand nor its workers will ask them to approve a tool call'
        Assert-Phrase -Text $script:SetupText -Where 'the setup skill' `
            -Phrase 'Permissions, and what you are agreeing to'
    }

    It 'sends them to a new shell and then to /import-project' {
        Assert-Phrase -Text $script:SetupText -Where 'the setup skill' `
            -Phrase '**Open a new shell.** `KINGSHAND_HOME` is set for the user'
        Assert-Phrase -Text $script:SetupText -Where 'the setup skill' `
            -Phrase '**Register a repository** with `/import-project <path>`'
    }

    It 'offers to re-run with -ProjectRoot when none was given' {
        Assert-Phrase -Text $script:SetupText -Where 'the setup skill' `
            -Phrase ('If `-ProjectRoot` was not passed, say so plainly: a repository outside this ' +
                     'directory cannot be reached until its root is added, and offer to re-run ' +
                     'with `-ProjectRoot <path>`.')
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

    It 'guards the whole install pass behind the switch' {
        Assert-Phrase -Text $script:InstallSource -Where 'install.ps1' `
            -Phrase 'if ($InstallMissing -and $missing.Count -gt 0) {'
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

    It 'never installs no-mistakes, whatever the switch says' {
        Assert-Phrase -Text (Get-DocText $script:InstallPs1) -Where 'install.ps1' `
            -Phrase 'no-mistakes is not on PATH and is never installed by -InstallMissing'
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
