# Text in a worker's input box that nobody sent

Date: 2026-09-02
Status: **current**

## What happened

A worker was found sitting idle with a well-formed instruction in its input box - `show me the
getting started section rendered`. Nothing had sent it. It appears in no transcript, no brief and no
`report.md`, because nothing ever submitted it.

It is the harness generating the prompt a person would plausibly type next and rendering it into the
empty box between turns. Three sightings, all found by chance while looking at something else.

That is a cosmetic render right up to the moment anything presses Enter at that worker. Then it is
an instruction the Hand never wrote, submitted under the Hand's name.

## The decisions

### The guard sits on the send paths, not on the input side

The suggestion is application state rather than input. It cannot concatenate onto anything - the
first typed character displaces it - so text arriving at the box is never at risk of being mixed
with it. A bare Enter is the whole hazard: it **accepts** what is rendered, and the harness records
a submission whose text equals the suggestion as accepted by `enter`. So
`Send-HerdrKeys -Keys @('enter')` at an idle worker submits a generated instruction as though the
Hand had written it, and `rally` step 3 sends exactly that call to answer a menu.

`Send-HerdrPrompt` and `Send-HerdrKeys` in `bin\Herdr.psm1` therefore read the box before they act,
and refuse when it is not empty. **Refuse, never clear.** Clearing destroys the evidence of the one
event worth noticing, and the caller may be about to send something that must not be mixed with
whatever is already there. The escape hatch is `-AllowNonEmptyBox`, which is the escalation: `rally`
quotes the text to the King and passes the switch only once they have seen it.

Teardown is the one standing exemption. `/exit` displaces whatever is rendered harmlessly, and a
worker that cannot be stopped because of a cosmetic render is a worse failure than the one the guard
prevents - so `Stop-HerdrAgent` passes the switch deliberately, through the guarded path rather than
around it.

### The discriminator is the caret plus a no-break space

The box line is drawn as the caret `❯` (U+276F) followed by U+00A0. The highlighted row of a
numbered option menu is drawn with the **same caret** followed by a plain space. On a rendered screen
that one glyph is the only thing separating them, and the detector returns its first match top-down,
so a caret-only rule reads a menu row above the box as box content.

That is not a cosmetic wrong answer. A worker blocked on a menu is answered by a bare Enter and there
is no other route to it - the panes are headless. A detector that refused that Enter would leave the
worker stuck with nobody able to deliver the answer the King had already given.

A plain `>` is never matched at all: a worker's own output lines start with one, and treating those
as a box would refuse every send to a perfectly healthy worker.

This is the captured render the fixtures in `tests\Herdr.Tests.ps1` are built from - a bare U+2500
rule, the caret and U+00A0 and the text at column 0, then another rule. There are no U+2502 side
borders on a real screen. `<U+00A0>` below stands for the no-break space that is really there,
because an invisible character in a document gets tidied into a plain space by the next editor to
touch it:

```
────────────────────────────────────────────────────────────────
❯<U+00A0>show me the getting started section rendered
────────────────────────────────────────────────────────────────
    ? for shortcuts
```

The fixtures escape it as `` `u{00A0} `` for the same reason.

### The placeholder exclusion is a named list, not "the value is empty"

The harness draws its own dim placeholder into the **empty** box at exactly the position box content
occupies, so position alone cannot tell one from the other. Refusing on one makes a worker
unsteerable on a hint the harness printed itself.

So `Get-HerdrPromptBoxText` carries a list of the placeholder strings, read out of the shipped binary
rather than paraphrased, and a match returns empty. Where a placeholder has a variable part it is
anchored on its invariant prefix and suffix, with the variable part required to be non-empty so the
anchor cannot swallow an arbitrary line that merely opens the same way.

**It is deliberately not the general rule "the underlying value is empty, so Enter submits nothing".**
That rule is false for the generated suggestion, which is the entire hazard: its value is empty too,
and the harness still records a submission equal to it as accepted by `enter`. Only the named
placeholders are excluded.

The list is bound to a harness version. A placeholder a later version adds is not on it, falls
through to the refusal, and `-AllowNonEmptyBox` covers the gap until it is added. Refusing an unknown
string is the safe direction; letting one through is not.

### This detector fails open, and the stall signal fails closed

They are opposites on purpose, and it is not an inconsistency.

`Get-HerdrAgentProgressSignal` fails closed: an unreadable screen answers `signalReadable = $false`
and no stall is claimed, because a caller that reads "could not see it" as "nothing changed" reports
a healthy worker as stuck - a false alarm reaching the King.

`Get-HerdrAgentPromptBox` fails open: an unreadable screen answers empty and the send proceeds. The
cost of guessing here is a teardown or a corrective steer that cannot be delivered to a worker that
may already be wedged. A pane too narrow to render must not make a worker unsteerable.

### The feature is switched off on worker panes as well

A worker has no human at its prompt, so a suggestion of what that human should type next has no
purpose at all and only creates the hazard. `CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=0` is set on the
pane, at both the server start and the pane creation in `bin\Herdr.psm1`.

**The environment check is the first branch of the harness's resolver**, so it wins over the remote
flag and over any setting file. It is preferred to the equivalent settings key because that key is
read at user scope: writing it into a worktree's `settings.local.json` may do nothing at all.

The variable is passed at pane creation as well as at server start for the same reason
`CLAUDE_CODE_CHILD_SESSION` is - the server scrub covers panes that server launched, and a herdr
server kingshand did not start carries whatever environment it inherited.

## What must not be undone

- **The guards stay even though the feature is off.** They also cover a herdr server kingshand did
  not start, and typing over a box the Hand did not fill was a defect before this feature existed.
- **The caret and the no-break space are matched as a pair.** Match the caret alone and every worker
  blocked on a menu becomes unanswerable. Match a plain `>` and every healthy worker becomes
  unsendable.
- **A refusal is never turned into a clear.** The quoted text is the only record that the event
  happened.
- **The placeholder exclusion stays a named list.** Generalising it to "the value is empty" reopens
  the exact hole the guard exists to close.
- **The box is reported, not classified.** `promptBox` is a field on the progress signal and on every
  `Wait-HerdrAgentProgress` report - settled, stalled, gone and timeout alike - and it is not folded
  into `Test-HerdrAgentAwaitingInput`. A box with text in it is not an interactive prompt, and
  treating it as one would read every finished worker as `blocked`. Reporting it on a wake the Hand
  already handles is what stops the fourth sighting also being found by chance.

## Revisit when

- The harness changes how it draws the input box, at which point the caret-plus-no-break-space pair
  stops matching. The symptom is silent in the safe direction: the guard simply stops firing.
  `Get-HerdrAgentPromptBox` against a worker with something visibly in its box is the check.
- The harness adds or reworks a placeholder string. The symptom is a worker that cannot be sent to,
  with the refusal quoting a string that is plainly the harness's own hint.
- `CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION` is renamed or its resolver reordered, at which point the
  suggestion comes back on worker panes and only the guards are left.
