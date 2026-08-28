# Standing instructions

Everything you write in this file is read at the start of every session and treated as your own
standing word. `install.ps1` copies this template to `instructions.md`, which is gitignored and
never leaves your machine.

**The Hand reads this file and never edits it.** Nothing curates it, nothing prunes it, and no
`/stow` pass will quietly drop a line from it. That is the whole difference between this file and
`data\king.md`: `king.md` is what the Hand inferred about how you work and `stow` prunes it against
a budget, while this file is what you stated. If you want something to survive untouched, it goes
here.

An absent `instructions.md` is a normal state, not an error - it means you have stated no standing
preferences yet. Delete every line below if none of it applies to you; a file of examples you never
meant is worse than no file.

## Defaults

This one is live, not an example. Delete it if you disagree.

- **A repository's own rules beat these.** Where a project carries its own instructions - a
  `CLAUDE.md`, an `AGENTS.md`, a contributing guide, a house style - follow that project's rules
  for work inside it, over anything written here or in kingshand's own `CLAUDE.md`. Read them
  before writing a brief. Where the two genuinely conflict and it matters, say so and ask.

Three things you might expect here are already the default in `CLAUDE.md`, so they do not need
restating: short replies in plain words rather than file-and-line references, no assistant or
model ever named as an author on anything reaching a remote, and `-` rather than the long dash.
Write them here only if you want to say something different from the default.

Everything below is commented out. Uncomment what you want and rewrite it in your own words.

<!--

## How to talk to me

- Lead with the answer. I will ask for the reasoning if I want it.
- No preamble, no closing pleasantries, no restating my question back to me.
- Give me estimates in minutes, hours or file counts. Never "shortly" or "a bit".
- Push back when you think I am wrong, with the evidence first. I would rather argue than be
  agreed with.

## Delivery defaults

- Default a new project to `local-only` until I say otherwise. Ask before raising a posture.
- Never open a pull request against a repository I have not registered.
- Branch names: `<my-initials>/<ticket>-<short-slug>`.
- Never push to a default branch, even where the posture allows it.

## My conventions

- Commit messages: imperative mood, one line under 72 characters, body only where it earns itself.
- Tests live beside the code they cover, never in a top-level tests directory.
- I use tabs in Go, two spaces everywhere else.
- The word "utils" is not allowed in a file name.

## Working hours and interruptions

- I am at the machine 09:00-18:00 UK time. Outside that, batch anything that is not a blocker.
- A blocked worker always reaches me. Routine progress never does.

## Things I have already decided

- Do not suggest adding a CI provider. I know. It is deliberate.
- Do not offer to write documentation unless I ask for it.

-->
