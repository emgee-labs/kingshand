# kingshand

A Claude Code setup for Windows that turns one session into a dispatcher for background workers.
You describe work; it writes a brief, gets your approval, spawns a background Claude Code agent in
its own git worktree, and comes back when there is something to decide.

## The model

**You are the King** - you decide, you approve, and a current explicit word from you overrides any
standing rule in the repo. **The tool is the Hand** - it acts on your behalf, never rules in its own
name, and never does the project work itself. **Workers are the King's men** - each called up for
one task in its own worktree, and released when it is done.

## What it actually gives you

- **Parallel workers.** One background agent per unit of work, each isolated in its own git
  worktree, so three tickets can be in flight without them treading on each other.
- **Two gates.** You approve what gets dispatched, and you approve what lands. Per project, you can
  turn both off.
- **Per-project delivery posture.** A project is registered as `local-only`, `direct-PR` or
  `no-mistakes`, and nothing is dispatched into a project that is not registered. Posture is read,
  never inferred.
- **A durable queue.** Work items, dependencies and held decisions survive a restart, because a
  decision that lives only in the conversation is a decision you will lose.
- **A session-start digest.** Registered projects, live workers, the queue, your standing
  instructions and the curated memory, printed once at session open. A restart is meant to be a
  non-event.
- **Your preferences stay yours.** `instructions.md` is read every session and never edited by the
  tool. Your registry, briefs, reports and memory are gitignored and never leave your machine.

## Status

Read this before deciding whether to use it.

- **One real work cycle has been completed end to end.** One. That cycle found four defects - among
  them a landing gate that diffed against the wrong base ref and reported a one-file change as six,
  and a dispatch that promised to report back without arming anything to wake it.
- **The test suite is 439 cases, and roughly half of them assert that a prose rule exists** in
  `CLAUDE.md` or a skill, not that an agent followed it. That is a real and deliberate limit: these
  tests catch a rule being deleted or diluted in an edit. They cannot catch a model reading the rule
  and doing something else. The scripts under `bin\` are tested properly; the behaviour of the agent
  reading the prose is not, and cannot be by this means.
- **There is no way to steer a running worker.** Claude Code exposes no scriptable send, so a worker
  that gets stuck is stopped and re-dispatched with a better brief, or handed to you interactively.
  `docs\2026-08-28-worker-control-plane-decision.md` records why that trade was taken.
- **Windows and PowerShell 7 only.** Paths, junctions and the process model are all Windows-shaped.
  Nothing here has been run anywhere else.
- **It has been used by one person, on one machine.** Expect to hit things.

## Prerequisites

| | Why | Install |
|---|---|---|
| PowerShell 7+ | every script targets it | `winget install --id Microsoft.PowerShell` |
| Claude Code | the Hand and every worker | `npm install -g @anthropic-ai/claude-code` |
| Git for Windows | worktrees are the isolation | `winget install --id Git.Git` |
| GitHub CLI | pull requests for push-capable postures | `winget install --id GitHub.cli`, then `gh auth login` |
| Pester 6+ | the test suite | `Install-Module Pester -MinimumVersion 6.0.0 -Force -SkipPublisherCheck -Scope CurrentUser` |
| `lavish-axi` | the review surface both gates render to | `npm install -g lavish-axi` |
| `tasks-axi` | the durable backlog | `npm install -g tasks-axi` |

Optional: `no-mistakes`, needed only by projects you register with the `no-mistakes` posture.

Add `.claude/worktrees/` to your global gitignore, or every worker shows up as untracked changes in
your repositories:

```powershell
git config --global core.excludesFile    # then add the line to whatever it names
```

## Install

Clone it, open Claude Code in it, and ask:

```powershell
git clone <this repository's URL> C:\tools\kingshand
cd C:\tools\kingshand
claude
```

Then type **`set it up`** - or `setup`, or `/setup`. The `setup` skill ships inside the repository
at `.claude\skills\setup\`, so it is readable in a fresh clone with nothing installed yet. It runs
the installer for you and tells you in plain language what installed, what was already there, and
what still needs you.

The manual equivalent, if you would rather run it yourself:

```powershell
cd C:\tools\kingshand
.\install.ps1 -ProjectRoot C:\repos
```

`install.ps1` checks every prerequisite and names the install command for each one it cannot find,
sets `KINGSHAND_HOME`, junctions the ten skills into `~\.claude\skills\`, copies
`instructions.example.md` to `instructions.md`, and writes the local directories and the startup
memory budget. It is idempotent, and it never overwrites an existing `instructions.md` or an
existing config value without saying which file it left alone. Pass `-Force` where you meant to
replace something.

**`-InstallMissing` is opt-in.** Without it the script installs nothing and only names the command
for each missing tool. With it, each of those commands is printed and then run, every tool is
re-checked afterwards rather than assumed installed, and nothing self-elevates - an install that
needs administrator rights is reported with the command to run in an elevated shell. `npm` and
`winget` are the floor: if either is absent, the tools behind it are named as unreachable and not
attempted. `no-mistakes` is never installed by it.

Open a new shell afterwards so `KINGSHAND_HOME` is picked up.

## First use

```powershell
cd C:\tools\kingshand
claude
```

The session-start digest prints on the first turn. With nothing registered it will say so.

1. **Write your standing instructions.** Open `instructions.md` and put your own preferences in it -
   how you want to be spoken to, your delivery defaults, your conventions. The Hand reads it every
   session and never edits it. It is gitignored.
2. **Register a repository.** `/import-project C:\repos\your-repo` - it records the delivery posture
   and never clones anything.
3. **Give it work.** "fix the flaky login test in your-repo". The Hand writes a brief, shows it to
   you, and dispatches a worker once you approve.
4. **Check in.** `/bearings` for where everything stands, `/ahoy` for what you missed in this
   session.
5. **Keep memory current.** `/stow` before a context reset, which curates what the Hand learned -
   and never touches `instructions.md`.

## Layout

```
CLAUDE.md              the Hand's always-loaded instructions - identity, hard rules, contracts
bin\                   the scripts: dispatch, crew state, registry, snapshot, digest, budget
skills\                ten skills - crew, import-project, bearings, ahoy, stow, and five references
.claude\skills\setup\  the one skill that ships in the repo, so "set it up" works in a fresh clone
tests\                 the Pester suite
docs\                  one architecture decision worth keeping
instructions.example.md the template install.ps1 copies to instructions.md
install.ps1            prerequisites, skill junctions, config
```

Everything a run produces - `data\`, `state\`, `config\`, `tools\` and `instructions.md` - is
gitignored. That is not tidiness: it is the difference between publishing this tool and publishing
your own project registry.

## Tests

```powershell
Invoke-Pester -Path .\tests
```

`tasks-axi` must be on PATH or the backlog cases skip with a reason. Nothing else in the suite has
an external dependency, and nothing in it reads or writes your live `data\` or `state\`.

## Permissions, and what you are agreeing to

`.claude\settings.json` ships with `defaultMode: bypassPermissions`, and `bin\Dispatch-Worker.ps1`
spawns every worker with `--permission-mode bypassPermissions`. **Neither the Hand nor its workers
will ask you to approve a tool call.** That is deliberate - the Hand reads diffs, runs git and
merges locally hundreds of times in a session, and a prompt on each one makes the tool unusable -
but it is a real decision and you should make it knowingly rather than find it later.

What still constrains it:

- Workers only ever run inside their own git worktree, never in your checkout.
- Nothing is dispatched into a repository you have not registered with `/import-project`, and
  posture is read from the registry rather than inferred.
- Nothing pushes unless that project is registered with a push-capable posture, and nothing is
  merged on the forge at all.
- `deny` blocks reads of `~\.ssh`, AWS credentials and `config\credentials\`, and blocks writes to
  `instructions.md` outright - the rule that your standing instructions are never rewritten is
  enforced by the permission layer, not just stated in prose.
- `additionalDirectories` ships empty. A worker cannot reach a directory you have not named.

If you would rather approve each call, remove `defaultMode` from `.claude\settings.json`. Expect a
great many prompts.

## Credit

Kingshand is a Windows-native rebuild of ideas from
[firstmate](https://github.com/kunchenguid/firstmate) by Kun Chen, which runs on macOS and Linux.
Several skills, the delivery-posture and knowledge-routing contracts, the registry line format
and the startup-memory estimate all come from there. Where a rule in this repository reads well,
it is usually because it was proven there first.

What is different here is the layer underneath. Firstmate supervises workers itself, across six
terminal backends and around 56,000 lines of shell. Kingshand hands that job to Claude Code's own
supervisor and keeps roughly 1,200 lines of PowerShell, which is why it runs on Windows at all
and why it cannot do some of what firstmate does. `docs\2026-08-28-worker-control-plane-decision.md`
records that trade and what would reverse it.

## Licence

MIT. See `LICENSE`, which also carries firstmate's copyright notice for the portions derived
from it.
