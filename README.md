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
- harness adapters
- verification and PR delivery plumbing
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

- `night-shift start --brief <path> [--harness <codex|cursor>] [--max-workers <n>]`
- `night-shift status [--run <id>|latest]`
- `night-shift report [--run <id>|latest]`
- `night-shift resume [--run <id>|latest]`
- `night-shift review [--harness <codex|cursor>]`

## Delivery Model

- Each completed task is delivered as a pull request.
- Dependent tasks may be delivered as stacked pull requests.
- Verification is run locally before PR creation.
- A local Markdown report is updated throughout the run.
