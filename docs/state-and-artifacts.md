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
- `runtime/`
- `worktrees/`

Night Shift only treats a run directory as real once `state.json`,
`events.jsonl`, and `report.md` all exist. Failed planning attempts may leave
planning artifacts behind, but they are ignored by `status` and `report`.

The run record itself stores:

- resolved planning and execution agent configs
- the selected environment name
- notes source metadata
- planning provenance such as `notes only` or `reviews + notes`
- an open-PR repo-state snapshot for review-driven plans
- mechanically derived supersession lineage on replacement tasks
- recorded decisions
- `planning_dirty`
- persisted per-task `runtime_context`
- task list and task states
- timestamps and current run status

## Runtime Artifacts

Night Shift writes per-task runtime artifacts under:

- `./.night-shift/runs/<run-id>/runtime/<task-id>/night-shift.env`
- `./.night-shift/runs/<run-id>/runtime/<task-id>/night-shift.runtime.json`
- `./.night-shift/runs/<run-id>/runtime/<task-id>/night-shift.handoff.md`

Those files are generated before setup or maintenance commands run. They live
under the run directory instead of inside the git worktree so they do not
pollute branches or pull requests.

The persisted task `runtime_context` points at those artifact paths and stores
the deterministic runtime identity Night Shift derived for the task, including
the compose-safe name and port base. Resume and maintenance reuse the saved
context rather than recomputing from current repo config.

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
- captured review snapshot details for review-driven runs
- actionable and impacted PR lists from the stored review snapshot
- replacement lineage such as `task -> superseded PR`
- supersession outcomes and warnings
- worktree retention and pruning notes
- execution recovery warnings when Night Shift accepted a sanitized or
  recovered provider payload
- payload-repair attempt, success, and failure notes when Night Shift retried a
  malformed execution result in place
- runtime identity summaries and artifact paths for prepared tasks
- task summaries
- planning validation failures
- event timeline

The persisted `report.md` under a run directory is the stable artifact written
with the run state. The `night-shift report` command is slightly richer for
review-driven runs: it refreshes repo-state drift against the current open PR
tree when a stored snapshot exists, so its live output is authoritative for
current drift while `report.md` remains durable and offline-readable.

Task-level provider logs and prompt files live under each run's `logs/`
directory.

Task worktrees are intentionally sticky. Night Shift keeps them mounted after
completion so operators can inspect delivery state or resume later without
reconstructing the world from scratch. The one automatic cleanup path is
review-driven supersession: after a successful replacement run comments on and
closes the old PRs, Night Shift prunes clean worktrees from older successful
runs whose PRs were fully superseded. Dirty or unresolved worktrees are
retained and called out in events and reports.

For review-driven runs, task lineage in `state.json` is Night Shift-owned
metadata. Providers return `superseded_pr_numbers = []`, then Night Shift
derives the replacement mapping from the impacted PR subtree plus the validated
task graph before it persists the run.

When execution payload decoding is noisy, Night Shift preserves the raw payload
and any sanitized recovery artifact under `logs/`. If the recovered payload is
still schema-valid and semantically safe, Night Shift accepts it and records an
`execution_payload_warning` event instead of forcing manual attention.

When execution payload decoding fails outright but the task worktree has
candidate changes, Night Shift also records a JSON-only payload-repair retry
under distinct `.payload-repair.*` log and prompt artifacts. If that retry
still fails, manual-attention summaries include both the original malformed
payload path and the repair artifacts.

## Active Lock

Night Shift keeps `./.night-shift/active.lock` so only one active run can
operate on a repository at a time. That lock is part of the repo-local control
plane rather than the task worktrees themselves.

## What `reset` Removes

`night-shift reset` attempts to:

- remove `./.night-shift/`
- remove recorded Night Shift task worktrees
- prune git worktree metadata

`reset` does not delete local Night Shift branches and it does not close or
modify remote pull requests.

It is deliberately destructive. If an active run still exists, use
`night-shift reset --force`. If you are not in an interactive terminal, pass
`--yes` as well.
