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

Execution payloads should follow the same discipline as real providers:

- emit exactly one JSON object between the Night Shift sentinel markers
- keep shell transcript noise outside that JSON payload
- return repo-relative `files_touched` paths

If you also need deterministic PR fixture behavior, set `NIGHT_SHIFT_GH_BIN`
to a `gh`-compatible executable that Night Shift should use for pull request
delivery and review-driven planning.

## Delivery Model

Night Shift's current delivery model is:

- each completed task is delivered as a pull request
- dependent tasks may be delivered as stacked pull requests
- verification runs locally before PR creation
- Night Shift can overlay a configurable reviewer handoff block onto the PR
  body, with repo-local markdown snippets before or after the generated block
- the local markdown report is updated throughout the run
- `night-shift report` is the live audit view for review-driven runs and can
  show current drift against the saved open-PR snapshot
- review-driven planning creates fresh successor PRs rather than mutating existing PR branches in place
- successor PRs can declare `Supersedes #...`, and Night Shift only comments on and closes superseded PRs after the replacement run succeeds
- providers do not author supersession lineage; Night Shift derives it from the impacted open-PR subtree and the validated replacement graph
- if a review-driven plan cannot be mapped cleanly onto the impacted subtree, Night Shift blocks planning instead of guessing
- after a successful replacement run, Night Shift prunes clean worktrees from
  older successful superseded runs and records any skipped dirty/missing
  worktrees as warnings
- when an execution payload is schema-valid after sanitization or recovery,
  Night Shift accepts it, normalizes safe path differences, and records a
  warning event instead of forcing manual attention
- when an execution payload is malformed but the task worktree has candidate
  changes, Night Shift performs one JSON-only payload-repair retry in the same
  worktree before falling back to manual attention

Delivery behavior is shaped by `base_branch`, `branch_prefix`,
`pr_title_prefix`, `[verification].commands`, and `[handoff]` in
`config.toml`.

## Reviewer Handoff

When handoff output is enabled, Night Shift can add a structured PR-body region
covering:

- context for why the PR exists
- scope such as `files_touched`, acceptance cues, and stack/supersession
  metadata when configured
- model-authored summary text and known risks
- deterministic evidence such as verification output
- provenance labels that distinguish Night Shift-owned facts from inferred
  provider-authored text

Night Shift encloses its PR-body overlay in stable markers and only rewrites
that marked region on later updates, so manual text outside the markers can
survive future delivery passes.

If `[handoff].managed_comment = true`, Night Shift also owns one PR comment for
incremental review deltas such as "Since Last Review", review-driven context,
and replacement-stack status. Repositories with stricter comment etiquette can
leave that disabled and still use the PR-body overlay.

## Dashboard

The local dashboard is intentionally narrow in scope. It binds to `127.0.0.1`,
prefers port `8787`, and serves a monitor-only UI for:

- run history
- summary metadata for the selected run
- repo-state summary for review-driven runs, including snapshot time and drift
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
