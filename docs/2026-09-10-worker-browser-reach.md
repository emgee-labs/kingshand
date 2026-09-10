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
the availability check came back available with nothing missing. One tool was loaded on top of that
line rather than from it, and the tab-close recommendation below names it. Being dispatched into a
worktree costs a worker nothing here - the tool inventory is the session's, not the directory's.

**They drive a real browser, not a stub.** A tab was created, navigated to a static
documentation-example page, its rendered text read back, its console and network traces read, and
the tab closed again. The page text that came back was the page's, so a browser genuinely answered.

**Tab isolation is structural, and it is most of the reason this is safe.** A worker's session gets
its own tab group. Asked for its context without permission to create one, a fresh worker was told
no group exists for this session; creating one produced a group holding exactly one new tab;
closing that tab emptied the group and the browser removed it. So the group held only the tab the
worker itself created, and a worker starts with no handle on any tab it did not create - nothing
the King has open is reachable by accident through a tab-scoped tool. The tool's documented
contract goes further and says only tabs in the session's own group can be closed at all, but that
is contract rather than evidence: testing it means aiming the close tool at a tab the worker did
not create, which this run was forbidden to touch.

That conclusion is bounded twice over. It covers the tab-scoped tools this run actually used, and
for those it is enough to make driving a browser the King is sitting in front of an acceptable
thing for a background worker to do. It says nothing about a tool that reads the screen or drives
mouse and keyboard: the procedure's base batch loads one of those and a find tool on every run, and
this run exercised neither, so there is no evidence here either way about what they reach. And the
stronger containment claim is untested. Both gaps are listed below.

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

**The payload lands in the worker, which is the whole point.** Every result above was returned into
the worker's own context window and none of it was added to the Hand's. That is the cost question
and the answer holds: the Hand does not pay context for a result a worker received, so the premise
stands and the design is viable.

Not being in the Hand's context is not the same as existing nowhere, and the second is what "the
cost dies with the worker" would have to mean. Two paths carry it further. The first is the
worker's screen, readable while the worker lives and wider than what the worker chose to print:
`bin\Herdr.psm1` reads the rendered terminal with the `recent-unwrapped` source, which includes
scrollback, so a rendered tool-result block is on that screen whether the worker printed anything
or not. That read is bounded by the number of rendered lines the call site asks for - the widest
written down anywhere is 60 lines - and by the truncation the terminal already applied, so the full
result never reaches the pane. The second has no such bound: the worker's on-disk session
transcript records tool output in full, and this repository names it in two places as somewhere
tool output lands. That is a durable, untruncated copy of the whole payload rather than a render of
it, and it is a path to anyone who goes looking, the Hand included. `CLAUDE.md` says the session
and its transcript go at teardown while `report.md` survives, so the on-disk copy is bounded in
time rather than permanent - this repository's stated behaviour, not something this run measured.

## What could not be established, and why it was not tested

**What happens to a worker's tab when the browser closes underneath it.** Answering it means
closing a browser the King is using. Not tested, and it should not be tested that way - the honest
version of this answer comes from a worker finding out during ordinary work and recording it.

**Whether two sessions driving the same browser interleave or one takes over.** Tab grouping is
per session, which strongly suggests they coexist, but the browser *selection* is account-wide and
shared. Confirming the interaction needs two sessions driving at once, which this run could not
arrange without commandeering another worker.

**Whether the close tool refuses a tab outside the worker's own group.** Its documented contract
says it does, and nothing seen here contradicts that, but confirming it means handing the close
tool a tab the worker did not create. Not tested, and not a thing to test against a browser
somebody is using.

**Whether the screen-and-input tool and the find tool are scoped to the session's tab group.** The
procedure loads `computer` and `find` on every run and this run used neither, so nothing here says
what they can reach. That is not evidence against them either - it is a gap, and the tab-group
argument above does not cover it.

All four are recorded as not established rather than inferred. The tab-group evidence above is
what is known; the rest is not.

## What a follow-up would change

Recommendations only. Nothing below was implemented, and each is a separate change through its own
gate.

- **`witness` should say to call the console and network reads before the navigation to be
  observed.** It prescribes no order at all today, and the natural reading of that silence is to
  navigate and then read, which returns an empty trace on a first call and looks like a clean run.
  This is the finding most likely to produce a false pass.
- **`witness` should say to filter the network trace rather than read it whole**, and say why: a
  personal browser's extensions dominate the trace and the unfiltered result is large.
- **`witness` should state that a worker never selects or switches the browser.** The selection is
  account-wide, the prompt for it cannot be answered by a background worker, and the broadcast
  alternative interrupts the King. A check that depends on landing in a particular browser is a
  check to record as not checked.
- **`witness` should load `tabs_close_mcp` and say to close the tab it created.** That is the tool
  this run used, loaded deliberately on top of the batched load line rather than from it, and it is
  the only reason the tab could be closed at all. The load line carries no way to close a tab and
  the procedure never mentions closing one, so a worker that follows it as written leaves its tab
  open in the browser the King is using. The tab group only empties, and the safety argument above
  only holds, if the tab the worker opened is closed when the checks are done. The load line and
  the required set both need that exact name.
- **The claim that a worker cannot see a variable set after the server started should come out of
  `bin\BrowserVerify.psm1` first.** That is where it originates: the module states it as measured
  fact and builds its reason strings on it, one of which tells the report the worker was started
  from an older environment. Those strings are what a worker copies into `report.md`, so the claim
  this run's evidence disproves reaches a durable record through the module rather than through the
  skill that relays it. The not-found message is not the problem and its restart line can stay - a variable
  set in neither place does need a person - and it is the routine presentation of a stale worker
  environment, for a variable that is set, that is wrong.
- **`witness` carries the same claim twice, and both are relays.** Once in the credential section,
  and once as the reason not to write an import path against the home variable. The rule in the
  second place stays right for the other reason already given on those lines - the installation's
  own directory is outside what a worker can reach - so only the rationale needs correcting there,
  never the rule.
- **`bin\BrowserVerify.psm1`'s required set covers reaching and reading a page and nothing else.**
  Its availability check answered correctly on the first call, and every tool in the set earns its
  place. What the set has no tool for is closing a tab, so a run can pass the availability check and
  still have no way to clean up after itself. If the tab-close recommendation above is taken, this
  is where it has to be enforced, because a check that is needed by every run that creates a tab is
  not one of the per-check tools the set deliberately leaves out.

## Which worker-environment claim this run supports

The worker also compared its own process environment against the live user-scope registry: 25 of
the 26 user-scope variables matched exactly, the only difference being the merged `Path`, which
cannot match. The server had been up half an hour, so this supports the fresh-per-pane claim
without settling it on its own. `docs\2026-09-04-worker-environment-propagation.md` owns the
decisive measurement. `docs\2026-09-03-browser-verification.md` states the opposite, and correcting
it is the first thing a follow-up should do; that correction is deliberately not part of this
change, which is scoped to this note alone.

## What this does not settle

That a worker *can* drive the browser is not an argument that it *should* on any given task.
`witness` already makes the browser step opt-in per brief and that stays right: this note removes a
suspected hard limit, it does not widen the opt-in.
