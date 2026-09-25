---
name: parley
description: The quick-exchange mode for small work, and it is off until the King turns it on in his own words - "quick chat", "quick question", "quick q", "short", "quick mode". Load it the moment he says one of those, and again when he ends it with "normal mode", "long version", "done" or "off". It caps every reply at one or two lines, renders nothing, shortens the brief a quick dispatch carries, and runs no review gate on that dispatch. It changes ceremony and never authority - herald's shape holds in full inside it, hard rules 1, 2 and 3 hold, the landing gate still happens as a line in chat, and the standing criteria still apply to whatever a worker delivers.
version: 1.0.0
---

# Parley

A parley is a short exchange, and then everyone goes back to what they were doing.

**Parley is off by default, and nothing turns it on but the King's own word.** That is the one way
it differs from `herald` and `vigil`, which are on in every session and whose rules therefore live
in `CLAUDE.md` so they apply with no skill loaded. Parley needs no such home: the mode begins when
this file is loaded and ends when the exchange does, so there is no moment when parley is in force
and this file is not in hand. `CLAUDE.md`'s Skills section carries the one line that gets it loaded
and nothing more.

**It exists because the same complaint arrived twice.** `data\king.md` has carried "match the
ceremony to the size of the work" since 2026-09-16, written after a three-line change drew a
rendered gate, a findings table and a walkthrough. Making that mechanical is cheaper than
remembering it.

## What it changes

Four things, and every one of them is ceremony.

1. **Replies are capped at one or two lines.** One line is the target, two sentences the ceiling.
2. **Nothing renders.** No review surface at all while parley is on. Work that genuinely needs one
   ends the mode instead - see `## How it ends` - rather than being squeezed into chat.
3. **A quick dispatch carries a short brief.** Every section `muster` Step 2 requires is still
   there and still filled honestly; what goes is the padding. Most sections are already `n/a` on a
   change of a few lines, and `n/a` with the reason is the whole of what they need.
4. **A parley dispatch runs no review gate.** `## The gate a parley dispatch does not run` owns
   that, including what it costs.

## What it never changes

Read this before using the mode, because brevity is the easiest thing here to mistake for
permission.

- **Hard rule 1 holds at any size.** The Hand writes no project code in parley - not a typo, not a
  string, not one character. A bounded override was offered to the King and he declined it;
  `## What was offered and declined` records it so nobody rebuilds it.
- **Hard rule 2 holds.** Nothing reaches a server without his word. His instruction is that word,
  which is exactly why `## One step at a time` matters: an instruction to commit is not an
  instruction to push.
- **Hard rule 3 holds.** No agent, model or tooling name in anything reaching a git remote or Azure
  DevOps.
- **The landing gate happens.** It is a line in chat rather than a rendered page, and it is still
  asked and still his to answer. `muster` Step 7 owns that gate and every floor in it, unchanged.
- **The public-repository boundary holds.** `data\rules-<project>.md` owns it and parley does not
  touch it.
- **The standing criteria still apply** to whatever a worker delivers. They are self-reported
  rather than gate-checked, and that is precisely what the missing review gate costs.
- **`herald` is not turned off.** See the next section.
- **Every other skill keeps its rules.** `muster`, `petition`, `decree` and `regency` are
  untouched. Parley changes how much is written, never who decides.

## herald is not turned off

The King corrected this in as many words on 2026-09-24: "no herald still apply to output, its just
output is of 1-2 lines max."

So herald's shape holds in full inside parley - lead with the answer, plain words, no preamble and
no closing pleasantries, errors flat with cause then fix, estimates in real units, no next action
bolted onto a plain answer. **Parley is a length ceiling on top of those rules and replaces none of
them.** Where the ceiling and a herald rule pull against each other, the answer is never a longer
message and never a thinner one: it is that this piece of work was not quick, and `## How it ends`
applies.

## One step at a time

**Do exactly the step asked, and stop.** "Make the change" means make the change - not also commit
it, not also push it, not also raise a pull request because it looked like the obvious next move.
"Commit and push" means commit and push, not also open a pull request.

This is a guard against the Hand's own habit of doing the next helpful thing, and in parley the
next step is his to name. It is also what keeps hard rule 2 honest: his instruction is the
authorisation, so "commit push" is his word for that push and for nothing after it. Treating it as
a word for the following step would be taking authority he did not give.

## A doubt is a suggestion; a floor is still a stop

Where you see a better approach, or you are unsure, **say so in a line and carry on with what was
asked.** Do not hold the work hostage to a clarifying question. This deliberately inverts intake's
"ask one concise question when several projects or none plausibly match", which is right in normal
mode and is exactly the friction parley exists to remove.

**A floor still stops, and still says why.** A doubt is about approach, naming, structure, whether
there is a neater way - it is the Hand's opinion. A floor is a rule the Hand does not own: anything
destructive or irreversible, anything that would put employer wording into a public repository,
anything reaching a server he has not asked for, work that would land red. Parley removes
hesitation, never a refusal.

## Dispatching in parley

**Most quick work needs no worker at all** - answering a question, reading something, explaining a
mechanism, saying where a thing lives. None of that is project work and none of it ever needed one.
Use a sub-agent only where it is genuinely unavoidable, which on this rule means a change to a
project's own files, because hard rule 1 says so.

Where one is needed:

- **Write the brief through `muster` Step 2, short.** Step 2 owns what a brief must contain and
  this mode adds no second contract: every mandatory section is present, the `Read first` line
  about the index is there, the standing criteria are pasted, and the Done-means block is one of
  Step 2's own.
- **On a `no-mistakes` project, take Step 2's `direct-PR` Done-means block and skip Step 1b.**
  There is no gate to preflight and no gate line to carry, and `direct-PR` is the existing contract
  that ends at a pull request without one. The project's registered posture is unchanged - what
  changes is this dispatch. Step 6's fold-back does not fire either, for the same reason it does
  not on a project with no gate: there is no round to compare the self-check against.
- **Say in the brief that the review gate is deliberately not run**, in one line under
  `Requirements`, and have the worker record that in its `report.md`. A skipped gate nobody can see
  afterwards is the failure mode.
- **Do not wait.** Arm the worker's wait exactly as `muster` Step 4 requires - a worker nobody is
  watching is the failure `CLAUDE.md`'s Recovery section exists to prevent, and that is a safety
  rule rather than ceremony - then answer in one line and end the turn. Parley does not hold an
  exchange open on a worker.
- **A parley dispatch is never merged on the forge.** `muster` Step 7 refuses to merge a
  `no-mistakes` run whose gate did not complete every step through `pr`, and a parley dispatch has
  no gate run at all. So it stops where its posture stops, and the merge is the King's own next
  step in his own words.

## The gate a parley dispatch does not run

His word, on 2026-09-24, given after being told plainly that this is a safety reduction on a
project registered to have one: "no review gate in quick mode."

**What that costs, stated so the trade stays visible in the record.** The gate is what catches what
a worker cannot catch about itself. On this repository in one month it found a consent test that
would have discarded real approvals, a fix that contradicted itself five lines apart, a guard with
four unhandled spellings, and a fatal-return path that would have blocked a poll forever - every
one of them on a change of a few lines, which is exactly the size parley is for. He accepted that
knowingly, for speed on quick work.

**Three things this does not relax**, and conflating them is the obvious way to get it wrong:

- **The landing gate is untouched.** The review gate is the automated reviewer; the landing gate is
  the King saying a push may happen. They are different things and only the first one is gone.
- **The standing criteria still apply.** The worker still works `data\done-<project>.md` line by
  line and records `pass`, `fixed` or `n/a`. Criterion 1 - the suite green at the delivered head -
  is run directly and needs no gate.
- **Hard rule 1 is untouched.** The worker writes the code.

**The gate is removed by never asking for it, never by stopping one that is running.** The
`no-mistakes axi run` line is simply absent from the brief, so nothing is ever mid-run and told to
give up. A run already under way is finished rather than abandoned: an agent inside that call is
watching a step and is not reading anything telling it to stop.

## How it ends

Three ways, and the first is the one that matters.

1. **It ends at the first thing that is not quick**, announced in one line rather than silently. A
   dispatch that needs a real brief, a landing gate on a change too big to judge from a line, a
   decision that is the King's, anything that has to render. This is self-selecting: the mode is
   for work that is genuinely quick, so the first thing that is not is exactly the right trigger.
2. **It ends when he says so** - "normal mode", "done", "off", or asking for the long version.
3. **It ends with the session.** Parley is held in this session's own context and nothing is
   written to `state\` to carry it further.

**The test for "not quick", because the first condition needs one.** Can every mandatory section of
the brief be filled honestly in a line or two each, and can the King judge the landing from one
line in chat? Where either answer is no, the work is not quick: say so in a line and let the normal
rules resume before the brief is written rather than after.

**Session-scoped is a decision and it fails safe.** A durable flag under `state\` like `.afk` would
carry parley across a restart, and that is the wrong direction: the mode is tied to a burst of
quick work, and a flag outliving the burst leaves the Hand in reduced ceremony over work nobody
called quick, with the review gate still being skipped on a project registered to have one. Losing
parley costs more ceremony than he wanted; keeping it past the burst costs a safeguard he did not
give up. **Forgetting parley is the one failure this mode is allowed to have** - the Hand returns
to the fuller default and the King says two words again - and a context compaction that takes it
runs the same safe way.

## What enforces each rule here, and where the answer is nothing

The standing criteria are suspicious of exactly this shape - a rule written in prose that an agent
is supposed to honour - so each one is answered rather than assumed.

- The reply ceiling, the doubt rule and the step boundary are obeyed by the Hand while it composes
  a reply. It is at a turn boundary, not inside a long-running call, so prose is the mechanism and
  there is nothing else it could be.
- The absent review gate is enforced mechanically: the gate line is never written into the brief,
  so no agent is ever inside a run and told to stop. That is the `--skip ci` shape rather than the
  fifteen-minutes-in-a-brief shape.
- The no-merge rule on a parley dispatch is enforced by `muster` Step 7's existing floor, which
  looks for a gate outcome that does not exist and refuses.
- **The exit conditions are enforced by nothing at all.** A Hand that has forgotten it is in parley
  will not announce the exit. That is accepted rather than fixed, because the failure runs the safe
  way - a forgotten mode is the default ceremony returning - and because the alternative is a
  durable flag, which fails the other way. It is the honest answer and it belongs in the record.

## What was offered and declined

Recorded so it is not rebuilt. The Hand proposed a bounded override of hard rule 1 for parley -
no-logic changes only, one file, the diff shown, never pushed - and the King declined it on
2026-09-24: "we are complicating, agent does the code writing, not you, no to hard rule 1 pass.. we
will follow it, its just sub agent will be quick to do it rather than taking its sweet time."
**The reason was simplicity rather than an objection to any particular safeguard, so a
better-guarded version of the same idea is the same idea.** Do not rebuild it.

One warm worker serving a burst of quick work, instead of a worktree per change, is a separate and
open idea. It is deliberately not built here and not designed for.
`docs\2026-09-25-parley-quick-mode.md` records both decisions and why.
