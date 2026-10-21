# Night's watch - 2026-10-21

Night's watch is the away mode that works the queue while the King sleeps. He says
`/nights-watch` before bed; while the session stays open the Hand works backlog items it can prove
are decided, lands and merges what comes back green under the floors, records every outcome in the
away journal, pauses its workers across a usage-window reset, and stops when no provably decided
item is left. He gets one digest on return.

## It is regency plus queue-working, never a widened regency

Regency's premise is that being away grants nothing. Folding queue-working into it would make every
afk an authorisation, so night's watch is a separate skill invoked on purpose. Entering it enters
regency - the same flag, the same journal, every one of regency's limits - and adds the one thing the
King granted it by name: working decided items from the queue. A restarted session sees only the
flag and returns to plain regency, which is the safe direction.

## The pool is what the queue can prove

`tasks-axi ready` already answers which items are unblocked and unheld, and it is asked rather than
second-guessed. On top of it, an item counts only on a registered project whose `yolo` is `'on'`,
because an item that would need a dispatch gate is not decided. An empty pool stops the watch. An
unreadable queue is no pool, never an empty one.

## Merging has its own token now

**This supersedes the September decision that merging while away is an option defaulting to on
everywhere, passed at invocation.** On 2026-10-21 the King gave night's watch its own per-project
token, `+watch-merge`, independent of `+merge`:

- night's watch merges a green pull request only where the entry declares `+watch-merge`, whether
  or not it declares `+merge`, and `+merge` alone grants it nothing;
- off unless set, and forced off by anything that forces `+merge` off;
- the invocation can turn watch merging off for a run, and nothing turns it on where the token is
  absent;
- it is the King's standing grant for one action on one repository, like `+merge`, and is never
  read onto a daytime merge.

The floors are firstmate's, kept whatever the default: never merge red, green at the live head with
the merge bound to that head, a local-only landing never relocated - plus every existing `muster`
Step 7 floor. Firstmate's research flagged our "never merge red while away" as prose with nothing
behind it; `Get-WatchMergeVerdict` is the guard, and `Invoke-WatchMerge` refuses any verdict that
did not allow it and passes `--match-head-commit`. Two floors stay with the Hand because no code can
read them from a diff: material expansion of the brief, and destructive or security-sensitive work.

## It runs inside the live session

The King declined a supervision host on 2026-09-25: what it uniquely buys is supervision past a
closed session, and a closed session costs hours rather than work, while the one thing genuinely
lost - the account of the night - is the away journal's job. So there is no daemon, no second
coordinating agent, and no fire-and-forget child. Background work is the harness's tracked jobs,
each bounded. The trigger that would reopen this is narrow: the King wanting work to progress during
hours no session can be kept open at all.

## A parked lane is one record

A worker legitimately waiting on a decision looks exactly like a wedged one by screen movement, and
firstmate escalated one such lane 671 times. Here a parked worker is recorded once - the same kind,
worker and text already in the journal is not written again - and its gate is watched with the
gate-run wait, which moves only when the run does.

## The usage window, handled across the reset

A night spans more than one five-hour window, and nothing wakes the Hand at a reset unless a timer
was armed before the budget ran out. The procedure that worked by hand is now mechanism:

- **Threshold 90 percent** of the driving window by default, an invocation argument. The King's 90
  of 2026-10-22 replaces his 88 of the day before: the last tenth is kept to hold the watch across
  the gap and nudge the paused workers after the reset, so nothing reads a window from 90 percent
  until it resets, apart from the one confirming read.
- **Reads every five minutes, every two from 85 percent**, the King's cadence of 2026-10-22, taken
  from a headless probe that is not rate limited - `docs\2026-09-05-usage-window-watch.md` records
  the reader. That cadence replaces seven and five, which were set against a reader that froze.
- **A pause on the climb.** On 2026-10-20 the window went from 83 to 88 percent in two minutes, so
  the watch also pauses where the rise since the window's previous reading, carried to the next
  read, would reach the threshold. Without two readings of the same window it is the plain
  threshold.
- **No reading while no worker is running.** The number barely moves then, and the first dispatch
  takes its own reading before it starts.
- **At the threshold, in order:** rescue each gate run's head to `refs/gate/<task>-<moment>` - a
  rescue never overwrites another - then tell each worker to finish its edit and commit, and only
  then stop it cleanly.
- **Across the gap:** one tracked timer pinned once from the reset plus a margin, zero quota reads,
  re-armed with the same time if it dies, refusing any wait over six hours.
- **After the reset:** a reading to confirm the window rolled - a stale one is read again every
  five minutes for up to thirty, a current one still at the limit re-arms the timer, and a reading
  stale throughout restarts the workers anyway with that recorded in the journal
  (`Get-WatchWakeStep`) - the limit dialog dismissed with Escape, and each worker restarted in its existing worktree with a prompt that cannot be built
  without where the commits are, resume or fresh, every standing direction and what is settled.
- **The weekly window** resets in days. The watch records that and stops rather than sleeping.

## How many workers

Unsettled by the King. The default is two at once, the cautious choice for an unattended night, and
it is an invocation argument.
