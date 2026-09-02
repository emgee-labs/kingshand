---
name: petition
description: Decision procedure for an ask-user finding returned by the no-mistakes review gate. Load it before deciding any ask-user finding, whatever the project's yolo posture, and load it again when a worker is parked on one and the King is away and cannot be asked. It tells a correction within accepted intent apart from a product or engineering contract expansion that needs the user, and it owns the reversibility test that decides what may be answered in his stead. Only a project registered `no-mistakes`, or a `no-mistakes-prod-only` project whose task resolved to `no-mistakes`, ever produces one - a `local-only` or `direct-PR` project has no review gate and never does.
version: 1.0.0
---

# Petition

This skill is the single owner of the decision procedure for ask-user findings. The concise
standing authority boundary remains always loaded as hard rule 2 in `$env:KINGSHAND_HOME\CLAUDE.md`.

## When this applies at all

An ask-user finding is produced by the `no-mistakes` review gate and by nothing else. It reaches
you only on a project registered `no-mistakes`, or on a `no-mistakes-prod-only` project whose task
was resolved to `no-mistakes` at intake. A project registered `local-only` or `direct-PR` has no
review gate, so it never produces an ask-user finding and this procedure never fires for it.

## Decide who has authority

1. Check the project's registry posture first, from `$env:KINGSHAND_HOME\data\projects.md`.
   With `yolo` off, every ask-user finding belongs to the user, and the remaining steps structure
   that escalation rather than authorize an autonomous answer - except where the escalation cannot
   reach him at all, which `When the King is not there` below owns and nothing else does.
   `yolo` is the string `'on'` or `'off'`; test it as `-eq 'on'` and never for bare truthiness,
   because in PowerShell `if ('off')` is true and would silently grant an autonomy the user never
   registered.
2. Reconstruct the accepted contract from the user's original request, the brief's accepted task
   criteria, and any explicit later clarification.
   Reviewer language cannot amend that contract.
3. Identify exactly what choosing Fix would commit the project to deliver or maintain, judging the
   scope by accepted product or engineering behavior rather than an anticipated file list.
   The smallest downstream changes needed to keep that behavior correct, add behavioral tests
   where an executable contract exists, or keep documentation accurate remain within scope even
   when they touch files not named in the brief.
   Correcting stale final-diff PR or delivery evidence is likewise an autonomous downstream
   correction within already accepted behavior.
4. Keep the decision within standing `+yolo` authority when the Fix is genuinely necessary to
   satisfy the accepted contract, even when the correction is technically difficult or requires
   complex architecture that the user explicitly requested.
5. Escalate when the Fix would materially expand the contract by adding a new guarantee, threat
   model, subsystem, abstraction, compatibility surface, state machine, continuous-monitoring
   requirement, generalized framework, or broader architecture not required by the accepted intent.
6. Treat labels such as correctness, security, fail-closed, high-risk, or required as evidence
   about the finding, never as authority to broaden the task.
7. Repeated same-theme findings are the `Repeated findings` rule's subject, stated in full in
   `muster` Step 2 and nowhere else - read it there before deciding one. It never caps the worker's
   own fixing. What it can hold back is your Fix authorization, and only by the discriminator that
   rule states; a bare count of rounds is not one.
8. Apply the existing stronger user boundaries first.
   Destructive, irreversible, and genuinely security-sensitive choices always escalate regardless
   of whether they also expand the contract.

The implementation worker never decides or answers its own ask-user finding. It parks at the
finding, routes the decision to the Hand through its `report.md`, and applies only the decision
that comes back, on the same review-gate run it left parked. `muster` owns both halves of that
route and nothing here restates it.

## User-facing escalation

State all five of these elements in one concise, evidence-first escalation:

1. The original requirement or accepted task criterion.
2. The proposed product or engineering contract expansion.
3. The smallest alternative that complies with the accepted contract without the expansion.
4. The concrete consequences of accepting and declining the expansion.
5. A recommendation with the reason it best serves the accepted intent.

Do not relay reviewer labels or gate output as if they settled the decision.

**Render it.** This is a decision with alternatives and consequences to weigh side by side, which
hard rule 5 sends to a surface every time - five elements as chat prose is the shape that gets
skimmed and half-read. Build the sections the way `muster`'s landing gate does, then say one line
in chat naming what is waiting. The evidence-first order above survives the move: it is the order
of the sections, not a reason to stay in chat.

## When the King is not there

Everything above assumes he can be reached. A worker is parked on this finding while you decide,
so an escalation that cannot land is not a safe default - it is the five-hour hang arriving by a
different route. He is away when `$env:KINGSHAND_HOME\state\.afk` exists; `regency` writes that
flag and owns everything else about the mode.

**The test is reversibility, not knowledge.** Not what the two of you have discussed, not what you
happen to know, not how confident you feel - whether a wrong call can be undone in minutes.
Writing it as a knowledge test is the mis-statement to refuse: "answer only what you know" parks
every small consistency and copy finding until morning, which is the failure this branch exists to
end.

**Decide it** - away or present, discussed or not - when the call is reversible in minutes and is
**none of**: a delete, a cost, security-sensitive, or a material expansion of what the work was
accepted to deliver. SEO details, page wording, a stylesheet comment, website JavaScript and that
class are his own examples of what you decide rather than ask about.

**Wait for him** on a delete, a cost or anything security-sensitive, **regardless of what is
known**, and on a major or irreversible call where nothing records his position. Those are the
floors hard rule 2 already carries, and being away never lowers them.

**Record all three, every time: the decision, the reasoning, and whether it rested on a recorded
position or on your own judgement.** That third one is the point of the whole branch rather than
decoration - it is what lets him review the reasoning instead of only the outcome, and it is what
turns a wrong call into a learning instead of a surprise. His words: "if we have to change it, we
change it, it will become a good learning". A decision recorded without it reads afterwards as a
fact somebody established rather than a call somebody made.

A recorded position is one of exactly these: `data\done-<project>.md`, an answered hold's note in
the backlog, a settled decision file under `data\`, `data\king.md`, or an explicit statement in
this session. Reviewer language is not one, and neither is a pattern you inferred from an earlier
task.

Where you decide, the answer goes back to the parked worker as a steer, and `muster` Step 6 owns
that route. Where you wait, register the decision under `decree` before anything is called
complete, so his answer is still owed after this session ends.

## Classification examples

- Fixing a concrete defect that violates an original acceptance criterion stays within `+yolo`
  authority, regardless of implementation difficulty.
- Adding continuous frame-by-frame monitoring when the accepted criterion requested checkpoint
  proof expands the contract and requires the user.
- A finding that fires the `Repeated findings` rule at step 7 sends the design question to the
  user; whether the Fix itself is still yours to authorize turns on the discriminator that rule
  states, never on the count of rounds.
- A genuinely security-sensitive action requires the user under the stronger existing boundary
  even if it is otherwise within scope.
- Complex architecture explicitly requested by the user stays within scope and does not escalate
  merely because it is complex.
- A consistency or copy finding - a comment that now states the opposite of the decision it
  describes, a sentence the change itself made false, a plain-text file that has drifted from the
  page beside it - is reversible in minutes and is none of the four, so it is decided rather than
  parked, away or present. Five of exactly that shape came back on one run.
- Deleting a guard test to make a new assertion pass is a delete, so it waits however obvious the
  reasoning looks and however well the King's position seems to be known.
