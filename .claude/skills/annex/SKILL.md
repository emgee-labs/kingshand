---
name: annex
description: Use when the user wants to register a repository so work can be dispatched into it - e.g. "import C:\repos\acme-api", "register acme-web", "annex C:\repos\acme-api", "add this repo as direct-PR", "what projects are registered". Records the project's standing delivery posture, and offers to initialise the review gate when the chosen posture needs one. It never clones and never removes.
tools: Bash, PowerShell, Read, Write, Glob, Grep, AskUserQuestion
version: 1.0.0
---

# Annex

## Overview

The registry records the user's **standing posture** for a project: how work ships, and whether
`muster` may act without asking. It never decides an individual task's mode - that is resolved at
intake and passed explicitly to the brief and the dispatch.

Posture is never inferred, only read. A repository that has not been imported cannot be
dispatched into.

$ARGUMENTS

## Step 0 - Which operation

| The user says | Go to |
|---|---|
| names a path or repo to import, register or add | Step 1 |
| asks what is registered, or about a project's posture | Step 5 |

## Step 1 - Resolve the request

Establish the absolute path. If the user gave a bare name rather than a path, ask for the path
rather than guessing - a wrong path registers the wrong repository.

Default the project name to the directory's leaf name. The user may override name, mode and
yolo in the request itself, in which case go straight to Step 3.

## Step 2 - Propose the posture

State the resolved default rather than asking the user to invent one:

```powershell
$path = "<absolute path>"
git -C $path rev-parse --is-inside-work-tree 2>&1
git -C $path remote get-url origin 2>&1
```

| Condition | Proposed mode |
|---|---|
| Has an `origin` remote | `no-mistakes-prod-only` |
| No remote | `local-only` |
| Always | `yolo` off |

The four modes:

- `no-mistakes` - full validation pipeline, then a PR, then the user merges.
- `direct-PR` - push and open a PR without the pipeline.
- `local-only` - no remote or PR required; lands through the guarded local fast-forward path.
- `no-mistakes-prod-only` - a conditional policy, not a flat mode. Internal-only tooling,
  automation, contributor or operator process and release work ships `direct-PR`; product-facing,
  mixed and uncertain work ships `no-mistakes`. Registering it is a one-time choice and never
  requires classifying any change now.

`+yolo` relaxes both of `muster`'s gates for this project: it writes the brief and dispatches
without approval, and lands green work itself. Default it off and enable it only on the user's
explicit instruction.

Tell the user what these mean in one line each if they have not seen them before, then confirm
name, path, mode and yolo together.

## Step 3 - Preflight

Every one of these is a refusal, not a warning. Report the exact condition and stop.

```powershell
Import-Module $env:KINGSHAND_HOME\bin\Projects.psm1 -Force
$check = Test-ProjectImportable -Path "<absolute path>" -Mode "<mode>"
if (-not $check.ok) { $check.reason }
```

`Test-ProjectImportable` owns three of the five refusals: the path existing, it being a git
repository, and a push-capable mode requiring an `origin` remote. Report `$check.reason`
verbatim and stop; do not paraphrase it into something softer.

The fourth is `gh`. A push-capable mode - `direct-PR`, `no-mistakes`, `no-mistakes-prod-only` -
ends at a pull request, and nothing here opens one without the GitHub CLI:

```powershell
Get-Command gh -ErrorAction SilentlyContinue
```

**Nothing back is a refusal, on exactly the terms above: report the condition and stop.** Say the
chosen mode needs `gh` and this machine does not have it, name the command that fixes it -
`winget install --id GitHub.cli`, then `gh auth login` - and offer `local-only` instead, which
needs no forge at all and can be raised later. `gh` is deliberately not a kingshand prerequisite
and its absence is not a broken install: work that stops at a finished local branch never calls
it. This is the one place that absence matters, so this is where it is caught - registering a
push-capable posture on a machine with no `gh` produces a project that looks importable and fails
at its first dispatch, which is the same defect the gate check below exists to prevent.

The fifth is uniqueness. The name must be unique, and the path must not already be registered
under another name. `Add-ProjectEntry` enforces both in Step 4; let it throw rather than
pre-checking.

## Step 4 - Record the gate state, then write the entry

Detect whether the review gate is initialised:

```powershell
Push-Location $path
$gate = & $env:KINGSHAND_HOME\tools\no-mistakes\no-mistakes.exe status 2>&1 | Select-Object -First 3
Pop-Location
```

Record what you found in the description, so a later dispatch is not surprised. Keep the
description useful for identifying the project and note gate state plainly, for example
`gate not initialised` or `gate initialised`.

**Do not put the date in the description. `Add-ProjectEntry` stamps `(added <date>)` itself.**
A description that ends in one produces `(added 2026-08-25) (added 2026-08-25)` on the entry
line. The function now strips a trailing stamp defensively, but write the description without
one - the stamp is the function's job, not yours.

### Offer to initialise the gate, only when the posture needs one

This applies **only** when the chosen mode is `no-mistakes` or `no-mistakes-prod-only`, and only
when `status` reports the repo is not initialised. A `direct-PR` or `local-only` project has no
review gate and needs none - never offer it there.

Import is the right moment to ask, because the posture that requires a gate is being chosen right
now. Registering a gate-requiring posture against a repo with no gate produces a project that
looks importable and fails at its first dispatch.

**Never run `init` without the user saying yes in the moment.** Tell them exactly what it does
before they answer: it creates a local bare repo as a gate, installs a post-receive hook, adds a
`no-mistakes` git remote, and records the repo in the tool's database. It writes **no tracked
files**, so their colleagues see nothing, and it is reversible with `no-mistakes eject`. It is
still their repository's configuration.

On an explicit yes:

```powershell
Push-Location $path
& $env:KINGSHAND_HOME\tools\no-mistakes\no-mistakes.exe init
& $env:KINGSHAND_HOME\tools\no-mistakes\no-mistakes.exe doctor
Pop-Location
```

Run `doctor` every time, immediately after `init`, and read its output. If it reports an
environment, authentication or daemon problem, that is a blocker: say so plainly and record the
posture as registered-but-not-gate-ready rather than claiming success. Never restart a shared
daemon to clear it - that reaches beyond this project.

Do not create a commit merely because initialisation ran.

If they decline, register the project anyway and record `gate not initialised` in the
description. That is a legitimate choice: the entry is honest about its state, and the dispatch
preflight will stop rather than proceed blind.

A worker never runs `init` itself. It is environment setup, outside any task's scope, and a
worker that tried would be writing configuration its brief never authorised.

```powershell
Add-ProjectEntry -Name "<name>" -Path $path -Mode "<mode>" -Description "<desc>" [-Yolo]
```

The registry is a durable file under `data\`, so index it in the same step that writes it. It has
a fixed name and the entry is rewritten in place, so this is safe to run on every import and the
line keeps the date the registry first entered the index. Without it a fresh install reports one
unindexed file from its very first `/annex`, and a drift count that is never zero is a count
nobody reads:

```powershell
Import-Module $env:KINGSHAND_HOME\bin\Index.psm1 -Force
Add-IndexEntry -Path "data\projects.md" -Summary "the project registry: each project's path and standing delivery posture"
```

Confirm in one line: the name, the posture, and the gate state.

If the posture is `no-mistakes` or `no-mistakes-prod-only` and the gate is not initialised, say so
plainly - work dispatched there will stop at its review gate until `no-mistakes init` is run in
that repository.

## Step 5 - Show what is registered

```powershell
Import-Module $env:KINGSHAND_HOME\bin\Projects.psm1 -Force
Get-AllProjects | ForEach-Object { [pscustomobject]$_ } |
    Select-Object name, rawMode, yolo, path | Format-Table -AutoSize
```

**The `[pscustomobject]` cast is required.** `Get-AllProjects` returns hashtables, and
`Select-Object name, ...` does not project hashtable keys: without the cast the table prints its
header and zero populated rows, so "what is registered" answers blank.

Answer in at most six lines. If there is more to say than that, render it and use lavish.

## Changing a posture later

There is no command for this. Edit the entry's annotation in `data\projects.md` by hand, and
record why in the description alongside the added date. The description doubles as the
posture-change log:

```
- acme-api [no-mistakes] - Acme .NET API (added 2026-08-24; raised from direct-PR 2026-09-02 once the gate was initialised)
      path: C:\repos\acme-api
```

**An entry line must be exactly one line, however long, with the indented `path:` line
immediately after it.** `Read-Registry` takes the next non-empty line after an entry as that
entry's `path:` line. Wrapping a description onto a second line therefore puts that continuation
where the path belongs, the entry parses with no path at all, and `Get-ProjectEntry` throws
`missing or malformed 'path:' line` - naming a fault in the path line that is in fact perfectly
correct, one line further down. Never wrap; let the line run long.

Keep the description useful for identifying the project. Do not turn the registry into project
documentation - architecture, ADO tagging and shorthand belong in their existing homes.

## Not in scope

- **No removal.** Deleting a line from `data\projects.md` by hand is safer and clearer than a
  command that must preflight in-flight work.
- **No clone and no create.** These are repositories that already exist on disk.
- **No gate initialisation.** See Step 4.
