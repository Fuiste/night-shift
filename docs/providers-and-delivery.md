---
title: Providers and Delivery
description: Learn how Night Shift shells out to providers, validates output, serves the dashboard, and opens pull requests.
permalink: /providers-and-delivery/
---

# Providers and Delivery

Night Shift treats providers as external runtimes. It prepares prompts, shells
out to provider CLIs, and then extracts structured payloads from stdout.

## Supported Providers

The current adapters target:

- Codex CLI
- Cursor Agent

Profiles and command-line overrides resolve to one of those providers plus an
optional model and reasoning level.

## Provider Contract

Night Shift extracts structured output from stdout between these markers:

```text
NIGHT_SHIFT_RESULT_START
{ ...json... }
NIGHT_SHIFT_RESULT_END
```

Planning providers emit task DAGs. Execution providers emit task status,
summary text, files touched, demo evidence, pull request metadata, and any
follow-up tasks.

For brief generation, Night Shift also supports a document-oriented planning
flow that rewrites the cumulative brief before task planning begins.

## Fake Providers and Fixture Harnesses

For local experimentation and integration tests, Night Shift can target a fake
provider executable through `NIGHT_SHIFT_FAKE_PROVIDER`.

That executable is expected to implement:

- `fake-provider plan <prompt-file>`
- `fake-provider plan-doc <prompt-file>`
- `fake-provider execute <prompt-file> <worktree> <repo-root>`

If you also need deterministic PR fixture behavior, set `NIGHT_SHIFT_GH_BIN`
to a `gh`-compatible executable that Night Shift should use for pull request
delivery and review mode.

## Delivery Model

Night Shift's current delivery model is:

- each completed task is delivered as a pull request
- dependent tasks may be delivered as stacked pull requests
- verification runs locally before PR creation
- the local markdown report is updated throughout the run
- review mode reopens open Night Shift PRs as stabilization tasks

Delivery behavior is shaped by `base_branch`, `branch_prefix`,
`pr_title_prefix`, and `[verification].commands` in `config.toml`.

## Dashboard

The local dashboard is intentionally narrow in scope. It binds to `127.0.0.1`,
prefers port `8787`, and serves a monitor-only UI for:

- run history
- summary metadata for the selected run
- task status
- event timeline
- report content

There are no browser-side mutation controls in the current cut.

## Demo Mode

`night-shift --demo` exercises a fixture-backed flow and prints a compact proof
summary. The headless demo validates `plan`, `start`, `status`, and `report`.
The UI demo validates the local dashboard payload as well.

Demo artifacts live under:

```text
$HOME/.local/state/night-shift-demo/
```
