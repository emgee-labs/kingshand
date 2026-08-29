# Worker control plane: herdr

Date: 2026-08-29
Status: decided
Supersedes: `2026-08-28-worker-control-plane-decision.md`

## The decision

Kingshand spawns and controls workers through herdr. Each worker is an ordinary interactive Claude
Code session running in a herdr pane, in a git worktree kingshand creates itself. `claude --bg
--worktree` is gone, and so is the whole `claude agents --json` / `logs` / `stop` / `rm` / `attach`
surface it came with.

`bin\Herdr.psm1` is the only place that knows herdr's command line. Nothing else composes one.

## What prompted it

Yesterday's record said the cheap option won because no worker had hung yet. One did, the next day.
It called `AskUserQuestion`, drew a menu nobody could see, and waited five to six hours. The old
control plane could not tell that state apart from working: a hung worker and a busy worker looked
identical, so the hang was found by the user asking rather than by anything noticing.

That was the trigger this record's predecessor wrote down for itself, and it fired sooner than the
predecessor expected.

## Why herdr answers it

herdr hosts the agent in a terminal it owns, so it can both write into it and read what is on it.
Two capabilities follow, and they are the whole reason for the move.

**It classifies state.** `idle`, `working`, `blocked`, `done` - and `blocked` is a first-class
state, detected from what the agent actually rendered. In the trial, the five-hour hang was a
state herdr reported within seconds of the menu appearing. **That classification did not hold in
production, and the correction is recorded below** - what survives is the capability underneath
it, that herdr can be asked what is on a worker's screen.

**It waits on state.** A wait blocks inside herdr and returns the moment the worker reaches one of
those states. The Hand's dispatch arms one, and its completion is the wake. There is no polling
loop left anywhere, which is not just tidier - a poll on a 20-second interval was a promise the
Hand had to keep making to itself, and the defect it was written to fix was the Hand not keeping it.

Steering came along with it. A running worker can be sent text, and a blocked one can be answered a
key at a time. That was the capability the predecessor record wrote off as not worth a daemon; it
turns out to be free once something owns the terminal.

## The evidence

All of it observed on this machine against herdr 0.8.2, protocol 20, on native Windows. Nothing
below is inferred.

- A genuinely busy worker read `working` for the full duration of a 75-second turn and settled to
  `idle` when it ended. The feared "reports everything as dead" failure did not occur.
- State does not come from the process name. It comes from priority-ordered regex rules in a
  per-agent manifest run against the rendered terminal, and the manifest for Claude Code is current
  and fetched from herdr's own server.
- A worker made to open an `AskUserQuestion` menu read `blocked` twelve seconds later, and a wait
  armed on `blocked` beforehand fired with it. **This held in the trial and does not hold
  generally** - see the correction below, which was measured later on the same machine.
- Sending that worker a prompt while blocked was refused outright, with a distinct error, rather
  than silently swallowed.
- A clean `/exit` proved the worker stopped in 1.7 seconds. A hard kill was detected in 662 ms.
- Text arrives intact: a 3,374-character prompt reached the worker whole.

## Correction: blocked detection does not hold

Added 2026-08-29, after a live end-to-end run of this layer. The trial evidence above is real and
stays; this is what happened when the same thing was measured again in production conditions.

herdr 0.8.2 with agent-detection manifest 2026.08.21.1 does **not** reliably classify a Claude
Code worker sitting on an unanswered `AskUserQuestion` menu. With the menu visibly on screen:

- `agent explain` reported `state: idle`, matched by rule `live_prompt_box` at priority 950. Rule
  `live_blocked_form` at priority 980 - the one that fired in the trial - evaluated and did not
  match. Every blocked rule failed.
- Minutes later the same still-blocked worker reported `done`, while a genuinely finished worker
  reported `idle`. The two states effectively inverted.

**Correction, established later the same day: the cause was terminal width, not the manifest.**
Those panes were 3 to 6 columns wide, rendering one character per line, because dispatch split an
existing pane for each new worker and every split halved the survivors. herdr's rules are regexes
over the rendered screen, so they cannot match a UI that never renders - and neither can
kingshand's own guard. Re-tested at 94 columns, herdr classified the same blocked worker correctly,
and so did the guard. Dispatch now gives every worker its own workspace; four created in a row
measured 93-94 columns with no degradation.

So the accurate statement is not "herdr's blocked detection does not hold". It is that **detection
of any kind needs a readable terminal**, and kingshand was destroying the terminal it depended on.
The guard stays anyway: one correct classification is not proof across a Claude Code interface
change, herdr's rules are a network-fetched artifact that can lag one, and a screen read costs
almost nothing against a worker silently reported as finished.

The consequence is worse than the hang this port was built for. `Wait-HerdrAgent` with no `-Until`
matches `idle`, `done` or `blocked`, so a worker waiting on a human wakes the Hand claiming
completion: previously the worker went silent, now it is actively reported as finished, and
whatever is downstream tears it down and reports work nobody did.

**Kingshand therefore no longer relies on herdr's classification for the blocked case.** The
worker's screen is the authority, and `bin\Herdr.psm1` owns the guard in three functions:

- `Test-HerdrAgentAwaitingInput` reads the LIVE VIEWPORT - `agent read --source visible` - and
  answers whether an interactive prompt is on screen now. The live viewport is load-bearing:
  `recent` and `recent-unwrapped` include scrollback, so a worker that answered a menu earlier
  still holds that text in history and would read as blocked forever.
- `Get-HerdrAgentState` is herdr's state corrected by that screen, returning `blocked` whenever a
  prompt is showing whatever herdr said. It is the only state function anything downstream calls,
  and `bin\Get-CrewStatus.ps1` routes through it, so nothing above reads `agent_status` raw.
- `Wait-HerdrAgentSettled` is the guarded wake. It wraps the wait, re-checks the screen before
  reporting a state, and distinguishes "not settled" from a state rather than inventing an outcome
  on a timeout.

The classification is still used for `working` and for waking at all, which is what herdr is
needed for. What is not used is its word for whether a stopped worker is finished or waiting on a
person, and `muster` no longer treats any state alone as proof of completion - a worker is done
when it settled, is not awaiting input, and left the `report.md` its brief required.

## What this costs, stated plainly

**No arguments can be passed to a worker, at all.** herdr's argument form is broken on Windows for
Claude Code - it launches through a mechanism that cannot run a PowerShell entry point - so the
only working shape is the bare launch. Everything that used to be a flag now lives in the
worktree's own `.claude\settings.local.json`, written before the worker starts. A future
requirement that genuinely needs a command-line argument has nowhere to go.

**A fresh worktree hits the folder-trust dialog.** The old spawn path inherited trust and never
needed its own entry; this one does, so trust is pre-seeded before the worker starts. Skip that and
the worker starts up blocked on a dialog instead of working.

**A force-killed worker costs its pane permanently.** It never sends its terminal-mode reset, so
the pane echoes every later keystroke as literal junk and no herdr command recovers it. The
worktree is never harmed - it is only a directory - but the pane must be discarded and a new one
made. Hence: always `/exit`, never a kill.

**Answering a prompt is a wrong-answer risk, not just a fiddly one.** Sending an arrow key and
Enter in one call selects the wrong option and reports success while doing it. Keys go one per
call, with the screen read back in between.

**Workers run with transcript saving off.** The Hand is itself a Claude Code session, so the herdr
server and every pane inherit `CLAUDE_CODE_CHILD_SESSION`. Both are scrubbed where kingshand starts
them, but a herdr server it did not start carries whatever it inherited. The practical consequence
is that the session transcript is not a reliable fallback for a worker's findings any more.
`report.md` is not a nicety; it is the only durable record.

**herdr keeps state outside the repository**, in `%APPDATA%\herdr` and `%LOCALAPPDATA%\herdr`, and
there is no way to redirect it. Its server also fetches detection manifests over the network at
start, falling back to bundled ones when offline.

**The fragility moved rather than went away, and it has already cost us.** State classification is
coupled to Claude Code's rendered interface and to herdr shipping a manifest that matches it. This
was written as a future risk; it was live at the time of writing. Manifest 2026.08.21.1 does not
classify the blocked case, and it degraded exactly as predicted - silently, with a confident wrong
answer rather than an error. A versioned, network-fetched artifact can be fixed without waiting
for a release, which is the good half; the bad half is that nothing announces the degradation, so
kingshand carries its own screen check rather than waiting for a manifest to be right.

## What would change the decision

- Claude Code gains a first-class scriptable way to run, watch and steer a background session. That
  would make owning a terminal unnecessary and this whole layer removable.
- State classification degrades further. The blocked case has already gone, and the answer was to
  read the screen directly rather than to abandon herdr - the terminal it owns is what makes that
  possible at all. What would genuinely reopen the decision is losing `working`, or the screen
  read itself becoming unreliable, because then nothing distinguishes a busy worker from a stuck
  one and the case for this layer is gone.
- herdr's argument handling is fixed on Windows. That does not undo the decision, but it would let
  configuration go back to being explicit rather than written into a settings file first.

## What must not be undone

- The wait is an event, not a poll. Reintroducing a sleep-and-check loop rebuilds the thing this
  replaced and re-opens the silence it was meant to close.
- `blocked` reaches the user immediately, and is never answered on their behalf. It is the defect
  this port exists to fix.
- The screen check stays, and it reads the live viewport. Deleting it, or pointing it at `recent`
  or `recent-unwrapped`, restores a control plane that reports a worker waiting on a person as
  finished. No state is ever proof of completion on its own.
- One file knows herdr's command line. Two would mean the next migration touches everything again.
