# Night Shift

Night Shift is a repo-local CLI for planning, executing, and delivering
autonomous coding work against a single Git repository. It turns a running
brief into a task graph, executes tasks inside isolated git worktrees through
external agent providers, delivers completed work as pull requests, and leaves
behind a durable report for the human who has to read it in the morning.

Read the in-repo docs at [docs/README.md](docs/README.md) or the published site
at [fuiste.github.io/night-shift](https://fuiste.github.io/night-shift/).

## Current Shape

Night Shift already has working support for:

- repo-local configuration in `./.night-shift/`
- cumulative brief planning with `plan --notes`
- resumable run journals and reports
- task DAG scheduling and follow-up task ingestion
- isolated worktree execution
- provider adapters for Codex CLI and Cursor Agent
- local verification before pull request delivery
- review-loop ingestion for open Night Shift pull requests
- a repo-local Dash front door via `night-shift dash`

The current operator flow is:

```sh
night-shift init
night-shift plan --notes notes/today.md
night-shift start
night-shift status
night-shift report
night-shift provenance
```

Supporting commands round out the lifecycle:

- `resolve` records answers for blocked planning decisions and replans the run
- `doctor` explains whether a saved run is safe to resume and why
- `provenance` renders a per-run evidence ledger from saved artifacts
- `resume` recovers an interrupted run from saved state
- `plan --from-reviews` turns open Night Shift PR feedback into a fresh
  successor stack
- `reset` removes repo-local Night Shift state and tracked worktrees
- `--demo` runs a fixture-backed proof flow

## Install

Night Shift prerelease bundles are published from `main` for:

- Linux x64
- macOS arm64
- macOS x64

Each bundle includes the `night-shift` launcher, the compiled Gleam shipment,
and an Erlang runtime. You still need whichever provider CLIs you plan to use
locally, such as Codex CLI or Cursor Agent.

```sh
tar -xzf night-shift-<tag>-macos-arm64.tar.gz
mkdir -p ~/.local/opt ~/.local/bin
mv night-shift-<tag>-macos-arm64 ~/.local/opt/
ln -sf ~/.local/opt/night-shift-<tag>-macos-arm64/night-shift ~/.local/bin/night-shift
```

The unpacked directory must remain intact because `night-shift` runs alongside
its bundled `shipment/` and `erlang/` directories.

Windows release assets are not published yet.

## Quick Start

Initialize the repository once:

```sh
night-shift init
```

On a fresh repo, `init` asks for:

1. the default provider
2. a model that exists in that provider's local CLI
3. whether Night Shift should generate `./.night-shift/worktree-setup.toml`

Then create or refresh the execution brief and task graph:

```sh
night-shift plan --notes notes/today.md
```

`--notes` accepts either a readable file path or inline text. `plan --doc
<path>` changes the brief destination; otherwise Night Shift writes
`./.night-shift/execution-brief.md`.

Start execution from the most recent pending run:

```sh
night-shift start
```

`start` executes the run that `plan` already created. It does not accept
provider, profile, brief, or environment overrides. It also expects the source
repository to be clean apart from changes under `./.night-shift/`.

Inspect progress and outputs:

```sh
night-shift status
night-shift report
night-shift provenance
```

If planning blocked on manual decisions:

```sh
night-shift resolve
night-shift start
```

If Night Shift was interrupted mid-run:

```sh
night-shift doctor
night-shift resume --explain
night-shift resume
```

If you want the browser front door for planning, execution, and audit:

```sh
night-shift dash
```

## Source Development

Night Shift targets Erlang through Gleam. Expected versions are pinned in
[.tool-versions](.tool-versions).

```sh
brew install erlang gleam
```

If you use `asdf`:

```sh
asdf install
```

## Docs Map

- [Getting Started](docs/getting-started.md)
- [Run Lifecycle](docs/run-lifecycle.md)
- [Configuration](docs/configuration.md)
- [Worktree Environments](docs/worktree-environments.md)
- [State and Artifacts](docs/state-and-artifacts.md)
- [Providers and Delivery](docs/providers-and-delivery.md)
