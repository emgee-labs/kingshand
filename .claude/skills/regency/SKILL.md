---
name: regency
description: Hold the fleet while the King is away from the machine. Use when the user says they are going afk, stepping out, going to bed, back in an hour, "watch this while I'm gone", invokes /regency or /afk, or when state\.afk already exists at session start. Keeps workers supervised, batches everything that does not need them, never answers a prompt a blocked worker is sitting on, decides a parked worker's unsettled decision only on petition's reversibility test, and ends the moment they speak again.
---

# Regency

A regent governs while the monarch is away and holds no new powers by doing so. That is the whole
contract. Read the limits before the procedure.

## What a regency never grants

Being away is not consent. Every one of these still waits for the King, however long that takes:

- **A landing that is not already authorised.** `+yolo` already permits landing green work inside
  the brief's accepted criteria; that stands and is unchanged. Regency adds nothing to it. A
  project without `+yolo` lands nothing while they are away.
- **Anything a blocked worker is sitting on.** A prompt drawn on a worker's screen is the King's
  to answer and nobody else's - see the blocked-worker rule below, which is unchanged. A decision
  a worker *wrote into its `report.md`* is a different case and no longer this one: `petition`
  owns whether you may answer that and by what test, and it is the only place the test is stated.
- **Anything destructive or irreversible.** Force-push, history rewrite, deleting a branch or a
  worktree holding unlanded work, dropping data. None of it, whatever the posture.
- **Anything security-sensitive.** Credentials, tokens, permissions, published artifacts, anything
  that leaves the machine.
- **A red merge.** Never, and being away does not make it more tempting, it makes it worse.
- **New work they did not ask for.** An empty queue while they are out is a healthy state. Do not
  invent work, tidy, refactor, or improve anything on your own initiative.

**This rule changed deliberately, on the King's own instruction, and it is not an accident to be
repaired.** Regency used to say a worker's question was recorded and never answered, full stop.
Answering nothing woke him for SEO details and copy fixes and parked workers overnight on calls
that take a minute to undo, so he replaced the knowledge test with a reversibility test. A reader
who finds `Record it, never answer it` in this file's history should read it as superseded rather
than as a rule that went missing. Nothing else in the list above moved: this bought no authority
at all over a land, a delete, a cost, or anything destructive, irreversible or security-sensitive.
`docs\2026-09-04-parked-decision-route.md` is the record of why.

If a choice is close enough that you find yourself building a case for it, that is the signal to
batch it and stop.

## What regency actually does

1. Write the durable flag and open the journal, so both the mode and the account of it survive a
   restart and a fresh session picks them up. **Reuse an open period's `since:`, and mint a new
   timestamp only where no away period is open or the existing `since:` cannot be read:**

   ```powershell
   Import-Module $env:KINGSHAND_HOME\bin\AwayJournal.psm1 -Force
   $afk  = Join-Path $env:KINGSHAND_HOME 'state\.afk'
   $flag = Get-AwayFlag
   $since = if ($flag.present -and $flag.since) { $flag.since }
            else { (Get-Date).ToUniversalTime().ToString('o') }

   Set-Content -LiteralPath $afk -Encoding utf8 -Value (@(
     "since: $since"
     "note: <whatever they said - 'back in an hour', 'overnight'>"
   ) -join "`n")

   Open-AwayJournal
   ```

   This one block covers all three ways you arrive here - entering a regency, picking up a durable
   flag after a restart, and a `/regency` or `/afk` that refreshes the mode - and only the first of
   those starts a new journal. The journal is named from the flag's `since:`, so a fresh timestamp
   on a period already open orphans the record written so far and the return digest reports the
   remainder as if it were the whole night. Updating the note mid-period is the ordinary thing to
   do while they are out; it must never be the thing that breaks the record.

   Opening the journal here is what lets an away period that produced nothing be told apart from
   one whose account was lost. `The away journal` section below owns the rest.

2. **Confirm what you can actually see, and say so if the answer is "not everything".** Regency
   rests entirely on noticing a worker has stopped, and that comes from reading its screen:

   ```powershell
   Import-Module $env:KINGSHAND_HOME\bin\Herdr.psm1 -Force
   foreach ($a in (Get-HerdrAgents)) {
     [pscustomobject]@{ worker = $a.name; readable = (Test-HerdrAgentReadable -Name $a.name) }
   }
   ```

   **Any worker reporting `readable = False` cannot be watched.** Its terminal is too narrow to
   render the text that identifies a prompt, so a stuck worker and a working one look identical.
   Say that plainly before they leave, naming the worker, and let them decide whether to go. Do not
   enter a regency silently over a worker you cannot see.

3. Arm a wait for every live worker, exactly as `muster` Step 4 describes. Nothing else wakes you.
   One per worker, and re-arm on timeout.

4. Say one line and stop talking. No plan, no reassurance, no list of what you will be doing.

## The away journal

Everywhere below that says to record something means **one line in the away journal, written the
moment it happens**. The journal is `data\away\<stamp>.jsonl`, one file per away period, named from
the flag's own `since:` - so a second regency cannot touch the first one's record, and a session
that restarts mid-period appends to the file already there rather than starting a new one.

```powershell
Import-Module $env:KINGSHAND_HOME\bin\AwayJournal.psm1 -Force
Write-AwayJournalEntry -Kind landed -Text 'T-1001 merged to dev' -Worker <id>
```

`-Kind` is one of `dispatched`, `landed`, `failed`, `blocked`, `decided`, `waiting`, `closed-out`
and `note`, and nothing else is accepted. `-Evidence` carries what a failure actually was, in its
own words. A `decided` entry is refused without `-Basis recorded` or `-Basis judgement`, because the
digest has to say whether the call rested on a position the King had already stated or on your own
judgement.

**Write it as it happens, never at the end.** The timestamp is stamped by the module and cannot be
supplied, and nothing can be written once the flag is gone - so a journal assembled at return time
is both impossible and unable to pass as a contemporaneous record. That is the whole point of the
file: an account composed at the end is session memory with extra steps, and a restart takes it
exactly as it always did.

**The journal is a record and never an authority.** Writing an outcome down grants nothing, moves no
posture and settles no decision. Every limit in *What a regency never grants* stands whatever the
journal says, and `petition` still owns what may be decided in his stead.

**It is kept on return, never cleared.** What was decided in his name, and on what basis, is
reviewable the next morning and the next week; deleting the record at the moment it becomes
reviewable is the wrong direction. `docs\2026-09-25-away-journal.md` argues that, and the choice of
`data\` over `state\`.

## While they are away

Handle each wake and then go quiet again. Nothing routine reaches them.

**A worker finished, green, inside its brief, on a `+yolo` project.** Land it per the project's
posture, exactly as you would with them present. Record it as `-Kind landed`. Do not message.

**A worker finished and anything is unclear** - scope drift, a result you cannot verify. Set its
stage, record it as `-Kind waiting` with what you could not verify, and batch it. `decree` still
owns any unresolved decision and still applies.

**A worker is parked on a decision its brief did not settle.** It wrote the question into its
`report.md` and ended its turn, so nothing is hanging and nothing
is lost while you think. Every posture parks that way, so this is not only the gated ones: a
review gate's ask-user finding is one route into it and not the only one. Load `petition`, whose
away-mode test owns whether this one is yours to answer, and take the route back into the worker
from `muster` Step 6. Register it under `decree` either way - what you decided, or the question the
test left standing with him - and record it in the journal as `-Kind decided` with its `-Basis`, or
as `-Kind waiting` where the test left it standing. Do not message.

**A worker is blocked on a prompt.** This is the case regency exists for and the one to get right.

- Do **not** send it keys. Not Enter, not an arrow, not "the obvious answer".
- Read its screen and record the question verbatim as `-Kind blocked`, so they answer the real
  thing on return and a restart cannot take the wording with it.
- Then choose, and prefer the first: leave it blocked if it costs nothing, so the worker can be
  answered and resumed when they get back. Stop it with `Stop-HerdrAgent` only if leaving it holds
  something else up - and never force-kill, because that costs the pane permanently.
- Its worktree stays. Always.

**A worker failed.** Record it as `-Kind failed`, with the evidence under `-Evidence`. Do not
re-dispatch it with a guessed fix - a failure they have not seen is not a failure you understand
yet.

**A worker has stopped advancing.** A wait reports this as `stalled`, and it is not the same as one
taking longer than expected - nothing on that worker's screen has moved for the whole threshold.
Load `rally`, which owns the response, and take from it only what is safe to do unwatched: read the
screen, record as `-Kind waiting` what the work is parked on and how long it has been there, then
batch it. A steer, a relaunch or a stop is a judgement they stepped away from. Its worktree stays.

**Everything else** - progress, output, a wait timing out, a worker that is slow but whose screen is
still moving - is not an event. Re-arm and stay quiet.

## The one thing that does reach them

Only this: something is on fire and waiting costs more than interrupting them. A credential expired
and everything is stalled. A worker is touching something it should not. A destructive action has
already happened. Anything where the honest sentence is "this could not wait".

Everything else, including every blocked worker, waits for the digest. A regency that interrupts is
not a regency.

## When they come back

Any ordinary message from them ends it. Bias every ambiguous case toward ending - a present King
outranks a durable flag, and wrongly staying in regency is worse than wrongly leaving it.

1. **Read the journal before you touch the flag.** The file is named from the flag's `since:`, so
   removing it first leaves the digest with nothing to render from.

   ```powershell
   Import-Module $env:KINGSHAND_HOME\bin\AwayJournal.psm1 -Force
   $away = Get-AwayDigest
   ```

2. Remove `state\.afk`.
3. Give the digest **before** answering whatever they just said, unless what they said is urgent.
   Short, and in this order: what landed, what is waiting on them, what broke, what is still
   running. Every blocked worker's question, quoted. **Every finding you decided in his stead,
   with the reasoning and whether it rested on a recorded position or on your own judgement** -
   that flag is what makes the digest reviewable, and `petition` owns why.

   **All of it comes out of `$away`, never out of this session.** `$away.byKind` holds each group
   and `$away.entries` holds them in the order they happened; the journal survives a restart and
   the session does not. Only "what is still running" is a live reading, taken from the fleet as it
   always was. `decree` is unchanged and still owns each decision's own lifecycle.

   **When `$away.readable` is `$false`, give `$away.summary` exactly as it stands and stop there.**
   Do not fill the gap from what you happen to remember. A thinner account nobody can tell is
   thinner is the precise failure this journal removes, and it arrives with no error at all.

4. Then answer them.

If nothing happened, say exactly that in one line. "Nothing needed you" is a complete and useful
report, and padding it is how the digest stops being read. That is `$away.summary`'s own answer for
an away period whose journal was opened and never written to, so an empty journal reads as a clean
night rather than as a missing one.

A message that starts with `/regency` or `/afk` refreshes the mode rather than ending it. Run step 1
above unchanged - it already reuses an open period's `since:` and rewrites only the note, which is
exactly what a refresh is.

## What this cannot do, stated plainly

**Nothing supervises the fleet if this Claude Code session ends.** The waits are background jobs
inside the session that armed them; closing the terminal, a crash, or a reboot takes them with it.
The workers keep running and their reports still land on disk, but nothing is watching and nothing
will wake. The next session picks the flag up, re-arms, and finds the journal with everything
recorded so far still in it - that is recovery, not continuity.

Say this once, in one line, to anyone entering a regency for longer than they will keep the window
open. It is the difference between an away mode and a promise you cannot keep.
