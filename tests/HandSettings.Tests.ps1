#Requires -Version 7.0
Set-StrictMode -Version Latest

# The Hand's own .claude\settings.json, read through a JSON parser. Its content is the contract:
# a deny rule naming a tool by bare name takes that tool's schema out of every call the Hand makes,
# measured at about 16k tokens for the six below, so losing one silently costs context on every
# call while removing a scoped rule silently drops a protection.

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    $script:Settings = Get-Content -LiteralPath (Join-Path $script:Root '.claude\settings.json') -Raw |
        ConvertFrom-Json
    $script:Deny = @($script:Settings.permissions.deny)
}

Describe 'the Hand''s settings deny list' {
    It 'denies <Tool> by bare name, which removes its schema from context' -ForEach @(
        @{ Tool = 'Artifact' }
        @{ Tool = 'SendFeedback' }
        @{ Tool = 'ScheduleWakeup' }
        @{ Tool = 'ReportFindings' }
        @{ Tool = 'ShareOnboardingGuide' }
        @{ Tool = 'ListAgents' }
    ) {
        $script:Deny | Should -Contain $Tool
    }

    It 'still carries <Rule>' -ForEach @(
        @{ Rule = 'Read(//**/.ssh/**)' }
        @{ Rule = 'Read(//**/.aws/credentials)' }
        @{ Rule = 'Read(./config/credentials/**)' }
        @{ Rule = 'Edit(./instructions.md)' }
    ) {
        $script:Deny | Should -Contain $Rule
    }

    # A bare-name rule removes a whole tool, so one added here unnoticed takes away a capability
    # the Hand may be told to use. Adding one is a decision, and this count is where it is made.
    It 'denies nothing beyond those ten rules' {
        $script:Deny.Count | Should -Be 10
    }
}

Describe 'the Hand''s settings environment' {
    # Every skill writes its commands as PowerShell, and on macOS and Linux Claude Code's PowerShell
    # tool is off unless this is set - so without it the Hand has only a Bash tool to run them with.
    It 'turns on the PowerShell tool' {
        $script:Settings.env.CLAUDE_CODE_USE_POWERSHELL_TOOL | Should -Be '1'
    }

    # The tracked file is the same for everyone, so a per-machine value written here would be one
    # machine's answer shipped to all of them. Those go in the gitignored settings.local.json.
    It 'carries nothing that is one machine''s answer' {
        @($script:Settings.env.PSObject.Properties.Name) | Should -Be @('CLAUDE_CODE_USE_POWERSHELL_TOOL')
    }
}
