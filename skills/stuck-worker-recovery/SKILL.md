---
name: stuck-worker-recovery
description: Reference procedure for a worker that has stopped making progress - a worker whose liveness read comes back dead or has no live process, one looping or repeatedly confused, one asking a question its brief already answers, one that has gone unresponsive, or one still recorded as working after the Hand's session restarted. Reconciles what that worker actually holds before escalating from targeted inspection through handing the session to the user, a safe relaunch, or a reported failure. The Hand loads it when that situation arrives; nobody invokes it by name.
version: 1.0.0
---

# Stuck worker recovery

Use this playbook when a worker's recorded session reads dead or has no live process, or when a
worker is stale, looping, repeatedly confused, asking a question its brief already answers,
unresponsive, or has stopped without landing.

Intent lives in `state\crew.json` through `bin\Crew.psm1`, and `bin\Get-CrewStatus.ps1` joins it
with live state. Where the two disagree, the live read wins for liveness and `crew.json` wins for
intent. A worker's own record of what it found is `$env:KINGSHAND_HOME\data\<id>\report.md`, which
lives outside the worktree and survives everything below.

## What kingshand can and cannot do to a running worker

The control plane is `claude` itself, and it is small:

```powershell
claude agents --json           # every background session, with pid, state, status, cwd
claude logs   "<worker id>"    # that session's recent output
claude stop   "<worker id>"    # stops the session and RETAINS its worktree
claude rm     "<worker id>"    # deletes the session AND its worktree
claude attach "<worker id>"    # opens the session interactively, in the user's terminal
```

**There is no `claude send`, and no scriptable way to steer a running worker.** The Hand cannot
answer a worker's question, interrupt it, or redirect it mid-run. Do not invent a mechanism for
it, do not write text into the worktree hoping the worker reads it, and do not describe a steer
you cannot perform as though it happened. The only way to talk to a running worker is
`claude attach`, which is interactive and belongs to the user, not the Hand. When that is what
the situation needs, the Hand's job is to name the situation, name the worker id, and hand it
over.

## `claude rm` destroys the worktree, and with it any unlanded work

`claude rm` deletes the session and its worktree together. Running it on a stuck worker that holds
uncommitted changes or unpushed commits destroys that work, and hard rule 1's protection of
unlanded work is what it breaks. `claude stop` retains the worktree; that is the difference
between the two, and it is the whole reason to reach for `stop` first.

The safe order is not negotiable:

1. Inspect first - `claude logs <worker id>`, then the worktree itself.
2. Confirm exactly what is committed, and whether the branch exists on the remote.
3. Use `claude stop <worker id>` while anything is unlanded. It ends the run and keeps the work.
4. Use `claude rm <worker id>` only once the work is committed and either landed or pushed, or the
   user has explicitly authorised discarding it.

`report.md` is outside the worktree and `claude rm` cannot reach it. Nothing else the worker
produced has that protection.

## Reconcile the recorded work before deciding anything

Treat a liveness result as a presence signal, not proof that the worker's work is gone. Read the
targeted current state before deciding to relaunch - `bin\Get-CrewStatus.ps1` for the joined view,
`claude logs <worker id>` for what the session was actually doing, and the worktree's own
`git status` and `git log` for what it holds.

When no live session accounts for the recorded task, inspect only that worker's own recorded
worktree and branch. Do not sweep every worktree under the repo, and do not infer ownership from a
matching branch name or directory name.

Before relaunching, prove that no live agent still owns the recorded task and that the existing
worktree remains available. Preserve its uncommitted changes and commits, and keep the same task
identity - the same ticket, the same repo, the same `crew.json` entry.

**Never allocate a second worktree for one task**, because that splits it across two copies and
neither is then the work. Kingshand's dispatch path creates a fresh worktree every time, so a
replacement worker is a second copy by construction; that is exactly the condition this rule
forbids leaving unresolved. The stuck worker's worktree must be accounted for before the
replacement runs - its work committed, and either pushed or carried into the replacement's base -
and only then removed under the `claude rm` order above.

If the worktree or the ownership cannot be reconciled safely, leave all state intact and report
the task failed or blocked with the conflicting evidence. Set the stage with
`Set-CrewStage -Stage 'failed'`; the valid stages are exactly `dispatched`, `implementing`,
`gating`, `ready`, `landed`, `failed`, and `Set-CrewStage` throws on anything else.

## Escalation, in order

1. **Peek.** `claude logs <worker id>`. Read what it is actually doing before doing anything to
   it.

2. **Hand the session to the user.** If the worker is waiting on a question its brief already
   answers, confused, or looping, `claude attach <worker id>` is the only way to reach it, and it
   is the user's terminal, not the Hand's. Tell the user what the worker is stuck on, name the
   worker id to attach to, and say what to tell it. Do not attempt a steer kingshand cannot
   perform.

3. **Relaunch.** If the worker is genuinely wedged, relaunch it - stop the worker, reconcile its
   worktree per the section above, then dispatch a fresh one through the normal `crew` path with
   the same brief plus a concise progress note saying what was already done and what remains.

   Genuine wedging means looping, unresponsive, repeating the same obstacle, or truly dead. **A
   low context reading is not wedging; modern harnesses auto-compact and keep going.**

   Relaunch is cheap only once the commits are safe. Until they are, it is destructive.

4. **Report the failure.** If a second relaunch fails too, set the stage to `failed` and tell the
   user the plain failure, the preserved work, and the consequence. This is a genuine blocker, so
   it reaches the user under hard rule 6; route it to a rendered surface under hard rule 5 when
   they must decide something rather than simply read it. Do not expose session ids, worktree paths, stage names, or other
   internal mechanics unless a path is what the user needs in order to act.
