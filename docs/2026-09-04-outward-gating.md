# Who may merge, and when the Hand asks before acting outward

2026-09-04. Two changes to the same rule, delivered together because they rewrite the same
sentences in the same places. Merging on the forge became a per-repository permission that is off
unless declared, and `yolo` off gained a stop before anything that goes to a server.

## Merging: the absolute was false in all three places it was stated

`CLAUDE.md` hard rule 2 said "Muster never merges on the forge". `muster` Step 7 listed it among
the floors no posture relaxes. `muster` Step 8 said `direct-PR` and `no-mistakes` work "ends at a
pull request that the user merges on the forge; `muster` never merges there".

All three were false at the time they were read. The King had granted the Hand permission to merge
kingshand's and aegis-manager's own green pull requests, and the Hand was doing it. The permission
lived as a sentence in each of those two entries' description text in `data\projects.md`, because
the registry annotation was a fixed token set that warned on anything it did not recognise. Both
descriptions said so themselves, each naming the task that would replace it.

A rule stated three times and true nowhere is worse than no rule. It teaches every reader that the
prohibitions in that list are approximate.

### Why a parsed token rather than the prose that was already working

The prose was working in the narrow sense that the Hand read it and acted correctly. It fails on
everything else:

- **It cannot fail closed.** A description is free-form text written by a person. Deciding
  "permission granted" from it means reading prose for intent, which has no bounded case space and
  no round after which the reading is finished. The standing criteria call that out by name, and
  this repository has paid for it three times in other guises.
- **It cannot be tested.** Nothing could force the failure and watch the permission stay off,
  which is the only way anyone finds out a default has silently flipped.
- **It is invisible where it matters.** `Get-ProjectEntry` returns the description, so the Hand
  had to notice a sentence buried in a paragraph at the moment it was deciding whether to merge.

So the permission is a `+merge` token in the annotation, parsed by `bin\Projects.psm1` into a
`merge` key holding the string `'on'` or `'off'` - the same shape as `yolo`, tested the same way,
and off unless the token is there. Every way of not reading it leaves it off: an unrecognised
token of either shape - a `+something` the parser does not know, or a bare word after the mode -
warns and forces merge off for that entry while leaving mode and yolo as they were, an
unrecognised mode drops the whole annotation including a `+merge` that sat beside it, and an
unreadable registry throws out of `Get-ProjectEntry` rather
than returning a value at all. That last one matters on its own terms: unreadable has to read as
unreadable, never as the state word `'off'`, or a caller cannot tell "declined" from "could not
tell".

### Why it is not a mode and not a fourth posture

The King settled this: "for merge, we can go repo to repo basis, 1 line do no harm." A mode
answers how work ships and `yolo` answers whether the Hand asks first. Merging is orthogonal to
both - a `+yolo` project the Hand may not merge is an ordinary combination, not a contradiction -
and folding it into either would have produced a cross product of postures to keep straight.

`emgeelabs-site` is the reason the default runs the way it does. Its `main` is what Cloudflare
Pages publishes, so a merge there is a live production release. It is registered `+yolo` and it
must never carry `+merge`.

### The contradiction this created, and how it was resolved

`CLAUDE.md`'s Instruction precedence section lists merge among the actions that still require the
user to state the concrete action explicitly, and says a registered `+yolo` posture is never a
substitute for that. A standing `+merge` permission contradicts it head on.

It is resolved rather than ignored, in that section, on the section's own terms: an override must
identify the concrete action, object, or bounded set it governs. `+merge` does exactly that - one
action, one repository - where `+yolo` grants routine autonomy over everything a project does and
therefore does not. The exception is named there and bounded there: never read by analogy onto
another repository, never inferred from `+yolo`, never widened past a merge.

**Green is untouched by any of this.** The permission answers who may merge. What may be merged is
the same list of floors it always was, and Step 7 restates none of them loosely.

### Decided at Step 7, performed at Step 8a

The first draft had Step 7 own the whole thing, and that does not work once `yolo` off holds Step 7
before the push: at that moment there is no pull request to merge, no gate outcome to call green
and nothing on the forge at all. So the two halves are separated. Step 7 reads `$proj.merge`, judges
it against the floors and is the gate. Step 8a performs it, after the push is confirmed and the URL
recorded at stage `ready`, which is the first point at which a pull request exists.

The merge command is `gh pr merge` with the strategy that repository already uses. No strategy is
prescribed here: squash, merge commit and rebase are settled per repository, and picking one in a
skill would quietly override that choice on every project at once.

### Merge against rule 2's own outward stop

A merge reaches a server, so it falls inside rule 2's open-ended clause, and with `yolo` off that
clause asks for the user's word. Read alongside a standing `+merge` permission that is exactly
that word given in advance, the two could be taken either way, and a rule with two readings is not
a rule. Rule 2 settles it: `+merge` is the word the stop asks for, recorded in the registry rather
than given fresh each time, so it is not asked again on a project that declares it and the merge is
refused outright on every project that does not.

## `yolo` off: the middle was ungated

With `yolo` off, the Hand gated two moments - before dispatching, and before landing - and nothing
in between. So a worker committed, the review gate pushed, and a pull request opened on a public
forge with nobody having been asked. The King's words: "the only change we are making is yolo off
asks before going to server, be a comment, ado ticket, pr raise, a git push or any server thing."

The gated set is named rather than left to judgement: a git push; raising or editing a pull
request; posting a comment anywhere; creating or updating an Azure DevOps work item; and any other
action that reaches outside this machine. **The last is the rule and the others are examples of
it** - an examples-only list invites the reading that anything unlisted is fine.

`local-only` needs nothing. It never pushes, never opens a pull request and never reaches a
server, so the rule does not fire there. That is why no separate confirmation exists for it: the
King dropped that idea deliberately, having satisfied himself that a worker's branch is visible
from his ordinary checkout.

`counsel` is covered by the same rule and does not get an exemption for producing tickets rather
than code. `tasks-axi` is local and needs nothing; an Azure DevOps work item reaches a server.

### Why the stop is the landing gate, held earlier

The obvious implementation is a third gate. It is the wrong one: the Hand would then hold a gate
before the push and another one after it, over the same change, with the same evidence.

Instead the existing landing gate moved. With `yolo` off on a push-capable project, the brief
stops the worker at its last local step, and Step 7 - the gate that already gathers the diff, the
log and the attribution scan and already renders them - is now held **before** the push rather
than after it. Approving it is the user's word for the outward step, and the surface says exactly
what that authorises. On approval the worker is still alive, so it is steered to finish with
`Send-HerdrPrompt`: the worker pushes, as it always did, rather than the Hand reaching into the
worktree.

The `local-only` blocks are untouched. For `direct-PR` the outward bullet is replaced with a stop.
For `no-mistakes` the gate runs with `--skip push,pr,ci`, which stops it at the last local step.

Two things about that split are easy to get wrong and are written down for it. **The approved run
still needs `$ci.briefLine`.** Holding the push back delays the CI wait rather than removing it -
the approved run is a full run and reaches the `ci` step - so Step 1b's answer is carried verbatim
into the bullet covering that second run. Dropping it reinstates the unbounded wait the preflight
exists to end, on exactly the repositories that cannot report a check. And **the steer differs by
mode.** A `direct-PR` worker pushes and opens the pull request itself; a `no-mistakes` worker has
to re-enter the pipeline, because a worker steered to push by hand goes around the gate's own
`push` and `pr` steps and everything they carry, and the result looks like a delivered pull request
either way.

### The `--skip` prohibition that had to be reopened

`muster` Step 2 said the flags were removed deliberately and "never add them back for a
`no-mistakes` project", on the reasoning that registering `no-mistakes` consents to the full
pipeline. That reasoning stands for the mode; it does not survive the King's new instruction,
because consent to the pipeline is not consent to run it unattended.

So the prohibition is narrowed rather than dropped: exactly one sanctioned use, `yolo` off, where
the flags are the stop itself. On a `+yolo` project they never appear. Adding them to shorten a
run, to get past a slow step, or because CI looks unlikely to report is still the misuse the
original line existed to prevent, and it is still named.

The cost is a second gate run on the resumed worker, which re-runs the local steps against commits
that have not changed before pushing. That is the price of holding the push back and it is the
intended one. **A future change must not pay it off by dropping the flags at dispatch** - that
puts the push back before the user, which is the whole defect.

## What a future change must not undo

- `+merge` defaults off, and an annotation the parser could not read in full never yields it -
  whichever token was the unreadable one, and whatever order it was written in. A default that
  flips on for convenience is a merge nobody authorised on a branch that may deploy. Merge is the
  strict one there while mode and yolo keep their existing leniency, deliberately: an unrecognised
  token has never changed either of those, and this was not the change to make it.
- Unreadable stays unreadable. `Get-ProjectEntry` throws; it never substitutes `'off'` for
  "could not tell". The warnings say what was ignored and what it cost, never what state resulted -
  a warning claiming a value the code did not set is read as a lost permission on an entry that
  still has one.
- The merge stays decided at Step 7 and performed at Step 8a. Folding it back into one step puts
  the decision where no pull request exists.
- `+merge` stays out of the mode set and out of `Get-ProjectPosture`'s string. Putting it in
  either makes it look like a posture, which is the thing it is not.
- The merge procedure is GitHub-only, and it is bounded at the step rather than at registration:
  nothing stops an Azure DevOps origin registering `[direct-PR +merge]`, so where `gh` cannot
  resolve the repository the merge is the user's and Step 8a stops. A future change must not
  substitute a web API or a push to the default branch for the missing `gh`.
- The named outward set keeps its open-ended clause stated as the rule.
- `emgeelabs-site` does not get the permission.
