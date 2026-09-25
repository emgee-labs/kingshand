# The away journal, and the digest rendered from it

Date: 2026-09-25
Status: **current**

## What this records

While the King is away, everything that happens - what landed, what broke, what a worker is blocked
on, what was decided in his stead - used to be accumulated in the Hand's session, and the return
digest was composed from that. A restart before he came back took the account with it while the
work itself survived. `regency` already admitted as much in writing and did not fix it.

The fix is a durable journal written as each outcome happens, and a return digest rendered from that
file. `bin\AwayJournal.psm1` owns the mechanics and `regency` owns the procedure; this note records
why the shape is what it is, and what a later change must not quietly undo.

**The failure it removes is silent, which is why it was worth building first.** Every other way an
away period can go wrong is noisy - a worker throws, a prompt box refuses, a wait reports a stall. A
digest lost to a restart produces no error at all. The King simply gets a thinner report and has no
way to tell that it is thinner.

## Why `data\` and not `state\`

Both are gitignored and the Hand may write to both, so this is a question of which shelf rather than
of access.

`state\` holds what the Hand owns **and reconciles against reality**: `crew.json` is intent to be
checked against herdr, and `.afk` is a mode flag that is true until the King speaks. Everything
there is about the present, and recovery's whole job is to make it agree with the world again.

A journal is about the past. Nothing reconciles it, nothing supersedes a line in it, and its readers
outlive the period it describes - the King on return, and anyone later auditing a call taken in his
name. That is what `data\` is for, beside `report.md`, `backlog.md` and `done-archive.md`.

The decision to keep the file, below, settles the rest: a directory that accumulates history forever
does not belong in the one recovery is expected to reconcile.

## Why it is kept on return rather than cleared

Clearing it at return is tempting because the digest has been delivered and the file has done its
job. It is the wrong direction.

The journal's `decided` records carry what was decided in the King's stead, with the reasoning and
whether the call rested on a position he had already stated or on the Hand's own judgement.
`petition` requires that flag precisely so the decision is **reviewable** - and the review happens
after the digest, not during it. Deleting the record at the moment it becomes reviewable destroys
the audit trail exactly when it starts being worth something.

Against that, the cost of keeping it is a few kilobytes per away period in a gitignored directory,
and a deletion is the kind of act kingshand does not do casually in any case. The away period's end
is already recorded by the flag coming off; nothing needs the journal to disappear to say so.

## One file per period, named from the flag

The file is `data\away\<stamp>.jsonl` and the stamp comes from `state\.afk`'s own `since:` line.
That single rule answers two requirements at once:

- **A second away period cannot overwrite the first's record.** A different period has a different
  `since:`, so it has a different name.
- **A session that restarts mid-period appends rather than starting over.** The same `since:` gives
  the same name, the existing file is found, and its header is checked before a byte is added.

The stamp is **re-rendered from a parsed timestamp**, never copied out of the file. So no byte of
file content reaches the path: the name can only ever be digits, `T` and `Z`, and a `since:` that
does not parse is refused rather than sanitised into a name pointing at the wrong period.

The header carries the format marker, its version and the period's `since:`, and every append checks
all three. A file that happens to land on the same name, or a journal belonging to another period,
is named in an error instead of being written over.

**A refresh keeps the original `since:`.** `/regency` while already away refreshes the mode rather
than starting a new one, so rewriting the flag with a fresh timestamp would split one period's
journal in two. `regency` spells the rewrite with `Get-AwayFlag` so the old value is carried across
mechanically.

## JSON Lines, not Markdown

Standing criterion 12 forbids a hand-written parser over an open-ended text format, and it was
earned over roughly twenty-two review rounds across three tasks. A Markdown journal would need
exactly such a parser to render a digest from.

So the journal is one JSON object per line: written by `ConvertTo-Json -Compress`, read back by
`ConvertFrom-Json`. The only hand-written step is splitting on newlines, and that input set is
closed because the writer escapes every newline inside a record. A line that does not parse is
counted and named, never skipped - a partially read journal that silently drops the one record that
mattered is the failure this whole file exists to remove.

The `kind` field is a closed set enforced by `ValidateSet` on the writer, which is what keeps the
reader's case space bounded. A kind read back that is not in the set is reported under its own name
rather than dropped into a bucket that hides it.

One consequence worth naming: `ConvertFrom-Json` recognises an ISO-8601 string and hands back a
`DateTime`. Rendering that with `[string]` uses the machine's own culture, which made a journal's
header disagree with the flag that named it. Every field is re-rendered round-trip on the way out.

## What enforces what

Standing criterion 13 asks, for every rule a change adds, who is supposed to obey it and what they
are doing at the moment it applies. For this change the answer is the Hand, between wakes, and the
mechanisms are these:

- **The digest cannot silently fall back to memory.** `Get-AwayDigest` returns `readable = $false`
  with a `summary` sentence written by the module when there is nothing to render from. There is no
  path that returns a digest-shaped success without having read a file, and the words the King sees
  in the failure case come from code rather than being composed over an absence.
- **An empty away period is a different answer from a lost one.** `regency` opens the journal when
  the flag is written, so a period that produced nothing has a header and no records and reads as
  "Nothing needed you", while a period whose journal was never opened reads as unreadable.
- **Nothing can be back-dated.** The `at` timestamp is stamped by the writer and cannot be supplied.
- **Nothing can be written outside an away period.** The path comes from the flag, so once the King
  is back and the flag is gone the journal is closed. A journal assembled at return time is not
  merely discouraged, it is not writable.
- **The return digest is read before the flag comes off**, because the flag is what names the file.
  `regency`'s return steps are ordered that way for that reason.

The one thing prose still carries is the habit of writing a record at each wake at all. Code cannot
force a write that never happens; what it can do is make the write cheap, make a late one visible,
and make an absent journal say so instead of rendering an empty one. It does all three.

## What this does not change

The journal is a record and never an authority. Writing an outcome down grants nothing, moves no
posture, and settles no decision. `regency`'s premise - that being away grants nothing - is
untouched, `petition` still owns what may be decided in the King's stead, and `decree` still owns a
decision's own lifecycle. `state\.afk` remains the away flag with its existing meaning; the journal
sits beside it rather than replacing it.

Nothing here supervises the fleet across a session ending, either. That limitation is unchanged and
`regency` still states it. What changes is that the next session picks up the account as well as the
flag.
