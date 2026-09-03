---
name: witness
description: Reference procedure for exercising a front-end change in a real browser and recording what was seen as evidence. A worker loads it when its brief carries a `## Browser checks` section, and the Hand loads it before writing that section into a brief. Owns the browser opt-in, the read-only boundary, the credential rule, and the record of what was verified, what failed and what could not be checked.
version: 1.0.0
---

# Witness

A change to a web front end can be asserted or it can be seen. This is how it gets seen, and how
what was seen survives the worker that saw it.

Two readers load this. **A worker** loads it when its brief carries a `## Browser checks` section,
before touching a browser tool. **The Hand** loads it before writing that section into a brief, to
know what a check has to say to be checkable.

## The opt-in is the brief, and there is no other one

**A brief with no `## Browser checks` section gets no browser step.** Not a shorter one, not a
quick look - none. Most work touches no browser at all, and a verification nobody asked for is
cost with no answer attached.

That section is the only input this procedure takes. Where a project has standing browser rules
of its own, they are pasted into it the way standing criteria are, so the worker still reads one
artefact and not two. Nothing is registered, nothing is inherited, and no project acquires a
browser step as a side effect of anything.

Each line of the section is one check, and the worker answers every one of them by name. A check
the Hand cannot state as something observable in a browser is a check to leave out rather than to
write vaguely: `- the settings drawer closes when the overlay is clicked` can be answered, and
`- the settings work` cannot.

## Before anything: can the browser be driven at all

The browser tools are deferred, so load them in **one** call rather than one call per tool:

```
ToolSearch: select:mcp__claude-in-chrome__tabs_context_mcp,mcp__claude-in-chrome__tabs_create_mcp,mcp__claude-in-chrome__navigate,mcp__claude-in-chrome__get_page_text,mcp__claude-in-chrome__read_console_messages,mcp__claude-in-chrome__read_network_requests,mcp__claude-in-chrome__computer,mcp__claude-in-chrome__find
```

Add `form_input` when a login is needed and `javascript_tool` when a check needs to read something
out of the page that text cannot show. Leave the rest.

Then settle availability mechanically rather than by eye, passing the names that actually came
back:

```powershell
Import-Module $env:KINGSHAND_HOME\bin\BrowserVerify.psm1 -Force
$tools = Get-BrowserToolStatus -Loaded @('<the tool names ToolSearch returned>')
$tools.available
$tools.reason
```

**The server is genuinely unreliable and its absence is an ordinary Tuesday.** It connected and
disconnected twice inside one conversation on 2026-09-03. So there is no retry loop here and no
waiting for it to come back: if it is not there, verification does not happen, and that is a
result to report rather than a problem to solve.

**When `$tools.available` is false, stop and write the record.** Every check becomes `not checked`
carrying that reason, and the run cannot come back verified:

```powershell
$record = Get-BrowserVerificationRecord -Unavailable $tools.reason -Declared @('<every id the brief listed>')
$record.summary
```

Say it plainly in `report.md` and in your final message: the change was not exercised in a
browser. **Never let that read as a pass**, never soften it to "verified by inspection", and never
substitute reading the code for running it - the whole point of the section is that inspection had
already been tried.

## Read-only by default

Navigating, reading a page, reading the console and reading the network trace change nothing and
need no permission. That is the default and it covers most checks.

**Anything that changes state on a server is different, and the brief has to authorise it.**
Submitting a form, calling an endpoint that writes, uploading, deleting, sending. The King's
standing rule is that nothing changes on a server without his word, and a verification step does
not relax it. With no explicit authorisation in the brief naming that action, the check is
recorded `not checked` with the reason, and you move on. **Do not ask** - there is nobody attached
to a background worker, and a question drawn in a browser reaches no one.

A login is the ordinary exception and it is still gated: signing in to an environment the brief
names is read-only in intent, so it is allowed where the brief asked for a check that needs it and
named the variable holding the login.

kingshand's generic stepwise-confirmation posture is queued and has not landed. When it does, this
defers to it and inherits whatever it says. **Do not build a second confirmation path here** - one
gate that fires on the brief is the whole mechanism until that one exists.

## Never open a dialog in the browser

A JavaScript `alert`, `confirm` or `prompt` blocks every later browser command until somebody
dismisses it by hand, and **there is nobody attached to a background worker**. The session cannot
be recovered from inside itself, so a single stray `confirm` costs the entire run.

So:

- Do not click a control that is guarded by a confirmation - a delete, a discard, a sign-out - and
  do not trigger one with `javascript_tool`.
- Where a check needs the state behind such a control, record it `not checked`, name the dialog,
  and move on. That is the right answer and not a failure to try harder.
- To get a value out of the page, log it and read it back with `read_console_messages`, filtering
  with the `pattern` parameter rather than reading everything.
- Where the application itself opens a dialog on load, the run ends there. Record every remaining
  check `not checked` naming that, and say so.

## A login is read, never written down

**No credential is ever written into this skill, a brief, a report or any file under `data\`.** A
project's notes name the variable and nothing else.

```powershell
$cred = Get-BrowserCredentialStatus -Variable '<THE_VARIABLE_NAME>'
$cred.found
$cred.summary        # safe to paste into report.md - the whole result carries no login
```

**The login is not in that result, and that is deliberate** - printing `$cred` puts every key it
holds into your pane and your transcript, so there is nothing there to leak. Get it only where you
are about to type it into the page:

```powershell
Get-BrowserCredentialValue -Variable '<THE_VARIABLE_NAME>'   # feed straight into form_input
```

Never print it, never echo it into a command line, never let it into the report. `$cred.summary`
is what the report gets.

**There is a trap underneath this, and the function is what handles it.** Workers are started by a
long-running server - measured at 24.8 hours of uptime on 2026-09-03 - and a process inherits its
environment block from its parent at the moment it is created. A variable set today is therefore
invisible to every worker that server starts, however long afterwards, until the server itself
restarts. Measured the same day: a variable set at user scope was absent from `$env:` in the
process that set it and in a child spawned after the set, while a registry read returned it from
both. So `$env:NAME` alone reads empty for a login that is perfectly well set, and the silent
failure looks exactly like a wrong password.

`Get-BrowserCredentialStatus` reads the process block first and the user environment second, so it
finds one the shell cannot see and says which source answered. **Never fall back to a bare
`$env:NAME` read** - that is the failure, not the fix. Where it finds nothing, the reason names the
variable and says to restart the worker server if a later worker still cannot see it; put that
reason in the report and record every check that needed the login `not checked`.

## Recording what was seen

**This is the point of the whole procedure.** A verification nobody can read afterwards is an
assertion with extra steps, and the worker's screen dies with it.

Prefer text evidence, always: a console line and a request line are quotable, cheap, and they
survive in the report. **Screenshots and recordings are not evidence this produces** - an image
cannot be quoted, cannot be diffed, and has to live somewhere and be cleaned up by somebody. Where
a defect can only be shown as a picture, describe it in words and say that is what you are doing.

**Copy the check ids out of the brief before you start**, while you still have the section in
front of you, and hand that list to `-Declared`. It is what makes a check you never reached
impossible to lose: the record answers on every declared id, whether or not your own list has an
entry for it.

Build the record from what you observed, one entry per check the brief listed:

```powershell
$declared = @('C-001', 'C-002', 'C-003')     # every id the brief listed, copied before the run
$checks = @(
    @{ id = 'C-001'; check = '<the check, as the brief worded it>'
       outcome = 'verified'; observed = '<what was seen>' }
    @{ id = 'C-002'; check = '<...>'; outcome = 'failed'; observed = '<what was seen instead>' }
    @{ id = 'C-003'; check = '<...>'; outcome = 'not checked'; reason = '<why not>' }
)
$record = Get-BrowserVerificationRecord -Declared $declared -Check $checks
$record.summary
```

Three outcomes and no others. **`verified`** with what was observed, **`failed`** with what was
observed instead, **`not checked`** with the reason. A check the brief listed always gets one of
them: **an item that could not be checked is reported, never skipped**, and a run with one of them
in it is not a pass. The function enforces that rather than trusting it - a missing outcome, an
outcome word it does not recognise, an entry naming no check, or a `verified` with nothing
observed all come back `not checked`, because a pass with no evidence behind it is exactly what
this replaces. An outcome word with nothing written behind it gets a stated reason saying so, so
no item in the record is ever a bare word. And a declared id your list never mentions comes back
`not checked` saying it was never answered, which is the one failure this cannot catch on its own:
a list built at the end from what you remember doing is exactly how a check goes missing.

Then write it into `report.md` under `## Browser verification`: the summary line first, then one
short block per item in `$record.items`, in order, none omitted. Nothing reads that back - it is
prose for whoever picks the work up next, not a format - so keep each block to the check, its
outcome, what was observed, and the one console or network line that shows it.

```markdown
## Browser verification

failed - 3 checks: 1 verified, 1 failed, 1 not checked.

- **C-001 the empty state renders** - verified. The panel showed "Nothing here yet", console clean.
- **C-002 saving a filter** - failed. `POST /api/filters` returned 500, and the panel kept spinning.
- **C-003 the export downloads** - not checked. It needs a signed-in session and no login variable
  was named in the brief.
```

Carry `$record.verdict` into your final message too. `failed` and `not verified` are both findings
the King needs, and neither is a completion notice. That block is read back when the work is
called done, so a brief that asked for these checks and a report with no `## Browser verification`
in it is treated as a report that was never written.

## Who drives the browser

**The worker making the change does, at the end of its own task, before it runs the review gate.**
Not a second worker afterwards.

The trade-off is real and it is a context one: a worker holding a repository, a build and a
browser session is carrying a lot, and that is the cost of this choice. The alternative costs
more. A separate verification worker would need the same worktree, the same branch, the same
running application and the same understanding of what the change was meant to do, so it pays the
context back almost in full - and it adds a dispatch, a second landing question, and a window in
which the branch has moved under it. The evidence is written to `report.md` as each check is
answered rather than held in context to the end, which is what keeps the cost bounded.

## Do not go down a hole

This is a bounded step at the end of a task, not an exploration. If a browser tool errors two or
three times, if a page will not load, if the application will not start, or if an element will not
respond, **stop, record those checks `not checked` with what happened, and finish the task.** A
worker that spends its remaining context fighting a browser delivers neither the change nor the
evidence. Stopping early is a result, and the declared list is what keeps it an honest one - every
id you never reached still appears in the record, so build the record from the ids the brief gave
you rather than from the ones you got to.
