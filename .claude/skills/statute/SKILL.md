---
name: statute
description: Reference for changing kingshand's own tracked material - `CLAUDE.md`, `bin\`, `.claude\skills\`, `tests\`, `docs\`. Load it before editing any of that material, whether working as the Hand directly or as a worker briefed on a kingshand-repo task. Covers the knowledge-placement decision tree, the one-owner rule for contracts, the inline-stub pattern for content moved into a skill, size discipline for the always-loaded file, trigger hygiene for new skills, the rule that a prose rule needs a test, and kingshand's style rules.
version: 1.0.0
---

# Statute

Load this before changing kingshand's own tracked material: `$env:KINGSHAND_HOME\CLAUDE.md`,
`bin\`, `.claude\skills\`, `tests\`, and `docs\`.

Every skill is project-local: it lives in `$env:KINGSHAND_HOME\.claude\skills\<name>\SKILL.md` and
loads only while Claude Code runs in this directory. Nothing here creates a junction, a symlink or
any other entry under `~\.claude\`, and a change that reintroduces one is a change that alters how
Claude Code behaves in every unrelated project on the machine.

`CLAUDE.md` is always loaded. Every line in it is paid for by every session, whether or not that
session ever reaches the situation the line describes, and conditional detail added inline instead
of routed to its right home is what makes an always-loaded file grow without bound. Applying the
rules below on every change is what keeps that from happening.

## Knowledge-placement decision tree

Before writing a new fact anywhere in this repo, ask where it belongs, in this order.

1. Does the Hand need this on every session or every turn to operate?
   If yes: `CLAUDE.md`, inline.
2. Does the Hand or a worker need it only in a nameable situation - an intake, a gate, a
   dispatch, a landing, a teardown, a specific lifecycle step, a reported bug?
   If yes: a skill under `.claude\skills\`, plus a one-line trigger pointer left inline in
   `CLAUDE.md`'s Skills section.
3. Is it design rationale - why kingshand is shaped the way it is, what was considered and
   rejected, what a future change must not undo?
   If yes: `docs\`, as a dated design note.
4. Is it mechanics - exact parameters, exact commands, exact paths for a script?
   If yes: the script's own header and comment-based help in `bin\`, not prose in `CLAUDE.md`, a
   skill, or a second documentation owner.
5. Is it task or incident evidence - chronology, transcripts, branches, temporary paths, failed
   hypotheses, or delivery proof?
   If yes: keep it in that task's `$env:KINGSHAND_HOME\data\<id>\report.md`, after distilling every
   unique durable fact into its authoritative owner.

Stop at the first tier that answers yes. Do not place a fact at a more convenient tier than the one
this tree gives you.

## One-owner rule

Every contract - a data format, a state machine, a decision procedure - is stated in full exactly
once. Every other mention of it is a one-line cross-reference, never a restatement. `muster` owns the
whole dispatch-to-teardown procedure and `CLAUDE.md` carries one line pointing at it; that is the
shape.

**`bin\Herdr.psm1` is the only place that knows herdr's command line.** Every skill, script and
test above it speaks in workers, panes and states; none of them composes a herdr argument list.
That boundary is the point - herdr replaced the previous spawn layer, something will replace
herdr, and the surface that has to be rewritten stays one file instead of scattering across four
scripts and three skills the way the last one did.

A single deliberate one-line reinforcement at a genuine risk point is allowed, for example a
"don't forget X" placed exactly where forgetting X is costly. Restating the contract's substance a
second time is not allowed: the two copies will drift the moment only one is edited.

When you touch a contract, patch, replace, or prune the owner's existing language rather than
appending a new clause or paragraph wherever possible, then grep the repo for its other mentions
and update the cross-references, not duplicate the change into a second full copy.

## Inline-stub pattern

When content moves out of `CLAUDE.md` into a skill, decide what stays behind by asking one
question: what must survive with no skill loaded? That is the trigger condition for loading the
skill, plus any safety-critical fact that fires in a situation the skill itself is not loaded for.
Everything else - the procedure, the mechanism, the surrounding detail - moves out completely.

Do not leave a partial restatement behind "just in case". A partial copy is exactly the duplication
the one-owner rule forbids.

The model to copy is `CLAUDE.md`'s Skills section: it keeps only when to invoke `muster`,
`annex`, and `survey`, plus the standing reminder that reading `CLAUDE.md` is not a
substitute for loading the skill, and points everything else at the skill itself.

## Size discipline

Apply the decision tree above to every line you are about to add to `CLAUDE.md`. If an addition
needs more than a few lines of conditional detail (detail that matters only in a specific
situation) or reference detail (a file format, an exact schema, historical rationale), you are
almost certainly adding it to the wrong file.

`CLAUDE.md`'s token cost is paid by every session, every time. A skill's cost is paid only by the
sessions that actually load it. When in doubt, write the fact into the skill or doc first by
patching that owner's existing language, and add only the one-line trigger to `CLAUDE.md`.

## Trigger hygiene

A new skill is dead weight if nothing loads it. Every new skill needs its load trigger declared
inline in `CLAUDE.md`'s Skills section, in one line. State the trigger as a condition ("load before
X", "load when Y is reported"), never as a vague pointer. The skill's own `description` must fire
on the situation as well, not only on a slash command, because a reference procedure is reached by
recognising the situation rather than by the user typing its name.

A skill exposed to the Hand and to workers alike is reachable from inside a dispatch, so say in
the skill which of the two is meant to load it and when.

Briefs for tasks that touch kingshand's own tracked material should tell the worker to load this
skill. Nothing in the dispatcher detects that case - `Dispatch-Worker.ps1` takes a repo path as a
caller-supplied string with no reliable signal that it names kingshand itself, unlike a project
registered in `data\projects.md`. Add the instruction to kingshand-repo briefs by hand instead.

## Prose rules need tests

Kingshand's load-bearing rules live in prose - `CLAUDE.md` and the skills - not in code. Nothing in
the suite fails when someone softens a push prohibition, reintroduces the `yolo` truthiness bug, or
quietly deletes a gate, and that is exactly where an irreversible action on a real repository comes
from.

`tests\Docs.Tests.ps1` is the answer: it asserts that the rules in `CLAUDE.md` and the skills
actually exist, by pinning the specific wording that carries each rule, so deleting the rule fails
a test. A new rule that matters gets an assertion there in the same change that introduces it.

Assert on wording specific enough that the rule's deletion breaks the test - a check for a word
common enough to survive the rule's removal is worthless. Follow the existing `Assert-Phrase`,
`Get-DocText`, and `Get-CodeFence` helpers rather than inventing a parallel mechanism, and note
that containment is asserted with `.Contains` and not `Should -BeLike`, because the backtick is
PowerShell's wildcard escape character and a `-BeLike` pattern quietly stops matching backtick-rich
text it was copied from.

For critical safety, routing, and gating behavior generally, prefer deterministic enforcement over
relying on agent memory alone. Keep the prose as the authority and discovery layer, and make the
test the thing that notices when the prose is gone.

## Style rules

- Use `-`, never the long dash (U+2014). `tests\Docs.Tests.ps1` asserts this for every skill and
  for `CLAUDE.md`.
- Never mention Claude, AI, an assistant, or a model in anything that reaches a git remote or Azure
  DevOps: ticket text, commit messages, PR bodies. This is hard rule 3 and it does not bend.
- Never add an agent name as a commit co-author.
- Wrap tracked Markdown to match the existing skills, at roughly 95 columns, and keep paragraphs
  as paragraphs rather than one sentence per line.
- Scripts under `bin\` are PowerShell 7: open with `#Requires -Version 7.0` and
  `Set-StrictMode -Version Latest`, as `Crew.psm1` and `Projects.psm1` do.
- A module under `bin\` imports a nested module **without** `-Force`; a script may force its own
  top-level imports. `-Force` removes the module before re-importing it, and the removal takes the
  copy the calling script already had, so that script silently loses the nested module's functions
  partway through and dies with "not recognized" from a module it never touched - which is how
  `Test-CrewPrereqs` printed every check OK and then lost `Get-KingshandHome`. `Herdr.psm1`,
  `Index.psm1` and `Projects.psm1` point their import line back here, and `tests\Index.Tests.ps1`
  and `tests\Projects.Tests.ps1` pin the two edges that regressed.
- `yolo` is the string `'on'` or `'off'`, never a boolean. Test it as `-eq 'on'`; `if ($proj.yolo)`
  is true for `'off'` because every non-empty string is truthy in PowerShell.
- Tests live in `tests\` as Pester, named `<Subject>.Tests.ps1`. Extend an existing file rather
  than inventing a new runner.
- Tests must exercise behavior through a public interface and must never assert
  implementation-source bytes, with the deliberate exception of the prose assertions above, whose
  subject genuinely is the text.
- The whole suite must pass before a change is done: `Invoke-Pester -Path $env:KINGSHAND_HOME\tests`.
