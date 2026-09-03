# Story analysis - the dialogue and the reading are two different jobs

2026-09-04

## What was asked for, and what already said no to it

The King asked for a way to take a story, or a whole feature of many stories, and turn it into a
decomposition somebody can act on: divided by layer, edge cases surfaced before anyone codes,
overlaps between stories found so work touching one area lands in one task. He named
brainstorming alongside breakdown and analysis, and pointed at an external plugin's own
brainstorming skill as reference.

Kingshand had already examined that skill and rejected it. The audit at
`data\kh-superpowers-audit\report.md` concluded **not for us**, for three independent reasons:

1. Hard rule 1 - the Hand routes and does not do.
2. `CLAUDE.md`'s Intake judgement - "never both present a likely-enough solution and launch a
   parallel design exercise that is not expected to change it", and "start with the simplest
   direct path".
3. Workers never address the user, so a one-question-at-a-time dialogue cannot happen inside a
   dispatch at all.

The King asking for the skill settles whether it exists. It does not settle any of those three,
and a skill that quietly routed around them would be a rule reversed by accident rather than
decided. So each one is answered here, and `.claude\skills\counsel\SKILL.md` is the operative
owner of every rule that came out of it.

## Reason 3 is structural, and it is what shaped the design

The third reason cannot be argued with. A worker runs detached and cannot ask the King anything,
so the dialogue a brainstorming skill is built around is not available inside a dispatch. Nor can
the Hand simply hold that dialogue and do the work itself, because reading a project's stories,
tickets and code is exactly what hard rule 1 gives to a worker.

That is not a deadlock, it is a split, and it is the design:

- **The dialogue belongs to the Hand**, because only the Hand can reach the King. Narrowing the
  problem, asking what is ambiguous, agreeing the layer set and the boundary, putting the result
  to him.
- **The reading belongs to a worker**, because it is a project's own material. Opening the
  stories, the tickets and the code, and writing back a map the Hand reads.

Every step in the skill says which of the two it is in, for one reason: a pass that has the Hand
open the repository "just to see how it divides" has broken hard rule 1, and the shape of that
mistake is a small one nobody notices.

## Reason 2 is answered by who may ask, not by weakening the rule

The Intake rule stands unchanged. What it forbids is the Hand volunteering a speculative design
exercise beside an answer that is already good enough. It says nothing about the King asking for
an analysis, which is an ordinary request for work.

So the skill is **user-invoked only, and the guard for that is a written rule rather than a
mechanism**: the Hand loads it when the King asks and never volunteers it beside an answer that is
already good enough. The Intake rule keeps its full force over what the Hand offers, and the King
keeps the ability to ask. Nothing here reverses a rule the King wrote.

The mechanical option was tried and rejected, and the evidence is worth keeping.
`disable-model-invocation: true` in the frontmatter does not merely stop the Hand volunteering the
skill - it removes the skill from the Hand's own listing entirely. With the key set, counsel was
the only one of the fifteen skills missing from a session's invocable-skills listing in this
repository, so the Hand could not have followed `CLAUDE.md`'s own instruction to invoke it when the
King asks, and every situational trigger in the description - "break this story down", "brainstorm
this with me" - was dead. `statute`'s trigger hygiene requires a description that fires on the
situation and not only on a slash command, and the key defeats exactly that. So the key is absent,
the description carries the triggers, and the restriction lives in prose in both `CLAUDE.md` and
the skill, as it already does for `survey`, `chronicle` and `update`.

Reason 1 is answered by the same split as reason 3: the Hand routes the analysis and a worker
performs it, exactly as with any other work.

## The overlap map, and the context failure behind it

The feature the King actually needed is the overlap map, and it exists to solve a context problem
rather than an analysis one. The real case was seventeen stories sharing one or more areas. They
were pasted into a single session so somebody could see where they touched, and the context window
ran out before the reading was done. That failure is why kingshand exists at all.

Worker isolation on its own does not fix it. Somebody still has to hold all seventeen stories at
once, because an overlap is a property of the set and not of any story in it. That rules out the
shape which otherwise looks obvious here - one worker per story - because each worker would see
one story and none of them could see an overlap, leaving the Hand holding seventeen reports
instead of seventeen stories.

The shape that works is one worker reading the whole set in its own full window and writing back a
short map, with the Hand reading only the map. The map is short by contract - one line per shared
area, one line per collapse, one line per story that shares nothing - because a map as long as the
stories has moved the context problem rather than solved it.

**What a future change must not undo:** the map's size contract, and the rule that the Hand reads
the map rather than the stories. Both are what keep the seventeen-story case inside one window.

## The trigger the audit said was missing

The audit found that kingshand already produces design comparisons inside worker reports, and that
what it lacked was a trigger saying when a design question deserves its own investigation dispatch
before an implementation dispatch. That trigger now lives in `counsel`, as a four-part test, and
`counsel` is its only owner.

The trigger is scoped, and the scope is load-bearing: it fires only on work the King has already
asked for, and all it decides is the order of that work - whether the shape must be settled before
an implementation dispatch. **It never starts a counsel pass.** Without that scope it reads as a
licence for the Hand to begin an analysis on situation match, which is the parallel design
exercise Intake judgement forbids and the guard at the top of the skill prohibits. The authority
rules themselves live in one ranked block in the skill, "Who may start what", so a pair of them
can never sit unranked again - that ambiguity is what this trigger produced the first time round.

It was placed there rather than in `muster` because the situation it fires in is a story that has
not been divided yet, which is what `counsel` is loaded for. It was deliberately **not** extended
to reported bugs: `inquest` already owns the diagnosis procedure, and `CLAUDE.md` already states
that a diagnosis is evidence rather than authorization to change code, so a bug-shaped copy of the
trigger would be a second owner of a rule that has one.

## The read-only close-out is deliberately left open

`muster`'s lifecycle is written for work that lands or pushes, and an analysis dispatch produces
no commits at all, so nothing in it says how such a dispatch ends. Three pieces are missing:

- **A Done-means block for a dispatch that produces no commits.** All four of the blocks
  `muster` generates open with committing on the worktree's branch, and it forbids inventing a
  fifth. An analysis brief written today therefore carries a delivery instruction that
  contradicts its own read-only scope, in the one section the worker is judged against.
- **A terminal stage for one.** Step 6 sets `gating`; `ready` needs the branch on the remote and
  `landed` needs a merge, so neither is reachable with zero commits. The worker's record sits at
  `gating` with nothing live behind it, which `survey` reports to the King as needing him.
- **A teardown rule keyed on where the deliverable lives.** Step 8b turns on landing or push
  evidence, because normally the worktree is the only copy. Here the deliverable is `report.md`,
  which sits outside the worktree and survives teardown, so the rule's reason does not apply -
  but the rule is absolute and `counsel` may not except itself from it.

`counsel` was not allowed to supply any of them. `muster` owns the lifecycle, and a skill that
writes a second one becomes a second owner that drifts the moment either file is edited - which is
exactly what a first attempt here did, each patch to it exposing the next assumption `muster`
makes about work that lands. So `counsel` states the gap, forbids working around it, and stops:
an analysis runs as an ordinary dispatch, ends at the report, and the King is told the worker has
nothing to land. Closing it is a change to `muster`.

## Deliberately not built

**No story parser.** A story is free-form prose and its case space is not closed. This repository
has paid roughly twenty-two review rounds across three tasks for hand-written parsers of
open-ended formats, which is why the standing criteria carry a line about it. The skill tells a
reader how to read a story and extracts nothing from it mechanically.

**No second skill for brainstorming.** It is folded into `counsel`, because two skills with
overlapping descriptions means the wrong one loads.

**No hardcoded layer set.** Which layers a project divides into is a per-project fact the skill
reads or asks for. This repository is public, the skill ships to strangers, and a layer set
written into it would be wrong for the next reader and invisible to them until their decomposition
came out wrong.
