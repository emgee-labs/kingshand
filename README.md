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
- **Your other projects are untouched.** The skills live in this repository's own
  `.claude\skills\`, so they load only while Claude Code is running here. Nothing is written into
  `~\.claude\`, so a session anywhere else on the machine behaves exactly as it did before.

## Status

Read this before deciding whether to use it.

- **One real work cycle has been completed end to end.** One. That cycle found four defects - among
  them a landing gate that diffed against the wrong base ref and reported a one-file change as six,
  and a dispatch that promised to report back without arming anything to wake it.
- **The test suite is 607 cases, and roughly half of them assert that a prose rule exists** in
  `CLAUDE.md` or a skill, not that an agent followed it. That is a real and deliberate limit: these
  tests catch a rule being deleted or diluted in an edit. They cannot catch a model reading the rule
  and doing something else. The scripts under `bin\` are tested properly; the behaviour of the agent
  reading the prose is not, and cannot be by this means.
- **Steering a running worker goes through herdr, and it is narrow.** Claude Code itself exposes no
  scriptable send; herdr owns the pane, so a prompt or a keypress can be delivered into a live
  worker. Keys go one at a time on purpose - a batched arrow-then-Enter picks the wrong option and
  reports success. A worker that is genuinely stuck is still stopped and re-dispatched with a better
  brief. `docs\2026-08-28-worker-control-plane-decision.md` records the trade this replaced.
- **Windows and PowerShell 7 only.** Paths, worktrees and the process model are all Windows-shaped.
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
| `herdr` | the terminal runtime every worker is spawned and steered through | `.\install.ps1 -InstallMissing` fetches and verifies it |

`herdr` is the odd one in that table. It does not come from a package manager and it is deliberately
never put on PATH: `install.ps1 -InstallMissing` reads `https://herdr.dev/latest.json`, checks the
download against the SHA-256 published there, and only then extracts it into this repository's own
gitignored `tools\herdr\`. A hash mismatch refuses to extract and deletes the download - an
unverified binary is not installed at all. If you already keep your own `herdr` on PATH, that one is
used and nothing is downloaded. kingshand was verified against herdr 0.8.2, protocol 20.

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

Then type **`set it up`** - or `setup`, or `/setup`. Every skill ships inside the repository at
`.claude\skills\`, so they are all readable in a fresh clone with nothing installed yet. `setup`
runs the installer for you and tells you in plain language what installed, what was already there,
and what still needs you.

The manual equivalent, if you would rather run it yourself:

```powershell
cd C:\tools\kingshand
.\install.ps1 -ProjectRoot C:\repos
```

`install.ps1` checks every prerequisite and names the install command for each one it cannot find,
sets `KINGSHAND_HOME`, copies `instructions.example.md` to `instructions.md`, and writes the local
directories and the startup memory budget. It is idempotent, and it never overwrites an existing
`instructions.md` or an existing config value without saying which file it left alone. Pass
`-Force` where you meant to replace something.

**It does not touch `~\.claude\skills\`, and nothing else here does either.** All eleven skills
live in this repository's own `.claude\skills\`, so they load only while Claude Code is running in
this directory. A session you start anywhere else on the machine is completely unaffected by
kingshand - installing it changes nothing about how Claude Code behaves in your other projects,
and it cannot collide with a skill of the same name you already have.

**`-InstallMissing` is opt-in.** Without it the script installs nothing and only names the command
for each missing tool. With it, each of those commands is printed and then run, every tool is
re-checked afterwards rather than assumed installed, and nothing self-elevates - an install that
needs administrator rights is reported with the command to run in an elevated shell. `npm` and
`winget` are the floor: if either is absent, the tools behind it are named as unreachable and not
attempted. `no-mistakes` is never installed by it. `herdr` is the one thing it downloads directly:
it is verified against the SHA-256 in `latest.json` before it is extracted, and if the machine is
offline the script says so in one line and changes nothing rather than throwing a web error at you.

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
2. **Register a repository.** `/annex C:\repos\your-repo` - it records the delivery posture
   and never clones anything.
3. **Give it work.** "fix the flaky login test in your-repo". The Hand writes a brief, shows it to
   you, and dispatches a worker once you approve.
4. **Check in.** `/survey` for where everything stands, `/audience` for what you missed in this
   session.
5. **Keep memory current.** `/chronicle` before a context reset, which curates what the Hand
   learned - and never touches `instructions.md`.

## Layout

```
CLAUDE.md              the Hand's always-loaded instructions - identity, hard rules, contracts
bin\                   the scripts: dispatch, crew state, registry, snapshot, digest, budget
.claude\skills\        eleven project-local skills - setup, muster, annex, survey, audience,
                       chronicle, and five references. They load only in this directory
tests\                 the Pester suite
tools\herdr\           herdr, fetched and SHA-256 verified by the installer - gitignored, and
                       deliberately not on PATH
docs\                  one architecture decision worth keeping
instructions.example.md the template install.ps1 copies to instructions.md
install.ps1            prerequisites and config - it writes nothing outside this repository
                       except KINGSHAND_HOME and LAVISH_AXI_PORT
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

`.claude\settings.json` ships with `defaultMode: bypassPermissions`, and every worker gets the same
grant written into its own worktree at `.claude\settings.local.json` before it starts. **Neither the Hand nor its workers
will ask you to approve a tool call.** That is deliberate - the Hand reads diffs, runs git and
merges locally hundreds of times in a session, and a prompt on each one makes the tool unusable -
but it is a real decision and you should make it knowingly rather than find it later.

What still constrains it:

- Workers only ever run inside their own git worktree, never in your checkout.
- Each worktree is recorded as trusted in your own `~\.claude.json` before its worker starts, so an
  unattended worker does not stop on Claude Code's folder-trust dialog with nobody there to answer
  it. That entry is exactly the worktree kingshand just created - never its parent repository, and
  never the machine. If you have no `~\.claude.json` yet, nothing is written and the worker stops at
  the dialog instead.
- Nothing is dispatched into a repository you have not registered with `/annex`, and
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
