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
- **Never read a non-empty `awaiting_agent` as not waiting.** The field's name is the tool saying
  what the run is waiting on. Matching only the documented `parked <duration>` wording and treating
  every other value as unparked is the same silent default in a safer-looking direction, and it is
  the direction that cost two hours and twenty-six minutes.
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

The fix was to read the field in both shapes. It was a change to which named fields are read, not to
how the format is parsed, because the reader works on a decoded document rather than on text it
matches. A hand-rolled parser would have needed its grammar reopened for the same drift. Where the
live tool and the documentation disagree, the live tool is the authority - and the reader is built
so that finding out costs a few lines.
