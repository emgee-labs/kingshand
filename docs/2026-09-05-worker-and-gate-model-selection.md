# Choosing the model a worker runs on, and the one the review gate runs on

2026-09-05

## The question

Review rounds are this repository's largest consumer of usage - single tasks have taken ten
and twenty-one of them. So: can a dispatched worker be put on a cheaper model, can the review
gate's repeated passes be put on one, and does either actually save anything?

Those are two questions, not one. A worker is Claude Code launched in a herdr pane by
`bin\Dispatch-Worker.ps1`. The gate is a separate program that spawns its own agent in its own
checkout. The answer for one says nothing about the other, and this note keeps them apart.

Everything below was measured on this machine on 2026-09-05 unless it says otherwise. Where
something was not exercised it says so rather than reasoning to a conclusion.

## A worker: two routes work, one is unavailable

kingshand passes no arguments to a worker at all - herdr launches `claude` through
`Start-Process` against a `.ps1` and dies with "%1 is not a valid Win32 application" the moment
an argument is added, which is why `bin\ClaudeWorkspace.psm1` exists. So `--model` is not a
route here. That is recorded in `bin\Herdr.psm1` from an earlier measurement and was not
re-tested.

The two routes that are left were both exercised, with a control:

| Route | What was done | Model the session ran on |
|---|---|---|
| control | worktree `settings.local.json`, no `model` key | `claude-opus-5[1m]` |
| worktree settings | same file plus `"model": "sonnet"` | `claude-sonnet-5` |
| environment | no `model` key, `ANTHROPIC_MODEL=claude-sonnet-5` | `claude-sonnet-5` |
| both | `"model": "sonnet"` and `ANTHROPIC_MODEL=claude-haiku-4-5-20251001` | `claude-haiku-4-5-20251001` |

The model each run actually used was read from the harness's own `modelUsage` in
`--output-format json`, not from anything the session said about itself.

The last row is the one to remember: the environment variable beats the settings file. That
matches what `bin\Herdr.psm1` already records about the harness resolving the environment
first.

The environment route survives the whole production spawn path. A pane created with
`herdr workspace create --env ANTHROPIC_MODEL=claude-sonnet-5` - the same flag `New-HerdrPane`
already passes two variables through - reported the variable set, and Claude Code launched
inside that pane ran on `claude-sonnet-5`.

**Not exercised:** every probe was a headless `claude -p` run. A dispatched worker is an
interactive session, and no worker was dispatched with a model set. The resolver is the same
code either way, but that step is unconfirmed, and confirming it costs one dispatch and one
`/status`.

## The gate: the mechanism is not where it looked, and it was not exercised

Facts first. The gate runs Claude Code as its agent, in a worktree it cuts from its own bare
copy of the repository, and that checkout carries the repository's tracked
`.claude\settings.json` - verified by listing the tree the gate reviewed. Of the 442 agent
invocations recorded in the gate's own database, every one names agent `claude`; the 409 that
record a model record `claude-opus-5`, every time, across 175 review passes and 139 fix
passes. Nothing in the gate's configuration chose that. It is the machine's own default model,
resolved the ordinary way in the directory the agent was started in.

The gate stores the materialised repository config it parsed with every round, which is a
complete list of the keys that file understands. It carries `agent: ""` and **no model key**.
So `.no-mistakes.yaml` selects which agent runs, not which model it runs on. The binary does
carry yaml keys `model`, `agent_path_override`, `agent_args_override`, `agent_config` and
`agent_timeout`, and since none of them is in the repository config, they belong to the global
config at `~\.no-mistakes\config.yaml`.

**Not exercised, deliberately.** Testing a global-config key means editing that file, which is
outside this worktree and excluded by this task, and the tool takes no environment override
pointing it at a copy. So the honest answer is: the gate has a `model` key somewhere in its
global configuration, and whether setting it moves the review pass is untested here.

There is a second candidate that is untested for the gate but measured for a session: the
repository's tracked `.claude\settings.json`, which the gate's checkout contains. A `model` key
there would be read by the same resolver the probes above exercised. It would also be read by
every worker worktree and by the Hand's own session in this repository, which is why it is
named here as a hazard rather than as a recommendation - and why the note in that file saying
it "affects the Hand only" is already narrower than what the file actually reaches.

## What switching would save: 40%, exactly

Both price tables were derived from the harness's own reported cost on probe runs whose token
counts it also reported, and they come out on round numbers, per million tokens:

| | input | output | cache read | cache write, 1h |
|---|---|---|---|---|
| `claude-opus-5[1m]` | $5 | $25 | $0.50 | $10 |
| `claude-sonnet-5` | $3 | $15 | $0.30 | $6 |

Sonnet is 0.600 of Opus on every line, so the saving does not depend on the shape of the
workload. Costing all 35 recorded gate runs on this repository from their own session
transcripts: **$1,998.66 on Opus, $1,199.19 on Sonnet**, across 142 review rounds - a mean of
$14.08 a round now, $8.45 a round then. The heaviest single run was $165.30; a ten-round run
costs about $134.

These runs are input-bound, which is why the flat ratio holds: one ten-round run read 121
million cached tokens against 777 thousand output tokens.

## What it would cost: unknown, and the break-even is nearer than it looks

A 40% saving per token means the break-even is **1.667 rounds on Sonnet for every 1 on Opus**.
A task that takes ten rounds today has to stay under seventeen. Anything past that and the
cheaper model is the more expensive one.

That number is a real risk rather than a theoretical one, because the same agent does the
fixing as well as the reviewing - 139 of the recorded passes are fix passes - so a weaker
model raises rounds from both ends: findings it fails to raise until later, and fixes that do
not land first time.

Whether Sonnet actually raises more rounds here was **not measured**, and it is the one thing
that decides the question. The gate ships the harness for measuring it: 48 gold-labelled
review cases captured from this machine's own runs, a 16-case tune set, and a recorded Opus
self-score of 98% recall (126 of 128 true issues). No candidate replay has ever been run -
`no-mistakes eval report` says so.

## What a follow-up change would do

Recommendation only. Nothing here was switched, and no configuration was edited.

1. **Measure the gate before touching it.** `no-mistakes eval run --cases tune --candidate
   claude,model=claude-sonnet-5 --repeats 1`, then `no-mistakes eval report` against the
   recorded Opus score. Sixteen review passes is not free; it is far cheaper than finding out
   through live rounds.
2. **For a worker**, the change is one key in `Set-WorkerWorkspaceSettings`
   (`bin\ClaudeWorkspace.psm1`): the `$settings` hashtable it writes gains `model`, its caller
   `bin\Dispatch-Worker.ps1` passes it, and the value comes from the project's registry entry
   so it is per project rather than machine-wide. The environment route works too and is
   worse: it is set at pane creation in `New-HerdrPane`, where nothing per-task can reach it,
   and it silently outranks the settings file.
3. **Do not put a model key in the tracked `.claude\settings.json`.** It reaches the Hand, every
   worker and the gate at once, and only in this repository.

## Re-running any of this

The worker probes are three directories each holding a `.claude\settings.local.json`, one
`claude -p '...' --output-format json` per case, and `modelUsage` read out of the answer. The
gate figures come from `~\.no-mistakes\state.sqlite` (`agent_invocations`, joined to `runs`)
and from the session transcripts under `~\.claude\projects\`, which are named for the run they
belong to. Copy the database before reading it rather than opening the live one.

The whole investigation cost about $0.55 in nine probe runs, which is less than one round.
