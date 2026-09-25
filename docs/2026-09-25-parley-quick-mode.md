# Parley, the quick-exchange mode - 2026-09-25

A three-line change was costing the ceremony of a three-hundred-line one: a rendered gate, a
findings table, a walkthrough, and a review gate that ran three and four rounds on changes of a few
lines. The preference had already been recorded once, in `data\king.md` on 2026-09-16 - "match the
ceremony to the size of the work" - and it arrived a second time as a request to build it. This
records what was decided, what was rejected on the way, and what a future change must not undo.

## Why it is its own skill and not a mode of `herald`

This was the one open design question and it looked settled the other way for a while. The King's
own correction - "no herald still apply to output, its just output is of 1-2 lines max" - says
parley is a length ceiling over herald's shape, which is an argument for it being a herald mode.

It is a sibling skill anyway, for two reasons.

**The deciding question is whether suppressing surfaces and shortening briefs is output shape at
all, and it is not.** Herald owns how a message reads. Parley also decides that nothing renders,
that a brief is written short, that a dispatch runs no review gate, that only the step asked for is
taken, and that a doubt is voiced rather than blocked on. Those are process and interaction rules.
Half of parley would have been about something herald has never governed.

**Herald's own contract forbids what parley does.** Herald says in as many words that it relaxes no
hard rule and touches no delivery posture, landing authority, or what may be done without the user.
Parley skips a review gate on a project registered to have one, which is a real safety reduction
the King authorised explicitly. Folding that into herald would have made herald's "what it never
does" section false - and that section is the thing stopping a reader treating brevity as
permission. The cost of a second skill is one more line in `CLAUDE.md`; the cost of the merge would
have been herald's own guarantee.

The spec anticipated this and set the condition: if it becomes its own skill, it must still state
that herald applies unchanged within it, or somebody will build it as a suspension. It does, in its
own section, and a test pins it.

## Why it is off by default, and what follows from that

`herald` and `vigil` are on in every session, so their rules have to live in `CLAUDE.md` where they
apply with no skill loaded - a rule that exists only in an unloaded skill is not in force. Parley
inverts that. It begins when the King says two words and the skill is loaded, and there is no
moment when the mode is in force and the file is not in hand. So the rules stay in the skill and
`CLAUDE.md` carries only the trigger, which is what the size discipline in `statute` asks for.

## Session-scoped, not a durable flag

A flag under `state\` like `.afk` would carry parley across a restart. It is held in the session's
own context instead, and the reason is which way each option fails.

Forgetting parley costs more ceremony than the King wanted: he says two words again. Remembering it
too long costs a safeguard - the Hand stays in reduced ceremony over work nobody called quick, and a
review gate goes on being skipped on a project registered to have one, silently. The mode is tied to
a burst of quick work, and a flag that outlives the burst recreates exactly the stranding the
announced exit exists to avoid.

That also settles what a context compaction does to it. Losing parley returns the Hand to the fuller
default, which is the safe direction for ceremony, and nothing has to be rebuilt to make that true.

It is not the safe direction for a dispatch already in flight, and that half needed building. A
brief written with no review gate outlives the session that wrote it, so a forgotten mode would
leave an ungated run looking like any other green branch - and on a project registered `+merge` it
would be merged as though it had been reviewed. So the constraint is attached to the work rather
than to the session: the brief carries a marker saying this dispatch ran no review gate and must not
be merged on the forge, the worker copies it into `report.md`, and muster Step 7 refuses the merge
on reading it. Both files are on disk, so the refusal holds through a restart with nobody
remembering how the work was dispatched.

## What was rejected

**A bounded override of hard rule 1.** The Hand proposed letting it make no-logic changes itself in
parley - one file, the diff shown, never pushed - and the King declined it: "we are complicating,
agent does the code writing, not you, no to hard rule 1 pass.. we will follow it, its just sub agent
will be quick to do it rather than taking its sweet time." **The reason was simplicity rather than
an objection to any particular safeguard**, which is what makes it worth recording: a
better-guarded version of the same proposal is the same proposal, and it has already been answered.

**Asking at the end of every reply whether the mode is still on.** Floated, and it defeats a
one-line answer. The exit conditions replace it: the mode ends at the first thing that is not
quick, announced in one line.

**Turning `herald` off inside parley.** Described that way once and corrected the same day. Parley
adds a ceiling; it replaces nothing.

## What the skipped review gate actually costs

Stated here rather than only in the skill, because the trade should survive the mode.

On this repository in one month the gate found a consent test that would have discarded real
approvals, a fix that contradicted itself five lines apart, a guard with four unhandled spellings,
and a fatal-return path that would have blocked a poll forever. Every one of those was on a change
of a few lines - the size parley is for. The King was told that plainly and answered "no review gate
in quick mode".

One thing keeps the absence visible rather than silent, and it does the work twice over. A parley
dispatch writes a marker into its brief saying it ran no review gate and must not be merged on the
forge, and its worker copies that line into `report.md`. Both files are durable, and muster Step 7
carries a floor that reads them and refuses the merge - on any posture and whatever `+merge`
declares, because nothing has established that a run with no review gate is safe to merge. Resting
the rule on Step 7's older gate check instead would have left it absent exactly where it read as
protection: that check lives on the `no-mistakes` limb alone, and the `direct-PR` limb requires no
gate at all. The King's own word is what moves it.

## What is enforced, and what is not

The one rule with no mechanism behind it is the exit, and it is the only one. A Hand that has
forgotten it is in parley will not announce leaving it. That is accepted, because for ceremony the
failure runs the safe way and because the only alternative - a durable flag - fails the other way.

Everything else has something. The absent review gate is an absence in the brief rather than an
instruction to abandon a run, which is the same shape as `--skip ci`: a constraint that has to hold
while an agent sits inside a long call is carried by a flag, never by a sentence the agent is not
reading. The no-merge rule is enforced rather than merely stated: muster Step 7 carries a floor that
refuses a forge merge while the brief and `report.md` say the run had no review gate, on any posture
and whatever `+merge` declares. That marker is durable, so the floor does not depend on anyone
remembering the mode, and it covers the `direct-PR` limb where Step 7 has no gate outcome to look
for. The reply ceiling and the step boundary are obeyed at a turn boundary, where prose is the only
mechanism there is.

## Out of scope, deliberately: one warm worker for a burst

Skipping the review gate removes the expensive half of the wall-clock. What it does not touch is the
cost of getting a worker at all - a worktree created, settings written, folder trust seeded, an
agent spawned and briefed, measured at one to two minutes before the worker had read anything. On a
genuinely one-line change that setup can cost more than the work.

One worker kept warm across several small exchanges would pay that once instead of once per change.
It is not built here and not designed for, because it trades against things that are settled: one
worktree per unit of work exists so that one diff is what the landing gate measures, and the durable
worker record maps one worker to one ticket. Ship the mode first, measure what the setup actually
costs against the work, and decide with a number rather than an expectation.
