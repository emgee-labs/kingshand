---
name: petition
description: Decision procedure for an ask-user finding returned by the no-mistakes review gate. Load it before deciding any ask-user finding, whatever the project's yolo posture, to tell a correction within accepted intent apart from a product or engineering contract expansion that needs the user. Only a project registered `no-mistakes`, or a `no-mistakes-prod-only` project whose task resolved to `no-mistakes`, ever produces one - a `local-only` or `direct-PR` project has no review gate and never does.
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
   that escalation rather than authorize an autonomous answer. `yolo` is the string `'on'` or
   `'off'`; test it as `-eq 'on'` and never for bare truthiness, because in PowerShell
   `if ('off')` is true and would silently grant an autonomy the user never registered.
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
   `muster` Step 2 and nowhere else - read it there before deciding one. It escalates the design
   question and never the fixing, and the discriminator it states is what separates an escalation
   from a Fix you may authorize; a bare count of rounds is neither.
8. Apply the existing stronger user boundaries first.
   Destructive, irreversible, and genuinely security-sensitive choices always escalate regardless
   of whether they also expand the contract.

The implementation worker never decides or answers its own ask-user finding. It stops at the
finding, routes the decision to the Hand, and applies only the decision returned through the
active review gate.

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

## Classification examples

- Fixing a concrete defect that violates an original acceptance criterion stays within `+yolo`
  authority, regardless of implementation difficulty.
- Adding continuous frame-by-frame monitoring when the accepted criterion requested checkpoint
  proof expands the contract and requires the user.
- A finding that fires the `Repeated findings` rule at step 7 sends the design question to the
  user while the fixing carries on, and only the discriminator that rule states decides whether
  the Fix itself is still yours to authorize.
- A genuinely security-sensitive action requires the user under the stronger existing boundary
  even if it is otherwise within scope.
- Complex architecture explicitly requested by the user stays within scope and does not escalate
  merely because it is complex.
