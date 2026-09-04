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

    # Get-MusterStep cannot serve for Step 2. The brief template inside that step carries its own
    # `## Goal`, `## Scope` and `## Done means` headings, so the step splitter cuts Step 2 off at
    # the first of them and returns a fraction of it. This bounds the region by its two step
    # headings instead, so a rule moved out of Step 2 stops matching rather than passing from
    # wherever in the file it landed.
    function Get-MusterRegion {
        param(
            [Parameter(Mandatory)][string]$FromHeading,
            [Parameter(Mandatory)][string]$ToHeading
        )
        $text  = Get-Content -Path $script:MusterMd -Raw
        $start = $text.IndexOf("`n## $FromHeading")
        $end   = $text.IndexOf("`n## $ToHeading")
        if ($start -lt 0) { throw "No '## $FromHeading' heading in the muster skill." }
        if ($end -le $start) {
            throw "'## $ToHeading' does not follow '## $FromHeading' in the muster skill."
        }
        ConvertTo-NormalisedText $text.Substring($start, $end - $start)
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
            $block.Contains('write the question into `$env:KINGSHAND_HOME\data\<id>\report.md` - the question, the options you can see, and what you would need in order to choose - then say so in your final message and end your turn.') |
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

    # The wake line prints `promptBox` on every branch, and a printed field with no stated response
    # is a field the Hand reads past. A box with text in it is the one thing on that line that must
    # never be acted on directly: submitting it sends an instruction nobody wrote, and clearing it
    # destroys the only record the event happened.
    It 'says what a non-empty prompt box is, and routes it to rally instead of acting on it' {
        Assert-Phrase -Text $script:Step4 -Where 'muster Step 4' `
            -Phrase ('**`$w.promptBox` with anything in it is not the worker''s output and not a ' +
                     'question for you.**')
        Assert-Phrase -Text $script:Step4 -Where 'muster Step 4' `
            -Phrase ('a bare Enter would submit it as though the Hand had written it')
        Assert-Phrase -Text $script:Step4 -Where 'muster Step 4' `
            -Phrase ('**Never submit it and never clear it** - quote it, say which worker it was ' +
                     'on, and load `rally`')
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
        # The snapshot carries neither half on its own, and the bucket must claim no more than it
        # has. The pointer is never cleared, so a key can be a decision answered hours ago; and a
        # null is silence rather than a completion, because the field is written by a Hand who read
        # the report. A bucket that read either as finished would drop a live question out of every
        # section of the digest, on the one surface built for coming back to the machine cold.
        Assert-Phrase -Text $script:SurveyText -Where 'the survey idle case' `
            -Phrase ('**`waitingOn` names a decision that worker stopped on at some point; it ' +
                     'never says the worker is still stopped on it.**')
        Assert-Phrase -Text $script:SurveyText -Where 'the survey idle case' `
            -Phrase ('It is not cleared when the answer lands, so a key here may be a decision ' +
                     'answered hours ago, and whether it is still open is the hold''s own state ' +
                     'in the backlog')
        Assert-Phrase -Text $script:SurveyText -Where 'the survey idle case' `
            -Phrase ('**Null never means the worker finished** either: the field is only written ' +
                     'by a Hand who has read that report, so a worker that parked overnight and ' +
                     'has not been woken since is still null, and the question is still only in ' +
                     'the report.')
        $script:SurveyText.Contains('so there is nothing to guess here') |
            Should -BeFalse -Because 'neither value of this field settles the idle case on its own'
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

    It 'statute matches a rule''s form to the failure it addresses' {
        # The distinction is the heart of the section: a recipe where the output comes out the
        # wrong shape, a prohibition where the rule is understood and skipped. Both halves are
        # pinned, because half of it is advice that reads as arbitrary, and so are the two
        # corollaries that say how to write each form. The basis sentence is pinned with them -
        # it is guidance from an outside measurement nobody has reproduced here, and a later
        # edit that tidies the caveat away would leave a guess reading as a law.
        $text = Get-DocText $script:GuidelinesMd
        Assert-Phrase -Text $text -Where 'statute' `
            -Phrase ('A **shaping** failure is output coming out the wrong shape rather than a ' +
                     'rule being skipped; write a recipe there')
        Assert-Phrase -Text $text -Where 'statute' `
            -Phrase ('A **discipline** failure is a rule understood and skipped anyway; a ' +
                     'prohibition is right there')
        Assert-Phrase -Text $text -Where 'statute' `
            -Phrase ('It is unverified against kingshand''s, so treat it as guidance for the ' +
                     'next rule you write rather than a law')
        Assert-Phrase -Text $text -Where 'statute' `
            -Phrase ('**Do not append a nuance clause to a recipe that works** - it degrades ' +
                     'the recipe.')
        Assert-Phrase -Text $text -Where 'statute' `
            -Phrase ('**an exemption clause does not scope**: "this limit does not apply to ' +
                     'code blocks" still suppresses code blocks')
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

    # rally owns the steer, and muster Step 6 sends the Hand here for the mechanics of steering an
    # answer back into a parked worker. So the blanket "a steer that needs a decision from the user
    # is the user's to make first" read as a refusal of the very steer that route depends on - the
    # parked-until-morning failure again. Narrowed the same way CLAUDE.md and regency were, and no
    # further: the blocked-prompt case is untouched and the test itself lives in petition alone.
    It 'narrows the never-steer-a-decision rule to the blocked-prompt case' {
        $text = Get-DocText $script:StuckMd
        Assert-Phrase -Text $text -Where 'rally' `
            -Phrase ('a steer that would answer a prompt a worker is blocked on is still the ' +
                     "King's to make first")
        Assert-Phrase -Text $text -Where 'rally' `
            -Phrase ('A decision the worker *wrote into its `report.md`* is the other case and ' +
                     'not this one: `petition` owns whether you may answer that and by what test')
        Assert-Phrase -Text $text -Where 'rally' `
            -Phrase '`muster` Step 6 owning the route the answer takes back'
        $text.Contains('reversible in minutes') |
            Should -BeFalse -Because 'the reversibility test is stated once, in petition'
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

    # A worker's input box can hold text nobody sent, and a bare Enter accepts it - so the one
    # thing rally must never tell the Hand to do is submit it or tidy it away. The guard in
    # bin\Herdr.psm1 refuses the send; this is the prose that says what to do with the refusal, and
    # deleting it is how someone re-learns the whole thing by submitting a generated instruction.
    It 'never submits or clears text a worker''s input box was found holding' {
        $text = Get-DocText $script:StuckMd
        Assert-Phrase -Text $text -Where 'the prompt-box hazard' `
            -Phrase '**Do not submit it, and do not clear it.**'
        Assert-Phrase -Text $text -Where 'the prompt-box hazard' `
            -Phrase ('A bare Enter accepts whatever is rendered there, so `Send-HerdrKeys ' +
                     '-Keys @(''enter'')` at an idle worker submits a generated instruction as ' +
                     'though the Hand had written it.')
        Assert-Phrase -Text $text -Where 'the prompt-box hazard' `
            -Phrase 'Clearing it destroys the only evidence the event happened.'
        Assert-Phrase -Text $text -Where 'the prompt-box hazard' `
            -Phrase ('**the exception is the escalation**: report what it said, and pass ' +
                     '`-AllowNonEmptyBox` only once the King has seen it')
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

    # A settled worker with a suggestion in its input box trips no other rally trigger: it is not
    # dead, not stalled, not blocked and not confused. Without this clause in both the always-loaded
    # trigger and the skill's own description, the one situation the guard reports has nowhere to go.
    It 'names an unexplained input box as a reason to load rally, here and in rally itself' {
        Assert-Phrase -Text (Get-DocText $script:HandMd) -Where 'the CLAUDE.md Skills section' `
            -Phrase 'found with unexplained text in its input box'
        $fm = Get-Frontmatter (Join-Path $script:Root '.claude\skills\rally\SKILL.md')
        $fm['description'].Contains('one found with unexplained text in its input box') |
            Should -BeTrue -Because 'the description is the trigger, and nothing else loads rally for a prompt box'
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

    It 'points at the project''s own rules file rather than restating its contents' {
        # The rule that has to survive is that conventions belong to the project and are read
        # rather than reconstructed. What changed is only where they are read from: they have a
        # named home now, so the Hand can open one rather than hunt for a memory file.
        $s = Get-HandSection 'Intake judgement'
        Assert-Phrase -Text $s -Where 'CLAUDE.md intake' `
            -Phrase ("Per-project conventions - a project's shorthand, its tagging, the vocabulary " +
                     'its tickets use - live in `data\rules-<project>.md`, not here and not ' +
                     'in the registry.')
        Assert-Phrase -Text $s -Where 'CLAUDE.md intake' `
            -Phrase '**read it before writing a brief or creating a work item**'
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
            -Phrase ('and neither is `done-<project>.md` or `rules-<project>.md` for any registered ' +
                     'project, nor any other name already in use for something else under `data\`')
    }

    # The two per-project standing files are the King's word for that project, delivered to every
    # worker dispatched into it. A curation pass that treated one as a decaying entry would
    # eventually delete a standing instruction he set once and expected to hold for a year, and
    # would do it in a pass nobody was watching.
    It 'the per-project standing files are outside the budget and outside the sweep' {
        Assert-Phrase -Text $script:ChronicleText -Where 'chronicle' `
            -Phrase ('**`data\rules-<project>.md` and `data\done-<project>.md` are outside this ' +
                     'budget and outside this sweep, and this pass never edits, decays, archives, ' +
                     'consolidates or offloads a line of either.**')
        Assert-Phrase -Text $script:ChronicleText -Where 'chronicle' `
            -Phrase 'they stand until he changes or removes them'
        Assert-Phrase -Text $script:ChronicleText -Where 'chronicle' `
            -Phrase 'Neither is measured against the startup budget, because neither is loaded'
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
    It 'muster states the nine refusals dispatch still makes' {
        $step = Get-MusterStep 'Step 4 - Dispatch'
        Assert-Phrase -Text $step -Where 'muster Step 4' `
            -Phrase ('There are nine, and each is refused by name: a brief with no ' +
                     '`## Read first` section at all, a brief that passes no `-ReadPath` and does ' +
                     'not say the index was checked when anything at all is indexed - and neither ' +
                     "the project's own standing files nor the browser procedure counts towards " +
                     'that one, per Step 2, which owns the rule - a brief carrying a ' +
                     '`## Browser checks` section that passes no `-ReadPath` for the browser ' +
                     'procedure or for the module it imports, a path that does not exist, a ' +
                     'directory where a file was meant, two different files whose names would ' +
                     'land on top of each other in the staging directory, a standing file that ' +
                     'exists and cannot be opened, a directory sitting where a standing file ' +
                     'belongs, and a brief that cannot be opened for writing to be told what was ' +
                     'attached to it.')
    }

    # The whole requirement, in the artefact the Hand reads at the moment it dispatches: the two
    # per-project files arrive whether or not anyone remembered them, and the brief ends up naming
    # each copy. Delivery by memory has already shipped a website without its settled brand.
    It 'muster says dispatch attaches the standing files and names them itself' {
        $step = Get-MusterStep 'Step 4 - Dispatch'
        Assert-Phrase -Text $step -Where 'muster Step 4' `
            -Phrase ("**Dispatch attaches the project's own standing files itself and writes their " +
                     '`Read first` lines.**')
        Assert-Phrase -Text $step -Where 'muster Step 4' `
            -Phrase 'It writes no line for a file you passed yourself'
        Assert-Phrase -Text $step -Where 'muster Step 4' `
            -Phrase 'A project with neither file dispatches exactly as it did before either existed.'
    }

    # The rules file is reference, not a checklist, and the distinction is the reason it is a second
    # file rather than more lines in the first. A worker answering n/a to "our tickets are tagged
    # NG-" dilutes the self-check on the lines that are really tested.
    It 'muster keeps the rules file out of the paste and out of -ReadPath' {
        Assert-Phrase -Text $script:MusterText -Where 'muster Step 2' `
            -Phrase '**The project''s standing rules are not pasted and not passed.**'
        Assert-Phrase -Text $script:MusterText -Where 'muster Step 2' `
            -Phrase 'pass no `-ReadPath` for it and write no line for it'
        Assert-Phrase -Text $script:MusterText -Where 'muster Step 2' `
            -Phrase 'never ask the worker to report against it'
        Assert-Phrase -Text $script:MusterText -Where 'muster Step 2' `
            -Phrase '**Read it yourself before you write the brief**'
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
        @{ file = 'docs\2026-09-02-prompt-box-safety.md' }
        @{ file = '.claude\skills\update\SKILL.md' }
        @{ file = 'docs\2026-09-03-versioning-and-update.md' }
        @{ file = '.claude\skills\counsel\SKILL.md' }
        @{ file = 'docs\2026-09-04-story-analysis-split.md' }
        @{ file = '.claude\skills\witness\SKILL.md' }
        @{ file = 'docs\2026-09-03-browser-verification.md' }
        @{ file = 'docs\2026-09-04-worker-environment-propagation.md' }
        @{ file = 'docs\2026-09-04-parked-decision-route.md' }
        @{ file = '.claude\skills\regency\SKILL.md' }
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
        # The key's job is stated without calling the registration idempotent. Only `add` is; a
        # `hold` replay overwrites the reason, and the mechanical facts below own that difference
        # rather than this sentence quietly promising the whole retry is free.
        Assert-Phrase -Text $script:HoldText -Where 'the stable-key rule' `
            -Phrase ('Give each distinct unresolved decision a **stable, privacy-safe key**, and ' +
                     'register it under that key, so a retry lands on the same durable item ' +
                     'rather than filing a second one while two different decisions keep two ' +
                     'different durable identities.')
        Assert-Phrase -Text $script:HoldText -Where 'the stable-key rule' `
            -Phrase ('Which half of that registration a retry may safely replay is the mechanical ' +
                     'facts'' business, below, and the two verbs do not behave alike.')
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
        # Narrowed to what is still true: Step 8b does read, so claiming it reads nothing would
        # have a Hand skip that check or rebuild a weaker one. And it reads BOTH sources - stating
        # the guard as the pointer alone would refuse cleanup of every worker that ever parked,
        # because the pointer is never cleared. What has not changed is that nothing under `bin\`
        # looks for an open hold, and that a decision nobody registered stops nothing - which is
        # the honesty this section exists for.
        Assert-Phrase -Text $script:HoldText -Where 'the enforcement section' `
            -Phrase ('`muster` Step 8b reads two recorded things before teardown - the pointer on ' +
                     'the worker''s record, and the hold that pointer names - and refuses only ' +
                     'where that hold is still open.')
        Assert-Phrase -Text $script:HoldText -Where 'the enforcement section' `
            -Phrase ('the pointer is never cleared, so a set field on its own would refuse cleanup ' +
                     'of every worker that ever parked, for the rest of its life')
        Assert-Phrase -Text $script:HoldText -Where 'the enforcement section' `
            -Phrase ('What neither read can catch is a decision nobody registered here - it has no ' +
                     'hold and no pointer, so it stops nothing at all.')
        Assert-Phrase -Text $script:HoldText -Where 'the enforcement section' `
            -Phrase '`bin\` contains no check that looks for an open hold before cleanup'
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
    # Every skill is project-local, under .claude\skills\, so all sixteen are readable the moment
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

        # The blocked-prompt floor is untouched and these three still pin it. What changed is the
        # blanket rule that used to sit beside it, and the two cases now have to stay apart: a
        # prompt drawn on a screen is still never answered, a decision written into a report is
        # petition's. An assertion on the old phrase would be worthless here - the deliberate-change
        # note quotes it so a reader can find it in git history - so this pins the new bullet and
        # the absence of the old one's own heading, which is what a restoration would bring back.
        It 'never answers a prompt a blocked worker is sitting on' {
            $script:Regency | Should -Match 'Do \*\*not\*\* send it keys'
            $script:Regency | Should -Match 'record the question verbatim'
            $script:Regency | Should -Match 'A prompt drawn on a worker''s screen is the King''s\s+to answer and nobody else''s'
        }

        It 'sends a decision written into a report to petition and states the test nowhere itself' {
            $script:Regency | Should -Match 'A decision\s+a worker \*wrote into its `report\.md`\* is a different case and no longer this one'
            $script:Regency | Should -Match '`petition`\s+owns whether you may answer that and by what test, and it is the only place the test is\s+stated'
            # The one-owner rule, asserted as absence: regency must not carry a second copy of the
            # test. A restatement here is exactly the drift statute forbids, and it would read as
            # authoritative to anyone who loaded regency without petition.
            $script:Regency | Should -Not -Match 'reversible in minutes'
        }

        It 'declares the change deliberate so history does not read as an accident' {
            $script:Regency | Should -Match '\*\*This rule changed deliberately, on the King''s own instruction'
            $script:Regency | Should -Match 'should read it as superseded rather\s+than as a rule that went missing'
            # The old bullet's own heading. Restoring the blanket rule brings this back with it,
            # and nothing else in the file would notice.
            $script:Regency | Should -Not -Match '\*\*Answering a question a worker asked\.\*\*'
        }

        It 'says plainly that the change bought no authority over the floors' {
            $script:Regency | Should -Match 'this bought no authority\s+at all over a land, a delete, a cost, or anything destructive, irreversible or security-sensitive'
        }

        # Keyed on how the worker parks, not on the gate that made it park. Every Done-means block
        # writes the same heading, so a `local-only` worker parks identically and the gate-only
        # wording left it matching no bullet at all.
        It 'carries the parked worker into the away-mode handling rather than leaving it unnamed' {
            $script:Regency | Should -Match '\*\*A worker is parked on a decision its brief did not settle\.\*\*'
            $script:Regency | Should -Match 'ended its turn, so nothing is hanging and nothing\s+is lost while you think'
            $script:Regency | Should -Match 'Every posture parks that way, so this is not only the gated ones'
            # Either way, matching petition and muster Step 6: a call that failed the test is
            # registered too, or the question survives only in the session that read it.
            $script:Regency | Should -Match 'Register it under `decree` either way - what you decided, or the question the\s+test left standing with him'
        }

        # The digest is session memory and the King's review of what was decided in his name cannot
        # be. The notes decree closed those decisions with are what a restart leaves behind.
        It 'rebuilds the decided-in-his-stead part of the digest from the durable notes' {
            $script:Regency | Should -Match 'Read those back from\s+the notes `decree` closed them with rather than from memory'
            $script:Regency | Should -Match 'a restart before he returns takes it with it, while the notes are still there'
        }

        # Two bullets both keyed on a decision in a report, and the broader one is read first: it
        # said to set the stage on the very worker the parked bullet says to leave mid-run, which
        # sends unfinished work to the landing gate. Only the parked bullet claims that case now.
        It 'the earlier unclear-worker bullet no longer claims a report decision as well' {
            $script:Regency | Should -Match '\*\*A worker finished and anything is unclear\*\* - scope drift, a result you cannot verify'
            $script:Regency | Should -Not -Match 'a decision in its `report\.md`, scope drift'
        }

        It 'puts what was decided in his stead, and on what basis, into the return digest' {
            $script:Regency | Should -Match '\*\*Every finding you decided in his stead,\s+with the reasoning and whether it rested on a recorded position or on your own judgement\*\*'
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
        $skills.Count | Should -Be 16 -Because 'fifteen skills plus setup, all project-local'
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

    It 'lists the four things a stall usually turns out to be' {
        Assert-Phrase -Text $script:StuckText -Where 'rally' `
            -Phrase '**Waiting for something that cannot arrive.**'
        Assert-Phrase -Text $script:StuckText -Where 'rally' `
            -Phrase '**A prompt the screen guard did not match.**'
        Assert-Phrase -Text $script:StuckText -Where 'rally' `
            -Phrase '**Genuinely slow work.**'
        Assert-Phrase -Text $script:StuckText -Where 'rally' `
            -Phrase '**Parked on a decision.**'
        Assert-Phrase -Text $script:StuckText -Where 'rally' `
            -Phrase ('That is the state working exactly as designed rather than a stall, it is ' +
                     'expected to last hours')
    }
}

Describe 'rally refuses to stop a worker that is only waiting on a decision' {
    # A parked worker is alive, idle, and its screen never moves again - the exact signature this
    # playbook reads as a stall. The ladder ends at relaunch, and relaunching one ends the process
    # the King's answer was going back to. So the discriminator runs before the ladder, off the
    # same two recorded values muster's landing and teardown floors read.
    BeforeAll { $script:ParkedStuck = Get-DocText $script:StuckMd }

    # Three consecutive rounds found the same defect here: rally carried its own copy of the park
    # test and each version dropped a different qualifier muster Step 6 carries - first that the
    # state existed at all, then what a null means, then the no-hold-covers-it clause. A fourth
    # qualifier would have bought a fourth round, so the copy is gone and the determination is
    # Step 6's. These assert the deletion as an absence, because that is what regresses.
    It 'carries no copy of the park test and defers the determination to muster Step 6' {
        Assert-Phrase -Text $script:ParkedStuck -Where 'rally' `
            -Phrase ('**Whether the worker in front of you is parked is `muster` Step 6''s ' +
                     'determination, and this playbook does not carry its own.**')
        Assert-Phrase -Text $script:ParkedStuck -Where 'rally' `
            -Phrase ('Step 6 owns the pointer, the hold, the archive line, the report read and ' +
                     'every qualifier on them, and nothing here repeats any part of that')
        foreach ($fragment in @(
            'waiting_on',                       # the pointer read
            'tasks-axi',                        # the hold lookup
            'done-archive.md',                  # the archive fallback
            'Get-Content "$env:KINGSHAND_HOME\data\<id>\report.md"'   # the report read
        )) {
            $script:ParkedStuck.Contains($fragment) |
                Should -BeFalse -Because "rally must not re-derive the park test: '$fragment' is Step 6's"
        }
        # The unguarded read that went with the copy. rally still names the report as the file that
        # outlives the worker, which is a different thing from reading it to classify one.
        @(Get-CodeFence $script:StuckMd | Where-Object { $_.Contains('report.md') }).Count |
            Should -Be 1 -Because 'the only report fence left is the Add-IndexEntry one'
        # The unqualified sentence that produced this round's finding, pinned as an absence.
        $script:ParkedStuck.Contains('the worker is parked too') |
            Should -BeFalse -Because 'rally must not decide parked-ness from a report it read itself'
    }

    It 'refuses before triaging, and keeps the refusal out of the ladder' {
        Assert-Phrase -Text $script:ParkedStuck -Where 'rally' `
            -Phrase ('Establish it there before triaging a stall and before steering, relaunching ' +
                     'or stopping anything.')
        Assert-Phrase -Text $script:ParkedStuck -Where 'rally' `
            -Phrase ('**The parked-worker check above comes before step 1.** A worker `muster` ' +
                     'Step 6 finds parked is not escalated at all while its process is alive')
    }

    It 'takes a live parked worker out of the playbook entirely' {
        Assert-Phrase -Text $script:ParkedStuck -Where 'rally' `
            -Phrase ('**A worker Step 6 finds parked is not touched by this playbook while its ' +
                     'process is alive.** Do not steer it, do not relaunch it, do not stop it, ' +
                     'and do not remove its worktree.')
    }

    # The refusal's stated harm is liveness-only ("that live process is holding a review gate
    # parked mid-run"), so a parked worker whose process is gone has no rung of the ladder that
    # fits it. A recovery route for that case was written and removed: three consecutive review
    # rounds each found one more interaction between its liveness fence, its order of operations
    # and the teardown floor. What is left is an escalation, and these pin it.
    It 'escalates a parked worker whose process is gone rather than recovering it' {
        Assert-Phrase -Text $script:ParkedStuck -Where 'rally' `
            -Phrase ('**A parked worker whose process is gone is not something this playbook ' +
                     'unblocks.**')
        Assert-Phrase -Text $script:ParkedStuck -Where 'rally' `
            -Phrase ('Getting it moving again means either discarding the unlanded work in its ' +
                     'worktree or answering the decision it parked on, and both of those belong ' +
                     'to the King rather than to a recovery step.')
        Assert-Phrase -Text $script:ParkedStuck -Where 'rally' `
            -Phrase ('So it is reported to him as a blocker, with the worktree, the branch and ' +
                     'every unlanded commit preserved untouched while he decides.')
        Assert-Phrase -Text $script:ParkedStuck -Where 'rally' `
            -Phrase ('Neither is a parked worker whose process is gone: no rung here can unblock ' +
                     'one, so it is reported as the rule above describes and its stage is left ' +
                     'alone.')
    }

    # Reporting it used to mean running step 5, and step 5 stamps `failed` on the record. That is
    # untrue here - the worker did not fail to build or fail to run the gate - and it destroys the
    # one thing the whole design exists to keep: the stage the worker was at when it parked, which
    # is why the pointer was made a field rather than a seventh stage. A cross-reference that was
    # not read to the end would have thrown that away.
    It 'reports the gone case without stamping the stage' {
        Assert-Phrase -Text $script:ParkedStuck -Where 'rally' `
            -Phrase '**Reporting it is all that happens to it, and the stage is not stamped.**'
        Assert-Phrase -Text $script:ParkedStuck -Where 'rally' `
            -Phrase ('step 5 sets the stage to `failed`, and that would be both untrue and ' +
                     'destructive here')
        Assert-Phrase -Text $script:ParkedStuck -Where 'rally' `
            -Phrase ('Destructive because the stage is the one record of what it was doing when ' +
                     'it parked, which is exactly the fact the pointer was made a field rather ' +
                     'than a seventh stage to preserve.')
        Assert-Phrase -Text $script:ParkedStuck -Where 'rally' -Phrase 'Leave the record as it stands.'
    }

    # The removed route's machinery, asserted as an absence, because re-deriving it is what
    # regresses: a liveness fence here has to tell "herdr could not be asked" from "nobody is
    # there" and then order itself against a teardown floor keyed on something else entirely.
    It 'carries no liveness fence and no replacement-worker path for the gone case' {
        foreach ($fragment in @(
            'Get-HerdrServerState',
            'Get-HerdrAgentInventory',
            'ConvertTo-HerdrAgentName',
            'GONE <worker id>',
            'Carry the open decision into the replacement''s brief'
        )) {
            $script:ParkedStuck.Contains($fragment) |
                Should -BeFalse -Because "the gone case is escalated, not proved and recovered ('$fragment')"
        }
    }

    It 'leaves the decision outstanding when the process is lost' {
        Assert-Phrase -Text $script:ParkedStuck -Where 'rally' `
            -Phrase '**Losing the process does not answer the decision.**'
        Assert-Phrase -Text $script:ParkedStuck -Where 'rally' `
            -Phrase ('`decree` owns that hold until it closes and `petition` owns who may answer ' +
                     'it - there is no second route to an answer here.')
    }

    It 'says plainly what relaunching or stopping a parked worker destroys' {
        Assert-Phrase -Text $script:ParkedStuck -Where 'rally' `
            -Phrase ('**Relaunching or stopping one destroys what the answer was coming back to.**')
        Assert-Phrase -Text $script:ParkedStuck -Where 'rally' `
            -Phrase ('End the process and the run can never be resumed, so the decision - once ' +
                     'somebody makes it')
        # The old absolute is what made this reachable, so it is narrowed where it was stated.
        $script:ParkedStuck.Contains('stopping is always safe') |
            Should -BeFalse -Because 'stopping a parked worker is not safe, and the sentence said it was'
        Assert-Phrase -Text $script:ParkedStuck -Where 'the removal hazard' `
            -Phrase '**Stopping is not free in every direction, though.**'
    }

    It 'cross-references the owners rather than restating them' {
        Assert-Phrase -Text $script:ParkedStuck -Where 'rally' `
            -Phrase ('`muster` Step 6 owns the route an answer takes back into the worker, and ' +
                     '`petition` owns who may answer it and by what test. Neither is restated here.')
        $script:ParkedStuck.Contains('reversible in minutes') |
            Should -BeFalse -Because 'the reversibility test is stated once, in petition'
    }
}

Describe 'the parked-decision record states what must not be undone' {
    # The rationale for the field, the missing clearing verb and the replaced report heading is
    # narrative, so it lives here rather than being paid for on every muster load. What it has to
    # survive carrying is the set of reversals a later editor would otherwise make while tidying:
    # a seventh stage, a clearing verb, the state back in the report, and the reversibility test
    # softened into a knowledge test.
    BeforeAll {
        $script:ParkedDoc = Get-DocText (Join-Path $script:Root 'docs\2026-09-04-parked-decision-route.md')
    }

    It 'says why a condition is not a stage' {
        Assert-Phrase -Text $script:ParkedDoc -Where 'the parked-decision record' `
            -Phrase ('Waiting for a decision is not a position in that lifecycle; it is a ' +
                     'condition that can happen at any of them')
        Assert-Phrase -Text $script:ParkedDoc -Where 'the parked-decision record' `
            -Phrase ('destroying the one fact most needed when the answer comes back: what the ' +
                     'worker was doing before it parked')
    }

    It 'keeps the clearing verb refused, from both directions' {
        Assert-Phrase -Text $script:ParkedDoc -Where 'the parked-decision record' `
            -Phrase ('`Set-CrewWaitingOn` sets the field. Nothing clears it, and no function to ' +
                     'clear it may be added.')
        Assert-Phrase -Text $script:ParkedDoc -Where 'the parked-decision record' `
            -Phrase ('either the question is lost or already-delivered work is refused and the ' +
                     'King is asked the same thing twice')
        Assert-Phrase -Text $script:ParkedDoc -Where 'the parked-decision record' `
            -Phrase ('**a null means no park has been recorded on this record - never that there ' +
                     'is nothing to answer**')
    }

    It 'records the review history that condemned the report heading' {
        Assert-Phrase -Text $script:ParkedDoc -Where 'the parked-decision record' `
            -Phrase ('every review round turned up one more shape nobody had listed - an empty ' +
                     'section, a worker parked twice, an answer with no record')
        Assert-Phrase -Text $script:ParkedDoc -Where 'the parked-decision record' `
            -Phrase ('A field has no shapes.')
        Assert-Phrase -Text $script:ParkedDoc -Where 'the parked-decision record' `
            -Phrase ('**Putting the state back into the report is a reversal, not a tidy-up.**')
    }

    It 'names both irreversible floors and why the archive line and the anchor are in them' {
        Assert-Phrase -Text $script:ParkedDoc -Where 'the parked-decision record' `
            -Phrase ('**A worker whose pointer names a hold that is still open is never landed.**')
        Assert-Phrase -Text $script:ParkedDoc -Where 'the parked-decision record' `
            -Phrase ('**A worker whose pointer names a hold that is still open is never torn ' +
                     'down**, and a confirmed push does not release that.')
        Assert-Phrase -Text $script:ParkedDoc -Where 'the parked-decision record' `
            -Phrase ('Drop the archive line and a decision answered long enough ago to have been ' +
                     'pruned reads as one nobody ever made.')
        Assert-Phrase -Text $script:ParkedDoc -Where 'the parked-decision record' `
            -Phrase ('Both mistakes were made and fixed during the change; neither is theoretical.')
    }

    # Two things a later editor would otherwise "tidy" back into the shape this arrangement was
    # reached by fixing: rally growing its own park test again, and the liveness scope on rally's
    # refusal being read as an oversight and tightened into the strand it was written to end.
    It 'records that rally refuses without carrying its own park test' {
        Assert-Phrase -Text $script:ParkedDoc -Where 'the parked-decision record' `
            -Phrase ('`rally` refuses; it does not carry its own test for whether a worker is ' +
                     'parked, and a version of it that grows one is drifting back toward the ' +
                     'three rounds of dropped qualifiers that produced this arrangement.')
    }

    # The note previously said "the refusal is scoped to a live process" directly under the
    # two-floor list, which read as though the floors carried that scope too - they do not, and
    # Step 8b states no liveness condition at all. The two protect different things, so the note
    # says which is which rather than leaving a later editor to reconcile them the wrong way.
    It 'records why the floors and rally''s refusal are scoped differently' {
        Assert-Phrase -Text $script:ParkedDoc -Where 'the parked-decision record' `
            -Phrase ('**The two floors above and `rally`''s refusal are scoped differently, and ' +
                     'that is deliberate rather than an inconsistency to reconcile.** They do not ' +
                     'protect the same thing.')
        Assert-Phrase -Text $script:ParkedDoc -Where 'the parked-decision record' `
            -Phrase ('`rally`''s refusal protects the live process holding a parked review-gate ' +
                     'run, so liveness is exactly its condition.')
        Assert-Phrase -Text $script:ParkedDoc -Where 'the parked-decision record' `
            -Phrase ('**The landing and teardown floors protect the worktree and the unlanded ' +
                     'work inside it, so they are keyed on the hold and never on liveness.**')
        Assert-Phrase -Text $script:ParkedDoc -Where 'the parked-decision record' `
            -Phrase ('A dead parked worker still has unlanded work and an open question, so ' +
                     'tearing it down discards the first while the second is unresolved')
        # And the recovery still finishes, so nobody needs to bend the floor to make it work.
        Assert-Phrase -Text $script:ParkedDoc -Where 'the parked-decision record' `
            -Phrase ('the hold closes when it is answered, and the floor stops barring teardown ' +
                     'at that point because it was keyed on the hold all along')
        Assert-Phrase -Text $script:ParkedDoc -Where 'the parked-decision record' `
            -Phrase ('Nothing here makes a parked worker with unlanded work easier to tear down.')
        # And what the liveness-scoped refusal leaves behind is escalated, not recovered. The note
        # records that a recovery route was tried and removed, so a later editor reaching for one
        # finds the reason rather than the gap.
        Assert-Phrase -Text $script:ParkedDoc -Where 'the parked-decision record' `
            -Phrase ('**A parked worker whose process is gone is escalated rather than recovered**')
        Assert-Phrase -Text $script:ParkedDoc -Where 'the parked-decision record' `
            -Phrase ('`rally` reports it as a blocker with the worktree, the branch and the ' +
                     'unlanded work preserved untouched, and carries no recovery route of its own.')
        Assert-Phrase -Text $script:ParkedDoc -Where 'the parked-decision record' `
            -Phrase ('it needed a liveness fence, an order of operations against the teardown ' +
                     'floor and a replacement-worker path')
    }

    # Step 8b's floor is what the paragraph above describes, so the two are pinned together: if
    # anyone scopes the floor to liveness the note stops matching the skill.
    It 'keeps the teardown floor unconditional on liveness' {
        $step8b = Get-MusterStep 'Step 8b'
        Assert-Phrase -Text $step8b -Where 'muster Step 8b' `
            -Phrase ('**A worker whose pointer names a hold that is still open is never torn down ' +
                     'either, and a confirmed push does not release that.**')
        foreach ($fragment in @('Get-HerdrAgentInventory', 'Get-HerdrServerState')) {
            $step8b.Contains($fragment) |
                Should -BeFalse -Because "the teardown floor is keyed on the hold, not on liveness ('$fragment')"
        }
    }

    It 'quotes the reversibility test and names the mis-statement to refuse' {
        Assert-Phrase -Text $script:ParkedDoc -Where 'the parked-decision record' `
            -Phrase '**The test is reversibility, not knowledge.**'
        Assert-Phrase -Text $script:ParkedDoc -Where 'the parked-decision record' `
            -Phrase ('**Decide it** - away or present, discussed or not - when the call is ' +
                     'reversible in minutes and is')
        Assert-Phrase -Text $script:ParkedDoc -Where 'the parked-decision record' `
            -Phrase ('The mis-statement to refuse by name is "answer only what you know".')
        # The quote is a record of what must not be reworded, and it says so - the rule itself is
        # still stated in exactly one place.
        Assert-Phrase -Text $script:ParkedDoc -Where 'the parked-decision record' `
            -Phrase ('`petition` states the test and is the only place it is stated.')
    }

    It 'keeps the prohibition on a worker opening an interactive prompt' {
        Assert-Phrase -Text $script:ParkedDoc -Where 'the parked-decision record' `
            -Phrase ('Every brief forbids the worker from opening an interactive question, and ' +
                     'parking does not relax it.')
        Assert-Phrase -Text $script:ParkedDoc -Where 'the parked-decision record' `
            -Phrase ('a worker sitting on a prompt has no pointer set and reads as an ordinary ' +
                     'blocked worker')
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

Describe 'the prompt-box record is the tracked owner of why the guard is shaped this way' {
    # The investigation that produced this lives under data\, which no other clone has. Everything a
    # future editor needs to avoid re-opening the hole - the glyph pair, the named placeholder list,
    # the fail-open direction and the captured render the fixtures copy - has to survive here.
    BeforeAll { $script:BoxDoc = Get-DocText (Join-Path $script:Root 'docs\2026-09-02-prompt-box-safety.md') }

    It 'says why the guard sits on the send paths rather than the input side' {
        Assert-Phrase -Text $script:BoxDoc -Where 'the prompt-box record' `
            -Phrase ('It cannot concatenate onto anything - the first typed character displaces it ' +
                     '- so text arriving at the box is never at risk of being mixed with it.')
        Assert-Phrase -Text $script:BoxDoc -Where 'the prompt-box record' `
            -Phrase '**Refuse, never clear.**'
    }

    It 'keeps the glyph pair that separates the box from a menu row' {
        Assert-Phrase -Text $script:BoxDoc -Where 'the prompt-box record' `
            -Phrase ('The box line is drawn as the caret `' + [char]0x276F + '` (U+276F) followed ' +
                     'by U+00A0. The highlighted row of a numbered option menu is drawn with the ' +
                     '**same caret** followed by a plain space.')
        Assert-Phrase -Text $script:BoxDoc -Where 'the prompt-box record' `
            -Phrase 'Match the caret alone and every worker blocked on a menu becomes unanswerable.'
    }

    It 'keeps the placeholder exclusion a named list rather than an emptiness test' {
        Assert-Phrase -Text $script:BoxDoc -Where 'the prompt-box record' `
            -Phrase ('**It is deliberately not the general rule "the underlying value is empty, so ' +
                     'Enter submits nothing".**')
        Assert-Phrase -Text $script:BoxDoc -Where 'the prompt-box record' `
            -Phrase 'Refusing an unknown string is the safe direction; letting one through is not.'
    }

    It 'states the two opposite failure directions and why they are not an inconsistency' {
        Assert-Phrase -Text $script:BoxDoc -Where 'the prompt-box record' `
            -Phrase 'This detector fails open, and the stall signal fails closed'
        Assert-Phrase -Text $script:BoxDoc -Where 'the prompt-box record' `
            -Phrase 'A pane too narrow to render must not make a worker unsteerable.'
    }

    It 'names the environment variable and why it beats the settings key' {
        Assert-Phrase -Text $script:BoxDoc -Where 'the prompt-box record' `
            -Phrase '`CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=0` is set on the pane'
        Assert-Phrase -Text $script:BoxDoc -Where 'the prompt-box record' `
            -Phrase ('**The environment check is the first branch of the harness''s resolver**')
        Assert-Phrase -Text $script:BoxDoc -Where 'the prompt-box record' `
            -Phrase 'writing it into a worktree''s `settings.local.json` may do nothing at all'
    }

    # The fixtures in Herdr.Tests.ps1 are copied off a capture under data\, so a clone without that
    # directory has only this reproduction to check them against.
    It 'reproduces the captured render the fixtures are built from' {
        Assert-Phrase -Text $script:BoxDoc -Where 'the prompt-box record' `
            -Phrase 'a bare U+2500 rule, the caret and U+00A0 and the text at column 0, then another rule'
        Assert-Phrase -Text $script:BoxDoc -Where 'the prompt-box record' `
            -Phrase ('`<U+00A0>` below stands for the no-break space that is really there')
    }
}

# The largest measured block of review waste in this system's own history was not defects the review
# gate should have caught earlier - it was two mechanisms hand-written to read an open-ended text
# format, where there is no round after which the mechanism is finished. Six consecutive rounds on a
# path parser, about ten on a hand-rolled Markdown renderer, every round in both finding real
# defects. And one rebuild on a gate built to a brief's literal words against an installation state
# nobody checked. The two rules below are the front end of that: they fire before a line is written,
# and they are pinned here because they live in prose and nothing else would notice them going.
Describe 'a brief settles the mechanism questions that have no last review round' {
    BeforeAll {
        # Step 2 is the only place the Hand reads while writing a brief, so these rules are
        # asserted at that step rather than anywhere in the file.
        $script:MusterStep2 = Get-MusterRegion -FromHeading 'Step 2 - Write a brief' `
            -ToHeading 'Step 3 - Gate one'
    }

    # The biggest block of waste in the evidence, and the one rule here that pays for itself on its
    # own. Both instances were correct at every round; what was wrong was that the mechanism had no
    # last round. Deleting this rule is what lets the next parser be written. The rule has to carry
    # its answer as well as its prohibition - "do not hand-roll this" with no alternative beside it
    # is a requirement a worker cannot deliver.
    It 'states the open-ended-input answer as a decision, not as another case to enumerate' {
        Assert-Phrase -Text $script:MusterStep2 -Where 'muster Step 2' `
            -Phrase '**Never leave a worker to hand-write something that reads an open-ended text format.**'
        Assert-Phrase -Text $script:MusterStep2 -Where 'muster Step 2' `
            -Phrase ('say so in `Requirements` rather than leaving the worker to find out at round ' +
                     'six, and say what to do about it: take an existing library, or change the ' +
                     'requirement so the input is not open-ended')
    }

    # Both numbers are hedged to what the evidence carries: the parser's six is exact, the renderer's
    # ten is recorded as `~10`, and the correctness claim holds per round in both records where only
    # the parser's holds per finding. The point the clause has to keep is that the rounds were not
    # spent on false findings - the mechanism was the problem.
    It 'Step 2 keeps the sixteen rounds behind the open-ended-input rule' {
        Assert-Phrase -Text $script:MusterStep2 -Where 'muster Step 2' `
            -Phrase 'cost about 16 review rounds between them, every round in both finding real defects'
        Assert-Phrase -Text $script:MusterStep2 -Where 'muster Step 2' `
            -Phrase 'there is no round after which the parser is finished'
        Assert-Phrase -Text $script:MusterStep2 -Where 'muster Step 2' `
            -Phrase 'enumerating is what ends both, by showing the list has no end'
    }

    # The index gate is the one instance that is not a thinking failure at all: the brief asserted
    # a fact about the live installation and the fact was wrong. Hard rule 1 splits the check in
    # two, and the split is the rule - without it this reads as licence for the Hand to go looking
    # inside a project itself.
    It 'Step 2 makes a requirement that names a mechanism carry the fact it rests on' {
        Assert-Phrase -Text $script:MusterStep2 -Where 'muster Step 2' `
            -Phrase '**A requirement that names a mechanism carries the fact it rests on.**'
        Assert-Phrase -Text $script:MusterStep2 -Where 'muster Step 2' `
            -Phrase 'would have refused nothing, ever'
        Assert-Phrase -Text $script:MusterStep2 -Where 'muster Step 2' `
            -Phrase 'hard rule 1 says a worker checks it, so write the requirement as a premise to verify before building to it'
    }
}

# A third of the findings measured across six dispatches were criteria the reviewer was always
# going to apply and no brief ever stated - and the single biggest block of waste was not findings
# at all, but ten rounds of correct findings inside a design nobody questioned. These pin the two
# answers: a per-project list the brief pastes in and the worker checks itself against, and a
# tripwire that reports the third round without ever stopping the fixing.
Describe 'a project has a standing definition of done, and repeated findings are reported not capped' {
    BeforeAll {
        $script:CritStep2 = Get-MusterRegion -FromHeading 'Step 2 - Write a brief' `
            -ToHeading 'Step 3 - Gate one'
        $script:CritStep6 = Get-MusterStep 'Step 6 - Completion'
        # The brief template is the one fence carrying both the Goal and the Done-means headings,
        # and it is read raw because the assertion below is about the order of its sections.
        $script:CritTemplate = @(Get-CodeFence $script:MusterMd |
            Where-Object { $_.Contains('## Goal') -and $_.Contains('## Done means') })
        # And normalised for everything else in it, so a sentence stays found when it is re-wrapped.
        $script:CritTemplateText = if ($script:CritTemplate.Count -eq 1) {
            ConvertTo-NormalisedText $script:CritTemplate[0]
        } else { '' }
        $script:CritDoneBlocksRaw = @(Get-CodeFence $script:MusterMd |
            Where-Object { $_.Contains("Implemented and committed on this worktree's branch.") })
        $script:CritDoneBlocks = @($script:CritDoneBlocksRaw |
            ForEach-Object { ConvertTo-NormalisedText $_ })
    }

    # The section has to sit in the brief, not in this skill: the worker reads one artefact and this
    # file is not it. Its position is pinned because the criteria are what the Done-means line sends
    # the worker back to, and a section below that line is one it works after the gate has run.
    It 'the brief template carries the Standing criteria slot between Unchanged and Done means' {
        $script:CritTemplate.Count |
            Should -Be 1 -Because 'the brief template is one fence and the worker gets what it says'
        $t = $script:CritTemplate[0]
        $t.Contains('## Standing criteria') |
            Should -BeTrue -Because 'the pasted criteria need a slot in the artefact the worker reads'
        $t.IndexOf('## Unchanged') | Should -BeLessThan $t.IndexOf('## Standing criteria')
        $t.IndexOf('## Standing criteria') | Should -BeLessThan $t.IndexOf('## Done means')
    }

    # A decision file does not load itself into a worker's session; a worker sees exactly one thing,
    # its brief. So both, and for different reasons - which is the part an editor trimming one of
    # them would undo.
    It 'Step 2 names the file, pastes it, and delivers the copy as well' {
        Assert-Phrase -Text $script:CritStep2 -Where 'muster Step 2' `
            -Phrase '**Paste the project''s standing criteria into the brief.**'
        Assert-Phrase -Text $script:CritStep2 -Where 'muster Step 2' `
            -Phrase ('`$env:KINGSHAND_HOME\data\done-<project>.md` - one `-` bullet per criterion, ' +
                     'each naming how it is checked')
        Assert-Phrase -Text $script:CritStep2 -Where 'muster Step 2' `
            -Phrase ('paste its lines into `## Standing criteria` unchanged, and hand the ' +
                     'same file to `-ReadPath` at Step 4')
        Assert-Phrase -Text $script:CritStep2 -Where 'muster Step 2' `
            -Phrase ('the paste is in the artefact the worker is judged against, so it is what gets ' +
                     'complied with, and the copy is what a mid-task re-read reaches')
    }

    # Keyed on what the file holds, not on whether it exists: the fold-back's retire branch can take
    # a file down to its last line, and an existing-but-empty file falls outside a rule that asks
    # only whether one is there - so the brief pastes a blank section and the worker cannot tell it
    # from one it forgot to work, which is the ambiguity `round 1: no findings` closed on the other
    # half of the report.
    It 'an empty list is written down rather than the section being dropped' {
        Assert-Phrase -Text $script:CritStep2 -Where 'muster Step 2' `
            -Phrase ('Where the file holds no criteria - it does not exist yet, or the fold-back ' +
                     'has retired its last line - write `- Nothing standing for this ' +
                     'project yet.` rather than dropping the section')
        Assert-Phrase -Text $script:CritStep2 -Where 'muster Step 2' `
            -Phrase ('Key that on what the file holds and never on whether it exists')
        Assert-Phrase -Text $script:CritStep6 -Where 'muster Step 6' `
            -Phrase ('Where that was the file''s last line, leave `- Nothing standing for this ' +
                     'project yet.` in its place rather than an empty file')
    }

    # The placeholder is a `-` bullet inside the section, so the self-check works it line by line and
    # the only answer available is `n/a`. Without this carve-out that `n/a` trips the wording-problem
    # clause on every gateless dispatch until a criteria file exists - and the paragraph it sits in
    # then talks about rewording a line in a file that does not exist.
    It 'the placeholder is not read as a criterion that needs rewording' {
        Assert-Phrase -Text $script:CritStep6 -Where 'muster Step 6' `
            -Phrase ('A section whose only line is `- Nothing standing for this project yet.` is ' +
                     'neither: there was nothing to check, the `n/a` against it is the only answer ' +
                     'available, and it is not a criterion to reword or a reason to create the file')
    }

    # That carve-out says "only line", and the retire branch can leave the placeholder as a file's
    # last line - so an add that joined it rather than replacing it would put the carve-out out of
    # reach and send the Hand to reword a placeholder on every dispatch from then on, which no
    # rewording can make checkable.
    It 'the first real criterion replaces the placeholder rather than joining it' {
        Assert-Phrase -Text $script:CritStep6 -Where 'muster Step 6' `
            -Phrase ('Where the file holds only `- Nothing standing for this project yet.`, the ' +
                     'first real criterion replaces that line rather than joining it')
        Assert-Phrase -Text $script:CritStep6 -Where 'muster Step 6' `
            -Phrase ('a file holding both says two contradictory things and leaves every future ' +
                     'worker working a line it can only record `n/a` against')
    }

    # One line form, stated once. The fold-back writes this file and the next brief pastes it back
    # `unchanged`, so a second form described anywhere leaves the paste step renumbering a file it
    # was told not to touch - or dropping it. The empty-case placeholder is already a `-` bullet,
    # which is what settles which form wins.
    It 'the criteria line form is stated once and never contradicted' {
        Assert-Phrase -Text $script:CritStep2 -Where 'muster Step 2' `
            -Phrase ('that one form is what every line of that file takes wherever it is written ' +
                     'or read')
        Assert-Phrase -Text $script:CritStep6 -Where 'muster Step 6' `
            -Phrase 'in that file''s one form of a `-` bullet naming how it is checked'
        $whole = Get-DocText $script:MusterMd
        $whole.Contains('numbered lines of `data\done-<project>.md`') |
            Should -BeFalse -Because 'a second line form is what makes the unchanged paste impossible'
        $whole.Contains('paste its numbered lines') |
            Should -BeFalse -Because 'the fold-back writes bullets, so the paste cannot expect numbers'
    }

    # The dispatcher refuses a brief whose `Read first` names a file that is not there, and no
    # project has one of these files yet - so a Hand that reads the paste-and-copy instruction
    # without this exception spends a dispatch discovering it, every time, until the first one
    # exists.
    # The criteria file goes to -ReadPath on every brief for a project that has one, and the
    # dispatcher's index gate refuses only when no path was passed - so counting it would open that
    # gate permanently for exactly the projects furthest along. Dispatch-Worker.Tests.ps1 owns the
    # enforcement; this pins that the Hand is told the same thing the code does.
    It 'the standing files are said not to discharge the index obligation' {
        Assert-Phrase -Text $script:CritStep2 -Where 'muster Step 2' `
            -Phrase '**The project''s own two standing files do not discharge this.**'
        Assert-Phrase -Text $script:CritStep2 -Where 'muster Step 2' `
            -Phrase ('dispatch knows it, discounting `done-<project>.md` and `rules-<project>.md` ' +
                     'from the paths that satisfy this refusal')
        Assert-Phrase -Text $script:CritStep2 -Where 'muster Step 2' `
            -Phrase ('Where it is the only file this task touches, a line about the index still ' +
                     'goes in the section beside it')
    }

    # The literal line the refusal quotes says there is nothing beyond the brief, which is false in
    # the one case this discount creates - the bullet above it hands the worker a file. A worker
    # reading both may skip the copy, which is the mid-task re-read the copy exists for.
    # Dispatch-Worker.Tests.ps1 runs the paraphrase against the real gate; this pins that muster
    # gives it rather than sending the Hand to the contradicting line.
    It 'the criteria-only case gets a line that does not contradict the file beside it' {
        Assert-Phrase -Text $script:CritStep2 -Where 'muster Step 2' `
            -Phrase ('but not the literal one above, which would tell the worker there is nothing ' +
                     'beyond the brief in the same breath as handing it a file to read')
        Assert-Phrase -Text $script:CritStep2 -Where 'muster Step 2' `
            -Phrase ('- The index was checked; nothing in it applies to this task beyond the ' +
                     'standing criteria above.')
    }

    It 'the empty case hands the dispatcher no path to refuse' {
        Assert-Phrase -Text $script:CritStep2 -Where 'muster Step 2' `
            -Phrase ('write no `Read first` line for it and pass no `-ReadPath` for it either, ' +
                     'because Step 4 refuses a brief naming a file that is not there')
    }

    # The empty case is the one a Hand starts believing. Step 6's fold-back writes this file the
    # first time a gate finding generalises, so any count of how many projects have one is false
    # from that turn - and false in the direction where the criteria just recorded never reach the
    # next worker, which is the loop this whole change exists to close.
    It 'the read is unconditional and no absence is carried forward' {
        Assert-Phrase -Text $script:CritStep2 -Where 'muster Step 2' `
            -Phrase ('Read the file every time even so, and never carry an absence forward from ' +
                     'the last brief you wrote')
        Assert-Phrase -Text $script:CritStep2 -Where 'muster Step 2' `
            -Phrase ('a project with nothing standing today has criteria the next dispatch is ' +
                     'expected to meet')
    }

    # The file is a standing list and the brief is this task's instruction, so the brief has to win
    # or a worker deciding for itself picks wrong half the time. The intent string is the other half:
    # a criterion broken silently is what the review gate raises a finding about.
    It 'the brief wins over the standing file, and the exception is named in the intent string' {
        Assert-Phrase -Text $script:CritStep2 -Where 'muster Step 2' `
            -Phrase ('say so in `Requirements` or `Unchanged` and in the `Intent` section the gate ' +
                     'is handed - the brief wins over the file')
    }

    # The Hand writes the brief and the worker writes the gate's intent string, so a set-aside the
    # Hand records has to travel through a slot in the brief or it never reaches the gate at all -
    # it condenses the Goal, the criterion looks broken for no stated reason, and the gate raises
    # the finding the rule exists to prevent. Both gated blocks have to point at the same slot.
    It 'what the intent string must carry has a slot the worker is handed' {
        $t = $script:CritTemplate[0]
        $t.Contains('## Intent') |
            Should -BeTrue -Because 'the Hand needs somewhere to write what the gate is told'
        $t.IndexOf('## Standing criteria') | Should -BeLessThan $t.IndexOf('## Intent')
        $t.IndexOf('## Intent') | Should -BeLessThan $t.IndexOf('## Done means')
        $script:CritTemplateText.Contains('plus every settled decision and standing criterion this task sets aside, and why - this is the string the gate is given verbatim') |
            Should -BeTrue -Because 'a slot that only repeats the Goal changes nothing'

        $gated = @($script:CritDoneBlocks | Where-Object { $_.Contains('no-mistakes axi run') })
        $gated.Count | Should -Be 2 -Because 'only the two no-mistakes blocks invoke the gate'
        foreach ($block in $gated) {
            $block.Contains("--intent '<the ``Intent`` section above, verbatim on one line>'") |
                Should -BeTrue -Because 'the worker passes the section rather than reconstructing it'
        }
        Assert-Phrase -Text $script:CritStep2 -Where 'muster Step 2' `
            -Phrase ('You write that string, not the worker: it is the `Intent` section of the ' +
                     'brief, and the two `no-mistakes` blocks hand it to the gate verbatim')
    }

    # The section is specified to carry settled decisions and criteria, and this repository names
    # every file, mode and posture in backticks - so the string it is pasted into decides whether
    # the gate reads a sentence or a fragment. In a double-quoted PowerShell string a backtick
    # escapes the next character and a double quote ends the argument, both silently.
    It 'the gate is handed the intent in a string that survives backticks' {
        $gated = @($script:CritDoneBlocks | Where-Object { $_.Contains('no-mistakes axi run') })
        $gated.Count | Should -Be 2
        foreach ($block in $gated) {
            $block.Contains('--intent "') |
                Should -BeFalse -Because 'a double-quoted string eats the backticks the section uses'
            $block.Contains('in a double-quoted PowerShell string a backtick escapes the character after it') |
                Should -BeTrue -Because 'the next editor has to know why the quotes are single'
            $block.Contains('Run the line in PowerShell and double any single quote inside the section') |
                Should -BeTrue -Because 'that is the one character a literal string still breaks on'
            $block.Contains('in a POSIX shell the same two characters close and reopen the string, so the apostrophe is deleted instead') |
                Should -BeTrue -Because 'a worker with both shells needs to know which one the rule assumes'
        }
    }

    # In all four, because the criteria only ever mattered as something the worker is made to work
    # through. The count stays four - per-project content inside these blocks would multiply them.
    # The trigger names delivery generically: `direct-PR` neither runs a gate nor stops on the
    # branch, so a two-clause trigger left the one mode whose next bullet opens a pull request
    # describing no moment at all.
    It 'all four Done-means blocks make the worker work the list before it delivers' {
        $script:CritDoneBlocks.Count | Should -Be 4
        foreach ($block in $script:CritDoneBlocks) {
            $block.Contains('Before you deliver - before you invoke the gate, push, open a pull request, or stop on the branch - work the `Standing criteria` section above line by line and record the result in `report.md`') |
                Should -BeTrue -Because 'every mode has to recognise its own delivery act here'
            $block.Contains('`pass` with what you checked, `fixed` with what you changed, or `n/a` with the reason') |
                Should -BeTrue -Because 'a recorded result is what the Hand compares against the findings'
            $block.Contains('A criterion you cannot check is a criterion to report, not to skip.') |
                Should -BeTrue -Because 'an unreportable skip is how the self-check becomes a formality'
        }
    }

    # The criteria are pasted `unchanged`, so a criterion this task sets aside arrives in the
    # section looking exactly like one to implement. "The brief wins over the file" is stated in
    # this skill, which the worker never reads - the precedence has to travel in the one bullet the
    # worker executes, or it works the list line by line and ships the change `Unchanged` forbade.
    It 'the worker is told a brief set-aside overrides a pasted criterion' {
        foreach ($block in $script:CritDoneBlocks) {
            $block.Contains('Where `Requirements` or `Unchanged` sets a criterion aside, this brief overrides that line: record it `n/a` naming the brief line that set it aside, and do not implement it.') |
                Should -BeTrue -Because 'precedence has to reach the artefact the worker is judged against'
        }
    }

    # "Before you invoke the gate" is what the bullet says; where the bullet sits is what a worker
    # working the list top-down actually does. Below the delivery bullets it self-checks code it has
    # already gated, pushed or opened a pull request against - a criterion it then records `fixed`
    # is a commit the delivered PR does not contain, and on a gated block it records `pass` on a
    # criterion the gate itself had just caught, which sends Step 6 off to reword a working line.
    # Asserted on all four blocks by position rather than on the two with a gate: the bullet is
    # copied four times, and the last round repositioned two of them and left two.
    It 'the self-check is the second bullet of every Done-means block' {
        $script:CritDoneBlocksRaw.Count |
            Should -Be 4 -Because 'one Done-means block per delivery mode'
        foreach ($block in $script:CritDoneBlocksRaw) {
            $bullets = @($block -split "`n" | Where-Object { $_ -match '^- ' })
            $bullets[0] | Should -BeLike "- Implemented and committed on this worktree's branch.*" `
                -Because 'there is nothing to check until the work exists'
            $bullets[1] | Should -BeLike '- Before you deliver*' `
                -Because 'every bullet below this one delivers, gates or stops the work'
        }
    }

    # "Identical but for the third line" was true until a bullet was inserted above it, and then it
    # pointed at the gate-run bullet - a Hand substituting $ci.briefLine where the prose said would
    # have dropped `no-mistakes axi run` out of the brief entirely. Asserted against Ci.psm1's own
    # output rather than an ordinal or a sentence: the two blocks must differ in exactly the line
    # that function computes, and in nothing else, which is what the prose claims and what makes
    # taking it from Step 1b safe.
    It 'the two gated blocks differ only in the line Ci.psm1 computes' {
        Import-Module "$PSScriptRoot\..\bin\Ci.psm1" -Force
        $gated = @($script:CritDoneBlocks | Where-Object { $_.Contains('no-mistakes axi run') })
        $gated.Count | Should -Be 2 -Because 'only the two no-mistakes blocks invoke the gate'

        $hasCi = ConvertTo-NormalisedText (Get-CiBriefLine -Status 'has-ci')
        $noCi  = ConvertTo-NormalisedText (Get-CiBriefLine -Status 'no-ci')
        $withHasCi = @($gated | Where-Object { $_.Contains($hasCi) })
        $withNoCi  = @($gated | Where-Object { $_.Contains($noCi) })
        $withHasCi.Count | Should -Be 1 -Because 'one block carries the has-ci line Step 1b computes'
        $withNoCi.Count  | Should -Be 1 -Because 'the other carries the terminating line'

        $withHasCi[0].Replace($hasCi, '') | Should -Be $withNoCi[0].Replace($noCi, '') `
            -Because 'identical but for that line is what lets the Hand swap one for the other'
    }

    # And the prose names it by its text, so the next bullet inserted above it cannot restale the
    # reference the way an ordinal was.
    It 'the prose names that line by its text rather than its position' {
        Assert-Phrase -Text $script:CritStep2 -Where 'muster Step 2' `
            -Phrase 'Identical but for the `Drive the pipeline` line'
        Assert-Phrase -Text $script:CritStep2 -Where 'muster Step 2' `
            -Phrase 'That `Drive the pipeline` line is `$ci.briefLine` from Step 1b'
        $script:CritStep2.Contains('Identical but for the third line') |
            Should -BeFalse -Because 'an ordinal goes stale the moment a bullet is inserted above it'
    }

    # Three rounds in one component and three failed fixes on one bug are the same signal reached
    # from two directions, and the rule was stated in three places before this. Per component, not
    # per run: three rounds spread across three areas is ordinary convergence.
    It 'the tripwire trigger counts failed fix attempts as well as rounds in one component' {
        $script:CritTemplateText.Contains('On the third round of findings in one component, or the third failed attempt at one bug') |
            Should -BeTrue -Because 'both halves of the trigger reach the worker or neither does'
        Assert-Phrase -Text $script:CritStep2 -Where 'muster Step 2' `
            -Phrase ('Its trigger counts failed fix attempts on one bug as well as rounds of ' +
                     'findings in one component, because three failed fixes is not a failed ' +
                     'hypothesis, it is the wrong architecture')
    }

    # The load-bearing assertion of the whole tripwire. `emgee-agent-crawlable` ran about ten rounds
    # and found genuine defects in every one, so a rule that stopped the fixing at three would have
    # shipped them - the tripwire's only permitted action is to write and report. Delete the clause
    # and the rule silently becomes a cap.
    It 'the tripwire never stops the fixing' {
        $script:CritTemplateText.Contains('**carry on fixing every finding as normal.** Nothing here caps the rounds or lets you stop early.') |
            Should -BeTrue -Because 'the worker is told to keep fixing at the moment it counts three'
        Assert-Phrase -Text $script:CritStep2 -Where 'muster Step 2' `
            -Phrase ('never soften **carry on fixing every finding as normal** into permission to ' +
                     'stop, and never put a round limit beside it')
        Assert-Phrase -Text $script:CritStep2 -Where 'muster Step 2' `
            -Phrase 'a rule that stopped the fixing at three would have shipped every one of them'
        Assert-Phrase -Text $script:CritStep6 -Where 'muster Step 6' `
            -Phrase 'It is never a reason to have capped the fixing.'
    }

    It 'the tripwire reports the tally and the design question, in the report and in the message' {
        $t = $script:CritTemplateText
        $t.Contains('Additionally write into `report.md` the tally, what each round or attempt found, and the design question: what keeps producing them') |
            Should -BeTrue -Because 'a tally with no design question beside it is just a number'
        $t.Contains('Say it in your final message too, so it arrives as a finding rather than a completion notice.') |
            Should -BeTrue -Because 'a report nobody is told to read arrives after the Hand has moved on'
    }

    # Item 2 fires on either trigger, and on the gateless majority of the fleet only the second one
    # can: there are no rounds to count. Written up in round-and-component terms alone, item 3 asks
    # a gateless worker for a record item 1 just told it never to keep, and the design question the
    # tripwire exists to surface never leaves the worktree - while Step 6, which names both
    # triggers, is looking for it.
    It 'the write-up covers the failed-attempt trigger, not rounds alone' {
        $t = $script:CritTemplateText
        $t.Contains('what each round or attempt found') |
            Should -BeTrue -Because 'three failed attempts at one bug produce no rounds to write up'
        $t.Contains('on a brief that runs no review gate the failed attempts are the only trigger there is') |
            Should -BeTrue -Because 'the gateless worker has to know which trigger is still live'

        # Both triggers Step 6 escalates on have to be writable from the brief, or the owner is
        # looking for a write-up the artefact never asked for.
        Assert-Phrase -Text $script:CritStep6 -Where 'muster Step 6' `
            -Phrase ('Where the worker reports three rounds of findings in one component or three ' +
                     'failed attempts at one bug')
        $t.Contains('or the third failed attempt at one bug') |
            Should -BeTrue -Because 'the brief has to arm the trigger Step 6 escalates'
    }

    # The rule was stated in `petition` step 7, proposed again for the tripwire, and reached us a
    # third time from outside. One owner, and every other mention is a cross-reference - the two
    # copies drift the moment only one of them is edited.
    It 'one owner: petition points at the rule rather than keeping a second copy' {
        Assert-Phrase -Text $script:CritStep2 -Where 'muster Step 2' `
            -Phrase ('this is the only place it is stated - `petition` step 7 points here rather ' +
                     'than keeping a second copy')
        Assert-Phrase -Text (Get-DocText $script:AskUserMd) -Where 'petition step 7' `
            -Phrase ('Repeated same-theme findings are the `Repeated findings` rule''s subject, ' +
                     'stated in full in `muster` Step 2 and nowhere else')
        (Get-DocText $script:AskUserMd).Contains('incremental corrections are preserving a questionable abstraction') |
            Should -BeFalse -Because 'petition cross-references the rule and never restates it'
    }

    # The discriminator moved with the rule, and it is what stops the tripwire escalating on a bare
    # count: three rounds that each closed an independent defect are ordinary convergence. Without
    # it in the one place the rule now lives, the cross-reference points at nothing that tells an
    # escalation from a Fix, and every third round becomes a question for the user.
    It 'the owner states the discriminator the cross-reference relies on' {
        Assert-Phrase -Text $script:CritStep2 -Where 'muster Step 2' `
            -Phrase ('withhold the Fix authorization and escalate where the rounds show ' +
                     'incremental corrections preserving a questionable abstraction rather than ' +
                     'closing independent defects')
        Assert-Phrase -Text $script:CritStep2 -Where 'muster Step 2' `
            -Phrase 'a bare count of three is not an escalation on its own'
    }

    # The worker and the Hand are gated differently and the rule reads as a self-contradiction the
    # moment that is blurred: an unqualified "the fixing carries on either way" cancels the Fix
    # authorization it just withheld, and a Hand facing a third-round finding has two opposite
    # answers with no second source to break the tie.
    It 'the owner separates the worker fixing from the Hand authorizing a Fix' {
        Assert-Phrase -Text $script:CritStep2 -Where 'muster Step 2' `
            -Phrase ('The worker''s own fixing is never gated at all: it keeps fixing at three ' +
                     'rounds and at ten')
        Assert-Phrase -Text $script:CritStep2 -Where 'muster Step 2' `
            -Phrase ('Your own decision is the single place a round count can hold anything back, ' +
                     'and only in one case')
        Assert-Phrase -Text $script:CritStep2 -Where 'muster Step 2' `
            -Phrase ('authorize the Fix on the finding''s own merits and send the design question ' +
                     'to the user beside it')
        $script:CritStep2.Contains('the fixing carries on either way') |
            Should -BeFalse -Because 'an unscoped either way cancels the authorization just withheld'
    }

    # Both mentions in petition point at that split rather than restating it, and neither may read
    # as a cap on the worker - which is the one failure a cross-reference is supposed to be immune
    # to.
    It 'petition points at the split without capping the fixing' {
        $petition = Get-DocText $script:AskUserMd
        Assert-Phrase -Text $petition -Where 'petition step 7' `
            -Phrase ('It never caps the worker''s own fixing. What it can hold back is your Fix ' +
                     'authorization, and only by the discriminator that rule states')
        Assert-Phrase -Text $petition -Where 'petition classification examples' `
            -Phrase ('whether the Fix itself is still yours to authorize turns on the ' +
                     'discriminator that rule states, never on the count of rounds')
    }

    # The loop that makes the list grow from evidence instead of from invention. Without it a
    # criterion learned at a gate round lives in one report and the next dispatch pays for it again.
    It 'Step 6 folds a finding no criterion matched back into the file' {
        Assert-Phrase -Text $script:CritStep6 -Where 'muster Step 6' `
            -Phrase '**Fold back what the standing criteria missed.**'
        Assert-Phrase -Text $script:CritStep6 -Where 'muster Step 6' `
            -Phrase ('A finding that matches a criterion the worker recorded `pass` or `fixed` ' +
                     'means that criterion did not end the defect')
        Assert-Phrase -Text $script:CritStep6 -Where 'muster Step 6' `
            -Phrase ('so rewrite that line in place in the same turn you read the report, in the ' +
                     'file''s one `-` bullet form, and say what you changed')
        Assert-Phrase -Text $script:CritStep6 -Where 'muster Step 6' `
            -Phrase ('A finding that matches no criterion at all is a candidate line for ' +
                     '`$env:KINGSHAND_HOME\data\done-<project>.md`')
        Assert-Phrase -Text $script:CritStep6 -Where 'muster Step 6' `
            -Phrase ('writing it with `Write-DataFile -Project "<project>"` from `bin\Index.psm1` ' +
                     'where it does not')
    }

    # The self-check records one of three values and the fold-back branches on two of them, so the
    # third has to land somewhere or it falls through both: `fixed` is not `pass`, and it does match
    # a criterion, so it is not "matches no criterion at all". A criterion the worker acted on and
    # the gate then caught anyway is the strongest evidence the line is too weak, and it was the one
    # result that reached neither branch.
    It 'every self-check result the worker can record reaches a fold-back branch' {
        $vocabulary = @('pass', 'fixed', 'n/a')
        foreach ($block in $script:CritDoneBlocks) {
            foreach ($result in $vocabulary) {
                $block.Contains("``$result``") |
                    Should -BeTrue -Because "the worker is offered $result and the Hand must handle it"
            }
        }
        Assert-Phrase -Text $script:CritStep6 -Where 'muster Step 6' `
            -Phrase 'recorded `pass` or `fixed`'
        Assert-Phrase -Text $script:CritStep6 -Where 'muster Step 6' `
            -Phrase ('`fixed` is in that branch deliberately - a criterion the worker acted on and ' +
                     'the gate then caught anyway is the clearest evidence there is that the line ' +
                     'does not say enough')
    }

    # `Write-DataFile` takes -Project as an optional parameter and routes the index entry by it, so
    # omitting it is silent: the file lands correctly and its index line lands in kingshand's own
    # index instead of the project's. Asserted against the real parameter set rather than the
    # sentence alone, so this stays true if the helper's signature changes.
    It 'the fold-back names the project the index entry belongs to' {
        Import-Module "$PSScriptRoot\..\bin\Index.psm1" -Force
        (Get-Command Write-DataFile).Parameters.ContainsKey('Project') |
            Should -BeTrue -Because 'the routing the instruction has to name is a real parameter'
        (Get-Command Write-DataFile).Parameters['Project'].Attributes |
            Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] -and $_.Mandatory } |
            Should -BeNullOrEmpty -Because 'it is optional, which is exactly why the instruction must name it'
        Assert-Phrase -Text $script:CritStep6 -Where 'muster Step 6' `
            -Phrase ('name the project, or the entry lands in kingshand''s own `data\index.md` and ' +
                     'the next session reading `data\index\<project>.md` finds no trace of it')
    }

    # Step 2 pastes this file into every brief for the project, so an unfiltered fold-back turns
    # every one-off defect into a line every future worker reads and records `n/a` against. The
    # generality test is what keeps the list a definition of done rather than a defect log, and the
    # retirement path is what stops it growing in one direction only - `chronicle` curates the two
    # memory files against a budget and deliberately does not reach this one.
    # Every branch of the fold-back has to say what to write and when, or the one that defers is the
    # one that costs most: a criterion too vague to check keeps returning `pass` while the gate
    # keeps finding the same defect, and the list stops discriminating without ever looking broken.
    # The `n/a`s that are the correct answer are carved out of it, since rewording a working line on
    # that evidence is the same damage from the other direction. Most useful criteria are
    # conditional ("every new X ..."), so a change that touches no X is the common case rather than
    # the edge, and treating every such `n/a` as a wording defect would rewrite correct criteria on
    # ordinary dispatches - churning the file this whole loop exists to build. Repetition of that
    # kind belongs to the retire branch, which the same paragraph already owns.
    It 'the reword branch writes in the same turn, and a correct n/a is not rewordable' {
        Assert-Phrase -Text $script:CritStep6 -Where 'muster Step 6' `
            -Phrase ('rewrite that line in place in the same turn you read the report')
        Assert-Phrase -Text $script:CritStep6 -Where 'muster Step 6' `
            -Phrase ('A criterion this brief set aside is not that: the `n/a` is the correct ' +
                     'answer and there is nothing to reword')
        Assert-Phrase -Text $script:CritStep6 -Where 'muster Step 6' `
            -Phrase ('A criterion whose subject this change does not touch is answered correctly ' +
                     'by `n/a`')
        Assert-Phrase -Text $script:CritStep6 -Where 'muster Step 6' `
            -Phrase ('Both are the right answer, and neither is reworded nor recorded')
        Assert-Phrase -Text $script:CritStep6 -Where 'muster Step 6' `
            -Phrase ('A criterion workers keep recording `n/a` against for want of anything to ' +
                     'check is the retire branch below, once it has happened more than once')
    }

    It 'the fold-back filters for generality and says what retires a line' {
        Assert-Phrase -Text $script:CritStep6 -Where 'muster Step 6' `
            -Phrase ('one test decides it: would it apply to the next unrelated change to this ' +
                     'project?')
        Assert-Phrase -Text $script:CritStep6 -Where 'muster Step 6' `
            -Phrase ('A one-off defect in one function is a finding and belongs in the report or a ' +
                     'backlog item')
        Assert-Phrase -Text $script:CritStep6 -Where 'muster Step 6' `
            -Phrase 'Retire a line the same way you add one, in the turn the evidence arrives'
        Assert-Phrase -Text $script:CritStep6 -Where 'muster Step 6' `
            -Phrase ('when workers keep recording it `n/a` on unrelated dispatches for want of ' +
                     'anything to check, delete it and say so')
    }

    # The comparison needs both halves to survive teardown. The self-check block is required by all
    # four Done-means blocks; the rounds are only in `report.md` because the brief made the worker
    # put them there as they landed. Drop that and the fold-back has one reading to compare against
    # nothing, and it silently does nothing at all.
    It 'the rounds the fold-back compares against are recorded as they land' {
        $script:CritTemplateText.Contains('Record every round in `report.md` as it lands - what it found and where - whether or not the tally ever reaches three') |
            Should -BeTrue -Because 'the fold-back compares against rounds that were written down'
        Assert-Phrase -Text $script:CritStep6 -Where 'muster Step 6' `
            -Phrase ('the `Repeated findings` section of the brief made the worker record every ' +
                     'round there as it landed')
    }

    # Without this the best outcome and the worst are the same report. A gate that raised nothing
    # first time leaves no rounds behind, which is exactly the shape Step 6 says to query - so the
    # clean run and the worker that ignored the recording instruction are indistinguishable.
    It 'a clean first pass is recorded, so no rounds at all means the recording was skipped' {
        $script:CritTemplateText.Contains('Record the first pass even when it raises nothing, as `round 1: no findings`, so that a report with no rounds in it means the recording was skipped rather than that the gate was clean.') |
            Should -BeTrue -Because 'an absent line has to mean one thing, not two opposite things'
        Assert-Phrase -Text $script:CritStep6 -Where 'muster Step 6' `
            -Phrase 'and the first pass as `round 1: no findings` where it raised none'
    }

    # The round half of the tally exists only where the brief runs the review gate, and 20 of the
    # 22 registered projects never do. Unscoped, this instruction breaks two ways at once: a worker
    # that takes it literally writes `round 1: no findings` for a gate it never ran and the
    # fold-back compares against a fabricated round, or it records nothing and Step 6 queries a
    # report that is exactly right.
    It 'the tally scopes its round half to a brief that runs the review gate' {
        $script:CritTemplateText.Contains('The round half applies only where the `Done means` block below has you run the review gate') |
            Should -BeTrue -Because 'a worker with no gate has no round to record'
        $script:CritTemplateText.Contains('you never write a round for a gate you did not run') |
            Should -BeTrue -Because 'the wrong reading has to be closed off, not left open'
        $script:CritTemplateText.Contains('The failed-attempt half applies whatever this brief asks of you') |
            Should -BeTrue -Because 'the per-bug half of the tally is mode-independent'

        $scope  = $script:CritTemplateText.IndexOf('The round half applies only where')
        $record = $script:CritTemplateText.IndexOf('Record every round in `report.md` as it lands')
        $scope  | Should -BeGreaterThan -1
        $record | Should -BeGreaterThan -1
        $scope  | Should -BeLessThan $record `
            -Because 'the scope has to be read before the instruction it scopes'
    }

    # Twenty of the twenty-two registered projects have no review gate, so an unqualified compare
    # is an instruction that cannot be carried out for most of the fleet. The self-check still gets
    # read there - an `n/a` is the same wording problem arriving from the other side. The prod-only
    # half is named because that mode resolves per task, so the two registered prod-only projects
    # produce gateless runs the registry alone does not account for.
    It 'the fold-back says it does not fire where there is no gate' {
        Assert-Phrase -Text $script:CritStep6 -Where 'muster Step 6' `
            -Phrase ('On a `local-only` or `direct-PR` project - including a ' +
                     '`no-mistakes-prod-only` project whose task resolved to `direct-PR` - there ' +
                     'is no gate and no round to compare against, so this loop does not fire, and ' +
                     'a report with no rounds in it is the record that brief asked for rather than ' +
                     'one to query')
        Assert-Phrase -Text $script:CritStep6 -Where 'muster Step 6' `
            -Phrase 'Read the self-check block either way'
    }

    # A qualifier stated after the clause it qualifies is one the reader has already acted on. The
    # query fires on the gateless majority, so the exemption has to be in front of it - the same
    # shape as the two n/a-classification defects this loop already had.
    It 'the gateless exemption is stated before the query it exempts' {
        $exempt = $script:CritStep6.IndexOf('there is no gate and no round to compare against')
        $query  = $script:CritStep6.IndexOf('no rounds at all is one to ask about')
        $exempt | Should -BeGreaterThan -1 -Because 'the exemption has to be there to be read'
        $query  | Should -BeGreaterThan -1 -Because 'the query is what it exempts'
        $exempt | Should -BeLessThan $query
    }

    It 'Step 6 escalates a round tally as a finding rather than filing it as progress' {
        Assert-Phrase -Text $script:CritStep6 -Where 'muster Step 6' `
            -Phrase '**A round tally in a report is a finding, not a completion notice.**'
        Assert-Phrase -Text $script:CritStep6 -Where 'muster Step 6' `
            -Phrase 'file it as a backlog item and let `decree` own the decision from there'
    }

    # `emgee-apex-design` named all seven of its settled decisions in the intent string and came back
    # with engineering findings only; `kh-decision-carry` left a stale one and the gate raised a
    # finding against the mismatch. The cheapest lever measured anywhere in that evidence.
    It 'the intent string names what the task deliberately sets aside' {
        Assert-Phrase -Text $script:CritStep2 -Where 'muster Step 2' `
            -Phrase '**Say in `--intent` what this task deliberately sets aside.**'
        Assert-Phrase -Text $script:CritStep2 -Where 'muster Step 2' `
            -Phrase 'add to it the settled decisions and standing criteria this work breaks, and why'
    }

    # And the boundary that has to come with it. A wider intent string is exactly what somebody
    # would use to suppress findings while believing they were being helpful, and from outside a
    # suppressed run and a well-prepared one look identical.
    It 'the intent string is never used to tell the gate what not to flag' {
        Assert-Phrase -Text $script:CritStep2 -Where 'muster Step 2' `
            -Phrase '**Never tell the review gate what not to flag.**'
        Assert-Phrase -Text $script:CritStep2 -Where 'muster Step 2' `
            -Phrase ('That string says what the work is for; it never says what the reviewer may ' +
                     'not find.')
        Assert-Phrase -Text $script:CritStep2 -Where 'muster Step 2' `
            -Phrase ('Name the decision and the evidence for it, and let the gate raise the finding ' +
                     'anyway.')
    }

    # The prohibition lands paired with the rationalisations it is meant to catch, so the writer
    # recognises their own sentence mid-draft rather than having to judge their own motive. All four
    # are real declines from this repository's gate history, turned into an instruction.
    It 'and it lists the phrasings that give it away' {
        Assert-Phrase -Text $script:CritStep2 -Where 'muster Step 2' `
            -Phrase '"the prose assertions in `Docs.Tests.ps1` are settled, do not raise them again"'
        Assert-Phrase -Text $script:CritStep2 -Where 'muster Step 2' `
            -Phrase '"the design notes in `docs\` are settled, so raise nothing against them"'
        Assert-Phrase -Text $script:CritStep2 -Where 'muster Step 2' `
            -Phrase '"the King has already declined findings of this class"'
        Assert-Phrase -Text $script:CritStep2 -Where 'muster Step 2' `
            -Phrase '"no linter is configured here, so ignore lint"'
    }
}

Describe 'the default branch and the integration branch are two things' {
    # A repository can land a fresh clone on `main` while every pull request targets `dev` and
    # every worker branches from `dev`. `origin/HEAD` names only the first, so the tooling table
    # has to say which of the two the dispatcher follows - otherwise the next reader assumes the
    # default branch, which is the assumption that cuts a worker from the wrong tree.
    It 'the CLAUDE.md tooling table says the dispatcher follows the declared integration branch' {
        Assert-Phrase -Text (Get-DocText $script:HandMd) -Where 'the CLAUDE.md Tooling table' `
            -Phrase ('| `bin\Resolve-BaseRef.ps1` | dot-sourced by the dispatcher: the one ref a ' +
                     'worker branches from and the landing gate diffs against - the integration ' +
                     'branch the repo declares in `.no-mistakes.yaml`, and its default branch ' +
                     'where it declares none, always confirmed with `git rev-parse --verify` |')
    }

    # Base resolution warns rather than refusing when it could not honour a declaration, or
    # honoured it only as a local copy - and on a `+yolo` project the Hand is the warning's sole
    # reader, so nothing else stops to show it. Delete the relay rule and work lands measured
    # against a stale base with nothing having said so, which no other test would notice.
    It 'muster Step 4 makes the Hand relay a base-resolution warning' {
        $step = Get-MusterStep 'Step 4 - Dispatch'
        Assert-Phrase -Text $step -Where 'muster Step 4' `
            -Phrase '**Relay any warning that call prints.**'
        Assert-Phrase -Text $step -Where 'muster Step 4' `
            -Phrase ('On a `+yolo` project nothing else stops to show it, so an unrelayed ' +
                     'warning is work landed against a stale base.')
    }

    # The recorded base and the branch point are one ref only where the dispatch actually branched.
    # Re-dispatching a ticket whose branch survived does not branch again, so a repository that has
    # declared an integration branch since - which is what this change makes likely - leaves the
    # base naming one tree and the branch cut from another. The Hand reads step 7's diff, so it is
    # the reader that has to know: without this, a widened diff looks like the worker's doing.
    It 'muster warns that a re-dispatched ticket can be diffed against the wrong base' {
        $step = Get-MusterStep 'Step 4 - Dispatch'
        Assert-Phrase -Text $step -Where 'muster Step 4' `
            -Phrase ('**On a re-dispatch the two can disagree, so read step 7''s diff knowing ' +
                     'that.**')
        Assert-Phrase -Text $step -Where 'muster Step 4' `
            -Phrase 'A widened diff on a re-dispatched ticket is that, not the worker''s doing.'
    }

    # The claim in that row that a reviewer cannot check by reading: that the two consumers of the
    # declaration read the same key from the same file. A row saying so while the gate read
    # something else would be worse than a row saying nothing.
    #
    # Asserted by running the real reader over this repository's own file, not by looking for a
    # string in it. A substring both false-passes and false-fails: `# base_branch: dev` left
    # commented out matches while the repository declares nothing, and `base_branch: "dev"` -
    # a form the reader honours - does not match at all.
    It 'the repository declares that branch where the review gate reads it' {
        $declared = Join-Path $script:Root '.no-mistakes.yaml'
        Test-Path -LiteralPath $declared | Should -BeTrue -Because 'the tooling table names this file'

        # A throwaway repo carrying this repository's declaration and nothing else, so what the
        # reader returns is decided by the file rather than by whatever refs this checkout holds.
        # No origin and a `main` default, so an undeclared repo resolves to `main` and only an
        # honoured declaration can come back as `dev`.
        $probe = Join-Path ([System.IO.Path]::GetTempPath()) `
                           ('declared-base-' + [guid]::NewGuid().ToString('N'))
        try {
            git init -b main $probe -q
            git -C $probe config user.name  'Test'
            git -C $probe config user.email 'test@example.invalid'
            Set-Content -Path (Join-Path $probe 'base.txt') -Value 'base' -Encoding utf8
            git -C $probe add -A
            git -C $probe commit -q -m 'Initial commit'
            git -C $probe branch dev
            Copy-Item -LiteralPath $declared -Destination (Join-Path $probe '.no-mistakes.yaml')

            . (Join-Path $script:Root 'bin\Resolve-BaseRef.ps1')
            Resolve-BaseRef -RepoPath $probe |
                Should -Be 'dev' -Because 'kingshand integrates on dev, whatever its default branch becomes'
        } finally {
            if (Test-Path -LiteralPath $probe) {
                Remove-Item -LiteralPath $probe -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

# Kingshand had no version at all: nothing said which copy you were running, and `git pull` - which
# takes whatever was pushed last - was the only way to move. The rules below are what replaced that,
# and every one of them is prose that nothing else in the suite would miss if it were deleted.
Describe 'the installation has a version, and one command moves it to a release' {
    BeforeAll {
        $script:UpdateMd   = Join-Path $script:Root '.claude\skills\update\SKILL.md'
        $script:UpdateText = Get-DocText $script:UpdateMd
        $script:VersionDoc = Get-DocText (Join-Path $script:Root 'docs\2026-09-03-versioning-and-update.md')
    }

    It 'ships a VERSION file holding one version and nothing else' {
        $path = Join-Path $script:Root 'VERSION'
        Test-Path -LiteralPath $path | Should -BeTrue -Because 'the version is a file, not a claim in prose'
        $lines = @(Get-Content -Path $path | Where-Object { $_.Trim() })
        $lines.Count | Should -Be 1 -Because 'a second line in it is a second thing to disagree with'
        $lines[0].Trim() | Should -Match '^\d+\.\d+\.\d+'
    }

    It 'names the version as one line of the session-start digest' {
        Assert-Phrase -Text (Get-HandSection 'Session start') -Where 'CLAUDE.md Session start' `
            -Phrase 'The digest carries six things: this installation''s version on one `VERSION:` line'
    }

    It 'declares the update skill trigger inline, with its refusals' {
        $skills = Get-HandSection 'Skills'
        Assert-Phrase -Text $skills -Where 'CLAUDE.md Skills' `
            -Phrase ('Invoke `update` when the user invokes `/update` or asks to move kingshand itself ' +
                     'to the latest version.')
        Assert-Phrase -Text $skills -Where 'CLAUDE.md Skills' `
            -Phrase ('It fast-forwards this installation to the latest tagged release, re-runs ' +
                     '`install.ps1`, and says which version it moved from and to.')
        Assert-Phrase -Text $skills -Where 'CLAUDE.md Skills' `
            -Phrase ('It refuses rather than proceeding on a dirty tree, on any live worker, off the ' +
                     'release branch, or where no release has been tagged yet.')
        Assert-Phrase -Text $skills -Where 'CLAUDE.md Skills' `
            -Phrase 'Never run it on the King''s behalf.'
    }

    It 'counts every skill that now loads' {
        Assert-Phrase -Text (Get-HandSection 'Skills') -Where 'CLAUDE.md Skills' `
            -Phrase 'so all sixteen load when Claude Code runs here'
    }

    It 'gives the version and the update their own owners in the tooling table' {
        $tooling = Get-HandSection 'Tooling'
        Assert-Phrase -Text $tooling -Where 'the CLAUDE.md tooling table' `
            -Phrase ('| `bin\Version.psm1` | the `VERSION` file at the repo root: this installation''s ' +
                     'version, read and validated in one place, and never fabricated when it cannot be read |')
        Assert-Phrase -Text $tooling -Where 'the CLAUDE.md tooling table' `
            -Phrase ('| `bin\Update.psm1` | the self-update behind `/update`: the four refusals, the ' +
                     'latest release tag, and the commit subjects between two releases |')
    }

    It 'has frontmatter that parses, with the trigger in the description' {
        $fm = Get-Frontmatter $script:UpdateMd
        $fm['name']    | Should -Be 'update' -Because 'the frontmatter name must match the skill directory'
        $fm['version'] | Should -Be '1.0.0'
        $fm['description'].Contains('"/update"') |
            Should -BeTrue -Because 'the slash command has to fire the skill'
        $fm['description'].Contains('"am I on the latest?"') |
            Should -BeTrue -Because 'a skill reached only by its own name is reached by nobody'
    }

    It 'says this is not project work and needs no worker' {
        Assert-Phrase -Text $script:UpdateText -Where 'the update skill' `
            -Phrase '**This is not project work and it needs no worker.**'
        Assert-Phrase -Text $script:UpdateText -Where 'the update skill' `
            -Phrase 'so do not write a brief, do not dispatch, and do not load `muster`'
        Assert-Phrase -Text $script:UpdateText -Where 'the update skill' `
            -Phrase '**Run it only when the user asks.**'
    }

    It 'updates to a tag and never to a branch head' {
        Assert-Phrase -Text $script:UpdateText -Where 'the update skill' `
            -Phrase '**It never updates to a branch head.**'
        Assert-Phrase -Text $script:UpdateText -Where 'the update skill' `
            -Phrase 'A release is a tag - a deliberate act - and a branch head is whatever was pushed last.'
        Assert-Phrase -Text $script:VersionDoc -Where 'the versioning record' `
            -Phrase '### `/update` moves to the latest TAG, never to a branch head'
    }

    It 'names all four refusals as refusals' {
        Assert-Phrase -Text $script:UpdateText -Where 'the update skill' -Phrase '**A dirty working tree.**'
        Assert-Phrase -Text $script:UpdateText -Where 'the update skill' -Phrase '**A live worker.**'
        Assert-Phrase -Text $script:UpdateText -Where 'the update skill' -Phrase '**Not on the release branch.**'
        Assert-Phrase -Text $script:UpdateText -Where 'the update skill' -Phrase '**No release has been tagged yet.**'
        Assert-Phrase -Text $script:VersionDoc -Where 'the versioning record' `
            -Phrase '### Four refusals, and none of them is an edge case'
    }

    It 'reads liveness from herdr rather than from the durable record' {
        Assert-Phrase -Text $script:UpdateText -Where 'the update skill' `
            -Phrase ('Liveness is read from herdr rather than from the durable record, because the two ' +
                     'disagree exactly when it matters')
        Assert-Phrase -Text $script:VersionDoc -Where 'the versioning record' `
            -Phrase '**Live workers are read from herdr, never from `state\crew.json`.**'
    }

    It 'tells a herdr that is down apart from a herdr that could not be asked' {
        Assert-Phrase -Text $script:VersionDoc -Where 'the versioning record' `
            -Phrase '**The guard tells three states apart, and never collapses the third into the first.**'
        Assert-Phrase -Text $script:VersionDoc -Where 'the versioning record' `
            -Phrase ('A herdr whose server is not running has no live worker, and that is a fact ' +
                     'rather than a guess, because a pane dies with the server it belongs to.')
        Assert-Phrase -Text $script:VersionDoc -Where 'the versioning record' `
            -Phrase ('the ordinary agent-list reader deliberately answers an unreachable herdr with ' +
                     'an empty list, which every status view wants and this guard must never accept')
    }

    It 'reads the server state itself as three-valued rather than as a boolean' {
        Assert-Phrase -Text $script:VersionDoc -Where 'the versioning record' `
            -Phrase ('**Every read on the way to that answer is three-valued too, not just the last ' +
                     'one.**')
        Assert-Phrase -Text $script:VersionDoc -Where 'the versioning record' `
            -Phrase ('the guard reads the server state as *running*, *stopped* or *unknown*, off ' +
                     '`herdr status --json` rather than off a regex over prose, and only *stopped* ' +
                     'means no workers')
    }

    It 'believes what herdr said over what it exited with, and says why' {
        Assert-Phrase -Text $script:VersionDoc -Where 'the versioning record' `
            -Phrase ('**What herdr said decides that read, and what it exited with does not.**')
        Assert-Phrase -Text $script:VersionDoc -Where 'the versioning record' `
            -Phrase ('the exit code for a server that is *down* has never been measured - seeing it ' +
                     'would mean stopping a server that was hosting live workers at the time')
        Assert-Phrase -Text $script:VersionDoc -Where 'the versioning record' `
            -Phrase ('*Unknown* is therefore kept for a reply nobody can read at all')
    }

    It 'treats the no-releases path as the common path rather than an edge case' {
        Assert-Phrase -Text $script:VersionDoc -Where 'the versioning record' `
            -Phrase '**There were zero tags when this was written, so the no-releases path is the common path.**'
        Assert-Phrase -Text $script:UpdateText -Where 'the update skill' `
            -Phrase ('the alternative - quietly pulling whatever was pushed last - is the thing this ' +
                     'deliberately does not do')
    }

    It 'creates no tag itself, and points at the procedure that does' {
        Assert-Phrase -Text $script:UpdateText -Where 'the update skill' `
            -Phrase '**It never creates or pushes a tag.**'
        Assert-Phrase -Text $script:UpdateText -Where 'the update skill' `
            -Phrase '`docs\2026-09-03-versioning-and-update.md` is where that procedure is written down'
    }

    It 'folds the release into the merge the King already performs' {
        Assert-Phrase -Text $script:VersionDoc -Where 'the versioning record' `
            -Phrase '**That merge is the release.**'
        Assert-Phrase -Text $script:VersionDoc -Where 'the versioning record' `
            -Phrase ('The tag is cut on it, as one more step in a thing already being done, rather than ' +
                     'as a separate ceremony on its own schedule.')
    }

    It 'says a pre-release tag is not a release anybody is moved to' {
        Assert-Phrase -Text $script:VersionDoc -Where 'the versioning record' `
            -Phrase ('**A pre-release tag is deliberately not a release `/update` will move anyone ' +
                     'to.**')
        Assert-Phrase -Text $script:VersionDoc -Where 'the versioning record' `
            -Phrase ('git''s own version ordering ranks `v1.0.0-rc1` *above* `v1.0.0` unless ' +
                     '`versionsort.suffix` is configured')
    }

    It 'reports what changed as commit subjects, with no parser anywhere' {
        Assert-Phrase -Text $script:VersionDoc -Where 'the versioning record' `
            -Phrase ('### "What changed" is the commit subjects between the two releases, and there is ' +
                     'no parser')
        Assert-Phrase -Text $script:VersionDoc -Where 'the versioning record' `
            -Phrase '**No changelog parser.**'
    }

    It 'never forces, stashes or discards, and never reports success it did not have' {
        Assert-Phrase -Text $script:UpdateText -Where 'the update skill' `
            -Phrase '**It never forces, stashes, resets, rebases or merges non-linearly.**'
        Assert-Phrase -Text $script:UpdateText -Where 'the update skill' `
            -Phrase '**It never reports success it did not have.**'
        Assert-Phrase -Text $script:UpdateText -Where 'the update skill' `
            -Phrase '**It never touches the user''s own state.**'
    }

    It 'states what a future change must not undo' {
        Assert-Phrase -Text $script:VersionDoc -Where 'the versioning record' `
            -Phrase '**The version stays in one file.**'
        Assert-Phrase -Text $script:VersionDoc -Where 'the versioning record' `
            -Phrase '**Updates stay tagged.**'
        Assert-Phrase -Text $script:VersionDoc -Where 'the versioning record' `
            -Phrase ('nothing may convert "cannot tell whether a worker is live" into "no workers are ' +
                     'live"')
    }
}

# ---------------------------------------------------------------------------------------------
# Story analysis. The King asked for a breakdown skill after kingshand's own audit had already
# concluded that an external brainstorming skill was not for us, for three independent reasons -
# one of them structural, because a worker cannot address the user and so cannot hold a dialogue
# at all. The resolution is a split: the dialogue is the Hand's, the reading is a worker's, and
# the skill is user-invoked only so the Intake rule against volunteering a design exercise keeps
# its force. Every line of that is prose, and prose is what nothing else in this suite would miss.
# ---------------------------------------------------------------------------------------------
Describe 'counsel splits the dialogue from the reading, and only the King starts it' {
    BeforeAll {
        $script:CounselMd   = Join-Path $script:Root '.claude\skills\counsel\SKILL.md'
        $script:CounselText = Get-DocText $script:CounselMd
        $script:CounselDoc  = Get-DocText (Join-Path $script:Root 'docs\2026-09-04-story-analysis-split.md')
    }

    It 'exists as a project-local skill with frontmatter that parses' {
        Test-Path -LiteralPath $script:CounselMd |
            Should -BeTrue -Because 'a skill nothing can load is not a skill'
        $fm = Get-Frontmatter $script:CounselMd
        $fm['name']    | Should -Be 'counsel' -Because 'the frontmatter name must match the skill directory'
        $fm['version'] | Should -Be '1.0.0'
    }

    # The whole resolution of the audit's rejection rests on this pair: the King may ask, the Hand
    # may not offer. The guard is the written rule, and the mechanical version of it was rejected
    # because it takes the skill out of the Hand's listing altogether, so both halves are pinned.
    It 'is user-invoked only, in frontmatter as well as in prose' {
        $fm = Get-Frontmatter $script:CounselMd
        $fm.ContainsKey('disable-model-invocation') |
            Should -BeFalse -Because 'that key would kill the situational triggers statute requires a description to fire on'
        $fm['user-invocable'] |
            Should -Be 'true' -Because 'the King is the only way in, so his way in must stay open'
        Assert-Phrase -Text $script:CounselText -Where 'the counsel skill' `
            -Phrase ('**The guard is a rule, not a mechanism.** The Hand loads this skill only when the ' +
                     'King asks for it, and never beside an answer that is already good enough. The ' +
                     'mechanical alternative was tried and rejected: `disable-model-invocation: true` ' +
                     'removes the skill from the Hand''s own listing entirely, so the Hand could not act ' +
                     'on the King''s request in his own words, and every situational trigger in the ' +
                     'description above would be dead.')
    }

    It 'the description fires on the situation and on <trigger>' -ForEach @(
        @{ trigger = '"/counsel"' }
        @{ trigger = '"break this story down"' }
        @{ trigger = '"brainstorm this with me"' }
        @{ trigger = '"where do these stories overlap"' }
    ) {
        $description = (Get-Frontmatter $script:CounselMd)['description']
        $description.Contains($trigger) |
            Should -BeTrue -Because "a skill reached only by its own name is reached by nobody, so $trigger must fire it"
    }

    It 'names the contradiction it resolves rather than routing around it' {
        Assert-Phrase -Text $script:CounselText -Where 'the counsel skill' `
            -Phrase ('**That is a resolution of a contradiction, not an oversight, and it is written ' +
                     'down here so nobody quietly reverses it.**')
        Assert-Phrase -Text $script:CounselText -Where 'the counsel skill' `
            -Phrase 'concluded **not for us**, for three independent reasons'
        Assert-Phrase -Text $script:CounselText -Where 'the counsel skill' `
            -Phrase 'workers never address the user, so that dialogue cannot happen inside a dispatch at all'
    }

    It 'resolves the Intake rule by who may ask, without weakening it' {
        Assert-Phrase -Text $script:CounselText -Where 'the counsel skill' `
            -Phrase '**the Intake rule binds what the Hand offers, never what the King may ask for.**'
        Assert-Phrase -Text $script:CounselText -Where 'the counsel skill' `
            -Phrase ('The Hand does not volunteer an analysis beside an answer that is already good ' +
                     'enough, and does not run one to look thorough.')
        Assert-Phrase -Text $script:CounselText -Where 'the counsel skill' `
            -Phrase '**An analysis authorises nothing.**'
    }

    # Hard rule 1 is the one this skill is most exposed to: the reading half is exactly the work a
    # busy Hand would do itself in one file open.
    It 'gives the dialogue to the Hand and the reading to a worker, at every step' {
        Assert-Phrase -Text $script:CounselText -Where 'the counsel skill' `
            -Phrase ('| Narrowing the problem, asking what is ambiguous, agreeing the division | the ' +
                     'Hand, with the King | A worker never addresses the user, so it can ask him ' +
                     'nothing |')
        Assert-Phrase -Text $script:CounselText -Where 'the counsel skill' `
            -Phrase ('| Opening the stories, the tickets and the code, finding what overlaps | a ' +
                     'worker | Hard rule 1: the Hand routes, and never reads a project''s source |')
        Assert-Phrase -Text $script:CounselText -Where 'the counsel skill' `
            -Phrase ('**A pass that has the Hand open the repository to see how the stories divide has ' +
                     'broken it**')
        Assert-Phrase -Text $script:CounselDoc -Where 'the story-analysis record' `
            -Phrase '**The dialogue belongs to the Hand**, because only the Hand can reach the King.'
        Assert-Phrase -Text $script:CounselDoc -Where 'the story-analysis record' `
            -Phrase '**The reading belongs to a worker**, because it is a project''s own material.'
    }

    # The skill ships to strangers. One reader's layers are front end, back end and database; the
    # next reader's are not, and a set written into the skill would be invisibly wrong for them.
    It 'treats the layer set as a per-project fact and never as a constant' {
        Assert-Phrase -Text $script:CounselText -Where 'the counsel skill' `
            -Phrase ('**Which layers this project divides into.** This is a per-project fact and never ' +
                     'a constant.')
        Assert-Phrase -Text $script:CounselText -Where 'the counsel skill' `
            -Phrase ('This skill ships to strangers, so it carries no project''s layer set, no product ' +
                     'name and no real story as an example.')
        Assert-Phrase -Text $script:CounselDoc -Where 'the story-analysis record' `
            -Phrase '**No hardcoded layer set.**'
    }

    # Fail closed: an unstated layer set reads as unstated. Filling it in from another project is
    # the failure that produces several wrong tasks with a tidy shape and no visible cause.
    It 'stops on an unstated layer set rather than guessing one' {
        Assert-Phrase -Text $script:CounselText -Where 'the counsel skill' `
            -Phrase ('**Where the project states no layer set and the King is not there to answer, say ' +
                     'the layer set is unstated and stop. Never fill it in from another project, and ' +
                     'never let a guessed set reach a brief.**')
        Assert-Phrase -Text $script:CounselText -Where 'the counsel skill' `
            -Phrase ('A decomposition divided along layers this project does not have is several wrong ' +
                     'tasks wearing a tidy shape.')
    }

    # Seventeen stories pasted into one session exhausted the window. Worker isolation alone does
    # not fix it, and one worker per story cannot see an overlap at all, so the map's shape and its
    # size contract are the load-bearing parts.
    It 'reads a whole story set in one worker and returns a short map' {
        Assert-Phrase -Text $script:CounselText -Where 'the counsel skill' `
            -Phrase ('**Worker isolation alone does not fix it**, because somebody still has to hold ' +
                     'all seventeen at once to see an overlap at all.')
        Assert-Phrase -Text $script:CounselText -Where 'the counsel skill' `
            -Phrase ('**The shape that works, and the one to use every time: one worker reads the whole ' +
                     'set in its own full window and writes back a short map. The Hand reads the map ' +
                     'and never the stories.**')
        Assert-Phrase -Text $script:CounselText -Where 'the counsel skill' `
            -Phrase 'The map is short by contract, because a map as long as the stories has solved nothing'
        Assert-Phrase -Text $script:CounselText -Where 'the counsel skill' `
            -Phrase 'The overlap question is a whole-set question, so it is one worker.'
        Assert-Phrase -Text $script:CounselDoc -Where 'the story-analysis record' `
            -Phrase ('**What a future change must not undo:** the map''s size contract, and the rule ' +
                     'that the Hand reads the map rather than the stories.')
    }

    It 'makes exactness checkable rather than asserted' {
        Assert-Phrase -Text $script:CounselText -Where 'the counsel skill' `
            -Phrase '**A wrong decomposition is expensive in a way a slow one is not.**'
        Assert-Phrase -Text $script:CounselText -Where 'the counsel skill' `
            -Phrase ('**The requirement ledger** - every requirement the worker read, each one marked ' +
                     'as covered by a named task, judged ambiguous, or assumed with the assumption ' +
                     'written out.')
        Assert-Phrase -Text $script:CounselText -Where 'the counsel skill' `
            -Phrase 'A requirement missing from the ledger is a requirement nobody read'
    }

    It 'sends an unsettled ambiguity to the decision owner instead of settling it' {
        Assert-Phrase -Text $script:CounselText -Where 'the counsel skill' `
            -Phrase ('An ambiguity the analysis could not settle and the King has to is a decision, and ' +
                     '`decree` owns what happens to it.')
    }

    It 'keeps brainstorming inside this skill rather than making a second one' {
        Assert-Phrase -Text $script:CounselText -Where 'the counsel skill' `
            -Phrase ('two skills with overlapping descriptions means the wrong one loads, which ' +
                     '`statute`''s trigger hygiene owns')
        Assert-Phrase -Text $script:CounselDoc -Where 'the story-analysis record' `
            -Phrase '**No second skill for brainstorming.**'
    }

    # The audit's one genuinely missing piece, and the one this skill refuses. A test that must
    # fire when the King asks for implementation work cannot live in a skill loaded only when he
    # asks for an analysis, and hard rule 1 stops the Hand evaluating one of its conditions at all.
    It 'disclaims the trigger for settling a shape first and names its home' {
        Assert-Phrase -Text $script:CounselText -Where 'the counsel skill' `
            -Phrase ('**This skill deliberately does not own that trigger. Its home is `muster` Step 1 ' +
                     'intake**')
        Assert-Phrase -Text $script:CounselText -Where 'the counsel skill' `
            -Phrase ('The test has to fire when the King asks for implementation work, which is a ' +
                     'situation this skill is never loaded for')
        Assert-Phrase -Text $script:CounselText -Where 'the counsel skill' `
            -Phrase ('whether a story can be divided without reading code nobody has read yet, is ' +
                     'something hard rule 1 forbids the Hand from checking')
        Assert-Phrase -Text $script:CounselText -Where 'the counsel skill' `
            -Phrase ('`inquest` owns the diagnosis procedure, and `CLAUDE.md` already says a diagnosis ' +
                     'is evidence rather than authorization')
        Assert-Phrase -Text $script:CounselDoc -Where 'the story-analysis record' `
            -Phrase ('**This task decided the trigger does not belong in `counsel`. Its home is `muster` ' +
                     'Step 1 intake**')
    }

    # Roughly 22 review rounds across three tasks went into hand-written parsers of open-ended
    # formats here. A story is prose, so this is the one hazard this skill could not be allowed to
    # walk into.
    It 'builds no story parser' {
        Assert-Phrase -Text $script:CounselText -Where 'the counsel skill' `
            -Phrase ('**Nothing in this skill extracts structure from story text with a regex, a line ' +
                     'scan or a hand-written parser.**')
        Assert-Phrase -Text $script:CounselText -Where 'the counsel skill' `
            -Phrase 'A parser for prose has no round after which it is finished'
        Assert-Phrase -Text $script:CounselDoc -Where 'the story-analysis record' `
            -Phrase '**No story parser.**'
    }

    It 'assumes no ticket system, and keeps hard rule 3 over whatever it reaches' {
        Assert-Phrase -Text $script:CounselText -Where 'the counsel skill' `
            -Phrase '**A ticket system is not assumed.**'
        Assert-Phrase -Text $script:CounselText -Where 'the counsel skill' `
            -Phrase 'Azure DevOps is an optional integration and absent by default'
        Assert-Phrase -Text $script:CounselText -Where 'the counsel skill' `
            -Phrase ('nothing landing in a ticket, a commit message or a pull request names an agent or ' +
                     'its tooling')
    }

    # Instructions that read as contradictions of the skill's own guards unless they are ranked:
    # the ordering trigger looks like the Hand volunteering an analysis, posture looks like warrant
    # to start one, and the read-only scope sits in the same brief as a Done-means block that opens
    # by requiring a commit. Each pair needs a stated winner, not a stated resolution.
    It 'ranks its authority rules and names which brief line wins' {
        Assert-Phrase -Text $script:CounselText -Where 'the counsel skill' `
            -Phrase ('**A counsel pass needs the King, whatever the posture.** The Hand never starts one ' +
                     'on its own authority, and `+yolo` does not authorise one')
        Assert-Phrase -Text $script:CounselText -Where 'the counsel skill' `
            -Phrase ('**An ordinary dispatch is `muster`''s to gate, unchanged.**')
        Assert-Phrase -Text $script:CounselText -Where 'the counsel skill' `
            -Phrase ('**That is about the dispatch decision and nothing else** - this skill neither ' +
                     'widens nor narrows that gate, and it says nothing about how the dispatch ends.')
        Assert-Phrase -Text $script:CounselText -Where 'the counsel skill' `
            -Phrase '**Wherever both could be read to apply, rule 1 wins.**'
        Assert-Phrase -Text $script:CounselText -Where 'the counsel skill' `
            -Phrase ('**Close-out is the one place this skill does narrow, deliberately, and the ' +
                     'close-out section below says how and why.**')
        Assert-Phrase -Text $script:CounselText -Where 'the counsel skill' `
            -Phrase ('**Then say in one line which instruction wins: where the read-only scope and the ' +
                     'pasted Done-means block disagree, the read-only scope wins - over committing on ' +
                     'the branch, running the review gate, pushing, opening a pull request and merging ' +
                     'alike.**')
        Assert-Phrase -Text $script:CounselText -Where 'the counsel skill' `
            -Phrase ('An analysis that comes back with a commit, a pushed branch or a pull request has ' +
                     'exceeded its brief.')
    }

    # muster's lifecycle assumes work that lands or pushes, and this dispatch makes no commits at
    # all. An earlier attempt to specify the missing close-out here made counsel a second owner of
    # the lifecycle, and every patch to it exposed the next assumption muster makes. So the rule is
    # that counsel names the gap and refuses to work around it.
    It 'names the read-only close-out gap instead of inventing a lifecycle for it' {
        Assert-Phrase -Text $script:CounselText -Where 'the counsel skill' `
            -Phrase ('**this skill does not invent a parallel lifecycle**, because `muster` owns the ' +
                     'lifecycle and a second owner of it drifts the moment either file is edited')
        Assert-Phrase -Text $script:CounselText -Where 'the counsel skill' `
            -Phrase ('**do not set a stage `muster` does not define, do not tear the worker down on this ' +
                     'skill''s authority, and do not skip `muster`''s base-ref verification in order to ' +
                     'justify one.**')
        Assert-Phrase -Text $script:CounselText -Where 'the counsel skill' `
            -Phrase ('Closing this properly needs three things `muster` does not have yet: a Done-means ' +
                     'block for a dispatch that produces no commits, a terminal stage for one, and a ' +
                     'teardown rule keyed on the deliverable living outside the worktree')
        Assert-Phrase -Text $script:CounselDoc -Where 'the story-analysis record' `
            -Phrase '## The read-only close-out is deliberately left open'
    }

    It 'renders the decomposition and dispatches nothing by having read it' {
        Assert-Phrase -Text $script:CounselText -Where 'the counsel skill' `
            -Phrase '**Nothing is dispatched by having been read.**'
        Assert-Phrase -Text $script:CounselText -Where 'the counsel skill' `
            -Phrase 'An accepted decomposition is a queue, not a licence.'
    }

    It 'declares its trigger inline in CLAUDE.md, with the rule that nothing volunteers it' {
        $skills = Get-HandSection 'Skills'
        Assert-Phrase -Text $skills -Where 'CLAUDE.md Skills' `
            -Phrase ('Invoke `counsel` when the King asks for a story, a feature or a pile of stories ' +
                     'to be broken down, analysed or brainstormed before anything is built.')
        Assert-Phrase -Text $skills -Where 'CLAUDE.md Skills' `
            -Phrase '**Never launch it unprompted**'
    }
}

# ---------------------------------------------------------------------------------------------
# Browser verification is opt-in, fails closed, and records what it saw.
#
# The failure this guards against is not a browser bug. It is a change that was never exercised
# coming back reading like one that was - so the rules that must survive are the ones that refuse
# a pass: no section means no browser step, an absent server means verification did not happen,
# and a check that could not be answered is reported rather than skipped.
#
# docs\2026-09-03-browser-verification.md owns why each of these is shaped the way it is.
# ---------------------------------------------------------------------------------------------
Describe 'witness keeps the rules that stop an unexercised change reading as a pass' {
    BeforeAll {
        $script:WitnessMd   = Join-Path $script:Root '.claude\skills\witness\SKILL.md'
        $script:WitnessText = Get-DocText $script:WitnessMd
        $script:BrowserDoc  = Get-DocText (Join-Path $script:Root 'docs\2026-09-03-browser-verification.md')
    }

    It 'has frontmatter that parses, with the situation in the description' {
        $fm = Get-Frontmatter $script:WitnessMd
        $fm['name']    | Should -Be 'witness' -Because 'the frontmatter name must match the skill directory'
        $fm['version'] | Should -Be '1.0.0'
        $fm['description'].Length |
            Should -BeGreaterThan 40 -Because 'the description is the trigger, and it must name the situation'
        $fm['description'].Contains('`## Browser checks` section') |
            Should -BeTrue -Because 'a reference skill is reached by recognising its situation, not by name'
    }

    # The opt-in. A browser step nobody asked for is cost with no answer attached, and the only
    # thing standing between that and every dispatch is this sentence.
    It 'gives no browser step to a brief that did not ask for one' {
        Assert-Phrase -Text $script:WitnessText -Where 'witness' `
            -Phrase '**A brief with no `## Browser checks` section gets no browser step.**'
        Assert-Phrase -Text $script:WitnessText -Where 'witness' `
            -Phrase 'That section is the only input this procedure takes'
        Assert-Phrase -Text (Get-HandSection 'Skills') -Where 'the CLAUDE.md Skills section' `
            -Phrase 'A brief with no such section gets no browser step at all.'
    }

    It 'is named inline as a reference procedure with its own load trigger' {
        $skills = Get-HandSection 'Skills'
        Assert-Phrase -Text $skills -Where 'the CLAUDE.md Skills section' `
            -Phrase '`witness` - load before writing a `## Browser checks` section into a brief'
        Assert-Phrase -Text $skills -Where 'the CLAUDE.md Skills section' `
            -Phrase 'Six more are reference procedures'
    }

    # A skill nothing delivers is a skill nobody follows, and naming one delivers nothing: skills
    # live in this repository and a worker runs in the target project's worktree. So the procedure
    # travels as a file, through the same Read-first copy every other settled file uses, and the
    # slot naming it sits above `## Done means`, which is the line the worker delivers on.
    It 'reaches the worker as a file, because a skill does not travel to another repo' {
        Assert-Phrase -Text (Get-HandSection 'Skills') -Where 'the CLAUDE.md Skills section' `
            -Phrase ('hand the worker the file itself under `Read first` rather than naming the ' +
                     'skill: skills exist in this repository only')

        $musterMd = Join-Path $script:Root '.claude\skills\muster\SKILL.md'
        $template = @(Get-CodeFence $musterMd |
            Where-Object { $_.Contains('## Goal') -and $_.Contains('## Done means') })
        $template.Count | Should -Be 1 -Because 'the brief template is one fence'
        $t = $template[0]
        $t.Contains('## Browser checks') |
            Should -BeTrue -Because 'the browser step needs a slot in the artefact the worker reads'
        $t.Contains('read-first\SKILL.md') |
            Should -BeTrue -Because 'the worker is pointed at the copy it can actually open'
        $t.Contains('read-first\BrowserVerify.psm1') |
            Should -BeTrue -Because 'the module travels the same way, into the one place it reaches'
        $t | Should -Not -Match 'read-first\\SKILL\.md[\s\S]*?\\bin\\BrowserVerify\.psm1' `
            -Because 'the installation''s own bin\ is not a place a worker can reach'
        $t.IndexOf('## Browser checks') | Should -BeLessThan $t.IndexOf('## Done means')

        # Both paths in that slot, not just the module one. A worker inherits a server environment
        # that predates the variable, so either path written against it names no file at all.
        $slot = $t.Substring($t.IndexOf('## Browser checks'))
        $slot = $slot.Substring(0, $slot.IndexOf("`n## "))
        $slot | Should -Not -Match '\$env:KINGSHAND_HOME' -Because 'a worker cannot expand it'

        # Every other section of the template stays in every brief. This one arriving by accident
        # is a browser step on a migration, so the fence itself has to say to delete it.
        $t.Contains('## Browser checks  <- delete this whole section unless the task renders something to look at') |
            Should -BeTrue -Because 'the only optional section needs the marker inside the fence'
    }

    # A record nobody reads back is an assertion again. The worker writes the verdict, and these
    # are the two places on the Hand's side that have to act on it - otherwise a change that was
    # never exercised lands looking exactly like one that was.
    It 'reads the verdict back before the work is called done or landed' {
        $step6 = Get-MusterStep 'Step 6 - Completion'
        Assert-Phrase -Text $step6 -Where 'muster Step 6' `
            -Phrase '**A brief that asked for browser checks needs a report that answers them.**'
        Assert-Phrase -Text $step6 -Where 'muster Step 6' `
            -Phrase ('A report without one is the same failure as a missing report and gets the ' +
                     'same treatment')
        Assert-Phrase -Text $step6 -Where 'muster Step 6' `
            -Phrase '**Read the verdict on that block and relay it as a finding.**'

        Assert-Phrase -Text (Get-MusterStep 'Step 7 - Gate two') -Where 'the landing gate floors' `
            -Phrase ('Never land a browser verdict that is not `verified`. A brief that asked for ' +
                     'browser checks and came back `failed`, `not verified` or with no ' +
                     '`## Browser verification` block at all goes to the user, on any posture.')
    }

    # Both ways: no section on a task that renders nothing, and no bare list of things to look at
    # on a task that does.
    It 'keeps the section out of every brief that does not need one' {
        $step2 = Get-MusterRegion -FromHeading 'Step 2 - Write a brief' -ToHeading 'Step 3 - Gate one'
        Assert-Phrase -Text $step2 -Where 'muster Step 2' `
            -Phrase '**`Browser checks` is the one optional section, and it is optional both ways.**'
        Assert-Phrase -Text $step2 -Where 'muster Step 2' `
            -Phrase ('**hand the worker the two files the step runs on rather than their names**')
        Assert-Phrase -Text $step2 -Where 'muster Step 2' `
            -Phrase '**Those copies do not discharge the index line.**'
    }


    # The server disconnected twice inside one conversation, so this path runs often. An absent
    # browser has exactly one honest outcome and it is not a quiet one.
    It 'treats an absent browser as verification that did not happen' {
        Assert-Phrase -Text $script:WitnessText -Where 'witness' `
            -Phrase '**When `$tools.available` is false, stop and write the record.**'
        Assert-Phrase -Text $script:WitnessText -Where 'witness' `
            -Phrase 'the change was not exercised in a browser'
        Assert-Phrase -Text $script:WitnessText -Where 'witness' `
            -Phrase '**Never let that read as a pass**'
        Assert-Phrase -Text $script:WitnessText -Where 'witness' `
            -Phrase 'never soften it to "verified by inspection"'
    }

    It 'loads the browser tools in one call, and asks for every tool it then requires' {
        Assert-Phrase -Text $script:WitnessText -Where 'witness' `
            -Phrase 'load them in **one** call rather than one call per tool'

        # The fence is what a reader copies. A skill that tells you to load a narrower set than
        # its own availability check demands would fail closed on every run, for ever.
        Import-Module (Join-Path $script:Root 'bin\BrowserVerify.psm1') -Force
        $fence = @(Get-CodeFence $script:WitnessMd |
                       Where-Object { $_.Contains('select:mcp__claude-in-chrome__') })
        $fence.Count | Should -Be 1 -Because 'one batched load, stated once'
        foreach ($tool in (Get-BrowserRequiredTools)) {
            $fence[0].Contains($tool) |
                Should -BeTrue -Because "the batched load must include $tool, which the check requires"
        }
    }

    # The King's standing rule is that nothing changes on a server without his word. A
    # verification step is not an exemption from it.
    It 'stays read-only unless the brief authorised the action by name' {
        Assert-Phrase -Text $script:WitnessText -Where 'witness' `
            -Phrase '**Anything that changes state on a server is different, and the brief has to authorise it.**'
        Assert-Phrase -Text $script:WitnessText -Where 'witness' `
            -Phrase 'the check is recorded `not checked` with the reason, and you move on'
        Assert-Phrase -Text $script:WitnessText -Where 'witness' `
            -Phrase '**Do not ask** - there is nobody attached to a background worker'
    }

    It 'defers to the queued confirmation posture instead of growing a second one' {
        Assert-Phrase -Text $script:WitnessText -Where 'witness' `
            -Phrase '**Do not build a second confirmation path here**'
    }

    # One stray confirm costs the whole run, and nobody is there to dismiss it.
    It 'forbids opening a dialog, and says what to do instead' {
        Assert-Phrase -Text $script:WitnessText -Where 'witness' `
            -Phrase '**there is nobody attached to a background worker**'
        Assert-Phrase -Text $script:WitnessText -Where 'witness' `
            -Phrase 'Do not click a control that is guarded by a confirmation'
        Assert-Phrase -Text $script:WitnessText -Where 'witness' `
            -Phrase 'log it and read it back with `read_console_messages`'
    }

    # A worker inherits its parent's environment at creation, so a login set today is invisible
    # to it. A bare $env: read is the failure, and it looks exactly like a wrong password.
    It 'reads a login from the environment and never writes it down' {
        Assert-Phrase -Text $script:WitnessText -Where 'witness' `
            -Phrase ('**No credential is ever written into this skill, a brief, a report or any ' +
                     'file under `data\`.**')
        Assert-Phrase -Text $script:WitnessText -Where 'witness' `
            -Phrase '**Never fall back to a bare `$env:NAME` read**'
        Assert-Phrase -Text $script:WitnessText -Where 'witness' `
            -Phrase 'the silent failure looks exactly like a wrong password'

        # The worked example must not do the thing the rule beside it forbids: an unassigned call
        # prints the login into a pane whose scrollback the Hand reads.
        Assert-Phrase -Text $script:WitnessText -Where 'witness' `
            -Phrase '**Be honest about what that costs.**'
        $fences = @(Get-CodeFence $script:WitnessMd |
                        Where-Object { $_.Contains('Get-BrowserCredentialValue') })
        $fences.Count | Should -Be 1
        $fences[0] | Should -Match '\$\w+\s*=\s*Get-BrowserCredentialValue' `
            -Because 'the example assigns the login rather than echoing it'
    }

    # The headline requirement: a record of what was seen, per check, with nothing dropped.
    It 'gives every check one of three outcomes and skips none of them' {
        Assert-Phrase -Text $script:WitnessText -Where 'witness' `
            -Phrase '**an item that could not be checked is reported, never skipped**'
        Assert-Phrase -Text $script:WitnessText -Where 'witness' `
            -Phrase ('**`verified`** with what was observed, **`failed`** with what was observed ' +
                     'instead, **`not checked`** with the reason')
        Assert-Phrase -Text $script:WitnessText -Where 'witness' `
            -Phrase 'a pass with no evidence behind it is exactly what this replaces'
        Assert-Phrase -Text $script:WitnessText -Where 'witness' `
            -Phrase '**Copy the check ids out of the brief before you start**'
    }

    # A record built at the end from what the worker remembers doing is how a check goes missing,
    # and the ids the brief declared are the only thing that catches it. The skill's own snippet
    # has to hand them over, and the function has to take them.
    It 'answers on the checks the brief declared, not just the ones the worker reported' {
        Import-Module (Join-Path $script:Root 'bin\BrowserVerify.psm1') -Force
        (Get-Command Get-BrowserVerificationRecord).Parameters.ContainsKey('Declared') |
            Should -BeTrue -Because 'the skill tells the worker to pass the declared ids'

        $fence = @(Get-CodeFence $script:WitnessMd |
                       Where-Object { $_.Contains('Get-BrowserVerificationRecord') })
        $fence.Count | Should -BeGreaterThan 0
        foreach ($f in $fence) {
            $f.Contains('-Declared') |
                Should -BeTrue -Because 'every call a worker copies has to carry what was asked for'
        }
    }

    It 'keeps the evidence as text, in the one file that survives teardown' {
        Assert-Phrase -Text $script:WitnessText -Where 'witness' `
            -Phrase '**Screenshots and recordings are not evidence this produces**'
        Assert-Phrase -Text $script:WitnessText -Where 'witness' `
            -Phrase 'write it into `report.md` under `## Browser verification`'
    }

    It 'says which worker drives the browser, and what that costs' {
        Assert-Phrase -Text $script:WitnessText -Where 'witness' `
            -Phrase ('**The worker making the change does, at the end of its own task, before it ' +
                     'runs the review gate.**')
        Assert-Phrase -Text $script:WitnessText -Where 'witness' `
            -Phrase 'Not a second worker afterwards.'
    }

    It 'gives the module its own row in the tooling table' {
        Assert-Phrase -Text (Get-HandSection 'Tooling') -Where 'the CLAUDE.md tooling table' `
            -Phrase ('| `bin\BrowserVerify.psm1` | the three answers a browser check must not give ' +
                     'from memory: whether the browser tools all loaded, where a login is set ' +
                     'without ever writing it down, and what a run of checks verified, failed or ' +
                     'could not check |')
    }

    It 'records why the opt-in is not a registry field, and what would change that' {
        Assert-Phrase -Text $script:BrowserDoc -Where 'the browser verification record' `
            -Phrase '## The opt-in lives in the brief, not the registry'
        Assert-Phrase -Text $script:BrowserDoc -Where 'the browser verification record' `
            -Phrase '**What would change this decision:**'
    }

    It 'records the measurement behind the credential rule' {
        Assert-Phrase -Text $script:BrowserDoc -Where 'the browser verification record' `
            -Phrase '**Do not replace that second read with a bare `$env:` lookup.**'
        Assert-Phrase -Text $script:BrowserDoc -Where 'the browser verification record' `
            -Phrase ('**an item that could not be checked is reported, never skipped.**')
    }
}

# The per-project rules file, and the one rule that makes it worth having: it reaches a worker
# mechanically. Delivery by memory has already failed once here - a settled brand spec sat in data\
# naming itself the input to the website brief while the site shipped without its logo, favicon,
# tagline or palette, because no brief named the file. A per-project file is that failure with a
# shorter fuse, because it applies to every task in the project rather than one.
Describe 'a project carries standing rules that reach every worker without being passed' {
    BeforeAll {
        $script:RulesOwn    = Get-HandSection 'What you own'
        $script:RulesRoute  = Get-HandSection 'Knowledge routing'
        $script:RulesAnnex  = Get-DocText $script:ImportMd
    }

    It 'CLAUDE.md names the file and says what it is for' {
        Assert-Phrase -Text $script:RulesOwn -Where 'CLAUDE.md ownership' `
            -Phrase ('`data\rules-<project>.md` - one project''s standing rules: conventions, ' +
                     'vocabulary, ticket tagging and casing, folders never to touch, branch naming, ' +
                     'environment facts, and where a login is kept.')
        Assert-Phrase -Text $script:RulesOwn -Where 'CLAUDE.md ownership' `
            -Phrase 'Not criteria and never self-reported against'
        Assert-Phrase -Text $script:RulesOwn -Where 'CLAUDE.md ownership' `
            -Phrase '`annex` owns its format and offers to create it at import.'
    }

    # The actual requirement. Everything else is supporting: a file the Hand has to remember to
    # pass is a file that gets forgotten, and the forgetting is silent.
    It 'CLAUDE.md says the dispatcher delivers both without being asked' {
        Assert-Phrase -Text $script:RulesOwn -Where 'CLAUDE.md ownership' `
            -Phrase ('**Both of those reach a worker mechanically. `bin\Dispatch-Worker.ps1` ' +
                     'attaches whichever of the two exists to every brief for that project and ' +
                     'names each copy under `Read first` itself,**')
        Assert-Phrase -Text $script:RulesOwn -Where 'CLAUDE.md ownership' `
            -Phrase 'so delivery never depends on your remembering to pass it'
    }

    # This repository is public, data\ being gitignored is one `git add -f` from a permanent leak,
    # a read-first file is copied per dispatch and outlives every worker, and report.md is durable
    # and indexed. Three concrete routes out, none hypothetical.
    It 'a credential value is never written into either file' {
        Assert-Phrase -Text $script:RulesOwn -Where 'CLAUDE.md ownership' `
            -Phrase ('Never store a credential value in either one: name the environment variable ' +
                     'or the credential-store entry that holds it, and nothing else.')
        Assert-Phrase -Text $script:RulesAnnex -Where 'the import skill' `
            -Phrase ('**A credential value is never written here, or in `done-<name>.md`. Name the ' +
                     'pointer.**')
        Assert-Phrase -Text $script:RulesAnnex -Where 'the import skill' `
            -Phrase 'one `git add -f` away from a permanent, unwithdrawable leak'
        Assert-Phrase -Text $script:RulesAnnex -Where 'the import skill' `
            -Phrase 'duplicated once per worker and outlive every one of them'
    }

    # Measured rather than assumed, because the failure it would have caused is indistinguishable
    # from a wrong password: a pointer to a variable no worker can see.
    It 'the import skill records that a variable set today reaches a worker' {
        Assert-Phrase -Text $script:RulesAnnex -Where 'the import skill' `
            -Phrase ('Measured 2026-09-04 against a herdr server that had been up for over 24 ' +
                     'hours: a variable created after the server started was visible to a shell ' +
                     'the server spawned seconds later')
    }

    # A one-sentence result nobody can re-check is a belief. The note carries the method and the raw
    # output, so a later session can run it again rather than take this on trust - and the skill
    # points at it, because a note nothing references is a note nobody opens.
    It 'the measurement behind that claim is recorded where it can be re-run' {
        $note = Join-Path (Split-Path $PSScriptRoot -Parent) `
                          'docs\2026-09-04-worker-environment-propagation.md'
        Test-Path -LiteralPath $note | Should -BeTrue
        Assert-Phrase -Text $script:RulesAnnex -Where 'the import skill' `
            -Phrase 'docs\2026-09-04-worker-environment-propagation.md'

        $text = Get-Content -LiteralPath $note -Raw
        foreach ($required in @(
            'PROBEVAL=[set-after-server-start-034115]',   # the raw output, not a paraphrase of it
            '2026-09-02 22:56',                           # server start, against a 2026-09-04 test
            'herdr workspace create',                     # the method, step by step
            'herdr pane run',
            'herdr pane read',
            'Re-running it')) {
            $text.Contains($required) | Should -BeTrue -Because "the note must record '$required'"
        }
    }

    It 'the import skill offers the file at import and writes nothing when there is nothing to write' {
        Assert-Phrase -Text $script:RulesAnnex -Where 'the import skill' `
            -Phrase '**Ask, in one line, whether this project has standing rules a worker must know**'
        Assert-Phrase -Text $script:RulesAnnex -Where 'the import skill' `
            -Phrase 'If they name none, **write nothing**.'
    }

    # Rules and criteria are different things handled differently, and conflating them is what this
    # file exists to undo: a worker recording n/a against "our tickets are tagged NG-" dilutes the
    # self-check on the lines that are really tested.
    It 'the import skill separates rules from criteria and says how to tell them apart' {
        Assert-Phrase -Text $script:RulesAnnex -Where 'the import skill' `
            -Phrase '**It holds rules and context, never criteria.**'
        Assert-Phrase -Text $script:RulesAnnex -Where 'the import skill' `
            -Phrase ('A criterion is something a worker can report `pass` or `fixed` against, and ' +
                     'those belong in `data\done-<name>.md`')
        Assert-Phrase -Text $script:RulesRoute -Where 'CLAUDE.md knowledge routing' `
            -Phrase ('Test the two apart by asking whether a worker could report pass or fixed ' +
                     'against it; where it could not, it is a rule and not a criterion.')
    }

    # The King asked for a year, and meant it. chronicle curates against a budget and archives what
    # goes stale, so without this a curation pass eventually deletes a standing instruction.
    It 'nothing expires the file' {
        Assert-Phrase -Text $script:RulesAnnex -Where 'the import skill' `
            -Phrase '**Nothing expires this file.**'
        Assert-Phrase -Text $script:RulesAnnex -Where 'the import skill' `
            -Phrase 'it stands until the King changes or removes it'
        Assert-Phrase -Text $script:RulesRoute -Where 'CLAUDE.md knowledge routing' `
            -Phrase ('Both are outside `chronicle`''s budget and its sweep, and nothing expires them.')
    }

    # The dispatcher writes to the brief now, and statute said in plain words that it never did.
    It 'statute no longer claims the dispatcher never writes to a brief' {
        $g = Get-DocText $script:GuidelinesMd
        Assert-Phrase -Text $g -Where 'the statute skill' `
            -Phrase ('it does add lines to a brief - one `Read first` line per standing file it ' +
                     'attached for the resolved project')
        $g.Contains('it never adds a line to a brief') |
            Should -BeFalse -Because 'the dispatcher does add lines to a brief now'
    }
}

Describe 'a parked decision reaches the Hand, and the answer reaches the worker back' {
    # A worker is a detached process with nobody attached. `petition` said it routes an ask-user
    # finding to the Hand and nothing implemented that route, so on 2026-09-01 a worker decided five
    # of them itself - correctly, by breaking the rule, because following it meant hanging. The route
    # is built entirely from what already existed: `report.md` is written mid-run, the Step 4 wait
    # already wakes on a settled worker, `axi run` already returns at the gate leaving the run
    # parked, and `Send-HerdrPrompt` already steers a live worker.
    #
    # What the route's *state* rides on was replaced after nine review rounds. It used to be a fixed
    # heading and an entry protocol inside `report.md`, read as prose - so every round turned up one
    # more shape nobody had listed, and the rules for reading it ended up longer than the route
    # itself. It is now `waiting_on` on the worker's own crew record: a nullable pointer at the
    # tasks-axi hold carrying the decision. Its presence is the state, so there is nothing to
    # enumerate and no next shape to discover.
    BeforeAll {
        $script:RouteBlocks = @(Get-CodeFence $script:MusterMd |
            Where-Object { $_.Contains("Implemented and committed on this worktree's branch.") } |
            ForEach-Object { ConvertTo-NormalisedText $_ })
        $script:RouteStep6  = Get-MusterStep 'Step 6 - Completion'
        $script:RouteHold   = Get-DocText $script:HoldMd
        $script:RouteFences = @(Get-CodeFence $script:MusterMd)
    }

    It 'all four Done-means blocks send an unsettled decision to the report as prose' {
        $script:RouteBlocks.Count | Should -Be 4
        foreach ($block in $script:RouteBlocks) {
            $block.Contains('**Write it as prose, the way you would put it to a colleague at their desk.**') |
                Should -BeTrue -Because 'the report carries the question and the reasoning, which is what prose is for'
            $block.Contains('Nothing parses this file, so there is no heading to match exactly, no slug to keep and no marker to get wrong') |
                Should -BeTrue -Because 'a worker told to write a marker exactly is a worker that can get it wrong'
        }
    }

    # The whole point of the replacement, asserted as an absence. Every one of these strings was a
    # thing a worker had to produce exactly so the Hand could parse it back, and each was a state
    # some review round found one more shape of.
    It 'no block asks a worker to write a marker the Hand parses back' {
        foreach ($block in $script:RouteBlocks) {
            $block.Contains('## Waiting on a decision') |
                Should -BeFalse -Because 'the route stopped reading its state out of the report'
            $block.Contains('`###` sub-heading') |
                Should -BeFalse -Because 'an entry protocol is a format, and a format has malformed cases'
            $block.Contains('on a line starting `Answer:`') |
                Should -BeFalse -Because 'whether a decision is answered is the hold, not a line in a file'
        }
    }

    # The load-bearing half for the worker: ending a turn is not the same as ending the work. A
    # worker that reads it as "stop" undoes its own change or reports failure, and the parked run
    # loses everything it was holding.
    It 'all four say ending the turn is not ending the work, and forbid unwinding it' {
        foreach ($block in $script:RouteBlocks) {
            $block.Contains('**Ending your turn is not the end of your work.**') |
                Should -BeTrue -Because 'stopping and waiting are different, and the worker has to be told which'
            $block.Contains('The answer comes back to you as an ordinary prompt and you carry on from there') |
                Should -BeTrue -Because 'the worker must know an answer is coming, or it will not wait for one'
            $block.Contains('do not undo what you have done, do not pick a different task, and do not report the work as failed') |
                Should -BeTrue -Because 'a worker that unwinds its own change while waiting loses the run'
            $block.Contains('A second question later is just another question, written the same way.') |
                Should -BeTrue -Because 'parking twice needed a rule of its own only while the report held the state'
        }
    }

    # Only the two no-mistakes blocks have a gate, so only they carry the parked-run half. Pinned at
    # two rather than four so moving it into a block with no gate fails here.
    It 'the two no-mistakes blocks leave the gate run parked rather than aborting it' {
        $parked = @($script:RouteBlocks | Where-Object { $_.Contains('**Leave the run parked while you wait.**') })
        $parked.Count | Should -Be 2 -Because 'a review gate exists only in the two no-mistakes variants'
        foreach ($block in $parked) {
            $block.Contains('the run still owns the branch and every fix commit it has already made') |
                Should -BeTrue -Because 'the reason to leave it parked is what stops someone aborting it'
            $block.Contains('Do not abort it, do not start a second run') |
                Should -BeTrue -Because 'an abort strands the gate fix commits in its own staging repo'
            $block.Contains('apply it with `no-mistakes axi respond` on that same run') |
                Should -BeTrue -Because 'the answer continues the parked run rather than starting a new one'
        }
    }

    # --yes is the exact flag that lets a worker decide its own ask-user findings: the tool documents
    # it as auto-resolving every gate including ask-user findings, with no escalation. Naming it is
    # the difference between a prohibition a worker can apply and one it cannot.
    It 'and forbid the one flag that would let a worker decide the finding itself' {
        $parked = @($script:RouteBlocks | Where-Object { $_.Contains('**Leave the run parked while you wait.**') })
        foreach ($block in $parked) {
            $block.Contains('never pass `--yes` - that flag decides ask-user findings itself with no escalation, which is the one thing you may not do') |
                Should -BeTrue -Because 'the worker never decides its own ask-user finding, and this is how it would'
        }
    }

    # And the other way it would, which needs no flag at all. Routing a gate ask-user finding into
    # the decision bullet put the pre-existing stated-assumption escape hatch directly behind it: a
    # worker could write "assuming he wants the shorter copy", respond to the gate with its own
    # answer and carry on. The escape hatch stays - it is the ordinary case - but not for these.
    It 'the assumption escape hatch is closed to a gate ask-user finding' {
        $parked = @($script:RouteBlocks | Where-Object { $_.Contains('**Leave the run parked while you wait.**') })
        $parked.Count | Should -Be 2
        foreach ($block in $parked) {
            $block.Contains('Where you can proceed on a stated assumption instead, do that: record the assumption in `report.md` and continue rather than stopping.') |
                Should -BeTrue -Because 'the ordinary case still prefers a recorded assumption to stopping'
            $block.Contains('**A finding the gate classified `ask-user` is never one of those.**') |
                Should -BeTrue -Because 'an assumption stated over one of those is the worker answering it itself'
            $block.Contains('write it down as the bullet above says and wait, however obvious the answer looks from here') |
                Should -BeTrue -Because 'the worker needs the alternative named, not only the prohibition'
        }
    }

    # muster names a Done-means bullet by its text and never by its position, and says so where the
    # `Drive the pipeline` line is introduced. An ordinal here pointed four bullets short of the one
    # it meant - at `Drive the pipeline through to a pull request` - so a worker reading literally
    # drove a parked gate finding to a PR instead of writing it down and waiting.
    It 'the parked-run bullet names the bullet it defers to by its text' {
        $parked = @($script:RouteBlocks | Where-Object { $_.Contains('**Leave the run parked while you wait.**') })
        $parked.Count | Should -Be 2
        foreach ($block in $parked) {
            $block.Contains('it takes the `When you reach a decision your brief does not settle` bullet below') |
                Should -BeTrue -Because 'a bullet named by position points at whatever was inserted above it since'
            $block.Contains('so it takes the bullet below') |
                Should -BeFalse -Because 'that ordinal pointed at the pull-request bullet instead'
        }
    }

    # A parked worker settles, shows no prompt and has written its report, so it passes Step 6's
    # three facts exactly as a delivery does. Something has to tell them apart or the Hand tears
    # down a worker that is mid-run - and that something is now a field rather than a file.
    It 'Step 6 tells a parked worker from a finished one by the pointer, not the report' {
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase '**A worker parked on a decision passes all three and is not finished either.**'
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase ('What separates it from a delivery is not in that file at all - **it is ' +
                     '`waiting_on` on the worker''s own record:**')
    }

    # Two values and no third, which is the property the whole change was made for. Absent is
    # normalised to null on the way in by Crew.psm1, so nobody downstream gets a third case to
    # handle and nobody has to enumerate one.
    It 'the pointer has two values, and absent is not a third' {
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase ('**The field is set or it is not, and there is no third value. A null means ' +
                     'no park has been recorded on this record, and never that there is nothing ' +
                     'to answer; set means it parked, and the field names the hold carrying what ' +
                     'it parked on.**')
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase ('`Import-CrewState` gives every record the field whether or not it was saved ' +
                     'with one, so absent and null are one case rather than two.')
    }

    # The field is write-once-per-park and never cleared, and that is what keeps its null honest.
    # Clearing it on the way back out gave one null two opposite meanings - never parked, and
    # parked-answered-and-carried-on - which the route then had no way to tell apart.
    It 'Step 6 never clears the pointer, and says what a cleared one would cost' {
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase ('**It is written on the turn the worker parks and never cleared**, so it ' +
                     'keeps naming that hold for the rest of the worker''s life')
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase ('**The pointer is not cleared here, or anywhere, ever - there is no verb for ' +
                     'it.**')
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase ('Clearing it would put two opposite meanings on one null - a worker that ' +
                     'never parked, and a worker that parked, was answered and carried on')
        $script:RouteStep6.Contains('Clear-CrewWaitingOn') |
            Should -BeFalse -Because 'the verb was removed, and a step that still calls it is a step that cannot run'
    }

    # The half the field does NOT carry, stated where the field is introduced so nothing downstream
    # has to infer it. Whether the decision is still owed is the hold's, and reading it off the
    # pointer is how a pointer turns back into a state machine.
    It 'Step 6 leaves open-or-closed to the hold rather than reading it off the pointer' {
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase ('**Whether that decision is still outstanding is not this field''s to say, ' +
                     'and nothing here restates it.**')
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase ('open and the worker is waiting, closed and it is answered, with the ' +
                     '`answered:` or `declined:` note `decree` requires on the close saying what ' +
                     'was decided')
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase ('Two sources, each owning its own half. `decree` owns the hold''s lifecycle ' +
                     'and `petition` owns who may answer it')
        # And the read itself is runnable, because a described command is one nobody has run.
        @($script:RouteFences | Where-Object { $_.Contains('$key = $rec.waiting_on') }).Count |
            Should -Be 1 -Because 'the open-or-closed half is read from the queue, not guessed'
    }

    # Said in the file itself, so a reader who finds the old heading in git history reads it as
    # superseded rather than as a rule somebody lost - and so a later editor knows that putting the
    # state back into the report is a reversal rather than a tidy-up. The evidence behind it is
    # narrative, so it lives in the dated note and the step cross-references it rather than
    # carrying it on every load.
    It 'Step 6 says the prose state it replaced was replaced deliberately' {
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase ('**This replaced a heading the Hand used to read out of `report.md`, and the ' +
                     'replacement was deliberate.**')
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase ('`docs\2026-09-04-parked-decision-route.md` carries the evidence and what a ' +
                     'future change must not undo.')
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase ('The report still carries the question and the reasoning, which is what prose ' +
                     'is good for; it stopped being where the system reads whether.')
    }

    # $w is Step 4's wake object and the three completion facts are read off it. Binding the crew
    # record over it inside the same step leaves the instructed re-read returning $null, so the
    # names are kept apart and the reason is stated where the second object is introduced.
    It 'Step 6 keeps the crew record and the wake object under different names' {
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase '**Inside this step the worker''s record is `$rec` and never `$w`.**'
        # Scoped, because Step 7 and Step 8 legitimately bind the record to $w with no wake object
        # in scope - an unscoped rule invites a later editor to churn them into agreement.
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase ('The rule is this step''s alone: Step 7 and Step 8 bind the record to `$w` ' +
                     'with no wake object in scope, and neither is a collision to go and tidy.')
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase ('binding the record over it leaves the re-read returning `$null` under normal ' +
                     'mode and throwing under `Set-StrictMode`')
        @($script:RouteFences | Where-Object { $_.Contains('$w = Get-CrewWorker') -and
            $_.Contains('waiting_on') }).Count |
            Should -Be 0 -Because 'the wake object must survive the pointer read'
    }

    # The field is the discriminator, but nothing writes it except a Hand who read the report - so
    # on a worker's FIRST park the pointer is null for want of a reader, not for want of a
    # decision. Without an ordered instruction to read on a null, the parked worker passes all
    # three facts, takes `gating`, lands and is torn down with its question answered nowhere. The
    # order has to be stated as an instruction, not left as a property of the field.
    It 'Step 6 orders the report read on every wake the worker is not waiting' {
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase ('**So the order is fixed. After the three facts, read the pointer - and ' +
                     'unless it names a hold that is still open, read ' +
                     '`$env:KINGSHAND_HOME\data\<id>\report.md` before you may treat that worker ' +
                     'as a delivery:**')
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase ('**A null says no park has been recorded on this record, and nothing ' +
                     'more.**')
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase ('the field is only ever written by a Hand who read that report, so on a first ' +
                     'park it stays null until somebody looks')
        # A steered worker goes back to work and can reach a SECOND decision. Excusing the read on
        # a closed hold is how that one is landed and torn down with its question answered nowhere,
        # which is the same irreversible failure the first park's read exists to prevent.
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase '**A pointer naming a closed hold does not excuse the read either.**'
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase ('a steered worker goes back to work and can reach a second decision its brief ' +
                     'does not settle just as easily as the first')
        # Exactly one exemption, and it is the one where the worker is not delivering anything.
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase ('**The one wake that needs no report read is a pointer naming a hold still ' +
                     'open**')
        # And no count anywhere: "once" is what made the rule depend on how many times anyone had
        # looked rather than on what the two sources say.
        $script:RouteStep6.Contains('That read of the report happens once') |
            Should -BeFalse -Because 'a counted read cannot see a worker that parks a second time'
    }

    # The one place the report is still read for this, and the turn the pointer is set. Registering
    # without pointing leaves the decision durable but the worker unmarked, so the landing gate and
    # the teardown both read it as delivered.
    It 'Step 6 sets the pointer in the same turn it registers the decision' {
        # The trigger is keyed on what the queue covers, not on the pointer being null - a second
        # park arrives with the closed hold of the first still named, and it is the same trigger.
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase ('**Where the report names a decision the worker''s brief did not settle and ' +
                     'no hold of this worker''s covers it, that is `decree`''s trigger and nobody ' +
                     'has pulled it yet.**')
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase ('A first park reaches it with a null pointer and a second with a pointer ' +
                     'naming the closed hold of the decision before it; both are the same trigger')
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase 'Register the decision there, and record the key it was registered under in the same turn'
        # A person reading a question, and a rule stated as a condition rather than as a count.
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase ('**That read is a person reading a question rather than a check parsing a ' +
                     'file, and it is the same read the fixed order above requires - not a second ' +
                     'one.**')
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase ('It is not counted, and it is not "once per worker": a worker steered past ' +
                     'one decision can reach another')
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase ('a restart, a compaction or a session that dispatched nothing reads two ' +
                     'recorded values instead of re-deriving one from prose')
    }

    # One writer and no way back, because the field is the only way the route records that a park
    # happened. A Hand editing crew.json by hand is a Hand writing a key that matches no hold.
    It 'Step 6 carries one runnable call for setting the pointer, and none for unsetting it' {
        $set = @($script:RouteFences | Where-Object {
            $_.Contains('Set-CrewWaitingOn -State $s -WorkerId "<id>" -HoldKey "<the key decree registered it under>"') })
        $set.Count | Should -Be 1 -Because 'the pointer is set in one place, when the decision is registered'
        $set[0].Contains('Save-CrewState -State $s -Path $env:KINGSHAND_HOME\state\crew.json') |
            Should -BeTrue -Because 'a pointer that was never saved does not survive the session it was set in'

        @($script:RouteFences | Where-Object { $_.Contains('Clear-CrewWaitingOn') }).Count |
            Should -Be 0 -Because 'there is no clearing verb, and a fence calling one would not run'
    }

    # No table, and that is the assertion. Nine rounds of findings were each one more row nobody had
    # listed; a field that is set or null has no rows. If a later edit rebuilds an enumeration over
    # this state, this fails.
    It 'Step 6 enumerates no states at all' {
        $script:RouteStep6.Contains('Every combination has an outcome') |
            Should -BeFalse -Because 'an enumeration that has to be complete is the defect this replaced'
        $script:RouteStep6.Contains('| unanswered |') |
            Should -BeFalse -Because 'the state table went with the prose state it was reading'
        $script:RouteStep6.Contains('## Waiting on a decision') |
            Should -BeFalse -Because 'nothing reads that heading any more'
        $script:RouteStep6.Contains('`Answer:` line') |
            Should -BeFalse -Because 'answered is what the hold records, not what the report is formatted like'
    }

    # The floor the state table used to carry as its stopping row. It survives as a rule about a
    # breach rather than as a row - but it cannot fire on "a decision the brief did not settle"
    # alone, because every brief tells the worker to proceed on a stated assumption and record it
    # in exactly that file. Written flat, the rule condemns a worker for following its instructions
    # and stalls delivered work. The discriminator is petition's reversibility test, cross-
    # referenced rather than restated, so there is one test and not a second one growing here.
    It 'Step 6 still refuses to ratify a worker that answered its own question' {
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase ('**Proceeding on a stated assumption is not a worker answering its own ' +
                     'question - every brief grants that hatch and tells it to record the ' +
                     'assumption in `report.md` and carry on rather than stopping.**')
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase ('What decides it is which side of `petition`''s reversibility test the call ' +
                     'sat on. **That test is stated there and not restated here**')
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase ('**A worker that resolved a call on the far side of that test, with no hold ' +
                     'ever registered for it, answered its own question - and its brief forbids ' +
                     'that outright.**')
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase ('Establish that first, from what the report actually claims: the two read ' +
                     'identically on the page until the test is applied to the call itself')
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase ('load `rally`, and read everything else it claims with the same suspicion a ' +
                     'missing report earns.')
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase ('Do not register that answer afterwards to make the record tidy: filing it ' +
                     'durably asserts that somebody with the authority gave it.')
        # The flat form, asserted as an absence: it fired on every recorded assumption.
        $script:RouteStep6.Contains('carried on past a decision its brief did not settle, with no') |
            Should -BeFalse -Because 'the briefs grant exactly that where the call is cheap to undo'
        # And the test itself stays in one place - a copy here is a copy that drifts.
        $script:RouteStep6.Contains('reversible in minutes') |
            Should -BeFalse -Because 'petition owns the reversibility test, and this cross-references it'
    }

    # Teardown is the irreversible one. It ends the process holding the parked run, so the answer
    # has nowhere to go and the gate's own fix commits are left in its staging repo.
    It 'Step 6 forbids advancing or tearing down a worker that is still waiting' {
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase ('**Do not set `gating`, do not close the backlog item, and above all do not ' +
                     'tear it down.**')
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase 'Teardown ends the process holding that parked run, and the answer then has nowhere to go.'
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase 'With all three confirmed and no hold of this worker''s still open, **set its stage to `gating`**'
    }

    It 'Step 6 loads petition before answering and leaves the hold to decree' {
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase ('**Load `petition` before answering it - whatever the posture, and whether or ' +
                     'not the King is at the machine.**')
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase 'it is the only place that test is stated'
        # One owner for the hold, cross-referenced rather than restated - which is what let the two
        # drift into contradicting each other twice in the previous run.
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase ('**`decree` owns the hold from its reason to its closing note, and nothing ' +
                     'here restates any of it.**')
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase ('what an open hold with no note means and how its reason tells the two causes ' +
                     'apart, what the closing note has to carry, and that the dependent work is ' +
                     'blocked before the hold closes')
        # Either way, and that word is the fix: petition scoped this to the wait branch, so a
        # finding the Hand answered in the King's stead was registered nowhere and the only record
        # of it was a return digest that dies with the session.
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase ('Both branches are registered there - an answer he still owes and an answer ' +
                     'you gave in his stead - because neither survives this session in chat or in ' +
                     'a return digest.')
    }

    # The interruption window has an order, and the order picks what a later session finds. Send
    # first and an interruption leaves an open hold the worker already acted on, which puts the same
    # question to the King twice - the cost decree exists to prevent.
    It 'Step 6 records and closes the decision before the steer is sent' {
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase ('**Where you are answering it, the block and the closing note go in before ' +
                     'the send, not after.**')
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase ('Close first and it finds a closed hold the worker has not been told about, ' +
                     'which sends the answer on once. Send first and it finds an open hold the ' +
                     'worker has already acted on, which puts the same question to the King a ' +
                     'second time.')
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase '`decree` owns the sequence itself, block before close.'
        # decree's own sequence says the same thing without restating the reasoning.
        Assert-Phrase -Text $script:RouteHold -Where 'the decree operating sequence' `
            -Phrase ('Where that answer is going back to a parked worker, this close comes before ' +
                     'the steer is sent; `muster` Step 6 owns that route and why the order matters.')
    }

    # The answer travels by the steer that already exists. Asserted as runnable text rather than as
    # prose about a steer: this is the one command the route depends on, and a described command is
    # one nobody has run.
    It 'Step 6 carries a runnable steer, not a description of one' {
        $fence = @($script:RouteFences |
            Where-Object { $_.Contains('Send-HerdrPrompt -Name "<worker id>" -Text "<the decision, and the reason for it>"') })
        $fence.Count | Should -Be 1 -Because 'the answer goes back by one steer, stated once'
        $fence[0].Contains('Read-HerdrAgent -Name "<worker id>" -Lines 20') |
            Should -BeTrue -Because 'a steer nobody read back is not a steer'
        # Herdr.psm1 documents the race: `agent prompt` returns before the state machine moves, so
        # a worker that is about to work still reads `idle` and a wait armed on the send returns at
        # once claiming a completion. Step 4 already forbids that; the fence has to obey it.
        $fence[0].Contains("Wait-HerdrAgent -Name ""<worker id>"" -Until 'working' -TimeoutMs 120000") |
            Should -BeTrue -Because 'the worker has to leave idle before a fresh wait is armed over it'
    }

    # Two failure modes of the steer itself, both already real in this repository: a prompt box
    # holding text nobody sent refuses the send outright, and a resumed worker with no wait armed is
    # the exact silence the Step 4 wait exists to prevent.
    It 'Step 6 names the refused send and re-arms the wait on a resumed worker' {
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase ("The send is refused outright when that worker's input box already holds " +
                     'text this session did not write')
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase '`rally` owns what to do about it rather than `-AllowNonEmptyBox` being reached for here'
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase ('**the worker is working again the moment the answer lands, so re-arm the ' +
                     'Step 4 wait**')
    }

    # The ordering the fence depends on, said in prose as well, and pointed at the Step 4 bullet
    # that already owns the reasoning rather than copying it down here.
    It 'Step 6 arms the fresh wait only once the worker has left idle' {
        # Single-quoted, because a backtick inside a double-quoted PowerShell string is the escape
        # character and silently drops the backticks the literal line carries.
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase ('**Arm it after that `-Until ''working''` line and never straight after the ' +
                     'send.**')
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase ('Step 4''s `Never arm the wait immediately after submitting a prompt without ' +
                     'accounting for stale state` bullet owns why')
        # `Wait-HerdrAgent` returns $null for a timeout and for a herdr error alike, and the module
        # names that ambiguity itself. So the null cannot be reported as a lost answer: a server
        # that stopped answering while the worker took the steer looks identical, and every
        # fail-closed path here has to name its own failure rather than pick one.
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase ('Where `working` never arrives inside those two minutes, the wait came back ' +
                     '`$null` and that is two things at once: the answer never landed, or herdr ' +
                     'stopped answering while the worker took it anyway.')
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase '**Do not report either one - the null does not say which.**'
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase ('Read the screen and check what the worker is actually doing, and load ' +
                     '`rally` where the screen cannot tell you')
    }

    # The close goes in before the send, so an interruption between the two leaves an answered
    # decision the worker was never told about. The pointer cannot spot that any more - it names the
    # same key either way - so the report is what tells a landed steer from one that never went, and
    # the recovery is one sentence rather than a table of the states it could be in.
    It 'Step 6 recovers a steer that never landed from the report, not from the pointer' {
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase '**A closed hold does not by itself say the worker was told.**'
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase ('The close goes in before the send, so an interruption between the two leaves ' +
                     'an answered decision the worker never heard - and the report is what tells ' +
                     'that from a steer that landed.')
        # The one judgement is delegated to the skill that already owns "what is this worker
        # actually doing" rather than growing a rule of its own here.
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase ('Where it does not show the worker acting on the decision, take the worker''s ' +
                     'condition from `rally` and send that note''s answer once.')
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase ('Do not decide it again: it is answered, and a worker told to decide the ' +
                     'same thing twice does the work twice.')
    }

    # Without this the step reads straight on into `gating` over a worker that resumed seconds ago:
    # the three facts were confirmed before the steer, and the pointer has just been cleared - so
    # nothing downstream catches it, and a `+yolo` project diffs and lands a worktree still being
    # written to.
    It 'Step 6 ends the pass at the re-armed wait rather than reading on into gating' {
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase ('**This pass ends at that re-armed wait, and nothing below it runs on this ' +
                     'one.**')
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase ('the next wake re-enters this step from the top against the state as it is ' +
                     'then')
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase ('on a `+yolo` project Step 7 would then diff and land a worktree that is ' +
                     'still being written to')
        # And the stage was never moved, so there is nothing to restore - which is the whole reason
        # waiting is a pointer rather than a seventh stage.
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase 'The stage stays exactly where it is - waiting was never a stage, so there is nothing to put back'
    }

    # Step 6 was the only place that protected a parked worker, and Step 0 routes "land / merge /
    # ship a worker" straight to Step 7 - so a parked worker could reach the landing gate, close-out
    # and teardown without Step 6 ever running, and Step 8b's own floor is satisfied by a pushed
    # branch. All three read the pointer now, which is the one thing here that cannot be malformed.
    It 'the landing gate, close-out and teardown each refuse a worker whose pointer is set' {
        Assert-Phrase -Text (Get-MusterStep 'Step 7 - Gate two: approve the landing') `
            -Where 'the landing gate floors' `
            -Phrase '**Never land a worker whose pointer names a hold that is still open.**'
        # The pointer is never cleared, so a set field on its own would refuse every worker that was
        # ever answered - for the rest of its life. The floor reads both sources: the field says
        # which decision, the hold says whether it is still owed.
        Assert-Phrase -Text (Get-MusterStep 'Step 7 - Gate two: approve the landing') `
            -Where 'the landing gate floors' `
            -Phrase ('**Read the pointer, and where it names a key read that hold**: the field ' +
                     'says which decision, and the hold says whether it is still owed.')
        Assert-Phrase -Text (Get-MusterStep 'Step 7 - Gate two: approve the landing') `
            -Where 'the landing gate floors' `
            -Phrase ('A closed one is answered rather than outstanding, and it is not on its own ' +
                     'a reason to refuse a landing.')
        # The one honest limit of a pointer: it is written by a Hand reading a report, so neither a
        # null nor a closed hold is current on its own - and direct entry skips that read entirely.
        # The detour is therefore unconditional. It cannot key on the stage: Step 6's parked path
        # runs to completion and leaves the stage alone, so `implementing` does not mean Step 6 has
        # not run - and it cannot key on memory either, which is the session-only discriminator an
        # earlier round of this same work already found and removed once.
        Assert-Phrase -Text (Get-MusterStep 'Step 7 - Gate two: approve the landing') `
            -Where 'the landing gate floors' `
            -Phrase ('**Nothing here is a delivery on the pointer alone** - a pointer that names ' +
                     'nothing, and one naming a hold already closed, are both only as current as ' +
                     'the last read of that worker''s report')
        Assert-Phrase -Text (Get-MusterStep 'Step 7 - Gate two: approve the landing') `
            -Where 'the landing gate floors' `
            -Phrase '**Do not try to work out whether one has already happened.**'
        Assert-Phrase -Text (Get-MusterStep 'Step 7 - Gate two: approve the landing') `
            -Where 'the landing gate floors' `
            -Phrase ('Step 6''s parked path runs to completion and deliberately leaves the stage ' +
                     'where it was, so `dispatched` and `implementing` are what a worker steered ' +
                     'an hour ago still reads')
        # The false premise itself, asserted as an absence: it read as not applying to any Hand who
        # knew Step 6 had run, which is every Hand that steered the worker in this same session.
        (Get-MusterStep 'Step 7 - Gate two: approve the landing').Contains(
            'means neither Step 6 nor Step 8a has run') |
            Should -BeFalse -Because 'Step 6''s parked path completes without moving the stage'
        Assert-Phrase -Text (Get-MusterStep 'Step 8a') -Where 'muster Step 8a' `
            -Phrase ('**It does mean the one check Step 6 owns has not run, so run it here: a ' +
                     'worker whose pointer names a hold that is still open is mid-run, and so is ' +
                     'one whose report names a decision no hold covers.**')
        Assert-Phrase -Text (Get-MusterStep 'Step 8b') -Where 'muster Step 8b' `
            -Phrase ('**A worker whose pointer names a hold that is still open is never torn down ' +
                     'either, and a confirmed push does not release that.**')
        Assert-Phrase -Text (Get-MusterStep 'Step 8b') -Where 'muster Step 8b' `
            -Phrase ('Teardown ends the live process, and that process is what the answer is ' +
                     'coming back to')
        # The teardown reads the two recorded sources and nothing else. Left free to re-read the
        # report it would rebuild a second, weaker reading of the same state - which is exactly how
        # three guards ended up with three different ideas of what unanswered meant.
        Assert-Phrase -Text (Get-MusterStep 'Step 8b') -Where 'muster Step 8b' `
            -Phrase '**Read those two and nothing else.**'
        Assert-Phrase -Text (Get-MusterStep 'Step 8b') -Where 'muster Step 8b' `
            -Phrase ('neither of them can be malformed - which is exactly why the route stopped ' +
                     'keeping this state in the worker''s own prose')
        Assert-Phrase -Text (Get-MusterStep 'Step 8b') -Where 'muster Step 8b' `
            -Phrase ('Do not go looking through `report.md` for a heading, a marker or a question ' +
                     'that reads as unanswered')
        # The hold read has to be runnable at the guard that cannot be taken back, or "still open"
        # is a judgement rather than a lookup.
        @(Get-CodeFence $script:MusterMd | Where-Object {
            $_.Contains('$key = (Get-CrewWorker -State $s -WorkerId "<id>").waiting_on') }).Count |
            Should -Be 1 -Because 'the teardown decides on the hold it reads, not on the field alone'
    }

    It 'decree stops describing the worker as stopped, and routes the answer back into its own item' {
        Assert-Phrase -Text $script:RouteHold -Where 'decree' `
            -Phrase ('Ending a turn is not the end of the work - `muster` Step 6 owns the route ' +
                     "that carries the Hand's answer back into a worker still waiting on one.")
        Assert-Phrase -Text $script:RouteHold -Where 'decree' `
            -Phrase ("**Where the answer went back into a worker already running on this work's " +
                     'own item, that item is the dependent one and no second is created**')
    }

    # Three places in decree say what happens to an authorised answer, and for a while only one of
    # them knew about the parked worker: a Hand following the operating sequence literally filed the
    # same work twice. All three carry the branch now, and the block still happens either way -
    # block first, close second is what records in the queue that the answer authorised anything.
    It 'decree says the same thing in the note convention, the command table and the sequence' {
        Assert-Phrase -Text $script:RouteHold -Where 'the decree command table' `
            -Phrase '`tasks-axi add <work-id> "<one line>"` where no item holds that work yet'
        Assert-Phrase -Text $script:RouteHold -Where 'the decree command table' `
            -Phrase 'skip the `add` and block that existing item'
        Assert-Phrase -Text $script:RouteHold -Where 'decree step 6' `
            -Phrase ('Where the answer went back into a worker already running on this ' +
                     "work's own item, that item is the one to block and no second is filed")
        Assert-Phrase -Text $script:RouteHold -Where 'decree step 6' `
            -Phrase 'the block is still what records that the answer authorised the work'
    }

    # decree used to have to make the key reconstructible from report prose, because reading it back
    # was the only way a later session could find the hold. The pointer is that lookup now, so the
    # composition rule collapses back to the general one - and the ownership split is stated in both
    # files in a line each rather than restated in either.
    It 'decree looks the parked decision key up rather than re-deriving it' {
        Assert-Phrase -Text $script:RouteHold -Where 'decree' `
            -Phrase ('**Where the decision came from a parked worker, the key is stable, ' +
                     'privacy-safe and slug-shaped like any other, and it is always prefixed ' +
                     'with the work id.**')
        Assert-Phrase -Text $script:RouteHold -Where 'decree' `
            -Phrase ('`muster` Step 6 writes the key you registered onto that worker''s own record ' +
                     'the same turn it registers the decision, so wherever that pointer is set a ' +
                     'later session looks the key up rather than reconstructing it from what a ' +
                     'worker happened to write.')
        Assert-Phrase -Text $script:RouteHold -Where 'decree' `
            -Phrase '`muster` owns it and this skill owns the key itself'
        # The key must NOT become free-form just because the pointer usually answers the lookup.
        # Nothing that says a key need not be re-derivable may come back: registering and pointing
        # are two commands, so there is a window with an open hold and no pointer, and the general
        # stability rule higher in this same file is what covers it.
        $script:RouteHold.Contains('the key does not have to be re-derivable') |
            Should -BeFalse -Because 'the register-then-point window has no pointer to look up'
    }

    # The window itself: hold registered, session ended, pointer never written. Both files have to
    # carry the same recovery or the next session invents a second key, and the King is asked the
    # same question twice while the first hold is orphaned. The recovery is a queue lookup on the
    # work-id prefix - reinstating a parse of report prose would be the defect this change removed.
    It 'both files recover an open hold with no pointer by looking the work id up in the queue' {
        Assert-Phrase -Text $script:RouteHold -Where 'decree' `
            -Phrase ('**The pointer is the direct lookup, and the work-id prefix is what covers ' +
                     'the window where there is no pointer yet.**')
        Assert-Phrase -Text $script:RouteHold -Where 'decree' `
            -Phrase ('It looks the work id up in the queue before registering anything, and ' +
                     'points the record at the open hold there that covers the decision the ' +
                     'report names - the work id narrows the search and the decision itself ' +
                     'selects among what it returns.')
        Assert-Phrase -Text $script:RouteHold -Where 'decree' `
            -Phrase ('Replaying `add` under an existing key changes nothing, so the pointer ends ' +
                     'up on the hold that exists.')
        # The work id alone does not identify the hold: a lookup that takes what the work id
        # returned aims the pointer at a live decision belonging to something else and steers the
        # worker on an answer that was never about it. Unestablished means escalate, not pick - and
        # the guard is keyed on coverage rather than on a count, so a single open hold whose reason
        # does not establish coverage is refused by the same sentence. Keyed on the count, exactly
        # one candidate reads as "take it", which is the failure this rule was added for.
        Assert-Phrase -Text $script:RouteHold -Where 'decree' `
            -Phrase ('**Where which open captain hold covers this decision cannot be ' +
                     'established, do not guess and do not take the first** - say so and ' +
                     'escalate, naming the candidates.')
        Assert-Phrase -Text $script:RouteHold -Where 'decree' `
            -Phrase ('That is keyed on coverage and not on how many candidates the work id ' +
                     'returned: a lone open hold whose reason does not establish that it covers ' +
                     'this decision is refused by this same sentence')
        $script:RouteHold | Should -Not -Match 'more than one open captain hold' `
            -Because 'a count-keyed guard reads as take-it when exactly one candidate comes back'
        Assert-Phrase -Text $script:RouteHold -Where 'decree' `
            -Phrase ('It does not replay `hold`: that one is a write, and it would overwrite the ' +
                     'reason the open hold is already carrying.')
        Assert-Phrase -Text $script:RouteHold -Where 'decree' `
            -Phrase ('**That recovery is a queue lookup and never a reading of report prose**')
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase ('**Look up every hold this work already has before registering anything - ' +
                     'the closed ones as much as an open one.**')
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase ('a null pointer over a report naming a decision has two causes: nobody ' +
                     'registered it, or somebody did and the pass ended before the pointer went in')
        # muster executes the procedure decree owns the key for, so its open branch selects on the
        # same thing decree does: coverage. Keyed on the hold merely existing under the work id, an
        # open hold belonging to another of this work's decisions captures this one - the decision
        # is never registered, and the answer to the other one is steered into a worker that asked
        # something else. The two adjacent rules would then give opposite instructions.
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase ('**Where an open `--kind captain` hold covers the decision the report ' +
                     'names, point the record at that same key rather than filing a second one.**')
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase ('What selects it is coverage and never its merely existing under this work id')
        $script:RouteStep6 | Should -Not -Match 'hold for this work is already there' `
            -Because 'an existence-keyed branch captures another decision''s open hold'
        # decree owns the coverage test; muster points at it rather than restating it.
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase ('`decree` owns that test and what to do where coverage cannot be established.')
        # And the lookup is the queue's, not the report's - stated in muster too, because that is
        # where the temptation is: the report is already open on the screen at this point.
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase 'the queue is the only place they are answered - do not go back to the report for a key'
    }

    # A second park replaces the key rather than keeping a list, which is intended - the earlier
    # decisions stay durable as their own closed holds with the answers on them. But a lookup that
    # returns only OPEN holds cannot see those, so every decision but the most recent reads as one
    # no hold covers: the Hand either re-files an answered question, putting it to the King twice
    # and writing an `answered:` note nobody authorised, or accuses delivered work of answering
    # itself. The lookup has to reach the closed ones for the trigger to mean anything.
    It 'the lookup reaches closed holds, so an answered decision is not re-filed' {
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase ('the pointer is a link to the current decision rather than a log of them, so ' +
                     'a worker parked twice names only its second while the first stays durable ' +
                     'as its own closed hold carrying the answer it was given')
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase ('**A decision a closed hold already covers is answered** - however long ago, ' +
                     'and whoever gave it - so it is neither registered again nor read as a ' +
                     'question the worker answered itself.')
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase ('Filing it a second time puts it to the King twice and writes a second ' +
                     '`answered:` note asserting an authorisation nobody gave.')
        # And the enumeration is runnable and covers both states. `ready --include-held` returns
        # queued and held work only, so on its own it can never answer "was this already decided".
        $lookup = @($script:RouteFences | Where-Object { $_.Contains('tasks-axi list --state done') })
        $lookup.Count | Should -Be 1 -Because 'a closed hold is how an answered decision is recorded'
        $lookup[0].Contains('tasks-axi list --state held') |
            Should -BeTrue -Because 'the open half is read in the same lookup, not a separate pass'
        # tasks-axi prunes closed items into the archive and never reads that file back, so the
        # queue alone answers this only for as long as retention lasts. Every lookup the route runs
        # has to reach the archive, or a decision answered months ago reads as one nobody made.
        $lookup[0].Contains('data\done-archive.md') |
            Should -BeTrue -Because 'a pruned hold is answered, not absent'
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase ('**The archive line is not optional, for the reason the pointer read-back ' +
                     'names**: a hold pruned out of the backlog is invisible to `list` and still ' +
                     'answered')
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase ('**`NOT_FOUND` from `show` is not an answer on its own - a closed hold gets ' +
                     'pruned out of the backlog.**')
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase ('a key found there is answered, and a key in neither place is a record that ' +
                     'has gone missing rather than a decision nobody made')
        @($script:RouteFences | Where-Object {
            $_.Contains('$key = $rec.waiting_on') -and $_.Contains('data\done-archive.md') }).Count |
            Should -Be 1 -Because 'the pointer read-back is the other lookup that goes blind on a prune'
        # All three copies of this lookup guard it, or a never-parked worker produces NOT_FOUND
        # plus an empty archive match and gets read as a record that has gone missing.
        @($script:RouteFences | Where-Object {
            $_.Contains('$key = $rec.waiting_on') -and $_.Contains('if ($key) {') }).Count |
            Should -Be 1 -Because 'a null pointer must not be handed to show as an empty argument'
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase ('**The `if ($key)` is the same guard the other two copies of this lookup ' +
                     'carry, and it is not decoration.**')
        # Measured against tasks-axi 0.2.5: an empty id is `Missing id` / VALIDATION_ERROR, and
        # NOT_FOUND is what a real key that is absent returns. This section's authority is that
        # its facts were measured, so the guard's justification has to name the right one.
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase ('it is a command that never ran: `error: Missing id`, `code: ' +
                     'VALIDATION_ERROR`')
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase ('A worker that has simply never parked would send the Hand chasing a record ' +
                     'that never existed')
        $script:RouteStep6.Contains('hands `show` an empty argument, which comes back `NOT_FOUND`') |
            Should -BeFalse -Because 'an empty id is a validation error, and NOT_FOUND is a different answer'
    }

    # The archived entry of a key this route looks up was a hold, so it carries the hold suffixes.
    # The rendering is stated here because the anchor is written by hand against it.
    It 'renders the archive entry as the tool actually writes it for a hold' {
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase ('`- [x] <key> - <title> (done <date>) (hold: <reason>) (hold-kind: <kind>)`')
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase ('with the `answered:` note on the continuation line below it')
    }

    # The claim the whole parked-worker stall guard turns on: a motionless screen over an open
    # hold is expected rather than wedged. Soften or delete it and rally's refusal to relaunch a
    # parked worker loses its justification, so it is pinned as a sentence rather than by theme.
    It 'Step 6 says a worker on an open hold is idle rather than hung' {
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase '**A worker waiting on an open hold is idle rather than hung**'
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase ('the review-gate run it left parked keeps the branch and every fix commit ' +
                     'already made')
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase ('**Do not set `gating`, do not close the backlog item, and above all do not ' +
                     'tear it down.**')
    }

    # Two mechanical facts this round's instructions got wrong against the real tool, both of which
    # produce a wrong outcome silently. Backlog.Tests.ps1 drives tasks-axi and PowerShell to prove
    # each one; these pin that the instructions match what was proven.
    It 'the field lists are quoted, because PowerShell splits a bare comma list' {
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase '**Quote the field list, and every field list.**'
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase ('PowerShell reads a bare `hold_kind,hold_reason` as a two-element array and ' +
                     'hands the native command one space-joined token, which `tasks-axi` refuses ' +
                     'with `VALIDATION_ERROR` and no rows at all')
        $lookup = @($script:RouteFences | Where-Object { $_.Contains('tasks-axi list --state held') })
        $lookup.Count | Should -Be 1
        $lookup[0].Contains("--fields 'hold_kind,hold_reason'") |
            Should -BeTrue -Because 'unquoted, the command returns a validation error and no holds'
        $lookup[0] -match '--fields\s+hold_kind,hold_reason' |
            Should -BeFalse -Because 'that exact form is the one that fails'
    }

    # Backlog.Tests.ps1 drives the real tool to prove both halves of this against tasks-axi: the
    # error block is on stdout with a non-zero exit, and the filter drops the column header. These
    # pin that the fence and its prose carry what was proven.
    It 'the queue reads fail closed and keep their column header' {
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase ('**Capture each read and check its exit code before filtering, because a ' +
                     'failed lookup must never read as an empty one.**')
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase ('`tasks-axi` prints its error block on stdout, not stderr, and exits ' +
                     'non-zero, so a filter applied straight to the pipeline swallows the failure')
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase ('Surface the tool''s own output and stop the lookup - a read that could not ' +
                     'get its evidence names the failure rather than passing for an answer.')
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase '**Let the `tasks[` header through with the matched rows.**'
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase ('so a headerless row can only be read by counting commas')

        $lookup = @($script:RouteFences | Where-Object { $_.Contains('tasks-axi list --state held') })
        $lookup.Count | Should -Be 1
        # Both reads are captured and both are guarded. A guard on one leaves the other fail-open.
        @([regex]::Matches($lookup[0], '\$LASTEXITCODE -ne 0')).Count |
            Should -Be 2 -Because 'the held read and the done read each have to name their own failure'
        @([regex]::Matches($lookup[0], 'throw "')).Count |
            Should -Be 2 -Because 'surfacing the output without stopping still continues on no evidence'
        $lookup[0] -match '(?m)^\s*tasks-axi list [^\r\n]*\|\s*$' |
            Should -BeFalse -Because 'a filter on the pipeline itself is what swallowed the error block'
        $lookup[0].Contains('^tasks\[|') |
            Should -BeTrue -Because 'the header alternative is what keeps the column names'
    }

    It 'nothing replays hold on an open hold, because the replay overwrites its reason' {
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase '**Do not replay `hold` on a hold that is already open.**'
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase ('That reason is the only thing recording whose question the hold is, so a ' +
                     'boilerplate replacement leaves a correctly escalated decision looking like ' +
                     'a pass nobody can classify')
        Assert-Phrase -Text $script:RouteHold -Where 'the decree mechanical facts' `
            -Phrase '**`add` is idempotent under the same key. `hold` is not.**'
        Assert-Phrase -Text $script:RouteHold -Where 'the decree mechanical facts' `
            -Phrase ('it prints `ok: hold <key> -> held (<kind>)`, never `already: true`, and it ' +
                     'overwrites both `hold_reason` and `hold_kind` with whatever the replay passed')
        Assert-Phrase -Text $script:RouteHold -Where 'the decree mechanical facts' `
            -Phrase ('passing nothing passes nothing, so an omitted `--kind` writes `-` over ' +
                     '`captain` rather than leaving it where it was')
        # muster's copy of the leave-it-alone rule has to name the kind too, or a re-run that
        # dutifully restores the reason still erases the marking that routes it to the King.
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase ('pass back both the reason and the `--kind` it already carries rather than a ' +
                     'new reason and no kind')
        # The claim that was wrong, asserted as an absence in both files that leaned on it.
        foreach ($text in @($script:RouteHold, $script:RouteStep6)) {
            $text.Contains('`add` and `hold` are idempotent') |
                Should -BeFalse -Because 'only add is, and the difference destroys the reason discriminator'
            $text.Contains('`add` and `hold` are both idempotent') |
                Should -BeFalse -Because 'the same claim in its other wording'
        }
    }

    # The archive lines are read with Select-String, so they are the one place in this route where
    # a match is written by hand rather than answered by the tool - and a bare substring there says
    # "answered" over a longer key that merely starts the same way.
    It 'every archive read is anchored to a whole entry rather than a substring' {
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase ('**Every archive read is anchored to the whole key on its own entry, never a ' +
                     'bare substring.**')
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase ('a bare match for `t-100-copy` finds `t-100-copy-length` in it - so an ' +
                     'unregistered decision reads as answered, and at the teardown a record that ' +
                     'has gone missing reads as one that is fine')
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase ('`[regex]::Escape` is not decoration either: a key may carry a `.`, which is ' +
                     'a wildcard unescaped.')
        # Every fence that reads the archive anchors it, and none of them is left on -SimpleMatch.
        $archiveFences = @(Get-CodeFence $script:MusterMd | Where-Object { $_.Contains('done-archive.md') })
        $archiveFences.Count | Should -Be 3 -Because 'the pointer read-back, the enumeration and the teardown all read it'
        foreach ($fence in $archiveFences) {
            $fence.Contains('^\s*-\s*\[x\]\s*') |
                Should -BeTrue -Because 'the archived entry begins the line, and that is what bounds the match'
            $fence.Contains('-SimpleMatch') |
                Should -BeFalse -Because 'a simple match cannot be anchored, which is how the bug got in'
        }
    }

    # A key is `<work-id>-<slug>`, so a bare-prefix match for T-100 also selects every T-1001- key.
    # On the open branch that points a worker at another work's live decision and steers it on an
    # answer that was never about it. The delimiter the composition already guarantees is the fix.
    It 'both files match the work id with its delimiter rather than as a bare prefix' {
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase ('**Match on the work id followed by its delimiter - `<work-id>-`, never a ' +
                     'bare prefix.**')
        Assert-Phrase -Text $script:RouteStep6 -Where 'muster Step 6' `
            -Phrase ('a bare prefix match for `T-100` also returns every `T-1001-` hold, which on ' +
                     'the open branch below would point this worker at another work''s live ' +
                     'decision')
        Assert-Phrase -Text $script:RouteHold -Where 'decree' `
            -Phrase ('**That lookup matches the full key, or the work id with the `-` that ' +
                     'follows it, and never a bare prefix.**')
        Assert-Phrase -Text $script:RouteHold -Where 'decree' `
            -Phrase ('without it, `T-100` selects every `T-1001-` key as well, and the recovery ' +
                     're-registers a worker against a live decision belonging to another piece of ' +
                     'work entirely')
    }

    # The teardown is the guard that cannot be taken back, and a pruned key answers NOT_FOUND there
    # too. Reading that as "no open hold, carry on" is right by luck; reading it as "no record at
    # all" has to stop, because a mistyped key and a moved queue file answer identically.
    It 'the teardown treats a missing record as a cause to establish, not a pass' {
        Assert-Phrase -Text (Get-MusterStep 'Step 8b') -Where 'muster Step 8b' `
            -Phrase '**`NOT_FOUND` from `show` is not permission to tear down.**'
        Assert-Phrase -Text (Get-MusterStep 'Step 8b') -Where 'muster Step 8b' `
            -Phrase ('Only a closed hold is ever archived, so a key the archive holds **on its ' +
                     'own entry** is answered and this worker may be stopped.')
        Assert-Phrase -Text (Get-MusterStep 'Step 8b') -Where 'muster Step 8b' `
            -Phrase ('A key in neither place is a record that has gone missing - a mistyped key, ' +
                     'a queue file that moved - and at the one guard that cannot be taken back ' +
                     'that is a cause to establish, never a pass.')
        @(Get-CodeFence $script:MusterMd | Where-Object {
            $_.Contains('$key = (Get-CrewWorker -State $s -WorkerId "<id>").waiting_on') -and
            $_.Contains('data\done-archive.md') }).Count |
            Should -Be 1 -Because 'the irreversible guard reads the archive too, or it goes blind on a prune'
        # And the anchor is named at the guard as well, because this is where a spurious match is
        # read as permission to stop a worker.
        Assert-Phrase -Text (Get-MusterStep 'Step 8b') -Where 'muster Step 8b' `
            -Phrase ('matched as a bare substring, a longer key sharing this one''s opening reads ' +
                     'as this one''s answer, and the guard passes on a record nobody has actually ' +
                     'found')
    }

    # The open-hold ambiguity is decree's, not muster's: both causes are `--kind captain` and
    # neither carries a note, so the reason is the only thing that can say which. What changed is
    # who acts on it - petition owns both branches, and muster no longer carries a table of them.
    It 'decree keeps the reason that tells the two open holds apart, and petition acts on it' {
        Assert-Phrase -Text $script:RouteHold -Where 'decree' `
            -Phrase '**The reason says which of the two open holds this is, and that is not optional.**'
        Assert-Phrase -Text $script:RouteHold -Where 'decree' `
            -Phrase ('he genuinely has the question, or the Hand was answering it in his stead ' +
                     'and the pass ended before the note went in')
        Assert-Phrase -Text $script:RouteHold -Where 'decree' `
            -Phrase ('the reason states it in words: that the question is with him and what he ' +
                     'has to choose, or that you are answering it in his stead under ' +
                     '`petition`''s test and which way')
        Assert-Phrase -Text $script:RouteHold -Where 'decree' `
            -Phrase ('The reason is what a later session reads to tell them apart, and `petition` ' +
                     'owns what each one does next: a question that is genuinely with him waits, ' +
                     'and an interrupted stead pass is re-entered on that skill''s test and ' +
                     'finished.')
        # And the repair for a reason that says neither, on a field and a verb that already exist.
        Assert-Phrase -Text $script:RouteHold -Where 'the decree lifecycle table' `
            -Phrase '| repair a reason that does not say which of the two open holds it is |'
        Assert-Phrase -Text $script:RouteHold -Where 'the decree lifecycle table' `
            -Phrase ('re-running `hold` under the same key rewrites the reason in place without ' +
                     'opening a second hold, which is why this is a repair and not something to ' +
                     'run by habit')
        # Verified against the real tool: an omitted --kind writes `-` over `captain`, so the row
        # has to carry the kind or the repair silently drops the decision off King's Call.
        Assert-Phrase -Text $script:RouteHold -Where 'the decree lifecycle table' `
            -Phrase '**The `--kind` is not optional on this row.**'
        Assert-Phrase -Text $script:RouteHold -Where 'the decree lifecycle table' `
            -Phrase ('An omitted one is not left alone: it is cleared to `-`, and the hold stops ' +
                     'being a captain hold, which drops the decision out of King''s Call and out ' +
                     'of the open-hold lookup that recovers an orphaned registration')
        $script:RouteHold.Contains('without opening a second hold or moving anything else') |
            Should -BeFalse -Because 'the replay does move something else, and the row said it did not'
    }

    # The repair row gives the command but a Hand has to know which of the two it is before it can
    # be run - so without an outcome for the ambiguous reason itself, the Hand guesses. This is the
    # default, and it has to be written AS a default: an enumeration of two branches plus a third
    # named case is the shape that spent nine rounds acquiring one more member.
    It 'decree gives an ambiguous reason a safe default rather than a third branch' {
        Assert-Phrase -Text $script:RouteHold -Where 'decree' `
            -Phrase ('**A reason that says neither is not a third branch to take - it is a cause ' +
                     'not yet established, and that is the default for every reason nobody ' +
                     'anticipated.**')
        Assert-Phrase -Text $script:RouteHold -Where 'decree' `
            -Phrase ('Nothing is steered, nothing is closed and nothing is re-escalated while it ' +
                     'stands')
        Assert-Phrase -Text $script:RouteHold -Where 'decree' `
            -Phrase ('establish which of the two it was, repair the reason with the row above, ' +
                     'and only then take the branch the repaired reason names')
        # The asymmetry is the reason the default is the safe one rather than either guess, and it
        # is the failure a previous round removed once already.
        Assert-Phrase -Text $script:RouteHold -Where 'decree' `
            -Phrase ('guessing that the question is his parks a worker until morning over a ' +
                     'decision the Hand already had the authority to answer')
        # And the totality itself, so a later edit that turns the default back into one more listed
        # case fails here rather than in a tenth review round.
        Assert-Phrase -Text $script:RouteHold -Where 'decree' `
            -Phrase ('Stated as a default rather than as one more case, so a reason shaped in a ' +
                     'way nobody here thought of is safe rather than unmatched.')
    }

    # The durable home for a decision made in the King's stead. petition requires three things
    # recorded every time and named no destination that outlives the session, so the record lived
    # only in a regency digest built from session memory - gone on the restart CLAUDE.md treats as
    # routine, and he is never told a call was made in his name.
    It 'decree holds the record of a decision answered in the King''s stead' {
        Assert-Phrase -Text $script:RouteHold -Where 'the decree note convention' `
            -Phrase ("**A decision the Hand answered in the King's stead is one of these too, and " +
                     'its note carries three things rather than one: the decision, the reasoning, ' +
                     "and whether it rested on a recorded position or on the Hand's own " +
                     'judgement.**')
        Assert-Phrase -Text $script:RouteHold -Where 'the decree note convention' `
            -Phrase ('it is registered and closed in the same pass because nobody is being waited ' +
                     'for')
        Assert-Phrase -Text $script:RouteHold -Where 'the decree note convention' `
            -Phrase ('a regency''s return digest is built inside one session, so a restart before ' +
                     'he is back means he is never told a call was made in his name at all')
        Assert-Phrase -Text $script:RouteHold -Where 'the decree command table' `
            -Phrase ("| record a decision the Hand answered in the King's stead |")
        # The row skipped the block, which the note convention and step 6 both require: an
        # `answered:` note with no dependency edge asserts an authorisation the queue never
        # recorded. The dependent item is the one the steered worker is already running under.
        Assert-Phrase -Text $script:RouteHold -Where 'the decree command table' `
            -Phrase ('`tasks-axi block <work-id> --by <key>` against the item the parked worker is ' +
                     'already running under')
        Assert-Phrase -Text $script:RouteHold -Where 'the decree note convention' `
            -Phrase ('**It is an `answered:` note like any other, so the block still happens**')
        Assert-Phrase -Text $script:RouteHold -Where 'the decree note convention' `
            -Phrase ('skipping it leaves a closed note claiming an authorisation the queue never ' +
                     'recorded')
        # petition keeps the test and the basis definition; decree keeps the lifecycle.
        Assert-Phrase -Text $script:RouteHold -Where 'the decree note convention' `
            -Phrase ('`petition` owns which decisions those are and what a recorded position is')
        $script:RouteHold.Contains('reversible in minutes') |
            Should -BeFalse -Because 'the reversibility test is stated once, in petition'
    }

    # CLAUDE.md is always loaded, so its two inventory lines are what a Hand believes crew.json and
    # Crew.psm1 hold before reading either. Both listed a shape this change made incomplete, and an
    # incomplete inventory in the always-loaded file is how a field goes unused - which is the same
    # failure as not having added it. Corrected in place: no new rule, no net new line, and the
    # pointer's own contract still stated only in muster.
    It 'CLAUDE.md names the pointer where it inventories crew.json, and nowhere else' {
        $hand = Get-DocText $script:HandMd
        Assert-Phrase -Text $hand -Where 'the ownership list' `
            -Phrase 'worker id to ticket, repo, stage, and which decision it parked on'
        Assert-Phrase -Text $hand -Where 'the tooling table' `
            -Phrase 'point a worker at the decision it parked on'
        $hand.Contains('waiting_on') |
            Should -BeFalse -Because 'the field name and its rules belong to muster and Crew.psm1, not to the always-loaded file'
    }

    # The replacement is only finished if nothing anywhere still reads the old marker. A skill left
    # matching on a heading no worker writes is a guard that passes on every worker, forever.
    It 'no skill and no always-loaded file still reads the old heading' {
        $files = @(
            $script:MusterMd, $script:HoldMd, $script:AskUserMd, $script:StuckMd, $script:HandMd,
            (Join-Path $script:Root '.claude\skills\regency\SKILL.md')
        )
        foreach ($f in $files) {
            (Get-Content -Path $f -Raw).Contains('## Waiting on a decision') |
                Should -BeFalse -Because "$f must not read a marker no worker is asked to write"
        }
    }
}

Describe "the reversibility test owns what may be answered in the King's stead" {
    # This is the rule most likely to be softened by a later editor into "only answer what you know",
    # which reintroduces the failure it was written to end: the Hand stuck every night on SEO details
    # and copy fixes while a worker sits parked on them. So the mis-statement is named in the skill
    # and pinned here, and every branch of the test is pinned word for word rather than by theme.
    BeforeAll { $script:Away = Get-DocText $script:AskUserMd }

    It 'states the test as reversibility and refuses the knowledge reading by name' {
        Assert-Phrase -Text $script:Away -Where 'petition' `
            -Phrase '**The test is reversibility, not knowledge.**'
        Assert-Phrase -Text $script:Away -Where 'petition' `
            -Phrase ('Not what the two of you have discussed, not what you happen to know, not ' +
                     'how confident you feel - whether a wrong call can be undone in minutes.')
        Assert-Phrase -Text $script:Away -Where 'petition' `
            -Phrase ('Writing it as a knowledge test is the mis-statement to refuse: "answer only ' +
                     'what you know" parks every small consistency and copy finding until morning')
    }

    # All four exclusions, and the "away or present, discussed or not" clause that keeps presence out
    # of the test. Dropping any one of the four widens the branch silently.
    It 'the decide-it branch keeps all four exclusions and the presence clause' {
        Assert-Phrase -Text $script:Away -Where 'petition' `
            -Phrase ('**Decide it** - away or present, discussed or not - when the call is ' +
                     'reversible in minutes and is **none of**: a delete, a cost, ' +
                     'security-sensitive, or a material expansion of what the work was accepted ' +
                     'to deliver.')
        # "away or present" is the clause most likely to be read as an accident and edited out, so
        # the skill says why it is there and this pins the reason with it: what presence changes is
        # which rule reaches the finding, never whether a wrong call can be undone.
        Assert-Phrase -Text $script:Away -Where 'petition' `
            -Phrase ('The clause says away or present because presence is not what the test turns ' +
                     'on - being at the machine does not make a wrong call any harder to undo.')
        Assert-Phrase -Text $script:Away -Where 'petition' `
            -Phrase ('present, steps 3 to 5 already keep a reversible correction inside your ' +
                     'authority without this section being reached at all')
    }

    # The section is the away branch and nothing else. Step 1 gives every ask-user finding to the
    # King with `yolo` off, so a section that also read as authority while he is at the machine left
    # the Hand holding two rules for one case and no way to choose between them.
    It 'authorises an answer only where he cannot be reached' {
        Assert-Phrase -Text $script:Away -Where 'petition' `
            -Phrase ('**This section authorises an answer only where he cannot be reached, and it ' +
                     'is not reached at all while he is at the machine.**')
        Assert-Phrase -Text $script:Away -Where 'petition' `
            -Phrase ('steps 3 to 5 keep a reversible correction inside your authority where the ' +
                     'posture at step 1 leaves it there, and everything else escalates and waits')
    }

    # Parking is mode-independent - every Done-means block writes the same heading - so keying the
    # away test to the gate's own ask-user finding left a `local-only` worker parked on a decision
    # nothing claimed: regency's finished-and-unclear bullet advanced it, which muster Step 6
    # forbids, or nothing matched at all and the decision was never registered.
    It 'the away test governs any parked decision, however the worker reached it' {
        Assert-Phrase -Text $script:Away -Where 'petition' `
            -Phrase ('**Its test governs any decision a parked worker has left you, however the ' +
                     'worker reached it.**')
        Assert-Phrase -Text $script:Away -Where 'petition' `
            -Phrase ('a worker on any posture writes the question into its `report.md` and ends ' +
                     'its turn for any decision its brief did not settle, and while he is away ' +
                     'that decision is answered on the test below or it is answered nowhere')
        # What stays gate-only is the ask-user finding and the escalation written for it - not the
        # analysis, which the present-King paragraph applies to a parked decision on any posture.
        # Saying both left two adjacent paragraphs answering the same case opposite ways.
        Assert-Phrase -Text $script:Away -Where 'petition' `
            -Phrase ('What does not generalise is the ask-user finding itself: only a gated ' +
                     'project''s review gate ever produces one, exactly as `When this applies at ' +
                     'all` says, and the escalation shape above is written for that finding.')
        $script:Away.Contains('still fires for a gated project alone') |
            Should -BeFalse -Because 'the analysis reads a parked decision on any posture'
        # The true half is intact; what was cut is the claim that the whole skill never fires for a
        # non-gated project, which three other places contradict by sending the Hand here for a
        # parked decision whatever the posture - and which a `local-only` Hand reads first.
        Assert-Phrase -Text $script:Away -Where 'petition' `
            -Phrase ('it never produces an ask-user finding, and what is written here for that ' +
                     'finding - its classification, and the gate procedure around it - never ' +
                     'fires for one of those projects.')
        Assert-Phrase -Text $script:Away -Where 'petition' `
            -Phrase '**The rest of this skill fires on any posture.**'
        Assert-Phrase -Text $script:Away -Where 'petition' `
            -Phrase ('the authority analysis below reads a parked decision on a `local-only` ' +
                     'project the same way it reads a gated one, and so does the away test')
        $script:Away.Contains('this procedure never fires for it') |
            Should -BeFalse -Because 'a parked decision reaches this skill on every posture'
    }

    # The symmetric half. muster Step 6 loads petition for a parked decision whatever the posture
    # and whether or not he is at the machine, and for a non-gated project with him present the
    # skill answered neither question - the gate procedure declines it and the away section is not
    # reached - which leaves "no procedure constrains me" available on a `yolo on` project.
    # And it grants nothing by routing the case rather than deciding it. "Put it to him whatever
    # the posture" revoked the +yolo authority steps 3 to 5 state twice in this same file, which
    # would wake him for the copy fix the posture already authorised - the failure the branch exists
    # to end - so the paragraph routes and the analysis decides.
    # The description is the only part of this skill a Hand sees before deciding to load it, and on
    # eighteen of twenty-two registered projects the old one said the situation it was reading -
    # a worker parked on a `local-only` project - was not this skill's. Both triggers now, and the
    # gate-only half stated as what it actually is: where ask-user findings come from.
    It 'the description carries both triggers rather than the gate one alone' {
        $fm = Get-Frontmatter (Join-Path $script:Root '.claude\skills\petition\SKILL.md')
        $fm['description'].Contains('whenever a worker is parked on a decision its brief did not settle, on any posture including `local-only` and `direct-PR`, whether or not the King is at the machine') |
            Should -BeTrue -Because 'the parked-decision trigger fires on every posture'
        $fm['description'].Contains('before deciding any ask-user finding the no-mistakes review gate returned') |
            Should -BeTrue -Because 'the gate finding is still a trigger'
        $fm['description'].Contains('Only a `no-mistakes` review gate ever produces an ask-user finding, and the classification written for that finding fires there alone.') |
            Should -BeTrue -Because 'the gate-only half is the classification, not the whole skill'
        $fm['description'].Contains('this procedure never fires') |
            Should -BeFalse -Because 'a parked decision reaches this skill on every posture'
    }

    It 'names the present-King route for a parked decision, and grants nothing by it' {
        Assert-Phrase -Text $script:Away -Where 'petition' `
            -Phrase ('**With him at the machine, the authority analysis above routes a parked ' +
                     'decision, and this section changes none of it.**')
        Assert-Phrase -Text $script:Away -Where 'petition' `
            -Phrase ('one steps 3 to 5 keep inside your authority is still answered without ' +
                     'asking, exactly as `+yolo` and those steps already provide')
        Assert-Phrase -Text $script:Away -Where 'petition' `
            -Phrase ('waking him for a copy fix the posture already authorised is the failure ' +
                     'this whole branch exists to end')
        # The non-gated present case still has an owner, which is why the paragraph exists.
        Assert-Phrase -Text $script:Away -Where 'petition' `
            -Phrase ('a `local-only` worker''s parked question weighs the accepted contract ' +
                     'against an expansion the same way a gated one does, even though no gate ' +
                     'produced it')
        Assert-Phrase -Text $script:Away -Where 'petition' `
            -Phrase ('This section adds exactly one thing to that: the answer the test below ' +
                     'allows while he is unreachable.')
    }

    # petition scoped registration to the wait branch, so the branch it exists for recorded
    # nothing. decree owns the lifecycle; this is the one-line cross-reference to it.
    It 'registers both branches under decree rather than only the wait' {
        Assert-Phrase -Text $script:Away -Where 'petition' `
            -Phrase ('**Either branch is registered under `decree`, and its note is where those ' +
                     'three things live.**')
        Assert-Phrase -Text $script:Away -Where 'petition' `
            -Phrase ('A regency digest is built inside one session, so a restart or a compaction ' +
                     'before he is back takes it with it')
        Assert-Phrase -Text $script:Away -Where 'petition' `
            -Phrase ('`decree` owns that lifecycle, including the pass that registers a decision ' +
                     'you answered yourself and closes it in the same breath; nothing here ' +
                     'restates it.')
    }

    # "regardless of what is known" is the mirror of the test above and the half a softened rewrite
    # drops first: it is what stops a well-evidenced guess authorising a delete.
    It 'the wait branch holds regardless of what is known' {
        Assert-Phrase -Text $script:Away -Where 'petition' `
            -Phrase ('**Wait for him** on a delete, a cost, anything irreversible or anything ' +
                     'security-sensitive, **regardless of what is known**, and on a major but ' +
                     'recoverable call where nothing records his position.')
        Assert-Phrase -Text $script:Away -Where 'petition' `
            -Phrase 'Those are the floors hard rule 2 already carries, and being away never lowers them.'
    }

    # The floor a later editor would most plausibly soften back, so it is pinned hardest. The
    # earlier wording put irreversible on the conditional side of the sentence, which left a gap
    # nothing errored in: a call that cannot be undone, with a position recorded in `king.md`, was
    # authorised by neither branch and refused by neither. Hard rule 2 carries no such exception -
    # never irreversibly without the King, regardless of posture - and the intent requires the
    # floors untouched, so irreversible is unconditional and only the recoverable case reads a
    # recorded position.
    It 'no recorded position ever authorises an irreversible call' {
        Assert-Phrase -Text $script:Away -Where 'petition' `
            -Phrase '**A recorded position never authorises an irreversible action.**'
        Assert-Phrase -Text $script:Away -Where 'petition' `
            -Phrase ('Irreversible sits with the delete, the cost and the security-sensitive ' +
                     'call, in the list that waits whatever is known')
        Assert-Phrase -Text $script:Away -Where 'petition' `
            -Phrase ('a recorded position is evidence about what he wants, not his word on the ' +
                     'one kind of call nobody can take back')
        Assert-Phrase -Text $script:Away -Where 'petition' `
            -Phrase ('The recorded-position clause above is about the major-but-recoverable case ' +
                     'and only that one')
    }

    # The third of the three is the one that reads like decoration and is not. Without it a decision
    # recorded afterwards is indistinguishable from a fact somebody established, so the King can
    # review the outcome but never the reasoning behind it.
    It 'requires the decision, the reasoning, and the basis it rested on' {
        Assert-Phrase -Text $script:Away -Where 'petition' `
            -Phrase ('**Record all three, every time: the decision, the reasoning, and whether it ' +
                     'rested on a recorded position or on your own judgement.**')
        Assert-Phrase -Text $script:Away -Where 'petition' `
            -Phrase 'it is what turns a wrong call into a learning instead of a surprise'
        Assert-Phrase -Text $script:Away -Where 'petition' `
            -Phrase ('A decision recorded without it reads afterwards as a fact somebody ' +
                     'established rather than a call somebody made.')
    }

    # Closed list, deliberately. An open one lets a reviewer's language or an inferred pattern count
    # as the King's position, which is how a guess becomes a recorded fact.
    It 'closes the list of what counts as a recorded position' {
        Assert-Phrase -Text $script:Away -Where 'petition' `
            -Phrase ('A recorded position is one of exactly these: `data\done-<project>.md`, an ' +
                     "answered hold's note in the backlog, a settled decision file under " +
                     '`data\`, `data\king.md`, or an explicit statement in this session.')
        Assert-Phrase -Text $script:Away -Where 'petition' `
            -Phrase ('Reviewer language is not one, and neither is a pattern you inferred from an ' +
                     'earlier task.')
    }

    # The branch fires off the durable flag regency writes, not off a judgement about whether the
    # King seems to be around. A flag survives a session restart and a feeling does not.
    It 'reads the away state from the durable flag rather than inferring it' {
        Assert-Phrase -Text $script:Away -Where 'petition' `
            -Phrase ('He is away when `$env:KINGSHAND_HOME\state\.afk` exists; `regency` writes ' +
                     'that flag and owns everything else about the mode.')
    }

    It 'says why an unreachable escalation is not a safe default' {
        Assert-Phrase -Text $script:Away -Where 'petition' `
            -Phrase ('an escalation that cannot land is not a safe default - it is the five-hour ' +
                     'hang arriving by a different route')
    }

    # The existing authority analysis is unchanged, and step 1 has to say where the new branch
    # attaches or it goes on claiming no autonomous answer is ever authorised.
    It 'step 1 points at the branch rather than going on denying it exists' {
        Assert-Phrase -Text $script:Away -Where 'petition step 1' `
            -Phrase ('that escalation rather than authorize an autonomous answer - except where ' +
                     'the escalation cannot reach him at all, which `When the King is not there` ' +
                     'below owns and nothing else does.')
    }

    # The worker's side of the boundary did not move: it still never decides. What changed is that
    # its finding now goes somewhere and comes back.
    It 'the worker still never decides its own finding, and the route is named not restated' {
        Assert-Phrase -Text $script:Away -Where 'petition' `
            -Phrase ('It parks at the finding, routes the decision to the Hand through its ' +
                     '`report.md`, and applies only the decision that comes back, on the same ' +
                     'review-gate run it left parked.')
        Assert-Phrase -Text $script:Away -Where 'petition' `
            -Phrase '`muster` owns both halves of that route and nothing here restates it.'
    }

    # The population this was designed against: five findings on one run, every one a consistency or
    # copy problem rather than anything the King had settled.
    It 'classifies the finding shape it was designed against' {
        Assert-Phrase -Text $script:Away -Where 'petition' `
            -Phrase 'is reversible in minutes and is none of the four.'
        # The verdict is conditional, because step 1 reverses it for one real combination: a gated
        # project registered `yolo off` with the King at the machine. A flat "decided, away or
        # present" in an example a Hand reads for a case-match hands back the wrong answer with no
        # rule erroring.
        Assert-Phrase -Text $script:Away -Where 'petition' `
            -Phrase ('Away, that is what makes it yours to decide rather than park. Present, this ' +
                     'section is not reached and the posture at step 1 decides whether it is yours ' +
                     'at all - with `yolo` off it is his, however small it looks.')
        Assert-Phrase -Text $script:Away -Where 'petition' `
            -Phrase 'Five of exactly that shape came back on one run.'
        Assert-Phrase -Text $script:Away -Where 'petition' `
            -Phrase ('Deleting a guard test to make a new assertion pass is a delete, so it waits ' +
                     'however obvious the reasoning looks')
    }
}

Describe 'CLAUDE.md keeps the away boundary to a pointer' {
    BeforeAll { $script:AwayHand = Get-DocText $script:HandMd }

    # The always-loaded file outranks every skill, so a stale blanket rule here could not be
    # corrected from petition at all - that is the one reason this change touches CLAUDE.md. It is
    # narrowed to the blocked-prompt case, which is still absolute, plus one pointer.
    It 'narrows the never-answer rule to the prompt case and points the rest at petition' {
        Assert-Phrase -Text $script:AwayHand -Where 'CLAUDE.md' `
            -Phrase 'never answers a prompt a worker is blocked on'
        Assert-Phrase -Text $script:AwayHand -Where 'CLAUDE.md' `
            -Phrase ("A blocked worker's question is recorded verbatim and waits; a decision a " +
                     'worker wrote into its report is decided under `petition`, never here.')
    }

    # Absence, because the failure is a second copy rather than a missing one. The test lives in
    # petition and CLAUDE.md must not grow a paraphrase of it.
    It 'does not restate the test itself' {
        $script:AwayHand.Contains('reversible in minutes') |
            Should -BeFalse -Because 'the reversibility test is stated once, in petition'
    }

    # Single-quoted on purpose, and the backticks around yolo are why: in a double-quoted string the
    # backtick is PowerShell's escape character and they silently vanish from the pattern, so the
    # assertion stops matching the literal line it was copied from.
    It 'the petition trigger fires whether or not the King is at the machine' {
        Assert-Phrase -Text $script:AwayHand -Where 'the CLAUDE.md Skills section' `
            -Phrase ('`petition` - load before deciding any ask-user finding, and before deciding ' +
                     'any decision a worker parked on because its brief did not settle it - ' +
                     'whatever the project''s posture, and whether or not the King is at the machine.')
    }

    # The always-loaded inventory is what a Hand reads before deciding whether to load the skill at
    # all, so a stub narrower than the skill it points at is the skill going unloaded. petition now
    # has two triggers and only one of them needs a review gate - on the eighteen registered
    # projects with no gate, the parked worker is the only way it is ever reached.
    It 'the petition stub carries the parked-decision trigger, not the gate one alone' {
        Assert-Phrase -Text $script:AwayHand -Where 'the CLAUDE.md Skills section' `
            -Phrase ('Only the `no-mistakes` review gate produces an ask-user finding; a parked ' +
                     'worker happens on any posture.')
        $script:AwayHand.Contains('Only the `no-mistakes` review gate produces one.') |
            Should -BeFalse -Because 'that scoped the whole skill to the gate, and half of it fires without one'
    }
}
