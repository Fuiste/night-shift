---
title: Docs Index
description: Operator-first documentation for Night Shift.
---

# Night Shift Docs

This directory is the repo-local source of truth for Night Shift's operator
documentation. The same content is also published as a static site at
[fuiste.github.io/night-shift](https://fuiste.github.io/night-shift/).

If you are new to the project, start here:

- [Getting Started](getting-started.md) for install, prerequisites, and the
  first runnable flow
- [Run Lifecycle](run-lifecycle.md) for how `plan`, `start`, `resolve`,
  `resume`, `doctor`, `provenance`, `plan --from-reviews`, and `reset` fit
  together
- [Configuration](configuration.md) for `config.toml` profiles and override
  precedence
- [Worktree Environments](worktree-environments.md) for
  `worktree-setup.toml`
- [State and Artifacts](state-and-artifacts.md) for what lives under
  `./.night-shift/`
- [Providers and Delivery](providers-and-delivery.md) for provider adapters,
  fake providers, dashboard behavior, and PR delivery

## What Night Shift Does Today

Night Shift currently focuses on one repository at a time. It maintains a
repo-local execution brief, asks a planning provider to turn that brief into a
task graph, executes tasks inside isolated worktrees, verifies the results
locally, delivers completed work as pull requests, and leaves a run journal
and report behind for inspection.

The canonical operator loop is:

```sh
night-shift init
night-shift plan --notes notes/today.md
night-shift start
night-shift status
night-shift report
night-shift provenance
```

Supporting flows handle the messier parts of reality:

- `resolve` records answers for manual-attention tasks and replans in place
- `doctor` explains whether an interrupted run looks safe to resume
- `provenance` prints the run's evidence ledger
- `resume` reattaches to an interrupted run
- `plan --from-reviews` turns open Night Shift PR feedback into a fresh successor stack
- `reset` removes Night Shift state and tracked task worktrees, but does not touch local branches or remote PRs
- `--demo` exercises a fixture-backed proof path
