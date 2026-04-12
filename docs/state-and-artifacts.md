---
title: State and Artifacts
description: Inspect the repo-local files Night Shift uses for briefs, journals, logs, and worktrees.
permalink: /state-and-artifacts/
---

# State and Artifacts

Night Shift keeps project-owned state under `./.night-shift/`. The design goal
is simple: the repository owns its own orchestration state, while runtime
artifacts that should not be committed stay ignored under that same root.

## Layout

Tracked project config lives in:

- `./.night-shift/config.toml`
- `./.night-shift/worktree-setup.toml`
- `./.night-shift/.gitignore`

Runtime artifacts live in:

- `./.night-shift/execution-brief.md`
- `./.night-shift/runs/<run-id>/`
- `./.night-shift/planning/<timestamp>/`
- `./.night-shift/active.lock`

## Run Journal

Each run directory contains durable state for one run:

- `brief.md`
- `state.json`
- `events.jsonl`
- `report.md`
- `logs/`
- `worktrees/`

The run record itself stores:

- resolved planning and execution agent configs
- the selected environment name
- notes source metadata
- recorded decisions
- `planning_dirty`
- task list and task states
- timestamps and current run status

## Planning Artifacts

Planning writes artifacts under `./.night-shift/planning/<timestamp>/`. Those
artifacts include prompt files, provider logs, generated worktree setup drafts,
and other inputs or outputs that make a planning pass auditable after the fact.

Inline `--notes` inputs are written into planning artifacts rather than
vanishing into the terminal scrollback.

## Reports and Logs

`night-shift report` prints the markdown report for a run. The report includes:

- run status
- planning and execution agent summaries
- environment label
- task summaries
- planning validation failures
- event timeline

Task-level provider logs and prompt files live under each run's `logs/`
directory.

## Active Lock

Night Shift keeps `./.night-shift/active.lock` so only one active run can
operate on a repository at a time. That lock is part of the repo-local control
plane rather than the task worktrees themselves.

## What `reset` Removes

`night-shift reset` attempts to:

- remove `./.night-shift/`
- remove recorded Night Shift task worktrees
- prune git worktree metadata

It is deliberately destructive. If an active run still exists, use
`night-shift reset --force`. If you are not in an interactive terminal, pass
`--yes` as well.
