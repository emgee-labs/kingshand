# Watching the usage window - 2026-09-05

Kingshand could spend the whole of a five-hour usage window without noticing, and the King found out
when work died mid-run. This records where the number comes from, what was tried and rejected on the
way to it, and the four decisions that shape what was built.

## Where the number comes from

`quota-axi`, a separate tool installed with npm. It reports the account's own windows as JSON - a
used percentage and a reset time per window - and `bin\Usage.psm1` runs it and parses that JSON.

**Nothing in kingshand reads a credential file, a transcript or a terminal to get this.** That
boundary is the same one `bin\Ci.psm1` keeps to `gh`, and it is what keeps the reader clear of the
account-switch machinery, which does read credentials and is none of this module's business. It is
also what honours the open-ended-input rule: the only format read is JSON with a declared schema
version, from a tool that owns the question.

## What was tried first, and what each one gave back

Four candidates were tested before settling. None of them answered the question, and they are
recorded here so nobody spends the time again - including the one that came closest.

**The statusline payload.** Claude Code hands a statusline command a JSON object, and that object
does carry `rate_limits.five_hour.used_percentage` and `resets_at` - it is the right data. It is
unreachable from here: the statusline runs only inside an interactive session, print mode does not
invoke it at all (measured, with a command that would have written a file and did not), and reaching
it would mean asking the King to configure a statusline whose only job was to copy the number onto
disk for something else to read. `quota-axi` answers the same question without that hop.

**The session transcripts.** These give half the answer and it is the wrong half. The per-message
records under the projects directory do carry token counts - input, output, cache read, cache
creation - on every assistant record, as bounded JSONL that needs no scanner, and they cover far
more than one session: measured here, 1126 messages across ten transcripts in ninety minutes,
spanning the Hand, four workers and the review-gate agents. So consumption is computable.

The window quota to divide it by is not, and neither is the reset time. Turning tokens into a
fraction of a window means inventing the denominator, which is the fabricated number the whole
design refuses - and the denominator is exactly what `quota-axi` supplies directly, which is why
the transcripts are not read at all here.

Two things worth keeping from that measurement even so. Cache reads dominate by two orders of
magnitude - 142 million against 3.7 million created and 2.3 thousand fresh input in that window -
and they are not billed like fresh input, so a percentage summed from these four fields would be
dominated by the component that matters least. And the timestamps are UTC: compared against a local
cutoff they return nothing at all rather than erroring, which looks exactly like no usage. That
second one is a defect class this module is still exposed to through the reset time, so it is tested
there directly.

**A non-interactive subcommand.** There is none. The CLI's own help lists nine commands and not one
of them reports usage or limits. Print mode with JSON output returns a result envelope carrying cost
and token counts for that one run, and nothing about the account's windows.

**The live session itself.** A session can be interrogated about itself and it does not know. The
environment carries a session id, a process id and an entrypoint; the session record on disk carries
a working directory, a version and a status. Neither carries consumption or a reset time, and the
context-budget figure a session does see is the context window, which is a different thing entirely
from the usage window.

Two files that look like they should answer and do not: the policy-limits file holds policy
restrictions rather than usage, and the top-level configuration holds a rate-limit tier name with no
figure attached to it.

## Four decisions

**The refusal fails open.** Dispatch refuses a new worker once the window is 90 percent spent, and a
reading nobody could take never refuses anything - it warns and dispatches. A missing tool, a lookup
that failed, an answer that will not parse and a reading the tool itself calls stale all pass
through. This is the same call the prompt-box guards already made for an unreadable screen: a blind
guard that blocks everything costs more than one that lets work through and says it could not see. A
reader that breaks must never make kingshand undispatchable.

**A settled "nothing here reports this" is quiet; a failed lookup warns.** The two are different
answers and the reader keeps them apart, which is the three-valued shape `Ci.psm1` already uses. An
account that genuinely reports no windows is a stable fact about the machine, and a warning on every
dispatch for a state nobody can act on teaches the reader to skip the next one. A lookup that did
not settle is something wrong, and it says so with the command that fixes it.

**Kingshand sums nothing, so it never has to choose which token counts to add.** The percentage
comes from the account's own windows as the tool reports them. Had it been computed here from
transcript tokens, the first decision would have been which of the four components to count - and
cache reads, two orders of magnitude larger than everything else and not billed like fresh input,
would have swamped the answer. Not computing it is what makes that question not arise.

**The worst window never decides.** An account has several windows and they do not all bound the
same thing. On the machine this was built on, the spend-limit window sits at 100 percent while the
session window is barely touched - so taking the worst of the list would have refused every dispatch
from the day it shipped. The tool publishes which windows bound every model and what is effectively
left across them, and that judgement is used rather than one made here. Only where it declines to
answer does the reader fall back to the five-hour session window on its own.

## The pulse, and why silence is the common case

One line: how much of the window is spent, how many workers are running, and a few words on each.
It speaks only when the fleet has moved or the percentage has crossed into a new ten-point band. A
line every interval regardless would be the progress narration hard rule 6 forbids, and the King
asked for this so he would not have to ask for updates - not so he would get a heartbeat.

One line is a hard cap, however many workers are live. Past three the tail becomes a count, and a
newline arriving through a worker's own name is stripped, because a pulse that wraps is one he has
to read twice.

A worker's phase comes from its recorded stage, which is a closed set of six words, and never from
its screen. A pane title is free text nobody wrote to a schema, and reading a phase out of it is the
open-ended scan the standing criteria forbid. A stage that is not recognised is reported as not
known rather than guessed at.

The pulse is the one thing here allowed a clock. A wait on a worker is an event and must never be a
loop - `muster` Step 4 owns that - but "nothing has changed for ten minutes" is not an event
anything can push, so the pulse polls and rides beside the waits rather than over them.

## The off switch is a person's word, not a setting

The pulse is on by default in every session. The rule lives in `CLAUDE.md` rather than in the
`vigil` skill, because a skill cannot invoke itself at session start and a rule that exists only in
an unloaded skill is not in force. That is the pattern `herald` already set for output shape.

The King turns it off permanently by writing a line in his own standing instructions, which are
injected in full at session start, so honouring it is the Hand reading its own instructions and
arming nothing.

**Nothing in `bin\` matches anything out of that file, and nothing may start.** It is free prose
written by a person and its case space is open, so a script matching a phrase in it is the kind of
parser that goes on producing review rounds because there is no round after which it is finished.
The session-start digest prints the file whole, which is the whole mechanism; a test pins that no
script under `bin\` puts a matching operator on a line that names it.

## What this deliberately does not do

It does not switch accounts, read a credential file, or call the account-switch script, and no code
path may be added that does. It does not resume work when the window resets - that belongs to other
work. And it adds no fourth thing a project's posture decides: the refusal sits ahead of dispatch
and applies to every project the same way.
