# Project session mode - 2026-10-21

The `fief` skill lets the King declare a session for one project. While it is in force every
request routes to that project, its context is read once, and one long-lived worker makes a run of
small fixes on a single branch in the project's own checkout - no worktree - committing, pushing
and raising a pull request only on his separate words.

The pattern existed before the mode did. It ran by hand from private notes, and the notes recorded
what went wrong each time: a permission file not put back, an allow list dropped, a worker blocked
on a settings warning written from a failed read, a brief that forgot to say the worker was not in
a worktree. Making it a mode is mostly making those mechanical.

## The design

- **The skill owns the mode, and it is session-scoped.** Entered only on the King's words, ended
  on his words or with the session. Nothing under `state\` carries it.
- **Routing is pinned.** Every request resolves to the session's project. A request that plainly
  names another gets one line naming the mismatch, and the Hand waits - a confirmation he asked
  for, not a refusal.
- **Context loads once**: the project's rules, criteria, index, and an optional
  `data\session-<project>.md` holding how a session for it runs. The test that separates the
  session file from the rules file: rules hold for every piece of work on the project, the session
  file only for how a session runs.
- **One warm worker writes all the code.** The first change dispatches it; every later fix
  reaches it as a prompt. Hard rule 1 is unchanged.
- **No worktree by default.** `Dispatch-Worker.ps1 -InCheckout -Branch <name>` runs the worker in
  the checkout. It creates and switches no branch and refuses, before anything exists, a checkout
  that is not already on the named branch. `ClaudeWorkspace.psm1` owns the permission file: it
  records the original bytes and whether a file existed before the first write, edits the file as
  JSON so every key - the `allow` list above all - survives, refuses a file it cannot read rather
  than building from the failure, and puts the original back or deletes the file at cleanup.
  `Stop-CheckoutWorker` is that cleanup, and it never deletes the branch or removes the checkout.
  A session that wants isolation gets one ordinary worktree for the whole run.
- **The checkout warnings are a fixed brief section the dispatcher writes**: not in a worktree,
  the branch to stay on, the commands never to run, commit and push only on a prompt, and git's
  own listing of what was already uncommitted and stashed, quoted as not the worker's.
- **One crew record carries many items.** A session worker's record holds every ticket or fix id
  on its branch, in order, each with its kind. It survives a restart and is the source for the
  commit and pull request titles. Every other record keeps the one-ticket shape it always had.
- **Delivery is one word at a time** - commit, push and pull request each authorise only
  themselves, whatever `yolo` says, because he is present and batching. On a `no-mistakes` task
  the review gate runs once, at the push word, over the whole branch.

## What the King settled at dispatch

1. **The warm worker writes the code.** A session is not a route to the Hand writing project
   code. The bounded override parley's design rejected stays rejected.
2. **The mode is session-scoped.** A restart drops it, which fails safe: the Hand returns to
   ordinary routing and asks which project, rather than routing a request to a project he has
   stopped working on. The worker itself is durable in the crew record and is re-armed at session
   start like any other; a restarted session reports it and does not re-enter the mode until he
   says so.

## The parley note's objections, answered

`docs\2026-09-25-parley-quick-mode.md` parked this idea as out of scope, for three reasons.

**"One worktree per unit of work exists so that one diff is what the landing gate measures."** It
still is one diff. The unit of work in a session is the run of fixes on one branch, and the landing
gate measures that branch against its base, once. What the objection protects - a gate that sees
exactly the work it is approving and nothing else - survives because unrelated work never rides
the session branch: it goes to its own branch and its own pull request through ordinary dispatch.
The one new hazard was measuring the branch against itself: with nothing recorded, the base
resolver falls back to the checked-out branch, which for a worktree is the default branch and for a
checkout is the session branch. The dispatcher refuses that base by name.

**"The durable worker record maps one worker to one ticket."** That was a property of the record,
not a reason for it, and it is now a choice per record. A session worker carries an ordered item
list; every other record is byte for byte what it was, and reading either shape goes through one
function. What the mapping protected - that a status line and a title name exactly the work in
flight - is held by the list itself, which is written before the worker touches each fix and
refused when it cannot be read.

**"Ship the mode first, measure what the setup actually costs, and decide with a number."** The
number arrived from use rather than a benchmark. A worker costs one to two minutes of setup before
it has read anything, and on a run of one-line fixes that cost was paid per fix while the work
itself took less. The hand-run version of this pattern then ran across two working days on one
project, and every defect it hit was mechanical. That is the evidence this design was built from,
and it is why the mechanical parts are code rather than prose.

## What is not enforced

Pinned routing, the one-line mismatch and the step boundary are obeyed by the Hand at a turn
boundary, where prose is the only mechanism there is. The exit conditions are enforced by nothing:
a Hand that forgets the mode returns to ordinary routing, which fails safe, and the warm worker is
still watched because its wait and its record never depended on the mode.
