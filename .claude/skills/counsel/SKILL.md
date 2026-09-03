---
name: counsel
description: Use when the user wants a story, a feature, or a pile of stories turned into work somebody can act on - e.g. "/counsel", "take counsel on this feature", "break this story down", "analyse these stories before we build", "brainstorm this with me", "split this epic into tasks", "where do these stories overlap". Divides the work by the layers that project actually has, names the edge cases before anyone writes code, and finds what the stories share so work touching one area lands in a single task. The King asks for it, and nothing launches it on his behalf.
user-invocable: true
version: 1.0.0
---

# Counsel

A king takes counsel before he commits men to work. This skill turns one story, or a whole
feature of many stories, into a decomposition somebody can act on: divided by the layers that
project actually has, with the edge cases named before anyone writes code, and with the overlaps
between stories found so work touching one area lands in a single task rather than three.

It ends at a decomposition the King has accepted. It never ends at a change.

## The King asks for this, and nothing offers it for him

**The guard is a rule, not a mechanism.** The Hand loads this skill only when the King asks for
it, and never beside an answer that is already good enough. The mechanical alternative was tried
and rejected: `disable-model-invocation: true` removes the skill from the Hand's own listing
entirely, so the Hand could not act on the King's request in his own words, and every situational
trigger in the description above would be dead.

**That is a resolution of a contradiction, not an oversight, and it is written down here so
nobody quietly reverses it.** Kingshand's own audit of an external plugin examined a brainstorming
skill built on one-question-at-a-time dialogue and concluded **not for us**, for three independent
reasons: hard rule 1 says the Hand routes and does not do; `CLAUDE.md`'s Intake judgement says
never to both present a likely-enough solution and launch a parallel design exercise that is not
expected to change it; and workers never address the user, so that dialogue cannot happen inside a
dispatch at all.

The King has asked for this skill, which settles whether it exists. It does not settle the
contradiction, so the resolution is stated instead: **the Intake rule binds what the Hand offers,
never what the King may ask for.** The Hand does not volunteer an analysis beside an answer that
is already good enough, and does not run one to look thorough. When the King asks for one, the
analysis is the work rather than a parallel exercise beside it. The third reason is structural, is
not resolved, and is designed around instead - that is the next section.
`docs\2026-09-04-story-analysis-split.md` holds the full record and what a future change must not
undo.

**An analysis authorises nothing.** `CLAUDE.md`'s Intake judgement already says a diagnostic
request, a report, a recommendation or an implementation-ready finding is evidence and not
authorization to change code, and that implementation is a separate dispatch through its own gate.
That applies to every word this skill produces.

### Who may start what

Two rules, and they are ranked:

1. **A counsel pass needs the King, whatever the posture.** The Hand never starts one on its own
   authority, and `+yolo` does not authorise one: a registered posture grants routine dispatch
   authority over work the King has asked for, and this pass is the asking.
2. **An ordinary dispatch is `muster`'s to gate, unchanged.** Where the King has asked for work
   and the ordering test below says its shape must be settled first, the investigation dispatch
   that follows goes through `muster`'s own dispatch gate and the project's posture exactly as any
   other dispatch does. **That is about the dispatch decision and nothing else** - this skill
   neither widens nor narrows that gate, and it says nothing about how the dispatch ends.

**Wherever both could be read to apply, rule 1 wins.**

**Close-out is the one place this skill does narrow, deliberately, and the close-out section below
says how and why.** An analysis dispatch has nothing to land and `muster` has no read-only path,
so rather than invent one this skill stops at the report and puts the close-out to the King. That
holds on a `+yolo` project too, because it is the safe direction: nothing is torn down that
nothing authorised, and hard rule 2 keeps destructive steps with the King whatever the posture.

## Two halves, and every step says which one it is in

The dialogue and the reading are different jobs done by different people, and the split is the
core of the design rather than a detail of it.

| The job | Whose it is | Why it cannot be the other's |
|---|---|---|
| Narrowing the problem, asking what is ambiguous, agreeing the division | the Hand, with the King | A worker never addresses the user, so it can ask him nothing |
| Opening the stories, the tickets and the code, finding what overlaps | a worker | Hard rule 1: the Hand routes, and never reads a project's source |
| Reading the written map, putting the decision to the King, recording his answer | the Hand, with the King | The decision is the King's, and only the Hand can reach him |

Hard rule 1 is not relaxed anywhere here. **A pass that has the Hand open the repository to see
how the stories divide has broken it**, however small the peek looked, and the fix is a worker
rather than one quick file.

## Step 1 - Narrow it with the King. This half is yours

Ask one thing at a time, and only the things whose answer changes the decomposition. Stop asking
when the next answer would not. Three answers are wanted before anything is dispatched.

**Which layers this project divides into.** This is a per-project fact and never a constant. One
project divides into front end, back end and database; the next into a device, a gateway and a
report; a third divides by service and does not think in layers at all. Read what the project
itself says - its own memory file carries its conventions, which `CLAUDE.md`'s Intake judgement
owns - and where nothing says, ask the King. **Where the project states no layer set and the King
is not there to answer, say the layer set is unstated and stop. Never fill it in from another
project, and never let a guessed set reach a brief.** A decomposition divided along layers this
project does not have is several wrong tasks wearing a tidy shape. Where the King states the
layers as a standing fact rather than an answer for today, that belongs in the project's own
memory file, which a worker writes through its delivery path and the Hand never writes -
Knowledge routing owns that.

**Where the edge of the work is.** What is deliberately not in this story. A boundary nobody
stated is the quiet widening this skill exists to prevent, and it cannot be recovered later from
the story text, because the story does not say what it is not.

**Where the decomposition is going.** The destination section below owns the answers.

File the analysis as its own work item before anything is dispatched, and keep the King's answers
in that item rather than in chat, which does not survive a session. `CLAUDE.md`'s Backlog
contract owns the queue.

## Step 2 - Commission the reading. This half is a worker's

`muster` owns intake, the brief, both gates, dispatch, close-out and teardown. Load it and follow
it; nothing here restates any of it. What is particular to an analysis is what its brief asks
for, and that is four parts of one written deliverable, in the worker's `report.md`:

1. **The division** - one section per layer the King named, and for each layer the work it holds,
   stated as tasks somebody could pick up and finish.
2. **The requirement ledger** - every requirement the worker read, each one marked as covered by
   a named task, judged ambiguous, or assumed with the assumption written out.
3. **The edge cases** - per layer, what happens when the input is empty, when it is at its limit,
   when the step before it failed, and when two of those land at once. Before anyone writes code,
   which is the point of doing this at all.
4. **The overlap map**, whenever there is more than one story. Its own section below.

Two things the brief must also say, because an analysis dispatch is unlike an implementation one:

- **It changes nothing.** Write the scope as reading only, and say so in the exclusions: this
  dispatch writes its own `report.md` and no other file. **Then say in one line which instruction
  wins: where the read-only scope and the pasted Done-means block disagree, the read-only scope
  wins** - `CLAUDE.md`'s Knowledge routing puts that call in the brief, and a worker left to choose
  between reading only and committing on the branch picks wrong half the time. An analysis that
  comes back with a commit has exceeded its brief.
- **Where two shapes are live, compare them.** Two or three approaches, their trade-offs, and a
  recommendation. That is the brainstorming half, and its own section below owns it.

### How an analysis dispatch ends, and what `muster` still lacks

Completion is `muster` Step 6's three-fact test, unchanged. The third fact - `report.md` exists -
is the deliverable itself here rather than corroboration for a diff, so a settled worker with no
report is exactly the case that step already refuses to advance.

Past that point `muster`'s lifecycle is written for work that lands or pushes. Every Done-means
block opens with committing on the branch, `gating` is the stage Step 6 sets and Step 7 is what
clears it, and Step 8b's teardown rule is written for work sitting in a worktree. An analysis
dispatch fits none of that, and **this skill does not invent a parallel lifecycle**, because
`muster` owns the lifecycle and a second owner of it drifts the moment either file is edited.

This is the narrowing "Who may start what" names above, and the reason is stated there rather than
twice. So until `muster` carries a read-only path: run the analysis as an ordinary dispatch, stop
at the report, read it, render the decomposition, and put the close-out to the King along with the
plain fact that the worker has nothing to land. Explicitly - **do not set a stage `muster` does not
define, do not tear the worker down on this skill's authority, and do not skip `muster`'s base-ref
verification in order to justify one.**

Closing this properly needs three things `muster` does not have yet: a Done-means block for a
dispatch that produces no commits, a terminal stage for one, and a teardown rule keyed on the
deliverable living outside the worktree rather than on a landing or a push. All three are a change
to `muster`, not to this skill, and `docs\2026-09-04-story-analysis-split.md` records why.

## Step 3 - The overlap map, and why the obvious shape fails

The overlap map is the part the King actually needs, and it exists to solve a context problem
rather than an analysis one.

The failure it answers is real and measured: seventeen stories sharing one or more areas, all
pasted into a single session so somebody could see where they touched, and the window ran out
before the reading did. That failure is why kingshand exists at all.

**Worker isolation alone does not fix it**, because somebody still has to hold all seventeen at
once to see an overlap at all. One worker per story is worse than useless for this question: each
worker sees one story, so no worker can see an overlap, and the Hand is left holding seventeen
reports instead of seventeen stories.

**The shape that works, and the one to use every time: one worker reads the whole set in its own
full window and writes back a short map. The Hand reads the map and never the stories.**

The map is short by contract, because a map as long as the stories has solved nothing:

- one line per shared area, naming the stories that touch it by their ids
- one line per collapse - these stories become one task, and why
- one line per story that shares nothing, so a story is never silently missing

Where one window cannot hold the set even so, the worker says in its report how it split the
reading, and it stays the worker's problem. Do not solve it by pasting the stories into your own
session, and do not solve it by giving each story its own worker. The overlap question is a
whole-set question, so it is one worker.

## What exact means here, in terms somebody can check

**A wrong decomposition is expensive in a way a slow one is not.** A slow one produces one late
task; a wrong one produces several wrong tasks that all look finished. So the analysis shows its
work rather than asserting it, and every claim below is checkable by a reader who has the report
and the story side by side.

- **Complete to the letter.** Every requirement in the story appears in the ledger. A requirement
  missing from the ledger is a requirement nobody read, and the ledger is what makes that visible
  instead of buried.
- **Not quietly widened.** A task doing something the story never asked for is named in the report
  as an addition, with who wants it, or it is dropped. Neither is a judgement the analysis makes
  on its own.
- **Ambiguity declared, never resolved quietly.** An ambiguity the analysis could not settle and
  the King has to is a decision, and `decree` owns what happens to it. It is filed before the
  analysis is treated as complete.
- **Assumptions written out.** Where the analysis proceeded on an assumption instead of stopping,
  the assumption is in the report in its own words, so a wrong reading is visible rather than
  inferred later from a task that came out strange.

## Brainstorming is part of this, and never a second skill

The King named brainstorming beside breakdown and analysis, and it is folded into this one skill
on purpose: two skills with overlapping descriptions means the wrong one loads, which `statute`'s
trigger hygiene owns.

Where the shape of the work is not settled, the analysis proposes two or three approaches with
their trade-offs and a recommendation, and the King chooses. That is a worker's written output,
not a conversation inside a dispatch - a worker cannot hold a dialogue, so what it produces is a
comparison with a recommendation, and the dialogue happens when the Hand puts it to the King.

Where the shape is already settled, do not manufacture alternatives to look thorough. Intake
judgement's simplest direct path still applies inside an analysis the King asked for.

## When a design question earns its own dispatch first

Kingshand already produces design comparisons inside worker reports. What it lacked was the
trigger, and this is it.

**This test fires only on work the King has already asked for, and all it decides is the order of
that work** - whether the shape has to be settled before an implementation dispatch, or whether
the implementation brief can be written now. It adds nothing beside an answer he already has, and
**it never starts a counsel pass on its own.** Where the shape needs settling, say so in one line
and let the King decide. The guard at the top of this skill is untouched by it.

This is where `CLAUDE.md` sends the Hand at intake, before an implementation brief is written for a
story or a feature. Posture does not enter into it: "Who may start what" above ranks the two rules
once, and this test changes neither of them.

**Dispatch an analysis before the implementation when any one of these is true:**

- the answer changes the task set - two shapes are live and they divide the work differently, so
  deciding after implementation starts means rewriting the tasks rather than finishing them
- the story cannot be divided without reading code nobody has read yet
- more than one story touches one area and nobody knows where
- an edge case's answer would change something outside this story - a contract, a schema, another
  layer

With none of them true, write the implementation brief and skip this entirely. Two dispatches
where one would do costs one dispatch; a wrong decomposition costs several wrong tasks, and that
is the whole reason the test leans this way.

**This trigger covers a story or a feature and nothing else.** For a reported bug the equivalent
already exists elsewhere: `inquest` owns the diagnosis procedure, and `CLAUDE.md` already says a
diagnosis is evidence rather than authorization. Neither is restated here.

## Nothing here parses a story

A story is free-form prose written by a person, and its case space is not closed. **Nothing in
this skill extracts structure from story text with a regex, a line scan or a hand-written parser.**
This skill tells a reader how to read a story; the reader reads it. A parser for prose has no
round after which it is finished, which this repository has already paid for several times over.

The machine-read inputs stay the bounded ones kingshand already has: the registry through
`bin\Projects.psm1`, the queue through `tasks-axi`, and a work item through the tooling that owns
it where a machine has one at all.

## Where the decomposition goes

The output is a decomposition. Where it goes is a separate question, and the default answer needs
nothing installed: each accepted task becomes a work item through `tasks-axi`, and the analysis
itself stays in the worker's `report.md`, which survives teardown. `CLAUDE.md`'s Backlog contract
owns the queue.

**A ticket system is not assumed.** Azure DevOps is an optional integration and absent by
default; `muster` Step 1 owns what happens when it is not there, and this skill adds nothing to
that.

Whatever the destination, hard rule 3 holds for every word that reaches it: nothing landing in a
ticket, a commit message or a pull request names an agent or its tooling. Write the decomposition
in the words the reader would use for their own work.

## Step 4 - Then render it, and stop there

A decomposition is something the King scans, compares and decides on, so it renders rather than
growing a chat message - hard rule 5, and `bin\Render-Review.ps1` is the renderer `muster`'s
gates already invoke. Chat carries one line and the link. Where lavish is unreachable, ask which
surface he wants rather than rendering to one he cannot open.

**Nothing is dispatched by having been read.** Each task in an accepted decomposition is its own
unit of work through `muster`, with its own dispatch gate and the project's own posture deciding
it. An accepted decomposition is a queue, not a licence.

## Generic on purpose

This skill ships to strangers, so it carries no project's layer set, no product name and no real
story as an example. Anything particular to one project - its layers, its vocabulary, its
stories - lives with that project: its own memory file, or `data\`, which is gitignored. A layer
set written into this file would be wrong for the next reader and invisible to them until their
decomposition came out wrong.
