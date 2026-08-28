---
name: decision-hold-lifecycle
description: Reference policy for finishing an investigation or a review without losing a decision that belongs to the user. The Hand loads it before treating a worker's work as complete, before closing that work out, and when recording or routing the user's answer. Owns the durable backlog lifecycle of an unresolved decision - the stable key, the registration, the inventory declaration, and the only way a hold is allowed to close.
version: 1.0.0
---

# Durable unresolved-decision lifecycle

This skill is the single policy owner for unresolved decisions that belong to the user and were
discovered by an investigation or a review. The Hand loads it; nobody invokes it by name.

A worker never loads it. Its brief already tells it to write any decision the brief did not settle
into `$env:KINGSHAND_HOME\data\<id>\report.md` and stop there, because a background worker cannot reach
the user. Turning that written question into durable state is the Hand's job, and this skill is
how it is done.

## Policy

Every unresolved decision that belongs to the user and is discovered while producing, reading or
ending an investigation or a review must become a durable backlog item in `data\backlog.md`
**before that work may be treated as complete**.

You perform the inventory yourself, because no script can infer a decision from report prose, chat
or terminal output. A worker's `report.md` is the surface that matters most: the Done-means block
requires it to name any decision its brief did not settle, so a report carrying such a question is
exactly this skill's trigger.

Give each distinct unresolved decision a **stable, privacy-safe key**, and register it under that
key, so registering it a second time on a retry is idempotent while two different decisions keep
two different durable identities. `tasks-axi` ids are slug-shaped - letters, digits, `.`, `_` and
`-`, with no spaces - so the key must be too. Derive it from the originating work id and the
substance of the choice, and never from a customer name, a credential, a path, a ticket body or
anything else the queue should not carry. A key that changes between retries files the same
decision twice; a key shared by two decisions loses one of them.

After inventorying the whole surface, either every unresolved key is registered, or you state
plainly that the reviewed surface contains no unresolved decision. **Do not let "I found nothing"
be silence.** An unstated inventory and an inventory never taken read identically afterwards, and
only one of them is safe.

**Do not close a hold merely because the work that found it finished**, its report was archived,
or its worker was torn down. Those are unrelated events. A completed investigation, a closed
backlog item for the investigation itself, a confirmed push and a removed worktree say nothing
whatsoever about whether the user has answered.

When the user's answer authorises follow-up work, the hold stays the authoritative item until the
answer is durably recorded, the dependent work exists as its own backlog item, and that item is
blocked by the hold. Only then does the hold close.

When the answer routes no work at all - a declined proposal - record that answer and close it.
That never substitutes for routing work the user did authorise.

Resolved findings, recommendations that need no choice, and prose that merely sounds
decision-like do not create holds. A question the worker answered itself, a recommendation the
user can take or leave with no consequence either way, and a sentence shaped like a question but
settled in the next paragraph are all noise, and filing them buries the real decisions among them.

`bearings` reads the resulting structured state through `tasks-axi` and must never compensate by
scraping reports, chat or terminal output. A decision that is not in the backlog does not appear
in the digest, and that is the point: the fix is to register it, never to make the digest guess.

## Expressing this with tasks-axi

`tasks-axi` has `add`, `hold`, `unhold`, `block --by`, `done` and `reopen`. It has **no**
`complete`, `resolve`, `decline` or `repair` verb, so each of those states is expressed with what
does exist. Do not build a wrapper script for the missing ones; adopting `tasks-axi` is what
removed the need for a wrapper, and a wrapper would become a second owner of this policy.

Run every command from `$env:KINGSHAND_HOME` so `.tasks.toml` resolves.

| What the lifecycle needs | How it is expressed here |
|---|---|
| register the decision | `tasks-axi add <key> "<one line>"`, then `tasks-axi hold <key> --reason "<reason>" --kind captain` |
| attest the inventory | no verb exists - you state it in the close-out, in words |
| route an authorised answer | `tasks-axi add <work-id> "<one line>"`, `tasks-axi block <work-id> --by <key>`, then `tasks-axi done <key> --note "answered: <the decision>"` |
| record a declined answer | `tasks-axi done <key> --note "declined: <the decision>"`, with no dependent item |
| repair a hold closed without its answer | `tasks-axi done <key> --note "<answered or declined>: ..."` backfills the note without moving the close date; where authorised work was never routed, `tasks-axi reopen <key>` first, then route it and close normally |

Four mechanical facts this depends on, each confirmed against the tool rather than assumed:

- **`add` and `hold` are both idempotent under the same key.** Re-running either reports
  `already: true` and changes nothing, which is what makes a stable key safe to replay after a
  failed or interrupted pass.
- **`--reason` may not contain parentheses.** `tasks-axi` reserves them for its own markdown hold
  tags and refuses the whole command with a validation error. Rewrite the reason rather than
  quoting around it.
- **Closing the blocker clears the dependency edge.** `tasks-axi done <key>` makes every item
  blocked by that key dispatchable again, so the closing `done` is what releases the work the
  answer authorised. That is why the order below is load-bearing: block first, close second. Close
  first and there is nothing left to route, and the queue never records that the answer authorised
  anything at all.
- **`--kind captain` is what marks the hold as the King's own.** The other kinds - `external`,
  `load`, `parked`, `future` - wait on something that is not the King, and `bearings` routes them to
  a different section. `stow` files its pinned-offload approvals the same way, so stay consistent
  with it rather than inventing a second spelling.
- **`captain` here is `tasks-axi`'s spelling, not ours, and it is not free text.** The tool
  validates `--kind` against exactly `captain`, `external`, `load`, `parked` and `future`, and
  refuses anything else with a `VALIDATION_ERROR`. It survives the King-and-Hand vocabulary
  everywhere else in this repo for that reason alone. Do not "correct" it to `king`; the hold will
  simply not be recorded, and the decision it was protecting is then durable nowhere.

### The note convention

The note on the closing `done` is the durable answer, and its first word says which kind of answer
it was. This is the whole mechanism that keeps a declined proposal distinguishable from one that
was answered and routed, so it is a convention to follow exactly rather than a suggestion:

- `answered: <the user's decision, in their terms>` - the answer authorised work. A dependent
  backlog item exists and was blocked by this key before the hold closed.
- `declined: <the user's decision, in their terms>` - the answer routed no work at all.

Both carry the decision itself, not a pointer to where it was said. Chat does not survive a
session; the note does. **A hold closed with no note leaves no durable answer**, so a later session
sees a closed item and cannot tell whether the user answered, declined, or was never asked - and
repairing that costs the user the same question a second time.

## Operating sequence

1. Read the complete result before declaring anything complete: the worker's `report.md` in full,
   and the review or investigation surface it belongs to.
2. Inventory only the genuine unresolved choices that require the user. Apply the exclusions in
   the policy above before filing anything.
3. Give each one a stable, privacy-safe, slug-shaped key, and register it with `add` then `hold`,
   with a concise reason stating the choice the user has to make.
4. State the inventory for that pass in the close-out: every key you registered, or plainly that
   this surface contained no unresolved decision.
5. Relay the choices to the user as decisions, in their own nouns, following `CLAUDE.md`'s
   Escalation and etiquette section. Do not use the word hold in chat; it is an internal label.
6. If the answer authorises work, file that work as its own backlog item and block it by the hold's
   key, before closing anything.
7. Close the hold with `done` and the `answered:` or `declined:` note, whichever the answer
   actually was.
8. Confirm the result in structured state: `tasks-axi ready --include-held` no longer lists the
   closed hold, and any routed work is a real queued item rather than a sentence in a report.

## No script enforces this gate

Firstmate blocks its teardown on this gate. **Kingshand has nothing equivalent, and this skill will
not pretend otherwise.** `crew` Step 8b tears a worker down on landing or push evidence alone and
reads no decision state, `bin\` contains no check that looks for an open hold before cleanup, and
`tests\Docs.Tests.ps1` pins the rules on this page as text without being able to observe whether a
decision was ever filed.

So this is a discipline the Hand follows, not a check a script performs. Nothing downstream
catches a decision you did not inventory: the worker is gone, its session and transcript are gone,
and the only trace left is a `report.md` nobody has a reason to re-open. Treat the inventory at
step 4 as the moment the decision either becomes durable or is lost.
