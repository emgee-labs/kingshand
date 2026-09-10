# 2026-09-10 - a dispatched worker can reach and drive the browser

Measured, first-hand, from inside a dispatched worker. Nothing here changed any behaviour: this
note records what was established so a later change can be designed against it rather than
guessed at.

## Why it was asked

Browser tool results are large. A browser-heavy session measured individual results between
roughly 100KB and 550KB, and a run of them put tens of megabytes into one session's context. If a
worker can drive the browser, that cost is paid by the worker and dies with it, and the Hand pays
for one `report.md` instead. If a worker cannot reach the browser at all, that is a hard limit and
every rule written around browser work has to assume the Hand does it.

So the question was never whether the browser is useful. It was where the payload lands.

## What was established

**The browser tools load in a worker.** They are deferred, and a worker's single batched load
returned all of them, including the two read tools the record is built from. `witness` owns the
exact load line and `bin\BrowserVerify.psm1` owns the required set; both were used as written and
the availability check came back available with nothing missing. Being dispatched into a worktree
costs a worker nothing here - the tool inventory is the session's, not the directory's.

**They drive a real browser, not a stub.** A tab was created, navigated to a static
documentation-example page, its rendered text read back, its console and network traces read, and
the tab closed again. The page text that came back was the page's, so a browser genuinely answered.

**Tab isolation is structural, and it is the reason this is safe.** A worker's session gets its own
tab group. Asked for its context without permission to create one, a fresh worker was told no group
exists for this session; creating one produced a group holding exactly one new tab; closing that
tab emptied the group and the browser removed it. A worker therefore starts with no handle on any
tab it did not create, and the close tool refuses anything outside its own group. Nothing the King
has open is reachable by accident. That is worth preserving: it is what makes driving a browser the
King is sitting in front of an acceptable thing for a background worker to do at all.

**Which browser gets driven is not a worker's decision, and it cannot be made into one.** Two
browsers were connected to the account during this run. The listing result instructs the caller to
open a selection prompt and let a human pick, which a background worker cannot do - there is nobody
attached, and opening any interactive prompt is forbidden. The alternative mechanism broadcasts a
confirmation screen to every connected browser and waits for someone to click it, which is worse:
it interrupts the King in order to serve the worker. So a worker drives whichever browser is
currently selected, cannot find out which one that is, and must not try to change it. With one
browser connected this is invisible. With two it is a real hazard, and it is the strongest argument
against a worker driving anything that depends on which profile it lands in.

**Console and network tracking start when the tool is first called, not when the page loads.** The
first read of each returned nothing at all and said so. A second navigation, after both had been
called once, returned a full trace. A worker that navigates first and reads afterwards gets an
empty result and no error, which reads exactly like a clean console. The order matters and it is
not the obvious one.

**A trace from a real browser carries the browser's own extensions.** One document request produced
33 network entries; 32 were script injections by extensions installed in that browser and had
nothing to do with the page. Evidence read out of a personal browser has to be filtered before it
means anything, and an unfiltered trace is both misleading and large.

**The payload lands in the worker, which is the whole point.** Every result above arrived in the
worker's own context. There is no path by which a worker's tool result is surfaced to the Hand: the
Hand sees the worker's `report.md`, its final message, and whatever is on its screen. So the
premise holds and the design is viable. One caveat, stated because it is the only leak: a worker's
screen is readable while the worker lives, and that read is wider than what the worker chose to
print. `bin\Herdr.psm1` reads the rendered terminal with the `recent-unwrapped` source, which
includes scrollback, so a rendered tool-result block is on that screen whether the worker printed
anything or not. The bound is the rendered line count - 40 by default - and the truncation the
terminal already applied to the result. The full tool result never reaches the pane, so the payload
still lands in the worker.

## What could not be established, and why it was not tested

**What happens to a worker's tab when the browser closes underneath it.** Answering it means
closing a browser the King is using. Not tested, and it should not be tested that way - the honest
version of this answer comes from a worker finding out during ordinary work and recording it.

**Whether two sessions driving the same browser interleave or one takes over.** Tab grouping is
per session, which strongly suggests they coexist, but the browser *selection* is account-wide and
shared. Confirming the interaction needs two sessions driving at once, which this run could not
arrange without commandeering another worker.

Both are recorded as not established rather than inferred. The tab-group evidence above is what is
known; the rest is not.

## What a follow-up would change

Recommendations only. Nothing below was implemented, and each is a separate change through its own
gate.

- **`witness` should say to call the console and network reads before the navigation to be
  observed.** It currently describes reading them afterwards, which returns an empty trace on a
  first call and looks like a clean run. This is the finding most likely to produce a false pass.
- **`witness` should say to filter the network trace rather than read it whole**, and say why: a
  personal browser's extensions dominate the trace and the unfiltered result is large.
- **`witness` should state that a worker never selects or switches the browser.** The selection is
  account-wide, the prompt for it cannot be answered by a background worker, and the broadcast
  alternative interrupts the King. A check that depends on landing in a particular browser is a
  check to record as not checked.
- **Nothing in `bin\BrowserVerify.psm1` needs to change.** Its required set is exactly what a
  worker needs and its availability check answered correctly on the first call.

## What this does not settle

That a worker *can* drive the browser is not an argument that it *should* on any given task.
`witness` already makes the browser step opt-in per brief and that stays right: this note removes a
suspected hard limit, it does not widen the opt-in.
