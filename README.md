# Night Shift

Night Shift is a Gleam CLI that orchestrates autonomous coding agents over a
single local repository. It turns a brief into a queue of tasks, executes that
queue through external harnesses like Codex CLI or Cursor Agent, opens pull
requests for completed work, and leaves behind a durable report for morning
review.

## Status

This repository currently contains the v1 implementation scaffold and core
runtime modules for:

- repo-local configuration
- resumable run journals
- task DAG scheduling
- async harness adapters for Codex CLI and Cursor Agent
- isolated git worktree execution
- verification and PR delivery plumbing
- review-loop task ingestion for open Night Shift PRs
- local notifier/report output

## Tooling

Night Shift targets Erlang through Gleam. This machine does not currently ship
with Gleam or Erlang by default, so the repo pins expected versions in
[`.tool-versions`](/Users/rudy/work/side-projects/night-shift/.tool-versions).

Suggested setup:

```sh
brew install erlang gleam
```

If you use `asdf`, run:

```sh
asdf install
```

## Configuration

Repository defaults live in
[`.night-shift.toml`](/Users/rudy/work/side-projects/night-shift/.night-shift.toml).

```toml
base_branch = "main"
default_harness = "codex"
max_workers = 4
branch_prefix = "night-shift"
pr_title_prefix = "[night-shift]"
notifiers = ["console", "report_file"]

[verification]
commands = []
```

## Commands

The CLI surface for v1 is:

- `night-shift --demo [--ui]`
- `night-shift start --brief <path> [--harness <codex|cursor>] [--max-workers <n>] [--ui]`
- `night-shift status [--run <id>|latest]`
- `night-shift report [--run <id>|latest]`
- `night-shift resume [--run <id>|latest] [--ui]`
- `night-shift review [--harness <codex|cursor>]`

## Dashboard

Night Shift can launch a local read-only dashboard while a run is active:

```sh
night-shift start --brief brief.md --ui
night-shift resume --run latest --ui
```

The dashboard binds to `127.0.0.1`, prefers port `8787`, and will try the next
few ports if that one is unavailable. The CLI prints the chosen URL and keeps
serving until you stop the process.

The first cut is intentionally minimal and monitor-only:

- run history for the current repository
- run summary metadata
- task status list
- event timeline
- report content as plain text

There are no browser-side controls for starting, resuming, or reviewing runs in
v1.

## Demo Mode

Night Shift can self-demo against fixture harnesses without printing anything on
success:

```sh
night-shift --demo
night-shift --demo --ui
```

The headless demo runs a real fixture-backed start flow and validates the
resulting journal/report state. The UI demo launches the local dashboard, waits
for the run to complete, validates the served payload, and then exits.

## Run Journal

Night Shift stores durable state outside the target repo under:

```text
$XDG_STATE_HOME/night-shift/<repo-key>/<run-id>/
```

If `XDG_STATE_HOME` is unset, it falls back to:

```text
$HOME/.local/state/night-shift/<repo-key>/<run-id>/
```

Each run directory includes:

- `brief.md`
- `state.json`
- `events.jsonl`
- `report.md`
- `logs/`

An `active.lock` file is kept at the repo state root so only one active run can
operate on a repo at a time.

## Harness Contract

Harnesses are treated as external runtimes. Night Shift prepares a prompt,
launches the selected CLI, and extracts a structured JSON payload from stdout
between these markers:

```text
NIGHT_SHIFT_RESULT_START
{ ...json... }
NIGHT_SHIFT_RESULT_END
```

The planner emits task DAGs. The executor emits task status, demo evidence,
files touched, PR metadata, and follow-up tasks.

For integration tests or local experimentation, you can point Night Shift at a
fixture harness by setting `NIGHT_SHIFT_FAKE_HARNESS` to an executable that
implements:

- `fake-harness plan <prompt-file>`
- `fake-harness execute <prompt-file> <worktree> <repo-root>`

## Delivery Model

- Each completed task is delivered as a pull request.
- Dependent tasks may be delivered as stacked pull requests.
- Verification is run locally before PR creation.
- A local Markdown report is updated throughout the run.
- Review mode reopens open Night Shift PRs, turns review state into
  stabilization tasks, and reruns the scheduler.
