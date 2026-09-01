# The data index - an index, not a classification

2026-08-30

## What went wrong

On 2026-08-29 the whole Emgee Labs brand was settled in one session: logo, favicon, tagline, both
theme palettes, the homepage headline verbatim, and a list of things never to put on the page. It
was written to `data\emgee-brand.md`, whose own first line says "This is the input to the website
brief."

On 2026-08-30 the site was built and shipped live with none of it. No logo, no favicon, no tagline,
none of the settled palette. It was found by looking at the page.

Nothing was lost and nothing was overruled. The file was simply never read, because nothing made
anyone read it. A worker sees exactly one thing - its brief - and no brief named the file.

## The design that was rejected

The first answer was a category: define "a settled decision that a future brief must carry", give
it a home at `data\decisions\`, list it in the digest, and require brief-writing to look for one.

It was rejected, correctly. Classifying a file as important at the moment it is written means
guessing what some future task will need. That guess is wrong regularly, and a wrong guess is
silent - the file is simply not in the special place, so nothing looks for it and nothing reports
that anything is missing. That is the same failure this whole change exists to fix, wearing a
different hat.

## The design that shipped

An index. Every durable file under `data\` gets one line recording where it is and what it is.
Nothing is judged important or unimportant at write time; everything is listed. The judgement moves
to read time, where the reader knows exactly what they are working on and opens the handful of
files their own task touches.

Four things make it work, and removing any one of them puts the failure back.

**It is a table of contents, never content.** Path, one line, date. A reader pays one line per file,
not one file per file. `Add-IndexEntry` refuses a summary over 160 characters rather than truncating
it, because a silently cut summary is a summary that lies, and because a cap is the only thing that
keeps a table of contents from growing into a second copy of the data.

**It is scoped per project.** `data\index\<project>.md` holds one project's files;
`data\index.md` at the root holds kingshand's own operational files. The project is the cut because
the project is the unit a brief is written against - an index spanning every project hands a
website worker the aegis reports, and an index nobody can scan is an index nobody reads. The root
index is a file beside the directory rather than a reserved name inside it, so no project name can
ever collide with it.

*Amended 2026-09-01.* In practice the settled files this design exists to deliver land in the ROOT
index, not in a project one: `chronicle`, `annex` and `survey` all index with no project, so an
unscoped `data\<topic>.md` goes to `data\index.md`, while `data\index\<project>.md` holds little
beyond briefs and reports. One look at the live installation is the evidence - `data\index\` did
not exist at all while `data\index.md` held real entries - so the dispatch gate added that day
could never have fired while it consulted the project index alone, and it reads both.
`bin\Dispatch-Worker.ps1`'s header owns that gate's rules. Nothing about how the index is written
or scoped changed; this is a correction to the record.

**Indexing is part of writing, not a separate act of virtue.** `Write-DataFile` writes the file and
indexes it in one call, so the two cannot come apart. Where another tool owns the write -
`tasks-axi` writing the backlog, a worker writing its own `report.md` - `Add-IndexEntry` records it
at the first moment somebody has both the file and the context to describe it, which is why `muster`
indexes a brief in the step that writes it and a report in the step that reads it. A rule that says
"remember to add it afterwards" is exactly the rule that was forgotten last time.

**The gap is visible.** `Get-IndexDrift` counts the files under `data\` that no index lists, and the
session-start digest prints that count. This is the part that makes the whole thing self-checking,
and it is the reason an index beats a classification: "this file is listed nowhere" is a fact a
machine can notice, where "somebody should have realised this mattered" never was.

**And it has to be clearable from both ends.** The digest also prints `STALE:`, the entries whose
file is gone, and that half had no remover at first - a dated `/survey file` artefact is written to
be deleted, so every deletion cost one permanent line of noise and took the whole number with it.
`Remove-IndexEntry -Missing -All` prunes them. The same argument that says a drift count growing by
one per dispatch is a count nobody reads says a count nothing can take to zero is not a signal.

## What is deliberately not in it

No exclusion is a judgement about a file's worth. The test each one passes is derivation: the file
is produced from something else that is itself listed, so an entry would record the same fact
twice. An index does not index itself. A rendered `*.html` review surface is regenerated from
state rather than read as a source. A `read-first\` copy is the snapshot dispatch takes of a file
that already has its own entry at its own path, so that its worker can reach it at all.

The count is not the rule; the test is. Guarding a number would have taken the drift signal down
instead: `read-first\` arrived after this note was first written, and with only "there are exactly
two" to go on, the choice was between a drift count that grows by one per dispatch forever - a
count nobody reads - and indexing each copy, which would put a duplicate entry in the table of
contents for a file already listed. An exclusion that cannot answer "derived from what?" is the
rejected classification creeping back in one file at a time, and that is what must not be added.

The digest prints counts and the location, never a file list and never a file's contents. The
startup-memory budget accounts for `king.md` and `learnings.md` only; the index is not printed in
full and is not accounted, which is what keeps a growing index from becoming a growing session-start
cost.

## What still has to move

`data\emgee-brand.md` is where it was. It is live evidence of the failure and was left alone
deliberately. It wants an entry in `data\index\emgeelabs-site.md`, and until it has one the digest
counts it as drift - which is the mechanism working, not a defect.
