---
title: Getting Started
description: Install Night Shift, initialize a repository, and run the first planning and execution cycle.
permalink: /getting-started/
---

# Getting Started

Night Shift expects one repository, one repo-local control plane, and one
active run at a time. The happy path is compact once the prerequisites are in
place.

## Install

Night Shift prerelease bundles are published from merges to `main` for Linux
x64, macOS arm64, and macOS x64. Each bundle includes the launcher, the
compiled Gleam shipment, and an Erlang runtime.

```sh
tar -xzf night-shift-<tag>-macos-arm64.tar.gz
mkdir -p ~/.local/opt ~/.local/bin
mv night-shift-<tag>-macos-arm64 ~/.local/opt/
ln -sf ~/.local/opt/night-shift-<tag>-macos-arm64/night-shift ~/.local/bin/night-shift
```

You still need the provider CLIs you plan to use locally, such as Codex CLI or
Cursor Agent. Night Shift shells out to those CLIs rather than embedding a
provider runtime of its own.

If you are developing from source instead, install the versions pinned in
`.tool-versions` with either:

```sh
brew install erlang gleam
```

or:

```sh
asdf install
```

## Initialize the Repo

Run this once per repository:

```sh
night-shift init
```

`init` creates `./.night-shift/`, writes `config.toml`, installs a local
`.gitignore`, and can generate a starter `worktree-setup.toml`.

Interactive `init` asks for:

1. the default provider
2. the model that should become the default for that provider
3. whether to generate an initial worktree setup file

For non-interactive bootstrap, pass the answers explicitly:

```sh
night-shift init --provider codex --model gpt-5.4 --generate-setup
night-shift init --provider codex --model gpt-5.4 --yes
```

`init` is the required first step. Aside from `help`, `--demo`, and `init`,
the CLI expects `./.night-shift/config.toml` to already exist.

## Plan the Brief

Create or refresh the cumulative execution brief:

```sh
night-shift plan --notes notes/today.md
night-shift plan --notes "Follow up on the landing page polish."
```

`--notes` accepts either:

- a readable file path
- inline text, which Night Shift saves into planning artifacts for auditability

By default Night Shift manages `./.night-shift/execution-brief.md`. Use
`--doc <path>` if you want a different brief location:

```sh
night-shift plan --notes notes/today.md --doc docs/brief.md
```

Planning is the entry point for execution. Night Shift writes or updates the
brief, creates or refreshes a pending run, and asks the planning provider to
produce a task graph for that run.

## Start Execution

Kick off the most recent pending run:

```sh
night-shift start
```

You can also target a specific run:

```sh
night-shift start --run run-123
```

`start` is execution-only. It uses the execution agent, environment, and brief
path already saved in the pending run produced by `plan`.

Before it starts, Night Shift checks that the source repository is clean apart
from changes inside `./.night-shift/`. That guard exists so worktree execution
and delivery stay aligned with the source checkout.

When a task worktree is prepared, Night Shift also generates deterministic
runtime artifacts under the run directory and injects stable `NIGHT_SHIFT_*`
variables into setup, maintenance, provider execution, and verification. The
zero-config defaults are usually enough; add `runtime.named_ports` in
`worktree-setup.toml` only when you want friendly aliases like
`NIGHT_SHIFT_PORT_WEB`.

## Inspect Results

Use these commands while a run is active or after it finishes:

```sh
night-shift status
night-shift report
night-shift provenance
```

`status` prints the current run state, planning and execution agent summaries,
confidence posture, provenance path, notes source, event count, runtime
identity counts, and report location. `report` prints the current markdown
report directly, including per-task runtime manifest and handoff paths once
worktrees have been prepared. `provenance` prints the run's evidence ledger
from the saved artifact graph.

## Supporting Flows

If planning produced manual-attention tasks, record the answers and let Night
Shift replan:

```sh
night-shift resolve
night-shift start
```

If a run was interrupted, resume from the saved journal:

```sh
night-shift doctor
night-shift resume --explain
night-shift resume
```

`doctor` is the dry recovery pass. It classifies each task as
`safe_to_resume`, `resume_with_warning`, `manual_attention`, or
`irrecoverable` before you mutate any run state.

If open Night Shift pull requests received feedback and you want a fresh
replacement stack instead of in-place edits:

```sh
night-shift plan --from-reviews
night-shift plan --from-reviews --notes notes/context.md
```

That flow captures the current open-PR tree, asks the planner for the smallest
successor stack that reconciles the feedback, and surfaces repo-state drift in
`status`, `report`, and the dashboard.

If you want a dry proof that the end-to-end harness is wired correctly:

```sh
night-shift --demo
night-shift --demo --ui
```

The UI demo launches `night-shift dash`, then drives the browser-backed start
flow through Dash's HTTP surface.
