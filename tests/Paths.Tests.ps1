#Requires -Version 7.0
Set-StrictMode -Version Latest

# Discovery for the optional review gate.
#
# The rule that matters here is not "can it find a file". It is that kingshand names the RIGHT
# source. `npm install -g no-mistakes` is the obvious guess and it installs a completely different,
# unrelated tool - a TS/JS static-analysis package by another author. It installs cleanly, so the
# mistake surfaces later, as a gate that does not gate. Anything that tells a user where to get the
# review gate has to steer them away from that name, and these cases pin it.

BeforeAll {
    Import-Module "$PSScriptRoot\..\bin\Paths.psm1" -Force

    $script:TempFixtures = [System.Collections.Generic.List[string]]::new()
    $script:SavedPath = $env:PATH
    $script:SavedHome = $env:KINGSHAND_HOME

    function New-TempFixtureDir {
        param([Parameter(Mandatory)][string]$Prefix)
        $p = Join-Path ([IO.Path]::GetTempPath()) ($Prefix + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $p | Out-Null
        $script:TempFixtures.Add($p)
        $p
    }
}

AfterAll {
    $env:PATH = $script:SavedPath
    $env:KINGSHAND_HOME = $script:SavedHome
    foreach ($p in $script:TempFixtures) {
        Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Get-NoMistakesCommandPath finds the review gate without demanding it' {

    It 'returns null when there is neither one on PATH nor one bundled' {
        $home_ = New-TempFixtureDir -Prefix 'nm-empty-'
        $env:KINGSHAND_HOME = $home_
        $env:PATH = New-TempFixtureDir -Prefix 'nm-path-'

        Get-NoMistakesCommandPath | Should -BeNullOrEmpty -Because 'the gate is optional, so absent is a normal answer rather than an error'
    }

    It 'finds the copy the installer drops in tools\no-mistakes' {
        $home_ = New-TempFixtureDir -Prefix 'nm-bundled-'
        New-Item -ItemType Directory -Force -Path (Join-Path $home_ 'tools\no-mistakes') | Out-Null
        $exe = Join-Path $home_ 'tools\no-mistakes\no-mistakes.exe'
        Set-Content -LiteralPath $exe -Value 'stub' -Encoding utf8

        $env:KINGSHAND_HOME = $home_
        $env:PATH = New-TempFixtureDir -Prefix 'nm-path-'

        Get-NoMistakesCommandPath | Should -Be $exe
    }

    # Someone who already manages their own copy must not be given a second one. Same rule as herdr.
    It 'prefers a copy the user already has on PATH over the bundled one' {
        $home_ = New-TempFixtureDir -Prefix 'nm-both-'
        New-Item -ItemType Directory -Force -Path (Join-Path $home_ 'tools\no-mistakes') | Out-Null
        Set-Content -LiteralPath (Join-Path $home_ 'tools\no-mistakes\no-mistakes.exe') -Value 'bundled' -Encoding utf8

        $onPath = New-TempFixtureDir -Prefix 'nm-onpath-'
        $theirs = Join-Path $onPath 'no-mistakes.cmd'
        Set-Content -LiteralPath $theirs -Value '@echo off' -Encoding ascii

        $env:KINGSHAND_HOME = $home_
        $env:PATH = $onPath

        Get-NoMistakesCommandPath | Should -Be $theirs
    }
}

Describe 'Get-NoMistakesHint sends people to the right tool' {

    It 'names the switch that installs it' {
        (Get-NoMistakesHint) | Should -BeLike '*-WithReviewGate*'
    }

    It 'names the actual source repository' {
        (Get-NoMistakesHint) | Should -BeLike '*github.com/kunchenguid/no-mistakes*'
    }

    # The whole reason this hint exists as one owned string rather than three ad-hoc messages.
    It 'warns against the npm package of the same name, which is a different tool' {
        $h = Get-NoMistakesHint
        $h | Should -BeLike '*npm install -g no-mistakes*'
        $h | Should -BeLike '*unrelated*'
    }

    It 'says the gate is only needed by the postures that use it' {
        $h = Get-NoMistakesHint
        $h | Should -BeLike '*no-mistakes-prod-only*'
    }
}


# ---------------------------------------------------------------------------------------------
# Which form of Claude Code gets resolved, and why the wrapper is the wrong answer.
#
# npm's claude.cmd forwards with `%*`, which re-expands the raw command line, so cmd.exe parses the
# quotes inside an argument as delimiters and the value is cut at the first one. Measured: a JSON
# schema passed through the wrapper arrived as `{` and Claude Code answered "--json-schema is not
# valid JSON: JSON Parse error: Expected '}'". The same call to the real binary, same machine, same
# minute, returned correct output.
#
# The cost of getting this wrong is not a crash - workers still dispatch fine, because kingshand
# passes no quoted arguments. It is the review gate: every one of its agent steps passes a JSON
# schema, so the whole pipeline dies instantly with an error about JSON that never mentions PATH.
# That is why the order below is asserted rather than left to whichever Get-Command answers first.
# ---------------------------------------------------------------------------------------------
Describe 'Get-ClaudeCommandPath prefers the binary over npm''s wrapper' {

    BeforeEach {
        $script:Bin = New-TempFixtureDir -Prefix 'claude-bin-'
        $script:Npm = New-TempFixtureDir -Prefix 'claude-npm-'
    }

    It 'returns claude.exe when it is on PATH, even with a wrapper also present' {
        Set-Content -LiteralPath (Join-Path $script:Bin 'claude.exe') -Value 'stub' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $script:Npm 'claude.cmd') -Value '@echo off' -Encoding ascii
        $env:PATH = "$($script:Bin);$($script:Npm)"

        Get-ClaudeCommandPath | Should -Be (Join-Path $script:Bin 'claude.exe')
    }

    # The npm bin directory holds claude, claude.cmd and claude.ps1 but no claude.exe - the binary
    # is one package directory down. Finding it there is what spares a user the PATH edit.
    It 'digs the binary out of the npm package when only the wrapper is on PATH' {
        $nested = Join-Path $script:Npm 'node_modules\@anthropic-ai\claude-code\bin'
        New-Item -ItemType Directory -Force -Path $nested | Out-Null
        Set-Content -LiteralPath (Join-Path $nested 'claude.exe') -Value 'stub' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $script:Npm 'claude.cmd') -Value '@echo off' -Encoding ascii
        $env:PATH = $script:Npm

        Get-ClaudeCommandPath | Should -Be (Join-Path $nested 'claude.exe')
    }

    It 'falls back to the wrapper rather than reporting nothing at all' {
        Set-Content -LiteralPath (Join-Path $script:Npm 'claude.cmd') -Value '@echo off' -Encoding ascii
        $env:PATH = $script:Npm

        $p = Get-ClaudeCommandPath
        $p | Should -Be (Join-Path $script:Npm 'claude.cmd')
        Test-ClaudeCommandIsWrapper -Path $p |
            Should -BeTrue -Because 'a degraded answer has to be recognisable as one'
    }

    It 'does not call the binary a wrapper' {
        Set-Content -LiteralPath (Join-Path $script:Bin 'claude.exe') -Value 'stub' -Encoding utf8
        $env:PATH = $script:Bin
        Test-ClaudeCommandIsWrapper -Path (Get-ClaudeCommandPath) | Should -BeFalse
    }

    It 'returns null when Claude Code is nowhere' {
        $env:PATH = New-TempFixtureDir -Prefix 'claude-none-'
        Get-ClaudeCommandPath | Should -BeNullOrEmpty
    }
}

Describe 'Get-ClaudeWrapperHint explains the failure someone will actually see' {

    It 'names the error text the wrapper produces' {
        (Get-ClaudeWrapperHint) | Should -BeLike '*--json-schema is not valid JSON*'
    }

    It 'names the directory that fixes it' {
        (Get-ClaudeWrapperHint) | Should -BeLike '*node_modules\@anthropic-ai\claude-code\bin*'
    }

    It 'says why the wrapper breaks, not just that it does' {
        $h = Get-ClaudeWrapperHint
        $h | Should -BeLike '*%`**'
        $h | Should -BeLike '*review gate*'
    }
}
