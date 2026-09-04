# A worker parked on a decision, and the route the answer takes back

Date: 2026-09-04
Status: **current**

## What this records

A worker that reaches a decision its brief did not settle stops, writes the question into its
`report.md`, and ends its turn. The Hand then decides it or escalates it, and sends the answer back
into the same live worker so the review-gate run it left parked can carry on.

The route itself is owned by the skills - `muster` Step 6 for the read and the send, `decree` for
the hold's lifecycle, `petition` for who may answer, `rally` for what a parked worker looks like to
anyone triaging a stall. This note is not a second copy of any of that. It records why the shape is
what it is, and what a later change must not quietly undo.

## The state lives in the hold, plus one nullable pointer

The decision is a `tasks-axi` hold. The worker's record in `state\crew.json` carries one nullable
field, `waiting_on`, holding that hold's key and nothing else.

**Two sources, each owning one half.** The pointer says *which* decision this worker parked on. The
hold says whether that decision is still outstanding, and its closing note says what was decided.
Neither can answer the other's half, and that is the point: a single source would have to be kept
correct in two directions by whoever happened to be editing it, and the route has to survive a
restart, a compaction, and a session that dispatched nothing.

### Why not a seventh stage

The six stages - `dispatched`, `implementing`, `gating`, `ready`, `landed`, `failed` - are a
lifecycle. A worker is at exactly one of them and moves forward through them. Waiting for a
decision is not a position in that lifecycle; it is a condition that can happen at any of them and
then resolves back to wherever the worker already was.

A `waiting` stage would therefore have to overwrite the stage it interrupted, destroying the one
fact most needed when the answer comes back: what the worker was doing before it parked. Restoring
it afterwards means remembering it somewhere else, which is the second source all over again. So
the stage is left exactly where it was and the pointer is added beside it.

The cost of that choice is real and was accepted: because the stage does not move, `dispatched` and
`implementing` are also what a worker steered an hour ago still reads, so nothing downstream may
infer from the stage whether the parked read has happened. `muster` Step 7 states that as an
instruction rather than leaving it to be worked out.

### Why there is no clearing verb

`Set-CrewWaitingOn` sets the field. Nothing clears it, and no function to clear it may be added.

Once a worker parks, the field keeps naming that hold for the rest of the worker's life - including
after the answer arrives and the worker carries on. Clearing it on the way back out would put two
opposite meanings on one null:

- a worker that never parked, which must be read for a question nobody has registered yet; and
- a worker that parked, was answered and carried on, which is a finished delivery.

Read as one value, either the question is lost or already-delivered work is refused and the King is
asked the same thing twice. So **null means never parked and nothing else**, and whether a set
pointer's decision is still outstanding is read from the hold. Parking a second time replaces the
key rather than clearing it: the pointer is a link to the current decision, not a log of them, and
the earlier decision stays durable as its own closed hold carrying the answer it was given.

`Import-CrewState` gives every record the field whether or not the file was saved with one, so
"absent" never becomes a third case for a reader to handle.

## Why the fixed report heading was the wrong place for this

The first shape of this route had no field at all. The worker wrote a `## Waiting on a decision`
heading into `report.md` and the Hand read the state out of that heading.

**The evidence against it is the review history of the change that introduced it.** The state was
prose over a free-text file, so every review round turned up one more shape nobody had listed - an
empty section, a worker parked twice, an answer with no record, a decision the worker had settled
for itself under the assumption hatch its own brief grants - and each one needed another rule for
reading the prose. By the end, the rules for reading the heading were longer than the route they
served, and they still were not exhaustive, because a free-text file has no closed set of shapes to
enumerate.

A field has no shapes. It is set or it is null, and the two irreversible guards below can read it
without a parser and without a rule for what a malformed section means.

The report did not lose anything by this. It still carries the question, the reasoning and what the
worker recommends, which is what prose is genuinely good for. It stopped being where the system
reads *whether*.

**Putting the state back into the report is a reversal, not a tidy-up.** A reader who finds
`## Waiting on a decision` in this repository's history should read it as superseded rather than as
a rule that went missing.

## What a future change must not undo

### The two irreversible floors

Both refuse an action that cannot be taken back, over a worker whose work is not finished:

- **A worker whose pointer names a hold that is still open is never landed.** It is mid-run
  whatever its branch shows. `muster` Step 7 owns the rule.
- **A worker whose pointer names a hold that is still open is never torn down**, and a confirmed
  push does not release that. Teardown ends the live process, and that process is what the answer
  is coming back to. `muster` Step 8b owns the rule, and `rally` carries the same refusal for the
  stop-and-relaunch path, because a parked worker's motionless screen is indistinguishable from a
  stalled one until Step 6 has been asked. `rally` refuses; it does not carry its own test for
  whether a worker is parked, and a version of it that grows one is drifting back toward the
  three rounds of dropped qualifiers that produced this arrangement.

**The two floors above and `rally`'s refusal are scoped differently, and that is deliberate rather
than an inconsistency to reconcile.** They do not protect the same thing.

`rally`'s refusal protects the live process holding a parked review-gate run, so liveness is exactly
its condition. **A parked worker whose process is gone is escalated rather than recovered**, because
getting it moving again means either discarding unlanded work or answering the decision it parked
on, and both of those belong to the King. `rally` reports it as a blocker with the worktree, the
branch and the unlanded work preserved untouched, and carries no recovery route of its own. One was
written and removed: it needed a liveness fence, an order of operations against the teardown floor
and a replacement-worker path, and each round of review found one more interaction between that
machinery and the floors here.

**The landing and teardown floors protect the worktree and the unlanded work inside it, so they are
keyed on the hold and never on liveness.** What makes that work still needed is that the decision it
is waiting on has not been answered, which is the hold's state and not the process's. A dead parked
worker still has unlanded work and an open question, so tearing it down discards the first while
the second is unresolved - which is why losing the process must not release the floor, and why
`muster` Step 8b states it with no liveness condition at all.

Neither floor has to be weakened to be got past. The decision is answered while the worktree is
preserved, the hold closes when it is answered, and the floor stops barring teardown at that point
because it was keyed on the hold all along. Nothing here makes a parked worker with unlanded work
easier to tear down.

Both guards read the hold from the queue **and** from `data\done-archive.md`, anchored to the whole
key on its own entry. Drop the archive line and a decision answered long enough ago to have been
pruned reads as one nobody ever made. Match the key as a bare substring instead of anchoring it and
a longer key sharing its opening reads as this one's answer, so the guard passes on a record nobody
has actually found. Both mistakes were made and fixed during the change; neither is theoretical.

### The reversibility test's wording

`petition` states the test and is the only place it is stated. What must not change is that it is a
test of reversibility rather than of knowledge:

> **The test is reversibility, not knowledge.**

> **Decide it** - away or present, discussed or not - when the call is reversible in minutes and is
> **none of**: a delete, a cost, security-sensitive, or a material expansion of what the work was
> accepted to deliver.

> **Wait for him** on a delete, a cost, anything irreversible or anything security-sensitive,
> **regardless of what is known**, and on a major but recoverable call where nothing records his
> position.

The mis-statement to refuse by name is "answer only what you know". It sounds like the cautious
reading and it is not: it parks every small copy and consistency finding until morning, which is
the failure this route was built to end. Five findings of exactly that shape came back on one run.
Softening the wording in that direction restores the failure while looking like a safety
improvement, which is why it is quoted here rather than paraphrased.

The floors in that quote are the same floors hard rule 2 already carries. Being away never lowers
them, and a recorded position never authorises an irreversible action.

### A worker still never opens an interactive prompt

Every brief forbids the worker from opening an interactive question, and parking does not relax it.
Parking is the opposite of asking: the worker writes the question into a file and ends its turn, so
nothing is waiting on a screen and nothing hangs.

This matters because the panes are headless. There is no terminal to hand the worker over in and no
window to attach to, so a prompt a worker opens can only be answered by the Hand pressing keys at
it - which is how five hours of silence happened once already. A change that lets a parked worker
ask its question through a prompt instead of through `report.md` reintroduces exactly that, and it
also breaks the two floors above, because a worker sitting on a prompt has no pointer set and reads
as an ordinary blocked worker.

## Coverage

The prose rules above are asserted in `tests\Docs.Tests.ps1`, which pins the specific wording that
carries each one. The behaviour is exercised rather than read: `tests\Crew.Tests.ps1` drives
`Set-CrewWaitingOn` and the `Import-CrewState` normalisation, and `tests\Backlog.Tests.ps1` drives
the real `tasks-axi` to prove the prune into `data\done-archive.md`, the anchored key match, the
quoted `--fields` list, and that replaying `hold` on an open hold overwrites its reason.
