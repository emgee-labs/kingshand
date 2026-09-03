---
name: muster
description: Use when the user wants work done on one or more tickets or repos in parallel - e.g. "do T-1001 and T-1002", "start on ticket T-1003", "fix the flaky login test in acme-web", "what are the workers doing", "land T-1001", "dispatch a worker", "muster a worker", "muster". Writes a brief per unit of work, gates it with the user, dispatches a background worker per brief, reports on completion, and lands only on explicit approval.
tools: Bash, PowerShell, Read, Write, Glob, Grep, ToolSearch, AskUserQuestion
version: 1.0.0
---

# Muster

## Overview

You dispatch background workers, one per unit of work, each in its own git worktree. How much
the user is involved depends on the project's posture. With `yolo` off, which is the default,
they are involved at two moments: approving what gets dispatched, and approving what lands. With
`+yolo` they are involved at neither - you proceed on your own, inside the floors in Step 7 that
no posture relaxes. And for the push-capable modes, `direct-PR` and `no-mistakes`, your
involvement ends at a pull request the user merges on the forge rather than at anything you land
here.

Everything you are not gating on is yours, and you stay quiet through it.

$ARGUMENTS

## Step 0 - Which operation

| The user says | Go to |
|---|---|
| names tickets, or describes work to do | Step 1 |
| asks what the workers are doing | Step 5 |
| says land / merge / ship a worker | Step 7 |

## Step 1 - Intake

Two kinds of work:

- **ticket** - an ADO work item id. Fetch it.
- **adhoc** - free text with no ticket. Use a short kebab-case slug as the id.

**Adhoc is the ordinary path and the one that needs nothing.** Azure DevOps is an optional
integration: the `ado-local-mcp` server is not a kingshand prerequisite, `install.ps1` does not
install it, and it needs an Azure DevOps organization and a token that most users do not have.
Nothing else in kingshand touches it.

For tickets, load the ADO tools:

```
ToolSearch: select:mcp__ado-local-mcp__wit_get_work_item,mcp__ado-local-mcp__wit_list_work_item_comments
```

**If those tools do not come back, say so plainly and carry on as adhoc. Never fail here, and
never retry in a loop.** An absent MCP server is a machine that is not set up for Azure DevOps,
which is the common case and not a fault. Tell the user in one line that Azure DevOps is not
connected on this machine, ask them to paste the ticket text or describe the work in their own
words, and treat what they give you as adhoc - a kebab-case slug for the id, their words as the
requirements. Keep the ticket id in the slug where they gave one, so the work is still findable by
it. Do not stop the dispatch, do not tell them to install anything, and do not go looking for the
work item another way.

Where the ADO tools did load, the rest of this section applies.

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
import it with `/annex`. Do not guess a posture, and do not dispatch without one.

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
afterwards. `/annex` Step 4 offers initialisation at import time for exactly these two
postures, so this is the exception rather than the normal path.

Tell the user, and let them choose: run `no-mistakes init` in that repo once, or drop the gate
line from the brief for this dispatch. `init` touches no tracked files and is reversible with
`no-mistakes eject`, but it is still their repo's configuration.

**Then establish whether anything can report a check there, before promising a worker it can wait
for one.** The pipeline's `ci` step waits for checks, and it cannot tell "checks have not started
yet" from "checks will never exist" - so on a repository with no CI it waits forever. A run on the
kingshand repository sat on that step for over an hour and was found only because the King asked.

```powershell
Import-Module $env:KINGSHAND_HOME\bin\Ci.psm1 -Force
$ci = Get-RepoCiStatus -RepoPath "<absolute repo path>"
"$($ci.status) - $($ci.detail)"
$ci.briefLine
```

Three answers, and each one changes what happens next:

- `has-ci` - carry on. `$ci.briefLine` is the ordinary line and Step 2 uses it unchanged.
- `no-ci` - carry on, and **say so in one plain line when you tell the user what you are
  dispatching**. `$ci.briefLine` now tells the worker to stop at the pull request instead of
  waiting for checks that cannot arrive. Do not offer to add CI to the repository: an absence is a
  decision somebody made, and this step makes it safe rather than reversing it.
- `unknown` - the question could not be settled: no `gh`, a remote this cannot see, an
  unauthenticated machine, a network that did not answer. **Say which, in one line, at dispatch
  time.** `$ci.briefLine` is the terminating one here too, because under uncertainty a worker that
  stops at the pull request loses at most a wait for a check the user can see on the forge anyway,
  while one told to wait for green loses an hour to checks that may not exist.

**Never substitute your own reading for the three answers, and never treat `unknown` as `no-ci`
when you report it.** The whole value of the check is that a failed lookup stays visibly a failed
lookup - `bin\Ci.psm1`'s header owns why, and it never converts one into an answer.

Carry `$ci.briefLine` to Step 2 verbatim. A preflight whose answer never reaches the brief changes
nothing at all, because the worker reads its brief and nothing else.

## Step 2 - Write a brief per unit of work

**Read the index for this project before you write anything.** It is at
`$env:KINGSHAND_HOME\data\index\<project>.md`, with kingshand's own operational files in
`$env:KINGSHAND_HOME\data\index.md`, and it is one line per durable file rather than the files
themselves - a page to scan, not a cost. Then **name in the brief, by absolute path and with an
instruction to read it in full, every file this task plausibly touches**, and say which source wins
where two disagree. Nothing else delivers them: a worker sees exactly one thing, its brief, so "it
is recorded" is not a delivery mechanism. A fully settled brand spec sat in `data\` naming itself
the input to the website brief while the site shipped without its logo, its favicon, its tagline or
its palette, because no brief ever named the file.

**`Read first` is a mandatory section of every brief**, and it is where those paths go. A
requirement that lives only in this skill reaches nobody: the worker never reads this file, it
reads the brief, so the slot has to be in the artefact. Write one line per file - the absolute
path, what it settles, and an instruction to read it in full - then the line that says which
source wins where two disagree. Where the index turns up nothing this task touches, say
`- Nothing beyond this brief - the index was checked and nothing in it applies.` rather than
dropping the section, so a brief that names no file is a decision someone made rather than a slot
someone forgot. Dispatch refuses a brief with no `## Read first` heading at all, before anything is
created - so a brief written before this section existed needs that one line adding before it can go
out.

**Where anything at all is indexed, that line is not optional, and it has to state both halves: that
the index was checked, and that nothing in it applies.** The line above is the one to copy, but the
wording is yours - dispatch accepts a paraphrase that states both halves, and refuses one that
leaves either out. Dispatch reads both indexes that could cover the work - the root `data\index.md`
and the project's own `data\index\<project>.md` - and refuses unless either a file is passed to
`-ReadPath` at Step 4 or the section states in one line that the index was checked and nothing in
it applies. The root index is not project-scoped, so it gates a repo the registry has never heard
of just as it gates a registered one, and it is where the settled files this exists to protect
actually sit. An empty section does not pass and neither does `- Nothing beyond this brief.` on its
own: a brief that says the index was checked is a decision, where a brief that says nothing is the
failure this whole mechanism exists to stop - a settled spec that sat in `data\` unread while the
site it described shipped without it. Reading the index is the first line of this step for exactly
that reason; the refusal is what stops a busy session skipping it.

**The project's own two standing files do not discharge this.** The criteria file goes to
`-ReadPath` on every brief for a project that has one, and dispatch attaches both it and
`data\rules-<project>.md` whether or not anyone passes them, so a gate that counted either would be
one no dispatch could ever fail again - and dispatch knows it, discounting `done-<project>.md` and
`rules-<project>.md` from the paths that satisfy this refusal. Where it is the only file this task
touches, a line about the index still goes in the section beside it - but not the literal one
above, which would tell the worker there is nothing beyond the brief in the same breath as handing
it a file to read. Write what is true instead:

```markdown
- The index was checked; nothing in it applies to this task beyond the standing criteria above.
```

Dispatch accepts that because it states both halves, and the worker gets a section that agrees with
itself. Any other file you pass counts as it always did.

**Name the copy, not the original.** A worker can reach exactly two places: its own worktree and
the brief's own directory. A settled file at `data\<name>.md` is a sibling of `data\<id>\` rather
than inside it, so a brief naming it there tells the worker to open a file it cannot reach - the
original failure with one extra hop. Step 4 hands the original to `-ReadPath` and dispatch copies
it to `$env:KINGSHAND_HOME\data\<id>\read-first\<filename>`, keeping the file name exactly. That
is the path the `Read first` line names, and every path you write there goes to `-ReadPath` at
Step 4.

**Nothing checks that those two agree, so you are the one who has to.** Dispatch reads this section
for its heading and for the one line stating the index was checked, and for no path at all: the
paths reach it through `-ReadPath`, from you, in the same call. Write the section and the
parameter together, in one go, and the pair cannot come apart. A line naming the original at
`data\<name>.md` instead of the copy sends the worker to a sibling of the one directory it can
read, and a copy no line names reaches nobody - both are yours to get right at the moment you
write them.

**Substitute this work's own id, every time.** Briefs get written several at a time from one
template, and a `Read first` block carried over from the brief above it keeps the other unit's id -
`data\<other id>\read-first\<filename>` names a real file in a directory this worker cannot read,
and the file name still matches, so only the id gives it away.

Say in the same line what the copy is of, so the worker knows what it is holding and a later reader
can find the original. The copy is taken at dispatch and does not change afterwards, which is
exactly what the brief itself is.

Granting the original's own directory would be the shorter route and it is the wrong one: the
canonical settled file sits directly under `data\`, so that grant hands the worker every other
worker's brief and report, `king.md`, `learnings.md`, `backlog.md` and `projects.md`, and hands
them writable. Do not ask for it.

**Paste the project's standing criteria into the brief.** They live at
`$env:KINGSHAND_HOME\data\done-<project>.md` - one `-` bullet per criterion, each naming how it is
checked, and that one form is what every line of that file takes wherever it is written or read -
and they are what every change to that project is expected to meet whether or not this task's
ticket mentions them. Read the file, paste its lines into `## Standing criteria` unchanged, and
hand the same file to `-ReadPath` at Step 4 with a `Read first` line naming the copy, exactly like
any other settled file. Both, and for different reasons: the paste is in the artefact the worker is
judged against, so it is what gets complied with, and the copy is what a mid-task re-read reaches.
Where the file holds no criteria - it does not exist yet, or the fold-back has retired its last
line - write `- Nothing standing for this project yet.` rather than dropping the section, so an
empty list is a decision someone made. Key that on what the file holds and never on whether it
exists: a file retired down to nothing pastes an empty section, and a worker cannot tell an empty
section from one it forgot to work. Where the file is absent, also write no `Read first` line for
it and pass no `-ReadPath` for it either, because Step 4 refuses a brief naming a file that is not
there and the refusal costs a whole dispatch. Read the file every time even so, and never carry an
absence forward from the last brief you wrote: the fold-back at Step 6 creates it the first time a
gate finding generalises, so a project with nothing standing today has criteria the next dispatch
is expected to meet. Where a criterion is one this task deliberately sets aside, say so in
`Requirements` or `Unchanged` and in the `Intent` section the gate is handed - the brief wins over
the file, and a worker left to work out which source wins picks wrong half the time.

**The project's standing rules are not pasted and not passed.** `data\rules-<project>.md` holds
context and vocabulary - tagging and casing, shorthand, folders never to touch, branch naming,
where a login is kept - and `annex` owns its format. Dispatch attaches it by itself and writes the
`Read first` line naming the copy, so pass no `-ReadPath` for it and write no line for it. Do not
paste it into the brief and never ask the worker to report against it: it is reference, and an
`n/a` answered to "our tickets are tagged NG-" dilutes the self-check on the lines that are really
tested. **Read it yourself before you write the brief** - the copy goes to the worker, and the
ticket text is yours.

Dispatch attaches `done-<project>.md` on the same terms if you did not pass it, which is a backstop
and not a reason to stop passing it: the paste above is what the worker is judged against, and it
is still yours to write.

**`Browser checks` is the one optional section, and it is optional both ways.** Leave it out
entirely unless this task changes something a browser renders and you can state what to look at -
most tasks change nothing of the kind, and a browser step nobody asked for is cost with no answer
attached. Where you do write it, load `witness` first, and then **hand the worker the two files the
step runs on rather than their names**: pass both
`$env:KINGSHAND_HOME\.claude\skills\witness\SKILL.md` and
`$env:KINGSHAND_HOME\bin\BrowserVerify.psm1` to `-ReadPath` at Step 4 and name both copies under
`Read first`, exactly as you would any other settled file. Naming them where they live is not
delivery - a worker reaches its own worktree and the brief's directory and nowhere else, and it
cannot load one of kingshand's skills at all - so a list of things to look at pointing at files
outside both sends it into a browser without the read-only boundary, the credential rule or the
record every check has to end up in, and the change comes back asserted, which is the one outcome
the section exists to prevent. Write both paths in that section resolved, the same way the report
path is: `$env:KINGSHAND_HOME` is often unset in a worker's session, so either path written
against it names no file at all, and the browser step dies on the first line of the procedure it
never read.

**Those copies do not discharge the index line.** Dispatch discounts them exactly as it discounts
the standing-criteria file, and for the same reason - every brief carrying browser checks passes
them, so they are evidence of nothing about this task. It also refuses the dispatch outright where
the section is there and either file was not passed, before anything is created, because a section
pointing at a copy that does not exist is the delivery failure this whole route was built to end. It is the one section in the template carrying a delete marker for that reason: every
other section stays in every brief, and this one arriving by accident is a browser step on a
migration. Give each line an id - `C-001`, `C-002` - because the worker copies those ids out
before it starts and the record answers on every one of them, which is what stops a check it never
reached going missing.

Write `$env:KINGSHAND_HOME\data\<id>\brief.md`:

```markdown
# <id> - <one line>

## Goal
<what done looks like, 2-3 sentences>

## Read first
- `$env:KINGSHAND_HOME\data\<id>\read-first\<filename>` - <what it settles>, copied here from
  `<the original absolute path>`. Read it in full before you start. If you cannot read it, stop
  and report that rather than proceeding without it.
- Where this brief and <that file> disagree, <the one that wins> wins.

## Scope
Repo: <repo>
Touch: <paths or areas>
Do NOT touch: <explicit exclusions>

## Requirements
- <one atomic requirement per line, quoted from the ticket where possible>

## Unchanged
- <behaviour that must not change>

## Browser checks  <- delete this whole section unless the task renders something to look at
Read `<the resolved KINGSHAND_HOME>\data\<id>\read-first\SKILL.md` - the browser procedure, named
under `Read first` above - in full before you touch a browser tool. It owns how the browser is driven,
what you may not do to a live server, how a login is read, and the record each check below has to
end up in: every one of them answered by its id in `report.md`, verified, failed or not checked.
The module it tells you to import is beside it, at
`<the resolved KINGSHAND_HOME>\data\<id>\read-first\BrowserVerify.psm1`.
- C-001 <one thing to look at, stated as something observable in a browser>

## Standing criteria
<the lines of `data\done-<project>.md`, pasted unchanged>

## Intent
<the Goal in one line, plus every settled decision and standing criterion this task sets aside,
and why - this is the string the gate is given verbatim>

## Repeated findings
1. While you fix, keep a tally two ways: gate rounds by the file or component they landed in, and
   failed fix attempts per bug. The failed-attempt half applies whatever this brief asks of you.
   The round half applies only where the `Done means` block below has you run the review gate -
   where it does not there is no pass and no round to record, a report with no rounds in it is the
   right record rather than a missing one, and you never write a round for a gate you did not run.
   Where it does, the tally is kept as it happens rather than reconstructed at the end. Record every
   round in `report.md` as it lands - what it found and where - whether or not the tally ever reaches
   three, because that record is the only thing the standing criteria can be compared against once
   you are gone. Record the first pass even when it raises nothing, as `round 1: no findings`, so
   that a report with no rounds in it means the recording was skipped rather than that the gate was
   clean.
2. On the third round of findings in one component, or the third failed attempt at one bug, **carry
   on fixing every finding as normal.** Nothing here caps the rounds or lets you stop early.
3. Additionally write into `report.md` the tally, what each round or attempt found, and the design
   question: what keeps producing them - the component that goes on raising findings, or the bug
   that will not stay fixed - and what the alternative is. Whichever of the two triggers fired is
   the one to write up, and on a brief that runs no review gate the failed attempts are the only
   trigger there is. Say it in your final message too, so it arrives as a finding rather than a
   completion notice.

## Done means
<the block for this project's mode - see below>
```

With that file on disk, index it. Index the brief in the same step that writes it, so the two
cannot come apart - and never before it is written, or the index carries a line for a file that
was abandoned:

```powershell
Import-Module $env:KINGSHAND_HOME\bin\Index.psm1 -Force
Add-IndexEntry -Project "<project>" -Path "data\<id>\brief.md" -Summary "<the one-line title>"
```

**The Done-means block is generated from the resolved mode.** Use exactly one of these four - and
for a `no-mistakes` task, which of the two `no-mistakes` blocks is chosen by Step 1b's answer, not
by memory: `has-ci` takes the first, `no-ci` and `unknown` take the second.

`local-only`:

```markdown
- Implemented and committed on this worktree's branch.
- Before you deliver - before you invoke the gate, push, open a pull request, or stop on the
  branch - work the `Standing criteria` section above line by line and record the result in
  `report.md`: for each line, `pass` with what you checked, `fixed` with what you changed, or `n/a`
  with the reason. A criterion you cannot check is a criterion to report, not to skip. Where
  `Requirements` or `Unchanged` sets a criterion aside, this brief overrides that line: record it
  `n/a` naming the brief line that set it aside, and do not implement it.
- Stop on the branch. Do not push. Do not open a PR. Do not merge.
- Write your findings to `$env:KINGSHAND_HOME\data\<id>\report.md` before you finish. This file is
  required every time, including when the work succeeded plainly with nothing surprising in it.
- Never call `AskUserQuestion`, and never open any interactive prompt, menu or confirmation of
  any kind. You are a background agent with nobody attached: there is no one to answer, and the
  run hangs until it is killed.
- When you reach a decision your brief does not settle, write the question into
  `$env:KINGSHAND_HOME\data\<id>\report.md` - the question, the options you can see, and what you
  would need in order to choose - then say so in your final message and end your turn. **Write it
  as prose, the way you would put it to a colleague at their desk.** Nothing parses this file, so
  there is no heading to match exactly, no slug to keep and no marker to get wrong: the Hand reads
  what you wrote and records the decision itself. **Ending your turn is not the end of your work.**
  The answer comes back to you as an ordinary prompt and you carry on from there, so leave
  everything where it is: do not undo what you have done, do not pick a different task, and do not
  report the work as failed. When the answer reaches you, write down what was decided and what you
  did with it in that same file, and carry on. A second question later is just another question,
  written the same way.
- Where you can proceed on a stated assumption instead, do that: record the assumption in
  `report.md` and continue rather than stopping.
- Never mention Claude, AI, or an assistant in any commit message or file.
- If the repo cannot build, stop and say so plainly in your final message rather than
  reporting success.
```

`direct-PR`:

```markdown
- Implemented and committed on this worktree's branch.
- Before you deliver - before you invoke the gate, push, open a pull request, or stop on the
  branch - work the `Standing criteria` section above line by line and record the result in
  `report.md`: for each line, `pass` with what you checked, `fixed` with what you changed, or `n/a`
  with the reason. A criterion you cannot check is a criterion to report, not to skip. Where
  `Requirements` or `Unchanged` sets a criterion aside, this brief overrides that line: record it
  `n/a` naming the brief line that set it aside, and do not implement it.
- Push the branch and open a pull request against the default branch.
- Do not merge it. Report the pull request's full https:// URL in your final message.
- Write your findings to `$env:KINGSHAND_HOME\data\<id>\report.md` before you finish. This file is
  required every time, including when the work succeeded plainly with nothing surprising in it.
- Never call `AskUserQuestion`, and never open any interactive prompt, menu or confirmation of
  any kind. You are a background agent with nobody attached: there is no one to answer, and the
  run hangs until it is killed.
- When you reach a decision your brief does not settle, write the question into
  `$env:KINGSHAND_HOME\data\<id>\report.md` - the question, the options you can see, and what you
  would need in order to choose - then say so in your final message and end your turn. **Write it
  as prose, the way you would put it to a colleague at their desk.** Nothing parses this file, so
  there is no heading to match exactly, no slug to keep and no marker to get wrong: the Hand reads
  what you wrote and records the decision itself. **Ending your turn is not the end of your work.**
  The answer comes back to you as an ordinary prompt and you carry on from there, so leave
  everything where it is: do not undo what you have done, do not pick a different task, and do not
  report the work as failed. When the answer reaches you, write down what was decided and what you
  did with it in that same file, and carry on. A second question later is just another question,
  written the same way.
- Where you can proceed on a stated assumption instead, do that: record the assumption in
  `report.md` and continue rather than stopping.
- Never mention Claude, AI, or an assistant in any commit message, PR title, PR body or file.
- If the repo cannot build or the push is rejected, stop and say so plainly in your final
  message rather than reporting success.
```

`no-mistakes`, where Step 1b answered `has-ci`:

```markdown
- Implemented and committed on this worktree's branch.
- Before you deliver - before you invoke the gate, push, open a pull request, or stop on the
  branch - work the `Standing criteria` section above line by line and record the result in
  `report.md`: for each line, `pass` with what you checked, `fixed` with what you changed, or `n/a`
  with the reason. A criterion you cannot check is a criterion to report, not to skip. Where
  `Requirements` or `Unchanged` sets a criterion aside, this brief overrides that line: record it
  `n/a` naming the brief line that set it aside, and do not implement it.
- Run the review gate from inside the worktree and fix what it parks:
  `no-mistakes axi run --intent '<the `Intent` section above, verbatim on one line>'`
  Single quotes, and keep them: that section names files, modes and postures in backticks, and in a
  double-quoted PowerShell string a backtick escapes the character after it, so the gate would be
  handed a mangled sentence and no error. Run the line in PowerShell and double any single quote
  inside the section - doubling is PowerShell's escape, and in a POSIX shell the same two
  characters close and reopen the string, so the apostrophe is deleted instead.
- A finding the gate classifies `ask-user` is a decision your brief does not settle, so it takes
  the `When you reach a decision your brief does not settle` bullet below - named by its text,
  because a bullet named by position points at whatever was inserted above it since. **Leave the
  run parked while you wait.** `axi run` returned at that gate rather than holding your terminal,
  so the run still owns the branch and every fix commit it has already made, and nothing is being
  lost by waiting. Do not abort it, do not start a second run, and never pass `--yes` - that flag
  decides ask-user findings itself with no escalation, which is the one thing you may not do. When
  the answer reaches you, apply it with `no-mistakes axi respond` on that same run and carry on.
- Drive the pipeline through to a pull request and report its full https:// URL when CI is
  first green. Do not merge it.
- Write your findings to `$env:KINGSHAND_HOME\data\<id>\report.md` before you finish. This file is
  required every time, including when the work succeeded plainly with nothing surprising in it.
- Never call `AskUserQuestion`, and never open any interactive prompt, menu or confirmation of
  any kind. You are a background agent with nobody attached: there is no one to answer, and the
  run hangs until it is killed.
- When you reach a decision your brief does not settle, write the question into
  `$env:KINGSHAND_HOME\data\<id>\report.md` - the question, the options you can see, and what you
  would need in order to choose - then say so in your final message and end your turn. **Write it
  as prose, the way you would put it to a colleague at their desk.** Nothing parses this file, so
  there is no heading to match exactly, no slug to keep and no marker to get wrong: the Hand reads
  what you wrote and records the decision itself. **Ending your turn is not the end of your work.**
  The answer comes back to you as an ordinary prompt and you carry on from there, so leave
  everything where it is: do not undo what you have done, do not pick a different task, and do not
  report the work as failed. When the answer reaches you, write down what was decided and what you
  did with it in that same file, and carry on. A second question later is just another question,
  written the same way.
- Where you can proceed on a stated assumption instead, do that: record the assumption in
  `report.md` and continue rather than stopping. **A finding the gate classified `ask-user` is
  never one of those.** Stating an assumption over one and carrying on is you answering your own
  ask-user finding, which is the one thing you may not do - write it down as the bullet above says
  and wait, however obvious the answer looks from here.
- Never mention Claude, AI, or an assistant in any commit message, PR title, PR body or file.
- If the repo cannot build or the gate cannot run, stop and say so plainly in your final
  message rather than reporting success.
```

`no-mistakes`, where Step 1b answered `no-ci` or `unknown`. Identical but for the `Drive the
pipeline` line, which is the whole point of the preflight - it ends a wait that would otherwise have
no end. Named by its text and never by its position: bullets get inserted above it, and an ordinal
that has gone stale points a Hand at the gate-run bullet instead:

```markdown
- Implemented and committed on this worktree's branch.
- Before you deliver - before you invoke the gate, push, open a pull request, or stop on the
  branch - work the `Standing criteria` section above line by line and record the result in
  `report.md`: for each line, `pass` with what you checked, `fixed` with what you changed, or `n/a`
  with the reason. A criterion you cannot check is a criterion to report, not to skip. Where
  `Requirements` or `Unchanged` sets a criterion aside, this brief overrides that line: record it
  `n/a` naming the brief line that set it aside, and do not implement it.
- Run the review gate from inside the worktree and fix what it parks:
  `no-mistakes axi run --intent '<the `Intent` section above, verbatim on one line>'`
  Single quotes, and keep them: that section names files, modes and postures in backticks, and in a
  double-quoted PowerShell string a backtick escapes the character after it, so the gate would be
  handed a mangled sentence and no error. Run the line in PowerShell and double any single quote
  inside the section - doubling is PowerShell's escape, and in a POSIX shell the same two
  characters close and reopen the string, so the apostrophe is deleted instead.
- A finding the gate classifies `ask-user` is a decision your brief does not settle, so it takes
  the `When you reach a decision your brief does not settle` bullet below - named by its text,
  because a bullet named by position points at whatever was inserted above it since. **Leave the
  run parked while you wait.** `axi run` returned at that gate rather than holding your terminal,
  so the run still owns the branch and every fix commit it has already made, and nothing is being
  lost by waiting. Do not abort it, do not start a second run, and never pass `--yes` - that flag
  decides ask-user findings itself with no escalation, which is the one thing you may not do. When
  the answer reaches you, apply it with `no-mistakes axi respond` on that same run and carry on.
- Drive the pipeline through to a pull request and stop there.
  Checks may not report on this repository at all, so when the pipeline's `ci` step has been
  waiting more than fifteen minutes with no checks reported, report the pull request's full
  https:// URL as delivered, say plainly that no checks were reported, and stop. Do not sit on it.
  Do not merge it.
- Write your findings to `$env:KINGSHAND_HOME\data\<id>\report.md` before you finish. This file is
  required every time, including when the work succeeded plainly with nothing surprising in it.
- Never call `AskUserQuestion`, and never open any interactive prompt, menu or confirmation of
  any kind. You are a background agent with nobody attached: there is no one to answer, and the
  run hangs until it is killed.
- When you reach a decision your brief does not settle, write the question into
  `$env:KINGSHAND_HOME\data\<id>\report.md` - the question, the options you can see, and what you
  would need in order to choose - then say so in your final message and end your turn. **Write it
  as prose, the way you would put it to a colleague at their desk.** Nothing parses this file, so
  there is no heading to match exactly, no slug to keep and no marker to get wrong: the Hand reads
  what you wrote and records the decision itself. **Ending your turn is not the end of your work.**
  The answer comes back to you as an ordinary prompt and you carry on from there, so leave
  everything where it is: do not undo what you have done, do not pick a different task, and do not
  report the work as failed. When the answer reaches you, write down what was decided and what you
  did with it in that same file, and carry on. A second question later is just another question,
  written the same way.
- Where you can proceed on a stated assumption instead, do that: record the assumption in
  `report.md` and continue rather than stopping. **A finding the gate classified `ask-user` is
  never one of those.** Stating an assumption over one and carrying on is you answering your own
  ask-user finding, which is the one thing you may not do - write it down as the bullet above says
  and wait, however obvious the answer looks from here.
- Never mention Claude, AI, or an assistant in any commit message, PR title, PR body or file.
- If the repo cannot build or the gate cannot run, stop and say so plainly in your final
  message rather than reporting success.
```

That `Drive the pipeline` line is `$ci.briefLine` from Step 1b, and taking it from there rather than
retyping it is the point: the two must agree, and only one of them is computed from what the
repository actually has. **Do not decide between the two blocks yourself** - a repository with no workflow file may
still get checks from outside it, which is exactly the case a reading-by-eye gets wrong.

**The no-interactive-prompts rule is absolute, and it is there because a worker hung on it for
hours.** Worker `7372d875` called `AskUserQuestion`, drew a menu that said "Enter to select,
up/down to navigate", and waited five hours with nobody watching. herdr now recognises that state
and reports the worker `blocked`, so the hang surfaces in minutes rather than never - but being
able to see a hang is not permission to cause one. Answering a menu on the worker's behalf is a
recovery path that `rally` owns, and it spends a decision the user was never asked to make. The
worker was not misbehaving: it had loaded `inquest`, which told it to seek decisive evidence,
and asking looked like the way to get it. Reasonable behaviour, impossible situation. The
boundary is the same one the Hand lives under in reverse - workers never address the user -
so do not soften this back into advice, and do not add an exception for "just one quick
question". A question written into `report.md` reaches the user; a question drawn on a menu
never does.

**Resolve the report path fully before the brief is written.** Substitute both the real root and
the real id: write `$env:KINGSHAND_HOME\data\T-1001\report.md`, never the literal `<id>` and never a
`$env:KINGSHAND_HOME` the worker is left to expand. The worker is a separate process that may not
carry your environment, and a brief naming a variable it cannot resolve names no file at all. The
worker can already write there - the dispatcher lists the brief's directory in the worktree's
`.claude\settings.local.json` before the worker starts. Do not change the dispatcher to arrange
this, and do not try to pass it as a command-line argument: no arguments reach a worker at all.

**Say in the brief what the report must contain**, in a few lines each:

- what was done;
- what was decided and why, where a decision was not simply the brief;
- anything the worker could not do, and why;
- anything the next session would need in order to continue without asking;
- a `## Browser verification` block, where and only where this brief carries `## Browser checks`:
  the verdict line, then every check id that section listed with what was seen. Step 6 reads it,
  so a brief that asks for the checks asks for the block that answers them.

Keep it short and tell the worker so. A report that runs to an essay is as much a failure as no
report - the point is that a fresh session can pick the work up, not that the worker narrates.

The reason the file exists is that a final chat message is a session artefact. A worker's screen
dies with its pane, and workers inherit `CLAUDE_CODE_CHILD_SESSION` from the Hand's own session,
so transcript saving is off and there is usually no transcript on disk to fall back to at all. A
finding that lives only in the worker's output cannot be recovered by a later session.
`report.md` is kingshand state and survives teardown.

The `--skip push,pr,ci` flags are gone from the `no-mistakes` variant deliberately. They existed
because nothing could leave the machine; a project registered `no-mistakes` has consented to the
full pipeline. Never add them back for a `no-mistakes` project, and never remove the push
prohibition from the `local-only` variant.

**Say in `--intent` what this task deliberately sets aside.** You write that string, not the worker:
it is the `Intent` section of the brief, and the two `no-mistakes` blocks hand it to the gate
verbatim. Start from the Goal in one line and add to it the settled decisions and standing criteria
this work breaks, and why. Leaving the section to say only what the Goal says is how a set-aside
recorded in `Requirements` or `Unchanged` never reaches the gate at all.
`emgee-apex-design` named all seven of its settled decisions there and came back with engineering
findings only and no ask-user finding at all, where `kh-decision-carry` left a stale intent string
and the gate duly raised a finding against the mismatch.

**Never tell the review gate what not to flag.** That string says what the work is for; it never
says what the reviewer may not find. A wider intent is exactly where someone weakens the gate while
believing they are being helpful, and from outside the two are indistinguishable - a run that
raised nothing looks identical either way - so catch it in your own sentence rather than in your
motive. You are already doing it if you write "the prose assertions in `Docs.Tests.ps1` are
settled, do not raise them again", "the design notes in `docs\` are settled, so raise nothing
against them", "the King has already declined findings of this class", or "no linter is configured
here, so ignore lint". Each of those is a real decline from this repository's own gate history
turned into an instruction to the reviewer. Name the decision and the evidence for it, and let the
gate raise the finding anyway.

Rules about writing briefs, all learned the hard way:

**`Unchanged` is mandatory whenever the ticket states it.** Those lines are instructions not to
do the obvious thing, which is exactly why they get implemented backwards.

**Be literal about artefacts.** A worker told to "create a marker file" produced `MARKER.md`
when the brief asked for `WORKER_PROBE.md`. If an exact filename, route, or identifier matters,
state it exactly and say it is exact. Workers paraphrase anything left loose.

**Never leave a worker to hand-write something that reads an open-ended text format.** Anything
hand-written that parses, renders or normalises an open format has no last case, so it has no last
review round either. Two dispatches on two projects cost about 16 review rounds between them, every
round in both finding real defects, and both were spent on exactly that. The `## Read first` path
parser took six consecutive rounds, and `docs\2026-08-31-read-first-declared-not-parsed.md` says why
there was no seventh worth having: "there is no round after which the parser is finished".
`emgee-agent-crawlable` took about ten, four of them inside a hand-rolled Markdown renderer before
it was replaced by a library and the rest cleaning up after a swap made that late. Neither is an
enumeration failure - enumerating is what ends both, by showing the list has no end. So where you
already know a requirement reads an open format, say so in `Requirements` rather than leaving the
worker to find out at round six, and say what to do about it: take an existing library, or change
the requirement so the input is not open-ended.

**The `Repeated findings` section in the template is a report, never a cap.** Those ten rounds
found genuine defects every time, so a rule that stopped the fixing at three would have shipped
every one of them - what was actually wrong was a single design decision nobody questioned, and the
rounds were the signal that surfaced it. So the section adds writing and reporting to the worker's
job and takes nothing away from it: never soften **carry on fixing every finding as normal** into
permission to stop, and never put a round limit beside it. Its trigger counts failed fix attempts
on one bug as well as rounds of findings in one component, because three failed fixes is not a
failed hypothesis, it is the wrong architecture. The two actors it touches are gated differently and
conflating them is what turns the rule back into a cap. The worker's own fixing is never gated at
all: it keeps fixing at three rounds and at ten, and the only thing the tripwire adds is what it
writes down. Your own decision is the single place a round count can hold anything back, and only in
one case - deciding an ask-user finding under `petition`, withhold the Fix authorization and
escalate where the rounds show incremental corrections preserving a questionable abstraction rather
than closing independent defects. Where they were closing independent defects it is ordinary
convergence: a bare count of three is not an escalation on its own, so authorize the Fix on the
finding's own merits and send the design question to the user beside it. That is the whole rule
about repeated findings and this is the only place it is stated - `petition` step 7 points here
rather than keeping a second copy.

**A requirement that names a mechanism carries the fact it rests on.** `kh-dispatch-index-gate`'s
brief said to gate on a project's own index. The worker built exactly that, then found that
`data\index\` does not exist at all while `data\index.md` holds real entries, so the gate as
built "would have refused nothing, ever" - correct to the letter, and it had to be widened;
`docs\2026-08-30-data-index.md` owns that record. Where the fact is yours to read - `data\`,
`state\`, the registry - check it and write it into the brief. Where it is inside the project, hard
rule 1 says a worker checks it, so write the requirement as a premise to verify before building to
it rather than as a settled fact.

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
        -BriefPath "$env:KINGSHAND_HOME\data\<id>\brief.md" `
        -ReadPath "<original absolute path 1>", "<original absolute path 2>"
```

**`-ReadPath` takes the ORIGINALS of exactly the files that brief's `Read first` section names,
and nothing else.** It is a list: one quoted path per file, separated by commas. Two paths inside
one pair of quotes are one string naming no file, and dispatch refuses it.

Dispatch copies each one to `$env:KINGSHAND_HOME\data\<id>\read-first\`, which is the path the
brief already names, because that directory is the only place outside its worktree a worker can
read. Drop the parameter only when the section states there is nothing to read.

Every refusal comes before anything at all is created, so a mistake here costs nothing to fix.
There are nine, and each is refused by name: a brief with no `## Read first` section at all, a
brief that passes no `-ReadPath` and does not say the index was checked when anything at all is
indexed - and neither the project's own standing files nor the browser procedure counts towards
that one, per Step 2, which owns the rule - a brief carrying a `## Browser checks` section that
passes no `-ReadPath` for the browser procedure or for the module it imports, a path that does not
exist, a directory where a file was meant, two different files whose names would land on top of
each other in the staging directory, a standing file that exists and cannot be opened, a directory
sitting where a standing file belongs, and a brief that cannot be opened for writing to be told
what was attached to it.

**Dispatch attaches the project's own standing files itself and writes their `Read first` lines.**
`data\done-<project>.md` and `data\rules-<project>.md` are staged whenever they exist, keyed off
the project the registry resolves from the repo path, and a line naming each copy goes in at the
end of that section, below anything you wrote there. It writes no line for a file you passed
yourself - that one you already named - and re-dispatching the same ticket adds nothing. Retire one
of those files and re-dispatch the same ticket, and dispatch takes its own line back out and
deletes the copy, so removing a standing file is enough to stop it reaching a worker. A project
with neither file dispatches exactly as it did before either existed.

**Dispatch does not read the paths out of the brief's prose, and nothing may make it start.** An
earlier version did, comparing what it parsed there against `-ReadPath`, and it cost six review
rounds without reaching a last bug - a path in prose can be absolute or relative, forward or back
slashed, quoted or bare, contain spaces, sit inside a sentence or wrap across a line, and two of
those rounds refused correct briefs over paths nobody had written. You write the brief and you make
this call, so you already hold the list. Passing it here is the whole mechanism.

**A brief written before the `Read first` section existed will be refused**, which is the intended
behaviour rather than a migration problem: the un-dispatched briefs already on disk name no settled
file, and that is the fault, not the refusal. Add the section before dispatching one - one line of
`- Nothing beyond this brief - the index was checked and nothing in it applies.` where it turns up
nothing this task touches.

The staged copies are not indexed, and that is deliberate rather than an oversight: each one is a
snapshot of a file the index already lists at its own path, so `Get-IndexableFiles` excludes
`read-first\` and the drift count stays about files nothing has recorded anywhere.

Then record it:

```powershell
Import-Module $env:KINGSHAND_HOME\bin\Crew.psm1 -Force
$s = Import-CrewState -Path $env:KINGSHAND_HOME\state\crew.json
Add-CrewWorker -State $s -WorkerId $r.id -Ticket "<id>" -Kind "<ticket|adhoc>" `
               -Repo "<repo>" -Worktree $r.worktree -Branch $r.branch -Base $r.base `
               -Brief "$env:KINGSHAND_HOME\data\<id>\brief.md"
Save-CrewState -State $s -Path $env:KINGSHAND_HOME\state\crew.json
```

Then mark the backlog item started, so the queue and the workers agree on what is under way:

```powershell
Set-Location $env:KINGSHAND_HOME
tasks-axi start "<id>"
```

**The worker id is now chosen, not discovered.** It is the `-Name` you passed, and `$r.id` gives
it back so the recording above does not change shape. There is no before-and-after listing to diff
and nothing to look up: use `$r.id` and never invent a second identifier for the same worker.

Pass `-Base $r.base` every time. It is the ref a first dispatch cut the worktree from, and the
landing gate in step 7 diffs against that same ref. **Which ref that is belongs to
`bin\Resolve-BaseRef.ps1`'s header, and nothing here restates it**; it is not always the default
branch, because a repository can declare a separate integration branch that every pull request
targets. The dispatcher confirms whatever it returns with `git rev-parse --verify` and refuses
rather than inventing a name that would resolve to nothing at the gate.

**On a re-dispatch the two can disagree, so read step 7's diff knowing that.** Re-dispatching a
ticket whose branch survived does not branch again - the branch point is whatever the earlier
dispatch chose - while the base is resolved fresh. If the repository has moved since, by declaring
an integration branch or changing its default, the recorded base names one tree and the branch was
cut from another, and step 7's `git log "$base..HEAD"` then lists commits nobody in this ticket
wrote. A widened diff on a re-dispatched ticket is that, not the worker's doing.

**Relay any warning that call prints.** Base resolution warns when it could not honour a
repository's declared integration branch, or honoured it only as a local copy nothing has
confirmed is current - and either one means the landing diff in step 7 is measured against the
wrong tree. On a `+yolo` project nothing else stops to show it, so an unrelayed warning is work
landed against a stale base. One line to the user naming the branch and what was used instead.

The dispatcher passes the brief by path, not by value. Keep it that way. Long text does now
survive the trip intact - a 3,374-character prompt arrived whole - but a path is one line, it does
not have to survive anything, and the brief on disk stays readable after the worker is gone.

**Then arm a wait for that worker, before you say anything to the user.** Nothing else in this
skill wakes you when a worker finishes. Step 5 goes quiet and Step 6 tells you what a finished
worker looks like, but only this wait's completion brings you back to look:

```powershell
Import-Module $env:KINGSHAND_HOME\bin\Herdr.psm1 -Force
$w = Wait-HerdrAgentProgress -Name "<worker id>" -TimeoutMs 2700000
if ($w.settled) { "WAKE <worker id> state=$($w.state) awaitingInput=$($w.awaitingInput) readable=$($w.signalReadable) box='$($w.promptBox)' last: $($w.lastActivity)" }
elseif ($w.stalled) { "STALLED <worker id> $($w.quietMinutes)m with no movement - box='$($w.promptBox)' last seen: $($w.lastActivity)" }
else { "NOT SETTLED <worker id> reason=$($w.reason) readable=$($w.signalReadable) box='$($w.promptBox)'" }
```

**Print every field you will need, because the printed line is all that survives.** The wait runs as
a background job and its result object dies with the job - what reaches you is stdout and nothing
else. `readable` is on both lines for that reason: a worker whose pane is too narrow to render is
unreadable for every sample, so no stall is ever claimed and the watch ends at `reason=timeout`,
which without that field is indistinguishable from a healthy worker that simply took longer than the
watch.

**Use a guarded wake - `Wait-HerdrAgentProgress` here, or `Wait-HerdrAgentSettled` where only
completion matters - and never `Wait-HerdrAgent` directly.** The raw
wait returns on herdr's own classification, and that classification is wrong in both directions:
a worker sitting on an unanswered menu was measured reporting `idle`, then `done` minutes later
while a genuinely finished worker reported `idle`. Since the raw wait matches `idle`, `done` or
`blocked`, it wakes you claiming completion for a worker that is waiting on a person. Both guarded
wakes re-read that worker's live screen before they answer, so `awaitingInput` is the screen and
not herdr's word for it, and `settled`, `state` and `awaitingInput` mean the same thing in either.

**`Wait-HerdrAgentProgress` also watches whether the work is advancing, which is a different
question from whether the worker is alive.** Liveness answered both of last week's failures
wrongly: a worker that handed its work to a background pipeline and returned to its prompt read
`done` within seconds, so the wait fired on a completion that had not happened, and the same night
a worker whose work was genuinely finished read `working` because stray text sat in its input box.
The signal it watches instead is the worker's own screen with the elapsed timer and token counter
normalised out - which needs no knowledge of what the worker was sent to do, and still catches a
review gate parked on one step, because a gate prints its own step transitions onto that screen.

**That fixes the second failure and not the first, so read the wake rather than trusting it.** A
worker that stops advancing is now reported, whatever state word it carries. A worker that has
genuinely stopped and one that has handed its work away and gone quiet look identical to anything
watching from outside, and no wait can tell them apart - so this one carries the worker's final
screen out with the wake instead of pretending to. **`state=done` is a state word, not a delivery.**
Read `last:` before you report anything as finished, and where it does not show the work actually
done, read the screen with `Read-HerdrAgent` and check `report.md` on disk. Step 6 is where that
check belongs and it is not optional.

This is an event, not a poll. Both wakes block inside herdr until the worker stops,
and return the moment it does. Nothing here sleeps in a loop and nothing re-reads state on a
timer; if you find yourself writing a `while` loop around `Get-HerdrAgent`, you have rebuilt the
thing this replaced. The progress wake samples the screen once per minute between those blocks,
because "nothing happened" is not an event anything can push at you.

- Run it as a **harness-tracked background job**, never with `&` and never as a detached process.
  Its completion is what wakes you; an untracked process wakes nothing and you will not notice it
  finish any more than you noticed the worker.
- Arm **one wait per dispatched worker**. Three workers means three waits, each with its own id.
- `blocked` is a wake reason, not a working state. A worker that goes `blocked` is sitting on an
  interactive prompt it cannot get past on its own, and it needs the user - surface it immediately
  and load `rally`. This is the failure that cost five hours of silence, and catching it is the
  main thing herdr bought. `awaitingInput` being `$true` says the same thing off the worker's own
  screen, and it wins over whatever `state` says.
- **`stalled` is a wake reason too, and it is not a completion.** It means nothing on that worker's
  screen has changed for `$w.quietMinutes` minutes against a threshold of twenty, which is long
  enough that a slow step is not it - a review pass on kingshand has legitimately taken 38 minutes
  while printing its progress the whole way. Tell the user what the work has stopped on, how long it
  has been there, and what it was last seen doing - `$w.lastActivity` carries that - then load
  `rally`, which owns what happens next. **Do not act on a stall on your own**: a wrong automatic
  action on a stalled worker is worse than a late human one, and nothing in the wait recovers
  anything by design. Raise the threshold with `-StallMinutes` for work that is genuinely quiet for
  longer; never lower it under fifteen, where slow steps start reporting as stalls and a false alarm
  reaching the King costs more than a silent one.
- **`$w.signalReadable` being `$false` means the watch was blind, not that the worker is fine.** The
  screen could not be read - usually a pane too narrow to render, the same defect that blinds the
  blocked-worker guard - so no stall can be claimed either way. Check it with
  `Test-HerdrAgentReadable` and say plainly that you cannot see the worker rather than reporting it
  healthy.
- **`$w.promptBox` with anything in it is not the worker's output and not a question for you.** It is
  text sitting in that worker's input box that nothing here sent, and a bare Enter would submit it as
  though the Hand had written it. **Never submit it and never clear it** - quote it, say which worker
  it was on, and load `rally`, which owns what happens next.
- **`reason` of `gone` means herdr has no such worker any more.** That is not a timeout and not a
  stall: the process is not there. It is confirmed by a second read and by the server still
  answering, so neither one transient error nor a server that is down produces it. Load `rally` and
  reconcile before anything else, and never remove its worktree first.
- **`reason` of `wait-failed` is the watch failing, not the worker.** Either herdr kept answering
  instantly instead of blocking for its slice, or the server stopped answering at all, so the wait
  gave up rather than spinning silently or claiming the worker had vanished. The worker is probably
  still alive and now unwatched: check the server with `Test-HerdrServer`, re-arm the wait, and say
  in one line that you lost sight of it rather than reporting it healthy.
- **Never arm the wait immediately after submitting a prompt without accounting for stale state.**
  A worker reads `idle` for a moment after its prompt is submitted, so a wait armed on `idle`
  alone can return instantly and report a completion that never happened. The dispatcher hands
  back a worker that has already been given its brief; if you submit anything further yourself,
  wait for `working` first.
- If the wait times out without the worker finishing, re-arm it. A timeout says nothing about the
  worker; assuming it is fine is how the silence starts again. That is what `settled` being
  `$false` means - not settled is the absence of an outcome, never an outcome of its own.
- **Never promise to report back without arming this first.** Saying "I will report when they are
  done" with no armed wait is exactly the defect this exists to prevent - three workers reached
  their reports and nothing came back to read them. If for any reason the wait cannot be armed,
  tell the user plainly that they will need to ask.

Tell the user one line per worker that dispatch happened, then stop talking.

## Step 5 - Quiet, and status on request

Between dispatch and completion, say nothing unless a worker is blocked, a worker has stopped
advancing, something needs a decision only the user can make, or the user asks.

**Quiet means no narration, not no monitoring.** The Step 4 wait stays armed the whole time and
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

**No state is proof that a worker finished.** herdr's classification was measured on this machine
calling a worker sitting on an unanswered menu `idle`, and calling that same still-blocked worker
`done` minutes later while a genuinely finished worker read `idle`. A state read as completion is
how a worker waiting on a person gets told it is done, torn down, and reported as delivered.

**A worker is finished when all three of these hold, and never on fewer:**

1. the guarded wake from Step 4 came back settled - `$w.settled` is `$true`;
2. it is not awaiting input - `$w.awaitingInput` is `$false`, which is read off the worker's live
   screen rather than taken from herdr's word for it;
3. `$env:KINGSHAND_HOME\data\<id>\report.md` exists.

The third is kingshand's own evidence and it is the one that carries the weight. Every brief
requires the worker to write that file before it finishes, and every brief forbids it from opening
an interactive question, so a worker that reached the end of its brief left a report behind. The
first two only say the worker stopped.

Re-read both before declaring anything, because the wake may be minutes old:

```powershell
Import-Module $env:KINGSHAND_HOME\bin\Herdr.psm1 -Force
Get-HerdrAgentState -Name "<worker id>"    # `blocked` when the screen shows a prompt, whatever herdr says
Test-Path "$env:KINGSHAND_HOME\data\<id>\report.md"
```

**A settled worker with no report is suspicious, not finished.** Do not advance it, do not tear it
down, and do not summarise it as complete. Read its screen, say plainly to the user that the one
instruction you can check the worker against was not followed, and treat the rest of what it
claims with the same suspicion.

**`blocked` is not finished, and it reaches the user immediately.** It means the worker is sitting
on an interactive prompt it cannot get past, which its brief forbade it from opening. Do not run
this step against it, and **never answer that prompt blindly** - the choice on it is the user's,
so tell them what the worker is asking and what the options are, and get their answer first -
surface it to the user now and load `rally`.

**`idle` alone is not a completion signal, and neither is `done`.** Claude Code returns to its
prompt box when a turn ends, so a worker that has said everything it is going to say reads `idle`
- exactly like a worker that has just started and been given nothing, and exactly like one holding
a menu open that herdr failed to classify. Read the three facts above, never the word on its own.

**A worker parked on a decision passes all three and is not finished either.** Its turn ended
cleanly, so it has settled; nothing is drawn on its screen, so it is not awaiting input; and its
brief made it write the file, so the report exists. What separates it from a delivery is not in
that file at all - **it is `waiting_on` on the worker's own record:**

```powershell
$w = Get-CrewWorker -State $s -WorkerId "<id>"
$w.waiting_on          # the key of the hold carrying its decision, or $null
```

**The field is set or it is not, and there is no third value. Null means this worker has never
parked; set means it parked, and the field names the hold carrying what it parked on.**
`Import-CrewState` gives every record the field whether or not it was saved with one, so absent
and null are one case rather than two. **It is written on the turn the worker parks and never
cleared**, so it keeps naming that hold for the rest of the worker's life - a worker that was
answered and carried on still carries the key of the decision it was answered on.

**Whether that decision is still outstanding is not this field's to say, and nothing here restates
it.** The hold answers it, and the hold is the source of truth: open and the worker is waiting,
closed and it is answered, with the `answered:` or `declined:` note `decree` requires on the close
saying what was decided. Two sources, each owning its own half. `decree` owns the hold's lifecycle
and `petition` owns who may answer it:

```powershell
Set-Location $env:KINGSHAND_HOME
tasks-axi show <the key the pointer names> --full
```

**So the order is fixed. After the three facts, read the pointer - and unless it names a hold that
is still open, read `$env:KINGSHAND_HOME\data\<id>\report.md` before you may treat that worker as
a delivery:**

```powershell
Get-Content "$env:KINGSHAND_HOME\data\<id>\report.md" -Raw
```

**A null says this worker has never parked, and nothing more.** It does not say the report names
no decision - the field is only ever written by a Hand who read that report, so on a first park it
stays null until somebody looks. Skip that read and a parked worker passes the three facts, takes
`gating`, and is landed and torn down with its question answered nowhere.

**A pointer naming a closed hold does not excuse the read either.** It says the decision it names
was answered; it does not say this wake is a delivery, because a steered worker goes back to work
and can reach a second decision its brief does not settle just as easily as the first. The report
is what tells those apart. **The one wake that needs no report read is a pointer naming a hold
still open** - that worker is waiting rather than delivering, and the rest of this step is about
it.

**This replaced a heading the Hand used to read out of `report.md`, and the replacement was
deliberate.** The route's state was written as prose over a free-text file, so every review round
turned up one more shape nobody had listed - an empty section, a worker parked twice, an answer
with no record - and the rules for reading it ended up longer than the route itself. A field has no
shapes. The report still carries the question and the reasoning, which is what prose is good for;
it stopped being where the system reads whether.

**Where the report names a decision the worker's brief did not settle and no hold of this worker's
covers it, that is `decree`'s trigger and nobody has pulled it yet.** A first park reaches it with
a null pointer and a second with a pointer naming the closed hold of the decision before it; both
are the same trigger, and both end with the pointer naming the new hold.

**Look for a hold already open under this work's id before registering anything.** Registering the
hold and writing the pointer are two commands and a session can end between them, so a null
pointer over a report naming a decision has two causes: nobody registered it, or somebody did and
the pass ended before the pointer went in. `decree` prefixes every key with the work id precisely
so the queue answers that, and the queue is the only place it is answered - do not go back to the
report for the key:

```powershell
Set-Location $env:KINGSHAND_HOME
tasks-axi ready --include-held
```

**Where an open `--kind captain` hold for this work is already there, re-register under that same
key rather than filing a second one.** `add` and `hold` are idempotent, so the replay changes
nothing and the pointer ends up naming the hold that already exists. File a second and the King is
asked the same question twice, while the first is orphaned with no pointer naming it and nothing
that will ever close it.

Register the decision there, and record the key it was registered under in the same turn:

```powershell
Set-CrewWaitingOn -State $s -WorkerId "<id>" -HoldKey "<the key decree registered it under>"
Save-CrewState -State $s -Path $env:KINGSHAND_HOME\state\crew.json
```

**That read is a person reading a question rather than a check parsing a file, and it is the same
read the fixed order above requires - not a second one.** It is not counted, and it is not "once
per worker": a worker steered past one decision can reach another, so the rule is the condition the
order already states, which is every wake where the pointer does not name a hold still open. From
there the pointer and its hold carry the state between them, so a restart, a compaction or a
session that dispatched nothing reads two recorded values instead of re-deriving one from prose.

**A worker that carried on past a decision its brief did not settle, with no hold ever registered
for it, answered its own question - and its brief forbids that outright.** Load `rally`, and read
everything else it claims with the same suspicion a missing report earns. Do not register that
answer afterwards to make the record tidy: filing it durably asserts that somebody with the
authority gave it.

**A worker waiting on an open hold is idle rather than hung**, and costs nothing where it is - the
review-gate run it left parked keeps the branch and every fix commit already made. **Do not set
`gating`, do not close the backlog item, and above all do not tear it down.** Teardown ends the
process holding that parked run, and the answer then has nowhere to go.

**Load `petition` before answering it - whatever the posture, and whether or not the King is at
the machine.** It owns who may decide this and by what test, including the test that applies when
he is away, and it is the only place that test is stated.

**`decree` owns the hold from its reason to its closing note, and nothing here restates any of
it.** Read the hold under the key the pointer names, and take it as that skill describes: what an
open hold with no note means and how its reason tells the two causes apart, what the closing note
has to carry, and that the dependent work is blocked before the hold closes. Both branches are
registered there - an answer he still owes and an answer you gave in his stead - because neither
survives this session in chat or in a return digest.

**Where you are answering it, the block and the closing note go in before the send, not after.**
An interruption is not a rare case here - the session can end at any point - and the order decides
what a later session finds. Close first and it finds a closed hold the worker has not been told
about, which sends the answer on once. Send first and it finds an open hold the worker has already
acted on, which puts the same question to the King a second time. `decree` owns the sequence
itself, block before close.

With the answer in hand and recorded, send it to the worker as one prompt, read the screen back,
and wait for the worker to actually pick the answer up:

```powershell
Import-Module $env:KINGSHAND_HOME\bin\Herdr.psm1 -Force
Send-HerdrPrompt -Name "<worker id>" -Text "<the decision, and the reason for it>"
Read-HerdrAgent -Name "<worker id>" -Lines 20
Wait-HerdrAgent -Name "<worker id>" -Until 'working' -TimeoutMs 120000
```

`rally` owns the steer itself and says why an unchecked one is not a steer at all. Three things
about this one in particular. The send is refused outright when that worker's input box already
holds text this session did not write - the wake reported `promptBox`, so you already know, and
`rally` owns what to do about it rather than `-AllowNonEmptyBox` being reached for here. And **the
worker is working again the moment the answer lands, so re-arm the Step 4 wait** - the wait that
woke you is spent, and a worker resumed with nothing watching it is the silence this whole layer
exists to prevent.

**Arm it after that `-Until 'working'` line and never straight after the send.** Step 4's
`Never arm the wait immediately after submitting a prompt without accounting for stale state`
bullet owns why, and this steer is the case it names: the worker still reads `idle` for a moment,
so a wait armed on the send comes back at once claiming a completion over a worker that has not
started on the answer yet. Naming `working` is the one wait that is allowed to be the raw one,
because it is asking for a state the worker has to reach rather than trusting herdr's word for one
it has stopped in. Where
`working` never arrives inside those two minutes, the wait came back `$null` and that is two
things at once: the answer never landed, or herdr stopped answering while the worker took it
anyway. **Do not report either one - the null does not say which.** Read the screen and check what
the worker is actually doing, and load `rally` where the screen cannot tell you, rather than arming
a wait over a worker that may never have taken the answer.

**The pointer is not cleared here, or anywhere, ever - there is no verb for it.** It named this
decision before the answer and it names it afterwards; the hold's own close is what records that
the answer was given, and that record outlives the worker. Clearing it would put two opposite
meanings on one null - a worker that never parked, and a worker that parked, was answered and
carried on - and those need opposite handling, so a route that cannot tell them apart either loses
a question nobody registered or refuses finished work and asks the King the same thing twice.

**A closed hold does not by itself say the worker was told.** The close goes in before the send, so
an interruption between the two leaves an answered decision the worker never heard - and the
report is what tells that from a steer that landed. Where it does not show the worker acting on
the decision, take the worker's condition from `rally` and send that note's answer once. Do not
decide it again: it is answered, and a worker told to decide the same thing twice does the work
twice.

**This pass ends at that re-armed wait, and nothing below it runs on this one.** The stage stays
exactly where it is - waiting was never a stage, so there is nothing to put back - you go quiet as
Step 5 describes, and the next wake re-enters this step from the top against the state as it is
then. Reading on from here would carry facts gathered before the answer was sent into a `gating`
the worker has not earned - it started working again seconds ago - and on a `+yolo` project Step 7
would then diff and land a worktree that is still being written to.

With all three confirmed and no hold of this worker's still open, **set its stage to `gating`** -
the implementation is done and the work is waiting on the landing gate at Step 7. Say so in chat as
an update: what finished, that the landing gate is now theirs, and the one next action. Keep it short
because there is little to say, not because a line count says so:

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

**A brief that asked for browser checks needs a report that answers them.** Where you wrote a
`## Browser checks` section into this brief, the report has to carry a `## Browser verification`
block answering every check id that section listed. A report without one is the same failure as a
missing report and gets the same treatment: say it to the user and do not advance the work on the
worker's word. **Read the verdict on that block and relay it as a finding.** `failed` means the
change is broken in a browser and `not verified` means part of it was never exercised - neither is
a completion notice, both reach the user in this step whatever the project's posture, and only
`verified` across every declared check is a browser step that passed. The whole capability exists
so a change nobody exercised cannot read like one that was, and this is where that stops being
true if nobody reads it.

**Fold back what the standing criteria missed.** The worker's self-check block and the gate's
round-one findings are two readings of the same change, so compare them. **That comparison needs a
gate, and most projects have none.** On a `local-only` or `direct-PR` project - including a
`no-mistakes-prod-only` project whose task resolved to `direct-PR` - there is no gate and no round
to compare against, so this loop does not fire, and a report with no rounds in it is the record
that brief asked for rather than one to query. Where this task did run the review gate, both
readings are in `report.md`: the `Repeated findings` section of the brief made the worker record
every round there as it landed, and the first pass as `round 1: no findings` where it raised none,
so a report carrying a self-check block and no rounds at all is one to ask about rather than one
with nothing to fold back. Read the self-check block either way, because a criterion the worker
could not check - one it could not tell whether this change met, for want of the line saying how -
is the same wording problem arriving from the other side. **Most `n/a`s are not that.** A criterion
whose subject this change does not touch is answered correctly by `n/a` - `- Every new component
has a Storybook story` against a task that fixes a CSS bug and adds no component - and so is one
this brief set aside. Both are the right answer, and neither is reworded nor recorded: most useful
criteria are conditional, so rewording every line a change happens not to touch would churn the
file this loop exists to build, on every unrelated dispatch. A criterion workers keep recording
`n/a` against for want of anything to check is the retire branch below, once it has happened more
than once - not a wording problem the first time. A section whose only line is `- Nothing standing
for this project yet.` is neither: there was nothing to check, the `n/a` against it is the only
answer available, and it is not a criterion to reword or a reason to create the file. A finding
that matches a criterion the worker recorded `pass` or `fixed` means that criterion did not end
the defect: written too vaguely to check, or skipped, or worked and still leaving the same class
of defect behind it. Either way the wording is what needs fixing, so rewrite that line in place
in the same turn you read the report, in the file's one `-` bullet form, and say what you changed.
`fixed` is in that branch deliberately - a criterion the worker acted on and the gate then caught
anyway is the clearest evidence there is that the line does not say enough. A criterion this brief
set aside is not that: the `n/a` is the correct answer and there is nothing to reword. A finding
that matches no criterion at all is a candidate line for
`$env:KINGSHAND_HOME\data\done-<project>.md`, and one test decides it: would it apply to the next
unrelated change to this project? A one-off defect in one function is a finding and belongs in the
report or a backlog item, however real it was - the file is pasted into every brief for the
project, so a line that does not generalise is one every future worker reads, works through and
records `n/a` against forever. Where it passes that test, add it in the same turn you read the
report, in that file's one form of a `-` bullet naming how it is checked, editing the file in place
where it already exists or writing it with `Write-DataFile -Project "<project>"` from
`bin\Index.psm1` where it does not - name the project, or the entry lands in kingshand's own
`data\index.md` and the next session reading `data\index\<project>.md` finds no trace of it. Where
the file holds only `- Nothing standing for this project yet.`, the first real criterion replaces
that line rather than joining it: the placeholder says there are no criteria, so a file holding
both says two contradictory things and leaves every future worker working a line it can only
record `n/a` against. Retire a line the same way you add one, in the turn the evidence arrives:
when the code it guarded is gone, when it has stopped discriminating because the practice is now
enforced by a test or a linter, or when workers keep recording it `n/a` on unrelated dispatches
for want of anything to check, delete it and say so. Where that was the file's last line, leave
`- Nothing standing for this project yet.` in its place rather than an empty file, so the next
brief pastes a decision somebody made instead of a blank section. This is the only thing that
makes the list grow from evidence instead of from invention, and a criterion learned at a gate
round and left sitting in a report is one somebody pays for again a dispatch later.

**A round tally in a report is a finding, not a completion notice.** Where the worker reports three
rounds of findings in one component or three failed attempts at one bug, escalate it with the tally
and the design question in the worker's own terms: what kept producing findings there, and what the
alternative was. It reaches the user immediately, like any other finding. Where the answer is a
design change nobody has made, file it as a backlog item and let `decree` own the decision from
there. It is never a reason to have capped the fixing.

**Before you treat this worker's work as complete, load `decree`.** A `report.md`
that names a decision the brief did not settle is exactly its trigger, and the Done-means block
above required the worker to write any such question there rather than ask. That skill owns
everything that follows: the stable key, the durable backlog item, and the declaration that says
either every unresolved decision from this report is registered or this report contained none.
A worker finishing is not an answer, and nothing here closes a decision.

**Record the outcome on the backlog item**, pointing at the report rather than restating it, and
**index the report in the same breath** - you have just read it, so this is the one moment its one
line can be written honestly, and a report no index lists is a finding the next brief will not
find:

```powershell
Set-Location $env:KINGSHAND_HOME
tasks-axi update "<id>" --report "data\<id>\report.md"

Import-Module $env:KINGSHAND_HOME\bin\Index.psm1 -Force
Add-IndexEntry -Project "<project>" -Path "data\<id>\report.md" -Summary "<one line of what it found>"
```

A report is indexed whenever it is first read, not only here. A worker that fails or goes
unresponsive never reaches this step - the Hand loads `rally` instead - and that path indexes it
too, so a torn-down worker's findings are never left listed nowhere.

Do not mark it done here. The item closes at Step 8 or Step 8a, when the work has actually landed.

Read the worker's own final message before summarising. If it reported that it could not build
or could not run the gate, say that plainly. Never translate a failure into a success - and set
the stage to `failed` rather than `gating`, because that work is not waiting on a gate and Step
8a must not take it.

herdr's agent record does **not** carry the final message - it holds a state, a pane, a cwd and
the window title, and nothing else. Read the worker's screen, which is the fallback when
`report.md` is missing or says less than the worker did:

```powershell
Import-Module $env:KINGSHAND_HOME\bin\Herdr.psm1 -Force
Read-HerdrAgent -Name "<worker id>" -Lines 60
```

That returns the worker's recent rendered output and is enough almost every time.

**There is no transcript to fall back to when it is not.** Workers inherit
`CLAUDE_CODE_CHILD_SESSION` from the Hand's own session, so they run with transcript saving off
and usually write nothing under `~\.claude\projects\` at all. Do not go looking for a `.jsonl`
that will not be there and do not report an empty search as an empty report. If the final message
has scrolled out of reach, ask for more lines while the pane is still alive - once the worker is
torn down at Step 8b, that output is gone for good and `report.md` is all that is left. That is
the whole reason the brief demands it.

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
- Never land a browser verdict that is not `verified`. A brief that asked for browser checks and
  came back `failed`, `not verified` or with no `## Browser verification` block at all goes to the
  user, on any posture.
- Never land work that materially expands the product or engineering contract beyond what the
  brief accepted. That goes back to the user.
- Destructive, irreversible and security-sensitive actions always go to the user.
- Never merge on the forge. `direct-PR` and `no-mistakes` work ends at a pull request the user
  merges.
- Never push a project that is not registered with a push-capable posture.
- **Never land a worker whose pointer names a hold that is still open.** It is mid-run rather than
  delivered, whatever its branch shows, and Step 6 owns what to do with it. **Read the pointer, and
  where it names a key read that hold**: the field says which decision, and the hold says whether
  it is still owed. A closed one is answered rather than outstanding, and it is not on its own a
  reason to refuse a landing. **Nothing here is a delivery on the pointer alone** - a pointer that
  names nothing, and one naming a hold already closed, are both only as current as the last read of
  that worker's report, so the worker goes through Step 6's read first. Step 0 sends
  "land / merge / ship a worker" straight to this step, so a worker arriving that way has had no
  such read at all. **Do not try to work out whether one has already happened.** Neither the stage
  nor anything you remember can tell you - Step 6's parked path runs to completion and deliberately
  leaves the stage where it was, so `dispatched` and `implementing` are what a worker steered an
  hour ago still reads. The read is cheap and the mistake it prevents cannot be taken back.

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

**Use `$w.base`, never the local default branch.** It is the ref recorded when this worker was
dispatched, which is usually a remote-tracking one and is not always the default branch. When a
local branch is behind - which is normal - diffing against it folds every upstream commit in that
gap into what looks like the worker's work. In the first real run this made a 1-file change appear
as 6 files across 3 commits. On a re-dispatched ticket the recorded base can itself predate a
repository change, as Step 4 says - so a diff that carries commits this worker never made is a bad
base, not a finding about the worker.

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
none of the workers' business. A hit outside the worker's own commits is a bad diff base, not a
violation.

Everything above runs in every case. What the posture changes is only what happens next.

When `$proj.yolo -eq 'off'`, **render the evidence and wait**. Render it - do not summarise a diff
into chat and ask for a yes. This is a decision, and hard rule 5 says every decision renders,
however short the summary looks:

```powershell
$sections = @(
  @{ heading = 'What changed'; items = @(
      @{ id='F-001'; text='<file> - <what changed and why it matters>'; detail='<+n/-n>'; badges=@(); flag=$false }
  )}
  @{ heading = 'Checks'; items = @(
      @{ id='C-001'; text='<check> - <result>'; detail='<evidence>'; badges=@(); flag=$false }
  )}
  @{ heading = 'Open questions'; items = @(
      @{ id='Q-001'; text='<anything report.md left unresolved>'; detail=''; badges=@(); flag=$true }
  )}
)
& $env:KINGSHAND_HOME\bin\Render-Review.ps1 -Title "Land: <id>" -Subtitle "<repo> - <mode>" `
    -Sections $sections -OutputPath $env:KINGSHAND_HOME\data\<id>\review.html

$env:LAVISH_AXI_PORT = '4388'
lavish-axi $env:KINGSHAND_HOME\data\<id>\review.html
lavish-axi poll $env:KINGSHAND_HOME\data\<id>\review.html
```

The parameter is `-OutputPath`. An earlier draft of this block abbreviated it, which would have
thrown the first time anyone reached the landing gate - a documented command nothing exercises. A
test pins the spelling for that reason.

Sections carry what they need to judge it: the changed files, the diff, the check results, the base
ref the diff was taken against, and anything the worker's `report.md` left unresolved. Then say one
line in chat naming what is waiting and stop - the surface holds the detail, chat holds the pointer.

`lavish-axi poll` long-polls and stays silent until they answer. Keep it in the foreground, or run
it as a harness-tracked background job whose completion wakes you. Never leave it detached with
nothing to wake on - that is the same silence this whole layer exists to prevent.

When `$proj.yolo -eq 'on'`, the waiting is skipped and nothing else is: the evidence is
still gathered and still checked, and a red check, an attribution hit, a scope expansion or
anything destructive still goes to the user - rendered, because each of those is a decision.

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
ends at a pull request that the user merges on the forge; `muster` never merges there. For those
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

**Muster itself never pushes.** Pushing is the user's action or the worker's, never yours. A
*worker* pushes only when its project's mode is push-capable - `direct-PR`, `no-mistakes`, or a
`no-mistakes-prod-only` project resolved to one of those - because registering that mode is the
consent. Never for `local-only`, whose brief forbids it outright, and never for a project that
is not registered at all.

## Step 8a - Close out push-capable work

Only for `direct-PR` and `no-mistakes` (including `no-mistakes-prod-only` resolved to either).
There is nothing to merge here - the pull request is the deliverable, and the user merges it.

**Load `decree` before closing this work out.** Close-out advances a stage and
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
advanced. That is the direct-entry path working as designed, not a reason to refuse. **It does
mean the one check Step 6 owns has not run, so run it here: a worker whose pointer names a hold
that is still open is mid-run, and so is one whose report names a decision no hold covers.** Leave
the stage where it is, take it to Step 6, and close nothing out - a decision still owed is not a delivery,
however good the branch looks. Otherwise set the stage to `gating` and carry on with the
rest of this step:

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

With both confirmed, the work is finished as far as this skill is concerned, but it is not merged,
so it moves from `gating` to `ready` rather than to `landed`. `ready` here is the close-out mark:
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

**A worker that reads `idle` is not a dead worker.** It is a live Claude Code process sitting at
its prompt in a live pane, and it holds an open handle on the worktree directory. Removing the
worktree while the worker lives fails on Windows with "being used by another process", leaving a
half-deleted directory and a stale git worktree registration.

**When to tear down depends on the mode**, because "the work is safe" means different things:

- `local-only` - after the merge in Step 8. The commits are on the default branch.
- `direct-PR`, `no-mistakes`, and `no-mistakes-prod-only` resolved to either - after the push is
  confirmed in Step 8a, at stage `ready`. The branch is on the remote, so removing the local
  worktree cannot lose the work. Do not wait for the pull request to be merged.

**Work that is neither landed nor pushed is never torn down.** If the merge did not happen and
the branch is not on the remote, the worktree is the only copy of the work and removing it
destroys it. Confirm one or the other first - teardown removes the worktree, and nothing puts it
back.

**A worker whose pointer names a hold that is still open is never torn down either, and a confirmed
push does not release that.** Teardown ends the live process, and that process is what the answer is
coming back to: kill it and the decision it is parked on can never be applied, while the gate run it
left parked keeps its fix commits somewhere nobody will look again. Read the field before you stop
anything, and where it names a key read that hold - still open, take the worker to Step 6 instead:

```powershell
$key = (Get-CrewWorker -State $s -WorkerId "<id>").waiting_on
if ($key) { Set-Location $env:KINGSHAND_HOME; tasks-axi show $key --full }
```

**Read those two and nothing else.** This is the one place where a wrong read cannot be taken
back, and neither of them can be malformed - which is exactly why the route stopped keeping this
state in the worker's own prose. Do not go looking through `report.md` for a heading, a marker or
a question that reads as unanswered: that read is Step 6's, and it is what did or did not put a
key in this field. This is the same shape as the floor above - both refuse an irreversible cleanup
over work that is not finished.

**`report.md` survives teardown, and must never be deleted as part of cleanup.** It lives at
`$env:KINGSHAND_HOME\data\<id>\report.md`, beside the brief and outside the worktree, so teardown
cannot reach it and nothing here should. Outliving the session is the entire reason the worker
was made to write it: the worktree, the pane and everything the worker said all go, and the
findings stay. Leave `data\<id>\` alone.

Teardown is three things in this order, and the order is the safety: stop the worker, discard its
pane, remove its worktree.

```powershell
Import-Module $env:KINGSHAND_HOME\bin\Herdr.psm1 -Force
$stop = Stop-HerdrAgent -Name "<worker id>"
if (-not $stop.stopped) { "STOP FAILED <worker id>" }     # do not touch the worktree
Remove-HerdrPane -PaneId $stop.paneId
```

**`Stop-HerdrAgent` exits the worker with `/exit`, and that is not a formality.** A worker killed
with `Stop-Process` never sends its terminal-mode reset, which leaves its pane echoing every later
keystroke as literal junk and unusable for anything, permanently. The worktree is never harmed by
either route - it is only a directory - but a killed worker costs you the pane and can leave a
handle open on the directory you are about to remove. Never reach for the pid.

`$stop.stopped` being false means the worker did not exit. Stop there, report it, and leave the
worktree alone: the process is still live and still holding the directory.

Then remove the worktree, which is kingshand's own now - the dispatcher created it, so the
dispatcher's caller cleans it up:

```powershell
git -C "<repo path>" worktree remove "<worktree path>"
git -C "<repo path>" worktree prune
git -C "<repo path>" branch -D "<branch>"      # only when discarding unlanded work
```

If `worktree remove` refuses because the tree is dirty, that is unlanded work you were about to
destroy - stop and read it rather than reaching for `--force`. If it refuses because the directory
is in use, the worker is not actually stopped. Do not force-delete the directory underneath git:
that leaves the worktree registered and the next dispatch with the same name will fail.

## Step 9 - Report

One or two lines: what landed or is waiting as a pull request, what is still running, anything
needing the user next.
Do not reprint the diff. The surface was the report.
