# Worker control plane: stay on `claude --bg`

Date: 2026-08-28
Status: decided

## The decision

Kingshand keeps spawning workers with `claude --bg --worktree` and accepts that it cannot steer a
running worker. It does not adopt the ConPTY model firstmate uses on Windows. Revisit only under
the conditions at the end of this file.

## What prompted it

Porting the `rally` procedure from the tool kingshand derives from exposed that three of its five
escalation steps - answer a question in one line, interrupt and redirect a confused worker,
relaunch carrying a progress note - have no mechanism in kingshand.

The verified control surface is `claude agents --json`, `logs`, `stop`, `rm` and `attach`. There
is no `claude send`. `attach` is interactive and belongs to the user, not to the Hand.

## Why a ConPTY harness can steer and kingshand cannot

This is architectural, not a Windows limitation. A harness that hosts the agent inside a
pseudoconsole it creates itself owns that ConPTY, and can therefore write into the agent's stdin:
send the literal text, then send the Enter key to submit it. Liveness comes from OSC 133 prompt
marks emitted into the same stream. A working implementation of exactly this exists, so the
capability is real rather than hypothetical.

Steering requires owning the process's terminal. Kingshand's workers are Claude Code background
sessions, so Claude Code's supervisor owns them and there is no pseudoconsole to write into. No
amount of work inside kingshand changes that; only replacing the spawn mechanism would.

## The trade

| | `claude --bg` (chosen) | ConPTY daemon |
|---|---|---|
| Infrastructure | none | a Node daemon, ~5 JS files, a native dependency, its own liveness machinery |
| Steer a live worker | no | yes |
| Interrupt and redirect | no | yes |
| Relaunch carrying a note | no | yes |
| Stuck-worker options | stop and re-dispatch, or hand to the user via `claude attach` | full five-step escalation |

## Why the cheap option wins here

A worker costs almost nothing to re-dispatch: the brief is on disk, the worktree persists through
`claude stop`, and a replacement starts from the same brief plus a progress note in its text. The
escalation steps that are lost are the ones that matter least when restarting is cheap.

Against that, the ConPTY model adds a daemon and a native dependency to a tool whose whole appeal
is having no moving parts. That is a poor trade today.

## What this costs, stated plainly

- A worker waiting on a question its brief already answers cannot be answered by the Hand. It
  is stopped and re-dispatched with a better brief, or handed to the user with `claude attach`.
- `Dispatch-Worker.ps1` always creates a fresh worktree, so a replacement is a second copy by
  construction. This sits in tension with firstmate's "never two worktrees for one task", and
  `rally` names that tension rather than hiding it: the stuck worktree's work must be committed
  and carried into the replacement's base before the replacement runs.

## What would change the decision

- Claude Code gains a scriptable way to send input to a background session. That removes the whole
  reason to own a terminal, and the ConPTY model stays unnecessary.
- Re-dispatching stops being cheap - long-running workers, expensive setup, or work that cannot be
  resumed from its brief.
- Stuck workers become frequent enough that stop-and-re-dispatch is a real cost rather than a rare
  annoyance. Nothing so far suggests this; no worker has hung yet.
