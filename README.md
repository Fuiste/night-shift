# Night Shift

Night Shift is a Gleam CLI that orchestrates autonomous coding agents over a
single local repository. It turns a brief into a queue of tasks, executes that
queue through external providers like Codex CLI or Cursor Agent, opens pull
requests for completed work, and leaves behind a durable report for morning
review.

## Status

This repository currently contains the v1 runtime for:

- repo-local configuration
- resumable run journals
- task DAG scheduling
- provider adapters for Codex CLI and Cursor Agent
- isolated git worktree execution
- verification and PR delivery plumbing
- review-loop task ingestion for open Night Shift PRs
- local notifier and report output

## Tooling

Night Shift targets Erlang through Gleam. This machine does not currently ship
with Gleam or Erlang by default, so the repo pins expected versions in
`.tool-versions`.

Suggested setup:

```sh
brew install erlang gleam
```

If you use `asdf`, run:

```sh
asdf install
```

## Configuration

Repository defaults live in `.night-shift.toml`.

```toml
default_profile = "default"
planning_profile = "planner"
execution_profile = "builder"
review_profile = "reviewer"

base_branch = "main"
max_workers = 4
branch_prefix = "night-shift"
pr_title_prefix = "[night-shift]"
notifiers = ["console", "report_file"]

[profiles.default]
provider = "codex"

[profiles.planner]
provider = "codex"
model = "gpt-5.4-mini"
reasoning = "medium"

[profiles.builder]
provider = "codex"
model = "gpt-5.4"
reasoning = "high"

[profiles.reviewer]
provider = "cursor"
model = "sonnet-4"

[profiles.reviewer.provider_overrides]
mode = "plan"

[verification]
commands = []
```

### Profiles

Profiles are the main developer-facing abstraction. Each profile is Night
Shift-owned and provider agnostic at the top level:

- `provider`: currently `codex` or `cursor`
- `model`: provider model id
- `reasoning`: normalized thinking level, currently `low`, `medium`, `high`,
  or `xhigh`
- `provider_overrides`: advanced provider-specific escape hatch for settings
  that do not fit the normalized surface

The phase selectors control which profile is used by default:

- `default_profile`: base fallback profile name
- `planning_profile`: used by `night-shift plan`
- `execution_profile`: used by `night-shift start`
- `review_profile`: used by `night-shift review`

An empty `.night-shift.toml` still works. Night Shift will use a built-in
`default` profile that targets Codex with provider defaults.

### Precedence

Night Shift resolves agent settings in this order:

1. Built-in defaults
2. Repo config profile values
3. Command-level overrides

Command-level `--profile`, `--provider`, `--model`, and `--reasoning`
override the resolved profile for that invocation.

For `start`, command-level overrides apply to both planning and execution for
that run so ad hoc runs stay predictable. `resume` never re-resolves settings;
it continues with the resolved planning and execution configs stored in the run
journal.

### Provider Overrides

Use `[profiles.<name>.provider_overrides]` only for provider-specific controls
that Night Shift does not normalize.

Current adapter support:

- Codex: no provider overrides yet
- Cursor: `mode = "plan"` or `mode = "ask"`

Night Shift fails fast when a normalized control cannot be represented by the
selected provider. For example, Cursor supports model selection but not the
generic `reasoning` control.

### Examples

Example configs live in:

- `examples/config-single-profile.toml`
- `examples/config-phase-profiles.toml`
- `examples/config-provider-overrides.toml`

## Commands

The CLI surface is:

- `night-shift --demo [--ui]`
- `night-shift plan --notes <path> [--doc <path>] [--profile <name>] [--provider <codex|cursor>] [--model <id>] [--reasoning <low|medium|high|xhigh>]`
- `night-shift start [--brief <path>] [--profile <name>] [--provider <codex|cursor>] [--model <id>] [--reasoning <low|medium|high|xhigh>] [--max-workers <n>] [--ui]`
- `night-shift status [--run <id>|latest]`
- `night-shift report [--run <id>|latest]`
- `night-shift resume [--run <id>|latest] [--ui]`
- `night-shift review [--profile <name>] [--provider <codex|cursor>] [--model <id>] [--reasoning <low|medium|high|xhigh>]`

## Planning Brief

Night Shift can build up a cumulative execution brief throughout the day:

```sh
night-shift plan --notes notes/morning.md
night-shift plan --notes notes/afternoon.md
```

By default this updates repo-root `night-shift.md`. Each run reads the existing
brief if present, combines it with the new notes, and asks the resolved
planning provider to rewrite the full document in place.

The brief is whole-file managed by Night Shift and always targets this outline:

- `# Night Shift Brief`
- `## Objective`
- `## Scope`
- `## Constraints`
- `## Deliverables`
- `## Acceptance Criteria`
- `## Risks and Open Questions`

You can override the destination file with `--doc <path>`, but the default
`night-shift.md` is also the happy-path execution input.

## Starting Work

If `night-shift.md` exists at the repo root, the simplest kickoff flow is:

```sh
night-shift start
```

Passing `--brief <path>` still works and overrides the default brief location.
If no default brief exists, Night Shift tells you to create one with
`night-shift plan --notes <path>` or pass `--brief`.

You can also override the resolved profiles at runtime:

```sh
night-shift start --profile fast
night-shift start --provider codex --model gpt-5.4 --reasoning high
night-shift plan --provider cursor --model sonnet-4
```

## Dashboard

Night Shift can launch a local read-only dashboard while a run is active:

```sh
night-shift start --ui
night-shift resume --run latest --ui
```

The dashboard binds to `127.0.0.1`, prefers port `8787`, and will try the next
few ports if that one is unavailable. The CLI prints the chosen URL and keeps
serving until you stop the process.

The first cut is intentionally minimal and monitor-only:

- run history for the current repository
- run summary metadata, including planning and execution profile details
- task status list
- event timeline
- report content as plain text

There are no browser-side controls for starting, resuming, or reviewing runs in
v1.

## Demo Mode

Night Shift can self-demo against fixture providers and prints a compact proof
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

An `active.lock` file is kept at the repo state root so only one active run can
operate on a repo at a time.

New run state persists fully resolved planning and execution configs. Older
run journals that still store a single `harness` field remain readable.

## Provider Contract

Providers are treated as external runtimes. Night Shift prepares a prompt,
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
fixture provider by setting `NIGHT_SHIFT_FAKE_PROVIDER` to an executable that
implements:

- `fake-provider plan <prompt-file>`
- `fake-provider plan-doc <prompt-file>`
- `fake-provider execute <prompt-file> <worktree> <repo-root>`

## Migration

Night Shift now uses `profile` and `provider` terminology instead of
`harness`.

- Replace `default_harness = "codex"` with a profile table and phase selectors.
- Replace `--harness codex` with `--provider codex` or `--profile <name>`.
- Prefer `reasoning` in config and CLI when you want to control thinking level.

## Delivery Model

- Each completed task is delivered as a pull request.
- Dependent tasks may be delivered as stacked pull requests.
- Verification is run locally before PR creation.
- A local Markdown report is updated throughout the run.
- Review mode reopens open Night Shift PRs, turns review state into
  stabilization tasks, and reruns the scheduler.
