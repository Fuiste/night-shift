---
title: Run Lifecycle
description: Understand how Night Shift moves between planning, execution, resolution, review, and reset.
permalink: /run-lifecycle/
---

# Run Lifecycle

Night Shift persists each run under `./.night-shift/runs/<run-id>/` and tracks
the run status in the journal. The current statuses are `pending`, `active`,
`blocked`, `completed`, and `failed`.

## Happy Path

The compact lifecycle is:

```sh
night-shift init
night-shift plan --notes notes/today.md
night-shift start
night-shift status
night-shift report
```

`plan` creates or refreshes a pending run. `start` activates that saved run and
hands tasks to the orchestrator. `status` and `report` are the cheap ways to
inspect what happened.

## Planning and Replanning

Planning does two related jobs:

- it rewrites the cumulative brief document
- it turns the brief into a task graph for a pending run

If an open run already exists, `plan` reuses it and marks `planning_dirty =
true` until the task graph has been refreshed. That is why `start` refuses to
run a pending plan that has newer planning inputs than its saved task graph.

## Blocked Runs and `resolve`

Night Shift blocks when the planner emits manual-attention tasks or unresolved
decision requests. `resolve` is the interactive command that records answers
for those decisions and immediately replans.

Use it like this:

```sh
night-shift resolve
night-shift resolve --run run-123
```

If `resolve` clears the decisions successfully, the run returns to `pending`
and the next action becomes `night-shift start`.

## Interrupted Runs and `resume`

`resume` is the recovery path for an interrupted run:

```sh
night-shift resume
night-shift resume --run run-123 --ui
```

Night Shift reloads the saved run, validates the saved environment, recovers
in-flight tasks, and continues orchestration. It does not re-resolve provider
or environment settings; it reuses what the run journal already saved.

## Review Mode

`review` is a separate entry point for stabilizing open Night Shift pull
requests:

```sh
night-shift review
night-shift review --profile reviewer --environment default
```

It inspects open Night Shift PRs, turns requested changes and failing checks
into review tasks, seeds a run with those tasks, and then executes that run.

Unlike `start` and `resume`, `review` can select a worktree environment
explicitly with `--environment <name>`.

## Reset

`reset` is the eject handle when the repo-local control plane has to go:

```sh
night-shift reset
night-shift reset --yes
night-shift reset --yes --force
```

It removes `./.night-shift/`, attempts to remove recorded Night Shift
worktrees, and prunes git worktree metadata. If a run is still active, you need
`--force`. If the terminal is non-interactive, you need `--yes`.

## Dashboard

The dashboard is monitor-only in the current cut:

```sh
night-shift start --ui
night-shift resume --ui
```

Night Shift binds to `127.0.0.1`, prefers port `8787`, and serves:

- run history for the current repository
- run summary metadata
- task status
- event timeline
- report content

There are no browser-side controls for starting, resuming, or reviewing runs in
this version.
