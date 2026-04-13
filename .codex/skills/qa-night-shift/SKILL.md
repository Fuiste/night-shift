---
name: qa-night-shift
description: Use when the user wants to QA test Night Shift against a user-specified scratch repo path, install the current worktree CLI, and run an approval-gated real-provider pass to validate init/plan/start/status/report/resolve/resume behavior.
---

# QA Night Shift

Use this skill when the user wants an investigation-oriented Night Shift pass
against a user-specified scratch repository on their machine.

The user should provide:

- a local scratch repo path
- optionally, the specific change, regression, or expected behavior to
  investigate

## Goal

Exercise the real Night Shift lifecycle in the target scratch repo with small,
targeted tasks so you can confirm expected behavior and gather evidence.

Before the QA run starts, install the currently worked-on Night Shift CLI from
the present worktree and show the user exactly what you plan to do. Do not run
the actual QA pass until the user explicitly approves it.

## Start Here

Inspect the target repo before mutating anything:

- confirm the path exists and is a git repo
- inspect whether `.night-shift/` already exists
- inspect `git status --short`
- inspect configured remotes
- inspect whether the repo appears to be an intentional scratch or testing
  target

Treat names like `test`, `qa`, `fixture`, `sandbox`, `demo`, or `scratch` as
positive signals, not proof.

Then install the local CLI from the current worktree before proposing the QA
pass.

Run:

```sh
.codex/skills/update-local-night-shift-cli/scripts/install_local_cli.sh --source /path/to/current/worktree
```

Use the actual current repo path for `--source`. Let the install script derive
its label unless the user asked for a specific one.

## Safety Gate

This skill is for real Night Shift runs, including real delivery behavior and
real inference spend.

- If the repo does not clearly look like a scratch or testing repo, stop and
  confirm with the user before mutating it.
- If it does look like an intentional testing target, proceed.
- Even for an obvious scratch repo, do not run `night-shift plan`,
  `night-shift start`, `night-shift resume`, or other inference-consuming QA
  steps until the user approves the presented plan.

Do not quietly assume a normal product repo is safe to use for QA.

## Real Harness Rules

Use the real Night Shift path unless the user explicitly asks for fixture-mode
testing.

- Do use the normal `night-shift` CLI
- Do use real local provider CLIs
- Do allow real end-to-end Night Shift behavior, including delivery when it
  occurs
- Do not use `night-shift --demo`
- Do not use `NIGHT_SHIFT_FAKE_PROVIDER`
- Do not swap in fake GitHub or other fake delivery plumbing unless the user
  explicitly asks for that kind of test

## Repo Setup

- If `.night-shift/` is missing, initialize Night Shift in the target repo.
- If Night Shift state already exists, inspect it first and reset only when
  needed.

Reset examples:

- stale or blocked run state
- unrelated prior QA state that would confuse the current investigation
- existing state that prevents a clean reproduction

Do not reset by default.

## Approval Gate

After inspection and local CLI installation, pause and present the exact QA
pass before executing it.

Include:

- the target scratch repo path
- whether `.night-shift/` already exists
- the current repo cleanliness signals that matter to the run
- which Night Shift CLI install you just pointed `night-shift` at
- the small task or notes you intend to use
- the specific `night-shift` commands you expect to run
- a brief reminder that the pass uses a real repo and real inference tokens

Wait for an explicit acceptance from the user. No acceptance, no QA run.

## Investigation Flow

Prefer a small, request-shaped QA loop instead of broad autonomous work.

Only enter this section after the approval gate is satisfied.

Typical flow:

1. inspect repo state and Night Shift state
2. initialize if needed
3. write a small `plan` note tied to the behavior being tested
4. run `night-shift plan`
5. inspect `night-shift status`
6. run `night-shift start`
7. inspect `night-shift report`
8. use `night-shift resolve` or `night-shift resume` only if the run actually
   requires it

For review-driven investigations, replace steps 3-4 with:

1. inspect open Night Shift PRs and their review state
2. run `night-shift plan --from-reviews`
3. optionally add `--notes <file-or-inline-text>` when the user wants extra
   operator context blended into the replanning pass

In review-driven runs, pay attention to repo-state evidence:

- the stored open-PR snapshot captured during planning
- whether `status`, `report`, or the dashboard show repo-state drift
- whether `night-shift report` shows the actionable/impacted subtree and
  replacement lineage, while the persisted `report.md` remains readable
  without live GitHub refresh
- whether successor PRs include `Supersedes #...`
- whether persisted tasks carry derived `superseded_pr_numbers` even though the
  planner prompt asks providers to leave them empty
- whether root-level feedback marks descendants as impacted in the review-driven prompt or resulting plan
- whether review-driven replanning blocks with a clear validation error when
  the replacement graph cannot be mapped cleanly onto the impacted PR subtree
- when the note explicitly asks for a strict serial stack, whether the planner
  is retried or rejected unless implementation tasks form one chain
- whether superseded PRs stay open until the replacement run completes
- whether old PRs are commented on and auto-closed only after successful
  completion
- whether completed task worktrees remain mounted after success, which is the
  current intended hygiene model
- whether successful replacement runs automatically prune only the clean
  worktrees from older superseded successful runs
- whether dirty or missing superseded worktrees are retained and called out as
  warnings instead of being removed silently
- whether `reset` removes Night Shift state and mounted worktrees without
  deleting local branches or closing remote PRs
- whether noisy-but-valid execution payloads are accepted with
  `execution_payload_warning` evidence instead of being routed to manual
  attention
- whether malformed execution payloads with candidate worktree changes trigger
  exactly one JSON-only payload-repair retry before Night Shift falls back to
  manual attention
- whether `status` and `report` show payload-repair attempts, successes, and
  failures with usable artifact paths

In delivery-focused investigations, also validate reviewer handoff behavior
when the repo config uses `[handoff]`:

- whether the delivered PR body includes or omits the Night Shift-owned
  handoff overlay according to `pr_body_mode`
- whether Night Shift preserves manual PR text outside its marked body region
  across later updates
- whether configured snippet files are spliced into the PR body or managed
  comment in the expected order
- whether unreadable snippet paths degrade to `pr_handoff_warning` evidence
  instead of blocking PR delivery
- whether managed comments stay disabled by default and only appear when
  `[handoff].managed_comment = true`
- whether the managed comment is updated in place instead of adding new comment
  noise on each delivery
- whether handoff provenance labels clearly separate deterministic Night
  Shift-owned evidence from provider-authored summary text

Use small tasks that validate the requested behavior instead of inviting large
feature work.

## Evidence to Collect

Ground the investigation in artifacts, not guesses.

Collect evidence from:

- relevant CLI output
- the current report path printed by Night Shift
- run journal paths under `.night-shift/runs/`
- relevant logs for the failing or surprising step
- PR or delivery results when they happen
- any verification output tied to the run

When a run finishes, inspect the generated report before drawing conclusions.

## Follow Up

After the approved QA pass finishes, follow up in the way that best matches the
chat context: investigation summary, bug confirmation, suggested next step,
request for a narrower rerun, or another concrete handoff.

Always include a QA summary tailored to the request:

- what you tested
- what happened
- whether behavior matched expectations
- concrete evidence paths
- likely root cause or next investigation steps

Keep the summary investigation-focused. The goal is to explain Night Shift
behavior, not to narrate every command unless it matters to the conclusion.
