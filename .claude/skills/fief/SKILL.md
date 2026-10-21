---
name: fief
description: Project session mode - one project per session, one warm worker, one branch. Off until the King declares it in his own words - "<project> session", "this session is for <project>", "fief <project>". Load it the moment he says one, and again when he ends it with "end session", or "normal mode" where parley is not also loaded. While it is in force every request routes to that project, its context is loaded once, and one long-lived worker makes a run of fixes on one branch in the project's own checkout with no worktree, committing, pushing and raising a pull request only on his separate words. It changes routing and delivery and never authority - hard rules 1, 2 and 3 hold, and both gates still happen. Also load it when the session-start digest names a session worker that is still live.
version: 1.0.0
---

# Fief

A fief is a holding granted for one domain. For as long as the King says, this session holds one
project and nothing else.

**Fief is off by default, and nothing turns it on but the King's own word.** It is held in this
session's own context, so the mode begins when this file is loaded and ends when the King ends it
or the session does - `## How it ends` owns that. `CLAUDE.md`'s Skills section carries the one line
that gets it loaded, and the one fact that has to survive without it: a restarted session that
finds a session worker still live reports it and does not re-enter the mode.

**It exists because a run of small fixes on one project paid for a worktree, a dispatch and a
landing per fix**, while the King sat watching that one checkout from a dev server and wanted the
fixes to land there, together, on one branch he named. That pattern ran by hand for weeks; this is
the supported version of it.

## How it starts

1. **Resolve the project from the registry**, the way intake resolves any project. A project that
   is not registered is never dispatched into, and a session does not change that: say so in one
   line and do not enter the mode.
2. **Load its context once**, now, and not again for each request:
   - `data\rules-<project>.md` - the standing rules;
   - `data\done-<project>.md` - the standing criteria;
   - `data\index\<project>.md` - what has been written for it;
   - `data\session-<project>.md` - how a session for this project runs: its checks before a pull
     request, its branch naming, anything the King has said about working it in a session.

   **Absent is a normal state** for every one of the four. `CLAUDE.md`'s Knowledge routing owns
   what goes in the session file and how it differs from the rules file.
3. **Say in one line** that the session is in force, for which project, and on which branch where
   he has named one.

## What it changes

Three things, and every one of them is routing or delivery.

1. **Routing is pinned.** Every request resolves to the session's project. `## Routing` owns it.
2. **Context is read once**, on entry, rather than per request.
3. **One warm worker does all the code, on one branch, in the project's own checkout.**
   `## The warm worker` owns how it is started, fed and stopped.

## What it never changes

- **Hard rule 1 holds.** The Hand writes no project code in a session - the warm worker does. A
  Hand-writes-code override was offered once for small work and the King declined it; `parley`'s
  `## What was offered and declined` records why, and a session is not a second route to it.
- **Hard rule 2 holds.** Nothing reaches a server without his word. `## Delivery` owns how that
  word is given, one step at a time.
- **Hard rule 3 holds.** No agent, model or tooling name in anything reaching a git remote or Azure
  DevOps - commit titles and pull request bodies built from the item list included.
- **The dispatch gate happens** for the warm worker, as `muster` Step 3 has it, before it exists.
- **The landing gate happens.** `muster` Step 7 owns it and every floor in it. In a session it
  shows the whole branch against its base, once - the session's diff is the one diff.
- **The registered posture is still read and never inferred**, and `muster` Step 7 still owns
  merging, `+merge` included.
- **It routes work and switches no account.** The identity and account rules in the King's global
  instructions are untouched, and checking the account before a push is exactly as it is outside.
- **`parley`'s rules are unchanged**, whether or not it is loaded. `## Fief and parley together`.

## Routing

**While the mode is in force, every request resolves to the session's project.** Intake's
one-question rule for an ambiguous project does not fire: the King has already answered it.

**A request that plainly names another project gets one line, and the Hand waits.** Name the
project the session holds and the one the request names, and stop. It is not a refusal and not a
lecture - the King asked for this confirmation because the slip is his to make, and his next word
decides it: work on the other project ends the session or is dispatched outside it, as he says.

**Unrelated work never rides the session branch.** Where he asks mid-session for something on the
same project that is not part of this run of fixes, say so in one line, and it goes to its own
branch and its own pull request through ordinary `muster` dispatch, worktree and all. What rides
the branch is what the worker's durable record lists, and nothing else.

## The warm worker

**The first change in the session starts it, through `muster` as any dispatch is.** Step 2 writes
its brief and Step 3 gates it. The brief covers the run rather than one fix: its first item, the
rule that later fixes arrive as prompts, and the Done-means block for the resolved mode - with
nothing in it that commits, pushes or runs the gate unprompted, because `## Delivery` gives each of
those its own word. Pass `data\session-<project>.md` under `Read first` where it exists; the
rules and criteria files are attached by dispatch on their own.

**No worktree by default.** Dispatch it into the checkout, on the branch the King named:

```powershell
$r = & $env:KINGSHAND_HOME\bin\Dispatch-Worker.ps1 `
        -RepoPath "<checkout root>" -Name "<project>-session" `
        -BriefPath "$env:KINGSHAND_HOME\data\<project>-session\brief.md" `
        -InCheckout -Branch "<branch he named>"
```

The dispatcher's header owns what that switch refuses and writes - it never creates or switches a
branch, it refuses a checkout not already on that branch, and it writes the checkout warnings into
the brief itself. Relay any refusal as it comes: a checkout on the wrong branch is his to switch.

**A session that asks for isolation** - "use a worktree", or work he must not see half-done in his
checkout - takes one ordinary worktree for the whole run of fixes: the same call without
`-InCheckout` or `-Branch`, and still one worker. Never one worktree per fix.

**Record it as one worker carrying many items**, then arm its wait exactly as `muster` Step 4
says:

```powershell
Add-CrewWorker -State $s -WorkerId $r.id -Ticket "<first id>" -Kind "<ticket|adhoc>" `
               -Repo "<repo>" -Worktree $r.worktree -Branch $r.branch -Base $r.base `
               -Brief "$env:KINGSHAND_HOME\data\<project>-session\brief.md" `
               -Session -InCheckout -SettingsRecord $r.settingsRecord
```

Drop `-InCheckout -SettingsRecord` for an isolated session. `bin\Crew.psm1` owns the record's
shape.

**Each later fix reaches the same worker as a prompt, never as a new dispatch.** Add its id to
the record first, with `Add-CrewItem`, and save - so the list on disk is the branch's truth before
the worker touches anything. A fix with no ticket gets a short slug of its own and kind `adhoc`.
Then send the fix with `Send-HerdrPrompt`, wait for `working`, and re-arm the wait, as Step 4
requires of any prompt you send yourself. The King asking for a fix is his word for that fix;
where sending it would add scope he did not state, that is a Step 3 question in one line first.

**It is stopped at the session's end or on his word, and never before its work is safe.** A
checkout worker's work is in the checkout and on its branch whatever happens to the worker, so
stopping it loses nothing - but a worker whose record points at an open hold is still never
stopped, as Step 8b says. Clean a checkout worker up with `Stop-CheckoutWorker` from
`bin\ClaudeWorkspace.psm1`, passing its recorded `settings_record`; it never deletes the branch
and never removes the checkout. An isolated session worker is cleaned up as Step 8b has it.

**A wedged warm worker is relaunched as the same worker, and keeps its fixes.** Clean it up with
`Stop-CheckoutWorker`, dispatch it again with the same name, brief and branch, and re-record it with
`Set-CrewRelaunch`, which keeps its items and `waiting_on`. The first dispatch kept a baseline of
what was already uncommitted, so the relaunched brief quotes only those files as not its own and
lists the rest as the session's own earlier fixes. **Pass `-EndSession` to `Stop-CheckoutWorker`
only when the session ends**, which removes that baseline too.

## Delivery

**Commit, push and raise a pull request are three separate words, and each authorises only
itself.** `parley`'s `## One step at a time` owns that rule and states it in full; in a session it
applies whether or not parley is loaded. **Inside a session that holds whatever the project's
`yolo` says**: he is present and batching, so `+yolo` lands nothing early here.

- **Commit** - prompt the worker to commit. The title names every id on the branch, comma
  separated, in the order its durable record holds them, read with `Get-CrewItems`.
- **Push** - on a task that resolves to `no-mistakes`, this is the word that runs the review gate:
  prompt the worker with the gate line from Step 2's block for that mode, once, over the whole
  branch, and the gate's own push follows. **The gate runs once, on the whole branch, never per
  fix**, because no fix prompt carries the gate line. On any other mode, prompt the push itself.
- **Pull request** - its title names every id the same way, and its description calls out each
  item of kind `adhoc` as a change with no ticket.

The landing gate in Step 7 shows the whole branch against the recorded base. That base is resolved
at dispatch exactly as for a worktree, and the dispatcher refuses one that resolves to the session
branch itself - pass `-Base` with the branch the work will be proposed against when it does.

## Fief and parley together

**Both can be loaded at once, and each keeps to its own half.** Parley governs reply length and
ceremony; the session governs routing and delivery. Neither relaxes anything the other holds.

**"normal mode" belongs to the innermost active mode, and parley is the inner one.** While parley
is loaded, "normal mode" ends parley and the session carries on untouched. With parley off it ends
the session, and leaves `herald` exactly as it was. `herald` receives it only when neither is in
force. "end session" always ends the session alone, and never touches parley.

A warm worker dispatched while parley is loaded is a parley dispatch, so parley's own rules decide
whether its brief carries the no-gate marker. A session adds no gate parley removed and removes
none it kept.

## How it ends

1. **When he says so** - "end session", "end fief", or "normal mode" where parley is not loaded.
2. **With the session.** Nothing under `state\` carries the mode, so a restart drops it and the
   Hand goes back to ordinary routing, which is the safe direction: one more question about which
   project, never a request routed to a project he has stopped working on.

Ending the mode does not stop the warm worker on its own. Say in one line whether it is still
running and what is uncommitted on its branch, and stop it on his word.

## After a restart

**The warm worker is durable even though the mode is not.** Its durable record and its item list
survive, and its wait is re-armed at session start like any live worker's. A restarted session
that finds a live session worker **reports it in the orientation line - the project, the branch
and the items on it - and does not re-enter the mode until the King says so.** Until he does,
routing is ordinary and a request for that project is matched the ordinary way.

## What enforces each rule here, and where the answer is nothing

- **The checkout warnings, the branch check and the permission file** are enforced by the
  dispatcher, before the worker exists. The worker is given them in its brief; nothing relies on
  the Hand remembering them.
- **The item list** is enforced by `bin\Crew.psm1`: an id joins only a session worker, only once,
  and a list that cannot be read is refused rather than guessed at.
- **One gate run over the whole branch** is enforced by the gate line being absent from every fix
  prompt. No agent is ever inside a run and told to stop.
- **Pinned routing, the one-line mismatch and the step boundary** are obeyed by the Hand while it
  composes a reply, at a turn boundary. Prose is the mechanism and nothing else could be.
- **The exit conditions are enforced by nothing at all.** A Hand that forgets the mode falls back
  to ordinary routing, which fails safe; the warm worker it leaves running is still watched,
  because its wait and its record do not depend on the mode.

`docs\2026-10-21-project-session.md` records the design and the two decisions the King made.
