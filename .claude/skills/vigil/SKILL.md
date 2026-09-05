---
name: vigil
description: Owns the usage pulse, and it is on by default - one line saying how much of the usage window is spent and what each live worker is doing, printed only when something has changed. Load this only to change that: when the user asks what the pulse is, asks to turn it off or back on for this session, asks for a different cadence, asks why they have heard nothing, or invokes /vigil. Also holds why a dispatch is refused near the limit and why an unreadable usage reading never blocks one.
---

# Vigil

A vigil watches through the night and speaks only when something happens.

**The pulse is the default. It is already on, in every session, without this skill being loaded.**
The rule lives in `CLAUDE.md`'s Escalation and etiquette section so it applies whether or not anyone
reads this file - a rule that only exists in an unloaded skill is not in force. Nothing here
auto-invokes at session start and nothing can: a skill loads when the Hand loads it, which is why
the standing behaviour is stated where it is rather than here.

This skill exists for four things: what the line means, the switch that turns it off, the refusal
that fires near the limit, and why an unreadable reading never blocks work.

## The line

One line, hard cap, however many workers are live:

```
62% used (session, personal) - 2 running: kh-usage-watch running checks, emgee-seo waiting on you
```

The percentage of the current usage window that is spent, which window that is and which account it
belongs to, how many workers are running, and a few words on each. Where more workers are live than
fit, the tail becomes a count - `+3 more` - rather than a second line.

**Two windows are watched, not one, and the line names whichever is nearer its limit.** An overnight
run sits comfortably inside the five-hour session window while burning the week, and the weekly
window resets in days rather than hours, so tripping that one costs far more.

**The account is named because the reading silently follows it.** The percentage always describes
whichever account is active at the time, so a switch changes which pool it is about with nothing
otherwise visible. Two readings either side of a switch are never compared - the pulse speaks again
instead, because silence would say they were one quota sitting still.

**A cached reading is said as a floor, never as a measurement:**

```
at least 41% used (stale, session, personal) - 1 running: kh-usage-watch working
```

That is the shape when the tool's own live fetch failed and it answered from cache. Consumption
never falls inside a window, so the cached figure is a lower bound - true, but not current. It is
said as "at least" and rounded down, because rounding a lower bound up claims more than the reading
supports: at a true 41.2, "at least 42%" is a sentence the evidence does not carry. Nothing is
guarded by these digits - the refusal compares the exact figure, never the rounded one.

Three things it never does. It never invents a percentage: where nothing could be read at all the
line opens `usage unknown` and says nothing more confident than that. It never invents a phase: a
worker whose phase cannot be worked out is reported as `phase not known` rather than guessed at or
quietly dropped. And it never speaks when nothing has changed - a silent interval is the pulse
working, not the pulse broken.

**Relay it as it comes.** It is already written in the King's nouns, so it needs no translating, no
preamble and no sentence around it. A pulse the Hand paraphrases into a paragraph is the progress
narration hard rule 6 forbids, arriving by the back door.

## Arming it

One background job per session, armed once, in the shape `muster` Step 4 already uses for worker
waits:

```powershell
Import-Module $env:KINGSHAND_HOME\bin\Usage.psm1
Watch-UsagePulse
```

**A harness-tracked background job, never with `&` and never as a detached process.** An untracked
process reaches nobody, which is the same failure as a wait nothing is watching.

Ten minutes between pulses by default. `-IntervalMinutes` changes it for a session that wants a
different cadence, and `bin\Usage.psm1` owns every other parameter and what it does.

This one polls on a timer, and that is not the worker-wait rule being broken. A wait on a worker is
an event and must never be a loop - `muster` Step 4 owns that. "Nothing has changed for ten minutes"
is not an event anything can push, so the pulse is the one thing here that is allowed a clock, and
it rides beside the waits rather than over them.

## Turning it off, and back on

Off when the user asks - "stop the pulse", "no usage updates", "quiet", `/vigil off`. Confirm in one
line and arm nothing for the rest of the session. Back on when they ask. Neither survives the
session, because the default is on.

**Permanently off is a line in `instructions.md`**, which is theirs to write and the Hand's to read.
That file is injected in full at session start, so honouring it is the Hand reading its own
instructions and arming nothing - it is not a setting, not a flag, and not a file anything greps.

**Nothing in `bin\` matches a phrase out of `instructions.md`, and nothing may start.** The
session-start digest prints that file whole, which is the entire mechanism and the only handling of
it there is. It is free prose written by a person and its case space is open, so a script matching a
phrase in it is exactly the open-ended scanner the standing criteria forbid - the kind of parser
that goes on producing review rounds because there is no round after which it is finished. The
switch is a person's word, read by the Hand.

The Hand cannot put that line there for them. Where a session teaches you it belongs there, say so
and let the King write it.

## The refusal near the limit

Dispatch refuses a new worker once the usage window is 90 percent spent, and says so by name so the
Hand can relay it. `bin\Dispatch-Worker.ps1` owns the threshold and the wording; the reason is that
a worker started into the last few percent of a window dies mid-run and leaves the work half done,
and that refusing before anything is created costs a message where refusing later costs a worktree,
a branch and a session.

**It fails open on a reading nobody could take, deliberately.** A missing `quota-axi`, a lookup that
failed and an answer that would not parse all warn and dispatch anyway. This is the same call the
prompt-box guards already made for an unreadable screen: a blind guard that blocks everything costs
more than one that lets work through and says it could not see. A reader that breaks
must never make kingshand undispatchable.

So there are three answers and not two, and the third is the point: a percentage that was read, a
settled "nothing here reports this", and a lookup that did not settle. Only the first ever refuses
**as a measurement**.

**A stale reading is the one unknown that can still refuse, and it refuses on its floor rather than
on its number.** The cached figure is never passed off as current - that is the failure that put 10
percent in front of the King when the truth was 42 - so it never becomes a percentage. But
consumption never falls inside a window, so it is a true lower bound. Where that floor alone is
already at or past the threshold, the real figure is too, and the dispatch is refused with a message
that says plainly it refused on a floor and when the window clears. Below the threshold it warns and
goes ahead like every other unknown. On this machine the tool's live fetch is rate limited most of
the time, so most readings are stale and this is usually the only guard there is.

## What it never does

- **It never blocks a dispatch because the reader broke.** A missing tool, a lookup that failed and
  an answer that would not parse all warn and go ahead. The one refusal without a current reading is
  a stale floor already at or past the threshold, which is a lower bound on the real figure rather
  than a guess at it. See above.
- **It never switches accounts and never reads a credential.** It reads the active account's *name*,
  from one file holding one word, because a percentage with no pool attached cannot be placed.
  Nothing here opens a credential file or calls the account-switch script, and no code path may be
  added that does.
- **It never resumes work when the window resets.** That belongs to other work and is not wired in
  here.
- **It never narrates progress.** A pulse that spoke every interval regardless would be exactly the
  thing hard rule 6 forbids, which is why silence is its common case.
- **It relaxes no hard rule.** Nothing here touches delivery posture, landing authority, or what may
  be done without the user.
