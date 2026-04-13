---
title: Configuration
description: Configure profiles, phase defaults, verification commands, handoff behavior, and provider overrides.
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

[handoff]
enabled = true
pr_body_mode = "append"
managed_comment = false
provenance = "structured"
pr_body_prefix_path = ".night-shift/pr-handoff-prefix.md"
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
- `planning_profile` also governs `night-shift plan --from-reviews`
- `execution_profile` for `night-shift start`
- `default_profile` as the fallback when a phase selector is unset

`review_profile` is deprecated. Night Shift still accepts it during the current
pre-1.0 transition, but review-driven planning now uses `planning_profile` and
emits a warning when `review_profile` is set.

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

## Handoff Settings

`[handoff]` controls the optional reviewer-facing metadata that Night Shift can
overlay onto delivered pull requests.

Supported fields:

- `enabled`: master switch for Night Shift handoff output
- `pr_body_mode`: `off`, `append`, or `prepend`
- `managed_comment`: whether Night Shift owns and updates one incremental PR
  comment with "Since Last Review" deltas
- `provenance`: `minimal`, `light`, or `structured`
- `include_files_touched`
- `include_acceptance`
- `include_stack_context`
- `include_verification_summary`
- `pr_body_prefix_path`, `pr_body_suffix_path`
- `comment_prefix_path`, `comment_suffix_path`

When `[handoff]` is absent, Night Shift uses the conservative default:

- handoff enabled
- PR body overlay appended
- managed comment disabled
- structured provenance
- files touched, stack context, and verification summary included

Snippet paths are repo-relative markdown fragments. Night Shift splices them
around its generated handoff sections; they augment the structured layout and
do not replace it. If a configured snippet path cannot be read, Night Shift
falls back to generated content and records a warning event.

Example configs live in:

- `examples/config-single-profile.toml`
- `examples/config-phase-profiles.toml`
- `examples/config-provider-overrides.toml`
