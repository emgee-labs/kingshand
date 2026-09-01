---
name: chronicle
description: Sweep the current session for uncaptured durable knowledge, file it to disk, and curate kingshand's tiered, decaying startup memory before a context reset. Use when the user invokes /chronicle (e.g. "/chronicle", "chronicle", "chronicle what you've learned", "save what you have learned", "write down what you learned"), before a session reset or context compaction, or periodically to keep operational memory current.
tools: PowerShell, Read, Write, Edit, Glob, Grep
user-invocable: true
version: 1.0.0
---

# Chronicle

Sweep this session for durable knowledge that exists only in the conversation, then leave the next
session with a compact current operating map rather than an accumulating journal. Memory entries
are tiered and decay between passes, and stale material retires to a cold archive instead of being
deleted.

Kingshand's always-loaded memory is exactly two files, both under `$env:KINGSHAND_HOME\data\`:

- `king.md` - what the Hand has observed about how the King works and what they prefer.
- `learnings.md` - operational facts and gotchas kingshand itself has hit, dated and
  evidence-backed.

**Both are created lazily and are absent until there is something to store. Absence is meaningful,
not an error, and it is never an invitation to manufacture content or write a placeholder.** A
kingshand that has learned nothing yet has no `learnings.md`, and that is the correct state.

**`$env:KINGSHAND_HOME\instructions.md` is not a memory file and this pass never touches it.** Those
two files are what the Hand *learned*, which is why this pass is allowed to rewrite, decay and prune
them. `instructions.md` is what the King *stated*: it is read at session start, it is not measured
against the budget, and no curation decision may edit, reformat, summarise, fold, prune or archive a
line of it. The distinction is the whole safeguard - a pass that treated a stated preference as a
decaying entry would eventually delete something the King said out loud, and would do it quietly.
Where this session produced something that belongs there, name it to the King and let them write it.

This skill writes only inside the Hand's own write boundary - `$env:KINGSHAND_HOME\data\` and
`$env:KINGSHAND_HOME\state\`. It never touches a project, and hard rule 1 is not suspended for a
curation pass.

## Memory tiers and entry markers

Markers are compact trailing HTML comments. They are deliberately cheap because **marker bytes are
counted content: they are measured against the startup-memory budget exactly like prose, so the
pass's own bookkeeping is never free.** That is why the spellings below are as short as they are.

- `<!--a:YYYY-MM-DD-->` - an `aging` entry; the embedded date is its last-reinforced date.
- `<!--p:YYYY-MM-DD-->` - a `perishable` entry; the embedded date is its last-reinforced date.
- `<!--P-->` - an explicitly `pinned` entry in a file whose default tier is not `pinned`.
- `<!--g-->` - migration only: an unconfirmed legacy entry that has consumed its one grace cycle,
  carrying no date because grace is not reinforcement.

```markdown
- Windows lavish runs on port 4388; 4387 is WSL's and answers with an opaque 500. <!--a:2026-08-28-->
- Worker acme-email-sender is mid-flight on the drawer fix (until it lands; backlog: acme-email-sender). <!--p:2026-08-28-->
- Never remove the worktree of a worker holding unlanded work. <!--P-->
```

The tier names say what the pass does with an entry:

- `pinned` - no clock is ever read for it. It is exempt from decay and from budget eviction, and
  changes only through inspect-then-update when the user or reality changes it, except that an
  explicit per-item approval from the user may offload it under the flow below.
- `aging` - it must re-prove itself. An entry whose age is 30 days or more since its last-reinforced
  date is stale, and a stale entry is re-validated with its date refreshed, or archived. Never kept
  by inertia alone.
- `perishable` - it is stored expecting disposal. An entry whose age is 7 days or more since its
  last-reinforced date is stale, and its prose must name a checkable expiry condition: a backlog id,
  a worker id, a version floor, or a dated expectation. An admitted durable entry that cannot name a
  checkable expiry condition is not `perishable` and is stored as `aging`. Omission is reserved for
  non-durable material and for facts already owned elsewhere.

Marking rules:

- Tier defaults are file-scoped. Entries in `data\king.md` default to `pinned`, because
  preferences and working style do not age. Entries in `data\learnings.md` default to `aging`,
  because operational facts must re-prove themselves.
- An entry matching its file's default tier carries no marker at all. Every `aging` and `perishable`
  entry always carries its dated marker, whose letter names the tier, so a clock-carrying entry is
  never ambiguous with unmarked legacy material.
- Each memory file's header carries at most a one-line pointer naming this skill as the owner of the
  scheme, such as `<!-- memory tiers: see the chronicle skill -->`. **This skill text is the
  single owner of tier semantics, marker spellings and clocks** - deliberately policy, not
  configuration - and no memory file header may restate them. Inspect each file's header pointer
  on every pass and add or correct it.
- A pre-existing missing or hand-dropped marker is never grounds for destructive treatment. It means
  the file's default tier: an unmarked entry in `king.md` is simply pinned, while an unmarked
  entry in `learnings.md` follows the migration rule below.

Decay advances only when a pass runs, so a kingshand whose memory is chronicled less often than a
clock experiences that clock at the interval between passes, not at the clock's own.

## The required startup-memory pass

Every `/chronicle` invocation performs this complete pass, even when the session produced no new
finding.

**1. Measure before considering a write.**

```powershell
Set-Location $env:KINGSHAND_HOME
Import-Module .\bin\Memory.psm1 -Force
$before = Get-MemoryReport
$before.files | ForEach-Object { "{0}: {1} bytes, {2} est. tokens, present={3}" -f $_.name, $_.bytes, $_.tokens, $_.present }
"total {0} / budget {1}; over={2}" -f $before.total, $before.budget, $before.overBudget
```

Record the effective budget and each file's estimate. The estimate is
`ceil(UTF-8 bytes / 3)` - a conservative portable approximation, not provider-exact accounting, and
the module header owns why. If `Get-MemoryReport` raises an error on the budget setting, do not
infer a default and do not silently continue: report that concrete exception and do not call the
session reset-safe.

**2. Read every current memory file completely** - `data\king.md` and `data\learnings.md` - before
changing either. Treat an absent file as absent. Read-before-write is not optional: a rewrite
decided without the current text is an append in disguise.

**3. Build one whole-file retention plan before editing**, ordered by how likely each entry is to
inform a future session. Keep in always-loaded memory only current user preferences, safety and
authority boundaries, recurring working style, operating facts that are relevant often, and concise
pointers that are expensive to rediscover. Prefer offloading current but conditional, narrow or
project-specific material to an owner that is loaded on demand, and archive stale, superseded or
low-recurrence material to the cold tier. Retain lower-utility material only while budget remains.

**4. Reinforce and stamp.** Refresh an entry's last-reinforced date to today only when this session
actually exercised, confirmed or re-derived it. **Reinforcement requires independent evidence from
this session that you can name in the receipt. Plausibility, importance, prior knowledge and the
entry's own text are not evidence**, and any explicit statement that no confirming session evidence
exists requires the no-evidence path. For an unmarked `learnings.md` entry with no such evidence,
that path is always to append `<!--g-->` and retain it for this entire pass; never stamp or archive
it during the same invocation. Stamp each newly written entry with today's date and its tier, and
admit a new `perishable` entry only with its checkable expiry condition stated in the prose.

**5. Evaluate every dated entry against its tier clock.** Re-validate a stale `aging` entry from
current evidence and refresh its date, or archive it. Re-confirm a stale `perishable` entry against
its named condition: still open means refresh the date, while resolved, expired or no longer
checkable means archive it in this pass. Promote `perishable` to `aging` when its condition keeps
proving durable past its expected life, and retier in place when a supersession changes an entry's
lifetime. `pinned` is exempt from this step entirely.

**6. Consolidate both files as needed**, not only the one that a new finding happens to touch.
Prefer one concise current rule or authoritative pointer over duplicate prose. Archive completed
incident chronology, stale versions and paths, transient worker state, resolved alternatives, old
metrics and report-sized procedures. Merge or remove only superseded claims and duplicates whose
facts are preserved elsewhere. **Never plainly remove a unique current fact:** every such exit must
archive it with provenance in the cold tier, relocate it to a live on-demand owner, or fold it into
a consolidation that preserves the fact.

**7. When the total is still over budget after decay and consolidation, make aggressive reduction
the default**, in this order: archive every stale, superseded or low-utility entry eligible for
archival; consolidate tighter; run the offload sweep below and relocate every eligible non-pinned
conditional entry into an already-existing owner, but only after that owner actually holds it; then,
only when the convergence precondition holds, archive eligible `aging` entries oldest-reinforced
first until within budget. A proposal, a future migration or an accepted exception is never budget
relief in this pass. Eviction considers only `aging` entries that carry a last-reinforced date and
are not pending offload; a `<!--g-->` grace entry is ineligible until its grace cycle resolves, so
eviction can neither cancel a promised grace cycle nor prefer just-validated entries over
unvalidated ones. **Convergence precondition:** before evicting anything, total the eligible pool and
check that archiving all of it would reach the budget. When even that cannot, skip the eviction rung
entirely, archive nothing for budget reasons, and carry the concrete inability into the receipt,
naming the exempt pinned floor that crowds out the budget. Automatic processes never move a `pinned`
entry - not decay, not grace, not oldest-first eviction, not offload. The sole exception is
relocation to an on-demand owner after explicit, per-item approval from the user, and that entry
stays in memory until its destination is live.

**8. Measure again after the complete pass** with the same command, and finish at or below the
budget or open one concrete decision with the user before ending the pass. When the convergence
precondition skipped eviction, report the exempt pinned floor and the remaining shortfall rather
than archiving knowledge that could not close the gap anyway. Only after every safe non-pinned
archival, consolidation, offload and eligible eviction is exhausted may a remaining excess be
attributed to pinned safety, authority or genuine preference entries. In that last-resort case, file
one held backlog item that names the shortfall and each relevant pinned entry, with exactly these
options: raise the effective budget in `config\startup-memory-budget`, or approve offloading or
trimming a named pinned entry. **Never end a pass over budget as an accepted exception, and never
describe the session as reset-safe while the total is over budget or an exception is unresolved.**

A net increase is allowed only for a genuinely new current fact with no stronger owner, and only
after consolidating enough lower-priority material to stay within budget.

## The cold tier: data\memory-archive.md

**Stale never means deleted.** Pruning an entry from a memory file always means moving it to
`$env:KINGSHAND_HOME\data\memory-archive.md`, kingshand's append-only cold tier. It is never loaded at
session start and never counted by `Get-MemoryReport`, so archive provenance stays verbose rather
than compact.

Each archived entry keeps its provenance under a dated pass heading: source file, tier,
last-reinforced date, and the reason it left.

**A correction drained from the inbox keeps its own provenance shape**, because it has no source
memory file, no tier and no last-reinforced date to record: source `corrections.md`, the date
recorded in the entry itself, and what superseded it. Inventing a tier or a reinforced date for it
would put a value in the archive that nothing ever measured.

```markdown
## 2026-08-28 chronicle
- (from learnings.md, tier: perishable, reinforced: 2026-07-14) Worker acme-low-med-email is
  mid-flight on the severity split... [archived: unreinforced 45d]
- (from corrections.md, recorded: 2026-08-14) Summarised a landing decision into chat instead of
  rendering it. [archived: superseded by the 2026-08-27 correction]
```

Reasons include `unreinforced <N>d`, `budget oldest-first`, and `legacy-unvalidated`. Archiving is a
move, not a removal, and recovery is a search plus a copy back with no tooling. Truncating a grown
archive is the user's decision, not a mechanism this pass performs on its own.

## Over-budget offload to on-demand owners

Decay handles staleness over time; offload handles scope. Some knowledge is current and durable but
relevant only in a nameable context, and therefore wrong to pay for in every session. For this
sweep's evaluation only, each entry has exactly three outcomes, decided in this fixed order:

1. **Archive** - the time outcome, always evaluated first. Staleness is judged before scope, and
   offload never moves a stale fact anywhere.
2. **Offload** - the scope outcome, asked only of current durable entries: is this needed in nearly
   every session, or only in a nameable context?
3. **Keep** - the default for this sweep: current, durable, and either broadly relevant or
   safety-relevant even in sessions that never name the topic.

The sweep runs only when the pass is still over budget after decay archiving and consolidation, so
routine passes never move entries speculatively. Every test must hold for a candidate:

- **Durable** - not `perishable`, not stale, expected to remain true for months.
- **Eligible by authority** - only a non-pinned, dated `aging` entry may be relocated without asking.
  A `pinned` entry may only be proposed for explicit, per-item approval, and can never be archived or
  offloaded automatically for budget relief.
- **Conditional** - a one-line nameable trigger exists, and a session that never touches that trigger
  runs no risk from omitting the fact.
- **Fat enough to matter** - roughly 50 estimated tokens or more, handled largest first, because
  consolidation already handles smaller entries.
- **Not already preserved by a stronger owner** - which ordinary consolidation handles, not offload.

### Destinations

`CLAUDE.md`'s Knowledge routing section is the source of truth for where a fact belongs. Do not
re-derive or duplicate that mapping here. Two consequences bind this pass in particular:

- **Knowledge useful to every contributor to one project** belongs in that project's own memory file,
  and only a worker may write it, through that project's delivery path under `muster`. The Hand
  never edits a project, so this destination is never live in the same pass that proposes it.
- **Knowledge general to kingshand itself** belongs in kingshand's tracked material under
  `statute`, which is a deliberate scoped change with its own test obligation - never an
  automatic product of a chronicle pass.
- **Detail that is current and durable but needed only in a nameable context** belongs in a topic
  file of its own, `$env:KINGSHAND_HOME\data\<topic>.md`, indexed on write in the same pass that
  offloads to it. **This is the destination that is live at the moment it is proposed**, and that
  property is the whole reason it works: it sits inside the Hand's own write boundary, so it needs
  no worker and no `statute` change, and this pass can write it, index it and confirm it holds the
  entry before the memory line goes. The two destinations above cannot do that - each needs work by
  somebody else first - so a sweep with only those two can never actually offload anything.

**`<topic>` is a new name of its own, and the pass checks the path is free before it writes.**
`Write-DataFile` overwrites whatever sits at that path without reading it first, so a topic name that
collides with a file `data\` already uses destroys that file silently and the after-the-write check
that the destination holds the entry passes on the wreckage. Test the path before writing and pick
another name when it is taken. **Kingshand's own operational files are never a topic name** -
`backlog.md`, `king.md`, `learnings.md`, `corrections.md`, `memory-archive.md`, `done-archive.md`,
`projects.md` and `index.md` - and neither is any other name already in use under `data\`. Where the
check finds a topic file an earlier pass wrote under the name still wanted, read it whole and rewrite
it in place, then index it with `Add-IndexEntry`; never aim `Write-DataFile` at a path that exists.

Index the topic file through `bin\Index.psm1`, which is the one place that knows the entry format,
and never by hand - a detail file no index lists is a file the next session cannot find, which is
the failure the index exists to prevent:

```powershell
Import-Module $env:KINGSHAND_HOME\bin\Index.psm1 -Force
# The free-path check first, because Write-DataFile overwrites without reading.
Test-Path -LiteralPath (Join-Path $env:KINGSHAND_HOME "data\<topic>.md")
# A new topic name the check found free: written and indexed in one call, so the two cannot come apart.
Write-DataFile -Path "data\<topic>.md" -Content $text -Summary "<what it holds, in one line>"
# A topic file that already existed, read whole and rewritten in place: index it in the same pass.
Add-IndexEntry -Path "data\<topic>.md" -Summary "<what it now holds, in one line>"
```

Forbidden as offload destinations: `CLAUDE.md` itself, which is always loaded for every session and
so relieves nothing; and any project file written by the Hand rather than by a worker.

### Flow: reduce, approve, migrate, remove

1. **Reduce non-pinned material now.** For each eligible candidate record its first line, source
   file, estimated tokens, one-line trigger, live destination and actual budget relief in the
   receipt. Relocate it only by adding it to an owner that already exists, then confirm that
   destination holds the quoted entry before removing the memory entry. A destination whose write
   belongs to somebody else - an undelivered project change, a `statute` change, or any other future
   work - is not live and cannot count as relief, so continue to the next archival or eviction rung
   instead of leaving an over-budget proposal pending. Writing a `data\<topic>.md` in this pass is
   not future work and is no exception to that rule: this pass writes the file, indexes it, and
   confirms it holds the quoted entry before the memory line goes, which is the same test every
   other destination has to pass and the only one that passes it unaided.
2. **Propose a pinned relocation only.** For a pinned candidate, record a `proposed-offload` section
   with the same fields in the receipt and file a held backlog item with
   `tasks-axi hold <id> --reason "<reason>" --kind captain`, preserving the candidate's approval
   state. Explicit approval from the user for that named item is required before anything migrates.
   If they never answer, nothing migrates, the held item persists, and it is never counted as relief.
3. **Migrate an approved candidate outside this pass**, through the owner that destination requires:
   a worker dispatched by `muster` for a project's memory file, or a scoped kingshand change under
   `statute` for kingshand's own material. The source of truth for the migration is the
   entry exactly as quoted in the proposal.
4. **Remove only once live.** The memory entry leaves its file only after the destination actually
   holds it. Until then the entry stays, so knowledge is never in limbo between owners. Leave no
   pointer behind by default, and at most one line where the destination's discoverability is
   genuinely doubtful.

## Draining the correction inbox

`$env:KINGSHAND_HOME\data\corrections.md` is where the Hand appends a correction the moment the King
makes one, under the obligation `CLAUDE.md` owns. **It is an inbox and not a third memory file:**
append-only, never loaded at session start, never counted by `Get-MemoryReport`, and emptied by this
pass rather than curated in place. An absent or empty inbox means no correction has been recorded
since the last pass, which is an ordinary state and never an error. It is a durable file under
`data\` like any other, and **this pass is what lists it** - index it in the knowledge sweep's index
step below, alongside the memory files this pass touched. The obligation in `CLAUDE.md` defers the
listing here on purpose: a mid-turn correction write that also has to index is the cost that stops
the write happening at all, which is the whole reason the inbox exists.

**Every invocation drains it, before the knowledge sweep below** and before step 3 builds the
retention plan - a drained entry is new material in a memory file, so it has to be planned,
consolidated, reduced and measured with everything else. A drain that lands after step 7 has spent
archival, consolidation, offload and eviction pushes the total over budget with every reduction rung
already gone, and step 8 then opens a decision with the user over material a reduction pass could
have absorbed.

1. **Read the whole file and take each entry separately.** An entry is the date, what the Hand did,
   what the King said, and the rule that follows; the rule is the part that has an owner.
2. **Route each entry to its most specific owner**, using `CLAUDE.md`'s Knowledge routing section,
   which owns that mapping: `data\king.md` for a preference, `data\learnings.md` for an operational
   fact, that project's own memory file for a project fact, and `data\memory-archive.md` for an entry
   a later correction already superseded, under the drained-correction provenance shape the cold tier
   section above owns.
3. **Draining is inspect-then-update, never an append.** Read the destination first, decide which
   current statement the entry supersedes, and rewrite that statement rather than adding a second one
   beside it. An entry that arrived as an append-log line still leaves as a curated one, and a drain
   that pastes entries onto the end of `learnings.md` has turned a curated file into the log the
   inbox exists to keep out of it.
4. **An entry whose destination is a project's memory file cannot be written by the Hand**, so it
   becomes a work item instead: file it with `tasks-axi`, naming the project and the fact, and let a
   worker write it through that project's delivery path. Hard rule 1 is not suspended here, and the
   work item is that entry's routing.
5. **Empty the inbox only once the routing is actually written.** An entry leaves the file after its
   destination holds it, or after its work item exists; anything that could not be written stays in
   the inbox for the next pass. Truncating the file with entries unrouted loses the correction
   silently, which is the failure the obligation exists to prevent.

## Knowledge sweep and routing

1. **Sweep the session for uncaptured durable knowledge.** Look for operational learnings,
   preferences the user expressed in passing, project-intrinsic facts, standing decisions, and
   undone next steps. The target is knowledge that exists only in this conversation and would be
   lost at the next reset.
2. **Route each finding using `CLAUDE.md`'s Knowledge routing section.** That section owns the
   mapping; this skill owns the pass. Do not restate the routing rules here.
3. **Write within the existing boundaries.** Create `data\learnings.md` only for a genuinely new
   local learning with no stronger owner, and create `data\king.md` only when there is a real
   preference to record. Project-intrinsic knowledge never goes into a project directly - it is
   routed through a worker. An investigation finding belongs in that worker's
   `$env:KINGSHAND_HOME\data\<id>\report.md` and is not copied into memory. File each undone next step as
   a backlog item, with a genuine dependency or hold where one applies.
4. **Use inspect-then-update.** For every retained fact ask which current statement it supersedes,
   whether it can be a one-sentence rewrite, and whether a stale entry should be refreshed, archived
   or routed to a stronger owner. **Rewrite and prune rather than appending forever.** The only exits
   from a memory file are: folding a learning into the preference file, archiving a stale entry to
   `data\memory-archive.md`, offloading an eligible conditional entry to a live on-demand owner
   through the flow above, promoting it into kingshand's tracked material through
   `statute`, or deleting an entry that is a duplicate of, or already preserved by, a
   stronger existing owner. **A stale unique fact is never deleted, only archived.** Do not invent
   another exit.
5. **Index every memory file this pass wrote or rewrote**, in the pass that wrote it. `king.md`,
   `learnings.md`, `memory-archive.md` and the drained `corrections.md` are durable files under
   `data\` like any other, and a file no index lists is drift the session-start digest counts. An
   existing entry is rewritten in place and keeps the date the file first entered the index, so
   re-indexing a curated file does not make it look new. Index only what this pass actually touched:

```powershell
Import-Module $env:KINGSHAND_HOME\bin\Index.psm1 -Force
Add-IndexEntry -Path "data\king.md"           -Summary "<one line of what it now holds>"
Add-IndexEntry -Path "data\learnings.md"      -Summary "<one line of what it now holds>"
Add-IndexEntry -Path "data\memory-archive.md" -Summary "<one line of what it now holds>"
Add-IndexEntry -Path "data\corrections.md"    -Summary "<one line of what it now holds>"
```

## One-time migration of unmarked entries

Legacy entries carry no markers. An unmarked entry is its file's default tier with unknown age, and
unknown age is not guilt. The first pass after adoption performs a one-time revalidation sweep
rather than a blanket restamp:

- In `data\king.md`, every unmarked entry is simply default-pinned and stays exempt from the
  aging clock, the grace cycle and archive-by-age. Consolidation still applies, and only genuine tier
  deviations receive markers.
- In `data\learnings.md`, stamp each entry the pass can confirm current with its dated marker for
  today, using a deviating tier letter or `<!--P-->` only where the entry genuinely deviates from the
  `aging` default.
- On the first pass that cannot cite independent current-session evidence for an unmarked
  `learnings.md` entry, add `<!--g-->` and retain it through the rest of that pass. Carrying no date,
  it records that the entry has consumed exactly one grace cycle without pretending it was
  reinforced.
- Only an entry that already carried `<!--g-->` when this invocation began is on the next-pass
  branch: replace that marker with a normal dated marker if independent current-session evidence
  confirms it, and otherwise archive it with the reason `legacy-unvalidated`.
- The grace period is one full chronicle cycle, not a time window, and the same transition applies
  when a hand edit later leaves an entry unmarked in `learnings.md`.

## Completion receipt

Report the outcome to the user in plain language, with all of these facts:

- the effective budget, and the total estimated tokens before and after;
- one or more actions for each of `data\king.md` and `data\learnings.md`, using only `unchanged`,
  `added`, `rewritten`, `pruned`, `archived` or `proposed-offload`. Adding or replacing a migration
  marker is `rewritten`, never a new verb such as `migrated`;
- each correction drained from the inbox and where it went, or that the inbox was absent or empty;
- each durable finding filed outside memory, and its owner;
- each archived entry's reason, each offload's live destination and actual relief, and, where a
  pinned candidate was proposed, the `proposed-offload` section with every field;
- every unresolved exception, and every concrete decision opened for an over-budget result;
- whether the session is safe to reset - and say so **only** when every durable finding is captured
  and the after total is within budget with no unresolved exception.

Keep it to the outcome, as the escalation rules require: this is a report about the user's memory,
not a transcript of the pass. Do not hide an over-budget result behind a reset-safe claim.

## Scope exclusion: the pass never writes a skill

**The chronicle pass itself must never create or edit a skill as a destination for a finding.**
Proposing an offload and letting a later approved migration run through its own owner is not the
pass writing a skill. Changing kingshand's tracked `.claude\skills\`, `bin\`, `tests\`, `docs\` or
`CLAUDE.md` is a deliberately scoped kingshand task under `statute`, with the test obligation that
comes with it, and never a by-product of curating memory.
