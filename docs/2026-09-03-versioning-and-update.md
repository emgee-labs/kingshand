# Versioning kingshand, and updating to a release

Date: 2026-09-03
Status: **current**

## What happened

Kingshand had no version. Not a stale one, not an implicit one - nothing anywhere said which copy
of it you were running, and `git pull` was the only way to move forward. Three things followed from
that, and all three had already happened.

Nobody could answer "which version am I on". A user told a fix had landed had no way to tell
whether their copy had it, and neither did anyone helping them: the only honest answer available
was a commit hash nobody had memorised.

`git pull` takes whatever was pushed last. On this repository that is a worker's merge, sometimes
minutes old, sometimes the middle of a series that is not finished yet. There was no way to ask for
a release, because nothing had ever been marked as one.

And an update could land on top of a working worker. Pulling `bin\` and `.claude\skills\` out from
under a running agent changes its instructions and its tooling mid-task, and nothing was checking.

## The decisions

### One `VERSION` file at the repository root, and nothing else holds the number

The file holds the version and nothing else. `bin\Version.psm1` reads it, validates it and is the
only place that knows where it lives. No script, skill, document or manifest carries a second copy:
a version written down twice disagrees with itself the first time somebody edits one of them, and
neither copy says which is right.

It started at `0.1.0`, on the working release before the first tag was cut.

An unreadable file is a refusal, never a guess. Absent, empty and holding-prose are three distinct
failures and each says which one it is. The session-start digest prints one `VERSION:` line and,
when the file cannot be read, prints `VERSION: unreadable` with the reason - because a fabricated
`0.0.0` is a number a reader would repeat back as the version they are running.

### `/update` moves to the latest TAG, never to a branch head

This is the decision the whole feature rests on. A tag is a release somebody decided to cut. A
branch head is whatever happened to be pushed last.

It also makes an update independent of which branch is default. A repository that moves its default
branch, or changes what pull requests target, does not change what `/update` does - which matters
here, because that separation was being made in a different piece of work at the same time.

The highest version tag wins, and **reachability is deliberately not checked**. A tag that cannot
be fast-forwarded onto the release branch is refused by `git merge --ff-only`, which is the honest
outcome. Filtering such a tag out instead would silently select an *older* release and report it as
the latest, and that is the one wrong answer here nobody would notice.

**There were zero tags when this was written, so the no-releases path is the common path.** It
refuses by name - no release has been tagged yet - and never falls back to pulling a branch,
inventing a version, or reporting success. `/update` shipped before there was anything to update
to, and that refusal is what makes shipping in that order safe.

### Four refusals, and none of them is an edge case

A dirty working tree, any live worker, a checkout that is not on the release branch, and a
repository with no releases yet. Each stops the update where it stands and names itself, and each
has a test that forces it.

**Live workers are read from herdr, never from `state\crew.json`.** The durable record says what
was intended; herdr says what is actually running. They disagree exactly when it matters - a worker
recorded as torn down but still alive is precisely the case this guard exists to catch - and
`CLAUDE.md` states that precedence. A herdr that cannot be reached is *unknown*, which is not the
same as none, so it refuses too.

**Fast-forward only.** Never a force, a stash, a reset, a rebase or a non-linear merge. An
installation that has diverged holds work nobody here may discard, so it is refused with git's own
reason and left exactly as it was. This half is taken from firstmate's `updatefirstmate`, which
solved the same problem for the project kingshand was derived from; its other half, nudging a fleet
of sub-agents to re-read their instructions, has no equivalent here because an update refuses
outright while any worker is live.

### "What changed" is the commit subjects between the two releases, and there is no parser

Commit subjects are already one-liners, written by the pipeline that produced them, so reporting
them needs no new discipline from anybody - and no changelog file, no Markdown renderer, and above
all no parser. A hand-written parser for an open-ended text format is the most expensive mistake
this repository has made, at roughly sixteen review rounds across two tasks. A `CHANGELOG.md` would
have been exactly that shape again. Merge commits are left out, because a merge subject names the
branch it merged and says nothing about what the release contains.

### The user's own state is never protected by machinery, because git already ignores it

`data\`, `state\`, `config\`, `tools\` and `instructions.md` are all in `.gitignore`, so no fetch
and no fast-forward can reach them. Verified 2026-09-03. Nothing in the update path copies, backs
up or restores any of it, and adding that machinery would mean maintaining a second, weaker copy of
a rule git already enforces.

## Cutting a release

The release branch is `main` and the integration branch is `dev`. `bin\Update.psm1` holds `main` as
the enforced release branch; this section is where the procedure lives.

Work reaches `dev` through pull requests. When the features on `dev` have stabilised - roughly
weekly - `dev` is merged into `main`. **That merge is the release.** The tag is cut on it, as one
more step in a thing already being done, rather than as a separate ceremony on its own schedule.

So, in order:

1. Decide the version. Edit `VERSION` on the branch being released, and let that edit reach `main`
   with the rest of the work. Patch for fixes, minor for anything a user would notice - a new
   skill, a new command, a changed contract.
2. Merge `dev` into `main` the way you already do.
3. Tag the merge commit on `main` with `v` and the version from the file: `git tag v0.1.0`, then
   `git push origin v0.1.0`.

The tag name is `v` plus the version in `VERSION`, and the two must agree: `/update` reads the
version out of the release's own `VERSION` file rather than off the tag name, and a tag whose file
cannot be read is refused rather than reported.

Nothing automates any of this, deliberately. A release is a judgement about whether the work is
ready, and the only mechanical part - the tag - is one command in a procedure that already exists.

## What a future change must not undo

- **The version stays in one file.** A second copy anywhere is the drift this was built to remove.
- **Updates stay tagged.** A fallback to a branch head, however convenient, removes the only thing
  that makes an update deliberate. If tags ever cannot work, the replacement has to keep releases
  deliberate rather than pulling whatever is newest.
- **The four refusals stay refusals.** In particular, nothing may convert "cannot tell whether a
  worker is live" into "no workers are live".
- **No changelog parser.** If the commit subjects ever stop being enough, change what is reported
  rather than writing something that reads free-form prose.
