# 2026-09-10 - one rules file for a family of projects

## What was decided

A registry entry may carry a `+family:<name>` token. Every project whose entry carries it gets
`data\rules-<name>.md` attached to every brief dispatched into it, beside that project's own
`data\rules-<project>.md`, with no one passing either.

The problem it removes is duplication with no owner. A set of repositories that work the same way -
one ticket tagging scheme, one work item workflow, one branch convention, one pair of accounts -
had nowhere to put a shared fact. It had to be repeated in each project's own rules file, where the
copies drift the moment one is edited, or written down once somewhere no brief names, where it
reaches nobody. That second outcome is the failure the whole read-first mechanism exists to close,
arrived at from a different direction.

## Why a token and not prose

The same reasoning `docs\2026-09-04-outward-gating.md` recorded for `+merge`, and it is worth
restating only in the one place it differs. A family has to be **read by a program** - the
dispatcher composes a file name from it - so it cannot live in the entry's free-form description.
Reading prose for a file name is what standing criterion 12 forbids, and it has no bounded case
space.

The token's own grammar is deliberately as narrow as the tokens beside it. The name after the
colon becomes `data\rules-<name>.md`, so it is held to the shape `bin\Index.psm1` already owns for
a name that becomes a file name - letters, digits, `.`, `_` and `-`. That is asked of Index.psm1
rather than copied into the registry parser, for the reason the parser's own comment gives: two
copies of one validation drift the moment either is edited.

## No family is the empty string, never a word

`Get-ProjectEntry` reports `family` on every entry, and it is the empty string where none is
declared. That is the ordinary state for most projects, so the key is always present and a caller
reads it without testing for it.

**It is not a word**, and this is the load-bearing half. A state word - `none`, `off`, `default` -
composes into `data\rules-none.md`, which somebody could perfectly well have written, and the
dispatcher would go looking for it and attach it. The empty string is the one value that cannot be
mistaken for a family whose file should be fetched.

## Strictness: family goes with merge, not with mode

The parser is lenient about the mode and about `yolo`, and strict about `+merge`. The family joins
`+merge`:

- An annotation this parser could not read in full yields neither the permission nor the family.
- An unknown mode drops both with everything else the annotation granted.
- A `+family:` token whose name could not be a file name declares no family, and forces merge off
  with it, exactly as any other unrecognised token does.
- A second `+family:` on one entry is the same: a project belongs to one family, so a line naming
  two has not said which, and guessing would hand a worker another set of repositories' conventions
  with nothing to show it had happened.

The failure direction that strictness chooses is "no family", which is an ordinary state a project
dispatches perfectly well in. The direction it refuses is a family taken from a line the parser
demonstrably could not read.

An installation whose `projects.md` carries the token while its `bin\` predates it keeps working:
the older parser sees an unrecognised `+` token, warns, forces merge off, and keeps the mode - so
nothing is silently lost but the permission, which is the direction that was already chosen.

## The precedence sentence lives in the composed line, and is unconditional

Where the family's file and the project's own disagree, the project's own wins - it is the more
specific of the two. That is stated in the `Read first` line the dispatcher composes for the family
file, because that line is the one place a worker holding both will read it, and a worker left to
work out which source wins picks wrong half the time.

**It does not vary with whether the project's own rules file exists.** That is not cosmetic. The
dispatcher finds the line an earlier dispatch wrote by composing exactly the same text again and
comparing whole lines. A wording that depended on another file being present would be composed
differently on the dispatch that retires it, so the old bullet could never be found - and it would
sit in the brief naming a copy that had been deleted, which is worse than the staleness the pruning
exists for.

## Retiring a family: the copy is the only record

The two per-project files can always be retired, because the project name survives the file: the
dispatcher composes `rules-<project>.md` from the registry every time, and can therefore compose
the line it once wrote even after the file is gone.

Removing a `+family:` token is different. With the token gone, the family name is gone with it, and
there is nothing left in the registry to compose the retired line from.

The candidates come from **the staging directory** instead - `data\<id>\read-first\rules-*.md`, the
copies an earlier dispatch made itself. That is a listing of real file names, not anything read out
of the brief's prose, so it introduces no parser. Each candidate leaf is turned back into the line
this dispatch *would* have composed for a family of that name, and the decision is the same
whole-line comparison the per-project pruning already makes, against wording nothing else writes.

Three guards keep it off files that are not the dispatcher's to touch:

- a leaf still in the current standing set is live, and the per-project loop owns its retirement;
- a leaf the Hand passed on this dispatch is the Hand's, copy and line both;
- a name the index could not turn into a file name was never a family, because the registry parser
  drops such a token rather than reporting it.

A leaf that was never a family's composes a line that is not in the brief, and is left where it is.

## What a future change must not undo

- **The dispatcher never reads a file name out of the brief's prose.** Everything above is either a
  whole-line comparison against text the dispatcher composed, or a directory listing. The six-round
  path parser recorded in `docs\2026-08-31-read-first-declared-not-parsed.md` must not come back
  through this door.
- **The family's file does not discharge the index gate.** It is discounted with the project's own
  two, and for a stronger reason: a path that arrives on every brief for every project in a family
  would switch the gate off for the whole family at once.
- **A project in no family dispatches byte-identically to a build without this change.** The
  lead-in the dispatcher writes above its bullets is unchanged, deliberately: changing it would give
  a brief written before this change a second lead-in on its next dispatch, and the wording is not
  made false by a family file, which is attached because of this project's own registry entry.
- **A project declaring a family of its own name has one file, not two.** The leaf collides, and it
  is attached once under the project's own wording, because a copy is not staged twice and there is
  nothing for a precedence sentence to be about.
- **A family name that is a DIFFERENT project's name is refused, at registration and again at
  dispatch.** `data\rules-<family>.md` would otherwise be that project's own standing rules, staged
  for a sibling under a line calling them shared. The refusal is load-bearing for that wording: the
  composed line asserts the file holds what every project in the family shares, and this is what
  makes the assertion true, so a change that drops or weakens it has to reword the line as well.
  Registration alone cannot close it, because a project can be registered after the family was
  named - hence both ends. A family named after the project declaring it is exempt: there is no
  other project's material in that file, and it collapses to the one attachment above.
