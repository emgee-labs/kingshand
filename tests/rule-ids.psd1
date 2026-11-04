# The literal exceptions to the rule-id check. tests\RuleIds.Tests.ps1 reads this file; statute's
# "Rule ids" section owns the grammar and the rule, and this file never restates them.
#
# Uncited - a rule id that is declared but that nothing outside its own file cites yet:
#     @{ Id = 'owner/name'; Reason = 'one line saying why it is declared anyway' }
#   An entry whose id is cited after all, or declared nowhere, fails the check, so the list cannot
#   outlive what it excuses.
#
# NotAnId - a phrase in one file that opens like a rule id on purpose and is not one:
#     @{ File = 'path/as/git/lists/it.md'; Phrase = 'exact text'; Reason = '...' }
#   The phrase is masked out of the line before the check counts openings, and only in that file.
#   Exceptions are literal by design - never a pattern and never a rule about context.
#
# This file is not Markdown, so it is never scanned.

@{
    Uncited = @(
    )

    NotAnId = @(
        @{ File = '.claude/skills/statute/SKILL.md'; Phrase = '`<!-- rule:<owner>/<name> -->`'
           Reason = 'the grammar written out, with placeholders where a real id would go' }
        @{ File = '.claude/skills/statute/SKILL.md'; Phrase = '`[rule:<owner>/<name>]`'
           Reason = 'the grammar written out, with placeholders where a real id would go' }
    )
}
