---
name: writ
description: Reference procedure for the work item behind a pull request - offering to move it to its in-review state and attach the pull request as a link, never a comment. The Hand loads it at muster's close-out once a pull request for work that came in as a work item is confirmed on the remote, after a fief session's pull request is confirmed the same way, and whenever the King asks to link a pull request to a work item, move one to in review, or update a ticket after a pull request - e.g. "update ticket 1234", "link the PR to the ticket", "move it to in review". One question first; a no changes nothing.
version: 1.0.0
---

# Writ

When a pull request goes up for work that has a work item behind it, the item should say so: moved
to its in-review state, with the pull request attached as a link. This skill is how the Hand offers
that and, on a yes, does it. **The Hand loads it; a worker never does** - every step here reaches
the work item tracker, and a worker's brief forbids creating or updating a work item.

`bin\WorkItemLink.psm1` makes every call that reaches the tracker, and its header owns the
parameters and the outcome words. Nothing here hand-builds a request body, an auth header or a
cache write, and nothing may start: **every write goes through that module.**

## When it fires

<!-- rule:writ/offer-after-pr -->
**At `muster` Step 8a, once the pull request is confirmed on the remote, for work that came in as a
work item.** That is the worker's record: `kind` is `ticket` and `ticket` is a work item number,
digits and nothing else. The pull request has to exist before it can be linked, so this is the
first point the offer can be made, and teardown does not wait on the answer. **A `fief` session's
pull request is the same moment**, once it is confirmed on the remote, and the same test runs on
each item its branch carries - `fief`'s `## Delivery` makes that offer.

**Work that came in as `adhoc` gets no offer**, and that is what keeps it off projects with no work
item behind their pull requests - the intake already recorded which kind of work this is, so no
per-project setting is needed to say it again. **Never take the id from a branch name or a slug.**
A slug that happens to carry a number is still adhoc work; where the King wants that item updated,
he asks, and you ask him which item if this session does not already know.

The King can also ask for it directly at any time. Take the id from what he said, or from this
session where it plainly names the item; otherwise ask him for it.

## Before the question

Check the two things the work depends on, so he is never asked a question that cannot be acted on:

```powershell
Import-Module $env:KINGSHAND_HOME\bin\WorkItemLink.psm1 -Force
Get-WorkItemConfig -Root $env:KINGSHAND_HOME | Out-Null
[bool]$env:ADO_MCP_AUTH_TOKEN
```

**Where either fails, say so in one line - what is missing - and make no offer.** A missing token is
a machine not set up for the tracker; a missing `review` block is one nobody has told which types
and states this applies to. Neither is guessed at.

The `review` block sits in `config\ado.json` beside the organization and project `muster` Step 1
reads, and it is the only place those names live. `config\` is gitignored, so the names stay on this
machine. An example - use your own process's type and state names:

```json
{
  "organization": "your-ado-organization",
  "project": "Your ADO Project",
  "review": {
    "types": ["Task", "Bug"],
    "moveFrom": ["New", "Active"],
    "target": "In Review",
    "alreadyDone": ["In Review", "Resolved", "Closed"]
  }
}
```

`types` is every work item type the move applies to, `moveFrom` the states it moves out of,
`target` the in-review state, and `alreadyDone` the target and every state past it.

## The offer

**One question, with the item id and the pull request in it** - move #<id> to <target> and attach
<full https:// URL> as a link? **A no is a complete answer and changes nothing** - no hold, no
second asking, nothing written.

**It is asked on every posture, `+yolo` included.** He asked for it to be asked, and both the move
and the link reach a server, so hard rule 2 [rule:claude/landing-authority] wants his word for
them anyway. It is a decision, so it renders like one, on the surface `muster` owns
[rule:muster/review-surface] - one item, his yes or no - and while `parley` is loaded it is a line
in chat instead, which that skill owns. **While regency or night's watch is in force it waits for his
return**, like any other write to a server; it is never answered in his stead.

## On a yes

Work these in order. Each one's outcome decides whether the next runs.

1. **Link it.**

   ```powershell
   $r = Add-PullRequestLink -Root $env:KINGSHAND_HOME -TicketId <id> -PullRequestUrl "<url>"
   $r.outcome; $r.reason
   ```

   - `refused` - the type is not one the configuration names. **Stop: nothing was written, and the
     state is not touched either.** Report the type, as the reason names it.
   - `guid-not-cached` - the tracker needs the repository's GUID and it is not cached yet. Go to
     step 2, then run this step again.
   - `already-linked` or `link-sent` - go to step 3.

2. **Find the repository's GUID - without asking.** A work item that already links another pull
   request from the same repository carries it. **The King has granted this lookup and the cache
   write standing, so neither is put to him, and the grant reaches nothing adjacent**: it is not a
   write to a work item, a state move or a comment.

   Take recent pull requests in the same repository whose title names a work item as `AB#<id>`,
   and hand every pair over. Each candidate is checked against that work item's own links. A link
   names no repository, so a work item shared across repositories can carry another one's pull
   request under the same number: the module sets aside any GUID already cached for another
   repository, and returns a GUID only where at least two candidates with different pull request
   numbers agree on it:

   ```powershell
   gh pr list --repo "<owner>/<repo>" --state all --limit 30 --json number,title
   $f = Find-RepoGuid -Root $env:KINGSHAND_HOME -RepoKey "<owner>/<repo>" `
        -Candidates @(@{ ticketId = <id>; prNumber = <n> }, @{ ticketId = <id2>; prNumber = <n2> })
   $f.guid; $f.matched; $f.unreadable; $f.reason
   ```

   With a GUID, run step 1 again with `-DiscoveredGuid $f.guid`, which caches it and links in one
   call. **With none, say so - not as a question.** There is not enough evidence to be sure of the
   repository's GUID, so the link cannot be made and nothing is cached. Where `unreadable` is not
   zero, also say how many candidates could not be read. A throw means the candidates disagree;
   report it and link nothing.

3. **Move the state.**

   ```powershell
   (Set-WorkItemInReview -Root $env:KINGSHAND_HOME -TicketId <id>).outcome
   ```

   `move-sent` means the move was sent. `already` means it was already in review or past it, so
   nothing was sent - report it as already fine. `unrecognised` means its state is in neither list,
   so it was left alone - report the state.

4. **Verify by reading it back.**

   ```powershell
   $v = Test-WorkItemReview -Root $env:KINGSHAND_HOME -TicketId <id> -PullRequestUrl "<url>"
   $v.verified; $v.linked; $v.stateOk; $v.url
   ```

   **This re-read is what verified means, and nothing before it is.** A write call coming back
   without an error is not success. Where either half fails, say which, plainly, and give `$v.url`
   for him to follow up by hand.

5. **Report it in chat**, in a few lines: the item and its type, the pull request, whether the link
   was attached or already there, the state it moved from or that it was already fine, and the
   re-read's result.

## When the pull request is not known

Asked directly with no pull request in hand, first read whether the item already links one -
`(Get-WorkItemStatus -Root $env:KINGSHAND_HOME -TicketId <id>).pullRequests` - and if it does, skip
the link and go to the state move. Its re-read in step 4 then leaves out `-PullRequestUrl`, so it
confirms that a pull request is linked rather than which one - there is no URL to name. Otherwise
search under the owner of the project's own remote:

```powershell
gh search prs --owner "<owner>" "<id>" --json repository,number,title,state,url --limit 10
```

None found means there is nothing to link: say so and stop. **More than one found is listed and put
to him** - the repository, number, title, state and URL of each - because a number turning up in a
title can be a coincidence. **Never link more than one silently.**

## Never

- **Never proceed for a type the configuration does not name.** The module refuses before any
  write; report the type it names.
- **Never add a comment.** Results are reported in chat only. The module has no call that could
  post one.
- **Never move a state backward or re-apply one.** Only a `moveFrom` state moves; anything in
  `alreadyDone` or in neither list is left exactly as it is.
- **Never link more than one pull request silently.**
- **Never guess the work item id from a branch name.** Ask.
- **Never report success without the re-read confirming both the link and the state.**
- **Never hand-construct the request body or the cache write.** Go through `bin\WorkItemLink.psm1`.
