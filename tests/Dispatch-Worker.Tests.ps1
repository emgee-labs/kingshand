BeforeAll {
    # Dot-sourced, not dispatched. The base-resolution rule lives in its own file precisely so
    # it can be exercised against throwaway repositories without spawning a real worker into
    # one. The dispatch block at the bottom of this file does run Dispatch-Worker.ps1, but only
    # against a herdr that is a shim on PATH - nothing there ever launches Claude Code.
    . "$PSScriptRoot\..\bin\Resolve-BaseRef.ps1"

    $script:TempFixtures = [System.Collections.Generic.List[string]]::new()

    function New-TempFixturePath {
        param([Parameter(Mandatory)][string]$Prefix)
        $p = Join-Path ([System.IO.Path]::GetTempPath()) ($Prefix + [guid]::NewGuid().ToString('N'))
        $script:TempFixtures.Add($p)
        $p
    }

    function New-TempRepo {
        param([string]$Branch = 'main', [switch]$WithOrigin, [switch]$Empty)
        $d = New-TempFixturePath -Prefix 'baseref-'
        git init -b $Branch $d -q
        git -C $d config user.name  'Test'
        git -C $d config user.email 'test@example.invalid'
        if (-not $Empty) {
            Set-Content -Path (Join-Path $d 'base.txt') -Value 'base' -Encoding utf8
            git -C $d add -A
            git -C $d commit -q -m 'Initial commit'
        }
        if ($WithOrigin) {
            $bare = "$d-remote.git"
            $script:TempFixtures.Add($bare)
            git init --bare -b $Branch $bare -q
            git -C $d remote add origin $bare
            if (-not $Empty) { git -C $d push -q origin $Branch 2>&1 | Out-Null }
        }
        $d
    }

    function Test-RefResolves {
        param([string]$RepoPath, [string]$Ref)
        $null = & git -C $RepoPath rev-parse --verify --quiet "$Ref^{commit}" 2>$null
        $LASTEXITCODE -eq 0
    }

    function Set-DeclaredBranch {
        param([Parameter(Mandatory)][string]$RepoPath, [Parameter(Mandatory)][string]$Yaml)
        Set-Content -Path (Join-Path $RepoPath '.no-mistakes.yaml') -Value $Yaml -Encoding utf8
    }

    # A repo declaring another worker's branch as where its work integrates, with that branch
    # pushed so both forms of it genuinely resolve. The declaration is refused all the same.
    function New-DeclaredWorkerBranchRepo {
        $repo = New-TempRepo -WithOrigin
        git -C $repo checkout -q -b 'worktree-other'
        Set-Content -Path (Join-Path $repo 'other.txt') -Value 'other' -Encoding utf8
        git -C $repo add -A
        git -C $repo commit -q -m 'Another worker commit'
        git -C $repo push -q origin 'worktree-other' 2>&1 | Out-Null
        git -C $repo checkout -q 'main'
        git -C $repo remote set-head origin -a 2>&1 | Out-Null
        Set-DeclaredBranch -RepoPath $repo -Yaml "pr:`n  base_branch: worktree-other"
        $repo
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

Describe 'Resolve-BaseRef - remoteless repository' {
    BeforeAll { $script:repo = New-TempRepo }

    It 'returns a ref that actually resolves' {
        $base = Resolve-BaseRef -RepoPath $script:repo
        Test-RefResolves -RepoPath $script:repo -Ref $base | Should -BeTrue
    }

    It 'returns the local default branch rather than an invented origin/ name' {
        $base = Resolve-BaseRef -RepoPath $script:repo
        $base | Should -Be 'main'
        $base | Should -Not -BeLike 'origin/*'
    }

    It 'returns the local default branch when it is not called main' {
        $trunk = New-TempRepo -Branch 'trunk'
        $base  = Resolve-BaseRef -RepoPath $trunk
        $base  | Should -Be 'trunk'
        Test-RefResolves -RepoPath $trunk -Ref $base | Should -BeTrue
    }
}

Describe 'Resolve-BaseRef - the evidence it makes possible' {
    # The regression this whole fix exists for: with an unresolvable base, `git log` and
    # `git diff` write fatal: to stderr and NOTHING to stdout, so the landing gate reads an
    # empty diff and an empty attribution scan as a clean pass. These assert the evidence is
    # really gathered, not merely that a string was returned.
    BeforeAll {
        # A remoteless repo with a branch standing in for the worker's, carrying the exact
        # trailer rule 3 forbids.
        $script:repo = New-TempRepo
        # Resolved first, in the same order dispatch does it: from the repo, before the
        # worker's branch exists.
        $script:base = Resolve-BaseRef -RepoPath $script:repo
        git -C $script:repo checkout -q -b 'worktree-probe'
        Set-Content -Path (Join-Path $script:repo 'thing.txt') -Value 'thing' -Encoding utf8
        git -C $script:repo add -A
        git -C $script:repo commit -q -m "Add thing`n`nCo-Authored-By: Claude <noreply@anthropic.com>"
    }

    It 'lets the attribution scan see a Co-Authored-By trailer it must catch' {
        $bodies = @(& git -C $script:repo --no-pager log --format='%B' "$($script:base)..HEAD" 2>$null)
        $hits = @($bodies | Select-String -Pattern 'claude|assistant|co-authored' -CaseSensitive:$false)
        $hits.Count | Should -BeGreaterThan 0
    }

    It 'produces a non-empty diff against the base' {
        $stat = @(& git -C $script:repo --no-pager diff --stat "$($script:base)...HEAD" 2>$null)
        $stat.Count | Should -BeGreaterThan 0
    }
}

Describe 'Resolve-BaseRef - repository with a remote' {
    It 'prefers origin/HEAD when the repo records one' {
        $repo = New-TempRepo -WithOrigin
        git -C $repo remote set-head origin -a 2>&1 | Out-Null
        $base = Resolve-BaseRef -RepoPath $repo
        $base | Should -Be 'origin/main'
        Test-RefResolves -RepoPath $repo -Ref $base | Should -BeTrue
    }

    It 'returns a resolving ref when there is a remote but no origin/HEAD' {
        $repo = New-TempRepo -WithOrigin
        git -C $repo symbolic-ref --delete refs/remotes/origin/HEAD 2>&1 | Out-Null
        $base = Resolve-BaseRef -RepoPath $repo
        Test-RefResolves -RepoPath $repo -Ref $base | Should -BeTrue
    }
}

Describe 'Resolve-BaseRef - a worker branch is never a base' {
    # Kingshand's workers branch as `worktree-<name>` - dispatch names them, and it is the one
    # place that name is chosen. `origin/HEAD` transiently pointed at one
    # during a multi-worker dispatch, and two workers were recorded with another worker's branch
    # as their base - so their landing diff and attribution scan would have measured against that
    # worker's unlanded commits rather than against the default branch.

    It 'falls back to the default when origin/HEAD points at a worktree- branch' {
        $repo = New-TempRepo -WithOrigin
        git -C $repo checkout -q -b 'worktree-other'
        Set-Content -Path (Join-Path $repo 'other.txt') -Value 'other' -Encoding utf8
        git -C $repo add -A
        git -C $repo commit -q -m 'Another worker commit'
        git -C $repo push -q origin 'worktree-other' 2>&1 | Out-Null
        git -C $repo checkout -q 'main'
        git -C $repo symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/worktree-other

        # The contaminated ref really does resolve - rejecting it is a rule, not a side effect
        # of it being missing.
        Test-RefResolves -RepoPath $repo -Ref 'origin/worktree-other' | Should -BeTrue

        $base = Resolve-BaseRef -RepoPath $repo
        $base | Should -Be 'origin/main'
        $base | Should -Not -BeLike '*worktree-*'
    }

    It 'falls back to the default when the local checkout is on a worktree- branch' {
        $repo = New-TempRepo
        git -C $repo checkout -q -b 'worktree-local'
        Set-Content -Path (Join-Path $repo 'local.txt') -Value 'local' -Encoding utf8
        git -C $repo add -A
        git -C $repo commit -q -m 'Worker commit'

        Test-RefResolves -RepoPath $repo -Ref 'worktree-local' | Should -BeTrue

        $base = Resolve-BaseRef -RepoPath $repo
        $base | Should -Be 'main'
        $base | Should -Not -BeLike '*worktree-*'
    }

    It 'leaves a branch that merely contains worktree- alone' {
        $repo = New-TempRepo -Branch 'feature/worktree-cleanup'
        $base = Resolve-BaseRef -RepoPath $repo
        $base | Should -Be 'feature/worktree-cleanup'
        Test-RefResolves -RepoPath $repo -Ref $base | Should -BeTrue
    }
}

Describe 'Resolve-BaseRef - refusal' {
    It 'throws rather than returning an unresolvable name when nothing resolves' {
        $empty = New-TempRepo -Empty
        { Resolve-BaseRef -RepoPath $empty } | Should -Throw '*Cannot resolve a base ref*'
    }

    It 'throws rather than returning a worker branch when that is the only branch' {
        $repo = New-TempRepo -Branch 'worktree-only'
        Test-RefResolves -RepoPath $repo -Ref 'worktree-only' | Should -BeTrue
        { Resolve-BaseRef -RepoPath $repo } | Should -Throw '*Cannot resolve a base ref*'
    }

    It 'names the rejected worker branch in the refusal' {
        $repo = New-TempRepo -Branch 'worktree-only'
        $err = $null
        try { Resolve-BaseRef -RepoPath $repo } catch { $err = $_.Exception.Message }
        $err | Should -Not -BeNullOrEmpty
        $err | Should -BeLike '*Rejected the worker branch*worktree-only*'
    }
}

Describe 'Resolve-BaseRef - the declared integration branch' {
    # The default branch and the integration branch are two things. A repository can land a
    # fresh clone on `main` while every pull request targets `dev`, and `origin/HEAD` names only
    # the first - so a worker resolved from it is cut from a tree its own pull request is not
    # proposed against. `pr.base_branch` in `.no-mistakes.yaml` is the declaration, and it is the
    # same key the review gate reads, so one statement serves both.

    BeforeAll {
        # A repo whose default branch is `main` and whose integration branch is `dev`, with both
        # pushed, so origin/HEAD and the declaration genuinely point at different refs.
        function New-SplitBranchRepo {
            $repo = New-TempRepo -WithOrigin
            git -C $repo checkout -q -b 'dev'
            Set-Content -Path (Join-Path $repo 'dev.txt') -Value 'dev' -Encoding utf8
            git -C $repo add -A
            git -C $repo commit -q -m 'A commit that exists only on the integration branch'
            git -C $repo push -q origin 'dev' 2>&1 | Out-Null
            git -C $repo checkout -q 'main'
            git -C $repo remote set-head origin -a 2>&1 | Out-Null
            $repo
        }
    }

    It 'follows the declaration rather than origin/HEAD' {
        $repo = New-SplitBranchRepo
        # origin/HEAD really does point elsewhere - the declaration is being preferred, not
        # winning because the alternative was missing.
        (git -C $repo symbolic-ref --short refs/remotes/origin/HEAD) | Should -Be 'origin/main'
        Set-DeclaredBranch -RepoPath $repo -Yaml "pr:`n  base_branch: dev"

        $base = Resolve-BaseRef -RepoPath $repo
        $base | Should -Be 'origin/dev'
        Test-RefResolves -RepoPath $repo -Ref $base | Should -BeTrue
    }

    It 'takes the local branch when only the local form of the declaration exists' {
        $repo = New-TempRepo
        git -C $repo checkout -q -b 'dev'
        Set-Content -Path (Join-Path $repo 'dev.txt') -Value 'dev' -Encoding utf8
        git -C $repo add -A
        git -C $repo commit -q -m 'Integration branch commit'
        git -C $repo checkout -q 'main'
        Set-DeclaredBranch -RepoPath $repo -Yaml "pr:`n  base_branch: dev"

        $base = Resolve-BaseRef -RepoPath $repo
        $base | Should -Be 'dev'
        Test-RefResolves -RepoPath $repo -Ref $base | Should -BeTrue
    }

    It 'reads a value carrying an inline comment' {
        $repo = New-SplitBranchRepo
        Set-DeclaredBranch -RepoPath $repo -Yaml "pr:`n  base_branch: dev  # where work integrates"
        Resolve-BaseRef -RepoPath $repo | Should -Be 'origin/dev'
    }

    It 'reads a quoted value' {
        $repo = New-SplitBranchRepo
        Set-DeclaredBranch -RepoPath $repo -Yaml "pr:`n  base_branch: `"dev`""
        Resolve-BaseRef -RepoPath $repo | Should -Be 'origin/dev'
    }

    # The two forms together, which is where they used to defeat each other: the comment strip
    # skipped the value for starting with a quote, and the quote strip skipped it for ending in a
    # comment, so the declaration came back as `"dev" # ...` and resolved to nothing.
    It 'reads a quoted value carrying an inline comment' {
        $repo = New-SplitBranchRepo
        Set-DeclaredBranch -RepoPath $repo `
                           -Yaml "pr:`n  base_branch: `"dev`"  # where work integrates"
        Resolve-BaseRef -RepoPath $repo | Should -Be 'origin/dev'
    }

    It 'reads a single-quoted value carrying an inline comment' {
        $repo = New-SplitBranchRepo
        Set-DeclaredBranch -RepoPath $repo -Yaml "pr:`n  base_branch: 'dev' # integration branch"
        Resolve-BaseRef -RepoPath $repo | Should -Be 'origin/dev'
    }

    It 'reads a file an editor left a byte-order mark on' {
        $repo = New-SplitBranchRepo
        $path = Join-Path $repo '.no-mistakes.yaml'
        [System.IO.File]::WriteAllText($path, "pr:`r`n  base_branch: dev`r`n",
                                       (New-Object System.Text.UTF8Encoding $true))
        Resolve-BaseRef -RepoPath $repo | Should -Be 'origin/dev'
    }

    # THE WORKER-BRANCH GUARD IS SHARED WITH THE DISPATCHER'S -Base, so widening what it refuses
    # widens what this function refuses too. These are the values real repositories actually
    # declare, and every one of them has to resolve to what it always did: the guard's extra
    # spellings are about a caller-supplied string, and the candidate list built here holds none of
    # them.
    It 'resolves the ordinary declared values exactly as before' -ForEach @(
        @{ Declared = 'dev';        Expected = 'origin/dev' },
        @{ Declared = 'main';       Expected = 'origin/main' },
        @{ Declared = 'origin/dev'; Expected = 'origin/dev' }
    ) {
        $repo = New-SplitBranchRepo
        Set-DeclaredBranch -RepoPath $repo -Yaml "pr:`n  base_branch: $Declared"
        Test-WorkerBranch $Declared | Should -BeFalse
        Resolve-BaseRef -RepoPath $repo -WarningAction SilentlyContinue | Should -Be $Expected
    }
}

Describe 'Resolve-BaseRef - a repository that declares nothing' {
    # Most registered projects declare nothing, and aegis-manager has only `main`. Every one of
    # them must resolve exactly as it did before any of this reader existed.

    BeforeAll {
        function New-RepoWithOriginHead {
            $repo = New-TempRepo -WithOrigin
            git -C $repo remote set-head origin -a 2>&1 | Out-Null
            $repo
        }
    }

    It 'resolves origin/HEAD when there is no config file at all' {
        $repo = New-RepoWithOriginHead
        Test-Path -LiteralPath (Join-Path $repo '.no-mistakes.yaml') | Should -BeFalse
        Resolve-BaseRef -RepoPath $repo | Should -Be 'origin/main'
    }

    It 'resolves origin/HEAD when the config has no pr block' {
        $repo = New-RepoWithOriginHead
        Set-DeclaredBranch -RepoPath $repo -Yaml "intent:`n  enabled: true"
        Resolve-BaseRef -RepoPath $repo | Should -Be 'origin/main'
    }

    It 'resolves origin/HEAD when the pr block declares no base_branch' {
        $repo = New-RepoWithOriginHead
        Set-DeclaredBranch -RepoPath $repo -Yaml "pr:`n  draft: true"
        Resolve-BaseRef -RepoPath $repo | Should -Be 'origin/main'
    }

    It 'treats an empty base_branch as no declaration, the way the gate does' {
        $repo = New-RepoWithOriginHead
        Set-DeclaredBranch -RepoPath $repo -Yaml "pr:`n  base_branch: `"`""
        Resolve-BaseRef -RepoPath $repo | Should -Be 'origin/main'
    }

    It 'ignores base_branch under some other top-level key' {
        $repo = New-RepoWithOriginHead
        Set-DeclaredBranch -RepoPath $repo -Yaml "test:`n  base_branch: dev"
        Resolve-BaseRef -RepoPath $repo | Should -Be 'origin/main'
    }

    It 'ignores base_branch nested deeper than the pr block itself' {
        $repo = New-RepoWithOriginHead
        Set-DeclaredBranch -RepoPath $repo -Yaml "pr:`n  evidence:`n    base_branch: dev"
        Resolve-BaseRef -RepoPath $repo | Should -Be 'origin/main'
    }

    # An inline `pr:` naming no branch is refused nowhere, because there is nothing for the
    # dispatcher and the gate to disagree about - the gate proposes against its own default and so
    # does this. Refusing it blocked every dispatch into the repository over a line that declares
    # nothing.
    It 'reads an empty inline pr mapping as no declaration' {
        $repo = New-RepoWithOriginHead
        Set-Content -Path (Join-Path $repo '.no-mistakes.yaml') -Value 'pr: {}' -Encoding utf8
        Resolve-BaseRef -RepoPath $repo | Should -Be 'origin/main'
    }

    It 'reads a null inline pr value as no declaration' {
        $repo = New-RepoWithOriginHead
        Set-Content -Path (Join-Path $repo '.no-mistakes.yaml') -Value 'pr: null' -Encoding utf8
        Resolve-BaseRef -RepoPath $repo | Should -Be 'origin/main'
    }

    # The refusal is decided on the value, not on the raw line. Searching the line for the word
    # refused this one for what its own comment says, which blocked every dispatch into the
    # repository over a declaration that is not there.
    It 'reads an inline pr mapping whose comment mentions base_branch as no declaration' {
        $repo = New-RepoWithOriginHead
        Set-Content -Path (Join-Path $repo '.no-mistakes.yaml') `
                    -Value 'pr: {} # base_branch is not set here' -Encoding utf8
        Resolve-BaseRef -RepoPath $repo | Should -Be 'origin/main'
    }

    It 'reads an inline pr mapping of other keys as no declaration' {
        $repo = New-RepoWithOriginHead
        Set-Content -Path (Join-Path $repo '.no-mistakes.yaml') `
                    -Value 'pr: {draft: true}' -Encoding utf8
        Resolve-BaseRef -RepoPath $repo | Should -Be 'origin/main'
    }

    # A mapping that contains another one still closes on its own line, so refusing it for not
    # closing said the opposite of what happened - and blocked every dispatch into the repository
    # over a line that declares no branch for the gate and this reader to disagree about.
    It 'reads an inline pr mapping containing a nested mapping as no declaration' {
        $repo = New-RepoWithOriginHead
        Set-Content -Path (Join-Path $repo '.no-mistakes.yaml') `
                    -Value 'pr: {draft: true, opts: {a: 1}}' -Encoding utf8
        Resolve-BaseRef -RepoPath $repo | Should -Be 'origin/main'
    }

    # The same rule the indent check applies to the block form: base_branch under a sub-mapping of
    # pr: is a different key that happens to share the name.
    It 'ignores base_branch nested inside a sub-mapping of an inline pr' {
        $repo = New-RepoWithOriginHead
        Set-Content -Path (Join-Path $repo '.no-mistakes.yaml') `
                    -Value 'pr: {opts: {base_branch: dev}}' -Encoding utf8
        Resolve-BaseRef -RepoPath $repo | Should -Be 'origin/main'
    }
}

Describe 'Resolve-BaseRef - a declaration is a candidate, not a guarantee' {
    It 'skips a declared branch that does not resolve' {
        $repo = New-TempRepo -WithOrigin
        git -C $repo remote set-head origin -a 2>&1 | Out-Null
        Set-DeclaredBranch -RepoPath $repo -Yaml "pr:`n  base_branch: never-fetched"
        Test-RefResolves -RepoPath $repo -Ref 'never-fetched' | Should -BeFalse

        $base = Resolve-BaseRef -RepoPath $repo -WarningAction SilentlyContinue
        $base | Should -Be 'origin/main'
        Test-RefResolves -RepoPath $repo -Ref $base | Should -BeTrue
    }

    It 'says out loud which branch it could not honour and what it used instead' {
        $repo = New-TempRepo -WithOrigin
        git -C $repo remote set-head origin -a 2>&1 | Out-Null
        Set-DeclaredBranch -RepoPath $repo -Yaml "pr:`n  base_branch: never-fetched"

        $warnings = @()
        $null = Resolve-BaseRef -RepoPath $repo -WarningVariable warnings -WarningAction SilentlyContinue
        ($warnings -join ' ') | Should -BeLike '*never-fetched*'
        ($warnings -join ' ') | Should -BeLike '*origin/main*'
        # This repo has an origin, so fetching is a real possibility - the remoteless case below
        # is the one where that advice would be wrong outright. It is offered as one of two
        # states rather than asserted, because origin may have no such branch either and nothing
        # short of a network round trip can tell which this is.
        ($warnings -join ' ') | Should -BeLike '*Fetch never-fetched*'
        ($warnings -join ' ') | Should -BeLike '*if origin has it*'
        ($warnings -join ' ') | Should -BeLike '*If origin has no never-fetched either*'
    }

    # The fetch advice is the only actionable sentence in that warning, and on a repository with
    # no origin there is nothing to fetch from and no pull request to misdirect either. Telling
    # that reader to fetch sends them after an upstream that does not exist.
    It 'asks for the branch to be created, not fetched, on a remoteless repo' {
        $repo = New-TempRepo
        Set-DeclaredBranch -RepoPath $repo -Yaml "pr:`n  base_branch: never-created"
        Test-RefResolves -RepoPath $repo -Ref 'never-created' | Should -BeFalse

        $warnings = @()
        $base = Resolve-BaseRef -RepoPath $repo -WarningVariable warnings -WarningAction SilentlyContinue
        $base | Should -Be 'main'
        $text = $warnings -join ' '
        $text | Should -BeLike '*no never-created branch exists here*'
        $text | Should -BeLike '*no origin to fetch one from*'
        $text | Should -BeLike '*Create never-created*'
        $text | Should -Not -BeLike '*Fetch never-created*'
        $text | Should -Not -BeLike '*pull request*'
    }

    It 'stays quiet when the declaration was honoured' {
        $repo = New-TempRepo -WithOrigin
        git -C $repo remote set-head origin -a 2>&1 | Out-Null
        Set-DeclaredBranch -RepoPath $repo -Yaml "pr:`n  base_branch: main"

        $warnings = @()
        $base = Resolve-BaseRef -RepoPath $repo -WarningVariable warnings -WarningAction SilentlyContinue
        $base | Should -Be 'origin/main'
        $warnings.Count | Should -Be 0
    }

    It 'rejects a declared worker branch outright, however well it resolves' {
        $repo = New-DeclaredWorkerBranchRepo
        Test-RefResolves -RepoPath $repo -Ref 'origin/worktree-other' | Should -BeTrue

        $base = Resolve-BaseRef -RepoPath $repo -WarningAction SilentlyContinue
        $base | Should -Be 'origin/main'
        $base | Should -Not -BeLike '*worktree-*'
    }

    # A declared worker branch is refused in both forms before anything is resolved, so it is not
    # a missing ref and telling the reader to fetch it sends them after a branch they already
    # have while the real fault - a declaration pointing at another worker's branch - goes unsaid.
    It 'says a declared worker branch was refused, not that it is missing' {
        $repo = New-DeclaredWorkerBranchRepo

        $warnings = @()
        $null = Resolve-BaseRef -RepoPath $repo -WarningVariable warnings -WarningAction SilentlyContinue
        $text = $warnings -join ' '
        $text | Should -BeLike '*worktree-other*'
        $text | Should -BeLike '*worker branch*'
        $text | Should -Not -BeLike '*neither origin/worktree-other nor worktree-other resolves*'
        $text | Should -Not -BeLike '*Fetch worktree-other*'
        $text | Should -BeLike '*refused on its name alone*'
        $text | Should -Not -BeLike '*It resolves fine*'
        $text | Should -Not -BeLike '*it belongs to another worker*'
    }

    # `$declaredIsWorker` is decided on the NAME, so this warning fires whether or not the declared
    # branch exists - both forms are dropped before anything is resolved. It must therefore not
    # claim the ref resolves: on a declaration naming a `worktree-*` branch nobody ever created,
    # "it resolves fine" is simply false, and the reader is being told about the wrong thing.
    It 'does not claim a declared worker branch resolves when no such branch exists' {
        $repo = New-TempRepo -WithOrigin
        git -C $repo remote set-head origin -a 2>&1 | Out-Null
        Set-DeclaredBranch -RepoPath $repo -Yaml "pr:`n  base_branch: worktree-ghost"
        Test-RefResolves -RepoPath $repo -Ref 'worktree-ghost'        | Should -BeFalse
        Test-RefResolves -RepoPath $repo -Ref 'origin/worktree-ghost' | Should -BeFalse

        $warnings = @()
        $base = Resolve-BaseRef -RepoPath $repo -WarningVariable warnings -WarningAction SilentlyContinue
        $base | Should -Be 'origin/main'
        $text = $warnings -join ' '
        $text | Should -BeLike '*worktree-ghost*'
        $text | Should -BeLike '*refused on its name alone*'
        $text | Should -Not -BeLike '*It resolves fine*'
        $text | Should -Not -BeLike '*it belongs to another worker*'
    }

    It 'says the same thing in the refusal when a declared worker branch is all there is' {
        $repo = New-TempRepo -Branch 'worktree-only'
        Set-DeclaredBranch -RepoPath $repo -Yaml "pr:`n  base_branch: worktree-only"
        Test-RefResolves -RepoPath $repo -Ref 'worktree-only' | Should -BeTrue

        $err = $null
        try { Resolve-BaseRef -RepoPath $repo } catch { $err = $_.Exception.Message }
        $err | Should -BeLike '*Cannot resolve a base ref*'
        $err | Should -BeLike '*worktree-only is the branch this repository declares*'
        $err | Should -BeLike '*refused rather than tried*'
        $err | Should -Not -BeLike '*tried first in both forms*'
    }

    It 'still throws when nothing resolves, and says the declaration was tried' {
        $repo = New-TempRepo -Empty
        Set-DeclaredBranch -RepoPath $repo -Yaml "pr:`n  base_branch: dev"
        $err = $null
        try { Resolve-BaseRef -RepoPath $repo } catch { $err = $_.Exception.Message }
        $err | Should -BeLike '*Cannot resolve a base ref*'
        $err | Should -BeLike '*dev is the branch this repository declares*'
        $err | Should -BeLike '*tried first in both forms*'
    }
}

Describe 'Resolve-BaseRef - the declared branch honoured only as a local ref' {
    # origin/$declared is preferred over the local $declared because the local copy is often
    # behind. Falling through to it on a repo that HAS an origin therefore means the declared
    # branch was never fetched: the worktree is cut from a stale tree, and every upstream commit
    # in the gap lands in the worker's diff and attribution scan as if the worker wrote it.

    It 'warns that the local copy is unconfirmed when the repo has a remote' {
        $repo = New-TempRepo -WithOrigin
        git -C $repo remote set-head origin -a 2>&1 | Out-Null
        git -C $repo branch dev
        Set-DeclaredBranch -RepoPath $repo -Yaml "pr:`n  base_branch: dev"
        Test-RefResolves -RepoPath $repo -Ref 'dev'        | Should -BeTrue
        Test-RefResolves -RepoPath $repo -Ref 'origin/dev' | Should -BeFalse

        $warnings = @()
        $base = Resolve-BaseRef -RepoPath $repo -WarningVariable warnings -WarningAction SilentlyContinue
        # The declaration is still honoured - this is a caution, not a refusal.
        $base | Should -Be 'dev'
        ($warnings -join ' ') | Should -BeLike '*origin/dev*'
        ($warnings -join ' ') | Should -BeLike '*Fetch dev*'
    }

    # Fetching only closes the gap when origin actually has the branch. This fixture is the other
    # state - `dev` was created locally and never pushed, so `git fetch origin dev` answers
    # `couldn't find remote ref dev` and there are no upstream commits to attribute to anyone.
    # Telling apart the two needs a network round trip on a path that must not hang a dispatch,
    # so the warning names both rather than asserting the one that happens to be wrong here.
    It 'names pushing as well as fetching, since origin may not have the branch at all' {
        $repo = New-TempRepo -WithOrigin
        git -C $repo remote set-head origin -a 2>&1 | Out-Null
        git -C $repo branch dev
        Set-DeclaredBranch -RepoPath $repo -Yaml "pr:`n  base_branch: dev"
        # The branch really is local-only: origin has main and nothing else.
        (git -C $repo ls-remote --heads origin dev) | Should -BeNullOrEmpty

        $warnings = @()
        $null = Resolve-BaseRef -RepoPath $repo -WarningVariable warnings -WarningAction SilentlyContinue
        $text = $warnings -join ' '
        $text | Should -BeLike '*if origin has it*'
        $text | Should -BeLike '*fetching cannot work*'
        $text | Should -BeLike '*push the branch*'
    }

    It 'stays quiet on a remoteless repo, where the local ref is the only ref there is' {
        $repo = New-TempRepo
        git -C $repo branch dev
        Set-DeclaredBranch -RepoPath $repo -Yaml "pr:`n  base_branch: dev"

        $warnings = @()
        $base = Resolve-BaseRef -RepoPath $repo -WarningVariable warnings -WarningAction SilentlyContinue
        $base | Should -Be 'dev'
        $warnings.Count | Should -Be 0
    }

    It 'leaves the caller no stray exit code from the remote probe' {
        $repo = New-TempRepo
        git -C $repo branch dev
        Set-DeclaredBranch -RepoPath $repo -Yaml "pr:`n  base_branch: dev"

        $global:LASTEXITCODE = 0
        $null = Resolve-BaseRef -RepoPath $repo -WarningAction SilentlyContinue
        $LASTEXITCODE | Should -Be 0
    }
}

Describe 'Resolve-BaseRef - a declaration nobody can read is not an absent one' {
    # Criterion: a fail-closed path names its own failure and never fabricates a value. Falling
    # through to origin/HEAD here would cut the worker from the default branch while its pull
    # request is proposed against whatever the unreadable file says - silently, which is the whole
    # failure this reader closes.

    It 'refuses when the config path is a directory' {
        $repo = New-TempRepo -WithOrigin
        New-Item -ItemType Directory -Path (Join-Path $repo '.no-mistakes.yaml') | Out-Null
        { Resolve-BaseRef -RepoPath $repo } | Should -Throw '*.no-mistakes.yaml is a directory*'
    }

    It 'refuses when the config cannot be read, naming the file' {
        $repo = New-TempRepo -WithOrigin
        $path = Join-Path $repo '.no-mistakes.yaml'
        Set-Content -Path $path -Value "pr:`n  base_branch: dev" -Encoding utf8
        # Held open with no sharing at all, which is the one way to make Get-Content fail on a
        # file that exists. Released in the finally, so the fixture cleanup can still remove it.
        $lock = [System.IO.File]::Open($path, 'Open', 'Read', 'None')
        try {
            { Resolve-BaseRef -RepoPath $repo } | Should -Throw "*Cannot read $path*"
        } finally { $lock.Dispose() }
    }

    It 'refuses an inline pr mapping that declares a branch rather than reading past it' {
        $repo = New-TempRepo -WithOrigin
        Set-Content -Path (Join-Path $repo '.no-mistakes.yaml') `
                    -Value 'pr: {base_branch: dev}' -Encoding utf8
        { Resolve-BaseRef -RepoPath $repo } |
            Should -Throw '*declares base_branch inline on the pr key*'
    }

    # A flow mapping that runs past its own line puts its keys where this reader skips them - they
    # are indented under a key it has already left - so the declaration came back as no
    # declaration at all, and the worker was based on origin/HEAD while the gate proposed against
    # `dev`. Unknown contents are refused, the same as an unreadable file.
    It 'refuses a pr flow mapping that does not close on its own line' {
        $repo = New-TempRepo -WithOrigin
        git -C $repo remote set-head origin -a 2>&1 | Out-Null
        Set-Content -Path (Join-Path $repo '.no-mistakes.yaml') -Encoding utf8 `
                    -Value @('pr: {', '  base_branch: dev', '}')
        { Resolve-BaseRef -RepoPath $repo } |
            Should -Throw '*cannot finish reading*'
    }

    It 'refuses a pr flow mapping left open after a nested one closes' {
        $repo = New-TempRepo -WithOrigin
        git -C $repo remote set-head origin -a 2>&1 | Out-Null
        Set-Content -Path (Join-Path $repo '.no-mistakes.yaml') -Encoding utf8 `
                    -Value @('pr: {opts: {a: 1},', '  base_branch: dev', '}')
        { Resolve-BaseRef -RepoPath $repo } |
            Should -Throw '*cannot finish reading*'
    }

    It 'still refuses a declared branch written beside a nested mapping' {
        $repo = New-TempRepo -WithOrigin
        Set-Content -Path (Join-Path $repo '.no-mistakes.yaml') `
                    -Value 'pr: {base_branch: dev, opts: {a: 1}}' -Encoding utf8
        { Resolve-BaseRef -RepoPath $repo } |
            Should -Throw '*declares base_branch inline on the pr key*'
    }
}

# ---------------------------------------------------------------------------------------------
# Dispatch itself. kingshand creates the worktree now - `claude --bg --worktree` used to - so the
# part that can go wrong quietly is git, not the spawn. herdr is replaced by a shim on PATH, which
# Get-HerdrCommandPath honours ahead of the bundled binary, so every case below drives the real
# Dispatch-Worker.ps1 end to end without a single Claude Code process starting.
#
# $env:USERPROFILE is redirected too. Grant-ClaudeFolderTrust writes ~\.claude.json, and a test
# suite that edited the person running it's real Claude Code project list would be indefensible.
# ---------------------------------------------------------------------------------------------
Describe 'Dispatch-Worker - the worktree it creates and the id it chooses' {
    BeforeAll {
        # The registry and the index the dispatch gate reads. Every case below drives them through
        # their own modules rather than writing their file formats by hand, and always inside the
        # fixture's data root - the live $env:KINGSHAND_HOME\data\ is never read or written here.
        Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'bin\Index.psm1')    -Force
        Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'bin\Projects.psm1') -Force

        $script:DispatchScript = "$PSScriptRoot\..\bin\Dispatch-Worker.ps1"
        $script:ProcedureFile  = (Resolve-Path (Join-Path (Split-Path $PSScriptRoot -Parent) `
                                                          '.claude\skills\witness\SKILL.md')).Path
        $script:ModuleFile     = (Resolve-Path (Join-Path (Split-Path $PSScriptRoot -Parent) `
                                                          'bin\BrowserVerify.psm1')).Path
        # What muster passes on every browser brief, and what dispatch therefore discounts.
        $script:BrowserFiles   = @($script:ProcedureFile, $script:ModuleFile)
        $script:SavedPath      = $env:PATH
        $script:SavedProfile   = $env:USERPROFILE

        $script:ShimDir = New-TempFixturePath -Prefix 'herdr-shim-'
        New-Item -ItemType Directory -Force -Path $script:ShimDir | Out-Null

        # One canned answer per `herdr <verb> <noun>`, so a single shim serves the whole dispatch
        # sequence: status, pane list, pane split, agent start, agent prompt.
        #
        # Once `agent prompt` has run, a `<verb>-<noun>-prompted.json` answer wins where one exists,
        # so the worker can read one way before its start prompt and another after it - which is
        # what confirming the prompt was taken reads. The marker sits beside the fixture's own call
        # log, so every fixture starts unprompted.
        Set-Content -Path (Join-Path $script:ShimDir 'herdr.cmd') -Encoding ascii -Value @(
            '@echo off',
            '>>"%KINGSHAND_TEST_HERDR_CALLS%" echo %*',
            'if "%1"=="status" goto :status',
            'if "%1 %2"=="agent prompt" type nul > "%KINGSHAND_TEST_HERDR_CALLS%.prompted"',
            'if exist "%KINGSHAND_TEST_HERDR_CALLS%.prompted" if exist "%KINGSHAND_TEST_HERDR_DIR%\%1-%2-prompted.json" goto :prompted',
            'type "%KINGSHAND_TEST_HERDR_DIR%\%1-%2.json"',
            'exit /b 0',
            ':prompted',
            'type "%KINGSHAND_TEST_HERDR_DIR%\%1-%2-prompted.json"',
            'exit /b 0',
            ':status',
            'type "%KINGSHAND_TEST_HERDR_DIR%\status.txt"',
            'exit /b 0'
        )

        # quota-axi is shimmed on PATH beside herdr, for the same reason and with the same effect:
        # the usage refusal is the first thing dispatch checks now, so every case below has to have
        # an answer waiting for it. It types one canned report and never logs a call, because the
        # call log is what the herdr assertions count.
        Set-Content -Path (Join-Path $script:ShimDir 'quota-axi.cmd') -Encoding ascii -Value @(
            '@echo off',
            'if exist "%KINGSHAND_TEST_HERDR_DIR%\quota-axi.fail" exit /b 1',
            'type "%KINGSHAND_TEST_HERDR_DIR%\quota-axi.json"',
            'exit /b 0'
        )

        # The usage probe is a stand-in too, named through the one variable Usage.psm1 reads for it,
        # because this script re-imports that module with -Force and no mock survives that - without
        # it every dispatch below would spend real usage. It types a canned stream-json reply, or
        # exits 1 with nothing, which is a probe that could not answer.
        Set-Content -Path (Join-Path $script:ShimDir 'claude-probe.cmd') -Encoding ascii -Value @(
            '@echo off',
            'if exist "%KINGSHAND_TEST_HERDR_DIR%\probe.fail" exit /b 1',
            'type "%KINGSHAND_TEST_HERDR_DIR%\probe.txt"',
            'exit /b 0'
        )
        $script:SavedProbe = $env:KINGSHAND_USAGE_PROBE_COMMAND
        $env:KINGSHAND_USAGE_PROBE_COMMAND = Join-Path $script:ShimDir 'claude-probe.cmd'

        # The reader's gate file lands under KINGSHAND_HOME\state\, so the whole context runs with
        # KINGSHAND_HOME on a root of its own. Nothing dispatch reads hangs off it otherwise: every
        # call passes -DataPath, and herdr is the shim on PATH.
        $script:SavedHome = $env:KINGSHAND_HOME
        $script:UsageHome = New-TempFixturePath -Prefix 'dispatch-home-'
        New-Item -ItemType Directory -Force -Path $script:UsageHome | Out-Null
        $env:KINGSHAND_HOME = $script:UsageHome

        # How much of the window this dispatch will believe is spent. A percentage is what the probe
        # answers; -Broken makes the probe and quota-axi both fail, which is the unknown the refusal
        # must fail open on. -Stale and -NoWindows are quota-axi's answers, so the probe fails first
        # for those and the fallback gives them. The gate file is removed every time, so a hold or a
        # fallback stamp one case left behind never decides the next.
        function Set-UsageReply {
            param([double]$Percent = 5, [switch]$Broken, [switch]$NoWindows, [switch]$Stale)

            $gate = Join-Path $script:UsageHome 'state\usage-gate.json'
            if (Test-Path -LiteralPath $gate) { Remove-Item -LiteralPath $gate -Force }

            $probeFail = Join-Path $script:ShimDir 'probe.fail'
            if ($Broken -or $Stale -or $NoWindows) { Set-Content -Path $probeFail -Value 'x' -Encoding ascii }
            elseif (Test-Path -LiteralPath $probeFail) { Remove-Item -LiteralPath $probeFail -Force }
            $reset = [datetimeoffset]::UtcNow.AddHours(3).ToUnixTimeSeconds()
            $reply = @{ type = 'rate_limit_event'; rate_limit_info = @{ status = 'allowed'
                        unifiedWindows = @{ five_hour = @{ utilization = $Percent / 100; resetsAt = $reset }
                                            seven_day = @{ utilization = 0.01
                                                           resetsAt = $reset + 86400 } } } }
            ($reply | ConvertTo-Json -Depth 8 -Compress) |
                Set-Content -Path (Join-Path $script:ShimDir 'probe.txt') -Encoding utf8

            $fail = Join-Path $script:ShimDir 'quota-axi.fail'
            if ($Broken) { Set-Content -Path $fail -Value 'x' -Encoding ascii }
            elseif (Test-Path -LiteralPath $fail) { Remove-Item -LiteralPath $fail -Force }

            $windows = @()
            if (-not $NoWindows) {
                # A reset relative to now, never a fixed timestamp: a window only counts while its
                # reset is still ahead, so a literal one turns every case here into a time bomb.
                # The spend cap rides along at 100 percent with no reset at all, because that is
                # what this machine really reports and it must never refuse a dispatch.
                $windows = @(
                    @{ id = 'five_hour'; kind = 'session'; percentUsed = $Percent
                       resetsAt = ([datetimeoffset]::UtcNow.AddHours(3).ToString('o')) },
                    @{ id = 'extra_usage'; kind = 'credits'; percentUsed = 100 }
                )
            }
            @{ schemaVersion = 3
               generatedAt = ([datetimeoffset]::UtcNow.ToString('o'))
               providers = @(@{ provider = 'claude'; windows = $windows
                                state = @{ status = if ($Stale) { 'stale' } else { 'fresh' }
                                           stale = [bool]$Stale } }) } |
                ConvertTo-Json -Depth 12 |
                Set-Content -Path (Join-Path $script:ShimDir 'quota-axi.json') -Encoding utf8
        }

        # Test-HerdrServer matches on this shape, so a running server needs no real one.
        Set-Content -Encoding ascii -Path (Join-Path $script:ShimDir 'status.txt') -Value @(
            'client:', '  version: 0.8.2', '', 'server:', '  status: running', '  socket: none'
        )

        function Set-HerdrReply {
            param([Parameter(Mandatory)][string]$Verb, [Parameter(Mandatory)]$Result)
            @{ id = "cli:$Verb"; result = $Result } | ConvertTo-Json -Depth 8 |
                Set-Content -Path (Join-Path $script:ShimDir "$Verb.json") -Encoding utf8
        }

        # Dispatch reads the started worker's state through Get-HerdrAgentState, never the raw
        # agent_status, so the shim has to answer `agent get` AND `agent read` as well. The screen
        # is what decides: herdr misreports a worker sitting on a prompt, so a blocked case that
        # only set agent_status would prove nothing about the check dispatch actually performs.
        #
        # The blocked screen uses the FOLDER-TRUST dialog's wording rather than a question menu,
        # because that is the prompt a fresh worktree really stops on, and its footer says "Enter
        # to confirm" where the menus say "Enter to select" - a guard that only knew the menu
        # wording would sail straight past the one dialog dispatch exists to catch.
        #
        # After the start prompt the worker reads -AfterPrompt, `working` by default - the prompt
        # taken - and -AfterPromptScreen replaces its screen where a case needs the box to differ.
        function Set-AgentStartState {
            param([string]$State = 'idle', [string]$AfterPrompt = 'working',
                  [string[]]$AfterPromptScreen = @())
            Set-HerdrReply -Verb 'agent-start'  -Result @{ agent = @{ name = 'x'; pane_id = 'p2'; agent_status = $State } }
            Set-HerdrReply -Verb 'agent-prompt' -Result @{ agent = @{ name = 'x'; pane_id = 'p2'; agent_status = 'idle' } }
            Set-HerdrReply -Verb 'agent-get'    -Result @{ agent = @{ name = 'x'; pane_id = 'p2'; agent_status = $State } }
            Set-HerdrReply -Verb 'agent-get-prompted' `
                -Result @{ agent = @{ name = 'x'; pane_id = 'p2'; agent_status = $AfterPrompt } }

            $after = Join-Path $script:ShimDir 'agent-read-prompted.json'
            if ($AfterPromptScreen.Count) {
                Set-Content -Path $after -Encoding utf8 -Value $AfterPromptScreen
            } elseif (Test-Path -LiteralPath $after) {
                Remove-Item -LiteralPath $after -Force
            }

            $screen = if ($State -eq 'blocked') {
                @(' Quick safety check: Is this a project you created or one you trust?',
                  '',
                  ' > 1. Yes, I trust this folder',
                  '   2. No, exit',
                  '',
                  ' Enter to confirm - Esc to cancel')
            } else {
                # Deliberately a realistic terminal width. Dispatch now checks that the guard can
                # actually read this worker's screen, and a fixture narrower than the guard's
                # threshold would make every ordinary dispatch warn that it had gone blind.
                @('* Claude Code v2.1.220 - Opus - E:\repo',
                  '',
                  '> ',
                  '  bypass permissions on (shift+tab to cycle) - left arrow for agents')
            }
            Set-Content -Path (Join-Path $script:ShimDir 'agent-read.json') -Encoding utf8 -Value $screen
        }

        # Every worker gets its OWN workspace now, never a split of an existing pane. Splitting
        # halves the terminal width each time, and two real workers came out 6 and 3 columns wide -
        # too narrow to render the prompt text the screen guard matches, which left both the guard
        # and herdr's own detection blind. pane-split is still answered so a test that reaches for
        # it fails on its assertion rather than on a missing fixture.
        Set-HerdrReply -Verb 'workspace-create' -Result @{ root_pane = @{ pane_id = 'p2' } }
        Set-HerdrReply -Verb 'pane-list'        -Result @{ panes = @(@{ pane_id = 'p1' }) }
        Set-HerdrReply -Verb 'pane-split'       -Result @{ pane = @{ pane_id = 'p2' } }
        Set-AgentStartState
        Set-UsageReply

        $env:KINGSHAND_TEST_HERDR_DIR = $script:ShimDir
        $env:PATH = $script:ShimDir + [IO.Path]::PathSeparator + $env:PATH

        # Every dispatch gets a fresh brief, call log and fake home, so no case can read another's.
        function New-DispatchFixture {
            param([Parameter(Mandatory)][string]$Name)
            $root = New-TempFixturePath -Prefix "dispatch-$Name-"
            # data\<id>\, the real layout: the guard resolves `$env:KINGSHAND_HOME\data\...` and the
            # index's bare `data\<name>.md` against the brief's own data root, so a fixture whose
            # data root is not called data would exercise neither form.
            $briefDir = Join-Path $root 'data\brief'
            $home_    = Join-Path $root 'home'
            New-Item -ItemType Directory -Force -Path $briefDir | Out-Null
            New-Item -ItemType Directory -Force -Path $home_    | Out-Null
            # The Read first section is in the default fixture because dispatch requires it of
            # every brief, and a fixture without one would exercise a brief muster cannot write.
            # Cases that need it absent overwrite this file themselves.
            Set-Content -Path (Join-Path $briefDir 'brief.md') -Encoding utf8 -Value @(
                '# Brief', '', '## Read first', '- Nothing beyond this brief.', ''
                '## Scope', 'Do the thing, and the SECRET-BODY-MARKER must never travel by value.'
            )
            # A config with a projects object, so the trust grant has somewhere real to land.
            '{ "projects": { "C:/somewhere-else": { "hasTrustDialogAccepted": true } } }' |
                Set-Content -Path (Join-Path $home_ '.claude.json') -Encoding utf8

            $env:USERPROFILE = $home_
            $env:KINGSHAND_TEST_HERDR_CALLS = Join-Path $root 'calls.txt'

            [pscustomobject]@{
                Repo      = New-TempRepo
                BriefPath = Join-Path $briefDir 'brief.md'
                BriefDir  = $briefDir
                DataPath  = Join-Path $root 'data'
                Home      = $home_
                CallLog   = Join-Path $root 'calls.txt'
            }
        }

        # -DataPath points the index gate at this fixture's own data root, where its registry and
        # its index live. Passed on every dispatch below, not only the gate's own cases: a suite
        # whose default reached the real installation's data\ would pass or fail on whatever that
        # machine happens to have registered.
        #
        # -Base is passed only by a case that names one, and the two calls below are deliberately
        # separate rather than one call with a possibly-empty value: every other case in this file
        # then exercises the parameter's OWN default, which is the path muster takes on every
        # ordinary dispatch, instead of an empty string this helper invented for it.
        function Invoke-Dispatch {
            param([Parameter(Mandatory)]$Fixture, [Parameter(Mandatory)][string]$Name,
                  [string]$Base = '')
            if ($Base) {
                & $script:DispatchScript -RepoPath $Fixture.Repo -Name $Name `
                    -BriefPath $Fixture.BriefPath -DataPath $Fixture.DataPath -Base $Base
            } else {
                & $script:DispatchScript -RepoPath $Fixture.Repo -Name $Name `
                    -BriefPath $Fixture.BriefPath -DataPath $Fixture.DataPath
            }
        }

        # A registered project for the fixture's repo, and optionally an index holding one entry.
        # Registering without -WithIndex is the unindexed case: a project the gate resolves and then
        # has nothing to check for.
        function Register-FixtureProject {
            param(
                [Parameter(Mandatory)]$Fixture,
                [string]$Project = 'acme-web',
                [switch]$WithIndex
            )
            Add-ProjectEntry -Name $Project -Path $Fixture.Repo -Mode 'local-only' `
                -Description 'the fixture repo' `
                -RegistryPath (Join-Path $Fixture.DataPath 'projects.md')
            if ($WithIndex) {
                Add-IndexEntry -Project $Project -Path 'data\brand.md' `
                    -Summary 'settled brand: logo, favicon, tagline, palettes' `
                    -DataPath $Fixture.DataPath | Out-Null
            }
            $Project
        }

        # One entry in the ROOT index, data\index.md, which no project owns. That is where the
        # settled files this gate exists to protect actually land - chronicle, annex and survey all
        # write data\<topic>.md with no project - so a fixture that only ever wrote a project index
        # would never exercise the index the real installation has.
        function Add-FixtureRootEntry {
            param([Parameter(Mandatory)]$Fixture, [string]$Leaf = 'brand.md')
            Add-IndexEntry -Path "data\$Leaf" `
                -Summary 'settled brand: logo, favicon, tagline, palettes' `
                -DataPath $Fixture.DataPath | Out-Null
        }

        function Get-CallLines {
            param([Parameter(Mandatory)]$Fixture)
            if (-not (Test-Path -LiteralPath $Fixture.CallLog)) { return @() }
            @(Get-Content -LiteralPath $Fixture.CallLog | Where-Object { $_.Trim() })
        }

        # What dispatch adds to a brief goes to <stem>.dispatch.md beside it, never into the brief,
        # and the worker is pointed at it by its start prompt. These read that file the way a
        # worker does - whole - and say '' rather than throwing when there is none.
        function Get-DispatchFilePath {
            param([Parameter(Mandatory)]$Fixture)
            Join-Path $Fixture.BriefDir 'brief.dispatch.md'
        }
        function Get-DispatchText {
            param([Parameter(Mandatory)]$Fixture)
            $p = Get-DispatchFilePath $Fixture
            if (-not (Test-Path -LiteralPath $p)) { return '' }
            [System.IO.File]::ReadAllText($p)
        }

        # A brief with a real `Read first` section, in the shape muster's template writes: the copy
        # named as read-first\<leaf>, with the original repeated in the same line as provenance.
        # Any fixture that stages a file has to name it, because dispatch now refuses a staged copy
        # the brief says nothing about.
        function Set-ReadFirstBrief {
            param(
                [Parameter(Mandatory)]$Fixture,
                [string[]]$Leaf   = @(),
                [string[]]$Body,
                [string]$From     = 'C:\somewhere\original.md',
                [switch]$BrowserChecks
            )
            if (-not $PSBoundParameters.ContainsKey('Body')) {
                $Body = if ($Leaf.Count -eq 0) { @('- Nothing beyond this brief.') } else {
                    foreach ($l in $Leaf) {
                        "- ``$($Fixture.BriefDir)\read-first\$l`` - what it settles, copied here from ``$From``."
                    }
                }
            }
            $browser = if ($BrowserChecks) {
                @('', '## Browser checks', '- C-001 the drawer closes when the overlay is clicked')
            } else { @() }
            Set-Content -Path $Fixture.BriefPath -Encoding utf8 -Value (@(
                '# Brief', '', '## Read first') + $Body + $browser + @(
                '', '## Scope', 'Do the thing, and the SECRET-BODY-MARKER must never travel by value.'))
        }
    }

    AfterAll {
        $env:PATH        = $script:SavedPath
        $env:USERPROFILE = $script:SavedProfile
        $env:KINGSHAND_HOME = $script:SavedHome
        $env:KINGSHAND_USAGE_PROBE_COMMAND = $script:SavedProbe
        Remove-Item Env:\KINGSHAND_TEST_HERDR_DIR   -ErrorAction SilentlyContinue
        Remove-Item Env:\KINGSHAND_TEST_HERDR_CALLS -ErrorAction SilentlyContinue
    }

    Context 'a first dispatch' {
        BeforeAll {
            Set-AgentStartState
            $script:First       = New-DispatchFixture 'first'
            $script:FirstResult = Invoke-Dispatch -Fixture $script:First -Name 'T-1001'
        }

        # The location is not an implementation detail. `.gitignore` covers .claude/worktrees/,
        # crew.json rows already recorded there, and the skills spell it out - moving it would
        # commit a worker's checkout into the repo it is working on.
        It 'puts the worktree exactly where claude --bg --worktree put it' {
            $expected = Join-Path $script:First.Repo '.claude\worktrees\T-1001'
            $script:FirstResult.worktree | Should -Be $expected
            Test-Path -LiteralPath (Join-Path $expected '.git') | Should -BeTrue
        }

        It 'branches it as worktree- plus the name, from the resolved base' {
            $script:FirstResult.branch | Should -Be 'worktree-T-1001'
            $script:FirstResult.base   | Should -Be 'main'
            $head = (& git -C $script:FirstResult.worktree rev-parse --abbrev-ref HEAD).Trim()
            $head | Should -Be 'worktree-T-1001'
        }

        # The whole point of the port: the id is chosen, so there is no before/after diff to lose
        # a worker in and no window in which a dispatch has no id to record.
        It 'returns the chosen name as the id rather than one discovered afterwards' {
            $script:FirstResult.id | Should -Be 'T-1001'
        }

        # Four crew.json fields plus one dispatch-time observation, and nothing else. `readable`
        # is deliberately not crew state: it says whether the guard could see this worker's screen
        # at the moment it started, which the caller has to know because "no prompt found" and
        # "could not look" are different answers and only one means the worker is healthy.
        It 'returns the four fields crew.json is built from, plus the readability answer' {
            @($script:FirstResult.Keys | Sort-Object) |
                Should -Be @('base', 'branch', 'id', 'readable', 'worktree')
        }

        It 'reports the worker as readable when its terminal is wide enough for the guard' {
            $script:FirstResult.readable |
                Should -BeTrue -Because 'the fixture screen is a realistic width, so the guard can see it'
        }

        # herdr cannot pass arguments to claude on Windows at all, so both grants have to be on
        # disk before the agent starts or the worker stops at the first permission prompt.
        It 'writes the two grants into the worktree before starting anything' {
            $settings = Join-Path $script:FirstResult.worktree '.claude\settings.local.json'
            Test-Path -LiteralPath $settings | Should -BeTrue
            $json = Get-Content -LiteralPath $settings -Raw | ConvertFrom-Json
            $json.permissions.defaultMode | Should -Be 'bypassPermissions'
            @($json.permissions.additionalDirectories) | Should -Contain $script:First.BriefDir
        }

        # The mode grant above no longer takes effect from this file, so a write under the
        # worktree's own .claude folder is answered by a hook instead - scoped to that folder.
        It 'writes the grant to edit the worktree''s own .claude folder, and no other' {
            $settings = Join-Path $script:FirstResult.worktree '.claude\settings.local.json'
            $json  = Get-Content -LiteralPath $settings -Raw | ConvertFrom-Json
            $group = @($json.hooks.PermissionRequest)
            $group.Count | Should -Be 1
            $group[0].matcher -split '\|' | Should -Contain 'Edit'
            $line = @($group[0].hooks)[0].args -join ' '
            $scope = [IO.Path]::GetFullPath((Join-Path $script:FirstResult.worktree '.claude'))
            $line.Contains("-ClaudeDir '$scope'") |
                Should -BeTrue -Because 'the grant names the worktree''s folder, never the main checkout''s'
        }

        It 'records folder trust for the worktree, so the agent never meets the dialog' {
            $config = Get-Content -LiteralPath (Join-Path $script:First.Home '.claude.json') -Raw |
                      ConvertFrom-Json
            $key = ($script:FirstResult.worktree -replace '\\', '/')
            @($config.projects.PSObject.Properties.Name) | Should -Contain $key
        }

        It 'passes the brief by path and never by value' {
            $prompt = @(Get-CallLines $script:First | Where-Object { $_ -like 'agent prompt*' })
            $prompt.Count | Should -Be 1
            $prompt[0] | Should -BeLike "*$($script:First.BriefPath)*"
            $prompt[0] | Should -Not -BeLike '*SECRET-BODY-MARKER*' `
                -Because 'a brief that travels by value is a brief that can be truncated in transit'
        }

        # `agent start <name> ... -- <args>` is broken on Windows for claude: herdr launches it
        # through Start-Process against a .ps1 and it dies with "%1 is not a valid Win32
        # application". No agent arguments can ever be passed, which is why the grants are on disk.
        It 'starts the agent with no claude arguments at all' {
            $start = @(Get-CallLines $script:First | Where-Object { $_ -like 'agent start*' })
            $start.Count | Should -Be 1
            $start[0] | Should -Not -BeLike '* -- *'
            $start[0] | Should -Not -BeLike '*bypassPermissions*'
            $start[0] | Should -Not -BeLike '*--add-dir*'
        }
    }

    # The declaration exists so that a repository can land a fresh clone on `main` while its work
    # integrates on `dev`. Resolve-BaseRef is exercised on its own above; what a worker is actually
    # handed is decided here, where the resolved ref becomes both the branch point and the recorded
    # base. So this asserts the tree the worker opens, not just the string that came back.
    # A `fief` session's warm worker runs in the project's own checkout, on the branch the King
    # named, with no worktree. Nothing here may create or switch a branch, and every refusal comes
    # before anything is created - the King's checkout is the one place a half-done dispatch costs
    # him something.
    Context 'a dispatch into the project''s own checkout' {
        BeforeAll {
            Set-AgentStartState

            function Invoke-CheckoutDispatch {
                # -Base main by default: these fixtures have no remote, and with nothing recorded the
                # resolver's answer for a checkout is the session branch itself, which is refused.
                # The case that drives that refusal passes -NoBase.
                param([Parameter(Mandatory)]$Fixture, [string]$Name = 'acme-api-session',
                      [string]$Branch = 'feature-x', [string]$RepoPath, [switch]$NoBase)
                if (-not $RepoPath) { $RepoPath = $Fixture.Repo }
                if ($NoBase) {
                    & $script:DispatchScript -RepoPath $RepoPath -Name $Name -BriefPath $Fixture.BriefPath `
                        -DataPath $Fixture.DataPath -InCheckout -Branch $Branch
                } else {
                    & $script:DispatchScript -RepoPath $RepoPath -Name $Name -BriefPath $Fixture.BriefPath `
                        -DataPath $Fixture.DataPath -InCheckout -Branch $Branch -Base 'main' 3>$null
                }
            }

            # The baseline is indexed and outlives a cleanup, so a re-dispatch meets a listed
            # file - as a real session brief always does - and says the index was checked.
            function Set-IndexCheckedBrief {
                param([Parameter(Mandatory)]$Fixture)
                $text = [System.IO.File]::ReadAllText($Fixture.BriefPath).Replace(
                    '- Nothing beyond this brief.',
                    '- Nothing beyond this brief - the index was checked and nothing in it applies.')
                [System.IO.File]::WriteAllText($Fixture.BriefPath, $text)
            }

            function Get-LocalBranches {
                param([Parameter(Mandatory)][string]$Repo)
                @(& git -C $Repo for-each-ref --format='%(refname:short)' refs/heads | Sort-Object)
            }

            # Nothing created: no settings file, no record, no dispatch file, no spawn, the brief as
            # it was.
            function Assert-NothingCreated {
                param([Parameter(Mandatory)]$Fixture, [Parameter(Mandatory)][string]$BriefBefore)
                Test-Path -LiteralPath (Join-Path $Fixture.Repo '.claude') | Should -BeFalse
                Test-Path -LiteralPath (Join-Path $Fixture.BriefDir 'checkout-settings.json') |
                    Should -BeFalse
                Test-Path -LiteralPath (Get-DispatchFilePath $Fixture) | Should -BeFalse
                @(Get-CallLines $Fixture | Where-Object { $_ -like 'agent start*' }).Count | Should -Be 0
                [System.IO.File]::ReadAllText($Fixture.BriefPath) | Should -Be $BriefBefore
            }

            $script:Co = New-DispatchFixture 'checkout'
            git -C $script:Co.Repo checkout -q -b 'feature-x'
            Set-Content -Path (Join-Path $script:Co.Repo 'wip.txt') -Value 'the owner''s' -Encoding utf8
            Set-Content -Path (Join-Path $script:Co.Repo 'base.txt') -Value 'edited' -Encoding utf8
            $script:CoBranches = Get-LocalBranches $script:Co.Repo
            $script:CoBriefWas = [System.IO.File]::ReadAllText($script:Co.BriefPath)
            $script:CoResult   = Invoke-CheckoutDispatch -Fixture $script:Co
            $script:CoBrief    = Get-DispatchText $script:Co
        }

        It 'runs the worker in the checkout itself, on the named branch' {
            $script:CoResult.worktree | Should -Be $script:Co.Repo
            $script:CoResult.branch   | Should -Be 'feature-x'
            $script:CoResult.checkout | Should -BeTrue
            (& git -C $script:Co.Repo rev-parse --abbrev-ref HEAD).Trim() | Should -Be 'feature-x'
        }

        It 'cuts no worktree and creates no branch' {
            Test-Path -LiteralPath (Join-Path $script:Co.Repo '.claude\worktrees') | Should -BeFalse
            @(& git -C $script:Co.Repo worktree list --porcelain | Where-Object { $_ -like 'worktree *' }).Count |
                Should -Be 1
            Get-LocalBranches $script:Co.Repo | Should -Be $script:CoBranches
        }

        It 'records the base the landing measures the whole branch against' {
            $script:CoResult.base | Should -Be 'main'
        }

        # With nothing recorded, the resolver falls back to the branch the checkout is on - right
        # for a worktree, where that is the default branch, and wrong here, where it is the session
        # branch: a diff of the branch against itself is empty, and empty reads as clean.
        It 'refuses a base that resolves to the session branch itself, before creating anything' {
            $f = New-DispatchFixture 'checkout-selfbase'
            git -C $f.Repo checkout -q -b 'feature-x'
            $before = [System.IO.File]::ReadAllText($f.BriefPath)
            { Invoke-CheckoutDispatch -Fixture $f -NoBase } | Should -Throw '*session branch feature-x itself*'
            Assert-NothingCreated -Fixture $f -BriefBefore $before
        }

        It 'takes the base from the repository when it records one' {
            $f = New-DispatchFixture 'checkout-origin'
            $bare = "$($f.Repo)-remote.git"
            $script:TempFixtures.Add($bare)
            git init --bare -q -b main $bare
            git -C $f.Repo remote add origin $bare
            git -C $f.Repo push -q origin main 2>&1 | Out-Null
            git -C $f.Repo remote set-head origin -a 2>&1 | Out-Null
            git -C $f.Repo checkout -q -b 'feature-x'
            (Invoke-CheckoutDispatch -Fixture $f -NoBase).base | Should -Be 'origin/main'
        }

        It 'grants the two settings in the checkout and records that no file existed before' {
            $settings = Join-Path $script:Co.Repo '.claude\settings.local.json'
            $json = Get-Content -LiteralPath $settings -Raw | ConvertFrom-Json
            $json.permissions.defaultMode | Should -Be 'bypassPermissions'
            @($json.permissions.additionalDirectories) | Should -Contain $script:Co.BriefDir
            $script:CoResult.settingsRecord | Should -Be (Join-Path $script:Co.BriefDir 'checkout-settings.json')
            (Get-Content -LiteralPath $script:CoResult.settingsRecord -Raw | ConvertFrom-Json).existed |
                Should -BeFalse
        }

        It 'indexes the record it wrote, like every durable file under data' {
            @(Get-IndexEntries -All -DataPath $script:Co.DataPath | ForEach-Object { $_.path }) |
                Should -Contain 'data\brief\checkout-settings.json'
        }

        It 'writes the checkout warnings beside the brief, with what was already uncommitted' {
            [System.IO.File]::ReadAllText($script:Co.BriefPath) | Should -Be $script:CoBriefWas
            $script:CoBrief.Contains('## Working in the checkout, not a worktree') | Should -BeTrue
            $script:CoBrief.Contains('**You are not in a worktree.**') | Should -BeTrue
            $script:CoBrief.Contains('**Stay on branch `feature-x`.**') | Should -BeTrue
            $script:CoBrief.Contains('**Never stash, reset, checkout, restore or clean anything**') |
                Should -BeTrue
            $script:CoBrief.Contains('**Do not commit, push or open a pull request until a prompt tells you to.**') |
                Should -BeTrue
            $script:CoBrief.Contains('**not yours**') | Should -BeTrue
            $script:CoBrief.Contains('- `?? wip.txt`') | Should -BeTrue
            $script:CoBrief.Contains('- ` M base.txt`') | Should -BeTrue
        }

        It 'says plainly when nothing was uncommitted' {
            $f = New-DispatchFixture 'checkout-clean'
            git -C $f.Repo checkout -q -b 'feature-x'
            $null = Invoke-CheckoutDispatch -Fixture $f
            (Get-DispatchText $f).Contains(
                'Nothing was uncommitted in this checkout when you were dispatched.') | Should -BeTrue
        }

        It 'refuses a checkout that is on another branch, before creating anything' {
            $f = New-DispatchFixture 'checkout-wrong'
            $before = [System.IO.File]::ReadAllText($f.BriefPath)
            { Invoke-CheckoutDispatch -Fixture $f } | Should -Throw '*is on main*told to work on feature-x*'
            Assert-NothingCreated -Fixture $f -BriefBefore $before
            (& git -C $f.Repo rev-parse --abbrev-ref HEAD).Trim() | Should -Be 'main'
        }

        It 'refuses a detached HEAD, before creating anything' {
            $f = New-DispatchFixture 'checkout-detached'
            git -C $f.Repo checkout -q --detach
            $before = [System.IO.File]::ReadAllText($f.BriefPath)
            { Invoke-CheckoutDispatch -Fixture $f } | Should -Throw '*not on any branch*'
            Assert-NothingCreated -Fixture $f -BriefBefore $before
        }

        It 'refuses a path below the top of the checkout' {
            $f = New-DispatchFixture 'checkout-subdir'
            git -C $f.Repo checkout -q -b 'feature-x'
            $sub = Join-Path $f.Repo 'src'
            New-Item -ItemType Directory -Force -Path $sub | Out-Null
            { Invoke-CheckoutDispatch -Fixture $f -RepoPath $sub } | Should -Throw '*not one*'
            Test-Path -LiteralPath (Join-Path $sub '.claude') | Should -BeFalse
        }

        It 'refuses -InCheckout with no branch, and a branch with no -InCheckout' {
            $f = New-DispatchFixture 'checkout-args'
            { & $script:DispatchScript -RepoPath $f.Repo -Name 'x1' -BriefPath $f.BriefPath `
                  -DataPath $f.DataPath -InCheckout } | Should -Throw '*needs -Branch*'
            { & $script:DispatchScript -RepoPath $f.Repo -Name 'x1' -BriefPath $f.BriefPath `
                  -DataPath $f.DataPath -Branch 'main' } | Should -Throw '*-InCheckout was not passed*'
            Test-Path -LiteralPath (Join-Path $f.Repo '.claude') | Should -BeFalse
        }

        It 'refuses a settings file it cannot read, before creating anything' {
            $f = New-DispatchFixture 'checkout-badjson'
            git -C $f.Repo checkout -q -b 'feature-x'
            New-Item -ItemType Directory -Force -Path (Join-Path $f.Repo '.claude') | Out-Null
            Set-Content -Path (Join-Path $f.Repo '.claude\settings.local.json') -Value '{ "permissions": '
            $before = [System.IO.File]::ReadAllText($f.BriefPath)
            { Invoke-CheckoutDispatch -Fixture $f } | Should -Throw '*not valid JSON*'
            Test-Path -LiteralPath (Join-Path $f.BriefDir 'checkout-settings.json') | Should -BeFalse
            [System.IO.File]::ReadAllText($f.BriefPath) | Should -Be $before
        }

        # The record is the only copy of the King's original settings file. A second dispatch into
        # a checkout nobody cleaned up would record the first worker's edit as the original.
        It 'refuses a second dispatch while the first one''s record is still there' {
            $before = [System.IO.File]::ReadAllText($script:Co.BriefPath)
            $record = [System.IO.File]::ReadAllText($script:CoResult.settingsRecord)
            { Invoke-CheckoutDispatch -Fixture $script:Co } | Should -Throw '*record already exists*'
            [System.IO.File]::ReadAllText($script:CoResult.settingsRecord) | Should -Be $record
            [System.IO.File]::ReadAllText($script:Co.BriefPath) | Should -Be $before
        }

        It 'replaces its own section on a re-dispatch rather than adding a second' {
            $f = New-DispatchFixture 'checkout-again'
            git -C $f.Repo checkout -q -b 'feature-x'
            Set-IndexCheckedBrief -Fixture $f
            $briefWas = [System.IO.File]::ReadAllText($f.BriefPath)
            $r = Invoke-CheckoutDispatch -Fixture $f
            $null = Restore-CheckoutWorkerSettings -RecordPath $r.settingsRecord
            $null = Remove-IndexEntry -Path $r.settingsRecord -DataPath $f.DataPath
            Set-Content -Path (Join-Path $f.Repo 'later.txt') -Value 'x' -Encoding utf8
            $null = Invoke-CheckoutDispatch -Fixture $f
            $text = Get-DispatchText $f
            ([regex]::Matches($text, '(?m)^## Working in the checkout, not a worktree')).Count | Should -Be 1
            $text.Contains('- `?? later.txt`') | Should -BeTrue
            [System.IO.File]::ReadAllText($f.BriefPath) | Should -Be $briefWas `
                -Because 'dispatch never edits the brief'
        }

        # A session's fixes stay uncommitted until the King says commit, so a relaunched warm worker
        # finds them beside his own work - and must be told which is which.
        It 'tells a relaunched session worker its own earlier fixes from the King''s uncommitted work' {
            $f = New-DispatchFixture 'checkout-relaunch'
            git -C $f.Repo checkout -q -b 'feature-x'
            Set-IndexCheckedBrief -Fixture $f
            Set-Content -Path (Join-Path $f.Repo 'wip.txt') -Value 'the owner''s' -Encoding utf8
            $r = Invoke-CheckoutDispatch -Fixture $f
            @(Get-IndexEntries -All -DataPath $f.DataPath | ForEach-Object { $_.path }) |
                Should -Contain 'data\brief\checkout-baseline.json'
            $null = Restore-CheckoutWorkerSettings -RecordPath $r.settingsRecord
            $null = Remove-IndexEntry -Path $r.settingsRecord -DataPath $f.DataPath
            Set-Content -Path (Join-Path $f.Repo 'fix.txt') -Value 'the session''s' -Encoding utf8

            $null = Invoke-CheckoutDispatch -Fixture $f
            $text = Get-DispatchText $f
            $mine   = $text.IndexOf('**this session''s own earlier fixes**')
            $theirs = $text.IndexOf('**not yours**')
            $theirs | Should -BeGreaterThan -1
            $mine   | Should -BeGreaterThan $theirs
            $text.IndexOf('- `?? wip.txt`') | Should -BeGreaterThan $theirs
            $text.IndexOf('- `?? wip.txt`') | Should -BeLessThan $mine
            $text.IndexOf('- `?? fix.txt`') | Should -BeGreaterThan $mine
        }

        It 'refuses a baseline a different first dispatch left, before creating anything' {
            $f = New-DispatchFixture 'checkout-otherbaseline'
            git -C $f.Repo checkout -q -b 'feature-x'
            Set-Content -Path (Join-Path $f.BriefDir 'checkout-baseline.json') -Encoding utf8 `
                -Value '{ "worker": "acme-web-session", "checkout": "C:\\repos\\acme-web", "branch": "feature-x", "dirty": [] }'
            $before = [System.IO.File]::ReadAllText($f.BriefPath)
            { Invoke-CheckoutDispatch -Fixture $f } | Should -Throw '*different first dispatch*'
            Assert-NothingCreated -Fixture $f -BriefBefore $before
        }

        It 'never writes the checkout section into an ordinary worktree brief' {
            $f = New-DispatchFixture 'worktree-plain'
            $null = Invoke-Dispatch -Fixture $f -Name 'T-1901'
            [System.IO.File]::ReadAllText($f.BriefPath).Contains('## Working in the checkout') |
                Should -BeFalse
            Test-Path -LiteralPath (Get-DispatchFilePath $f) | Should -BeFalse `
                -Because 'a worktree dispatch with nothing to attach has nothing to add'
        }
    }

    Context 'a repository whose integration branch is not its default branch' {
        BeforeAll {
            Set-AgentStartState
            $script:Split = New-DispatchFixture 'split-branch'

            # Default `main`, integration `dev`, and a commit that exists only on `dev` - so a
            # worktree cut from the default branch is missing a file a worktree cut from the
            # integration branch has, and the two are told apart by what is on disk.
            $repo = New-TempRepo -WithOrigin
            git -C $repo checkout -q -b 'dev'
            Set-Content -Path (Join-Path $repo 'only-on-dev.txt') -Value 'integration' -Encoding utf8
            git -C $repo add -A
            git -C $repo commit -q -m 'A commit that exists only on the integration branch'
            git -C $repo push -q origin 'dev' 2>&1 | Out-Null
            git -C $repo checkout -q 'main'
            git -C $repo remote set-head origin -a 2>&1 | Out-Null
            Set-DeclaredBranch -RepoPath $repo -Yaml "pr:`n  base_branch: dev"

            $script:Split.Repo   = $repo
            $script:SplitResult  = Invoke-Dispatch -Fixture $script:Split -Name 'T-3001'
        }

        It 'cuts the worker from the declared branch, not from the default one' {
            # origin/HEAD really does name the other branch, so the declaration is being
            # preferred rather than winning because the alternative was missing.
            (git -C $script:Split.Repo symbolic-ref --short refs/remotes/origin/HEAD) |
                Should -Be 'origin/main'

            $head = (& git -C $script:SplitResult.worktree rev-parse 'HEAD').Trim()
            $head | Should -Be (& git -C $script:Split.Repo rev-parse 'origin/dev').Trim()
            $head | Should -Not -Be (& git -C $script:Split.Repo rev-parse 'origin/main').Trim()
        }

        # What the worker sees when it opens its checkout: the integration branch's tree, with the
        # work that has landed there present rather than absent.
        It 'gives the worker a checkout holding the integration branch work' {
            Test-Path -LiteralPath (Join-Path $script:SplitResult.worktree 'only-on-dev.txt') |
                Should -BeTrue -Because 'the worker is working on top of what has already integrated'
        }

        # The recorded base is what the landing gate diffs against, so recording the default
        # branch here would fold every dev-only commit into the worker's diff.
        It 'records the declared branch as the base the landing gate will diff against' {
            $script:SplitResult.base | Should -Be 'origin/dev'
        }

        # The diff the landing gate actually takes, run against the base this dispatch recorded:
        # empty on a fresh branch, because the worker has written nothing yet. Against the default
        # branch it would list the integration branch's file as this worker's work.
        It 'leaves the landing diff empty until the worker writes something' {
            $diff = @(& git -C $script:SplitResult.worktree diff --name-only `
                             "$($script:SplitResult.base)...HEAD" | Where-Object { $_.Trim() })
            $diff | Should -BeNullOrEmpty
            @(& git -C $script:SplitResult.worktree diff --name-only 'origin/main...HEAD') |
                Should -Contain 'only-on-dev.txt' `
                -Because 'this is the widened diff the declaration exists to avoid'
        }
    }

    # A repository whose work integrates on a FEATURE branch, which nothing may write into its
    # tracked `.no-mistakes.yaml`: `pr.base_branch: epic-checkout` would be wrong the moment the epic
    # merges. So the base is named for the one task instead. What has to hold is that the ref handed
    # in is both the ref the worktree is cut from and the ref recorded for the landing gate - one
    # string doing both jobs, because a base naming one tree while the branch was cut from another
    # is the gate measuring commits nobody in the ticket wrote.
    Context 'a dispatch that names its own base' {
        BeforeAll {
            Set-AgentStartState
            $script:Named = New-DispatchFixture 'named-base'

            # Three branches, each carrying a file the others do not, so which one the worktree came
            # from is decided by what is on disk rather than by the string that came back. `dev` is
            # declared as well, and `epic-checkout` is cut from `main` rather than from `dev`, so the
            # named base is beating a live declaration rather than winning because nothing else was
            # there.
            $repo = New-TempRepo -WithOrigin
            git -C $repo checkout -q -b 'dev'
            Set-Content -Path (Join-Path $repo 'only-on-dev.txt') -Value 'integration' -Encoding utf8
            git -C $repo add -A
            git -C $repo commit -q -m 'A commit that exists only on the integration branch'
            git -C $repo push -q origin 'dev' 2>&1 | Out-Null
            git -C $repo checkout -q 'main'
            git -C $repo checkout -q -b 'epic-checkout'
            Set-Content -Path (Join-Path $repo 'only-on-epic.txt') -Value 'epic' -Encoding utf8
            git -C $repo add -A
            git -C $repo commit -q -m 'A commit that exists only on the epic branch'
            git -C $repo push -q origin 'epic-checkout' 2>&1 | Out-Null
            git -C $repo checkout -q 'main'
            git -C $repo remote set-head origin -a 2>&1 | Out-Null
            Set-DeclaredBranch -RepoPath $repo -Yaml "pr:`n  base_branch: dev"

            $script:Named.Repo  = $repo
            $script:NamedResult = Invoke-Dispatch -Fixture $script:Named -Name 'T-3101' `
                                                  -Base 'origin/epic-checkout'
        }

        It 'cuts the worktree from the base it was handed rather than from the resolved one' {
            # What the resolver would have said, asked directly, so the named base is demonstrably
            # replacing a live answer rather than filling in for a missing one.
            Resolve-BaseRef -RepoPath $script:Named.Repo | Should -Be 'origin/dev'

            $head = (& git -C $script:NamedResult.worktree rev-parse 'HEAD').Trim()
            $head | Should -Be (& git -C $script:Named.Repo rev-parse 'origin/epic-checkout').Trim()
            $head | Should -Not -Be (& git -C $script:Named.Repo rev-parse 'origin/dev').Trim()
            $head | Should -Not -Be (& git -C $script:Named.Repo rev-parse 'origin/main').Trim()
        }

        It 'gives the worker a checkout holding the epic branch work and not the other branch''s' {
            Test-Path -LiteralPath (Join-Path $script:NamedResult.worktree 'only-on-epic.txt') |
                Should -BeTrue -Because 'the worker is working on top of the epic it was pointed at'
            Test-Path -LiteralPath (Join-Path $script:NamedResult.worktree 'only-on-dev.txt') |
                Should -BeFalse -Because 'the declaration was not what this dispatch was cut from'
        }

        # THE POINT OF THE WHOLE PARAMETER, asserted as two halves of one fact rather than as a
        # returned string: the base recorded for the landing gate resolves to the very commit the
        # worktree starts at. Record one ref and cut from another and the gate diffs against a tree
        # the branch was never based on, which is how an empty diff once read as clean.
        It 'records the same ref it cut the worktree from' {
            $script:NamedResult.base | Should -Be 'origin/epic-checkout'
            $recorded = (& git -C $script:NamedResult.worktree rev-parse `
                                "$($script:NamedResult.base)^{commit}").Trim()
            $recorded | Should -Be (& git -C $script:NamedResult.worktree rev-parse 'HEAD').Trim()
        }

        It 'leaves the landing diff empty until the worker writes something' {
            $diff = @(& git -C $script:NamedResult.worktree diff --name-only `
                             "$($script:NamedResult.base)...HEAD" | Where-Object { $_.Trim() })
            $diff | Should -BeNullOrEmpty
            @(& git -C $script:NamedResult.worktree diff --name-only 'origin/dev...HEAD') |
                Should -Contain 'only-on-epic.txt' `
                -Because 'this is the widened diff naming the base for one task exists to avoid'
        }

        # The parameter's own default, fired on the same repository, so the two answers are told
        # apart by the parameter alone. This is the branch every dispatch that names no base takes.
        It 'resolves the base itself when the same repository is dispatched without one' {
            Set-AgentStartState
            $r = Invoke-Dispatch -Fixture $script:Named -Name 'T-3102'
            $r.base | Should -Be 'origin/dev' -Because 'with no base named, nothing about resolution changes'
            (& git -C $r.worktree rev-parse 'HEAD').Trim() |
                Should -Be (& git -C $script:Named.Repo rev-parse 'origin/dev').Trim()
        }

        # NAMING A BASE SKIPS THE RESOLVER, and the resolver is the only thing that says out loud
        # when the branch point and the pull request target have come apart - so without this the
        # dispatch most likely to have them apart is the quietest one in the fleet. It fires
        # unconditionally: the target is taken from `pr.base_branch` on the default branch, falling
        # back to that default branch, and this dispatch reads neither, so a warning conditioned on
        # a declaration would cover half the cases while reading as though it covered all of them.
        It 'warns that the pull request target is decided somewhere this dispatch did not look' {
            Set-AgentStartState
            $f = New-DispatchFixture 'named-base-warns'
            git -C $f.Repo branch 'epic-checkout'

            $warnings = @()
            $r = & $script:DispatchScript -RepoPath $f.Repo -Name 'T-3107' `
                -BriefPath $f.BriefPath -DataPath $f.DataPath -Base 'epic-checkout' `
                -WarningVariable warnings
            $r.base | Should -Be 'epic-checkout'
            $text = $warnings -join ' '
            $text | Should -BeLike '*based on epic-checkout because this dispatch named it*'
            $text | Should -BeLike '*pr.base_branch on the default branch*'
            $text | Should -BeLike '*carries every commit epic-checkout has and its target does*'
        }

        # The other half of unconditional: it belongs to the parameter and to nothing else, so an
        # ordinary dispatch - which is nearly all of them - must not start carrying a warning about
        # a pull request target it never touched.
        It 'says nothing of the kind when the base is resolved rather than named' {
            Set-AgentStartState
            $f = New-DispatchFixture 'named-base-quiet'

            $warnings = @()
            $r = & $script:DispatchScript -RepoPath $f.Repo -Name 'T-3108' `
                -BriefPath $f.BriefPath -DataPath $f.DataPath -WarningVariable warnings
            $r.id | Should -Be 'T-3108'
            @($warnings | Where-Object { "$_" -like '*because this dispatch named it*' }) |
                Should -BeNullOrEmpty
        }

        # Refused where it costs nothing: before the worktree, the branch, the staged copies and the
        # pane. A base that resolves to nothing is worse than a wrong one - `git log` and `git diff`
        # against a missing ref write nothing to stdout, so the gate reads empty evidence as clean.
        It 'refuses a base git cannot resolve, and makes no herdr call at all' {
            Set-AgentStartState
            $f = New-DispatchFixture 'named-base-unresolvable'

            { Invoke-Dispatch -Fixture $f -Name 'T-3103' -Base 'origin/no-such-epic' } |
                Should -Throw '*git cannot resolve it*'
            (Get-CallLines $f).Count | Should -Be 0
            Test-Path -LiteralPath (Join-Path $f.Repo '.claude\worktrees\T-3103') |
                Should -BeFalse -Because 'nothing is created before the base is known to exist'
        }

        # Going around the resolver must not go around its guard. The branch really does resolve, so
        # this is the rule firing on the name rather than on the ref being missing.
        It 'refuses a base in the worker branch namespace even though it resolves' {
            Set-AgentStartState
            $f = New-DispatchFixture 'named-base-worker'
            git -C $f.Repo checkout -q -b 'worktree-other'
            Set-Content -Path (Join-Path $f.Repo 'other.txt') -Value 'other' -Encoding utf8
            git -C $f.Repo add -A
            git -C $f.Repo commit -q -m 'Another worker commit'
            git -C $f.Repo checkout -q 'main'
            Test-RefResolves -RepoPath $f.Repo -Ref 'worktree-other' | Should -BeTrue

            { Invoke-Dispatch -Fixture $f -Name 'T-3104' -Base 'worktree-other' } |
                Should -Throw '*worker branch namespace*'
            (Get-CallLines $f).Count | Should -Be 0
            Test-Path -LiteralPath (Join-Path $f.Repo '.claude\worktrees\T-3104') |
                Should -BeFalse -Because 'nothing is created before the base is known to be allowed'
        }

        # THE SAME BRANCH UNDER EVERY NAME GIT RESOLVES IT BY. The guard used to be asked only about
        # the resolver's own candidates, which can hold nothing but `worktree-x` and
        # `origin/worktree-x`; asked about a string somebody typed, those two are not the whole
        # question. `refs/remotes/origin/worktree-x` is what `git branch -a` prints, which is where
        # a name gets copied from, and it points at the identical commit.
        It 'refuses <Ref>, which git resolves to another worker''s branch' -ForEach @(
            @{ Ref = 'refs/heads/worktree-other';          Name = 'T-3109' },
            @{ Ref = 'heads/worktree-other';               Name = 'T-3110' },
            @{ Ref = 'remotes/origin/worktree-other';      Name = 'T-3111' },
            @{ Ref = 'refs/remotes/origin/worktree-other'; Name = 'T-3112' }
        ) {
            Set-AgentStartState
            $f = New-DispatchFixture 'named-base-spelling'
            $f.Repo = New-TempRepo -WithOrigin
            git -C $f.Repo checkout -q -b 'worktree-other'
            Set-Content -Path (Join-Path $f.Repo 'other.txt') -Value 'other' -Encoding utf8
            git -C $f.Repo add -A
            git -C $f.Repo commit -q -m 'Another worker commit'
            git -C $f.Repo push -q origin 'worktree-other' 2>&1 | Out-Null
            git -C $f.Repo checkout -q 'main'
            Test-RefResolves -RepoPath $f.Repo -Ref $Ref | Should -BeTrue `
                -Because 'the refusal has to fire on a name that really does resolve'
            (& git -C $f.Repo rev-parse "$Ref^{commit}").Trim() |
                Should -Be (& git -C $f.Repo rev-parse 'worktree-other^{commit}').Trim()

            { Invoke-Dispatch -Fixture $f -Name $Name -Base $Ref } |
                Should -Throw '*worker branch namespace*'
            (Get-CallLines $f).Count | Should -Be 0
            Test-Path -LiteralPath (Join-Path $f.Repo ".claude\worktrees\$Name") |
                Should -BeFalse -Because 'nothing is created before the base is known to be allowed'
        }

        It 'leaves a base that merely contains worktree- alone' {
            Set-AgentStartState
            $f = New-DispatchFixture 'named-base-lookalike'
            git -C $f.Repo branch 'feature/worktree-cleanup'

            $r = Invoke-Dispatch -Fixture $f -Name 'T-3105' -Base 'feature/worktree-cleanup'
            $r.base | Should -Be 'feature/worktree-cleanup'
        }

        # The refusals say "Nothing was created" and that has to be true of the staged copies too,
        # which are written well before the base is used. Checked early for exactly this reason.
        It 'refuses before a single read-first copy is staged' {
            Set-AgentStartState
            $f = New-DispatchFixture 'named-base-nodebris'
            $one = Join-Path (Split-Path $f.BriefDir -Parent) 'brand.md'
            Set-Content -Path $one -Value 'teal' -Encoding utf8
            Set-ReadFirstBrief -Fixture $f -Leaf @('brand.md')

            { & $script:DispatchScript -RepoPath $f.Repo -Name 'T-3106' -BriefPath $f.BriefPath `
                -DataPath $f.DataPath -ReadPath $one -Base 'origin/no-such-epic' } |
                Should -Throw '*Nothing was created*'
            Test-Path -LiteralPath (Join-Path $f.BriefDir 'read-first') |
                Should -BeFalse -Because 'a refusal that says nothing was created must have created nothing'
        }
    }

    Context 're-dispatching the same ticket' {
        # `git worktree add -b` cannot be told twice, and a raw "fatal: a branch named
        # worktree-T-2001 already exists" is not something the Hand can route on. Sending a worker
        # back to the same ticket is ordinary, so each of the three states it can find is decided
        # deliberately.
        It 'reuses the checkout that is already there rather than failing on the branch' {
            Set-AgentStartState
            $f = New-DispatchFixture 'again'
            $one = Invoke-Dispatch -Fixture $f -Name 'T-2001'
            Set-Content -Path (Join-Path $one.worktree 'work-in-progress.txt') -Value 'kept' -Encoding utf8

            $two = Invoke-Dispatch -Fixture $f -Name 'T-2001'
            $two.worktree | Should -Be $one.worktree
            $two.branch   | Should -Be $one.branch
            Test-Path -LiteralPath (Join-Path $one.worktree 'work-in-progress.txt') |
                Should -BeTrue -Because 'unlanded work is never discarded to get a clean add'
        }

        It 'checks the branch out again when the branch outlived its worktree' {
            Set-AgentStartState
            $f = New-DispatchFixture 'branch-survived'
            $one = Invoke-Dispatch -Fixture $f -Name 'T-2002'
            & git -C $f.Repo worktree remove --force $one.worktree 2>&1 | Out-Null
            (& git -C $f.Repo rev-parse --verify --quiet 'refs/heads/worktree-T-2002') |
                Should -Not -BeNullOrEmpty -Because 'the branch is the work, and removal kept it'

            $two = Invoke-Dispatch -Fixture $f -Name 'T-2002'
            (& git -C $two.worktree rev-parse --abbrev-ref HEAD).Trim() | Should -Be 'worktree-T-2002'
        }

        # A directory deleted by hand leaves a record under .git\worktrees, and `git worktree add`
        # then refuses with "already exists" about a directory nobody can see.
        It 'prunes a stale worktree record instead of refusing over a directory that is gone' {
            Set-AgentStartState
            $f = New-DispatchFixture 'stale-record'
            $one = Invoke-Dispatch -Fixture $f -Name 'T-2003'
            Remove-Item -LiteralPath $one.worktree -Recurse -Force

            { Invoke-Dispatch -Fixture $f -Name 'T-2003' } | Should -Not -Throw
            Test-Path -LiteralPath (Join-Path $one.worktree '.git') | Should -BeTrue
        }

        It 'refuses when something git does not own is sitting at the worktree path' {
            Set-AgentStartState
            $f = New-DispatchFixture 'foreign-dir'
            $path = Join-Path $f.Repo '.claude\worktrees\T-2004'
            New-Item -ItemType Directory -Force -Path $path | Out-Null
            Set-Content -Path (Join-Path $path 'someones-notes.txt') -Value 'not ours' -Encoding utf8

            { Invoke-Dispatch -Fixture $f -Name 'T-2004' } |
                Should -Throw '*git does not own it*'
        }
    }

    Context 'a worker that comes back blocked' {
        # herdr reports agent_not_ready while the agent exists and sits on an interactive prompt,
        # so Start-HerdrAgent hands back the live record instead of throwing. Sending keys at a
        # prompt nobody has read answers whichever option happens to be highlighted, and a batched
        # arrow+enter is delivered out of order and picks the wrong one while returning success.
        It 'reports the block and sends no keys at it' {
            Set-AgentStartState -State 'blocked'
            $f = New-DispatchFixture 'blocked'

            { Invoke-Dispatch -Fixture $f -Name 'T-3001' } | Should -Throw '*blocked on an interactive prompt*'

            $lines = Get-CallLines $f
            @($lines | Where-Object { $_ -like 'agent send-keys*' }).Count |
                Should -Be 0 -Because 'nothing here answers a security prompt it has not read'
            @($lines | Where-Object { $_ -like 'agent prompt*' }).Count |
                Should -Be 0 -Because 'a blocked agent cannot take the brief, so it is not submitted'
        }

        It 'leaves the worktree and branch in place, and names them' {
            Set-AgentStartState -State 'blocked'
            $f = New-DispatchFixture 'blocked-evidence'
            $err = $null
            try { Invoke-Dispatch -Fixture $f -Name 'T-3002' } catch { $err = $_.Exception.Message }

            $expected = Join-Path $f.Repo '.claude\worktrees\T-3002'
            $err | Should -BeLike "*$expected*"
            $err | Should -BeLike '*worktree-T-3002*'
            Test-Path -LiteralPath (Join-Path $expected '.git') | Should -BeTrue
        }

        AfterAll { Set-AgentStartState }
    }

    # `agent prompt` returns once the text is written, not once the worker has taken it. A start
    # prompt left sitting in the box used to come back as a successful dispatch of a worker that
    # had not started, so dispatch now confirms it and names what it saw when it was not taken.
    Context 'a start prompt that is not taken' {
        BeforeAll {
            # The box drawn the way Claude Code really draws it - the caret and a NO-BREAK space -
            # holding a collapsed paste, which is how a long start prompt sits in it unsent.
            $rule = ([string][char]0x2500) * 92
            $script:UnsentScreen = @(
                '* Claude Code v2.1.220 - Opus - E:\repo', '', $rule,
                "$([char]0x276F)$([char]0x00A0)[Pasted text #1 +3 lines]", $rule,
                '  bypass permissions on (shift+tab to cycle) - left arrow for agents')
            Set-HerdrReply -Verb 'agent-send-keys' -Result @{ ok = $true }

            function Invoke-ShortConfirmDispatch {
                param([Parameter(Mandatory)]$Fixture, [Parameter(Mandatory)][string]$Name)
                & $script:DispatchScript -RepoPath $Fixture.Repo -Name $Name `
                    -BriefPath $Fixture.BriefPath -DataPath $Fixture.DataPath `
                    -PromptConfirmSeconds 2
            }
        }

        It 'refuses by name when the prompt is still in the box, and never sends it twice' {
            Set-AgentStartState -AfterPrompt 'idle' -AfterPromptScreen $script:UnsentScreen
            $f = New-DispatchFixture 'unsent'

            { Invoke-ShortConfirmDispatch -Fixture $f -Name 'T-3101' } | Should -Throw '*(UNSENT)*'

            $lines = Get-CallLines $f
            @($lines | Where-Object { $_ -like 'agent prompt*' }).Count |
                Should -Be 1 -Because 'a second copy of the brief would be submitted with the first'
            @($lines | Where-Object { $_ -like 'agent send-keys * enter' }).Count |
                Should -Be 1 -Because 'the one resend is a bare Enter on the text already there'
        }

        It 'refuses by name when the box empties but the worker never starts, and resends nothing' {
            Set-AgentStartState -AfterPrompt 'idle'
            $f = New-DispatchFixture 'not-started'

            { Invoke-ShortConfirmDispatch -Fixture $f -Name 'T-3102' } |
                Should -Throw '*(NOT-STARTED)*'

            $lines = Get-CallLines $f
            @($lines | Where-Object { $_ -like 'agent prompt*' }).Count | Should -Be 1
            @($lines | Where-Object { $_ -like 'agent send-keys*' }).Count |
                Should -Be 0 -Because 'with the box empty the brief may already be submitted'
        }

        It 'returns once the worker is working with its box empty, on the default wait' {
            Set-AgentStartState
            $f = New-DispatchFixture 'taken'
            $r = Invoke-Dispatch -Fixture $f -Name 'T-3103'
            $r.id | Should -Be 'T-3103'
            @(Get-CallLines $f | Where-Object { $_ -like 'agent send-keys*' }).Count | Should -Be 0
        }

        AfterAll { Set-AgentStartState }
    }

    Context 'refusing before anything is spawned' {
        # Resolve-BaseRef refuses rather than inventing a ref, and it is called first for exactly
        # this reason: a refusal after the spawn would leave an agent running with nothing recorded.
        It 'makes no herdr call at all when the base cannot be resolved' {
            Set-AgentStartState
            $f = New-DispatchFixture 'no-base'
            $empty = New-TempRepo -Empty
            # DataPath is carried over with the rest. Without it this dispatch reads the real
            # installation's data\ - a live registry and a live root index deciding whether a unit
            # test refuses, which is the one thing every case here is built to avoid.
            $f2 = [pscustomobject]@{
                Repo = $empty; BriefPath = $f.BriefPath; BriefDir = $f.BriefDir
                DataPath = $f.DataPath; Home = $f.Home; CallLog = $f.CallLog
            }

            { Invoke-Dispatch -Fixture $f2 -Name 'T-4001' } | Should -Throw '*Cannot resolve a base ref*'
            (Get-CallLines $f2).Count | Should -Be 0
            Test-Path -LiteralPath (Join-Path $empty '.claude\worktrees\T-4001') |
                Should -BeFalse -Because 'nothing is created before the base is known'
        }

        It 'refuses a brief that is not on disk' {
            $f = New-DispatchFixture 'no-brief'
            { & $script:DispatchScript -RepoPath $f.Repo -Name 'T-4002' -DataPath $f.DataPath `
                -BriefPath (Join-Path $f.BriefDir 'missing.md') } | Should -Throw '*Brief not found*'
        }

        # A brief naming a file that is not there is a brief the worker cannot carry out, and
        # finding that out after it is running costs a whole dispatch.
        It 'refuses a Read-first path that is not on disk, before creating anything' {
            Set-AgentStartState
            $f = New-DispatchFixture 'no-readpath'
            { & $script:DispatchScript -RepoPath $f.Repo -Name 'T-4003' -BriefPath $f.BriefPath `
                -DataPath $f.DataPath -ReadPath (Join-Path $f.BriefDir '..\brand.md') } |
                Should -Throw '*under Read first and it does not exist*'
            Test-Path -LiteralPath (Join-Path $f.Repo '.claude\worktrees\T-4003') |
                Should -BeFalse -Because 'nothing is created before every named file is known to be there'
        }
    }

    # A worker started into the last few percent of a usage window dies mid-run and leaves the work
    # half done. The check is first of all of them because it is the one that costs nothing to fail:
    # nothing exists yet, so the refusal is free.
    #
    # THE HALF THAT MATTERS MOST IS THE FAIL-OPEN HALF. A reading nobody could take must never make
    # kingshand undispatchable, so only a percentage that was actually read refuses.
    Context 'the usage window near its limit' {
        AfterEach { Set-UsageReply }

        It 'refuses at the threshold nobody passes, and creates nothing' {
            Set-AgentStartState
            Set-UsageReply -Percent 95
            $f = New-DispatchFixture 'usage-refused'

            { Invoke-Dispatch -Fixture $f -Name 'T-4101' } |
                Should -Throw '*new work is refused from 90 percent*'
            (Get-CallLines $f).Count | Should -Be 0 -Because 'nothing is spawned to be refused later'
            Test-Path -LiteralPath (Join-Path $f.Repo '.claude\worktrees\T-4101') | Should -BeFalse
            @(& git -C $f.Repo branch --list 'worktree-T-4101') |
                Should -BeNullOrEmpty -Because 'the refusal says nothing was created'
        }

        It 'names the number so the Hand can relay it' {
            Set-AgentStartState
            Set-UsageReply -Percent 95
            $f = New-DispatchFixture 'usage-message'

            $err = { Invoke-Dispatch -Fixture $f -Name 'T-4102' } | Should -Throw -PassThru
            "$($err.Exception.Message)" | Should -BeLike '*95 percent spent*'
            "$($err.Exception.Message)" | Should -BeLike '*Nothing was created*'
        }

        # THESE TWO PIN THE DEFAULT THRESHOLD, and they are where the number 90 is held. Neither
        # passes -UsageThresholdPercent, so both run on whatever the dispatcher's own default is:
        # move it and one of the pair goes red. Docs.Tests.ps1 holds the other end - that the vigil
        # skill and the design note tell the King the same 90 - so the two halves cannot drift apart
        # without a test saying so, and neither half proves its point by reading the other's source.
        It 'refuses exactly at the threshold, not only past it' {
            Set-AgentStartState
            Set-UsageReply -Percent 90
            $f = New-DispatchFixture 'usage-boundary'
            { Invoke-Dispatch -Fixture $f -Name 'T-4103' } | Should -Throw '*refused from 90 percent*'
        }

        It 'dispatches below the threshold' {
            Set-AgentStartState
            Set-UsageReply -Percent 89
            $f = New-DispatchFixture 'usage-under'
            (Invoke-Dispatch -Fixture $f -Name 'T-4104').id | Should -Be 'T-4104'
        }

        It 'takes a higher threshold from a caller that has to send this one out now' {
            Set-AgentStartState
            Set-UsageReply -Percent 95
            $f = New-DispatchFixture 'usage-override'
            $r = & $script:DispatchScript -RepoPath $f.Repo -Name 'T-4105' `
                -BriefPath $f.BriefPath -DataPath $f.DataPath -UsageThresholdPercent 99
            $r.id | Should -Be 'T-4105'
        }

        # A HELD WINDOW IS AT THE LIMIT WHATEVER THE THRESHOLD. The first dispatch reads 91 and is
        # refused, which holds the window; the probe then answers 5, and a dispatch that may go out
        # up to 99 must still be refused, because nothing reads a held window before its reset.
        It 'refuses on a held window even when the caller allows up to 99 percent' {
            Set-AgentStartState
            Set-UsageReply -Percent 91
            $f = New-DispatchFixture 'usage-held'
            { Invoke-Dispatch -Fixture $f -Name 'T-4107' } | Should -Throw '*refused from 90 percent*'

            ($reply = @{ type = 'rate_limit_event'; rate_limit_info = @{ status = 'allowed'
                unifiedWindows = @{ five_hour = @{ utilization = 0.05
                    resetsAt = [datetimeoffset]::UtcNow.AddHours(3).ToUnixTimeSeconds() } } } }) | Out-Null
            ($reply | ConvertTo-Json -Depth 8 -Compress) |
                Set-Content -Path (Join-Path $script:ShimDir 'probe.txt') -Encoding utf8

            $err = { & $script:DispatchScript -RepoPath $f.Repo -Name 'T-4108' `
                        -BriefPath $f.BriefPath -DataPath $f.DataPath -UsageThresholdPercent 99 } |
                Should -Throw -PassThru
            "$($err.Exception.Message)" | Should -BeLike '*held from 90 percent until its reset*'
            "$($err.Exception.Message)" | Should -BeLike '*at least 91 percent*'
            "$($err.Exception.Message)" | Should -BeLike '*It resets at*'
            "$($err.Exception.Message)" | Should -BeLike '*Nothing was created*'
            (Get-CallLines $f).Count | Should -Be 0
        }

        # The prompt-box guards already made this call for an unreadable screen and the reasoning
        # transfers: a blind guard that blocks everything costs more than one that lets work through
        # and says it could not see.
        It 'dispatches anyway when the reading could not be taken, and warns' {
            Set-AgentStartState
            Set-UsageReply -Broken
            $f = New-DispatchFixture 'usage-unknown'

            $warnings = @()
            $r = & $script:DispatchScript -RepoPath $f.Repo -Name 'T-4106' `
                -BriefPath $f.BriefPath -DataPath $f.DataPath -WarningVariable warnings
            $r.id | Should -Be 'T-4106'
            @($warnings | Where-Object { "$_" -like '*usage window*could not be established*' }).Count |
                Should -BeGreaterThan 0 -Because 'a guard that has gone blind must say so'
        }

        # THE MEASURED TRAP, AT THE PLACE IT WOULD HAVE COST SOMETHING. The reply above always
        # carries a spend cap at 100 percent with no reset time, exactly as this machine reports it.
        # A threshold taken across every window would read 100 and refuse this dispatch, and every
        # dispatch after it, for good.
        It 'is not refused by a hundred-percent window that has no reset time' {
            Set-AgentStartState
            Set-UsageReply -Percent 5
            $f = New-DispatchFixture 'usage-spend-cap'
            (Invoke-Dispatch -Fixture $f -Name 'T-4108').id | Should -Be 'T-4108'
        }

        # A stale reading is never a number, so it cannot refuse as a measurement - but the cached
        # figure is a floor, consumption never falls inside a window, and a floor already past the
        # threshold means the real figure is too.
        It 'refuses on a stale floor that is already past the threshold' {
            Set-AgentStartState
            Set-UsageReply -Percent 95 -Stale
            $f = New-DispatchFixture 'usage-floor-over'

            $err = { Invoke-Dispatch -Fixture $f -Name 'T-4109' } | Should -Throw -PassThru
            "$($err.Exception.Message)" | Should -BeLike '*At least 95 percent*'
            "$($err.Exception.Message)" | Should -BeLike '*floor from a cached reading*'
            Test-Path -LiteralPath (Join-Path $f.Repo '.claude\worktrees\T-4109') | Should -BeFalse
        }

        # THE COMPARISON IS RAW AND THE FIGURE SHOWN IS ROUNDED DOWN, and this case is where the
        # two would part company if either moved. A floor of 90.4 is past the threshold as an exact
        # number, so it refuses; the message says "at least 90 percent" because that is all the
        # cached reading measured, and claiming 91 would assert a point nobody read. Round the
        # comparison instead and this dispatch would go out; round the message up and it would
        # overstate the evidence.
        It 'refuses on the exact floor while saying only the percentage that was measured' {
            Set-AgentStartState
            Set-UsageReply -Percent 90.4 -Stale
            $f = New-DispatchFixture 'usage-floor-exact'

            $err = { Invoke-Dispatch -Fixture $f -Name 'T-4111' } | Should -Throw -PassThru
            "$($err.Exception.Message)" | Should -BeLike '*At least 90 percent*'
            "$($err.Exception.Message)" | Should -Not -BeLike '*At least 91 percent*'
        }

        # The other side of that boundary. 89.6 shows as 89 and must still dispatch, because the
        # exact figure is under the threshold - a comparison that rounded the floor up first would
        # refuse this one.
        It 'dispatches on a floor under the threshold that would refuse if it were rounded up' {
            Set-AgentStartState
            Set-UsageReply -Percent 89.6 -Stale
            $f = New-DispatchFixture 'usage-floor-near'

            $r = & $script:DispatchScript -RepoPath $f.Repo -Name 'T-4112' `
                -BriefPath $f.BriefPath -DataPath $f.DataPath -WarningAction SilentlyContinue
            $r.id | Should -Be 'T-4112'
        }

        # A refusal that does not say when the window clears leaves out the one thing wanted next,
        # and on this machine the floor refusal is the one that fires most.
        It 'tells the user when the window resets on a floor refusal' {
            Set-AgentStartState
            Set-UsageReply -Percent 95 -Stale
            $f = New-DispatchFixture 'usage-floor-reset'

            $err = { Invoke-Dispatch -Fixture $f -Name 'T-4113' } | Should -Throw -PassThru
            "$($err.Exception.Message)" | Should -BeLike '*It resets at *'
        }

        It 'dispatches on a stale floor below the threshold, and says the reading was not current' {
            Set-AgentStartState
            Set-UsageReply -Percent 20 -Stale
            $f = New-DispatchFixture 'usage-floor-under'

            $warnings = @()
            $r = & $script:DispatchScript -RepoPath $f.Repo -Name 'T-4110' `
                -BriefPath $f.BriefPath -DataPath $f.DataPath -WarningVariable warnings
            $r.id | Should -Be 'T-4110'
            @($warnings | Where-Object { "$_" -like '*without a current usage reading*' }).Count |
                Should -BeGreaterThan 0
        }

        # A settled "nothing here reports this" is a stable fact about the machine rather than
        # something wrong with it, and a warning on every dispatch for a state nobody can act on
        # teaches the reader to skip the next one.
        It 'dispatches without a word when the account reports no windows at all' {
            Set-AgentStartState
            Set-UsageReply -NoWindows
            $f = New-DispatchFixture 'usage-none'

            $warnings = @()
            $r = & $script:DispatchScript -RepoPath $f.Repo -Name 'T-4107' `
                -BriefPath $f.BriefPath -DataPath $f.DataPath -WarningVariable warnings
            $r.id | Should -Be 'T-4107'
            @($warnings | Where-Object { "$_" -like '*usage*' }) | Should -BeNullOrEmpty
        }
    }

    # The settled spec the whole index exists to deliver lives at data\<name>.md, a SIBLING of the
    # brief's own data\<id>\ directory. With only the brief's grant the worker is told to read a
    # file it cannot open, which is the original failure with one extra hop.
    #
    # The fixture puts the spec DIRECTLY under the data root on purpose. An earlier fixture used a
    # subdirectory, which meant the invariant below held for the fixture and was violated by the
    # documented case: granting the containing directory of data\<name>.md grants the data root.
    Context 'a brief that names files to read first' {
        BeforeAll {
            Set-AgentStartState
            $script:Read     = New-DispatchFixture 'readfirst'
            $script:DataRoot = Split-Path $script:Read.BriefDir -Parent
            $script:SpecFile = Join-Path $script:DataRoot 'brand.md'
            Set-Content -Path $script:SpecFile -Value 'teal, not amber' -Encoding utf8
            Set-ReadFirstBrief -Fixture $script:Read -Leaf 'brand.md' -From $script:SpecFile

            $script:ReadResult = & $script:DispatchScript -RepoPath $script:Read.Repo `
                -Name 'T-5001' -BriefPath $script:Read.BriefPath -DataPath $script:Read.DataPath `
                -ReadPath $script:SpecFile
            $script:ReadGrants = @((Get-Content -LiteralPath `
                (Join-Path $script:ReadResult.worktree '.claude\settings.local.json') -Raw |
                ConvertFrom-Json).permissions.additionalDirectories)
            $script:Staged = Join-Path $script:Read.BriefDir 'read-first\brand.md'
        }

        It 'puts each named file where the worker can actually reach it' {
            Test-Path -LiteralPath $script:Staged | Should -BeTrue
            (Get-Content -LiteralPath $script:Staged -Raw).Trim() | Should -Be 'teal, not amber'
        }

        It 'keeps the file name, so the path the brief already named is the path that appears' {
            Split-Path $script:Staged -Leaf | Should -Be (Split-Path $script:SpecFile -Leaf)
        }

        # The grant list is what bypassPermissions applies to, so an entry here is read AND write.
        It 'grants the brief''s own directory and nothing else at all' {
            $script:ReadGrants | Should -Be @($script:Read.BriefDir)
        }

        It 'never grants the data root, whatever the brief names' {
            $script:ReadGrants | Should -Not -Contain $script:DataRoot `
                -Because 'that is every other worker''s brief and report, king.md, learnings.md, backlog.md and projects.md, writable'
        }

        It 'leaves the original where it was' {
            Test-Path -LiteralPath $script:SpecFile | Should -BeTrue
            (Get-Content -LiteralPath $script:SpecFile -Raw).Trim() | Should -Be 'teal, not amber'
        }

        It 'adds no grant when a named file already sits beside the brief itself' {
            Set-AgentStartState
            $f = New-DispatchFixture 'readfirst-same'
            $beside = Join-Path $f.BriefDir 'notes.md'
            Set-Content -Path $beside -Value 'x' -Encoding utf8
            Set-ReadFirstBrief -Fixture $f -Leaf 'notes.md' -From $beside
            $r = & $script:DispatchScript -RepoPath $f.Repo -Name 'T-5002' `
                -BriefPath $f.BriefPath -DataPath $f.DataPath -ReadPath $beside
            $grants = @((Get-Content -LiteralPath `
                (Join-Path $r.worktree '.claude\settings.local.json') -Raw |
                ConvertFrom-Json).permissions.additionalDirectories)
            $grants | Should -Be @($f.BriefDir)
        }

        It 'carries every file the brief named, not just the first' {
            Set-AgentStartState
            $f = New-DispatchFixture 'readfirst-many'
            $root = Split-Path $f.BriefDir -Parent
            $one  = Join-Path $root 'brand.md'
            $two  = Join-Path $root 'voice.md'
            Set-Content -Path $one -Value 'teal' -Encoding utf8
            Set-Content -Path $two -Value 'plain words' -Encoding utf8
            Set-ReadFirstBrief -Fixture $f -Leaf 'brand.md', 'voice.md'

            & $script:DispatchScript -RepoPath $f.Repo -Name 'T-5003' `
                -BriefPath $f.BriefPath -DataPath $f.DataPath -ReadPath $one, $two | Out-Null

            (Get-Content -LiteralPath (Join-Path $f.BriefDir 'read-first\brand.md') -Raw).Trim() |
                Should -Be 'teal'
            (Get-Content -LiteralPath (Join-Path $f.BriefDir 'read-first\voice.md') -Raw).Trim() |
                Should -Be 'plain words'
        }

        # One would land on top of the other and the worker would read whichever was copied last,
        # with nothing to say the other was ever named.
        It 'refuses two different files sharing one name, before creating anything' {
            Set-AgentStartState
            $f = New-DispatchFixture 'readfirst-clash'
            $root = Split-Path $f.BriefDir -Parent
            $a = Join-Path $root 'a\spec.md'
            $b = Join-Path $root 'b\spec.md'
            foreach ($p in @($a, $b)) {
                New-Item -ItemType Directory -Force -Path (Split-Path $p -Parent) | Out-Null
                Set-Content -Path $p -Value 'x' -Encoding utf8
            }
            { & $script:DispatchScript -RepoPath $f.Repo -Name 'T-5004' `
                -BriefPath $f.BriefPath -DataPath $f.DataPath -ReadPath $a, $b } |
                Should -Throw '*two different files called spec.md*'
            Test-Path -LiteralPath (Join-Path $f.Repo '.claude\worktrees\T-5004') | Should -BeFalse
        }

        It 'refuses a directory where a file was meant, before creating anything' {
            Set-AgentStartState
            $f = New-DispatchFixture 'readfirst-dir'
            { & $script:DispatchScript -RepoPath $f.Repo -Name 'T-5005' `
                -BriefPath $f.BriefPath -DataPath $f.DataPath `
                -ReadPath (Split-Path $f.BriefDir -Parent) } |
                Should -Throw '*Name the files the worker must read*'
            Test-Path -LiteralPath (Join-Path $f.Repo '.claude\worktrees\T-5005') | Should -BeFalse
        }
    }

    # Five refusals, and not one of them reads a path out of the brief's prose. An earlier version
    # parsed the `Read first` section and compared that set against -ReadPath in both directions.
    # The intent was right and the mechanism had no last bug: six consecutive review rounds each
    # closed one path shape and exposed the next, and two of them refused correct briefs over paths
    # nobody had written. The Hand writes the brief AND calls the dispatcher, so it supplies the
    # list; what remains is checked where the path is known exactly, plus the one check about the
    # section that never needed a path at all - that it is there.
    Context 'the Read first section the dispatcher requires' {
        # The refusals all say "Nothing was created", and that has to be true. An earlier ordering
        # staged first, so a file was already copied and a directory already existed underneath a
        # message denying both.
        It 'leaves no staged file behind when it refuses' {
            Set-AgentStartState
            $f = New-DispatchFixture 'readfirst-nodebris'
            $one = Join-Path (Split-Path $f.BriefDir -Parent) 'brand.md'
            Set-Content -Path $one -Value 'teal' -Encoding utf8
            Set-Content -Path $f.BriefPath -Encoding utf8 -Value @('# Brief', '', '## Scope', 'Do it.')

            { & $script:DispatchScript -RepoPath $f.Repo -Name 'T-6005' `
                -BriefPath $f.BriefPath -DataPath $f.DataPath -ReadPath $one } |
                Should -Throw '*Nothing was created*'
            Test-Path -LiteralPath (Join-Path $f.BriefDir 'read-first') |
                Should -BeFalse -Because 'a refusal that says nothing was created must have created nothing'
        }

        # The whole point of passing the list structurally: whatever shape a path is written in
        # down there, nothing reads it. Every one of these lines refused a dispatch at some round of
        # the parser's life - the original path, the env-var form the template teaches, the relative
        # form the index stores, a file name with a space in it, and prose that says `read-first\`
        # without naming a file after it. The brief is the WORKER's instruction; -ReadPath is the
        # dispatcher's.
        It 'dispatches whatever path shapes the section is written in, because nothing reads them' {
            Set-AgentStartState
            $f = New-DispatchFixture 'readfirst-shapes'
            $one = Join-Path (Split-Path $f.BriefDir -Parent) 'brand.md'
            Set-Content -Path $one -Value 'teal' -Encoding utf8
            Set-ReadFirstBrief -Fixture $f -Body @(
                "- ``$one`` - the settled brand, written as the original absolute path."
                '- `$env:KINGSHAND_HOME\data\emgee-brand.md` - the form the template teaches.'
                '- `data\emgee-brand.md` - the form the index stores.'
                '- `data\T-1002\read-first\brand spec.md` - another unit''s copy, with a space in it.'
                '- The copy lives under read-first\ in this directory.')

            $r = & $script:DispatchScript -RepoPath $f.Repo -Name 'T-6001' `
                -BriefPath $f.BriefPath -DataPath $f.DataPath -ReadPath $one
            $r.id | Should -Be 'T-6001'
            Test-Path -LiteralPath (Join-Path $f.BriefDir 'read-first\brand.md') | Should -BeTrue
        }

        # A spaced name was refused at -ReadPath only so the prose parser never had to guess where
        # such a path ended. With no parser there is nothing to guess, and staging carries the file
        # perfectly well.
        It 'stages a file whose name contains a space' {
            Set-AgentStartState
            $f = New-DispatchFixture 'readfirst-spaced-name'
            $one = Join-Path (Split-Path $f.BriefDir -Parent) 'brand spec.md'
            Set-Content -Path $one -Value 'teal' -Encoding utf8
            Set-ReadFirstBrief -Fixture $f -Leaf 'brand spec.md' -From $one

            (& $script:DispatchScript -RepoPath $f.Repo -Name 'T-6017' `
                -BriefPath $f.BriefPath -DataPath $f.DataPath -ReadPath $one).id | Should -Be 'T-6017'
            (Get-Content -LiteralPath (Join-Path $f.BriefDir 'read-first\brand spec.md') -Raw).Trim() |
                Should -Be 'teal'
        }

        # A fenced block is quoted example text. A brief for a task on muster's own template quotes
        # that template, and the quoted heading was read as this brief's own section.
        It 'does not accept a Read first heading that only appears inside a fenced block' {
            Set-AgentStartState
            $f = New-DispatchFixture 'readfirst-fenced-heading'
            Set-Content -Path $f.BriefPath -Encoding utf8 -Value @(
                '# Brief', '', '## Requirements', 'The template muster writes is:', '', '```markdown'
                '## Read first'
                '- `$env:KINGSHAND_HOME\data\<id>\read-first\<filename>` - what it settles.'
                '```', '', 'Keep that slot.')

            { Invoke-Dispatch -Fixture $f -Name 'T-6021' } |
                Should -Throw "*has no '## Read first' section*"
        }

        # The two reports an inquest follow-up needs really are both called report.md, so the advice
        # has to be one the caller can act on rather than a rename that breaks the convention every
        # index entry pointing at them uses.
        It 'advises a route that exists when two staged files share one name' {
            Set-AgentStartState
            $f = New-DispatchFixture 'readfirst-clash-advice'
            $root = Split-Path $f.BriefDir -Parent
            $a = Join-Path $root 'T-1000\report.md'
            $b = Join-Path $root 'T-1001\report.md'
            foreach ($p in @($a, $b)) {
                New-Item -ItemType Directory -Force -Path (Split-Path $p -Parent) | Out-Null
                Set-Content -Path $p -Value 'found it' -Encoding utf8
            }

            $err = { & $script:DispatchScript -RepoPath $f.Repo -Name 'T-6020' `
                -BriefPath $f.BriefPath -DataPath $f.DataPath -ReadPath $a, $b } | Should -Throw -PassThru
            $err.Exception.Message | Should -BeLike '*Pass only the one this task needs*'
            $err.Exception.Message | Should -BeLike '*copy one under a distinct name*'
            $err.Exception.Message |
                Should -Not -BeLike '*Rename one*' -Because 'renaming a durable report.md is not a route'
        }

        It 'refuses when the brief has no Read first section at all but a file was staged' {
            Set-AgentStartState
            $f = New-DispatchFixture 'readfirst-nosection'
            $one = Join-Path (Split-Path $f.BriefDir -Parent) 'brand.md'
            Set-Content -Path $one -Value 'teal' -Encoding utf8
            Set-Content -Path $f.BriefPath -Encoding utf8 -Value @('# Brief', '', '## Scope', 'Do it.')

            { & $script:DispatchScript -RepoPath $f.Repo -Name 'T-6007' `
                -BriefPath $f.BriefPath -DataPath $f.DataPath -ReadPath $one } |
                Should -Throw "*has no '## Read first' section*"
        }

        # Every other check compares two sets, and both are empty when the section was never
        # written and -ReadPath was never passed. So the case the whole mechanism exists to
        # prevent - a brief naming no settled file at all - was the one case that passed every
        # guard, and the worker launched knowing nothing about the file that was already decided.
        It 'refuses a brief with no Read first section even when no file was staged' {
            Set-AgentStartState
            $f = New-DispatchFixture 'readfirst-missing-slot'
            Set-Content -Path $f.BriefPath -Encoding utf8 -Value @(
                '# Brief', '', '## Goal', 'Ship the marketing site.', '', '## Scope', 'Repo: whatever')

            { Invoke-Dispatch -Fixture $f -Name 'T-7101' } |
                Should -Throw "*has no '## Read first' section*"
            Test-Path -LiteralPath (Join-Path $f.Repo '.claude\worktrees\T-7101') |
                Should -BeFalse -Because 'the refusal comes before anything is created'
            (Get-CallLines $f).Count |
                Should -Be 0 -Because 'no worker is spawned for a brief that names nothing to read'
        }

        # An empty section and an absent one are different facts, and only the first is a decision
        # somebody made. A brief with genuinely nothing to read must still dispatch.
        It 'dispatches a brief whose section says there is nothing to read' {
            Set-AgentStartState
            $f = New-DispatchFixture 'readfirst-nothing-beyond'
            Set-ReadFirstBrief -Fixture $f

            (Invoke-Dispatch -Fixture $f -Name 'T-7102').id | Should -Be 'T-7102'
        }

        # The shape muster's template actually writes: the copy named as read-first\<leaf>, with the
        # original repeated in the same line as provenance. This is the ordinary dispatch, and it
        # has to stay ordinary.
        It 'dispatches the template shape, which names the copy and the original in one line' {
            Set-AgentStartState
            $f = New-DispatchFixture 'readfirst-provenance'
            $one = Join-Path (Split-Path $f.BriefDir -Parent) 'brand.md'
            Set-Content -Path $one -Value 'teal' -Encoding utf8
            Set-ReadFirstBrief -Fixture $f -Leaf 'brand.md' -From $one

            $r = & $script:DispatchScript -RepoPath $f.Repo -Name 'T-6008' `
                -BriefPath $f.BriefPath -DataPath $f.DataPath -ReadPath $one
            $r.id | Should -Be 'T-6008'
            Test-Path -LiteralPath (Join-Path $f.BriefDir 'read-first\brand.md') | Should -BeTrue
        }
    }

    # The section being there says a slot was filled in. It does not say the index behind it was
    # ever opened, and an index of pointers nobody is obliged to follow is the settled-spec failure
    # at a larger scale - worse, because it looks solved. So a dispatch anything is indexed for
    # cannot go out without one of two deliberate acts: a file passed to -ReadPath, or a line saying
    # the index was checked and nothing in it applies.
    #
    # BOTH indexes count. The root data\index.md is where the settled files this gate protects
    # actually land, and it is not project-scoped, so it gates an unregistered repo as well; the
    # project's own index gates on top of it once the registry resolves one.
    #
    # None of this reads a path out of the brief. The staged count comes from -ReadPath, "lists
    # something" is Index.psm1's answer, and the escape is one stated sentence.
    Context 'the index behind that section' {
        It 'refuses an indexed project when the brief neither names a file nor says it was checked' {
            Set-AgentStartState
            $f = New-DispatchFixture 'index-silent'
            Register-FixtureProject -Fixture $f -WithIndex | Out-Null
            Set-ReadFirstBrief -Fixture $f -Body @('- Nothing beyond this brief.')

            { Invoke-Dispatch -Fixture $f -Name 'T-8001' } |
                Should -Throw '*neither names a file from them to read*'
        }

        # A refusal that says nothing was created has to have created nothing, and this one comes
        # before the staging copy, the worktree and the spawn alike.
        It 'creates nothing at all when it refuses over the index' {
            Set-AgentStartState
            $f = New-DispatchFixture 'index-nodebris'
            Register-FixtureProject -Fixture $f -WithIndex | Out-Null
            Set-ReadFirstBrief -Fixture $f -Body @('- Nothing beyond this brief.')

            { Invoke-Dispatch -Fixture $f -Name 'T-8002' } | Should -Throw '*Nothing was created*'
            Test-Path -LiteralPath (Join-Path $f.Repo '.claude\worktrees\T-8002') | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $f.BriefDir 'read-first') | Should -BeFalse
            (Get-CallLines $f).Count |
                Should -Be 0 -Because 'no worker is spawned for a brief that ignored the index'
        }

        # The refusal is the Hand's instruction sheet: which project, where its index is, and both
        # ways past it. A refusal that only says no is one the reader has to go and research.
        It 'names the project, its index and both ways past it' {
            Set-AgentStartState
            $f = New-DispatchFixture 'index-message'
            Register-FixtureProject -Fixture $f -Project 'acme-web' -WithIndex | Out-Null
            Set-ReadFirstBrief -Fixture $f -Body @('- Nothing beyond this brief.')

            $err = { Invoke-Dispatch -Fixture $f -Name 'T-8003' } | Should -Throw -PassThru
            $msg = $err.Exception.Message
            $msg | Should -BeLike '*acme-web*'
            $msg.Contains((Join-Path $f.DataPath 'index\acme-web.md')) |
                Should -BeTrue -Because 'the Hand has to be told where to look'
            $msg | Should -BeLike '*-ReadPath*'
            $msg | Should -BeLike '*checked and nothing in it applies*'
        }

        It 'dispatches an indexed project when a file is passed to -ReadPath' {
            Set-AgentStartState
            $f = New-DispatchFixture 'index-readpath'
            Register-FixtureProject -Fixture $f -WithIndex | Out-Null
            $one = Join-Path $f.DataPath 'brand.md'
            Set-Content -Path $one -Value 'teal, not amber' -Encoding utf8
            Set-ReadFirstBrief -Fixture $f -Leaf 'brand.md' -From $one

            $r = & $script:DispatchScript -RepoPath $f.Repo -Name 'T-8004' `
                -BriefPath $f.BriefPath -DataPath $f.DataPath -ReadPath $one
            $r.id | Should -Be 'T-8004'
            Test-Path -LiteralPath (Join-Path $f.BriefDir 'read-first\brand.md') | Should -BeTrue
        }

        # muster hands data\done-<project>.md to -ReadPath on every brief for a project that has
        # one, so counting it here would retire this refusal the moment the first criteria file is
        # written - the gate would be open for exactly the projects furthest along. The evidence it
        # asks for is that the Hand went through the index for THIS task, and a path passed by rote
        # on every dispatch is none.
        It 'refuses an indexed project whose only -ReadPath is the standing-criteria file' {
            Set-AgentStartState
            $f = New-DispatchFixture 'index-criteria-only'
            $name = Register-FixtureProject -Fixture $f -WithIndex
            $criteria = Join-Path $f.DataPath "done-$name.md"
            Set-Content -Path $criteria -Value '- Every new prose rule is pinned by a test.' -Encoding utf8
            Set-ReadFirstBrief -Fixture $f -Leaf "done-$name.md" -From $criteria

            { & $script:DispatchScript -RepoPath $f.Repo -Name 'T-8021' `
                -BriefPath $f.BriefPath -DataPath $f.DataPath -ReadPath $criteria } |
                Should -Throw '*neither names a file from them to read*'
        }

        # And the refusal says which path it discounted, because otherwise the Hand reads a message
        # denying it named any file while looking at the one it just passed.
        It 'names the standing-criteria file it discounted' {
            Set-AgentStartState
            $f = New-DispatchFixture 'index-criteria-message'
            $name = Register-FixtureProject -Fixture $f -WithIndex
            $criteria = Join-Path $f.DataPath "done-$name.md"
            Set-Content -Path $criteria -Value '- Every new prose rule is pinned by a test.' -Encoding utf8
            Set-ReadFirstBrief -Fixture $f -Leaf "done-$name.md" -From $criteria

            $msg = ''
            try {
                & $script:DispatchScript -RepoPath $f.Repo -Name 'T-8022' `
                    -BriefPath $f.BriefPath -DataPath $f.DataPath -ReadPath $criteria
            } catch { $msg = $_.Exception.Message }
            $msg | Should -BeLike "*$criteria*"
            $msg | Should -BeLike '*every brief for this project passes*'
        }

        # The refusal is the Hand's instruction sheet, so the line it recommends has to be one the
        # Hand is allowed to write. In this branch the section already hands the worker the criteria
        # copy, and the literal line would say there is nothing beyond the brief in the same breath -
        # the contradiction muster rules out. So this branch recommends muster's paraphrase, and
        # the test above proves the gate takes it.
        It 'recommends the paraphrase rather than the contradicting literal line' {
            Set-AgentStartState
            $f = New-DispatchFixture 'index-criteria-recommends'
            $name = Register-FixtureProject -Fixture $f -WithIndex
            $criteria = Join-Path $f.DataPath "done-$name.md"
            Set-Content -Path $criteria -Value '- Every new prose rule is pinned by a test.' -Encoding utf8
            Set-ReadFirstBrief -Fixture $f -Leaf "done-$name.md" -From $criteria

            $msg = ''
            try {
                & $script:DispatchScript -RepoPath $f.Repo -Name 'T-8025' `
                    -BriefPath $f.BriefPath -DataPath $f.DataPath -ReadPath $criteria
            } catch { $msg = $_.Exception.Message }
            $msg | Should -BeLike ('*The index was checked; nothing in it applies to this task ' +
                                   'beyond the standing criteria above.*')
            $msg | Should -Not -BeLike '*Nothing beyond this brief - the index was checked*'
        }

        # And the ordinary case keeps the literal line, which is true there: the section names no
        # file at all, so nothing in it contradicts saying there is nothing beyond the brief.
        It 'still recommends the literal line where no path was passed at all' {
            Set-AgentStartState
            $f = New-DispatchFixture 'index-no-path-recommends'
            Register-FixtureProject -Fixture $f -WithIndex | Out-Null
            Set-ReadFirstBrief -Fixture $f -Body @('- Nothing beyond this brief.')

            $msg = ''
            try {
                & $script:DispatchScript -RepoPath $f.Repo -Name 'T-8026' `
                    -BriefPath $f.BriefPath -DataPath $f.DataPath
            } catch { $msg = $_.Exception.Message }
            $msg | Should -BeLike '*Nothing beyond this brief - the index was checked and nothing in it applies.*'
        }

        # The way past the discount that muster actually tells the Hand to write. The literal line
        # the refusal quotes would say there is nothing beyond the brief while the bullet above it
        # hands the worker a file, so muster names this paraphrase instead - and a paraphrase is
        # only usable if the gate really takes it, which is what this runs.
        It 'accepts the paraphrase muster gives for the criteria-only case' {
            Set-AgentStartState
            $f = New-DispatchFixture 'index-criteria-paraphrase'
            $name = Register-FixtureProject -Fixture $f -WithIndex
            $criteria = Join-Path $f.DataPath "done-$name.md"
            Set-Content -Path $criteria -Value '- Every new prose rule is pinned by a test.' -Encoding utf8
            Set-ReadFirstBrief -Fixture $f -Body @(
                "- ``$($f.BriefDir)\read-first\done-$name.md`` - the standing criteria, copied here from ``$criteria``.",
                '- The index was checked; nothing in it applies to this task beyond the standing criteria above.')

            $r = & $script:DispatchScript -RepoPath $f.Repo -Name 'T-8024' `
                -BriefPath $f.BriefPath -DataPath $f.DataPath -ReadPath $criteria
            $r.id | Should -Be 'T-8024'
            Test-Path -LiteralPath (Join-Path $f.BriefDir "read-first\done-$name.md") | Should -BeTrue
        }

        # The discount is exactly one file. Any other path the Hand chose is the engagement this
        # gate asks for, and it still opens the gate when the criteria file rides along beside it.
        It 'dispatches when another file is passed alongside the standing-criteria file' {
            Set-AgentStartState
            $f = New-DispatchFixture 'index-criteria-plus'
            $name = Register-FixtureProject -Fixture $f -WithIndex
            $criteria = Join-Path $f.DataPath "done-$name.md"
            Set-Content -Path $criteria -Value '- Every new prose rule is pinned by a test.' -Encoding utf8
            $brand = Join-Path $f.DataPath 'brand.md'
            Set-Content -Path $brand -Value 'teal, not amber' -Encoding utf8
            Set-ReadFirstBrief -Fixture $f -Leaf @("done-$name.md", 'brand.md') -From $brand

            $r = & $script:DispatchScript -RepoPath $f.Repo -Name 'T-8023' `
                -BriefPath $f.BriefPath -DataPath $f.DataPath -ReadPath @($criteria, $brand)
            $r.id | Should -Be 'T-8023'
            Test-Path -LiteralPath (Join-Path $f.BriefDir 'read-first\brand.md') | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $f.BriefDir "read-first\done-$name.md") | Should -BeTrue
        }

        # The browser procedure and its module are the other paths passed by rote: muster hands
        # both over on every brief carrying browser checks, because a worker reaches its worktree
        # and the brief's directory and nowhere else. Counting them would open this gate on
        # exactly those briefs, which is the failure the criteria discount already exists to
        # prevent - and each clause has to stand on its own, since either can be the first written.
        It 'refuses an indexed project whose only -ReadPath is the browser pair' {
            Set-AgentStartState
            $f = New-DispatchFixture 'index-procedure-only'
            Register-FixtureProject -Fixture $f -WithIndex | Out-Null
            Set-ReadFirstBrief -Fixture $f -Leaf @('SKILL.md', 'BrowserVerify.psm1') `
                -From $script:ProcedureFile -BrowserChecks

            $msg = ''
            try {
                & $script:DispatchScript -RepoPath $f.Repo -Name 'T-8028' `
                    -BriefPath $f.BriefPath -DataPath $f.DataPath -ReadPath $script:BrowserFiles
            } catch { $msg = $_.Exception.Message }
            $msg | Should -BeLike '*neither names a file from them to read*'
            $msg | Should -BeLike '*browser procedure*' -Because 'the refusal says what it discounted'
            $msg | Should -BeLike '*browser module*'
            $msg | Should -BeLike '*The only files this brief passes are*'
            $msg | Should -Not -BeLike '*for the same reason*' -Because 'no criteria sentence precedes it'
        }

        It 'dispatches when a file this task touches is passed beside the browser pair' {
            Set-AgentStartState
            $f = New-DispatchFixture 'index-procedure-plus'
            Register-FixtureProject -Fixture $f -WithIndex | Out-Null
            $brand = Join-Path $f.DataPath 'brand.md'
            Set-Content -Path $brand -Value 'teal, not amber' -Encoding utf8
            Set-ReadFirstBrief -Fixture $f -Leaf @('SKILL.md', 'BrowserVerify.psm1', 'brand.md') `
                -From $brand -BrowserChecks

            $r = & $script:DispatchScript -RepoPath $f.Repo -Name 'T-8029' `
                -BriefPath $f.BriefPath -DataPath $f.DataPath `
                -ReadPath (@($script:BrowserFiles) + $brand)
            $r.id | Should -Be 'T-8029'
            Test-Path -LiteralPath (Join-Path $f.BriefDir 'read-first\SKILL.md') | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $f.BriefDir 'read-first\BrowserVerify.psm1') | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $f.BriefDir 'read-first\brand.md') | Should -BeTrue
        }

        # The discount is about a file passed by rote, and it is only by rote where the brief asked
        # for browser checks. A kingshand task to change that procedure passes it because it IS the
        # subject, so it engages the gate like any other file the Hand chose - and a refusal there
        # would have told the Hand a reason untrue of its own brief.
        It 'counts the browser procedure on a brief that asked for no browser checks' {
            Set-AgentStartState
            $f = New-DispatchFixture 'index-procedure-subject'
            Register-FixtureProject -Fixture $f -WithIndex | Out-Null
            Set-ReadFirstBrief -Fixture $f -Leaf 'SKILL.md' -From $script:ProcedureFile

            $r = & $script:DispatchScript -RepoPath $f.Repo -Name 'T-8030' `
                -BriefPath $f.BriefPath -DataPath $f.DataPath -ReadPath $script:ProcedureFile
            $r.id | Should -Be 'T-8030'
            Test-Path -LiteralPath (Join-Path $f.BriefDir 'read-first\SKILL.md') | Should -BeTrue
        }

        # A brief quoting muster's template quotes the browser section too, fence and all. That is
        # somebody else's example, not this brief asking for a browser step, so it must not switch
        # the discount on and refuse a dispatch that named a real file.
        It 'does not take a quoted browser-checks heading as this brief asking for one' {
            Set-AgentStartState
            $f = New-DispatchFixture 'index-procedure-quoted'
            Register-FixtureProject -Fixture $f -WithIndex | Out-Null
            Set-ReadFirstBrief -Fixture $f -Body @(
                "- ``$($f.BriefDir)\read-first\SKILL.md`` - the procedure, copied here.",
                '', '## Scope', 'Change the template that reads:', '',
                '```markdown', '## Browser checks', '- C-001 something', '```')

            $r = & $script:DispatchScript -RepoPath $f.Repo -Name 'T-8031' `
                -BriefPath $f.BriefPath -DataPath $f.DataPath -ReadPath $script:ProcedureFile
            $r.id | Should -Be 'T-8031'
        }

        # The section is the whole opt-in, and the copies under read-first are the only way the
        # rules and the module reach a worker: it gets its own worktree and the brief's directory
        # and nothing else. Forget either -ReadPath and the worker follows the brief to a file that
        # is not there, then drives a browser with no read-only boundary and no record format -
        # which is the failure the file delivery was added to close.
        It 'refuses a brief that asks for browser checks and hands over neither file' {
            Set-AgentStartState
            $f = New-DispatchFixture 'browser-no-procedure'
            Register-FixtureProject -Fixture $f -WithIndex | Out-Null
            $brand = Join-Path $f.DataPath 'brand.md'
            Set-Content -Path $brand -Value 'teal, not amber' -Encoding utf8
            Set-ReadFirstBrief -Fixture $f -Leaf 'brand.md' -From $brand -BrowserChecks

            $msg = ''
            try {
                & $script:DispatchScript -RepoPath $f.Repo -Name 'T-8032' `
                    -BriefPath $f.BriefPath -DataPath $f.DataPath -ReadPath $brand
            } catch { $msg = $_.Exception.Message }
            $msg | Should -BeLike '*## Browser checks*'
            $msg | Should -BeLike "*$script:ProcedureFile*" -Because 'the refusal names the path to pass'
            $msg | Should -BeLike "*$script:ModuleFile*"
            $msg | Should -BeLike '*Nothing was created*'
            Test-Path -LiteralPath (Join-Path $f.Repo '.claude\worktrees\T-8032') | Should -BeFalse
            (Get-CallLines $f).Count | Should -Be 0
        }

        # The procedure's first instruction is to import the module, so handing over one of the two
        # leaves the browser step dead one line further down than handing over neither.
        It 'refuses a browser brief that hands over the procedure but not the module' {
            Set-AgentStartState
            $f = New-DispatchFixture 'browser-no-module'
            Set-ReadFirstBrief -Fixture $f -Leaf 'SKILL.md' -From $script:ProcedureFile -BrowserChecks

            $msg = ''
            try {
                & $script:DispatchScript -RepoPath $f.Repo -Name 'T-8036' `
                    -BriefPath $f.BriefPath -DataPath $f.DataPath -ReadPath $script:ProcedureFile
            } catch { $msg = $_.Exception.Message }
            $msg | Should -BeLike '*browser module*'
            $msg | Should -BeLike "*$script:ModuleFile*"
            $msg | Should -Not -BeLike '*browser procedure*' -Because 'that one was handed over'
            Test-Path -LiteralPath (Join-Path $f.BriefDir 'read-first') | Should -BeFalse
        }

        # And it is not the index gate wearing another hat: a project with nothing indexed at all
        # still has to hand both files over.
        It 'refuses the same brief on a project with no index to check' {
            Set-AgentStartState
            $f = New-DispatchFixture 'browser-no-procedure-unindexed'
            Set-ReadFirstBrief -Fixture $f -Body @('- Nothing beyond this brief.') -BrowserChecks

            { Invoke-Dispatch -Fixture $f -Name 'T-8033' } |
                Should -Throw '*passes no -ReadPath for*'
        }

        It 'dispatches a browser brief that hands both files over' {
            Set-AgentStartState
            $f = New-DispatchFixture 'browser-with-procedure'
            Set-ReadFirstBrief -Fixture $f -Leaf @('SKILL.md', 'BrowserVerify.psm1') `
                -From $script:ProcedureFile -BrowserChecks

            $r = & $script:DispatchScript -RepoPath $f.Repo -Name 'T-8034' `
                -BriefPath $f.BriefPath -DataPath $f.DataPath -ReadPath $script:BrowserFiles
            $r.id | Should -Be 'T-8034'
            Test-Path -LiteralPath (Join-Path $f.BriefDir 'read-first\SKILL.md') | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $f.BriefDir 'read-first\BrowserVerify.psm1') |
                Should -BeTrue -Because 'the module the procedure imports travels the same way'
        }

        # Every copy is in the section, so a line saying nothing applies beyond one of them
        # contradicts the others - the same contradiction the criteria paraphrase exists to avoid.
        It 'recommends a line naming every copy that was discounted' {
            Set-AgentStartState
            $f = New-DispatchFixture 'index-both-discounted'
            $name = Register-FixtureProject -Fixture $f -WithIndex
            $criteria = Join-Path $f.DataPath "done-$name.md"
            Set-Content -Path $criteria -Value '- Every new prose rule is pinned by a test.' -Encoding utf8
            Set-ReadFirstBrief -Fixture $f `
                -Leaf @("done-$name.md", 'SKILL.md', 'BrowserVerify.psm1') -From $criteria -BrowserChecks

            $msg = ''
            try {
                & $script:DispatchScript -RepoPath $f.Repo -Name 'T-8035' `
                    -BriefPath $f.BriefPath -DataPath $f.DataPath `
                    -ReadPath (@($criteria) + $script:BrowserFiles)
            } catch { $msg = $_.Exception.Message }
            $msg | Should -BeLike ('*beyond the standing criteria, the browser procedure and the ' +
                                   'browser module above.*')
            $msg | Should -Not -BeLike '*Nothing beyond this brief - the index was checked*'
        }

        # The discount has to survive a relative -DataPath, because the two ways of rooting one
        # disagree: GetFullPath uses the PROCESS working directory, which Set-Location does not
        # move, while Index.psm1 reads its indexes from POWERSHELL's location. Rooted the first way
        # the composed done-<project>.md named a file in a directory nobody was looking at, no
        # -ReadPath matched it, and the dispatch went through on a path passed by rote with no index
        # consulted - silently, which is the exact failure the discount exists to catch.
        It 'discounts the standing-criteria file when the data directory is named relatively' {
            Set-AgentStartState
            $f = New-DispatchFixture 'index-criteria-relative'
            $name = Register-FixtureProject -Fixture $f -WithIndex
            $criteria = Join-Path $f.DataPath "done-$name.md"
            Set-Content -Path $criteria -Value '- Every new prose rule is pinned by a test.' -Encoding utf8
            Set-ReadFirstBrief -Fixture $f -Leaf "done-$name.md" -From $criteria

            $savedCwd = [System.Environment]::CurrentDirectory
            Push-Location (Split-Path $f.DataPath -Parent)
            try {
                # The divergence stated outright rather than left to whatever the test host's
                # working directory happens to be.
                [System.Environment]::CurrentDirectory = $f.Home
                { & $script:DispatchScript -RepoPath $f.Repo -Name 'T-8027' `
                    -BriefPath $f.BriefPath -DataPath 'data' -ReadPath $criteria } |
                    Should -Throw '*neither names a file from them to read*'
            } finally {
                [System.Environment]::CurrentDirectory = $savedCwd
                Pop-Location
            }
        }

        It 'dispatches an indexed project when the section says the index was checked' {
            Set-AgentStartState
            $f = New-DispatchFixture 'index-stated'
            Register-FixtureProject -Fixture $f -WithIndex | Out-Null
            Set-ReadFirstBrief -Fixture $f -Body @(
                '- Nothing beyond this brief - the index was checked and nothing in it applies.')

            (Invoke-Dispatch -Fixture $f -Name 'T-8005').id | Should -Be 'T-8005'
        }

        # A project with no index has nothing to consult, so it dispatches exactly as it did before
        # any of this existed. The gate is about an index that exists and went unread.
        It 'dispatches a registered project that has no index at all' {
            Set-AgentStartState
            $f = New-DispatchFixture 'index-none'
            Register-FixtureProject -Fixture $f | Out-Null
            Set-ReadFirstBrief -Fixture $f -Body @('- Nothing beyond this brief.')

            (Invoke-Dispatch -Fixture $f -Name 'T-8006').id | Should -Be 'T-8006'
        }

        # The distinction the whole gate rests on: a line that says the index was checked is a
        # decision somebody made, where a slot filled in with the template's own words says only
        # that the slot was filled in, and an empty one says nothing at all.
        It 'refuses an indexed project whose section is empty' {
            Set-AgentStartState
            $f = New-DispatchFixture 'index-empty-section'
            Register-FixtureProject -Fixture $f -WithIndex | Out-Null
            Set-Content -Path $f.BriefPath -Encoding utf8 -Value @(
                '# Brief', '', '## Read first', '', '## Scope', 'Do the thing.')

            { Invoke-Dispatch -Fixture $f -Name 'T-8007' } |
                Should -Throw '*neither names a file from them to read*'
        }

        # A quoted template cannot make a statement on this brief's behalf, for the same reason a
        # quoted heading does not satisfy the heading check.
        It 'does not accept the stated line from inside a fenced block' {
            Set-AgentStartState
            $f = New-DispatchFixture 'index-fenced-line'
            Register-FixtureProject -Fixture $f -WithIndex | Out-Null
            Set-Content -Path $f.BriefPath -Encoding utf8 -Value @(
                '# Brief', '', '## Read first', '- Nothing beyond this brief.', '',
                'The line muster writes when there is nothing to read is:', '', '```markdown',
                '- Nothing beyond this brief - the index was checked and nothing in it applies.',
                '```', '', '## Scope', 'Do the thing.')

            { Invoke-Dispatch -Fixture $f -Name 'T-8008' } |
                Should -Throw '*neither names a file from them to read*'
        }

        # The refusal that was already there is not weakened by the one added beside it. A brief
        # with no heading fails for every project, indexed or not, and it fails as that brief rather
        # than as an index complaint - the two say different things and both have to keep saying it.
        It 'still refuses a brief with no Read first heading when the project is indexed' {
            Set-AgentStartState
            $f = New-DispatchFixture 'index-noheading'
            Register-FixtureProject -Fixture $f -WithIndex | Out-Null
            Set-Content -Path $f.BriefPath -Encoding utf8 -Value @('# Brief', '', '## Scope', 'Do it.')

            { Invoke-Dispatch -Fixture $f -Name 'T-8009' } |
                Should -Throw "*has no '## Read first' section*"
        }

        It 'still refuses a brief with no Read first heading when nothing is indexed' {
            Set-AgentStartState
            $f = New-DispatchFixture 'index-noheading-unindexed'
            Set-Content -Path $f.BriefPath -Encoding utf8 -Value @('# Brief', '', '## Scope', 'Do it.')

            { Invoke-Dispatch -Fixture $f -Name 'T-8010' } |
                Should -Throw "*has no '## Read first' section*"
        }

        # An unregistered repo resolves to no project, so no PROJECT index applies to it - and
        # another project's index is that project's, not this dispatch's. The gate resolves the
        # project from the registry rather than taking it as an argument, precisely so a forgotten
        # argument cannot switch it off, but an unregistered repo is a posture question the Hand
        # answers, not something this script infers.
        It 'dispatches a repo no registry lists when only another project is indexed' {
            Set-AgentStartState
            $f = New-DispatchFixture 'index-unregistered'
            Register-FixtureProject -Fixture $f -Project 'someone-else' -WithIndex | Out-Null
            $f.Repo = New-TempRepo
            Set-ReadFirstBrief -Fixture $f -Body @('- Nothing beyond this brief.')

            (Invoke-Dispatch -Fixture $f -Name 'T-8011').id | Should -Be 'T-8011'
        }

        # The root index is not project-scoped, and it is where the settled files actually sit. A
        # gate that consulted only data\index\<project>.md could not fire at all on an installation
        # whose data\index\ directory does not even exist - the inert version of the failure it was
        # written for, and the reason an unregistered repo is gated here too.
        It 'refuses a repo no registry lists when the root index lists something' {
            Set-AgentStartState
            $f = New-DispatchFixture 'index-root-unregistered'
            Add-FixtureRootEntry -Fixture $f
            Set-ReadFirstBrief -Fixture $f -Body @('- Nothing beyond this brief.')

            $err = { Invoke-Dispatch -Fixture $f -Name 'T-8012' } | Should -Throw -PassThru
            $err.Exception.Message.Contains((Join-Path $f.DataPath 'index.md')) |
                Should -BeTrue -Because 'the index that triggered the refusal is the one to open'
            Test-Path -LiteralPath (Join-Path $f.Repo '.claude\worktrees\T-8012') | Should -BeFalse
        }

        It 'dispatches a repo the root index gates once the section says it was checked' {
            Set-AgentStartState
            $f = New-DispatchFixture 'index-root-stated'
            Add-FixtureRootEntry -Fixture $f
            Set-ReadFirstBrief -Fixture $f -Body @(
                '- Nothing beyond this brief - the index was checked and nothing in it applies.')

            (Invoke-Dispatch -Fixture $f -Name 'T-8013').id | Should -Be 'T-8013'
        }

        # Every index that triggered the refusal is named with its path, because the Hand has to
        # open each one. Naming only the first would leave the other unread on the next attempt.
        It 'names both indexes when both list something' {
            Set-AgentStartState
            $f = New-DispatchFixture 'index-both'
            Register-FixtureProject -Fixture $f -Project 'acme-web' -WithIndex | Out-Null
            Add-FixtureRootEntry -Fixture $f -Leaf 'learnings.md'
            Set-ReadFirstBrief -Fixture $f -Body @('- Nothing beyond this brief.')

            $err = { Invoke-Dispatch -Fixture $f -Name 'T-8014' } | Should -Throw -PassThru
            $msg = $err.Exception.Message
            $msg.Contains((Join-Path $f.DataPath 'index.md'))            | Should -BeTrue
            $msg.Contains((Join-Path $f.DataPath 'index\acme-web.md'))   | Should -BeTrue
        }

        # The one case where "no index to check" is actually true, and the only one that leaves a
        # dispatch untouched.
        It 'dispatches untouched when nothing is indexed anywhere' {
            Set-AgentStartState
            $f = New-DispatchFixture 'index-nothing-anywhere'
            Register-FixtureProject -Fixture $f | Out-Null
            Set-ReadFirstBrief -Fixture $f -Body @('- Nothing beyond this brief.')

            Test-Path -LiteralPath (Join-Path $f.DataPath 'index.md')   | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $f.DataPath 'index')      | Should -BeFalse
            (Invoke-Dispatch -Fixture $f -Name 'T-8015').id | Should -Be 'T-8015'
        }

        # The registry is maintained by hand as well as by /annex, so a `path:` line with no value
        # gets through the parser as a single space - truthy, and an argument GetFullPath throws on.
        # Resolution used to be wrapped whole, so that one line abandoned every project at once and
        # turned the gate off in silence: a fail-open with no signal, in the check that exists to
        # stop one. The bad entry is registered FIRST, so the project below it is what proves the
        # loop carried on.
        It 'still gates a project listed after a registry entry whose path is unusable' {
            Set-AgentStartState
            $f = New-DispatchFixture 'index-badpath'
            Add-ProjectEntry -Name 'hand-edited' -Path ' ' -Mode 'local-only' `
                -Description 'a path: line with no value' `
                -RegistryPath (Join-Path $f.DataPath 'projects.md')
            Register-FixtureProject -Fixture $f -Project 'acme-web' -WithIndex | Out-Null
            Set-ReadFirstBrief -Fixture $f -Body @('- Nothing beyond this brief.')

            { Invoke-Dispatch -Fixture $f -Name 'T-8016' -WarningAction SilentlyContinue } |
                Should -Throw '*acme-web*'
        }

        # The escape hatch is a statement, not a coincidence of vocabulary. A brief for a
        # search-index task writes "index" and "nothing" in one ordinary sentence about scope and
        # has said nothing at all about consulting anything - so the line has to name what was DONE
        # to the index as well, or the gate switches itself off on the very class of task most
        # likely to use the word, silently and with no error.
        It 'refuses a line that merely mentions an index and the word nothing' {
            Set-AgentStartState
            $f = New-DispatchFixture 'index-loose-words'
            Register-FixtureProject -Fixture $f -WithIndex | Out-Null
            Set-ReadFirstBrief -Fixture $f -Body @(
                '- The search index rebuild is out of scope; change nothing about it.')

            { Invoke-Dispatch -Fixture $f -Name 'T-8018' } |
                Should -Throw '*neither names a file from them to read*'
        }

        # Tightened, not narrowed to one sentence. The Hand states the decision in its own words as
        # long as the words say the index was opened and turned up nothing.
        It 'accepts a line that says in other words that the index was read' {
            Set-AgentStartState
            $f = New-DispatchFixture 'index-paraphrase'
            Register-FixtureProject -Fixture $f -WithIndex | Out-Null
            Set-ReadFirstBrief -Fixture $f -Body @(
                '- I read the index and none of it touches this task.')

            (Invoke-Dispatch -Fixture $f -Name 'T-8019').id | Should -Be 'T-8019'
        }

        # `index` inside a hyphenated compound is a different noun, not a mention of the index. The
        # word boundary in `\bindex\b` sits at the hyphen, so this sentence - an ordinary scope note
        # on a search-index task, with `read` supplied by the section's own title - satisfied all
        # three conditions and dispatched without the index ever being opened.
        It 'refuses a line whose only index is inside a hyphenated compound' {
            Set-AgentStartState
            $f = New-DispatchFixture 'index-hyphenated'
            Register-FixtureProject -Fixture $f -WithIndex | Out-Null
            Set-ReadFirstBrief -Fixture $f -Body @(
                '- Nothing in the search-index module changes; read only the API layer.')

            { Invoke-Dispatch -Fixture $f -Name 'T-8020' } |
                Should -Throw '*neither names a file from them to read*'
        }

        # The plural is what the Hand actually writes, because muster sends it to two indexes.
        It 'accepts a line that says both indexes were checked' {
            Set-AgentStartState
            $f = New-DispatchFixture 'index-plural'
            Register-FixtureProject -Fixture $f -WithIndex | Out-Null
            Add-FixtureRootEntry -Fixture $f
            Set-ReadFirstBrief -Fixture $f -Body @(
                '- Nothing beyond this brief - both indexes were checked and none apply.')

            (Invoke-Dispatch -Fixture $f -Name 'T-8021').id | Should -Be 'T-8021'
        }

        It 'accepts a line that says the index was reviewed' {
            Set-AgentStartState
            $f = New-DispatchFixture 'index-reviewed'
            Register-FixtureProject -Fixture $f -WithIndex | Out-Null
            Set-ReadFirstBrief -Fixture $f -Body @(
                '- Nothing beyond this brief - the index was reviewed and nothing in it applies.')

            (Invoke-Dispatch -Fixture $f -Name 'T-8022').id | Should -Be 'T-8022'
        }

        It 'warns rather than skipping a registry entry it cannot use in silence' {
            Set-AgentStartState
            $f = New-DispatchFixture 'index-badpath-warn'
            Add-ProjectEntry -Name 'hand-edited' -Path ' ' -Mode 'local-only' `
                -Description 'a path: line with no value' `
                -RegistryPath (Join-Path $f.DataPath 'projects.md')
            Register-FixtureProject -Fixture $f | Out-Null
            Set-ReadFirstBrief -Fixture $f -Body @('- Nothing beyond this brief.')

            $r = & $script:DispatchScript -RepoPath $f.Repo -Name 'T-8017' `
                -BriefPath $f.BriefPath -DataPath $f.DataPath `
                -WarningVariable warned -WarningAction SilentlyContinue
            $r.id | Should -Be 'T-8017'
            (@($warned) -join ' ') | Should -BeLike '*hand-edited*'
        }
    }

    # The project's own two standing files, delivered without anyone passing them.
    #
    # Delivery by memory has already failed once on this installation: a settled brand spec sat in
    # data\ naming itself the input to the website brief while the site shipped without its logo,
    # favicon, tagline or palette, because no brief named the file. A per-project file is that
    # failure with a shorter fuse, because it applies to every task in the project rather than one.
    Context "the project's own standing files" {
        BeforeAll {
            # A standing file at the fixture's own data root, under the name the project resolved to.
            function New-StandingFile {
                param(
                    [Parameter(Mandatory)]$Fixture,
                    [Parameter(Mandatory)][string]$Leaf,
                    [string]$Text = 'Tickets are tagged NG-, capital N capital G. Never touch legacy\.'
                )
                $p = Join-Path $Fixture.DataPath $Leaf
                Set-Content -LiteralPath $p -Value $Text -Encoding utf8
                $p
            }

            function Get-BriefText {
                param([Parameter(Mandatory)]$Fixture)
                Get-Content -LiteralPath $Fixture.BriefPath -Raw
            }

            # The whole documented order in one reading, so an ordering test cannot pass on a partial
            # one: the heading, then the lead-in that scopes the bullets, then the criteria file,
            # then the rules file - the order $standing composes and every dispatch file carries.
            function Get-ReadFirstOrder {
                param([Parameter(Mandatory)]$Fixture, [Parameter(Mandatory)][string]$Project)
                $lines = @(Get-Content -LiteralPath (Get-DispatchFilePath $Fixture))
                $mark  = '*attached by dispatch from this project*'
                $at    = {
                    param($pattern)
                    @(0..($lines.Count - 1) | Where-Object { $lines[$_] -like $pattern })[0]
                }
                [pscustomobject]@{
                    Lines    = $lines
                    Heading  = @(0..($lines.Count - 1) |
                                    Where-Object { $lines[$_] -match '^\s*##\s+Read first\s*$' })[0]
                    LeadIn   = & $at $mark
                    Criteria = & $at "*read-first\done-$Project.md*"
                    Rules    = & $at "*read-first\rules-$Project.md*"
                    LeadIns  = @($lines | Where-Object { $_ -like $mark }).Count
                }
            }
        }

        It 'attaches the rules file nobody passed, where the worker can reach it' {
            Set-AgentStartState
            $f = New-DispatchFixture 'standing-rules'
            $name = Register-FixtureProject -Fixture $f
            New-StandingFile -Fixture $f -Leaf "rules-$name.md" | Out-Null
            Set-ReadFirstBrief -Fixture $f -Body @('- Nothing beyond this brief.')

            (Invoke-Dispatch -Fixture $f -Name 'T-9001').id | Should -Be 'T-9001'
            $copy = Join-Path $f.BriefDir "read-first\rules-$name.md"
            Test-Path -LiteralPath $copy | Should -BeTrue
            (Get-Content -LiteralPath $copy -Raw) | Should -BeLike '*NG-*'
        }

        # Staging alone is the original failure with an extra step: a worker reads what it is told
        # to read and nothing else, so a copy no line names reaches it not at all. The line is in
        # the dispatch file, and the start prompt names that file beside the brief.
        It 'names the attached copy in the dispatch file, under Read first' {
            Set-AgentStartState
            $f = New-DispatchFixture 'standing-named'
            $name = Register-FixtureProject -Fixture $f
            New-StandingFile -Fixture $f -Leaf "rules-$name.md" | Out-Null
            Set-ReadFirstBrief -Fixture $f -Body @('- Nothing beyond this brief.')

            Invoke-Dispatch -Fixture $f -Name 'T-9002' | Out-Null
            $text = Get-DispatchText -Fixture $f
            $text.Contains((Join-Path $f.BriefDir "read-first\rules-$name.md")) | Should -BeTrue
            $text | Should -BeLike '*attached automatically at dispatch*'
        }

        # The line sits under a Read first heading, so it is inside a section a worker is told to
        # work through rather than loose in the file.
        It 'puts the line under the dispatch file''s own Read first heading' {
            Set-AgentStartState
            $f = New-DispatchFixture 'standing-position'
            $name = Register-FixtureProject -Fixture $f
            New-StandingFile -Fixture $f -Leaf "rules-$name.md" | Out-Null
            Set-ReadFirstBrief -Fixture $f -Body @('- Nothing beyond this brief.')

            Invoke-Dispatch -Fixture $f -Name 'T-9003' | Out-Null
            $lines   = @(Get-Content -LiteralPath (Get-DispatchFilePath $f))
            $heading = @(0..($lines.Count - 1) | Where-Object { $lines[$_] -match '^\s*##\s+Read first\s*$' })[0]
            $named   = @(0..($lines.Count - 1) | Where-Object { $lines[$_] -like '*read-first\rules-*' })[0]
            ($null -ne $heading) | Should -BeTrue
            ($named -gt $heading) | Should -BeTrue
            @($lines[$heading..$named] | Where-Object { $_ -match '^\s*#{1,6}\s' }).Count |
                Should -Be 1 -Because 'no other heading falls between the section and its line'
        }

        # THE BRIEF IS NEVER EDITED. Every line dispatch adds goes beside it, because an edit to the
        # file the Hand just wrote is handed back into the Hand's own context on every dispatch.
        It 'leaves the brief byte for byte as the Hand wrote it' {
            Set-AgentStartState
            $f = New-DispatchFixture 'standing-brief-untouched'
            $name = Register-FixtureProject -Fixture $f
            New-StandingFile -Fixture $f -Leaf "done-$name.md" -Text '- Pester is green.' | Out-Null
            New-StandingFile -Fixture $f -Leaf "rules-$name.md" | Out-Null
            Set-ReadFirstBrief -Fixture $f -Body @('- Nothing beyond this brief.')
            $before = [System.IO.File]::ReadAllBytes($f.BriefPath)

            Invoke-Dispatch -Fixture $f -Name 'T-9035' | Out-Null
            [System.IO.File]::ReadAllBytes($f.BriefPath) | Should -Be $before
            (Get-DispatchText -Fixture $f).Contains("read-first\rules-$name.md") | Should -BeTrue
        }

        # The worker is told about the file by the one thing it is certain to read first. Nothing
        # in the brief names it, so a prompt that left it out would hand the worker none of it.
        It 'names the dispatch file in the worker''s start prompt, beside the brief' {
            Set-AgentStartState
            $f = New-DispatchFixture 'standing-prompt-names'
            $name = Register-FixtureProject -Fixture $f
            New-StandingFile -Fixture $f -Leaf "rules-$name.md" | Out-Null
            Set-ReadFirstBrief -Fixture $f -Body @('- Nothing beyond this brief.')

            Invoke-Dispatch -Fixture $f -Name 'T-9036' | Out-Null
            $prompt = @(Get-CallLines $f | Where-Object { $_ -like 'agent prompt*' })
            $prompt.Count | Should -Be 1
            $prompt[0] | Should -BeLike "*$($f.BriefPath)*"
            $prompt[0] | Should -BeLike "*$(Get-DispatchFilePath $f)*"
        }

        It 'names no dispatch file in the prompt when it wrote none' {
            Set-AgentStartState
            $f = New-DispatchFixture 'standing-prompt-plain'
            Register-FixtureProject -Fixture $f | Out-Null
            Set-ReadFirstBrief -Fixture $f -Body @('- Nothing beyond this brief.')

            Invoke-Dispatch -Fixture $f -Name 'T-9037' | Out-Null
            Test-Path -LiteralPath (Get-DispatchFilePath $f) | Should -BeFalse
            $prompt = @(Get-CallLines $f | Where-Object { $_ -like 'agent prompt*' })
            $prompt[0] | Should -Not -BeLike '*.dispatch.md*'
        }

        # The path is this script's own only when its first line says so. A file somebody else put
        # there is refused rather than overwritten, with nothing created.
        It 'refuses a file at the dispatch path that dispatch did not write' {
            Set-AgentStartState
            $f = New-DispatchFixture 'standing-foreign-dispatch-file'
            $name = Register-FixtureProject -Fixture $f
            New-StandingFile -Fixture $f -Leaf "rules-$name.md" | Out-Null
            Set-ReadFirstBrief -Fixture $f -Body @('- Nothing beyond this brief.')
            $foreign = Get-DispatchFilePath $f
            Set-Content -LiteralPath $foreign -Value '# My own notes' -Encoding utf8

            { Invoke-Dispatch -Fixture $f -Name 'T-9038' } | Should -Throw '*dispatch did not write*'
            (Get-Content -LiteralPath $foreign -Raw).Trim() | Should -Be '# My own notes'
            Test-Path -LiteralPath (Join-Path $f.BriefDir 'read-first') | Should -BeFalse
            @(Get-CallLines -Fixture $f) | Should -BeNullOrEmpty
        }

        # A file it cannot read is refused too, because whether it is this script's own cannot be
        # told - and guessing either way either overwrites somebody's file or leaves a stale one.
        It 'refuses a dispatch file it cannot read, with nothing created' {
            Set-AgentStartState
            $f = New-DispatchFixture 'standing-unreadable-dispatch-file'
            $name = Register-FixtureProject -Fixture $f
            New-StandingFile -Fixture $f -Leaf "rules-$name.md" | Out-Null
            Set-ReadFirstBrief -Fixture $f -Body @('- Nothing beyond this brief.')
            Set-Content -LiteralPath (Get-DispatchFilePath $f) -Value 'x' -Encoding utf8

            $held = [System.IO.File]::Open((Get-DispatchFilePath $f), 'Open', 'Read', 'None')
            try {
                { Invoke-Dispatch -Fixture $f -Name 'T-9039' } | Should -Throw '*could not be read*'
            } finally { $held.Dispose() }
            Test-Path -LiteralPath (Join-Path $f.BriefDir 'read-first') | Should -BeFalse
        }

        It 'attaches the standing-criteria file the same way when nobody passed that either' {
            Set-AgentStartState
            $f = New-DispatchFixture 'standing-criteria-auto'
            $name = Register-FixtureProject -Fixture $f
            New-StandingFile -Fixture $f -Leaf "done-$name.md" -Text '- Pester is green.' | Out-Null
            Set-ReadFirstBrief -Fixture $f -Body @('- Nothing beyond this brief.')

            Invoke-Dispatch -Fixture $f -Name 'T-9004' | Out-Null
            Test-Path -LiteralPath (Join-Path $f.BriefDir "read-first\done-$name.md") | Should -BeTrue
            (Get-DispatchText -Fixture $f).Contains("read-first\done-$name.md") | Should -BeTrue
        }

        It 'attaches both when both are there, and neither lands on the other' {
            Set-AgentStartState
            $f = New-DispatchFixture 'standing-both'
            $name = Register-FixtureProject -Fixture $f
            New-StandingFile -Fixture $f -Leaf "done-$name.md"  -Text '- Pester is green.' | Out-Null
            New-StandingFile -Fixture $f -Leaf "rules-$name.md" -Text 'Tag NG-, never legacy\.' | Out-Null
            Set-ReadFirstBrief -Fixture $f -Body @('- Nothing beyond this brief.')

            Invoke-Dispatch -Fixture $f -Name 'T-9005' | Out-Null
            (Get-Content -LiteralPath (Join-Path $f.BriefDir "read-first\done-$name.md")  -Raw) |
                Should -BeLike '*Pester is green*'
            (Get-Content -LiteralPath (Join-Path $f.BriefDir "read-first\rules-$name.md") -Raw) |
                Should -BeLike '*Tag NG-*'
        }

        # A project with neither file dispatches exactly as it did before either existed.
        It 'attaches nothing and stages no directory for a project with neither file' {
            Set-AgentStartState
            $f = New-DispatchFixture 'standing-neither'
            Register-FixtureProject -Fixture $f | Out-Null
            Set-ReadFirstBrief -Fixture $f -Body @('- Nothing beyond this brief.')
            $before = Get-BriefText -Fixture $f

            (Invoke-Dispatch -Fixture $f -Name 'T-9006').id | Should -Be 'T-9006'
            Test-Path -LiteralPath (Join-Path $f.BriefDir 'read-first') | Should -BeFalse
            Test-Path -LiteralPath (Get-DispatchFilePath $f) | Should -BeFalse
            (Get-BriefText -Fixture $f) | Should -Be $before
        }

        # Posture is read, never inferred, and neither is a project. A repo the registry has never
        # heard of resolves to no project, so there is no name to compose either file from.
        It 'attaches nothing for a repo no registry lists, even when a rules file is there' {
            Set-AgentStartState
            $f = New-DispatchFixture 'standing-unregistered'
            New-StandingFile -Fixture $f -Leaf 'rules-acme-web.md' | Out-Null
            Set-ReadFirstBrief -Fixture $f -Body @('- Nothing beyond this brief.')

            (Invoke-Dispatch -Fixture $f -Name 'T-9007').id | Should -Be 'T-9007'
            Test-Path -LiteralPath (Join-Path $f.BriefDir 'read-first') | Should -BeFalse
        }

        # The gate's premise is that a -ReadPath is evidence the Hand went through the index for
        # THIS task. A file that arrives on every dispatch is no evidence, and one that arrives
        # without anyone passing it is less than none - a gate every dispatch satisfies by rote
        # refuses nothing, ever.
        It 'does not let the attached rules file satisfy the index gate' {
            Set-AgentStartState
            $f = New-DispatchFixture 'standing-not-engagement'
            $name = Register-FixtureProject -Fixture $f -WithIndex
            New-StandingFile -Fixture $f -Leaf "rules-$name.md" | Out-Null
            Set-ReadFirstBrief -Fixture $f -Body @('- Nothing beyond this brief.')

            { Invoke-Dispatch -Fixture $f -Name 'T-9008' } |
                Should -Throw '*neither names a file from them to read*'
        }

        It 'says in that refusal which standing files it is attaching by itself' {
            Set-AgentStartState
            $f = New-DispatchFixture 'standing-refusal-names'
            $name = Register-FixtureProject -Fixture $f -WithIndex
            New-StandingFile -Fixture $f -Leaf "rules-$name.md" | Out-Null
            Set-ReadFirstBrief -Fixture $f -Body @('- Nothing beyond this brief.')

            $msg = ''
            try { Invoke-Dispatch -Fixture $f -Name 'T-9009' } catch { $msg = $_.Exception.Message }
            $msg | Should -BeLike "*rules-$name.md*"
            $msg | Should -BeLike '*say nothing about this task either*'
        }

        # The two standing-file cases part company in what the refusal tells the Hand to write.
        # Where dispatch attaches the file ITSELF, the lead-in it inserts scopes the bullet, so the
        # canonical short line is true and is what gets recommended.
        It 'recommends the short literal line when it attaches the standing file itself' {
            Set-AgentStartState
            $f = New-DispatchFixture 'standing-recommends-literal'
            $name = Register-FixtureProject -Fixture $f -WithIndex
            New-StandingFile -Fixture $f -Leaf "rules-$name.md" | Out-Null
            Set-ReadFirstBrief -Fixture $f -Body @('- Something the index never mentioned.')

            $msg = ''
            try { Invoke-Dispatch -Fixture $f -Name 'T-9025' } catch { $msg = $_.Exception.Message }
            $msg | Should -BeLike "*'- Nothing beyond this brief - the index was checked and nothing in it applies.'*"
            $msg | Should -Not -BeLike '*beyond the standing criteria above*'
        }

        # Where the Hand PASSED the file, the line naming it is the Hand's own and no lead-in scopes
        # it, so the short line would still contradict the section. That branch keeps the paraphrase.
        It 'still recommends the paraphrase when the Hand passed the standing file itself' {
            Set-AgentStartState
            $f = New-DispatchFixture 'standing-recommends-paraphrase'
            $name = Register-FixtureProject -Fixture $f -WithIndex
            $criteria = New-StandingFile -Fixture $f -Leaf "done-$name.md" -Text '- Pester is green.'
            Set-ReadFirstBrief -Fixture $f -Body @(
                "- ``$($f.BriefDir)\read-first\done-$name.md`` - the standing criteria, copied from ``$criteria``.")

            $msg = ''
            try {
                & $script:DispatchScript -RepoPath $f.Repo -Name 'T-9026' `
                    -BriefPath $f.BriefPath -DataPath $f.DataPath -ReadPath $criteria
            } catch { $msg = $_.Exception.Message }
            $msg | Should -BeLike '*beyond the standing criteria above*'
        }

        # A file that is there and cannot be read is not an absent one, and the difference decides
        # whether a worker ships without the project's standing rules leaving no trace it happened.
        It 'refuses a rules file that is there and cannot be opened' {
            Set-AgentStartState
            $f = New-DispatchFixture 'standing-unreadable'
            $name = Register-FixtureProject -Fixture $f
            $rules = New-StandingFile -Fixture $f -Leaf "rules-$name.md"
            Set-ReadFirstBrief -Fixture $f -Body @('- Nothing beyond this brief.')

            $held = [System.IO.File]::Open($rules, 'Open', 'Read', 'None')
            try {
                { Invoke-Dispatch -Fixture $f -Name 'T-9010' } |
                    Should -Throw '*exists and could not be opened*'
            } finally { $held.Dispose() }
        }

        It 'creates nothing when it refuses over a rules file it cannot open' {
            Set-AgentStartState
            $f = New-DispatchFixture 'standing-unreadable-clean'
            $name = Register-FixtureProject -Fixture $f
            $rules = New-StandingFile -Fixture $f -Leaf "rules-$name.md"
            Set-ReadFirstBrief -Fixture $f -Body @('- Nothing beyond this brief.')
            $before = Get-BriefText -Fixture $f

            $held = [System.IO.File]::Open($rules, 'Open', 'Read', 'None')
            try {
                try { Invoke-Dispatch -Fixture $f -Name 'T-9011' } catch { }
            } finally { $held.Dispose() }

            Test-Path -LiteralPath (Join-Path $f.BriefDir 'read-first') | Should -BeFalse
            (Get-BriefText -Fixture $f) | Should -Be $before
            @(Get-CallLines -Fixture $f) | Should -BeNullOrEmpty
        }

        It 'refuses a directory sitting where the rules file belongs' {
            Set-AgentStartState
            $f = New-DispatchFixture 'standing-directory'
            $name = Register-FixtureProject -Fixture $f
            New-Item -ItemType Directory -Force -Path (Join-Path $f.DataPath "rules-$name.md") | Out-Null
            Set-ReadFirstBrief -Fixture $f -Body @('- Nothing beyond this brief.')

            { Invoke-Dispatch -Fixture $f -Name 'T-9012' } | Should -Throw '*is a directory*'
        }

        # Two files with one name would land on top of each other in the staging directory, and the
        # worker would read whichever was copied last with no sign the other ever existed.
        It 'refuses a -ReadPath whose name collides with the project rules file' {
            Set-AgentStartState
            $f = New-DispatchFixture 'standing-collision'
            $name = Register-FixtureProject -Fixture $f
            New-StandingFile -Fixture $f -Leaf "rules-$name.md" | Out-Null
            $elsewhere = Join-Path $f.Home "rules-$name.md"
            Set-Content -LiteralPath $elsewhere -Value 'a different file with the same name' -Encoding utf8
            Set-ReadFirstBrief -Fixture $f -Leaf "rules-$name.md" -From $elsewhere

            { & $script:DispatchScript -RepoPath $f.Repo -Name 'T-9013' `
                -BriefPath $f.BriefPath -DataPath $f.DataPath -ReadPath $elsewhere } |
                Should -Throw '*would land on*'
        }

        # The Hand passing the project's own file by hand is the muster contract for the criteria
        # file, and it must not produce a second line naming the copy the Hand already named.
        It 'writes no line for a standing file the brief passed itself' {
            Set-AgentStartState
            $f = New-DispatchFixture 'standing-passed-by-hand'
            $name = Register-FixtureProject -Fixture $f
            $criteria = New-StandingFile -Fixture $f -Leaf "done-$name.md" -Text '- Pester is green.'
            Set-ReadFirstBrief -Fixture $f -Body @(
                "- ``$($f.BriefDir)\read-first\done-$name.md`` - the standing criteria, copied from ``$criteria``.",
                '- The index was checked; nothing in it applies beyond the standing criteria above.')

            & $script:DispatchScript -RepoPath $f.Repo -Name 'T-9014' `
                -BriefPath $f.BriefPath -DataPath $f.DataPath -ReadPath $criteria | Out-Null
            (Get-DispatchText -Fixture $f) | Should -Not -BeLike '*attached automatically at dispatch*'
            Test-Path -LiteralPath (Join-Path $f.BriefDir "read-first\done-$name.md") | Should -BeTrue
        }

        # Re-dispatching a ticket is ordinary - a worker sent back to keep going - and neither the
        # brief nor the dispatch file may collect a second copy of the same line.
        It 'adds no second line when the same ticket is dispatched again' {
            Set-AgentStartState
            $f = New-DispatchFixture 'standing-redispatch'
            $name = Register-FixtureProject -Fixture $f
            New-StandingFile -Fixture $f -Leaf "rules-$name.md" | Out-Null
            Set-ReadFirstBrief -Fixture $f -Body @('- Nothing beyond this brief.')
            $brief = Get-BriefText -Fixture $f

            Invoke-Dispatch -Fixture $f -Name 'T-9015' | Out-Null
            $after = Get-DispatchText -Fixture $f
            Invoke-Dispatch -Fixture $f -Name 'T-9015' | Out-Null
            (Get-DispatchText -Fixture $f) | Should -Be $after
            (Get-BriefText -Fixture $f) | Should -Be $brief
        }

        # The section the Hand actually writes when the index turns up nothing says there is nothing
        # beyond the brief. Attaching a copy beside that line without a word of explanation hands the
        # worker a file and tells it in the next breath that no such file exists - and a worker that
        # believes the second line skips the project's standing rules entirely.
        It 'scopes the attachment so a nothing-beyond-this-brief section still reads coherently' {
            Set-AgentStartState
            $f = New-DispatchFixture 'standing-leadin'
            $name = Register-FixtureProject -Fixture $f
            New-StandingFile -Fixture $f -Leaf "rules-$name.md" | Out-Null
            Set-ReadFirstBrief -Fixture $f -Body @(
                '- Nothing beyond this brief - the index was checked and nothing in it applies.')
            $brief = Get-BriefText -Fixture $f

            Invoke-Dispatch -Fixture $f -Name 'T-9019' | Out-Null
            $lines   = @(Get-Content -LiteralPath (Get-DispatchFilePath $f))
            $heading = @(0..($lines.Count - 1) | Where-Object { $lines[$_] -match '^\s*##\s+Read first\s*$' })[0]
            $leadIn  = @(0..($lines.Count - 1) | Where-Object { $lines[$_] -like '*attached by dispatch from this project*' })[0]
            $bullet  = @(0..($lines.Count - 1) | Where-Object { $lines[$_] -like "*read-first\rules-$name.md*" })[0]

            ($null -ne $leadIn) | Should -BeTrue
            ($leadIn -gt $heading) | Should -BeTrue
            ($bullet -gt $leadIn)  | Should -BeTrue
            # The line the Hand wrote is left exactly as it was - nothing here rewrites the brief.
            (Get-BriefText -Fixture $f) | Should -Be $brief
            # Coherence is carried by the lead-in scoping what follows it.
            $lines[$leadIn] | Should -BeLike "*as well as everything in the brief's own Read first section*"
            $lines[$leadIn] | Should -BeLike '*nothing beyond this brief was named*'
        }

        # The lead-in belongs to the same block as the bullets, so a re-dispatch adds neither.
        It 'adds no second lead-in when the same ticket is dispatched again' {
            Set-AgentStartState
            $f = New-DispatchFixture 'standing-leadin-redispatch'
            $name = Register-FixtureProject -Fixture $f
            New-StandingFile -Fixture $f -Leaf "rules-$name.md" | Out-Null
            Set-ReadFirstBrief -Fixture $f -Body @(
                '- Nothing beyond this brief - the index was checked and nothing in it applies.')

            Invoke-Dispatch -Fixture $f -Name 'T-9020' | Out-Null
            $after = Get-DispatchText -Fixture $f
            Invoke-Dispatch -Fixture $f -Name 'T-9020' | Out-Null
            (Get-DispatchText -Fixture $f) | Should -Be $after
            @(@(Get-Content -LiteralPath (Get-DispatchFilePath $f)) |
                Where-Object { $_ -like '*attached by dispatch from this project*' }).Count |
                Should -Be 1
        }

        # The growth case: a project that has one standing file when a ticket is first dispatched and
        # two by the time it is re-dispatched. The lead-in is already in the brief, so it is not added
        # again - and the new bullet must land below it AND below the file already named, or the
        # newest file silently jumps the documented criteria-before-rules order.
        It 'keeps criteria above rules when the rules file appears after the first dispatch' {
            Set-AgentStartState
            $f = New-DispatchFixture 'standing-grew-a-file'
            $name = Register-FixtureProject -Fixture $f
            New-StandingFile -Fixture $f -Leaf "done-$name.md" -Text '- Pester is green.' | Out-Null
            Set-ReadFirstBrief -Fixture $f -Body @(
                '- Nothing beyond this brief - the index was checked and nothing in it applies.')

            Invoke-Dispatch -Fixture $f -Name 'T-9023' | Out-Null
            New-StandingFile -Fixture $f -Leaf "rules-$name.md" | Out-Null
            Invoke-Dispatch -Fixture $f -Name 'T-9023' | Out-Null

            $o = Get-ReadFirstOrder -Fixture $f -Project $name
            ($null -ne $o.Rules) | Should -BeTrue
            ($o.LeadIn   -gt $o.Heading)  | Should -BeTrue
            ($o.Criteria -gt $o.LeadIn)   | Should -BeTrue
            ($o.Rules    -gt $o.Criteria) | Should -BeTrue
            $o.LeadIns | Should -Be 1
            Test-Path -LiteralPath (Join-Path $f.BriefDir "read-first\rules-$name.md") | Should -BeTrue
        }

        # Growth the other way round, which the single-anchor insertion happened to get right and a
        # per-line walk must not break: the file that appears later is the one that belongs FIRST, so
        # it has to be placed above a bullet already in the brief rather than after it.
        It 'keeps criteria above rules when the criteria file appears after the first dispatch' {
            Set-AgentStartState
            $f = New-DispatchFixture 'standing-grew-criteria'
            $name = Register-FixtureProject -Fixture $f
            New-StandingFile -Fixture $f -Leaf "rules-$name.md" | Out-Null
            Set-ReadFirstBrief -Fixture $f -Body @(
                '- Nothing beyond this brief - the index was checked and nothing in it applies.')

            Invoke-Dispatch -Fixture $f -Name 'T-9027' | Out-Null
            New-StandingFile -Fixture $f -Leaf "done-$name.md" -Text '- Pester is green.' | Out-Null
            Invoke-Dispatch -Fixture $f -Name 'T-9027' | Out-Null

            $o = Get-ReadFirstOrder -Fixture $f -Project $name
            ($null -ne $o.Criteria) | Should -BeTrue
            ($o.LeadIn   -gt $o.Heading)  | Should -BeTrue
            ($o.Criteria -gt $o.LeadIn)   | Should -BeTrue
            ($o.Rules    -gt $o.Criteria) | Should -BeTrue
            $o.LeadIns | Should -Be 1
            Test-Path -LiteralPath (Join-Path $f.BriefDir "read-first\done-$name.md") | Should -BeTrue
        }

        # The order a first dispatch produces, pinned as the baseline both growth cases converge on.
        It 'names the criteria file above the rules file on a first dispatch with both' {
            Set-AgentStartState
            $f = New-DispatchFixture 'standing-order-first-dispatch'
            $name = Register-FixtureProject -Fixture $f
            New-StandingFile -Fixture $f -Leaf "done-$name.md"  -Text '- Pester is green.' | Out-Null
            New-StandingFile -Fixture $f -Leaf "rules-$name.md" | Out-Null
            Set-ReadFirstBrief -Fixture $f -Body @(
                '- Nothing beyond this brief - the index was checked and nothing in it applies.')

            Invoke-Dispatch -Fixture $f -Name 'T-9028' | Out-Null

            $o = Get-ReadFirstOrder -Fixture $f -Project $name
            ($o.LeadIn   -gt $o.Heading)  | Should -BeTrue
            ($o.Criteria -gt $o.LeadIn)   | Should -BeTrue
            ($o.Rules    -gt $o.Criteria) | Should -BeTrue
            $o.LeadIns | Should -Be 1
        }

        # The anchor is found by matching text this script composed, so a brief that QUOTES that text
        # must not move it. A kingshand brief discussing this very feature does exactly that: it
        # quotes the lead-in and a bullet inside a fenced block under a later heading. Scanning to the
        # end of the file put the attachment inside that fence, in a section no worker acts on - the
        # "a copy nothing names reaches nobody" failure, reached through the attachment itself - and
        # it was sticky, because the next dispatch then saw the bullet as already present.
        It 'ignores a quoted copy of its own lines under a later heading' {
            Set-AgentStartState
            $f = New-DispatchFixture 'standing-quoted-elsewhere'
            $name = Register-FixtureProject -Fixture $f
            New-StandingFile -Fixture $f -Leaf "rules-$name.md" | Out-Null

            # Composed exactly as the dispatcher composes them, so the quote is verbatim rather than
            # merely similar - a near-miss would prove nothing about a whole-line comparison.
            $leadIn = '- The file(s) named directly below were attached by dispatch from this ' +
                      "project's own standing files, not by hand. They apply as well as everything " +
                      'else in this section, including any line saying nothing beyond this brief ' +
                      'was named - that line was written before these were attached. Read them.'
            $bullet = "- ``$($f.BriefDir)\read-first\rules-$name.md`` - the standing rules for $name " +
                      '- conventions, vocabulary, exclusions, branch naming, environment facts, ' +
                      "attached automatically at dispatch from ``$(Join-Path $f.DataPath "rules-$name.md")`` " +
                      'rather than named by hand. Read it in full before you start. It is reference ' +
                      'to consult, not a list to answer, so never self-report against its lines.'

            Set-Content -Path $f.BriefPath -Encoding utf8 -Value @(
                '# Brief', '', '## Read first',
                '- Nothing beyond this brief - the index was checked and nothing in it applies.',
                '', '## Intent', 'We are changing how dispatch writes these lines. It writes:',
                '```', $leadIn, $bullet, '```', '', '## Scope', 'Do the thing.')

            $brief = [System.IO.File]::ReadAllBytes($f.BriefPath)
            Invoke-Dispatch -Fixture $f -Name 'T-9029' | Out-Null

            # The brief, quote and all, is exactly as the author left it.
            [System.IO.File]::ReadAllBytes($f.BriefPath) | Should -Be $brief

            # The dispatch file names the copy once, under its own lead-in, whatever the brief quotes.
            $lines = @(Get-Content -LiteralPath (Get-DispatchFilePath $f))
            @($lines | Where-Object { $_ -like "*read-first\rules-$name.md*" }).Count | Should -Be 1
            @($lines | Where-Object { $_ -like '*attached by dispatch from this project*' }).Count |
                Should -Be 1
        }

        # The lead-in says the files named DIRECTLY BELOW were attached by dispatch and not by hand.
        # The Hand's own lines stay in the brief where the Hand put them, and the attached ones go
        # under that lead-in in the dispatch file, so the sentence is true of every line it covers.
        It 'leaves the lines the Hand wrote in the brief and names only its own beside it' {
            Set-AgentStartState
            $f = New-DispatchFixture 'standing-below-hand-lines'
            $name = Register-FixtureProject -Fixture $f
            $criteria = New-StandingFile -Fixture $f -Leaf "done-$name.md" -Text '- Pester is green.'
            New-StandingFile -Fixture $f -Leaf "rules-$name.md" | Out-Null
            Set-ReadFirstBrief -Fixture $f -Body @(
                "- ``$($f.BriefDir)\read-first\done-$name.md`` - the standing criteria, copied from ``$criteria``.",
                '- The index was checked; nothing in it applies to this task beyond the standing criteria above.')
            $brief = Get-BriefText -Fixture $f

            & $script:DispatchScript -RepoPath $f.Repo -Name 'T-9030' `
                -BriefPath $f.BriefPath -DataPath $f.DataPath -ReadPath $criteria | Out-Null

            (Get-BriefText -Fixture $f) | Should -Be $brief
            $lines  = @(Get-Content -LiteralPath (Get-DispatchFilePath $f))
            $leadIn = @(0..($lines.Count - 1) | Where-Object { $lines[$_] -like '*attached by dispatch from this project*' })[0]
            $rules  = @(0..($lines.Count - 1) | Where-Object { $lines[$_] -like "*read-first\rules-$name.md*" })[0]
            ($rules -gt $leadIn) | Should -BeTrue
            @($lines | Where-Object { $_ -like "*read-first\done-$name.md*" }).Count |
                Should -Be 0 -Because 'the Hand already named the file it passed'
        }
        # A standing file the King removes must stop reaching the worker. Removing one is supported -
        # annex says the file stands until the King changes or removes it - and a re-dispatch is
        # ordinary, so the stale copy and the line naming it would otherwise both survive.
        It 'clears the copy and the line when the King removes a standing file' {
            Set-AgentStartState
            $f = New-DispatchFixture 'standing-removed'
            $name = Register-FixtureProject -Fixture $f
            New-StandingFile -Fixture $f -Leaf "done-$name.md" -Text '- Pester is green.' | Out-Null
            $rules = New-StandingFile -Fixture $f -Leaf "rules-$name.md"
            Set-ReadFirstBrief -Fixture $f -Body @(
                '- Nothing beyond this brief - the index was checked and nothing in it applies.')

            Invoke-Dispatch -Fixture $f -Name 'T-9031' | Out-Null
            $copy = Join-Path $f.BriefDir "read-first\rules-$name.md"
            Test-Path -LiteralPath $copy | Should -BeTrue

            Remove-Item -LiteralPath $rules -Force
            Invoke-Dispatch -Fixture $f -Name 'T-9031' | Out-Null

            Test-Path -LiteralPath $copy | Should -BeFalse
            $text = Get-DispatchText -Fixture $f
            $text.Contains("read-first\rules-$name.md") | Should -BeFalse
            # The file still there is untouched, and so is the lead-in that introduces it.
            $text.Contains("read-first\done-$name.md")  | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $f.BriefDir "read-first\done-$name.md") | Should -BeTrue
            $text | Should -BeLike '*attached by dispatch from this project*'
        }

        # With no attached file left, the lead-in introduces nothing and goes with them - and putting
        # the file back restores both, which is what makes the pruning safe to do at all.
        It 'drops the lead-in with the last standing file, and restores both when it returns' {
            Set-AgentStartState
            $f = New-DispatchFixture 'standing-removed-last'
            $name = Register-FixtureProject -Fixture $f
            $rules = New-StandingFile -Fixture $f -Leaf "rules-$name.md"
            Set-ReadFirstBrief -Fixture $f -Body @(
                '- Nothing beyond this brief - the index was checked and nothing in it applies.')

            $brief = Get-BriefText -Fixture $f
            Invoke-Dispatch -Fixture $f -Name 'T-9032' | Out-Null
            Remove-Item -LiteralPath $rules -Force
            Invoke-Dispatch -Fixture $f -Name 'T-9032' | Out-Null

            # Nothing left to add, so the dispatch file goes with its last line.
            Test-Path -LiteralPath (Get-DispatchFilePath $f) | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $f.BriefDir "read-first\rules-$name.md") | Should -BeFalse
            # The Hand's own line is left exactly as it was.
            (Get-BriefText -Fixture $f) | Should -Be $brief

            New-StandingFile -Fixture $f -Leaf "rules-$name.md" | Out-Null
            Invoke-Dispatch -Fixture $f -Name 'T-9032' | Out-Null

            $back = Get-DispatchText -Fixture $f
            $back | Should -BeLike '*attached by dispatch from this project*'
            $back.Contains("read-first\rules-$name.md") | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $f.BriefDir "read-first\rules-$name.md") | Should -BeTrue
        }

        # The prune must survive the gap between dispatches, where the -ReadPath guard cannot see.
        # muster passes data\done-<project>.md on every brief and writes its own bullet for it, so a
        # retired criteria file leaves a leaf that looks exactly like an abandoned auto-attachment:
        # source gone, copy present, nothing passed this time. Deleting it on that evidence took the
        # Hand's file while the Hand's own line survived, leaving the brief naming a file that is not
        # there - worse than the staleness the prune exists for.
        It 'leaves a copy the Hand passed on an earlier dispatch, and the line naming it' {
            Set-AgentStartState
            $f = New-DispatchFixture 'standing-hand-passed-earlier'
            $name = Register-FixtureProject -Fixture $f
            $criteria = New-StandingFile -Fixture $f -Leaf "done-$name.md" -Text '- Pester is green.'
            # muster's own wording, which is not the line this script composes.
            $handLine = "- ``$($f.BriefDir)\read-first\done-$name.md`` - the standing criteria for " +
                        "$name, copied from ``$criteria``. Work its lines one by one."
            Set-ReadFirstBrief -Fixture $f -Body @(
                $handLine,
                '- The index was checked; nothing in it applies to this task beyond the standing criteria above.')

            & $script:DispatchScript -RepoPath $f.Repo -Name 'T-9034' `
                -BriefPath $f.BriefPath -DataPath $f.DataPath -ReadPath $criteria | Out-Null
            $copy = Join-Path $f.BriefDir "read-first\done-$name.md"
            Test-Path -LiteralPath $copy | Should -BeTrue

            # The criteria file is retired, and muster now passes no -ReadPath for it.
            Remove-Item -LiteralPath $criteria -Force
            Invoke-Dispatch -Fixture $f -Name 'T-9034' | Out-Null

            # The copy the Hand staged is not this script's to delete, and the Hand's line stands.
            Test-Path -LiteralPath $copy | Should -BeTrue
            $text = Get-BriefText -Fixture $f
            $text.Contains($handLine) | Should -BeTrue
        }

        # The prune keys on this script's own line in its own earlier file, never on the brief. A
        # brief that merely QUOTES that line is not evidence this script staged anything, so the
        # copy the Hand staged under the same name stays.
        It 'does not prune on a line the brief quotes rather than one its own earlier file held' {
            Set-AgentStartState
            $f = New-DispatchFixture 'standing-prune-ignores-brief'
            $name = Register-FixtureProject -Fixture $f
            $criteria = New-StandingFile -Fixture $f -Leaf "done-$name.md" -Text '- Pester is green.'
            $own = "- ``$($f.BriefDir)\read-first\done-$name.md`` - the standing definition of done " +
                   "for $name, attached automatically at dispatch from ``$criteria`` rather than " +
                   'named by hand. Read it in full. It is this project''s standing definition of ' +
                   'done, and you work its lines one by one.'
            Set-ReadFirstBrief -Fixture $f -Body @(
                $own,
                '- The index was checked; nothing in it applies to this task beyond the standing criteria above.')

            & $script:DispatchScript -RepoPath $f.Repo -Name 'T-9040' `
                -BriefPath $f.BriefPath -DataPath $f.DataPath -ReadPath $criteria | Out-Null
            $copy = Join-Path $f.BriefDir "read-first\done-$name.md"
            Remove-Item -LiteralPath $criteria -Force
            Invoke-Dispatch -Fixture $f -Name 'T-9040' | Out-Null

            Test-Path -LiteralPath $copy | Should -BeTrue
        }

        # A file the Hand passed lives under the same staging name and its line is the Hand's own.
        # Pruning must never reach either, even when the project's standing file of that name is gone.
        It 'leaves a hand-passed file alone when the standing file of that name is absent' {
            Set-AgentStartState
            $f = New-DispatchFixture 'standing-removed-hand-passed'
            $name = Register-FixtureProject -Fixture $f
            $elsewhere = Join-Path $f.Home "rules-$name.md"
            Set-Content -LiteralPath $elsewhere -Value 'the Hand''s own file' -Encoding utf8
            Set-ReadFirstBrief -Fixture $f -Leaf "rules-$name.md" -From $elsewhere

            & $script:DispatchScript -RepoPath $f.Repo -Name 'T-9033' `
                -BriefPath $f.BriefPath -DataPath $f.DataPath -ReadPath $elsewhere | Out-Null

            $copy = Join-Path $f.BriefDir "read-first\rules-$name.md"
            Test-Path -LiteralPath $copy | Should -BeTrue
            (Get-Content -LiteralPath $copy -Raw) | Should -BeLike "*the Hand's own file*"
            (Get-BriefText -Fixture $f).Contains("read-first\rules-$name.md") | Should -BeTrue
        }

        # The preflight guards a write. On a re-dispatch that adds nothing there is no write to
        # guard, so demanding an exclusive handle would refuse over work it was never going to do -
        # and unlike the read-only flag, a share lock is transient and arrives from editors and
        # scanners nobody dispatched.
        It 'does not demand the dispatch file when a re-dispatch would add nothing to it' {
            Set-AgentStartState
            $f = New-DispatchFixture 'standing-locked-noop-redispatch'
            $name = Register-FixtureProject -Fixture $f
            New-StandingFile -Fixture $f -Leaf "rules-$name.md" | Out-Null
            Set-ReadFirstBrief -Fixture $f -Body @('- Nothing beyond this brief.')

            Invoke-Dispatch -Fixture $f -Name 'T-9024' | Out-Null
            $after = Get-DispatchText -Fixture $f

            $held = [System.IO.File]::Open((Get-DispatchFilePath $f), 'Open', 'Read', 'Read')
            try {
                (Invoke-Dispatch -Fixture $f -Name 'T-9024').id | Should -Be 'T-9024'
            } finally { $held.Dispose() }

            (Get-DispatchText -Fixture $f) | Should -Be $after
        }

        # The brief is never written, so nothing about it being read-only or held open by another
        # process can stop a dispatch any more - the case that used to refuse now simply goes out.
        It 'dispatches a brief that is read-only or held against writing, and leaves it alone' {
            Set-AgentStartState
            $f = New-DispatchFixture 'standing-readonly-brief-ok'
            $name = Register-FixtureProject -Fixture $f
            New-StandingFile -Fixture $f -Leaf "rules-$name.md" | Out-Null
            Set-ReadFirstBrief -Fixture $f -Body @('- Nothing beyond this brief.')
            $before = Get-BriefText -Fixture $f
            $item = Get-Item -LiteralPath $f.BriefPath
            $item.IsReadOnly = $true
            $held = [System.IO.File]::Open($f.BriefPath, 'Open', 'Read', 'Read')
            try {
                (Invoke-Dispatch -Fixture $f -Name 'T-9041').id | Should -Be 'T-9041'
            } finally { $held.Dispose(); $item.IsReadOnly = $false }
            (Get-BriefText -Fixture $f) | Should -Be $before
            (Get-DispatchText -Fixture $f).Contains("read-first\rules-$name.md") | Should -BeTrue
        }

        # This script never reads the brief's body, so it may not assert anything about what is in
        # it. muster usually pastes the criteria in and says so in its own line - but the backstop
        # exists precisely for the dispatch where nobody did, and there the claim would be false.
        It 'does not claim the criteria file is pasted into the brief' {
            Set-AgentStartState
            $f = New-DispatchFixture 'standing-criteria-claim'
            $name = Register-FixtureProject -Fixture $f
            New-StandingFile -Fixture $f -Leaf "done-$name.md" -Text '- Pester is green.' | Out-Null
            Set-ReadFirstBrief -Fixture $f -Body @('- Nothing beyond this brief.')

            Invoke-Dispatch -Fixture $f -Name 'T-9021' | Out-Null
            $line = @(@(Get-Content -LiteralPath (Get-DispatchFilePath $f)) |
                        Where-Object { $_ -like "*read-first\done-$name.md*" })[0]
            ($null -ne $line) | Should -BeTrue
            $line | Should -Not -BeLike '*pasted into this brief*'
            # It still has to say what the file IS and how it is worked, or the worker is handed a
            # copy with no idea it is the one thing it self-reports against.
            $line | Should -BeLike '*standing definition of done*'
            $line | Should -BeLike '*one by one*'
        }

        # A dispatch file that cannot be written to would leave the copies on disk with nothing
        # telling the worker to open them, which is the failure this attachment exists to close.
        # Driven as a growth re-dispatch, so there is a real write for the preflight to guard.
        It 'refuses before creating anything when the dispatch file is read-only' {
            Set-AgentStartState
            $f = New-DispatchFixture 'standing-readonly-dispatch-file'
            $name = Register-FixtureProject -Fixture $f
            New-StandingFile -Fixture $f -Leaf "rules-$name.md" | Out-Null
            Set-ReadFirstBrief -Fixture $f -Body @('- Nothing beyond this brief.')
            Invoke-Dispatch -Fixture $f -Name 'T-9016' | Out-Null
            New-StandingFile -Fixture $f -Leaf "done-$name.md" -Text '- Pester is green.' | Out-Null
            $before = Get-DispatchText -Fixture $f

            $item = Get-Item -LiteralPath (Get-DispatchFilePath $f)
            $item.IsReadOnly = $true
            try {
                { Invoke-Dispatch -Fixture $f -Name 'T-9016' } | Should -Throw '*read-only*'
                Test-Path -LiteralPath (Join-Path $f.BriefDir "read-first\done-$name.md") |
                    Should -BeFalse
                (Get-DispatchText -Fixture $f) | Should -Be $before
            } finally { $item.IsReadOnly = $false }
        }

        # The read-only flag is not the only way the write fails, and it is not the common one. A
        # lock or an ACL denial would sail past a flag check and abort at the write itself, with the
        # copies already staged and no line naming them.
        It 'refuses before creating anything when another process holds the dispatch file' {
            Set-AgentStartState
            $f = New-DispatchFixture 'standing-locked-dispatch-file'
            $name = Register-FixtureProject -Fixture $f
            New-StandingFile -Fixture $f -Leaf "rules-$name.md" | Out-Null
            Set-ReadFirstBrief -Fixture $f -Body @('- Nothing beyond this brief.')
            Invoke-Dispatch -Fixture $f -Name 'T-9022' | Out-Null
            New-StandingFile -Fixture $f -Leaf "done-$name.md" -Text '- Pester is green.' | Out-Null
            $calls = @(Get-CallLines -Fixture $f).Count

            $held = [System.IO.File]::Open((Get-DispatchFilePath $f), 'Open', 'Read', 'Read')
            try {
                $msg = ''
                try { Invoke-Dispatch -Fixture $f -Name 'T-9022' } catch { $msg = $_.Exception.Message }
                $msg | Should -BeLike "*$(Get-DispatchFilePath $f)*"
                $msg | Should -BeLike '*could not be opened for writing*'
                $msg | Should -BeLike '*Nothing was created*'
            } finally { $held.Dispose() }

            Test-Path -LiteralPath (Join-Path $f.BriefDir "read-first\done-$name.md") | Should -BeFalse
            @(Get-CallLines -Fixture $f).Count | Should -Be $calls
        }
        # The composed name can hold no separator and no traversal, because the resolution loop
        # skips any registry entry whose name the index cannot turn into a file name. Without that,
        # a hand-edited registry line would decide which file this dispatch copies out of data\.
        It 'resolves no project from a registry name the index cannot make a file name of' {
            Set-AgentStartState
            $f = New-DispatchFixture 'standing-hostile-name'
            @('# Projects', '', '- ../../secrets [local-only] - hand written', "      path: $($f.Repo)") |
                Set-Content -LiteralPath (Join-Path $f.DataPath 'projects.md') -Encoding utf8
            Set-ReadFirstBrief -Fixture $f -Body @('- Nothing beyond this brief.')

            $r = & $script:DispatchScript -RepoPath $f.Repo -Name 'T-9017' `
                -BriefPath $f.BriefPath -DataPath $f.DataPath -WarningAction SilentlyContinue
            $r.id | Should -Be 'T-9017'
            Test-Path -LiteralPath (Join-Path $f.BriefDir 'read-first') | Should -BeFalse
        }

        It 'refuses to register a project name that could not be composed into a file name' {
            { Add-ProjectEntry -Name '../../secrets' -Path 'C:\repos\x' -Mode 'local-only' `
                -Description 'x' -RegistryPath (Join-Path (New-TempFixturePath -Prefix 'reg-') 'projects.md') } |
                Should -Throw '*cannot be registered*'
        }

        # The rules file is reference handed over whole. Nothing here reads what is inside it, so a
        # file whose content would defeat any parser is copied through untouched.
        It 'copies the rules file through without reading a thing inside it' {
            Set-AgentStartState
            $f = New-DispatchFixture 'standing-opaque'
            $name = Register-FixtureProject -Fixture $f
            $body = @('## Read first', '```', '- `C:\not\a\path.md`', '```', 'index checked, nothing applies') -join "`r`n"
            New-StandingFile -Fixture $f -Leaf "rules-$name.md" -Text $body | Out-Null
            Set-ReadFirstBrief -Fixture $f -Body @('- Nothing beyond this brief.')

            (Invoke-Dispatch -Fixture $f -Name 'T-9018').id | Should -Be 'T-9018'
            (Get-Content -LiteralPath (Join-Path $f.BriefDir "read-first\rules-$name.md") -Raw).Trim() |
                Should -Be $body
        }
    }
}
