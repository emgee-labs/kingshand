# A worker sees a user variable set after the herdr server started

2026-09-04

## Why this was in doubt

`data\rules-<project>.md` and `data\done-<project>.md` must never hold a credential value. They
name a pointer instead - a user-scope environment variable, or an entry in a credential store - and
the worker reads the value from there. That rule only works if a worker can actually see a variable
the King set today.

There was good reason to think it could not. A worker is not spawned by the King's shell. It is
spawned by the herdr server, which is long-lived - the one measured here had been up since
2026-09-02 22:56, more than 24 hours. On Windows a child process inherits the creating process's
environment block by default, and `bin\Herdr.psm1` builds the server's own block explicitly
(`Start-HerdrServer` sets `$psi.Environment`, and the `New-HerdrPane` comment notes that "the
server scrub covers panes it launches"). If panes simply inherited that block, a variable created
after the server started would never reach a worker.

The failure that would cause is the reason this was worth measuring rather than assuming: the
worker reads an empty variable, authentication fails, and it looks exactly like a wrong password.
Nothing would point at the environment.

## Method

1. Set a User-scope variable from an ordinary shell, with a value marking when it was created:
   `[Environment]::SetEnvironmentVariable('PROBEVAL', 'set-after-server-start-034115', 'User')`
2. Confirm the running server predates it - `herdr status`, and the server process start time.
3. `herdr workspace create` a fresh pane, so the pane is launched by that same long-lived server.
4. `herdr pane run` an echo of the variable in that pane.
5. `herdr pane read` the pane to collect the output.

## Result

```
PROBEVAL=[set-after-server-start-034115]
```

Server start 2026-09-02 22:56; variable created and read on 2026-09-04. The variable was created
after the server started, and the pane the server spawned seconds later could see it.

## Conclusion

herdr composes a fresh environment for each pane rather than handing out the snapshot the server
booted with. So a pointer written into a standing file today reaches a worker dispatched today,
with no need to restart the server after setting a variable.

That is the whole premise the credential guidance rests on - "name the environment variable, never
the value" in `.claude\skills\annex\SKILL.md` and in `CLAUDE.md`. It holds. What does not follow
from this measurement, and was not tested: whether a variable *changed* after a pane already exists
reaches that pane. Assume it does not, and dispatch a fresh worker after changing one.

## Re-running it

Follow the method above. The check is only meaningful while the server has been up longer than the
variable has existed - restart the server first if in doubt, then set the variable, then measure.
A result showing an empty `PROBEVAL=[]` would mean panes inherit the server's block after all, and
the credential-pointer design would need the King to restart herdr after setting any variable.

The probe variable and the pane created for this measurement were both removed afterwards.
