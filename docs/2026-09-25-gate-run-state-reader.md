# One reader for a gate run's state, and why it decodes rather than matches

Date: 2026-09-25
Status: **current**

## What this records

Nothing in `bin\` read `no-mistakes axi status` before, so every session invented its own parse of
that output by eye - and the eye was wrong every time anyone measured it. On 2026-09-10 one run's
state was reported wrongly three times in a single session: a pull request called open when nothing
had been pushed, the run called parked when it was mid-fix, then parked again when the review step
had already completed. On 2026-09-24/25 the same session hand-wrote four different watch conditions
over the same output. Two fired falsely - one by matching `outcome:` inside the tool's own help
text, one by reading a park that had been there before a steer was sent as though it were the answer
to that steer - and a third was keyed on the branch head moving, which a park does not do, so it
missed a parked run for two hours and twenty-six minutes.

One cause runs through all of it: state inferred from something next to the state instead of read
from the field that states it.

`bin\GateRun.psm1` is the one reader. This note records what was considered, what was rejected, and
what a later change must not undo. The module's own header owns the mechanics.

## Standing criterion 12 is the whole design question here

The command has no JSON mode. `axi status --help` offers only `--run`, so there is no flag that
turns the answer into something already structured. `axi` with no subcommand is leaner to read, but
it answers a different question: a list of recent runs, with no per-step statuses, no
`awaiting_agent` and no findings. It cannot support a reader whose entire point is telling those
three apart.

So the output arrives as TOON, and the question is what is allowed to read it.

**Two TOON libraries exist, and both were tested against real captured output rather than taken on
their description.** The PowerShell one on the gallery returns a confidently wrong partial object
for a real capture - the entire run block silently dropped, no error raised. That is worse than
having no library at all, because a wrong answer arrives looking exactly like a right one, which is
the failure mode this whole module exists to remove. The JavaScript reference implementation decodes
the same capture exactly.

**A hand-written reader was rejected on evidence, and this is the part most likely to be undone by
someone who does not know why it is there.** From a distance the format looks like indented keys and
comma-separated rows, and the obvious move is to split the rows with `ConvertFrom-Csv`. It does not
work. A review finding's `description` is free text a reviewer wrote, and TOON quotes it with its
own backslash escape set - `\"` for a quote, `\\` for a backslash - rather than CSV's doubled quote.
So the row split cannot be delegated, and it cannot be done by hand without reimplementing that
escape set, the indentation rules, the declared row and item counts, and per-array delimiter
scoping. That is a general parser for a format whose input set never closes, which is the criterion
12 failure outright.

**So the decoder is vendored and nothing in PowerShell reads TOON at all.** `bin\assets\toon\`
holds the reference implementation verbatim with its MIT licence, and `decode.mjs` beside it turns
one document into JSON. Everything above reads only that JSON - the same boundary `bin\Usage.psm1`
keeps to `quota-axi`'s JSON and `bin\Ci.psm1` keeps to `gh`. Node is already a hard prerequisite of
this installation, because `lavish-axi` and `tasks-axi` are npm packages and `install.ps1` installs
it for them, so this adds a file rather than a class of dependency. It is vendored rather than
installed because it is a single file with no dependencies of its own, and a reader that stops
working when a global package is missing is a reader nobody can rely on.

Strict decoding is the decoder's own default and is left on deliberately: it enforces the row and
item counts each table declares, so a truncated capture raises an error instead of arriving as a
short table that looks complete.

## Where the output cannot be read, there is no state

Three statuses, and the third is the point: `has-run` and `no-run` are answers, `unreadable` is the
refusal to guess. Nothing turns a failed read into a state word or into an empty run. That is
standing criterion 7, and it is the reason this class of bug exists at all - a watcher that could
not see a park reported none.

The same rule holds inside the reading, not only at its edges. A value the output carries but this
reader does not recognise is reported as unrecognised, never quietly folded into the nearest state
word it resembles.

## What a later change must not undo

- **Never apply a pattern to the whole output.** The tool's own `help[]` block contains `outcome:`,
  `approve` and `push`, so any match over the whole document finds help rather than state. Nothing
  here matches over the whole document, which makes that structural rather than a rule somebody has
  to remember.
- **Never infer a park from a finding count.** `run.findings` is a residual summary string that
  survives findings being declined: a real cancelled run on this repository still reads
  `findings: "1 awaiting, 1 auto-fix"` with every step terminal and nothing waiting on anybody. It
  is carried through as `findingsSummary` and nothing computes from it.
- **No read that decides or reports anything bypasses the primitive.** A key is read by
  presence; a value in a shape the reader cannot take is named rather than collapsed into absent.
  That is the rule in its final form, and it is stated as a rule about reads rather than about
  fields because **it took seven instances across five review rounds to get there.**

  The seven: `awaiting_agent` matched only the documented `parked <duration>` wording, so any
  other wording read as not waiting. `gate:` was read as a scalar, so the live tool's nested
  object read as no gate and a response carrying six findings read as none. `gate:` presence was
  then taken from the value's shape, so a third shape fell through every arm. `awaiting_agent`
  fell to the same thing again by truthiness. The findings table was dropped row by row, so a
  gate carrying `findings[2]: r1,r2` reported a parked run with nothing to decide. `Read-ToonTable`
  named a shape only when rows were lost, so a `steps:` mapping - which loses none, because none
  arrive - read as a run with no pipeline. And `outcome` was read by value, so a finished run read
  as unfinished.

  **Every one of those fixes was correct and every one held. The rounds kept coming anyway**,
  because each fix was about a field and the defect was never in a field. It is in any read that
  decides something through an accessor whose answers cannot tell "absent" from "present but not
  understood" - `Get-ToonText` returns `''` for both, `Get-ToonNumber` returns `$null` for both,
  `Get-ToonRows` returns no rows for both. Counting instances is what turns that from a series of
  bugs into one rule.

  So every key goes through `Read-ToonField`, `Read-ToonList`, `Read-ToonTable` or
  `Read-ToonCells`, which answer three ways rather than two, and anything of the third kind is
  named on `notUnderstood` and in `detail`. The three accessors still do the taking and are
  reached only through those four. A field that falls silent is the failure; one that says "I
  could not take this" is not. **Do not add a read that goes straight to an accessor** - that is
  the move that produced all seven, and the test over every known key is there to catch the
  eighth.
- **Never read a present `awaiting_agent` as not waiting.** The field's name is the tool saying
  what the run is waiting on. Treating an unrecognised wording, or a value in an unrecognised
  shape, as unparked is the same silent default in a safer-looking direction, and it is the
  direction that cost two hours and twenty-six minutes.
- **Never let a declared table whose entries are not objects become rows.** `steps[2]:
  intent,review` is valid TOON - a list of two strings rather than two rows of fields - and reading
  it row by row yields two steps whose every column is empty. That is a run reported confidently in
  a shape nobody sent, which is the same fault as merging the two step lists, reached from the
  other side. Dropping those entries in silence is not the fix either; the table is named as
  unreadable.
- **Never merge or deduplicate `steps[]` and `active_steps[]`.** They describe different things -
  what each step of the pipeline did, and what one currently running step is doing right now -
  and merging them produces rows with neither shape's columns.
- **Never replace the decoder with hand-written parsing**, whatever the format looks like from a
  distance. The argument above is the reason, and it does not weaken as the parse gets cleverer.

## Evidence that decoding was the right call

It was tested almost immediately, and not by design. The shipped documentation for this format was
already out of date about the `gate:` value: it shows a scalar step name, while the live tool emits
an object carrying `step`, `status`, `risk`, `note` and its own findings table. The first version
written to the documentation lost the whole gate answer - the step name came back empty, so the park
had nowhere to point, and a response carrying six findings read as none.

The first fix read the field in both shapes. That was not enough on its own and is not how the code
works now - the rule above is, and `gate:` is read by whether its key is there, with the object and
the scalar being two shapes it knows how to take and anything else named as unreadable. What matters
as evidence is that each correction was a change to which named fields are read, not to how the
format is parsed, because the reader works on a decoded document rather than on text it matches. A
hand-rolled parser would have needed its grammar reopened for the same drift. Where the live tool
and the documentation disagree, the live tool is the authority - and the reader is built so that
finding out costs a few lines.
