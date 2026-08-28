---
name: bearings
description: Use when the user invokes /bearings or asks for a catch-up on the fleet - e.g. "where did I left off", "catch me up", "status report", "morning brief", "what is in the works", "bearings". Renders a complete four-section digest of the current fleet state. Plain /bearings is chat-only and writes nothing, while /bearings file additionally writes the dated data\status-report-<YYYY-MM-DD>.md artifact.
tools: PowerShell, Read, Write
user-invocable: true
version: 1.0.0
---

# Bearings

Generate a complete current snapshot of the fleet, so the user can pick up where they left off in
one read after a break, a night, or a fresh session.

This runs only when the user asks for it. There is no session-start hook and none is wanted: a
catch-up is worth reading when it is asked for, and worth nothing when it is printed at every
session whether or not anything changed. Do not add one and do not propose one.

Plain `/bearings` returns only the four-section chat digest. Only `/bearings file` writes the
dated report artifact and then returns the same four-section chat digest with the report path.

This skill is operationally read-only in both modes. It never dispatches, steers, lands, merges,
tears down, answers a decision, or mutates `state\` or `data\` other than that single dated report
in explicit file mode.

## Invocation modes

- Plain `/bearings` gathers a fresh bounded snapshot and renders the four-section chat digest
  without creating, deleting, reading, or replacing `$env:KINGSHAND_HOME\data\status-report-<YYYY-MM-DD>.md`.
- `/bearings file` gathers a fresh bounded snapshot, replaces today's
  `$env:KINGSHAND_HOME\data\status-report-<YYYY-MM-DD>.md` from scratch, and then renders the same
  four-section chat digest with the path to that report.
- Treat `file` only as an explicit invocation option in the slash command. Do not treat natural
  language such as "write a report", "save this", "persist it", or "make a file" as file mode
  unless the invocation explicitly includes the standalone `file` option.

## What it does

### 1. Gather the state with the one command

Run it, and read its output:

```powershell
$snap = & $env:KINGSHAND_HOME\bin\Get-BearingsSnapshot.ps1
```

That script is the single bounded, deterministic fleet-state source for this skill. It reads the
registry, crew.json joined with live agent state, each worker's `report.md`, and every
`data\<id>\` holding a `brief.md` with no crew.json entry. Its header owns its exact fields and
bounds.

- Do not create or consult a second fleet-state reader, ad-hoc registry parse, ad-hoc
  `claude agents --json` call, or hand-rolled scan of `data\` or `state\`.
- Do not scrape conversation history, a worker's transcript, or an earlier status report to
  supplement current state. What is on disk now is the state; what was said earlier is not.
- Do not read `brief.md` or `report.md` bodies to pad a section. Name the pointer and let the
  user or `crew` open it.
- `$snap.diagnostics` is not decoration. Every entry is a fact the digest is missing, so surface
  each one under Charted Next as an integrity warning rather than rendering a confident section
  built on a section that failed.
- `live` is `$true` or `$false` when the liveness join ran, and `$null` when it could not.
  `$null` means unknown, never dead; say unknown and name the diagnostic.

The snapshot covers the fleet; it does not cover the queue. Read the queue with its own reader,
from `$env:KINGSHAND_HOME` so `.tasks.toml` resolves:

```powershell
Set-Location $env:KINGSHAND_HOME
tasks-axi ready --include-held
tasks-axi list --blocked
```

The first returns queued work that is ready to dispatch plus every held item with its reason and
kind; the second returns items still waiting on a dependency. `tasks-axi --help` owns the rest.

**The hold kind is what decides the bucket, so read it rather than the hold alone.** A hold of
kind `captain` waits on the user's own answer and belongs in King's Call; `external`, `load`,
`parked` and `future` wait on something else and belong in Charted Next.

Both are reads and write nothing. Neither is the second fleet-state reader the rule above
forbids - `tasks-axi` is `data\backlog.md`'s own reader, and hand-scanning that file instead is
exactly what the rule does forbid. If `tasks-axi` is unavailable or the command fails, treat it as a
diagnostic: say the queue could not be read and do not render Charted Next as though it were
empty.

### 2. Compose the four-section chat digest

The gather is deterministic. Your judgement is scoped to ranking those facts by what matters now
and writing scannable prose. Render the four sections below, in that order, every one of them,
every time. Plain mode stops here and writes nothing.

### 3. In explicit file mode only, replace the dated report

The report uses the same four sections in the same order and adds the detail the chat omits: each
worker's repo, stage, branch pointer and report path, each registry entry's posture, and each
un-dispatched brief's path.

- Write it to `$env:KINGSHAND_HOME\data\status-report-<YYYY-MM-DD>.md` using today's date.
- If today's file already exists, delete it first and build the new one from scratch.
- Never read an earlier `status-report-*.md` to decide what to omit, include, describe as
  changed, or call current.
- That file is the only write this skill is allowed to make.

After writing it, return the same four-section chat digest and include the report path inside it,
without adding a fifth section.

## Chat-response contract

This skill owns the `/bearings` response format; `Get-BearingsSnapshot.ps1` owns the data that
feeds it. Every `/bearings` response renders EXACTLY these four sections, in THIS order, and
nothing else structural:

1. **King's Call** - ONLY what needs the user's own action now.
   Empty-state: "Nothing needs your action right now."
2. **Recently Landed** - the current completions baseline.
   Empty-state: "No recent completions are in the current baseline."
3. **Underway** - live work progressing on its own, one line of current state each.
   Empty-state: "Nothing is underway."
4. **Charted Next** - work waiting on something other than the user, plus action-free integrity
   warnings.
   Empty-state: "Nothing is queued."

Rules that keep the contract unambiguous:

- Every section ALWAYS renders, even when empty, with its short empty-state sentence. Never omit
  a section, and never merge two of them because both are thin.
- Every digest and every file-mode report is a complete current snapshot, never a delta against a
  previous report. Recently Landed renders the current baseline even when the same completions
  appeared in yesterday's report.
- The four buckets are mutually exclusive, so every item lands in exactly one: needs-your-action
  is King's Call, done is Recently Landed, self-progressing is Underway, and waiting on
  something other than the user is Charted Next.
- The strict boundary keeps action-free items OUT of King's Call. A worker still working, a
  brief already approved and dispatched, landed work, and a report pointer each belong to one of
  the other three sections, never King's Call.
- Every PR appears as the full `https://...` URL, never a bare `#number`. A `#number` shorthand is
  fine only as a back-reference after the full URL has already appeared in the same digest.
- One scannable line per item. Long detail belongs in the file, and only when file mode is
  explicit.
- Address the user directly at least once, inside an item or an empty-state sentence.

## Kingshand bucket mapping

Map the snapshot onto the four buckets like this, and nowhere else:

**King's Call**

- A worker whose `agentState` is `blocked`, whatever its stage. It cannot proceed on its own, so
  it is never Underway. Give it its own line naming the worker id.

  **`agentStatus` decides what you tell the user, and the two cases need opposite advice.**
  Both are `blocked`; only one can be answered.

  - `blocked` with `agentStatus` of `waiting` means it is sitting on an interactive prompt that
    nobody can answer, because a background worker has no one attached. It is hung and will wait
    indefinitely. Say so, and point at `claude attach <id>` as the only way in. A worker's brief
    forbids opening such a prompt, so this also means that brief was not followed.
  - `blocked` with `agentStatus` of `idle` means it stopped by design. It reached a decision its
    brief did not settle, wrote the question into `data\<id>\report.md`, and stopped as instructed.
    Point at the report, not at `claude attach` - attaching a worker that finished correctly
    wastes the user's time and misreads its own report as a failure.

  Never give the `claude attach` line for an `idle` worker, and never describe a `waiting` one as
  having finished.
- A worker at stage `ready` - it is waiting at the landing gate for the user's approval.
- An open PR waiting on the user's merge. Crew never merges on the forge, so a PR sits here until
  the user merges it. Full `https://...` URL.
- A brief written but not yet dispatched - `$snap.data.undispatched`. The dispatch gate is the
  user's, so an un-dispatched brief is work waiting on them, not queued work.
- A backlog item held with a hold kind of `captain` - an open decision waiting on the user's own
  answer, read from `tasks-axi ready --include-held`. One line naming the item's id, its title and
  its hold reason, phrased as the decision it is rather than as a hold. This is what King's
  Call is for, so it renders here and in no other section.
- A registered project whose recorded path is missing from disk - `pathExists` is `$false`.
  Nothing can be dispatched into it until the path is restored or the entry is corrected.

**Recently Landed**

- A worker at stage `landed`. Name its report path when `hasReport` is `$true`; the pointer is a
  pointer, not an action.

**Underway**

- A live worker at stage `dispatched`, `implementing` or `gating` **whose `agentState` is not
  `blocked`**, one line of current state each from its stage and its `agentState` or
  `agentStatus`.
- A worker whose `agentState` is `blocked` is never Underway, whatever its stage says. A live
  process at stage `dispatched` looks like progress and is not - it is stopped, waiting on the
  user. It goes to King's Call.
- A worker whose intent says it is working but whose `live` is `$false` has stopped without
  landing. That is not Underway - it needs the user, so it goes to King's Call with what its
  stage was.

**Charted Next**

- Real queued work read from `data\backlog.md`: an item not yet dispatched, an item whose
  dependencies have not cleared, and an item held for something other than the user - a hold kind
  of `external`, `load`, `parked` or `future` - with its hold reason. One line each, naming the
  item's id and its title.
- A hold of kind `captain` is the one queued item that does not belong here. It awaits the user's
  own answer, so it renders in King's Call and nowhere else. Never duplicate it into this
  section to keep the queue looking complete: the four buckets are mutually exclusive, and one
  decision rendered twice reads as two.
- An item filed at intake with no brief yet is queued work and belongs here. A brief already
  written and waiting on the dispatch gate is the user's next action and stays in King's Call;
  the two never both render for the same unit of work.
- Any `$snap.diagnostics` entry, as an action-free integrity warning, plus a stage `failed` worker
  whose failure the user has already seen.
- When the queue really is empty and there is nothing else to warn about, render "Nothing is
  queued." rather than dropping the section.

An empty registry is meaningful, not an error. It means nothing can be dispatched until
`/import-project` runs, and it belongs in King's Call as exactly that one line. The same is
true of an absent `crew.json`: nothing has been dispatched yet.

`rawMode` is the registered posture and the one to quote; `mode` is the mechanical resolution and
the two differ only for `no-mistakes-prod-only`. `yolo` is the string `'on'` or `'off'` - report
it by comparing with `-eq 'on'`, never by testing it for truthiness.

## Operationally read-only

This skill changes no fleet state. It never dispatches a worker, steers one, lands work, merges a
PR, tears down a worktree, answers a decision, or writes any file except the single dated report
in explicit file mode.

**Reading the backlog is a read.** Never add, start, hold, unhold, update or close a backlog item
from this skill; `crew` owns every one of those, and `decision-hold-lifecycle` owns the only way a
captain hold may close. A queued item that needs acting on is named in its section and left there.

If what it reads implies an action - a worker at the landing gate, a PR ready to merge, a brief
waiting on the dispatch gate - name it in its section and leave the action to `crew`. Naming the
next step is the digest's job; taking it is not.
