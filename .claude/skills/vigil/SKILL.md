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
62% used - 2 running: kh-usage-watch running checks, emgee-seo waiting on you
```

The percentage of the current usage window that is spent, how many workers are running, and a few
words on each. Where more workers are live than fit, the tail becomes a count - `+3 more` - rather
than a second line.

Three things it never does. It never invents a percentage: where the reading could not be taken the
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
failed, an answer that would not parse and a reading the tool itself calls stale all warn and
dispatch anyway. This is the same call the prompt-box guards already made for an unreadable screen:
a blind guard that blocks everything costs more than one that lets work through and says it could
not see. A reader that breaks must never make kingshand undispatchable.

So there are three answers and not two, and the third is the point: a percentage that was read, a
settled "nothing here reports this", and a lookup that did not settle. Only the first ever refuses.

## What it never does

- **It never blocks a dispatch on an unreadable reading.** See above; this is the whole design.
- **It never touches accounts.** It reads how much is spent and stops there. Nothing in this
  watches credentials, switches accounts, or calls the account-switch script.
- **It never resumes work when the window resets.** That belongs to other work and is not wired in
  here.
- **It never narrates progress.** A pulse that spoke every interval regardless would be exactly the
  thing hard rule 6 forbids, which is why silence is its common case.
- **It relaxes no hard rule.** Nothing here touches delivery posture, landing authority, or what may
  be done without the user.
