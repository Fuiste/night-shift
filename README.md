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

[discord]
webhook_url_env = "NIGHT_SHIFT_DISCORD_WEBHOOK_URL"
```

To enable Discord delivery, add `"discord"` to `notifiers` and provide the
webhook through the configured environment variable. Keep the webhook secret
out of repo-tracked files.

Example:

```toml
notifiers = ["console", "report_file", "discord"]

[discord]
webhook_url_env = "NIGHT_SHIFT_DISCORD_WEBHOOK_URL"
```

```sh
export NIGHT_SHIFT_DISCORD_WEBHOOK_URL="https://discord.com/api/webhooks/..."
```

Discord delivery is best-effort. If the webhook env var is missing or delivery
fails, Night Shift continues the run, leaves PRs open for review, and records
the gap in the final Markdown report.

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

Night Shift can self-demo against fixture harnesses and prints a compact proof
summary on success:

```sh
night-shift --demo
night-shift --demo --ui
```

The headless demo runs a real fixture-backed start flow and validates the
resulting `start`, `status`, and `report` CLI flows. The UI demo launches the
local dashboard through the real CLI, waits for the run to complete, validates
the served payload, and then exits. Both variants print the validated flows,
the proof file path, and the artifact directory so the demo is visible from the
terminal.

Artifacts are kept under:

```text
$XDG_STATE_HOME/night-shift-demo/
```

If `XDG_STATE_HOME` is unset, this resolves under:

```text
$HOME/.local/state/night-shift-demo/
```

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

The Markdown report now includes:

- shipped work and opened PRs
- blocked or manual-attention items
- queued follow-up tasks and open questions
- manual setup gaps such as missing Discord webhook configuration
- recommended next steps for the morning reviewer

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
- PR bodies include stack context, verification output, known risks, and
  follow-up notes for reviewers.
- Verification is run locally before PR creation.
- A local Markdown report is updated throughout the run.
- Notifications can be delivered to Discord via webhook when enabled.
- Review mode reopens open Night Shift PRs, turns review state into
  stabilization tasks, and reruns the scheduler.
