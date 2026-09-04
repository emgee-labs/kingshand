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

1. Write the durable flag, so the mode survives a restart and a fresh session picks it up:

   ```powershell
   $afk = Join-Path $env:KINGSHAND_HOME 'state\.afk'
   Set-Content -LiteralPath $afk -Encoding utf8 -Value (@(
     "since: $((Get-Date).ToUniversalTime().ToString('o'))"
     "note: <whatever they said - 'back in an hour', 'overnight'>"
   ) -join "`n")
   ```

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

## While they are away

Handle each wake and then go quiet again. Nothing routine reaches them.

**A worker finished, green, inside its brief, on a `+yolo` project.** Land it per the project's
posture, exactly as you would with them present. Record it for the return digest. Do not message.

**A worker finished and anything is unclear** - scope drift, a result you cannot verify. Set its
stage, write the outcome down, and batch it. `decree` still owns any unresolved decision and still
applies.

**A worker is parked on a decision its brief did not settle.** It wrote the question into its
`report.md` and ended its turn, so nothing is hanging and nothing
is lost while you think. Every posture parks that way, so this is not only the gated ones: a
review gate's ask-user finding is one route into it and not the only one. Load `petition`, whose
away-mode test owns whether this one is yours to answer, and take the route back into the worker
from `muster` Step 6. Register it under `decree` either way - what you decided, or the question the
test left standing with him - carry it into the return digest, and do not message.

**A worker is blocked on a prompt.** This is the case regency exists for and the one to get right.

- Do **not** send it keys. Not Enter, not an arrow, not "the obvious answer".
- Read its screen and record the question verbatim, so they answer the real thing on return.
- Then choose, and prefer the first: leave it blocked if it costs nothing, so the worker can be
  answered and resumed when they get back. Stop it with `Stop-HerdrAgent` only if leaving it holds
  something else up - and never force-kill, because that costs the pane permanently.
- Its worktree stays. Always.

**A worker failed.** Record the failure and the evidence. Do not re-dispatch it with a guessed fix -
a failure they have not seen is not a failure you understand yet.

**A worker has stopped advancing.** A wait reports this as `stalled`, and it is not the same as one
taking longer than expected - nothing on that worker's screen has moved for the whole threshold.
Load `rally`, which owns the response, and take from it only what is safe to do unwatched: read the
screen, record what the work is parked on and how long it has been there, then batch it. A steer, a
relaunch or a stop is a judgement they stepped away from. Its worktree stays.

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

1. Remove `state\.afk`.
2. Give the digest **before** answering whatever they just said, unless what they said is urgent.
   Short, and in this order: what landed, what is waiting on them, what broke, what is still
   running. Every blocked worker's question, quoted. **Every finding you decided in his stead,
   with the reasoning and whether it rested on a recorded position or on your own judgement** -
   that flag is what makes the digest reviewable, and `petition` owns why. Read those back from
   the notes `decree` closed them with rather than from memory: this digest is built inside a
   session and a restart before he returns takes it with it, while the notes are still there.
3. Then answer them.

If nothing happened, say exactly that in one line. "Nothing needed you" is a complete and useful
report, and padding it is how the digest stops being read.

A message that starts with `/regency` or `/afk` refreshes the mode rather than ending it.

## What this cannot do, stated plainly

**Nothing supervises the fleet if this Claude Code session ends.** The waits are background jobs
inside the session that armed them; closing the terminal, a crash, or a reboot takes them with it.
The workers keep running and their reports still land on disk, but nothing is watching and nothing
will wake. The next session picks the flag up and re-arms - that is recovery, not continuity.

Say this once, in one line, to anyone entering a regency for longer than they will keep the window
open. It is the difference between an away mode and a promise you cannot keep.
