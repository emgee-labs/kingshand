# Noticing a worker that has stopped making progress

Date: 2026-09-01
Status: **current**

## What happened

Two failures on the same night, both costing real time, both invisible until the King asked.

**A review gate waited an hour for CI that could never arrive.** A pipeline run on the kingshand
repository reached its `ci` step and sat there for over an hour. This repository has no CI at all:
no workflow files, nothing configured on GitHub, zero check runs on the commit. The gate cannot tell
"checks have not started yet" from "checks will never exist", so its wait had no end.

**The Hand's own wait was watching the wrong thing.** `Wait-HerdrAgentSettled` asks whether a worker
is alive. A worker that handed its work to a background pipeline and returned to its prompt read
`done` immediately, so the wait fired within seconds and reported a completion that had not
happened. The same night the opposite also happened: a worker whose work was genuinely finished read
`working`, because stray text was sitting in its input box.

The common thread is that liveness and progress are different questions, and only one of them is
the one anybody cares about.

## The decisions

### CI is established before a worker is promised a wait for it

`bin\Ci.psm1` answers one question - can anything report a check on this repository's pull requests
- and `muster` Step 1b asks it before a `no-mistakes` task is dispatched. The answer picks which of
the two `no-mistakes` Done-means blocks the brief carries, so a repository with no CI produces a
brief that says to stop at the pull request rather than one that says to wait for green.

**Two signals, and the second one is why this is not a directory test.** A `.github\workflows`
directory is the obvious signal and it is insufficient in both directions: `emgeelabs-site` has no
workflow file anywhere in the repository and gets Cloudflare Pages check runs on every commit, while
a repository that deleted its last workflow keeps the empty directory. So the stronger signal is the
checks GitHub actually reported on recent commits of the default branch, and it is consulted
whenever nothing the repository itself configures could report on a pull request. That last clause
is the third way a file listing lies: a workflow triggered only by `schedule` or `workflow_dispatch`
exists, runs, and still never puts a check on a pull request, so its triggers are read rather than
its presence counted. A workflow whose `on:` block cannot be read is kept, and so is another
provider's config file, because neither is evidence of absence. Both were verified against the three real cases
on this machine: kingshand answers `no-ci`, emgeelabs-site answers `has-ci` from check runs alone,
and a repository that cannot be reached answers `unknown` with the HTTP error in the detail.

**The third answer is the point.** `unknown` is the refusal to guess when the question could not be
settled - no `gh`, a remote that is not GitHub, an unauthenticated machine, a network that did not
answer. Nothing in that module converts a failed lookup into either answer, because both wrong
answers are expensive: a false `no-ci` throws away a real green check, and a false `has-ci` restores
the hour-long wait. `unknown` takes the same terminating brief line as `no-ci`, because under
uncertainty stopping at the pull request loses at most a wait for a check the user can see on the
forge anyway. The shared line says checks *may* not report rather than that they are not expected
to: the instruction is what ends the wait, and a line that asserted the absence as fact would have a
worker report a repository as CI-less on the strength of an expired token.

### The progress signal is the worker's own screen, normalised

Three signals were available and the screen was chosen.

- **The worker's screen changing** needs no knowledge of what the worker was sent to do.
- **A pipeline run's step, head commit or last-activity timestamp** is a much stronger signal, and
  only where the work is a review-gate run.
- **The worktree's `git log` and working tree** is a third, and it moves only at commit boundaries -
  a worker can work correctly for forty minutes without touching it.

The screen won because the Hand waits on investigations, audits and plain edits as well as pipeline
runs, and a watcher that only understands pipelines is blind to every other kind of work. It also
subsumes the pipeline signal in practice: a review gate prints its own step transitions into the
worker's terminal, so a step advancing **is** a screen change, with nothing here having to know that
a pipeline exists. That also sidesteps the trap that `no-mistakes axi status` with no `--run` returns
the most recent run in the repository rather than the one being watched - a watcher started before
its own run registered once read a different, already completed run and reported success
immediately. Not knowing about runs at all cannot get the run id wrong.

**Normalisation is what makes the screen usable.** Claude Code repaints an elapsed timer and a token
counter every second while it works, so the raw screen is never twice the same and a naive hash would
report a worker frozen for an hour as making steady progress. Only those volatile shapes are removed
- durations, token counts, spinner glyphs, trailing space. Digits in general are left alone
deliberately: a counter like `142/300` is real progress and must survive. The bias that leaves is
toward missing a stall rather than inventing one, which is the correct direction, because a false
alarm reaching the King is worse than a silent one and a missed stall is only as bad as today.

### Twenty minutes, and it is a parameter

A review pass on this project has legitimately taken 38 minutes, though it printed progress
throughout. Under about fifteen minutes, slow steps start reporting as stalls; an hour is plainly too
long, since that is roughly what the incident cost. Twenty minutes is the default on
`Wait-HerdrAgentProgress` and `-StallMinutes` overrides it per call.

### Reporting is the whole deliverable

`Wait-HerdrAgentProgress` never recovers anything: no steer, no answered prompt, no relaunch, no
stop. It returns a stall with the evidence needed to act - how long, what the worker was last seen
doing, whether its screen could be read at all - and `rally` owns the response. A wrong automatic
action on a stalled worker is worse than a late human one.

## What must not be undone

- **`Wait-HerdrAgentSettled` keeps its behaviour.** The progress wait was added beside it, not over
  it. Other callers depend on it and its guarded screen read is correct for what it does.
- **The normalisation stays, and stays narrow.** Delete it and every frozen worker reports as
  progressing. Widen it to strip digits wholesale and every counter-printing job reports as stalled.
- **An unreadable screen never becomes a stall.** `signalReadable` being `$false` means the watch was
  blind, and a caller that reads it as "unchanged" reports a healthy worker as stuck. It is the same
  pane-width defect that inverts herdr's own classification, arriving at a different function.
- **`unknown` is never rewritten into an answer.** The value of the CI preflight is that a failed
  lookup stays visibly a failed lookup.
- **The wait stays an event.** herdr's own wait is the blocking primitive and the sample interval is
  only that wait's timeout, so a finished worker still wakes the caller instantly. Sampling exists
  only for the stall half, because "nothing happened" is not an event anything can push, and it is
  bounded so that a herdr answering instantly with an error cannot turn the wait into a spin. The
  bound counts only returns that came back without consuming their slice: counting every iteration
  left about three of margin, so one server restart on a healthy worker ended the watch.
- **Nothing on a wake is assumed.** A worker herdr does not name is read twice before it is called
  gone, and the server is checked before that answer is given at all - a server that is down answers
  nothing for every worker, so reporting it as `gone` would send the Hand to reconcile a worktree
  still being written to. A stall reports the state and `awaitingInput` it read, because a worker
  sitting on an unmatched dialog looks exactly like a stalled one and needs the user rather than a
  hunt for a stuck step. And the default timeout is computed from the stall threshold, since a watch
  that ends first can never reach it.
- **A read that failed is not a screen.** `agent read` is invoked with `2>&1`, so herdr's own error
  arrives as ordinary text: non-empty, constant, and therefore a stable fingerprint that reports a
  stall twenty minutes later with the error message as evidence of what the worker was last seen
  doing. One function owns that read and the question of whether it succeeded, because the pane
  guard `rally` cross-checks with reads the same viewport and would otherwise confirm the story.

## Revisit when

- herdr grows a progress or activity signal of its own, at which point the screen fingerprint may
  become redundant.
- Claude Code changes its status line enough that the normalisation stops matching. The symptom is
  silent: stalls simply stop being reported. `Get-HerdrAgentProgressSignal` on a busy worker,
  sampled twice a minute apart, is the check.
