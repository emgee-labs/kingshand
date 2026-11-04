# Words that must not appear in kingshand's tracked material, and the literal exceptions to them.
# tests\Vocabulary.Tests.ps1 reads this file and fails, naming the file, the line, the word and
# what to use instead, wherever a banned word turns up. Edit the lists here; the test needs no
# change when a word is added or removed.
#
# Banned - one entry per word:
#     @{ Word = 'oldword'; Use = 'newword'; Reason = 'one line saying why' }
#   A word is matched whole and case-insensitively, so `mate` never matches `material` or
#   `estimate`. Letters, digits, `_` and `-` only, no spaces.
#
# Allow - a literal exception to one banned word, either a whole file or an exact phrase:
#     @{ Word = 'oldword'; File = 'path/as/git/lists/it.md'; Reason = '...' }
#     @{ Word = 'oldword'; Phrase = 'exact phrase holding oldword'; Reason = '...' }
#   A phrase exempts the word only where it sits inside that phrase, matched case-insensitively.
#   An exception for a word that is not banned does nothing until it is. Exceptions are literal by
#   design - never a pattern and never a rule about context.
#
# This file itself is never scanned.

@{
    Banned = @(
    )

    Allow = @(
        @{ Word = 'captain'; Phrase = '--kind captain'
           Reason = 'tasks-axi''s own --kind value, an external schema' }
        @{ Word = 'firstmate'; File = 'README.md'
           Reason = 'credits the project kingshand was derived from' }
        @{ Word = 'anchor'; Phrase = 'anchor point'
           Reason = 'not naval' }
    )
}
