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
