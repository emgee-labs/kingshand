---
name: setup
description: Use when the user wants kingshand installed and configured on this machine - e.g. "set it up", "setup", "set up", "init", "initialise", "initialize", "install", "install kingshand", "get started", "let's start", "ready to start", "first run", "/setup". Also use when the session-start digest says NOT SET UP YET. Runs install.ps1 -InstallMissing from the repository root, then says in plain language what installed, what was already there, what it left alone, and what still needs them. One shot, and it does no project work.
tools: Bash, PowerShell, Read, AskUserQuestion
version: 1.0.0
---

# Setup

## Overview

This skill lives in `.claude\skills\` beside the other ten, and every one of them is readable the
moment someone opens Claude Code in this directory - nothing has to be installed or linked first.
That is what breaks the bootstrap cycle, and it is also why a Claude Code session started anywhere
else on this machine never loads any of them.

$ARGUMENTS

## Step 1 - Greet them once, say what is about to happen, then run it

If this is a first run - the digest said `NOT SET UP YET`, or `data\` does not exist - open with a
short greeting before anything else. One or two lines, warm, and then straight to work:

> Ready to start ruling? Let me check what the kingdom has, and fetch whatever is missing.

Use the King and Hand framing lightly here and nowhere else in this skill. It is a greeting, not a
costume, and the rest of the run is plain reporting. On a re-run, skip the greeting entirely - they
have met you.

Then one line on what is about to happen: this checks the prerequisites, installs the ones that are
missing, and writes this machine's configuration - `KINGSHAND_HOME`, the lavish port,
`instructions.md` from the template, and the local `data\`, `state\` and `config\` directories. It
touches none of their repositories, and it writes nothing into their `~\.claude\` profile.

Say too that it adds one line, `.claude/worktrees/`, to their global gitignore. That is the only
thing it changes outside this repository other than the two environment variables, and it is there
because workers run inside their own repositories and would otherwise appear as untracked changes.
One line, said once - not a paragraph of reassurance.

**Then ask them two questions, and only on a first run.**

**First, what to call them.** The template default is "your Highness", chosen because it assumes
nothing about them. Ask what they would rather have:

> One thing first - what should I call you? The default is "your Highness". "my Queen" or "my King"
> if you prefer one, or your own name, or nothing at all.

Take whatever they say at face value. **Never infer a title from their name, their writing, or
anything else about them** - guessing wrong here is a worse failure than asking, and the neutral
default exists precisely so guessing is never necessary. Do not talk anyone out of "nothing". Pass
the answer as `-AddressAs "<their answer>"`; leave the flag off to keep the default, and if they
want no title at all, say so plainly and tell them the one line to delete. The Hand cannot write this itself - the permission layer denies it edits
to `instructions.md`, which is exactly why that file is trustworthy - so the installer writes it.

**Second, how far work should go before it reaches them.** Two answers, in plain words - no posture
names, they do not know them yet:

> Two ways to run this. Either work stops at a finished branch on your machine and you decide what
> happens next, or it goes through a full review pipeline and arrives as a pull request. The second
> needs a review tool I would download - about 14 MB. Which suits you? You can add it later either
> way.

Do not recommend one. Someone who only wants work to land locally should not be talked into a
review pipeline, and someone who wants pull requests should not have to discover afterwards that a
tool was missing. If they are unsure, take the local answer: it is the reversible one, and
`.\install.ps1 -WithReviewGate` adds the gate any time later.

Then run it from the repository root, carrying both answers. Without the review gate:

```powershell
.\install.ps1 -InstallMissing -AddressAs "my Queen"
```

With it:

```powershell
.\install.ps1 -InstallMissing -WithReviewGate -AddressAs "my Queen"
```

`-AddressAs` takes their exact words. Drop the flag entirely if they wanted no title.

If the user named a directory their repositories live under, or `$ARGUMENTS` carries one, add
`-ProjectRoot <path>`. They rarely need to - see Step 4.

The script prints every install command before it runs it. It is idempotent, and it never
overwrites an existing `instructions.md` or an existing config value.

**Never tell them to `npm install -g no-mistakes`.** That name on npm is a different, unrelated
tool that installs cleanly and then does not work, which is the worst shape a wrong answer can
take. The gate is a GitHub release, and `-WithReviewGate` is the only route to it here.

## Step 2 - Report what happened, in their words

Read the output and translate it. **Never paste the script's output into chat.** Cover four
things, briefly:

- What was installed just now, by name.
- What was already present, as a count rather than a list.
- What it left alone and why - a `KEPT` line means their own value or their own file was there
  first, and `-Force` is the only way it would be replaced.
- What still needs them: any tool that is still missing after the re-check, and `gh auth login`
  if the GitHub CLI went in fresh.

**A `NOTE` line is not a problem and must never be reported as one.** The script prints `MISS`
for something dispatch cannot work without and `NOTE` for something a working installation may
legitimately never need - the GitHub CLI, Pester, the review gate, Azure DevOps. Read the exit
code and the `MISS` lines for what is wrong; everything else is a choice they can make later.
If the run ended clean, say it is ready, and do not hand them a list of optional things to worry
about.

If a tool failed to install for want of administrator rights, give them the one command to run in
an elevated shell. Nothing here elevates itself.

## Step 3 - Name the two things it deliberately did not do

Both are choices, not omissions, and the user should hear them now rather than discover them:

- **`no-mistakes` was not installed.** It is optional, has no package-manager source, and only
  projects registered with the `no-mistakes` posture need it.
- **`config\ado.json` was not written.** When that file is absent, `muster` asks for the Azure
  DevOps organization and project the first time it needs them, rather than inventing values that
  would then be trusted as configured. Say in the same breath that **Azure DevOps integration is
  optional and needs nothing unless they work ADO tickets**: the `ado-local-mcp` server is not a
  prerequisite, nothing here installs it, and without it work is described in their own words and
  handled as adhoc, which is the ordinary path.

## Step 4 - What to do next

1. **Open a new shell.** `KINGSHAND_HOME` is set for the user, and this session started before it
   existed.
2. **Write `instructions.md`.** It was just created from the template. It is their standing word -
   how they want to be spoken to, their delivery defaults, their conventions - and nothing here
   ever rewrites it, not `chronicle`, not another install run. It is gitignored.
3. **Register a repository** with `/annex <path>`. Nothing is dispatched into a project
   that is not registered.

Do not tell the user they must add their repository roots first. They almost certainly do not.
`defaultMode: bypassPermissions` already lets the Hand read, write, glob and run git against a
repository on any drive, so `/annex <path>` works straight away wherever the repository lives -
which is the whole point of registering one in place instead of cloning it. `-ProjectRoot` is
worth mentioning only if the user has narrowed that permission mode.

## Step 5 - The permission posture, said out loud

`.claude\settings.json` ships with `defaultMode: bypassPermissions`, and every worker is spawned
the same way, so **neither the Hand nor its workers will ask them to approve a tool call.** That is
deliberate and it is reversible. Point them at the README section "Permissions, and what you are
agreeing to" for what still constrains it and how to turn it off.

## Not in scope

Setup only. No project work, no dispatch, no registration - `/annex` owns that, and
`muster` owns everything after it.
