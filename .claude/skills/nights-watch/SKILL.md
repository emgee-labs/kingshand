---
name: nights-watch
description: Work the queue while the King sleeps. Use when he invokes /nights-watch or says in his own words to keep working the backlog overnight while he is away. It is regency plus queue-working - it carries regency's flag and journal unchanged, works only backlog items the queue can prove are decided, lands and merges what comes back green under every floor (merging only where a project declares +watch-merge), records every outcome in the away journal, pauses its workers at the usage threshold and restarts them after the window resets, and stops when no provably decided item is left. It runs inside the live session, grants nothing regency does not beyond the queue-working he granted by name, and ends on his next ordinary message.
version: 1.0.0
---

# Night's watch

The watch holds the wall while everyone sleeps, and claims nothing while doing it.

**It is regency plus one thing.** Entering night's watch enters `regency` - its durable flag, its
journal, every limit in its `## What a regency never grants` - and adds only the queue-working the
King granted by name on 2026-09-03. Regency's premise, that being away grants nothing, is unchanged:
that is why this is a separate skill, invoked on purpose, and never folded into regency, where it
would make every afk an authorisation.

`docs\2026-10-21-nights-watch.md` records the design and every decision behind it.

## How it starts

1. **Run regency's step 1 exactly as written** - the flag and the journal. Put his words in the
   note verbatim, and say in it that night's watch is in force with these options.
2. **Read the options once**, from what he said, and nothing else:

   ```powershell
   Import-Module $env:KINGSHAND_HOME\bin\NightsWatch.psm1 -Force
   $opts = New-WatchOptions        # -ThresholdPercent 90  -MaxWorkers 2  -NoMerge
   ```

   The threshold defaults to 90 percent of the driving window, at most two workers run at once, and
   merging is on wherever a project's entry declares `+watch-merge`. `-NoMerge` turns watch merging
   off for this run; **nothing he can say at invocation turns it on where the token is absent.**
3. **Run regency's steps 2 and 3** - confirm every worker is readable, arm a wait for each one.
4. Say one line naming the options and that the watch runs only while this session stays open, and
   stop talking.

## The pool

**Only work the queue can prove is decided, and nothing else, ever.**

```powershell
$ready = Get-WatchReadyItems
$pool  = Select-WatchPool -Items $ready.items -Projects (Get-AllProjects)
```

`tasks-axi ready` is the authority on what is unblocked and unheld - a captain hold is a hold, and
an unresolved blocker is a blocker - and `Select-WatchPool` keeps only items on a registered project
whose `yolo` is `'on'`. **An item that would need a dispatch gate is not provably decided**, so it
is left out with its reason, never reached for. A queue that cannot be read is no pool at all.

**When the pool is empty the watch stops, and records that it stopped and why.** It never reaches
for an ambiguous item and never invents work - regency's last limit is the same rule.

Work the pool in the queue's own order, through `muster` exactly as with the King present on a
`+yolo` project: Step 2 writes the brief, Step 4 dispatches and arms the wait. Before each dispatch
take `Test-WatchDispatchSlot` and a usage reading - `## The usage window` - and dispatch only where
both allow it. The dispatcher's own refusal near the limit still applies on top.

## Landing and merging

**Land green work within its brief exactly as `+yolo` already permits.** Every `muster` Step 7
floor holds, the parley marker included, and so do these, which are floors rather than options:

- never merge red;
- green at the live head, and the merge bound to that head;
- never merge work that materially expands its brief;
- never anything destructive or security-sensitive;
- a `local-only` landing is never relocated - it lands on its branch;
- every existing Step 7 floor.

**Merge only where `Get-WatchMergeVerdict` allows it, and only through `Invoke-WatchMerge`:**

```powershell
$v = Get-WatchMergeVerdict -Project $proj -Options $opts -PullRequest "<full https:// URL>" `
       -BriefPath "<brief>" -ReportPath "<report>" -Mode "<resolved mode>" `
       -GateOutcome "<complete|incomplete|not-run>" -CiStatus "<has-ci|no-ci|unknown>" [-HoldOpen]
if ($v.allowed) { Invoke-WatchMerge -Verdict $v -Strategy "<the repository's strategy>" }
```

The verdict checks every floor code can hold and refuses on each by name: the project's own
`+watch-merge`, `+merge` alone granting nothing, the run's own switch, local-only, the gate, an open
hold, the parley marker, and every check green at the live head. The merge is bound to the head
the checks were read at. **Two floors it cannot check, and you judge them before calling it**:
whether the work materially expands its brief, and whether it is destructive or security-sensitive.
Where either is in doubt, it waits for the King. The strategy comes from the repository, as Step
8a has it, never a default.

A verdict that refuses is not a failure: record it as `waiting` with its reasons and move on.

## Decisions

**A decision a worker parked on is decided by `petition`'s `## When the King is not there` test,
unchanged** - load it, apply it, and never restate it here. Record each one the moment it is made:
`decided` with its `-Basis`, or `waiting` where the test leaves it with him. Register it under
`decree` either way, as regency says.

**A worker legitimately parked is not wedged.** Once `muster` Step 6 has found it parked, record it
once with `Write-WatchRecordOnce` and watch its gate with `Wait-GateRunChange` from
`bin\GateRunWait.psm1` rather than a progress wait, so a parked lane is one record, not a stall
report every threshold. A blocked worker's prompt stays regency's case and is never answered.

## The usage window

**Read the quota no more often than `nextReadMinutes`** - every five minutes, every two from 85
percent, the King's cadence of 2026-10-22 - and act on what each reading says:

```powershell
$step = Get-WatchUsageStep -Reading (Read-WatchUsage -LiveCount <workers running now>) -Options $opts
```

**No reading while no worker is running.** `Read-WatchUsage` takes none at a count of zero and the
step comes back `idle`; the dispatcher takes its own fresh reading before the first worker starts.
**The pause comes on the climb as well as the figure**: where the rise since the window's previous
reading would carry it to the threshold by the next read, the step pauses now. With no earlier
reading of that window, the plain threshold decides.

- `idle` - nothing is running and nothing was read; dispatch as the pool allows.
- `continue` - carry on.
- `blind` - no current reading. It fails open exactly as `vigil`'s `## The refusal near the limit`
  says; record once that the watch could not see the window, and carry on.
- `stop-weekly` - the weekly window is the one at the limit, or the reset time could not be read.
  The reset is days away or unknown, so record it and stop the watch rather than sleeping.
- `pause` - do these in this order, and record each as a `note`:
  1. **Rescue first.** For every worker with a gate run, `Save-WatchGateRescue` its run's head to a
     ref named for the task and the moment, before anything is stopped.
  2. **Tell each working worker to finish its edit, commit and stop** - a prompt, not a stop.
  3. **Only then stop it cleanly**, with `Stop-HerdrAgent`. Never a kill. A worker parked on a
     decision is idle and spends nothing, so it is left alone, as `rally` says.
  4. **Arm one timer**: `Wait-WatchReset -WakeAt $step.wakeAt` as one harness-tracked background
     job, never `nohup` and never a detached child. `wakeAt` is pinned once from the last reading
     and never recomputed. Take **zero** quota readings across the gap. If the job dies, re-arm it
     with the same `wakeAt`.
  5. **After it wakes**, decide each reading with
     `Get-WatchWakeStep -Reading (Read-WatchUsage -Confirming) -Options $opts -WokeAt <when it woke>`
     - the read is taken with every worker paused, because confirming the reset is why it woke.
     **A stale reading is read again every five minutes for up to thirty**: `reread` waits
     `nextReadMinutes` and reads once more; `pause` re-arms the timer from that reading's reset
     time, as step 4; `stop-weekly` stops the watch; `restart-unconfirmed` restarts the workers
     anyway and records its `detail` in the away journal. On `restart` or `restart-unconfirmed`,
     for each paused worker: `Clear-WatchLimitDialog` - it dismisses the limit dialog with Escape and
     nothing else - restart it in its existing worktree with `New-HerdrPane` and
     `Start-HerdrAgent`, and send `New-WatchRestartPrompt`, which refuses to be built without
     where the commits are, resume or fresh from `Get-WatchResumeChoice`, every standing direction
     in full, and what is settled. Re-arm its wait.

## How it ends

1. **On the King's next ordinary message**, exactly as regency ends - and regency's `## When they
   come back` gives the digest: read from the journal first, before the flag comes off. In this
   order: what merged, what is waiting on him, what failed, what is still running.
2. **When the pool is empty**, or at `stop-weekly`. The watch stops; regency carries on holding
   the fleet until he returns.
3. **With the session.** Nothing records that night's watch is in force except the flag's note,
   which nothing reads as authority. A restarted session sees the flag, loads regency, and holds
   the fleet without working the queue until he invokes night's watch again - the safe direction.

## What enforces each rule here, and where the answer is nothing

- **The pool** is enforced by `tasks-axi ready` and `Select-WatchPool`.
- **The merge floors code can hold** are enforced by `Get-WatchMergeVerdict` and
  `Invoke-WatchMerge`, which refuses any verdict that did not allow it and binds to the head.
- **Material expansion and destructive or security-sensitive work** are judged by the Hand against
  the brief, at a turn boundary. Nothing mechanical can read either from a diff.
- **The pause order, the single pinned timer and the restart prompt's contents** are enforced by
  `Save-WatchGateRescue`, `Wait-WatchReset` and `New-WatchRestartPrompt`, each refusing the
  shortcut. Telling a worker to finish and commit is a prompt it acts on at its own turn boundary,
  not an instruction inside a long call.
- **No daemon and no supervision host** is the absence of any such thing to start. The King declined
  one on 2026-09-25; do not reopen it without the new fact the design note names.
