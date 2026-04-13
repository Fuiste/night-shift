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

[environments.default.runtime]
# Optional aliases for deterministic derived ports.
# named_ports = ["web", "api"]

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
- `runtime`: optional runtime aliases. v0 supports `named_ports = ["web",
  "api"]` and nothing else
- `preflight`: commands that validate the environment before work starts
- `setup`: commands run when Night Shift creates a task worktree
- `maintenance`: commands run when Night Shift reattaches to an existing
  worktree

Commands are grouped by platform key: `default`, `macos`, `linux`, and
`windows`.

Runtime identity is always enabled, even when `runtime` is omitted. The
runtime subsection only adds friendly named port aliases on top of the default
generated values.

## Runtime Identity

Before Night Shift runs environment setup or provider execution for a task, it
derives a stable per-task runtime identity from the run ID and task ID. That
identity is persisted in the run journal and reused on resume, so an existing
task does not silently pick up new runtime values after a config edit.

Night Shift always injects:

- `NIGHT_SHIFT_WORKTREE_ID`
- `NIGHT_SHIFT_COMPOSE_PROJECT`
- `NIGHT_SHIFT_PORT_BASE`
- `NIGHT_SHIFT_RUNTIME_DIR`
- `NIGHT_SHIFT_RUNTIME_ENV_FILE`
- `NIGHT_SHIFT_RUNTIME_MANIFEST`
- `NIGHT_SHIFT_HANDOFF_FILE`

If `named_ports` is configured, Night Shift also injects one variable per
normalized alias:

- `NIGHT_SHIFT_PORT_WEB`
- `NIGHT_SHIFT_PORT_API`
- and so on

The generated values are meant to be consumed by your existing setup scripts,
Compose files, and verification commands. Night Shift does not reserve ports,
start services, or manage secrets.

## Validation Rules

Night Shift rejects invalid worktree setup config before any task worktrees
launch.

- `env` may not define variables with the reserved `NIGHT_SHIFT_` prefix
- `runtime.named_ports` entries must normalize to unique uppercase identifiers
- empty names are rejected
- names that normalize to duplicates are rejected
- more than 16 named ports are rejected

## Generated Artifacts

Each prepared task gets runtime artifacts under the run directory, not inside
the git worktree:

- `./.night-shift/runs/<run-id>/runtime/<task-id>/night-shift.env`
- `./.night-shift/runs/<run-id>/runtime/<task-id>/night-shift.runtime.json`
- `./.night-shift/runs/<run-id>/runtime/<task-id>/night-shift.handoff.md`

`night-shift.env` is plain `KEY=VALUE` output for shell scripts and Compose.
`night-shift.runtime.json` is the machine-readable source of truth.
`night-shift.handoff.md` is the short human-and-agent summary.

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
- Prefer consuming `NIGHT_SHIFT_RUNTIME_ENV_FILE` or
  `NIGHT_SHIFT_RUNTIME_MANIFEST` from scripts instead of re-deriving port or
  naming schemes yourself.
