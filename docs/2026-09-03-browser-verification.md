# Browser verification, and why it is shaped this way

2026-09-03

A front-end change used to be delivered on an assertion that the code looked right. `witness` lets
a worker exercise it in a real browser instead, and records what it saw. Five decisions shaped it,
and each one is here because the obvious alternative is worse in a way that is not obvious.

## The opt-in lives in the brief, not the registry

A field beside the delivery posture in `data\projects.md` was the obvious candidate. It was not
taken.

The registry answers "what posture did the Hand register for this project", which is a standing
fact that changes about once. Whether a browser is worth driving is not that fact. It is a
property of **the task**: most changes to a project with a web front end touch no rendered
behaviour at all, so a project-level flag would fire a browser step on migrations, build changes,
test changes and documentation, and every one of those runs would answer nothing. The flag would
then be read as noise and worked around, which is how a gate stops being one.

The brief is also the only artefact a worker actually reads. A registry field would still have had
to be copied into the brief to reach anyone, so the field would have been a second place to state
the same thing - and the two would disagree the first time one of them was edited.

The same fact settles how the procedure reaches the worker: it travels as a file, not as a name.
Skills live in kingshand's own `.claude\skills\`, and a worker runs in the target project's
worktree, where none of them exists - so a brief telling a worker to load `witness` would name
something it cannot open, and it would drive a browser with none of the rules attached. The brief
hands over the skill file itself, and `bin\BrowserVerify.psm1` with it, through the `Read first`
copy every settled file already uses - the installation's own `bin\` is no more reachable than its
skills, so the module the procedure imports has to travel the same way. Dispatch discounts both
copies from the index gate for the same reason it discounts the standing-criteria file - a path
passed on every brief of one shape is evidence about none of them - and refuses, before anything
is created, a brief carrying the section that did not pass both, because a section pointing at a
copy nobody made delivers exactly the nothing this route was built to end.

So `## Browser checks` in the brief is the whole mechanism: absent means no browser step, and a
project's standing browser rules are pasted into it the way standing criteria already are. Nothing
in `bin\Projects.psm1`, the registry format or `/annex` changed, and no registered project acquired
a browser step as a side effect.

**What would change this decision:** several projects each carrying the same standing browser rules,
copied into brief after brief. That is the point at which a per-project home earns itself. One
project's worth of rules does not.

## The environment a worker inherits is a snapshot, and it is usually stale

A login has to reach a worker without being written down anywhere, so it comes from a user-scope
environment variable. The trap is that it does not arrive.

Measured on this machine, 2026-09-03:

- the `herdr.exe` that started this worker had been up since the previous day - 25 hours;
- a variable set at user scope was **not** visible as `$env:NAME` in the process that set it;
- it was **not** visible in a child process spawned after the set either;
- a registry read - `[Environment]::GetEnvironmentVariable($name, 'User')` - returned it from both.

That is ordinary Windows behaviour rather than a defect in anything: a process inherits its
parent's environment block at creation, and a long-running console server never learns that the
user environment changed. Every worker it starts inherits the environment as it was when the
server started. The failure mode is the bad one - `$env:NAME` reads empty for a variable that is
correctly set, and an empty password looks exactly like a wrong password.

`Get-BrowserCredentialStatus` therefore reads the process block first and the user environment
second, and reports which source answered. The second read is the one that usually succeeds, so
the answer is a variable that simply works rather than an instruction to restart a server, which
is advice a background worker cannot act on anyway. The restart is still named in the not-found
message, because a variable set in neither place needs it.

The login itself is not in what that function returns. A hashtable evaluated on its own prints
every key it holds, so a worker typing `$cred` to see whether a login was found would put the
login into its pane and its transcript - a foot-gun no prose warning removes. The status is
therefore safe to print by construction, and `Get-BrowserCredentialValue` is the only way to the
login, called where it is typed into the page and nowhere else.

**Do not replace that second read with a bare `$env:` lookup.** It will appear to work on any
machine where the server was started after the variable was set, which is exactly the machine
nobody tests on.

## The implementing worker drives the browser

The alternative was a separate verification worker dispatched after the change.

A worker holding a repository, a build and a browser session is a large context, and that is the
real cost of this choice. It is still the cheaper one. A second worker would need the same
worktree, the same branch, the same running application and the same understanding of what the
change was meant to do - so it pays that context back almost in full, and adds a dispatch, a
second landing question, and a window in which the branch moves underneath it. What keeps the cost
bounded is that evidence is written into `report.md` as each check is answered, rather than
accumulated in context until the end.

## Text evidence, and no screenshots

Console lines and request lines are quotable, diffable, and they survive teardown inside
`report.md`, which is the one file that does. An image cannot be quoted, has to live somewhere,
and needs somebody to decide when to delete it - so image evidence would have introduced a write
destination and a retention question in exchange for evidence nobody can grep.

The consequence is deliberate: this capability adds **no new write destination at all**. The
record goes into the worker's own `report.md`, which already has an owner and a lifecycle.

## It fails closed because the tool is unreliable

The `claude-in-chrome` server connected and disconnected twice inside a single conversation on
2026-09-03, so its absence is a normal outcome and not an incident. There is no retry loop: when
the tools are not there, verification did not happen, every check is recorded `not checked`, and
the run cannot come back verified. `Get-BrowserVerificationRecord` enforces that rather than
trusting a worker to remember it - and it enforces the same thing against a missing outcome, an
unrecognised outcome word, and a `verified` with nothing observed, because each of those is a way
for an unexercised change to read as a passing one.

The rule that pays for all of it: **an item that could not be checked is reported, never skipped.**
A skipped item is indistinguishable from a passing one by the time anybody reads the report.
