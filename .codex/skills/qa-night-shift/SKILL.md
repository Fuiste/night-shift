---
name: qa-night-shift
description: Use when the user wants to QA test Night Shift against a local repo path, investigate recent Night Shift changes with small real tasks, or validate init/plan/start/status/report/resolve/resume behavior through real provider harnesses.
---

# QA Night Shift

Use this skill when the user wants an investigation-oriented Night Shift pass
against a local repository on their machine.

The user should provide:

- a local repo path
- optionally, the specific change, regression, or expected behavior to
  investigate

## Goal

Exercise the real Night Shift lifecycle in the target repo with small,
targeted tasks so you can confirm expected behavior and gather evidence.

## Start Here

Inspect the target repo before mutating anything:

- confirm the path exists and is a git repo
- inspect whether `.night-shift/` already exists
- inspect `git status --short`
- inspect configured remotes
- inspect whether the repo appears to be an intentional testing target

Treat names like `test`, `qa`, `fixture`, `sandbox`, `demo`, or `scratch` as
positive signals, not proof.

## Safety Gate

This skill is for real Night Shift runs, including real delivery behavior.

- If the repo does not clearly look like a testing repo, stop and confirm with
  the user before mutating it.
- If it does look like an intentional testing target, proceed.

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

## Investigation Flow

Prefer a small, request-shaped QA loop instead of broad autonomous work.

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

## Wrap Up

End with a QA summary tailored to the request:

- what you tested
- what happened
- whether behavior matched expectations
- concrete evidence paths
- likely root cause or next investigation steps

Keep the summary investigation-focused. The goal is to explain Night Shift
behavior, not to narrate every command unless it matters to the conclusion.
