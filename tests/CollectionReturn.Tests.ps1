#Requires -Version 7.0
Set-StrictMode -Version Latest

# The measurement behind statute's collection-return rule, kept as a test so the rule cannot drift
# away from what PowerShell actually does.
#
# A typed List returned bare is NOT one shape: `return $list` enumerates it like any array, so the
# caller gets $null, a lone item or an object[] depending on the count. Returned whole - behind the
# leading comma, or through Write-Output -NoEnumerate - it is the list itself on assignment at
# every size, and arrives as one object in @() and in the pipeline. That is the rule: one shape in
# every position, and a caller that assigns it before using it.

BeforeAll {
    function New-TestList {
        param([int]$Count)
        $list = [System.Collections.Generic.List[object]]::new()
        for ($i = 1; $i -le $Count; $i++) { $list.Add("item$i") }
        , $list
    }

    function Get-Bare     { param([int]$Count) $list = New-TestList $Count; return $list }
    function Get-Comma    { param([int]$Count) $list = New-TestList $Count; return , $list }
    function Get-NoEnum   { param([int]$Count) $list = New-TestList $Count; Write-Output -NoEnumerate $list }
    function Get-Through  { param([int]$Count) return Get-Comma $Count }

    function Get-TypeName {
        param($Value)
        if ($null -eq $Value) { 'null' } else { $Value.GetType().Name }
    }
}

Describe 'a bare List is not one shape' {
    It 'assigns <count> items as <type>' -TestCases @(
        @{ count = 0; type = 'null' }
        @{ count = 1; type = 'String' }
        @{ count = 3; type = 'Object[]' }
    ) {
        $x = Get-Bare $count
        Get-TypeName $x | Should -Be $type -Because 'return enumerates a List exactly as it does an array'
    }

    It 'counts <count> items in @() and in the pipeline' -TestCases @(
        @{ count = 0 }, @{ count = 1 }, @{ count = 3 }
    ) {
        @(Get-Bare $count).Count | Should -Be $count
        (Get-Bare $count | Measure-Object).Count | Should -Be $count
    }
}

Describe 'a List returned whole is one shape' {
    It 'assigns <count> items as the list itself, through <name>' -TestCases @(
        @{ name = 'the leading comma'; count = 0 }
        @{ name = 'the leading comma'; count = 1 }
        @{ name = 'the leading comma'; count = 3 }
        @{ name = 'Write-Output -NoEnumerate'; count = 0 }
        @{ name = 'Write-Output -NoEnumerate'; count = 1 }
        @{ name = 'Write-Output -NoEnumerate'; count = 3 }
        @{ name = 'a function returning another one''s call'; count = 0 }
        @{ name = 'a function returning another one''s call'; count = 1 }
        @{ name = 'a function returning another one''s call'; count = 3 }
    ) {
        $f = @{
            'the leading comma'                       = 'Get-Comma'
            'Write-Output -NoEnumerate'               = 'Get-NoEnum'
            'a function returning another one''s call' = 'Get-Through'
        }[$name]
        $x = & $f $count
        $x -is [System.Collections.Generic.List[object]] | Should -BeTrue
        $x.Count | Should -Be $count
    }

    It 'arrives as one object in @() and in the pipeline at <count> items' -TestCases @(
        @{ count = 0 }, @{ count = 1 }, @{ count = 3 }
    ) {
        @(Get-Comma $count).Count | Should -Be 1 -Because 'so @() at the call site nests it'
        (Get-Comma $count | Measure-Object).Count | Should -Be 1
        @(Get-NoEnum $count).Count | Should -Be 1
        (Get-NoEnum $count | Measure-Object).Count | Should -Be 1
    }

    It 'enumerates its <count> items once assigned or parenthesised' -TestCases @(
        @{ count = 0 }, @{ count = 1 }, @{ count = 3 }
    ) {
        $x = Get-Comma $count
        @($x).Count | Should -Be $count
        ((Get-Comma $count) | Measure-Object).Count | Should -Be $count
        $seen = 0
        foreach ($item in (Get-Comma $count)) { $seen++ }
        $seen | Should -Be $count
    }

    It 'is unrolled again by a bare return of the assigned variable' {
        function Get-Relayed { $x = Get-Comma 1; return $x }
        Get-TypeName (Get-Relayed) | Should -Be 'String' -Because 'a relay must return it whole too'
    }
}
