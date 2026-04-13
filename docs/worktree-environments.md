---
title: Worktree Environments
description: Define deterministic worktree setup and maintenance commands with worktree-setup.toml.
permalink: /worktree-environments/
---

# Worktree Environments

`./.night-shift/worktree-setup.toml` lets the repository define deterministic
commands and environment variables for task worktrees.

If the file is absent, environment setup is a no-op. If it is present but
invalid, Night Shift fails before any task worktrees launch.

## Shape

The current schema starts like this:

```toml
version = 1
default_environment = "default"

[environments.default.env]

[environments.default.preflight]
default = []
macos = []
linux = []
windows = []

[environments.default.setup]
default = []
macos = []
linux = []
windows = []

[environments.default.maintenance]
default = []
macos = []
linux = []
windows = []
```

Each environment can define:

- `env`: environment variables injected into setup, maintenance, provider
  execution, and verification commands
- `preflight`: commands that validate the environment before work starts
- `setup`: commands run when Night Shift creates a task worktree
- `maintenance`: commands run when Night Shift reattaches to an existing
  worktree

Commands are grouped by platform key: `default`, `macos`, `linux`, and
`windows`.

## Selection Rules

Environment selection is intentionally conservative:

- `plan`, including `plan --from-reviews`, resolves the default environment
  and stores that environment name in the pending run
- `start` uses the environment already stored in the selected pending run
- `resume` reuses the environment stored in the run journal
- if no environment is selected explicitly, Night Shift uses
  `default_environment`

The environment name itself is saved in the run journal, so a resumed run can
validate that the saved environment still exists before continuing.

## Generation

`night-shift init` can optionally generate a starter `worktree-setup.toml`.
Internally, Night Shift asks the selected planning provider to draft the file,
writes the generated TOML into planning artifacts, validates it, and then saves
it into the repository-local Night Shift home.

## Operational Advice

- Keep setup and maintenance commands idempotent where possible.
- Reserve environment-specific logic for genuinely different bootstraps.
- Put long-lived repo assumptions here rather than inside provider prompts.
- Treat `preflight` as the place to fail fast when the environment is not
  usable.
