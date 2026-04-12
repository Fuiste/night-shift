---
title: Configuration
description: Configure profiles, phase defaults, verification commands, and provider overrides.
permalink: /configuration/
---

# Configuration

Repository-owned configuration lives in `./.night-shift/config.toml`.

Tracked config files:

- `./.night-shift/config.toml`
- `./.night-shift/worktree-setup.toml`

Runtime artifacts stay alongside them under the same repo-local home.

## Example

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
mode = "ask"

[verification]
commands = ["gleam test"]
```

If `config.toml` is empty, Night Shift still works. The built-in default
profile is named `default`, targets `codex`, and leaves model and reasoning at
provider defaults.

## Profiles

Profiles are the main operator abstraction. Each profile can define:

- `provider`: currently `codex` or `cursor`
- `model`: provider model id
- `reasoning`: normalized level, one of `low`, `medium`, `high`, `xhigh`
- `provider_overrides`: escape hatch for provider-specific settings that do not
  fit the normalized surface

Phase selectors decide which profile each command uses by default:

- `planning_profile` for `night-shift plan`
- `execution_profile` for `night-shift start`
- `review_profile` for `night-shift review`
- `default_profile` as the fallback when a phase selector is unset

## Override Precedence

Night Shift resolves agent settings in this order:

1. built-in defaults
2. repo config profile values
3. command-level overrides

That means `--profile`, `--provider`, `--model`, and `--reasoning` override
what the chosen profile would otherwise resolve for that invocation.

One important wrinkle: `start` does not accept those overrides. It uses the
planning and execution agent configs already saved in the pending run. `resume`
also reuses the saved configs instead of re-resolving them.

## Provider Overrides

Use `[profiles.<name>.provider_overrides]` sparingly, and only for settings
Night Shift does not normalize.

Current support:

- Codex: no provider overrides yet
- Cursor: `mode = "plan"` or `mode = "ask"`

Night Shift fails fast when a normalized control cannot be represented by the
selected provider. For example, Cursor can select a model but does not support
the generic `reasoning` control.

## Verification and Delivery Settings

These top-level settings shape how Night Shift delivers completed work:

- `base_branch`: the base branch used for worktree branching and PR delivery
- `max_workers`: maximum concurrent task execution
- `branch_prefix`: branch prefix for Night Shift-created branches
- `pr_title_prefix`: prefix for pull request titles
- `notifiers`: currently `console` and `report_file`
- `[verification].commands`: commands to run locally before PR delivery

Example configs live in:

- `examples/config-single-profile.toml`
- `examples/config-phase-profiles.toml`
- `examples/config-provider-overrides.toml`
