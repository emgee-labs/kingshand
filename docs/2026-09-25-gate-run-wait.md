# Waiting on a gate run, and what a read it could not take means

Date: 2026-09-25
Status: **current**

## What this records

There was no supported way to wait for a gate run to change state, so every session that needed one
hand-wrote it. On 2026-09-25 four such watches ran over the same output in a single night and three
of them answered wrongly. The expensive one was keyed on the branch head moving: a run parked with
two decisions waiting sat unanswered for **two hours and twenty-six minutes**, because a park does
not move the head, and nothing woke anybody until the watch hit its own ceiling. Of the other three,
one matched `outcome:` inside the tool's own help text, one reported a run settled while its gate
was still running in a background shell, and one read a park that was already there as the answer to
a steer just sent.

`bin\GateRunWait.psm1` is the one wait. `bin\GateRun.psm1` is the one reader beneath it and owns
everything about turning output into state; this note records the three questions the wait adds on
top, and what a later change must not undo. The module's own header owns the mechanics.

## The three questions, and where each is answered

**What is the state?** Not this module's question. `Get-GateRunState` is the only source and nothing
here ever sees the tool's output. A wait that read text would be the fifth hand-written watch rather
than the end of them.

**What counts as a change?** A transition away from a baseline taken at the first readable read -
never a condition that happens to be true. This is the concrete defect from the same night: a park
that predated a steer satisfied a watch armed after it, so the steer read as answered instantly when
nothing had happened at all. A wait armed on a parked run must sit there.

**What does a read it could not take mean?** This is the question the wait adds, and the reader does
not have it - the reader answers once and hands its answer back. A wait fires repeatedly, against a
clock, with a baseline to protect.

## An unreadable read is not a state, and that has three consequences

The reader answers three ways. `has-run` and `no-run` are readings; `unreadable` is the refusal to
guess. **A reading the tool gave is a state however empty it is, and a read the reader refused is
not a state at all.** Three things follow, and each removes a wrong answer that was available:

1. **It can never be the baseline and never an endpoint.** If a refusal could be a baseline, the
   next readable read is a transition from `unreadable` to `has-run` - so the wait reports a change
   in the reader's luck as a change in the run. That is the least obvious of the three wrong answers
   and the worst, because it wakes a caller with a change list that describes nothing that happened.
2. **One failed read does not end the wait**, stop the clock or touch the baseline. `axi status`
   asks a local daemon, and a wait armed as a run starts will meet one that is not answering yet. A
   wait that cannot survive its own first second is not a wait, and a wait that wakes a caller for
   nothing gets ignored - which is the silence it was built to remove, arriving by another door.
3. **Enough failed reads in a row do end it, naming the read rather than the run.** Three
   consecutive, by default. At that point the read itself is broken - node gone, daemon wedged,
   binary vanished - and polling a read that cannot work until the timeout learns nothing and then
   reports a quiet run. That is the silence arriving by a third door.

A readable read clears the consecutive count, because consecutiveness is the whole evidence for
"the read is broken" and a scattered failure is ordinary noise.

**And every result says how blind it was.** `unreadableReads`, `consecutiveUnreadable` and
`lastUnreadable` are on the object whatever the reason, including the successful ones. A timeout
that spent a third of its reads refused cannot honestly say the run did not change, and saying so
is the difference between "the run is quiet" and "I could not always tell".

## What a later change must not undo

- **Never let an unreadable read become a baseline, an endpoint, or evidence of quiet.** The three
  consequences above are one rule seen from three sides, and each side has a forced test.
- **Never key a wake on the branch head.** It is the watch that cost two hours and twenty-six
  minutes. The head moving is a side effect of a step doing work, not the run changing state, and
  the step statuses already report that work. It is deliberately not in the signature.
- **Never key a wake on the residual finding summary.** `run.findings` survives findings being
  declined - a cancelled run on this repository still reads `1 awaiting, 1 auto-fix` with nothing
  waiting on anybody - so a count changing is not a state changing.
- **Never put a field that moves on every read into the signature.** Durations, `active_for`,
  `last_activity`, `agent_pid` and the reading's own timestamp all do. A signature carrying any of
  them makes every read a change, and a wait that always returns is no wait.
- **Never report a timeout as an outcome.** `changed` being false is the absence of an outcome, not
  one of its own - the same distinction `Wait-HerdrAgentProgress` makes with `settled` for a worker.
  The two things that end a wait without the run moving are the clock running out and the read
  giving up, and neither is a fact about the run.
- **Never read a run's flag by casting its text.** `[bool]'False'` is `$true` in PowerShell, because
  the cast asks whether the string is empty rather than what it says. A flag is read from the
  property's type, which is the reader's own rule one layer up.
- **Never take an outcome word this wait does not know as a pass.** It ends the wait - the run said
  it is over, and waiting for a word that happens to be recognised is waiting forever - and it is
  reported as not passed, with the tool's word carried verbatim and named as unrecognised. That is
  the reader's rule about an unrecognised `awaiting_agent`, applied at the other end of the run.
- **Never let the default timeout fall below `(tolerance + 1) * poll`.** It is a floor rather than a
  constant for that reason: a timeout shorter than the failures it takes to notice a broken read
  makes the unreadable branch unreachable for every caller that overrides nothing. This repository
  has already paid for that once, with a four-minute default against a twenty-minute stall
  threshold.

## What this is not

It does not watch a worker. `Wait-HerdrAgentProgress` watches a process and this watches a pipeline;
they have different failure modes and are deliberately separate. It does not drive a run either - it
reaches the gate binary only through the reader, which cannot drive one.
