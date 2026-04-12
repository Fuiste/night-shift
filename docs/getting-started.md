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

You can also target a specific run or open the local dashboard:

```sh
night-shift start --run run-123
night-shift start --ui
```

`start` is execution-only. It uses the execution agent, environment, and brief
path already saved in the pending run produced by `plan`.

Before it starts, Night Shift checks that the source repository is clean apart
from changes inside `./.night-shift/`. That guard exists so worktree execution
and delivery stay aligned with the source checkout.

## Inspect Results

Use these commands while a run is active or after it finishes:

```sh
night-shift status
night-shift report
```

`status` prints the current run state, planning and execution agent summaries,
notes source, event count, and report location. `report` prints the current
markdown report directly.

## Supporting Flows

If planning produced manual-attention tasks, record the answers and let Night
Shift replan:

```sh
night-shift resolve
night-shift start
```

If a run was interrupted, resume from the saved journal:

```sh
night-shift resume
night-shift resume --ui
```

If you want a dry proof that the end-to-end harness is wired correctly:

```sh
night-shift --demo
night-shift --demo --ui
```
