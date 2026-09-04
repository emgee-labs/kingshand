---
name: decree
description: Reference policy for finishing an investigation or a review without losing a decision that belongs to the user. The Hand loads it before treating a worker's work as complete, before closing that work out, and when recording or routing the user's answer. Owns the durable backlog lifecycle of an unresolved decision - the stable key, the registration, the inventory declaration, and the only way a hold is allowed to close.
version: 1.0.0
---

# Decree

This skill is the single policy owner for unresolved decisions that belong to the user and were
discovered by an investigation or a review. The Hand loads it; nobody invokes it by name.

A worker never loads it. Its brief already tells it to write any decision the brief did not settle
into `$env:KINGSHAND_HOME\data\<id>\report.md` and end its turn there, because a background worker
cannot reach the user. Ending a turn is not the end of the work - `muster` Step 6 owns the route
that carries the Hand's answer back into a worker still waiting on one. Turning that written
question into durable state, so it is still owed after this session ends, is the Hand's job, and
this skill is how it is done.

## Policy

Every unresolved decision that belongs to the user and is discovered while producing, reading or
ending an investigation or a review must become a durable backlog item in `data\backlog.md`
**before that work may be treated as complete**.

You perform the inventory yourself, because no script can infer a decision from report prose, chat
or terminal output. A worker's `report.md` is the surface that matters most: the Done-means block
requires it to name any decision its brief did not settle, so a report carrying such a question is
exactly this skill's trigger.

Give each distinct unresolved decision a **stable, privacy-safe key**, and register it under that
key, so a retry lands on the same durable item rather than filing a second one while two different
decisions keep two different durable identities. Which half of that registration a retry may
safely replay is the mechanical facts' business, below, and the two verbs do not behave alike. `tasks-axi` ids are slug-shaped - letters, digits, `.`, `_` and
`-`, with no spaces - so the key must be too. Derive it from the originating work id and the
substance of the choice, and never from a customer name, a credential, a path, a ticket body or
anything else the queue should not carry. A key that changes between retries files the same
decision twice; a key shared by two decisions loses one of them.

**Where the decision came from a parked worker, the key is stable, privacy-safe and slug-shaped
like any other, and it is always prefixed with the work id.** `muster` Step 6 writes the key you
registered onto that worker's own record the same turn it registers the decision, so wherever that
pointer is set a later session looks the key up rather than reconstructing it from what a worker
happened to write. That is the whole reason the pointer exists; `muster` owns it and this skill
owns the key itself.

**The pointer is the direct lookup, and the work-id prefix is what covers the window where there
is no pointer yet.** Registering the hold and writing the pointer are two commands, so a session
that ends between them leaves an open hold that no pointer names, and the next session finds a
report naming a decision with a null pointer. It looks the work id up in the queue before
registering anything, and points the record at the open hold there that covers the decision
the report names - the work id narrows the search and the decision itself selects among what
it returns. Replaying `add` under an existing key changes nothing, so the pointer ends up on
the hold that exists. It does not replay `hold`: that one is a write, and it would overwrite
the reason the open hold is already carrying. **Where which open captain hold covers this
decision cannot be established, do not guess and do not take the first** - say so and escalate,
naming the candidates. That is keyed on coverage and not on how many candidates the work id
returned: a lone open hold whose reason does not establish that it covers this decision is
refused by this same sentence, because taking it for want of an alternative points the record at
a live decision belonging to other work and steers the worker on an answer that was never about
it.
**That lookup matches the full key, or the work id with the `-` that follows it, and never a bare
prefix.** The composition above puts a `-` between the two halves precisely so it can be matched
on: without it, `T-100` selects every `T-1001-` key as well, and the recovery re-registers a worker
against a live decision belonging to another piece of work entirely.
**That recovery is a queue lookup and never a reading of report prose**: nothing re-derives a key
from what a worker wrote, and filing a second key for the same decision asks the King the same
question twice and orphans the first hold.

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

`survey` reads the resulting structured state through `tasks-axi` and must never compensate by
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
| route an authorised answer | `tasks-axi add <work-id> "<one line>"` where no item holds that work yet, then `tasks-axi block <work-id> --by <key>`, then `tasks-axi done <key> --note "answered: <the decision>"`. Where the answer went back into a worker already running on this work's own item, skip the `add` and block that existing item |
| record a declined answer | `tasks-axi done <key> --note "declined: <the decision>"`, with no dependent item |
| record a decision the Hand answered in the King's stead | `tasks-axi add <key> "<one line>"`, `tasks-axi hold <key> --reason "<reason>" --kind captain`, `tasks-axi block <work-id> --by <key>` against the item the parked worker is already running under, then `tasks-axi done <key> --note "answered: <the decision, the reasoning, and whether it rested on a recorded position or on your own judgement>"` - registered and closed in the same pass, because there is nobody to wait for, and the block is still what makes that `answered:` note true |
| repair a reason that does not say which of the two open holds it is | `tasks-axi hold <key> --reason "<the reason, restated to say either that the question is with him and what he has to choose, or that you are answering it in his stead under petition's test and which way>" --kind captain` - re-running `hold` under the same key rewrites the reason in place without opening a second hold, which is why this is a repair and not something to run by habit. **The `--kind` is not optional on this row.** An omitted one is not left alone: it is cleared to `-`, and the hold stops being a captain hold, which drops the decision out of King's Call and out of the open-hold lookup that recovers an orphaned registration |
| repair a hold closed without its answer | `tasks-axi done <key> --note "<answered or declined>: ..."` backfills the note without moving the close date; where authorised work was never routed, `tasks-axi reopen <key>` first, then route it and close normally |

Seven mechanical facts this depends on, each confirmed against the tool rather than assumed:

- **`add` is idempotent under the same key. `hold` is not.** Re-running `add` prints
  `already: true` and changes nothing, not even the title, which is what makes a stable key safe to
  replay after a failed or interrupted pass. Re-running `hold` opens no second hold, but it is a
  write rather than a no-op: it prints `ok: hold <key> -> held (<kind>)`, never `already: true`, and
  it overwrites both `hold_reason` and `hold_kind` with whatever the replay passed - and passing
  nothing passes nothing, so an omitted `--kind` writes `-` over `captain` rather than leaving it
  where it was. The repair row above carries the kind explicitly for that reason. So does the
  harm: the reason is the only thing recording whose
  question an open hold is, so replaying `hold` with a fresh reason over an open one destroys the
  discriminator and freezes a decision that was already registered correctly. Replay `add` freely;
  leave an open hold's reason alone unless you are deliberately repairing it.
- **`--reason` may not contain parentheses.** `tasks-axi` reserves them for its own markdown hold
  tags and refuses the whole command with a validation error. Rewrite the reason rather than
  quoting around it.
- **Closing the blocker clears the dependency edge.** `tasks-axi done <key>` makes every item
  blocked by that key dispatchable again, so the closing `done` is what releases the work the
  answer authorised. That is why the order below is load-bearing: block first, close second. Close
  first and there is nothing left to route, and the queue never records that the answer authorised
  anything at all.
- **The reason says which of the two open holds this is, and that is not optional.** An open hold
  with no note has two causes that take opposite actions later: he genuinely has the question, or
  the Hand was answering it in his stead and the pass ended before the note went in. Nothing else
  in the queue tells them apart - both are `--kind captain`, and neither carries a note yet - so
  the reason states it in words: that the question is with him and what he has to choose, or that
  you are answering it in his stead under `petition`'s test and which way. A reason that records
  only the choice leaves a later session unable to tell a question he owes from a pass that was
  interrupted, and it freezes the second as though it were the first. The reason is what a later
  session reads to tell them apart, and `petition` owns what each one does next: a question that
  is genuinely with him waits, and an interrupted stead pass is re-entered on that skill's test and
  finished.
- **A reason that says neither is not a third branch to take - it is a cause not yet established,
  and that is the default for every reason nobody anticipated.** Nothing is steered, nothing is
  closed and nothing is re-escalated while it stands: establish which of the two it was, repair the
  reason with the row above, and only then take the branch the repaired reason names. Guessing is
  what this default exists to stop, because the two guesses are not symmetric - guessing that the
  question is his parks a worker until morning over a decision the Hand already had the authority
  to answer. Stated as a default rather than as one more case, so a reason shaped in a way nobody
  here thought of is safe rather than unmatched.
- **`--kind captain` is what marks the hold as the King's own.** The other kinds - `external`,
  `load`, `parked`, `future` - wait on something that is not the King, and `survey` routes them to
  a different section. `chronicle` files its pinned-offload approvals the same way, so stay
  consistent with it rather than inventing a second spelling.
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
  backlog item exists and was blocked by this key before the hold closed. **Where the answer went
  back into a worker already running on this work's own item, that item is the dependent one and
  no second is created** - steering the answer in is what routes it, and a new item beside the one
  already under way files the same work twice.
- `declined: <the user's decision, in their terms>` - the answer routed no work at all.

**A decision the Hand answered in the King's stead is one of these too, and its note carries three
things rather than one: the decision, the reasoning, and whether it rested on a recorded position
or on the Hand's own judgement.** `petition` owns which decisions those are and what a recorded
position is; this is where the record lands, and it is registered and closed in the same pass
because nobody is being waited for. **It is an `answered:` note like any other, so the block still
happens** - the steered worker's own item is the dependent one, exactly as the bullet above says,
and skipping it leaves a closed note claiming an authorisation the queue never recorded. Nothing else durably holds it - a regency's return digest is
built inside one session, so a restart before he is back means he is never told a call was made in
his name at all.

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
6. If the answer authorises work, block that work by the hold's key before closing anything, and
   file it as its own backlog item first where no item holds it yet. Where the answer went back
   into a worker already running on this work's own item, that item is the one to block and no
   second is filed - it is already the dependent item, and the block is still what records that
   the answer authorised the work.
7. Close the hold with `done` and the `answered:` or `declined:` note, whichever the answer
   actually was. Where that answer is going back to a parked worker, this close comes before the
   steer is sent; `muster` Step 6 owns that route and why the order matters.
8. Confirm the result in structured state: `tasks-axi ready --include-held` no longer lists the
   closed hold, and any routed work is a real queued item rather than a sentence in a report.

## No script enforces this gate

Firstmate blocks its teardown on this gate. **Kingshand has nothing equivalent, and this skill will
not pretend otherwise.** `muster` Step 8b reads two recorded things before teardown - the pointer
on the worker's record, and the hold that pointer names - and refuses only where that hold is
still open. The pointer says which decision, the hold says whether it is still owed, and a closed
one stops nothing: the pointer is never cleared, so a set field on its own would refuse cleanup of
every worker that ever parked, for the rest of its life. What neither read can catch is a decision
nobody registered here - it has no hold and no pointer, so it stops nothing at all. `bin\` contains
no check that looks for an open hold before cleanup, and
`tests\Docs.Tests.ps1` pins the rules on this page as text without being able to observe whether a
decision was ever filed.

So this is a discipline the Hand follows, not a check a script performs. Nothing downstream
catches a decision you did not inventory: the worker is gone, its session and transcript are gone,
and the only trace left is a `report.md` nobody has a reason to re-open. Treat the inventory at
step 4 as the moment the decision either becomes durable or is lost.
