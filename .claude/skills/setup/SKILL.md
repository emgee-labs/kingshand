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

Then run it from the repository root:

```powershell
.\install.ps1 -InstallMissing
```

If the user named a directory their repositories live under, or `$ARGUMENTS` carries one, pass it:

```powershell
.\install.ps1 -InstallMissing -ProjectRoot <path>
```

The script prints every install command before it runs it. It is idempotent, and it never
overwrites an existing `instructions.md` or an existing config value.

## Step 2 - Report what happened, in their words

Read the output and translate it. **Never paste the script's output into chat.** Cover four
things, briefly:

- What was installed just now, by name.
- What was already present, as a count rather than a list.
- What it left alone and why - a `KEPT` line means their own value or their own file was there
  first, and `-Force` is the only way it would be replaced.
- What still needs them: any tool that is still missing after the re-check, and `gh auth login`
  if the GitHub CLI went in fresh.

If a tool failed to install for want of administrator rights, give them the one command to run in
an elevated shell. Nothing here elevates itself.

## Step 3 - Name the two things it deliberately did not do

Both are choices, not omissions, and the user should hear them now rather than discover them:

- **`no-mistakes` was not installed.** It is optional, has no package-manager source, and only
  projects registered with the `no-mistakes` posture need it.
- **`config\ado.json` was not written.** When that file is absent, `muster` asks for the Azure
  DevOps organization and project the first time it needs them, rather than inventing values that
  would then be trusted as configured.

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
