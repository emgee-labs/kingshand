---
name: crew
description: Use when the user wants work done on one or more tickets or repos in parallel - e.g. "do T-1001 and T-1002", "start on ticket T-1003", "fix the flaky login test in acme-web", "what is the crew doing", "land T-1001", "dispatch a worker". Writes a brief per unit of work, gates it with the user, dispatches a background worker per brief, reports on completion, and lands only on explicit approval.
tools: Bash, PowerShell, Read, Write, Glob, Grep, ToolSearch, AskUserQuestion
version: 1.0.0
---

# Crew

## Overview

You dispatch background workers, one per unit of work, each in its own git worktree. How much
the user is involved depends on the project's posture. With `yolo` off, which is the default,
they are involved at two moments: approving what gets dispatched, and approving what lands. With
`+yolo` they are involved at neither - crew proceeds on its own, inside the floors in Step 7 that
no posture relaxes. And for the push-capable modes, `direct-PR` and `no-mistakes`, crew's
involvement ends at a pull request the user merges on the forge rather than at anything crew
lands.

Everything you are not gating on is yours, and you stay quiet through it.

$ARGUMENTS

## Step 0 - Which operation

| The user says | Go to |
|---|---|
| names tickets, or describes work to do | Step 1 |
| asks what the crew is doing | Step 5 |
| says land / merge / ship a worker | Step 7 |

## Step 1 - Intake

Two kinds of work:

- **ticket** - an ADO work item id. Fetch it.
- **adhoc** - free text with no ticket. Use a short kebab-case slug as the id.

For tickets, load the ADO tools:

```
ToolSearch: select:mcp__ado-local-mcp__wit_get_work_item,mcp__ado-local-mcp__wit_list_work_item_comments
```

**The ADO organization and project are configuration, never built in.** Read them from
`$env:KINGSHAND_HOME\config\ado.json`, which is absent by default:

```powershell
$adoPath = Join-Path $env:KINGSHAND_HOME 'config\ado.json'
$ado = if (Test-Path $adoPath) { Get-Content $adoPath -Raw | ConvertFrom-Json } else { $null }
$ado.organization, $ado.project
```

The file holds exactly two keys:

```json
{
  "organization": "your-ado-organization",
  "project": "Your ADO Project"
}
```

**With no config file, ask the King for the organization and project. Do not guess, and do not
carry over a value from an earlier session.** A work item fetched from the wrong organization is
not an error you will see - it is a "work item not found" that looks like a bad ticket number, or
worse, a real ticket from somewhere else. Offer to write the answer to `config\ado.json` so the
question is asked once; `config\` is gitignored, so it stays on this machine.

Where the King has already answered in this session, use that answer and stop asking.

Fetch the work item **and its comments**. Comments frequently carry the clarification that
changes a rule; where a comment overrides the description, the comment wins and you note it
inline as `[per comment, {author} {date}]`.

Determine which repo each unit belongs to. If ambiguous, ask - do not guess. Dispatching into
the wrong repo wastes an entire worker.

Resolve the project through the registry. It supplies both the path and the posture:

```powershell
Import-Module $env:KINGSHAND_HOME\bin\Projects.psm1 -Force
$proj = Get-ProjectEntry -Name "<project name>"
[pscustomobject]$proj | Format-List name, path, rawMode, yolo
```

**The `[pscustomobject]` cast is required.** `Get-ProjectEntry` returns a hashtable, and
`Format-List name, path, ...` does not project hashtable keys: without the cast it prints seven
empty `Name : <key>` blocks and no values, so the one moment you eyeball posture before
dispatching shows you nothing.

> **`$proj.yolo` is the string `'on'` or `'off'`, never a boolean. Always test it as
> `$proj.yolo -eq 'on'`.** A bare truthiness test is wrong: in PowerShell `if ('off')` is
> **true**, because every non-empty string is truthy. Writing `if ($proj.yolo) { ... }` treats
> every project as `+yolo` and silently skips both gates - the dispatch gate at Step 3 and the
> landing gate at Step 7 - on projects the user never granted autonomy for. There is no
> recovery from that; the work is already dispatched or already landed. Test the value, never
> the variable.

**An unregistered project stops the dispatch.** `Get-ProjectEntry` throws, and that is correct:
posture is never inferred, only read. Tell the user the project is not registered and offer to
import it with `/import-project`. Do not guess a posture, and do not dispatch without one.

**`$proj.rawMode` is what was registered, and it is the field you route on.** For every flat mode
(`local-only`, `direct-PR`, `no-mistakes`) `$proj.mode` holds exactly the same value and the two
are interchangeable. They differ only for the policy: a `no-mistakes-prod-only` project comes back
with `rawMode` of `no-mistakes-prod-only` and `mode` of `no-mistakes`. That `mode` is the most
rigorous leg of the policy, a conservative fallback for mechanical callers - it is **not** what
the work ships as, and taking it at face value sends internal-only work through a review gate the
repo may not even have, stopping a dispatch at Step 1b that should have shipped `direct-PR`.

So when `rawMode` is `no-mistakes-prod-only`, classify this task's surface now: internal-only
tooling, automation, contributor or operator process and release work ships `direct-PR`, while
product-facing, mixed and uncertain work ships `no-mistakes`. Never infer internal-only from file
location or project name. Record the resolved mode and the one-line reason in the brief.

**Record the unit of work in the backlog before its brief is written.** Use the same `<id>` the
brief, the worker and `crew.json` will use, and run it from `$env:KINGSHAND_HOME` so `.tasks.toml`
resolves:

```powershell
Set-Location $env:KINGSHAND_HOME
tasks-axi add "<id>" "<one line>" --repo "<repo>"
```

Ids are slug-shaped - letters, digits, `.`, `_` and `-`, with no spaces. Filing the item here is
what makes a unit of work visible before anything is dispatched, so do it even when the dispatch
gate is about to refuse it. `CLAUDE.md`'s Backlog contract owns why, and `tasks-axi --help` owns
the flags.

## Step 1b - Preflight the review gate

This step applies only when the task's resolved mode is `no-mistakes`. A `direct-PR` or
`local-only` task has no review gate and skips straight to Step 2.

For a `no-mistakes` task, check the repo actually has a gate before promising one:

```powershell
Push-Location "<absolute repo path>"
& $env:KINGSHAND_HOME\tools\no-mistakes\no-mistakes.exe status 2>&1 | Select-Object -First 5
Pop-Location
```

`repo not initialized (run 'no-mistakes init' first)` means the gate has never been set up
there. Do not dispatch against it and do not let a worker run `init` itself - `init` writes git
config, a hook and a local bare repo, which is environment setup and outside any task's scope.
A worker that obeys its brief will stop and report the failure, wasting the dispatch.

Reaching this point means the gate was declined at import, or the posture was raised by hand
afterwards. `/import-project` Step 4 offers initialisation at import time for exactly these two
postures, so this is the exception rather than the normal path.

Tell the user, and let them choose: run `no-mistakes init` in that repo once, or drop the gate
line from the brief for this dispatch. `init` touches no tracked files and is reversible with
`no-mistakes eject`, but it is still their repo's configuration.

## Step 2 - Write a brief per unit of work

Write `$env:KINGSHAND_HOME\data\<id>\brief.md`:

```markdown
# <id> - <one line>

## Goal
<what done looks like, 2-3 sentences>

## Scope
Repo: <repo>
Touch: <paths or areas>
Do NOT touch: <explicit exclusions>

## Requirements
- <one atomic requirement per line, quoted from the ticket where possible>

## Unchanged
- <behaviour that must not change>

## Done means
<the block for this project's mode - see below>
```

**The Done-means block is generated from the resolved mode.** Use exactly one of these three.

`local-only`:

```markdown
- Implemented and committed on this worktree's branch.
- Stop on the branch. Do not push. Do not open a PR. Do not merge.
- Write your findings to `$env:KINGSHAND_HOME\data\<id>\report.md` before you finish. This file is
  required every time, including when the work succeeded plainly with nothing surprising in it.
- Never call `AskUserQuestion`, and never open any interactive prompt, menu or confirmation of
  any kind. You are a background agent with nobody attached: there is no one to answer, and the
  run hangs until it is killed.
- When you reach a decision your brief does not settle, write the question into
  `$env:KINGSHAND_HOME\data\<id>\report.md` - the question, the options you can see, and what you
  would need in order to choose - then stop and say so in your final message.
- Where you can proceed on a stated assumption instead, do that: record the assumption in
  `report.md` and continue rather than stopping.
- Never mention Claude, AI, or an assistant in any commit message or file.
- If the repo cannot build, stop and say so plainly in your final message rather than
  reporting success.
```

`direct-PR`:

```markdown
- Implemented and committed on this worktree's branch.
- Push the branch and open a pull request against the default branch.
- Do not merge it. Report the pull request's full https:// URL in your final message.
- Write your findings to `$env:KINGSHAND_HOME\data\<id>\report.md` before you finish. This file is
  required every time, including when the work succeeded plainly with nothing surprising in it.
- Never call `AskUserQuestion`, and never open any interactive prompt, menu or confirmation of
  any kind. You are a background agent with nobody attached: there is no one to answer, and the
  run hangs until it is killed.
- When you reach a decision your brief does not settle, write the question into
  `$env:KINGSHAND_HOME\data\<id>\report.md` - the question, the options you can see, and what you
  would need in order to choose - then stop and say so in your final message.
- Where you can proceed on a stated assumption instead, do that: record the assumption in
  `report.md` and continue rather than stopping.
- Never mention Claude, AI, or an assistant in any commit message, PR title, PR body or file.
- If the repo cannot build or the push is rejected, stop and say so plainly in your final
  message rather than reporting success.
```

`no-mistakes`:

```markdown
- Implemented and committed on this worktree's branch.
- Run the review gate from inside the worktree and fix what it parks:
  `no-mistakes axi run --intent "<the Goal above, one line>"`
- Drive the pipeline through to a pull request and report its full https:// URL when CI is
  first green. Do not merge it.
- Write your findings to `$env:KINGSHAND_HOME\data\<id>\report.md` before you finish. This file is
  required every time, including when the work succeeded plainly with nothing surprising in it.
- Never call `AskUserQuestion`, and never open any interactive prompt, menu or confirmation of
  any kind. You are a background agent with nobody attached: there is no one to answer, and the
  run hangs until it is killed.
- When you reach a decision your brief does not settle, write the question into
  `$env:KINGSHAND_HOME\data\<id>\report.md` - the question, the options you can see, and what you
  would need in order to choose - then stop and say so in your final message.
- Where you can proceed on a stated assumption instead, do that: record the assumption in
  `report.md` and continue rather than stopping.
- Never mention Claude, AI, or an assistant in any commit message, PR title, PR body or file.
- If the repo cannot build or the gate cannot run, stop and say so plainly in your final
  message rather than reporting success.
```

**The no-interactive-prompts rule is absolute, and it is there because a worker hung on it for
hours.** Worker `7372d875` called `AskUserQuestion`, drew a menu that said "Enter to select,
up/down to navigate", and waited. Nobody was attached, there is no `claude send` to answer a
running worker with, and the only way out was to kill it - a whole dispatch lost. The worker was
not misbehaving: it had loaded `diagnostic-reasoning`, which told it to seek decisive evidence,
and asking looked like the way to get it. Reasonable behaviour, impossible situation. The
boundary is the same one the Hand lives under in reverse - workers never address the user -
so do not soften this back into advice, and do not add an exception for "just one quick
question". A question written into `report.md` reaches the user; a question drawn on a menu
never does.

**Resolve the report path fully before the brief is written.** Substitute both the real root and
the real id: write `C:\tools\kingshand\data\T-1001\report.md`, never the literal `<id>` and never a
`$env:KINGSHAND_HOME` the worker is left to expand. The worker is a separate process that may not
carry your environment, and a brief naming a variable it cannot resolve names no file at all. It is
the brief's own directory, so the worker can already write there - the dispatcher passes `--add-dir`
for it. Do not change the dispatcher to arrange this.

**Say in the brief what the report must contain**, in a few lines each:

- what was done;
- what was decided and why, where a decision was not simply the brief;
- anything the worker could not do, and why;
- anything the next session would need in order to continue without asking.

Keep it short and tell the worker so. A report that runs to an essay is as much a failure as no
report - the point is that a fresh session can pick the work up, not that the worker narrates.

The reason the file exists is that a final chat message is a session artefact. `claude logs` and
the transcript under `~/.claude/projects/` both die with the session, so a finding that lives
only there cannot be recovered by a later session without a handoff. `report.md` is kingshand
state and survives teardown.

The `--skip push,pr,ci` flags are gone from the `no-mistakes` variant deliberately. They existed
because nothing could leave the machine; a project registered `no-mistakes` has consented to the
full pipeline. Never add them back for a `no-mistakes` project, and never remove the push
prohibition from the `local-only` variant.

Two rules about writing briefs, both learned the hard way:

**`Unchanged` is mandatory whenever the ticket states it.** Those lines are instructions not to
do the obvious thing, which is exactly why they get implemented backwards.

**Be literal about artefacts.** A worker told to "create a marker file" produced `MARKER.md`
when the brief asked for `CREW_PROBE.md`. If an exact filename, route, or identifier matters,
state it exactly and say it is exact. Workers paraphrase anything left loose.

## Step 3 - Gate one: approve the dispatch

**This gate is skipped when the project is registered `+yolo`.** In that case write the brief,
say in one line what you are dispatching and why, and go straight to Step 4. With `yolo` off,
which is the default, render the gate and wait.

**The test is `$proj.yolo -eq 'on'`, and nothing else.** `yolo` is the string `'on'` or `'off'`.
`if ($proj.yolo)` is true for `'off'` as well, because a non-empty string is truthy in
PowerShell - it would skip this gate on every project and dispatch work no one approved.

Build one section per unit of work, one item per requirement, then render:

```powershell
$sections = @(
  @{ heading = '<id> - <repo>'; items = @(
      @{ id='R-001'; text='<requirement>'; detail='<source>'; badges=@(); flag=$false }
  )}
)
& $env:KINGSHAND_HOME\bin\Render-Review.ps1 -Title "Dispatch: <ids>" -Subtitle "<n> workers" `
    -Sections $sections -OutputPath $env:KINGSHAND_HOME\data\_dispatch\review.html

$env:LAVISH_AXI_PORT = '4388'
lavish-axi $env:KINGSHAND_HOME\data\_dispatch\review.html
lavish-axi poll $env:KINGSHAND_HOME\data\_dispatch\review.html
```

**Both commands, in that order.** `poll` on its own fails with `No active Lavish Editor session
for this file` / `NOT_FOUND`; the bare `lavish-axi <file>` call is what opens the session that
`poll` then waits on.

`poll` blocks until the user sends. That is expected - it stays silent the whole time. Do not
treat a slow return as a hang, do not kill it, and do not poll in a loop. Run it as a tracked
background job so its completion wakes you; never with `&` or a detached process.

A returned poll is not automatically an approval. Check what came back: `ended_by: agent` means
the session was closed rather than answered, and nothing was approved. Only the user's own sent
feedback is consent to dispatch.

Lavish binds to 127.0.0.1, so these gates are unreachable when the user is away from the
machine. If they say they cannot open the link, put short gates directly in chat and ask which
surface they want for long ones rather than rendering another unreachable page.

When `$proj.yolo -eq 'off'`, dispatch nothing until they approve. If they change a brief, rewrite
it and render again. None of this gate binds a `+yolo` project - there the brief is written, the
one line is said, and Step 4 follows.

## Step 4 - Dispatch

One worker per brief:

```powershell
$r = & $env:KINGSHAND_HOME\bin\Dispatch-Worker.ps1 `
        -RepoPath "<absolute repo path>" -Name "<id>" `
        -BriefPath "$env:KINGSHAND_HOME\data\<id>\brief.md"
```

Then record it:

```powershell
Import-Module $env:KINGSHAND_HOME\bin\Crew.psm1 -Force
$s = Import-CrewState -Path $env:KINGSHAND_HOME\state\crew.json
Add-CrewWorker -State $s -WorkerId $r.id -Ticket "<id>" -Kind "<ticket|adhoc>" `
               -Repo "<repo>" -Worktree $r.worktree -Branch $r.branch -Base $r.base `
               -Brief "$env:KINGSHAND_HOME\data\<id>\brief.md"
Save-CrewState -State $s -Path $env:KINGSHAND_HOME\state\crew.json
```

Then mark the backlog item started, so the queue and the crew agree on what is under way:

```powershell
Set-Location $env:KINGSHAND_HOME
tasks-axi start "<id>"
```

The worker id is assigned by the supervisor and returned by the dispatcher. Never invent one -
`--session-id` is ignored for background workers.

Pass `-Base $r.base` every time. Where the repo has a remote the worktree branches from the
*remote* default branch, and the landing gate needs that ref rather than the local one - see
step 7. The dispatcher confirms whatever it returns with `git rev-parse --verify`, and on a
remoteless repo returns the repo's *local* default branch rather than inventing an `origin/...`
name that would resolve to nothing at the gate.

The dispatcher passes the brief by path, not by value, and grants the worker read access to the
brief's directory with `--add-dir`. Do not "simplify" it back to inlining the brief text:
`Start-Process` flattens its argument list, and a 1,733-character brief reached the worker as
its 57-character first line with every requirement dropped.

**Then arm a poll for that worker, before you say anything to the user.** Nothing else in this
skill wakes you when a worker finishes. Step 5 goes quiet and Step 6 tells you what `done` looks
like, but only this poll's completion brings you back to look:

```powershell
$deadline = (Get-Date).AddMinutes(45)
while ((Get-Date) -lt $deadline) {
  Start-Sleep -Seconds 20
  $w = & claude agents --json 2>$null | ConvertFrom-Json | Where-Object { $_.id -eq '<worker id>' }
  if (-not $w) { "GONE <worker id>"; break }
  if ($w.state -in @('done','blocked','failed')) { "WAKE <worker id> state=$($w.state) status=$($w.status)"; break }
}
```

- Run it as a **harness-tracked background job**, never with `&` and never as a detached process.
  Its completion is what wakes you; an untracked process wakes nothing and you will not notice it
  finish any more than you noticed the worker.
- Arm **one poll per dispatched worker**. Three workers means three polls, each with its own id.
- `blocked` is a wake reason, not a working state. A worker that goes `blocked` needs the user and
  must surface immediately - that is the interactive-prompt failure caught early rather than
  discovered hours later.
- If the poll times out without the worker finishing, re-arm it. A timeout says nothing about the
  worker; assuming it is fine is how the silence starts again.
- **Never promise to report back without arming this first.** Saying "I will report when they are
  done" with no armed poll is exactly the defect this exists to prevent - three workers reached
  their reports and nothing came back to read them. If for any reason the poll cannot be armed,
  tell the user plainly that they will need to ask.

Tell the user one line per worker that dispatch happened, then stop talking.

## Step 5 - Quiet, and status on request

Between dispatch and completion, say nothing unless a worker is blocked, something needs a
decision only the user can make, or the user asks.

**Quiet means no narration, not no monitoring.** The Step 4 poll stays armed the whole time and
its wake is not narration - it is the completion you promised to report. Going quiet is never a
reason to skip arming it, cancel it, or ignore what it returns.

When they ask:

```powershell
& $env:KINGSHAND_HOME\bin\Get-CrewStatus.ps1 | Format-Table -AutoSize
```

This is an update, so it takes the update shape from `CLAUDE.md`'s Escalation and etiquette
section: current state, what the user owes, one concrete next action. Keep it to what changed.
Render it only if they must choose between workers rather than simply read where things stand -
length alone is not the test.

## Step 6 - Completion

A worker is finished when `Get-CrewStatus.ps1` shows `agentState` of `done`.

**Set its stage to `gating`** - the implementation is done and the work is waiting on the landing
gate at Step 7. Say so in chat as an update: what finished, that the landing gate is now theirs,
and the one next action. Keep it short because there is little to say, not because a line count
says so:

```powershell
Set-CrewStage -State $s -WorkerId "<id>" -Stage 'gating'
Save-CrewState -State $s -Path $env:KINGSHAND_HOME\state\crew.json
```

```
T-1001 gating - acme-web, 3 files, review clean
```

If the summary needs more than that, it is a gate rather than a notification - render it and
use lavish instead.

Do not set `ready` here. `ready` belongs to Step 8a's close-out and means something narrower:
the push is confirmed and the worker has been torn down. Keeping the two apart is what lets a
later status query tell "waiting on the landing gate" from "closed out", and stops it re-entering
Step 8a against a worktree that no longer exists.

**Read `$env:KINGSHAND_HOME\data\<id>\report.md` first. It is the primary record of what the worker
found**, and its brief required it. Unlike a chat message it is kingshand state, so it is still
there in a fresh session that dispatched nothing:

```powershell
Get-Content "$env:KINGSHAND_HOME\data\<id>\report.md" -Raw
```

**A missing report is itself worth reporting.** It means the worker did not follow its brief, so
say so to the user rather than quietly falling back - and treat everything else that worker
claims with the same suspicion, since the one instruction you can check it against was ignored.

**Before you treat this worker's work as complete, load `decision-hold-lifecycle`.** A `report.md`
that names a decision the brief did not settle is exactly its trigger, and the Done-means block
above required the worker to write any such question there rather than ask. That skill owns
everything that follows: the stable key, the durable backlog item, and the declaration that says
either every unresolved decision from this report is registered or this report contained none.
A worker finishing is not an answer, and nothing here closes a decision.

**Record the outcome on the backlog item**, pointing at the report rather than restating it:

```powershell
Set-Location $env:KINGSHAND_HOME
tasks-axi update "<id>" --report "data\<id>\report.md"
```

Do not mark it done here. The item closes at Step 8 or Step 8a, when the work has actually landed.

Read the worker's own final message before summarising. If it reported that it could not build
or could not run the gate, say that plainly. Never translate a failure into a success - and set
the stage to `failed` rather than `gating`, because that work is not waiting on a gate and Step
8a must not take it.

`claude agents --json` does **not** carry the final message - its fields are only `cwd, id,
kind, name, pid, sessionId, startedAt, state, status`. Use the log, which is the fallback when
`report.md` is missing or says less than the worker did:

```powershell
claude logs "<worker id>"
```

That prints the session's recent terminal output and is enough almost every time. When the
final message is long enough to have scrolled out of it, read the transcript instead:

```powershell
$w = & claude agents --json | ConvertFrom-Json | Where-Object { $_.id -eq "<worker id>" }
$p = Get-ChildItem "$env:USERPROFILE\.claude\projects" -Recurse -Filter "$($w.sessionId).jsonl" |
     Select-Object -First 1
Get-Content $p.FullName | ForEach-Object { try { $_ | ConvertFrom-Json } catch {} } |
  Where-Object { $_.type -eq 'assistant' -and $_.message.content } |
  ForEach-Object { ($_.message.content | Where-Object { $_.type -eq 'text' }).text } |
  Where-Object { $_ } | Select-Object -Last 1
```

Workers report real problems in that message that no git command will show you. Treat it as
evidence and verify its claims yourself - it is a report, not a finding.

## Step 7 - Gate two: approve the landing

**This gate is skipped when the project is registered `+yolo`**, but only for work that is
green. Gather the evidence either way; with `+yolo` you may take the mode's route below without
asking, provided every check passes and the change stays inside the brief's accepted criteria.

**The test is `$proj.yolo -eq 'on'`, and nothing else.** `yolo` is the string `'on'` or `'off'`.
`if ($proj.yolo)` is true for `'off'` as well, because a non-empty string is truthy in
PowerShell - it would skip this gate on every project and land work no one approved.

These floors hold regardless of posture and `+yolo` never relaxes them:

- Never land red. A failing check is never routine.
- Never land work that materially expands the product or engineering contract beyond what the
  brief accepted. That goes back to the user.
- Destructive, irreversible and security-sensitive actions always go to the user.
- Never merge on the forge. `direct-PR` and `no-mistakes` work ends at a pull request the user
  merges.
- Never push a project that is not registered with a push-capable posture.

**Verify the base ref resolves before gathering anything.** This check is not optional and
nothing below it runs until it passes:

```powershell
$w = Get-CrewWorker -State $s -WorkerId "<id>"
$base = $w.base            # e.g. origin/main, or a local branch - recorded at dispatch
git -C $w.worktree rev-parse --verify --quiet "$base^{commit}"
```

**Empty output, or a non-zero exit, means the base does not resolve - refuse.** Report the
unresolvable base to the user and stop. Do not substitute another ref, do not fall back to
`HEAD`, and above all do not carry on and gather evidence against it.

The reason is that git fails *quietly on stdout* here. `git log "$base..HEAD"` and
`git diff "$base...HEAD"` against a ref that does not exist write `fatal:` to stderr and print
**nothing** to stdout. So the diff comes back as zero files and the attribution scan below comes
back with zero hits, and both look exactly like a clean pass. They are not.

**Empty evidence is never clean evidence.** A diff with no files and an attribution scan with no
hits are a pass only when the range was valid. If the range is invalid they mean the check never
ran, and treating that as green fast-forwards work no one inspected - in the case that found
this, a commit carrying a `Co-Authored-By: Claude` trailer, straight through the rule 3 check.
When you cannot tell which it is, it is not a pass.

With the base confirmed, gather the evidence:

```powershell
git -C $w.worktree --no-pager diff --stat "$base...HEAD"
git -C $w.worktree --no-pager log --oneline "$base..HEAD"
```

**Use `$w.base`, never the local default branch.** Claude Code creates the worktree from the
*remote* default branch. When the local one is behind - which is normal - diffing against it
folds every upstream commit in that gap into what looks like the worker's work. In the first
real run this made a 1-file change appear as 6 files across 3 commits.

Check the commits for attribution before showing anything:

```powershell
git -C $w.worktree --no-pager log --format='%B' "$base..HEAD" |
    Select-String -Pattern 'claude|assistant|co-authored' -CaseSensitive:$false
```

Any hit is a rule 3 violation - report it and do not land until it is fixed. A scan with no hits
counts as clean **only because the base was verified above**; an unverified base produces the
same empty output on a commit that plainly violates the rule.

Scope this to `$base..HEAD` for the same reason. Run against a stale local branch it reports
**colleagues' commits**, whose own co-author trailers are legitimate upstream history and are
none of the crew's business. A hit outside the worker's own commits is a bad diff base, not a
violation.

Everything above runs in every case. What the posture changes is only what happens next. When
`$proj.yolo -eq 'off'`, render the diff and log into sections, poll lavish, and wait for explicit
approval. When `$proj.yolo -eq 'on'`, the waiting is skipped and nothing else is: the evidence is
still gathered and still checked, and a red check, an attribution hit, a scope expansion or
anything destructive still goes to the user.

**Then route on the resolved mode.** This routing is the same whether the gate was answered or
skipped by `+yolo`:

| Resolved mode | Where the work goes from here |
|---|---|
| `local-only` | Step 8 - merge locally, set `landed`, then Step 8b |
| `direct-PR` | **skip Step 8 entirely** - go to Step 8a, then Step 8b |
| `no-mistakes` | **skip Step 8 entirely** - go to Step 8a, then Step 8b |
| `no-mistakes-prod-only` | resolved at Step 1 to `direct-PR` or `no-mistakes` - take that row |

Step 8 is local merging, which push-capable work never does. Sending a `direct-PR` or
`no-mistakes` worker into Step 8 is a dead end - it disclaims them in its first sentence and the
worker would never reach a terminal stage or a teardown.

## Step 8 - Land

Only for a `local-only` project, and only as a local merge. `direct-PR` and `no-mistakes` work
ends at a pull request that the user merges on the forge; crew never merges there. For those
modes, do not run this step at all - report the pull request's full https:// URL and go to
Step 8a.

```powershell
git -C "<repo path>" merge --ff-only "<branch>"
```

If fast-forward is refused, the branch has diverged. Report that and stop. Do not force, do not
rebase, do not merge with a commit, without asking first.

If the local default branch is behind its remote, this fast-forward lands the worker's commits
**and** every upstream commit in the gap. That is a legitimate fast-forward, not a bug, but the
user asked to land one change and would be getting several. Check first and say so plainly:

```powershell
git -C "<repo path>" rev-list --left-right --count "<default>...origin/<default>"
```

A non-zero right-hand number means extra commits ride along. Name how many and whose before
merging.

Then:

```powershell
Set-CrewStage -State $s -WorkerId "<id>" -Stage 'landed'
Save-CrewState -State $s -Path $env:KINGSHAND_HOME\state\crew.json
```

The work has landed, so close the backlog item:

```powershell
Set-Location $env:KINGSHAND_HOME
tasks-axi done "<id>"
```

Then go to Step 8b and tear the worker down.

**Crew itself never pushes.** Pushing is the user's action or the worker's, never yours. A
*worker* pushes only when its project's mode is push-capable - `direct-PR`, `no-mistakes`, or a
`no-mistakes-prod-only` project resolved to one of those - because registering that mode is the
consent. Never for `local-only`, whose brief forbids it outright, and never for a project that
is not registered at all.

## Step 8a - Close out push-capable work

Only for `direct-PR` and `no-mistakes` (including `no-mistakes-prod-only` resolved to either).
There is nothing to merge here - the pull request is the deliverable, and the user merges it.

**Load `decision-hold-lifecycle` before closing this work out.** Close-out advances a stage and
records a pull request; it never closes a decision the user has not answered. A hold opened from
this work's report stays open through `gating`, through `ready`, through `landed`, and through the
teardown at Step 8b, because none of those events is an answer. That skill owns the only way it
may close.

**Check the stage first, and stop if this work is already closed out.** Read it before anything
else:

```powershell
$w = Get-CrewWorker -State $s -WorkerId "<id>"
$w.stage
```

**`ready` or `landed` is the only hard stop.** It means Step 8a has already run and Step 8b has
already torn the worker down. The worktree is gone with the session, so `git -C $w.worktree
ls-remote` below would run against a deleted directory and fail for a reason that has nothing to
do with the push. Report the stage it is already at and stop - there is nothing left to close out.

**`failed` does not close out through Step 8a at all.** Step 6 sets that stage when the worker
reported it could not build or could not run the gate; that work is not waiting on a gate and
this step must not take it. Leave the stage where it is and report the failure as Step 6
describes.

**`dispatched` or `implementing` means Step 6 was skipped, which is normal here.** Step 0 routes
"land / merge / ship a worker" straight to Step 7, and Step 6 is the only place `gating` is ever
set - so a user returning in a fresh session and saying "land T-1001" arrives with the stage never
advanced. That is the direct-entry path working as designed, not a reason to refuse. Set the stage
to `gating` and carry on with the rest of this step:

```powershell
Set-CrewStage -State $s -WorkerId "<id>" -Stage 'gating'
Save-CrewState -State $s -Path $env:KINGSHAND_HOME\state\crew.json
```

Now confirm two things before recording anything:

1. The worker reported a pull request URL, and it is a full `https://` URL.
2. The branch really is on the remote - the PR URL is the worker's claim, not proof:

```powershell
git -C $w.worktree ls-remote --heads origin "<branch>"
```

Empty output means the push never landed. Leave the stage at `gating`, do not advance it to
`ready`, and do not tear anything down; report it and stop.

With both confirmed, the work is finished as far as crew is concerned, but it is not merged, so
it moves from `gating` to `ready` rather than to `landed`. `ready` here is the close-out mark:
the push is confirmed and the worker is about to be torn down. Record it:

```powershell
Set-CrewStage -State $s -WorkerId "<id>" -Stage 'ready'
Save-CrewState -State $s -Path $env:KINGSHAND_HOME\state\crew.json
```

Record the outcome on the backlog item as well - the pull request is what this work produced:

```powershell
Set-Location $env:KINGSHAND_HOME
tasks-axi update "<id>" --pr "<full https:// URL>"
```

Leave the item open at `ready`. Nothing has landed yet, and an item closed here would report a
merge the user has not made.

Move to `landed` only when the user tells you the pull request was merged on the forge, and close
the backlog item in the same breath:

```powershell
Set-CrewStage -State $s -WorkerId "<id>" -Stage 'landed'
Save-CrewState -State $s -Path $env:KINGSHAND_HOME\state\crew.json
```

```powershell
Set-Location $env:KINGSHAND_HOME
tasks-axi done "<id>" --pr "<full https:// URL>"
```

Never check the forge and decide that yourself, and never merge it to make it true. The stages
are exactly `dispatched`, `implementing`, `gating`, `ready`, `landed`, `failed` - `Set-CrewStage`
throws on anything else, so do not invent one for this path.

Then go to Step 8b. The confirmed push is what makes teardown safe here - waiting for the merge
would leave the worktree and the live worker process sitting around until the user gets to it.

## Step 8b - Tear the worker down

**A worker reported `done` is not a dead worker.** The supervisor keeps its process alive so the
session can be resumed, and that live process holds an open handle on the worktree directory.
Removing the worktree while the worker lives fails on Windows with "being used by another
process", leaving a half-deleted directory and a stale git worktree registration.

**When to tear down depends on the mode**, because "the work is safe" means different things:

- `local-only` - after the merge in Step 8. The commits are on the default branch.
- `direct-PR`, `no-mistakes`, and `no-mistakes-prod-only` resolved to either - after the push is
  confirmed in Step 8a, at stage `ready`. The branch is on the remote, so removing the local
  worktree cannot lose the work. Do not wait for the pull request to be merged.

**Work that is neither landed nor pushed is never torn down.** If the merge did not happen and
the branch is not on the remote, the worktree is the only copy of the work and removing it
destroys it. Confirm one or the other first - `claude rm` deletes the worktree with the session.

**`report.md` survives teardown, and must never be deleted as part of cleanup.** It lives at
`$env:KINGSHAND_HOME\data\<id>\report.md`, beside the brief and outside the worktree, so `claude rm`
cannot reach it and nothing here should. Outliving the session is the entire reason the worker
was made to write it: the worktree, the session and its transcript all go, and the findings stay.
Leave `data\<id>\` alone.

Stop the worker first, confirm it is no longer live, and only then remove the worktree. "No
longer live" means what `claude agents --json` actually shows: the worker has no pid, or its
`state` is `exited`, or the id is absent from the listing altogether. A stopped worker that still
appears as exited is stopped - `stop` keeps the session resumable on purpose, so waiting for the
id to vanish before `rm` has run is waiting for something that will not happen.

```powershell
claude stop "<worker id>"      # keeps the conversation, resumable with `claude attach`
claude rm   "<worker id>"      # deletes the session AND its worktree; works on exited ones too
```

That is the whole teardown. `claude rm` owns the worktree, so do not hand-remove it: `stop`
deliberately retains the worktree and says so. Only drop to git when `rm` has already run and
something is still registered:

```powershell
git -C "<repo path>" worktree unlock "<worktree path>"
git -C "<repo path>" worktree remove --force "<worktree path>"
git -C "<repo path>" worktree prune
git -C "<repo path>" branch -D "<branch>"      # only when discarding unlanded work
```

**The unlock is required.** Claude Code registers the worktree as locked (`lock reason: claude
session <name> (pid ...)`), and that lock outlives the process - `remove --force` still refuses
with "cannot remove a locked working tree" against a pid that no longer exists. Stopping the
worker does not release it.

If removal still fails after unlocking, the worker is not actually stopped. Do not force-delete
the directory underneath git - that leaves the worktree registered and the next dispatch with
the same name will fail.

`claude stop <id>` and `claude rm <id>` are both real, verified top-level commands - use them
rather than the agent view. `stop` keeps the conversation so the session can be resumed with
`claude attach <id>`. Do not kill the pid instead: `Stop-Process` leaves the supervisor's record
behind, the supervisor may respawn from its stored `respawnFlags`, and a worker stopped that way
can reappear in `claude agents --json` with no pid and a reverted cwd.

Confirm in `claude agents --json` that the worker is no longer live before touching the worktree:
no pid, or `state` of `exited`, or - once `claude rm` has run - absent from the listing. A live
pid is the one result that means stop did not take.

## Step 9 - Report

One or two lines: what landed or is waiting as a pull request, what is still running, anything
needing the user next.
Do not reprint the diff. The surface was the report.
