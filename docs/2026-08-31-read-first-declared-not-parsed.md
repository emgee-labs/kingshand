# Read first is declared, not parsed

2026-08-31

## What this replaces

`bin\Dispatch-Worker.ps1` used to read the brief's `## Read first` section, pull file paths out of
that prose, and compare the set it found against the paths handed to `-ReadPath`. The intent was
sound: the section and the parameter are written in two different steps, and prose was the only
thing tying them together, so a brief could name a copy nothing staged or stage a copy no line
named, and either way the worker ended up holding a path it could not open.

The mechanism was the problem. Over one run it took six consecutive review rounds, in this order:
refuse paths outside the worker's grant, read every path form rather than only drive-letter paths,
read whole paths rather than truncated ones, tighten the parsing, refuse spaced file names instead
of guessing where a path ended, and refuse spaced mentions while searching every index. Every one
of those findings was correct and every one of those fixes was right. That is the point: a path
written in prose can be absolute or relative, forward or back slashed, quoted or bare, contain
spaces, sit inside a sentence, or wrap across a line, so there is no round after which the parser
is finished.

Two of those rounds had already produced the failure mode a parser eventually reaches: refusing a
correct brief with a message naming a path nobody had written. One read a staged original as
running on into the words after it and lost its exemption; another read the leaf ` in` out of the
phrase "under read-first\ in this directory". A guard that refuses good work is not a safer guard
than none.

## What replaced it

The paths arrive structurally. `-ReadPath` takes the list, the dispatcher copies each file into
`data\<id>\read-first\`, and nothing reads the section's text for a path at all.

The reason this is not a weakening is that there was never a second source to reconcile against.
The Hand writes the brief and the Hand calls the dispatcher, in the same step, holding the same
list. Parsing the prose was the dispatcher asking the Hand a question the Hand had just answered,
and then trying to understand the answer in English.

**Do not reintroduce a parser here.** A future round that notices the section and `-ReadPath` can
still disagree has noticed something true; the answer is that muster writes them together, not that
the dispatcher should start reading English again.

## What still refuses, and why each one needs no prose

Five checks, all before a worktree or a branch exists, so a refused dispatch leaves no debris.

**The `## Read first` section must exist.** This is the check that closes the originating failure
described in `2026-08-30-data-index.md`: a brief that names no settled file at all, which passed
every set comparison because both sets were empty. A brief with nothing to read says so in one
line; a brief missing the slot says nothing, and only the first is a decision somebody made. It is
a regex against a heading - no path, no ambiguity. Fenced blocks are skipped, because a brief for a
task on muster's own template quotes that template and the quoted heading satisfied the check for a
brief that had no section of its own.

**An indexed dispatch was either handed a file or says the index was checked.** Added 2026-09-01,
because the section being present says a slot was filled in and says nothing about the index behind
it - an index of pointers nobody is obliged to follow is the same settled-spec failure at a larger
scale, and worse for looking solved. When any index that could cover the dispatch lists something,
it is refused unless at least one `-ReadPath` was passed or one line of the section states the index
was checked and nothing in it applies. Reading that one stated line is not the parser this document
forbids: it counts `-ReadPath` entries that arrived structurally, asks `Index.psm1` what each index
lists, and looks for a statement - never a file name - in the prose.

*Amended 2026-09-02.* One `-ReadPath` no longer counts towards it - the project's standing-criteria
file at `data\done-<project>.md`, which `muster` passes on every brief for a project that has one.
A path passed by rote is no evidence the index was read for this task, and counting it would have
made this refusal unreachable from the first criteria file onwards. That is still not a parser: the
path is compared as a path, against one the dispatcher composes itself.
`bin\Dispatch-Worker.ps1`'s header owns the exact rule, as `2026-08-30-data-index.md` already says.

**Every `-ReadPath` entry exists on disk.** A brief naming a file that is not there is a brief the
worker cannot carry out.

**No `-ReadPath` entry is a directory.** A directory would copy whatever happened to be in it.

**No two `-ReadPath` entries share a leaf name.** They would land on top of each other in the
staging directory and the worker would read whichever was copied last, with nothing to say the
other was ever named. The refusal says to pass one or copy it under a distinct name, and
deliberately does not say to rename: two reports really are both called `report.md`, and that is
the name every index entry pointing at them already uses.

Each of those knows its path exactly, because the caller handed it over. That is the difference
between this list and the one it replaces.

## What is unchanged

The staging copy itself, the single grant it protects, the exclusion of `read-first\` from the
drift count, and the whole index design in `2026-08-30-data-index.md`. Nothing here reopens any of
it. What came out is one cross-check, not the mechanism it was guarding.
