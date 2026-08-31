---
name: rally
description: Reference procedure for a worker that has stopped making progress - a worker reported blocked on an interactive prompt, one whose liveness read comes back dead or has no live process, one looping or repeatedly confused, one asking a question its brief already answers, one that has gone unresponsive, or one still recorded as working after the Hand's session restarted. Reconciles what that worker actually holds before escalating from targeted inspection through a corrective steer, an answered prompt the user decided, a safe relaunch, or a reported failure. The Hand loads it when that situation arrives; nobody invokes it by name.
version: 1.0.0
---

# Rally

Use this playbook when a worker reads `blocked`, when its recorded session reads dead or has no
live process, when a worker settled without writing its `report.md`, or when a worker is stale,
looping, repeatedly confused, asking a question its brief already answers, unresponsive, or has
stopped without landing.

Intent lives in `state\crew.json` through `bin\Crew.psm1`, and `bin\Get-CrewStatus.ps1` joins it
with live state. Where the two disagree, the live read wins for liveness and `crew.json` wins for
intent. A worker's own record of what it found is `$env:KINGSHAND_HOME\data\<id>\report.md`, which
lives outside the worktree and survives everything below.

**Index that report the moment you read it.** This path never reaches `muster` Step 6, which is the
only other place that lists it, so a worker rallied or torn down here leaves its findings in a file
no index names - and an unlisted report is a finding the next brief will not find, plus a drift
count the session-start digest prints forever:

```powershell
Import-Module $env:KINGSHAND_HOME\bin\Index.psm1 -Force
Add-IndexEntry -Project "<project>" -Path "data\<id>\report.md" -Summary "<one line of what it found, or that the worker stopped before writing one>"
```

## What kingshand can and cannot do to a running worker

The control plane is herdr, reached only through `bin\Herdr.psm1`. Nothing here composes a herdr
command line by hand:

```powershell
Import-Module $env:KINGSHAND_HOME\bin\Herdr.psm1 -Force
Get-HerdrAgents                                  # every live worker, with its state, pane and cwd
Get-HerdrAgent  -Name "<worker id>"              # one worker, or $null if herdr has never heard of it
Get-HerdrAgentState -Name "<worker id>"          # the state to act on: herdr's, corrected by the screen
Test-HerdrAgentAwaitingInput -Name "<worker id>" # is that worker sitting on a prompt right now
Read-HerdrAgent -Name "<worker id>" -Lines 60    # what is on that worker's screen right now
Send-HerdrPrompt -Name "<worker id>" -Text "..." # steer it: text in, Enter sent
Send-HerdrKeys  -Name "<worker id>" -Keys down,enter   # answer a prompt, one key per call
Stop-HerdrAgent -Name "<worker id>"              # /exit, then confirm it is gone
Remove-HerdrPane -PaneId "<pane id>"             # discard the pane the worker was in
```

**A running worker can now be steered, and that is new.** `Send-HerdrPrompt` puts text into a live
worker and submits it, so the escalation below can correct a confused worker in one line instead
of throwing the dispatch away. Use it. What it does not do is talk to a worker that is `blocked`:
herdr refuses a prompt outright there with `agent_blocked`, and `Send-HerdrPrompt` hands that back
as a result rather than an error.

**Steering is still not a conversation.** The worker cannot reply to you, its brief still forbids
it from asking anything, and a steer that needs a decision from the user is still the user's to
make first. Do not write text into the worktree hoping the worker reads it, and do not describe a
steer as done without checking `Read-HerdrAgent` afterwards to see that it landed.

## herdr's own state is wrong in both directions, and the screen is the authority

**Do not decide anything here from herdr's classification.** Measured on this machine against
herdr 0.8.2 with agent-detection manifest 2026.08.21.1, a worker sitting on an unanswered
`AskUserQuestion` menu reported `idle` - `agent explain` showed it matched by `live_prompt_box`
while every blocked rule evaluated and failed - and minutes later that same still-blocked worker
reported `done` while a genuinely finished worker reported `idle`. The two states inverted.

That was traced to terminal width, not to herdr. The panes were 3 to 6 columns wide and neither
herdr's rules nor the guard can match a UI that never renders; at 94 columns both classified the
same blocked worker correctly. **So the first question about a worker behaving oddly is whether you
can read it at all** - `Test-HerdrAgentReadable`. A false there means you do not know its state
rather than that it is fine, and the cure is a herdr server restart once workers have finished. So a
worker reading `idle` or `done` may be waiting on a person, and one reading `blocked` may not be.

`Test-HerdrAgentAwaitingInput` is the authority. It reads the LIVE VIEWPORT and answers whether
there is an interactive prompt on the screen now. `Get-HerdrAgentState` wraps it and is the state
to act on - it returns `blocked` whenever the screen shows a prompt, whatever herdr said. Never
read `agent_status` yourself.

The live viewport is the point, not an implementation detail: `recent` and `recent-unwrapped`
carry scrollback, so a worker that answered a menu an hour ago still has that text in its history
and would read as blocked forever. `Read-HerdrAgent` is for reading what a worker said, and it is
not a blocked test.

## Removing the worktree destroys any unlanded work

Kingshand creates each worker's worktree itself, so kingshand is what removes it, and nothing
else does. Stopping a worker never touches it: `Stop-HerdrAgent` exits the process and leaves the
directory exactly where it was, which is why stopping is always safe and removing never is.
Running `git worktree remove` on a stuck worker that holds uncommitted changes or unpushed commits
destroys that work, and hard rule 1's protection of unlanded work is what it breaks.

The safe order is not negotiable:

1. Inspect first - `Read-HerdrAgent -Name <worker id>`, then the worktree itself.
2. Confirm exactly what is committed, and whether the branch exists on the remote.
3. Use `Stop-HerdrAgent -Name <worker id>` while anything is unlanded. It ends the run and keeps
   the work.
4. Remove the worktree only once the work is committed and either landed or pushed, or the user
   has explicitly authorised discarding it.

`report.md` is outside the worktree and no cleanup here can reach it. Nothing else the worker
produced has that protection.

## Always `/exit`, never a kill

`Stop-HerdrAgent` sends `/exit` and waits for the worker to disappear. Never substitute
`Stop-Process` or any other force-kill.

**A force-killed worker leaves its pane permanently unusable.** It never sends its terminal-mode
reset, so the pane stays in Kitty keyboard protocol with bracketed paste on: every later keystroke
is echoed as literal text instead of being interpreted, `ctrl+c` arrives as `[99;5u`, and starting
a fresh worker into that pane times out. No herdr command recovers it - three interrupts and an
Enter did nothing.

**When a pane is not reusable, discard it and keep the worktree.** The worktree is only a
directory and nothing corrupts it; a fresh pane at the same cwd picks the work straight back up.
`Stop-HerdrAgent` returns `paneReusable`, and it is `$true` only after a clean exit. Anything else
means make a new pane rather than reusing that one, and never assume a relaunch into the old pane
will work.

## Never batch keys at a blocked prompt

`Send-HerdrKeys` sends one key per call with a pause between, deliberately. Sending an arrow and
Enter in a single herdr invocation **silently selects the wrong option** - the Enter is delivered
before the menu has processed the arrow, and herdr reports success while doing it. A wrong answer
with no error is the worst failure shape there is, and it is the user's decision being answered
wrongly on their behalf.

So: move the cursor, read the screen back with `Read-HerdrAgent` to see where it actually landed,
and only then send Enter. Never compose the two into one call, and never answer a prompt whose
options you have not read.

## Reconcile the recorded work before deciding anything

Treat a liveness result as a presence signal, not proof that the worker's work is gone. Read the
targeted current state before deciding to relaunch - `bin\Get-CrewStatus.ps1` for the joined view,
`Read-HerdrAgent -Name <worker id>` for what the worker was actually doing, and the worktree's own
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
and only then removed under the safe order above.

If the worktree or the ownership cannot be reconciled safely, leave all state intact and report
the task failed or blocked with the conflicting evidence. Set the stage with
`Set-CrewStage -Stage 'failed'`; the valid stages are exactly `dispatched`, `implementing`,
`gating`, `ready`, `landed`, `failed`, and `Set-CrewStage` throws on anything else.

## Escalation, in order

1. **Peek.** `Read-HerdrAgent -Name <worker id>`, and `Get-HerdrAgentState -Name <worker id>` for
   the state to act on. Read what it is actually doing before doing anything to it, and do not
   trust a state that came from anywhere else.

2. **Steer it.** If the worker is confused, looping, or asking something its brief already
   answers, send one corrective prompt with `Send-HerdrPrompt` and read the screen back to
   confirm it landed. This is the cheap step and it comes first now: throwing a dispatch away for
   something one sentence fixes is waste, and it was the only option before herdr.

3. **A blocked worker is the user's decision, not yours.** `blocked` means it is sitting on an
   interactive prompt, and herdr will refuse a prompt at that worker until the prompt is answered.
   Confirm it with `Test-HerdrAgentAwaitingInput` rather than herdr's state word, and confirm the
   same way before concluding a worker is *not* blocked - that direction is the dangerous one.
   Read the options off the screen, tell the user plainly what the worker is asking and what the
   choices are, and get their answer before touching anything. Then answer it with
   `Send-HerdrKeys`, one key per call, reading the screen back between the arrow and the Enter.

   **Never answer a blocked prompt on the user's behalf**, and never guess at an option you have
   not read. There is no interactive terminal to hand the worker over in - the panes are headless
   and there is no window to attach to - so the Hand is the only route to that prompt, which makes
   getting the answer first the whole safeguard rather than a nicety. Note it too: the worker's
   brief forbade opening that prompt, so its brief was not followed and the rest of its work
   deserves the same suspicion.

4. **Relaunch.** If the worker is genuinely wedged, relaunch it - stop the worker, reconcile its
   worktree per the section above, then dispatch a fresh one through the normal `muster` path with
   the same brief plus a concise progress note saying what was already done and what remains.

   Genuine wedging means looping, unresponsive, repeating the same obstacle, or truly dead. **A
   low context reading is not wedging; modern harnesses auto-compact and keep going.**

   Relaunch is cheap only once the commits are safe. Until they are, it is destructive. A
   relaunch also needs a pane: if the old worker did not exit cleanly, its pane is unusable, so
   discard it and let the dispatch make a fresh one at the same worktree.

5. **Report the failure.** If a second relaunch fails too, set the stage to `failed` and tell the
   user the plain failure, the preserved work, and the consequence. This is a genuine blocker, so
   it reaches the user under hard rule 6; route it to a rendered surface under hard rule 5 when
   they must decide something rather than simply read it. Do not expose session ids, worktree paths, stage names, or other
   internal mechanics unless a path is what the user needs in order to act.
