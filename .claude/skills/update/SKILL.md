---
name: update
description: Use when the user wants kingshand itself moved to the latest version - e.g. "/update", "update", "update kingshand", "get the latest kingshand", "am I on the latest?", "is there a newer version". Fast-forwards this installation to the latest tagged release, re-runs install.ps1, and reports the version it moved from, the version it moved to, and what changed between them. Refuses on a dirty tree, on any live worker, off the release branch, or where no release has been tagged yet.
tools: Bash, PowerShell, Read
version: 1.0.0
---

# Update

Move this installation of kingshand to the latest release, and say what that changed.

**This is not project work and it needs no worker.** Nothing here edits a tracked file: it
fast-forwards the checkout to a release somebody already cut, then re-runs the installer. Hard rule
1 is about doing a project's work yourself, and there is no work here to do - so do not write a
brief, do not dispatch, and do not load `muster`.

**Run it only when the user asks.** An update moves `CLAUDE.md`, `bin\` and the skills underneath
a running session, so it is their call and never a housekeeping task you take on yourself.

## Step 1 - Run it

One command, from anywhere:

```powershell
Import-Module $env:KINGSHAND_HOME\bin\Update.psm1 -Force
Invoke-KingshandUpdate -Root $env:KINGSHAND_HOME
```

It returns a result rather than printing a report, and it never throws: read `status`, and read
`reason` whenever `status` is `refused`.

Everything it does is in `bin\Update.psm1`, which owns the whole contract - the four refusals, how
the latest release is chosen, and what "what changed" means. Do not compose your own git commands
to work around a refusal, and do not fetch, merge, reset or check out anything by hand.

## Step 2 - Report what happened

Three outcomes, and each is two or three sentences of plain words. Never paste the result object.

**`updated`** - say the version it moved from and to, then what changed. `changes` holds the commit
subjects between the two releases; give at most five and say how many more there were. If
`rereadNeeded` is true, say that this session's own instructions moved and **read `CLAUDE.md`
again now**, before doing anything else - you were started on the old ones. If `installOk` is
false, say that plainly with `installError`: the update landed but the installer did not finish, so
this installation may be configured for the version it left behind.

**`already-current`** - one line. They are on the latest release, and name it.

**`refused`** - lead with `reason`, which names the concrete thing in the way, then what they can
do about it. Nothing was touched, so say that too. The four:

- **A dirty working tree.** Their own uncommitted changes. Commit them or put them aside; this
  never stashes, resets or discards anything.
- **A live worker.** An update would move `bin\` and the skills out from under a worker mid-task.
  Wait for it to finish, or stop it. Liveness is read from herdr rather than from the durable
  record, because the two disagree exactly when it matters - `CLAUDE.md` states that precedence.
- **Not on the release branch.** Switching branches is theirs to decide, not an update's.
- **No release has been tagged yet.** There is nothing to update to. Say so as a fact rather than
  as a fault: it is the ordinary state of a repository whose first release has not been cut, and
  the alternative - quietly pulling whatever was pushed last - is the thing this deliberately does
  not do.

Report a refusal as an answer, not as a failure to escalate. The user asked whether they could
update; "no, because X" is the answer.

## What it never does

- **It never creates or pushes a tag.** Cutting a release is the King's own step, and
  `docs\2026-09-03-versioning-and-update.md` is where that procedure is written down. Point them
  there if they ask how a release is made; do not run it for them.
- **It never updates to a branch head.** A release is a tag - a deliberate act - and a branch head
  is whatever was pushed last. That is the point of the whole command, and it is also what keeps
  updating independent of which branch happens to be default.
- **It never forces, stashes, resets, rebases or merges non-linearly.** The only write is a
  fast-forward, and one that cannot happen does not happen.
- **It never touches the user's own state.** `data\`, `state\`, `config\`, `tools\` and
  `instructions.md` are gitignored, so no fetch or fast-forward can reach them.
- **It never reports success it did not have.** A version it could not read reads as unreadable,
  and no version is ever invented to fill the gap.
