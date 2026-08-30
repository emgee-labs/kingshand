# Test-CrewPrereqs.ps1 runs on every session start behind the digest, so what it calls a FAILURE
# decides what a user is told about their own machine. It called two things failures that a working
# installation may legitimately never have - Pester, which only runs this repository's own tests,
# and gh, which only a push-capable posture needs - so a brand-new user with a perfectly good
# install was shown FAILED and a non-zero exit. A report that says that is a report people learn to
# ignore, which costs the failures that are real.
#
# Asserted by running the script rather than by reading it, because the thing that matters is the
# classification and the exit code, not the source that produces them. It is detect-only: it
# installs nothing and configures nothing, so running it inside the suite is safe.
#
# The child process gets a PATH cut down to git alone. That makes the outcome the same on every
# machine: claude, lavish-axi and tasks-axi are genuinely missing, so the run must fail - and gh and
# Pester must be reported as notes in that same run rather than joining the failures. git stays
# because the script shells out to `git config --global core.excludesFile`, and PSModulePath is cut
# to $PSHOME\Modules, which never carries Pester.

BeforeAll {
    $script:Root    = Split-Path $PSScriptRoot -Parent
    $script:Prereqs = Join-Path $script:Root 'bin\Test-CrewPrereqs.ps1'
    $script:Git     = (Get-Command git -CommandType Application -ErrorAction SilentlyContinue |
                       Select-Object -First 1)

    # One run, reused by every case below. Spawning a pwsh per assertion would cost seconds each
    # for output that cannot differ between them.
    $script:Run = $null
    if ($script:Git) {
        $gitDir = Split-Path $script:Git.Source -Parent
        $driver = Join-Path ([IO.Path]::GetTempPath()) ("prereq-" + [guid]::NewGuid().ToString('N') + '.ps1')
        Set-Content -LiteralPath $driver -Encoding utf8 -Value @"
`$env:PATH         = '$gitDir'
`$env:PSModulePath = Join-Path `$PSHOME 'Modules'
& '$($script:Prereqs)'
Write-Host "PREREQ_EXIT=`$LASTEXITCODE"
"@
        try {
            $out = & (Get-Process -Id $PID).Path -NoProfile -File $driver 2>&1 | Out-String
            $script:Run = @{
                Text = $out
                Exit = if ($out -match 'PREREQ_EXIT=(\d+)') { [int]$Matches[1] } else { -1 }
            }
        } finally {
            Remove-Item -LiteralPath $driver -Force -ErrorAction SilentlyContinue
        }
    }

    # Everything after the "FAILED:" banner, which is the only part that sets the exit code.
    function Get-FailureBlock {
        param([Parameter(Mandatory)][string]$Text)
        $i = $Text.IndexOf('FAILED:')
        if ($i -lt 0) { return '' }
        $Text.Substring($i)
    }
}

Describe 'the prereq check fails only on what dispatch cannot work without' {
    BeforeEach {
        if (-not $script:Git) { Set-ItResult -Skipped -Because 'git is not on PATH, so the script cannot run at all' }
    }

    It 'still fails when a genuine prerequisite is missing' {
        $script:Run.Exit | Should -Be 1 -Because 'claude, lavish-axi and tasks-axi were hidden from this run'
        $script:Run.Text | Should -Match 'FAILED:'
    }

    It 'reports a missing gh as a note, not a failure' {
        $script:Run.Text | Should -Match '(?m)^\s+NOTE gh not found\.'
        (Get-FailureBlock $script:Run.Text).Contains('gh not found') |
            Should -BeFalse -Because 'only a push-capable posture needs gh, and annex refuses that case itself'
    }

    It 'reports a missing Pester as a note, not a failure' {
        $script:Run.Text | Should -Match '(?m)^\s+NOTE Pester 6\+ not found\.'
        (Get-FailureBlock $script:Run.Text).Contains('Pester 6+ not found') |
            Should -BeFalse -Because 'Pester runs this repository''s own tests and nothing at runtime imports it'
    }

    It 'says in each note what it is for, so the reader can decide rather than obey' {
        $script:Run.Text | Should -Match 'Needed only by a push-capable posture'
        $script:Run.Text | Should -Match 'It runs kingshand''s own test suite and nothing at runtime needs it'
    }

    It 'names install.ps1 as the fix for the global gitignore rather than a manual edit' {
        # The check used to say "add the line by hand" and nothing in the repository ever wrote it,
        # so every new machine failed this by definition. install.ps1 does it now, and the hint has
        # to point there or the check is unactionable again.
        $source = Get-Content -LiteralPath $script:Prereqs -Raw
        $source.Contains('it appends the lines .claude/worktrees/ and .claude/settings.local.json to the file named by core.excludesFile') |
            Should -BeTrue -Because 'a check whose fix nothing performs is a check that always fails'
    }
}
