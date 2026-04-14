---
title: Run Lifecycle
description: Understand how Night Shift moves between planning, execution, resolution, review-driven replanning, and reset.
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
night-shift doctor
night-shift resume --explain
night-shift resume
night-shift resume --run run-123 --ui
```

Night Shift reloads the saved run, validates the saved environment, recovers
in-flight tasks, and continues orchestration. It does not re-resolve provider
or environment settings; it reuses what the run journal already saved.

`doctor` and `resume --explain` are the read-only recovery surfaces. They
inspect the saved run, active lock, worktrees, logs, review drift, and
interrupted task states, then classify each task as `safe_to_resume`,
`resume_with_warning`, `manual_attention`, or `irrecoverable`.

## Review-Driven Replanning

Review feedback re-enters Night Shift through `plan --from-reviews`:

```sh
night-shift plan --from-reviews
night-shift plan --from-reviews --notes notes/context.md
```

This command inspects open Night Shift pull requests, captures the current PR
tree as repo state, and asks the planner to produce the smallest fresh
successor stack that reconciles the actionable feedback. Night Shift derives
the superseded-PR lineage itself after planning; the provider only designs the
replacement task graph.

If the brief explicitly asks for a strict serial stack, Night Shift validates
that the implementation tasks form a single chain. For review-driven replans,
Night Shift also validates that the new implementation graph can be mapped
cleanly onto the impacted open-PR subtree. If either invariant fails, planning
stops rather than guessing.

When review-driven planning supersedes existing PRs, Night Shift opens new PRs
with `Supersedes #...` metadata and only auto-closes the old PRs after the
replacement run completes successfully.

`status`, `report`, and the dashboard surface the stored repo-state snapshot
for these runs, including captured open/actionable PR counts, the actionable
and impacted subtree, replacement lineage, and whether the live PR tree has
drifted since planning. `night-shift report` is the live operator view here:
it recomputes drift against the current PR tree when the run has a stored
review snapshot, while the on-disk `report.md` remains the stable persisted
artifact for the run.

## Provenance

`provenance` is the operator-facing evidence ledger for a run:

```sh
night-shift provenance
night-shift provenance --run run-123 --format json
night-shift provenance --task task-1
```

Night Shift persists `./.night-shift/runs/<run-id>/provenance.json` alongside
`report.md`. The command normalizes the run journal, prompt artifacts, logs,
payload-repair traces, verification artifacts, worktree paths, and confidence
posture into one inspectable view.

## Reset

`reset` is the eject handle when the repo-local control plane has to go:

```sh
night-shift reset
night-shift reset --yes
night-shift reset --yes --force
```

It removes `./.night-shift/`, attempts to remove recorded Night Shift
worktrees, and prunes git worktree metadata. It does not delete local Night
Shift branches or close remote pull requests. If a run is still active, you
need `--force`. If the terminal is non-interactive, you need `--yes`.

Completed task worktrees stay mounted after a run finishes so you can inspect
or resume them later. For successful review-driven replacement runs, Night
Shift now prunes the safe subset automatically: clean worktrees from older
successful runs whose PRs were fully superseded by the replacement run. Dirty,
blocked, failed, or manual-attention worktrees are retained. `reset` remains
the full cleanup path.

When a task returns malformed execution JSON but the task worktree has
candidate changes, Night Shift now performs one JSON-only payload-repair retry
in that same worktree. If the repaired payload decodes and passes semantic
checks, execution continues normally; otherwise the task still lands in manual
attention with both the original and repair artifacts recorded.

## Dashboard

Dash is the human-first local control surface:

```sh
night-shift dash
```

Night Shift binds Dash to `127.0.0.1` for the current repository and serves:

- structured bootstrap state for initialization, runs, task DAG metadata, repo-state drift, confidence, runtime identities, report, and provenance references
- SSE-first live updates for the selected repository state
- browser command endpoints for `init`, `plan`, `plan --from-reviews`, `resolve`, `start`, and `resume`
- raw artifact and audit routes for reports, provenance, logs, payloads, and runtime handoff files
