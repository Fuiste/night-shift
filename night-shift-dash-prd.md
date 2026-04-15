# Night Shift Dash PRD

## Summary

`night-shift dash` will become the new human-first front door for Night Shift.
Instead of a monitor-only `--ui` mode attached to `start` and `resume`, Dash
will start a localhost web application that lets an operator initialize a repo,
plan work, inspect the task DAG before execution, start and resume runs, resolve
planning decisions, and audit the resulting artifacts in realtime.

This is a functional product surface, not a visual design exercise. The v1 goal
is a solid interaction shape and a trustworthy execution/audit story.

### Locked decisions

- Dash is a full front door, not a read-only monitor.
- The UI stack is pure Gleam/Lustre by default.
- Realtime updates use Server-Sent Events (SSE), not polling-first or
  websocket-first transport.
- The `dash` process owns execution of Night Shift workflows directly rather
  than shelling out to separate CLI subprocesses or introducing a new daemon.
- v1 is localhost-only, single-user, and current-repo-only.
- `start --ui` and `resume --ui` are removed in favor of `night-shift dash`.
- Dash includes guided init, browser-based planning input, browser-based
  decision resolution, DAG visualization, and audit/report/provenance surfaces.

## Problem

The current `--ui` flag is too narrow to justify being a first-class product
surface:

- it is monitor-only
- it is attached to `start` and `resume` rather than being a front door
- it relies on polling rather than a proper realtime model
- it does not help with init, planning, decision resolution, or resume
- it does not present the DAG as a primary object before execution begins
- it does not make audit, reports, provenance, and PR review links feel like a
  coherent operator experience

Night Shift already persists enough structured state to support a richer GUI:
run journals, events, reports, provenance artifacts, review-driven repo-state
snapshots, task state, worktree/runtime metadata, and delivered PR information.
The missing piece is a proper UI/control-plane surface that is shaped around how
an operator actually uses the tool.

## Goals

- Make Night Shift operable primarily from the browser.
- Show repo state, run state, and DAG state before execution starts and while a
  run is live.
- Make status, report, provenance, and raw artifacts easy to inspect and audit.
- Link directly to task PRs and review-relevant context.
- Preserve the repo-local, inspectable, durable character of Night Shift.
- Keep the first version functionally solid rather than visually polished.

## Non-Goals

- Multi-repo orchestration or a cross-repo control plane.
- Remote access, shared sessions, or multi-user coordination.
- Authentication/session hardening beyond the localhost-only model.
- A separate persistent daemon or background service shared with the CLI.
- Pixel-perfect design-system work, advanced theming, or a polished brand pass.

## Primary User

The primary user is the local operator running Night Shift inside one checked-out
repository on their own machine. This operator needs a reliable way to:

- initialize and configure Night Shift for the repo
- create or refresh a plan
- understand the DAG before starting it
- watch execution progress live
- inspect repo-state drift and review-driven lineage
- answer blocked planning questions
- audit reports, provenance, logs, and PR handoff after the run

## Product Shape

Dash is a repo-local web app started by:

```sh
night-shift dash
```

The command launches a localhost server bound to `127.0.0.1`, opens or prints a
browser URL, and hosts a single-repo workspace for the current repository. The
browser is the primary control surface for operator actions. Existing read-only
CLI surfaces such as `status`, `report`, and `provenance` remain available and
must continue to work against runs created or driven through Dash.

The workspace should be organized around the following persistent areas:

- Repo/workspace header
- Current run summary
- DAG graph plus synchronized task list/detail pane
- Repo-state/review context panel when available
- Live event timeline
- Status/report/provenance/artifact inspection area

## Operator Journeys

### 1. Uninitialized repo -> guided init

When the repo has not been initialized, Dash should detect the missing
`.night-shift` control plane and present an onboarding flow instead of a broken
empty workspace.

The init flow must support:

- selecting the default provider
- selecting a model available to that provider
- choosing whether to generate `./.night-shift/worktree-setup.toml`
- confirming resulting configuration

On successful init, Dash transitions directly into the normal workspace without
requiring the operator to restart the command.

### 2. Notes planning via browser

Dash should provide a planning surface with:

- a notes textarea for pasted planning input
- an optional brief path field
- a plan action
- a `Plan From Reviews` action

The operator can plan from pasted notes, reviews, or both. After planning, Dash
must render the resulting pending DAG before execution begins.

### 3. Inspect pending DAG before start

After planning, the operator must be able to inspect:

- task dependency shape
- task kind and execution mode
- readiness/blocked/manual-attention state
- acceptance/demo details
- review-driven replacement lineage when present

The DAG should be viewable both as a graph and as a structured list so that the
operator can understand both the topology and the exact details.

### 4. Start run and watch live execution

The operator starts execution from Dash. Once started, the UI must live-update:

- run status
- task state transitions
- follow-up task insertion or DAG refreshes
- event timeline
- PR delivery updates, including direct PR links
- report/provenance availability as artifacts land

The operator should not need to refresh manually to track an active run.

### 5. Resolve blocked planning decisions in browser

If a run blocks on manual-attention planning decisions, Dash must present those
decision requests as browser-native forms, including:

- question
- rationale
- structured options when available
- recommended option when available
- freeform answer input when allowed

Submitting decisions should trigger replanning inside Dash and update the
displayed DAG without dropping the current workspace context.

### 6. Resume interrupted run

If a run was interrupted, Dash should expose resume affordances and recovery
context. The operator should be able to inspect recovery signals and then resume
the run from the browser with live updates continuing over the same Dash
session.

### 7. Audit completed, blocked, or failed runs

After a run finishes or blocks, Dash must remain useful as an audit surface. It
should make it easy to inspect:

- final status
- timeline of events
- rendered report
- provenance artifact
- raw logs/artifacts
- task-level worktree/runtime context
- delivered PRs and lineage
- review-driven repo-state drift when applicable

Refreshing the page must not destroy access to this audit surface.

## UX Requirements

### Workspace shell

Dash should present a single-repo workspace with enough context to orient the
operator immediately:

- repo root
- initialization state
- active or latest run
- high-level next action
- connection status for the realtime stream

### DAG visualization

The minimum acceptable DAG visualization is a graph-plus-list hybrid:

- a node-edge graph that shows dependency shape
- a synchronized task list/detail pane for exact inspection
- selecting a task in either surface highlights it in the other
- task state is visible in both surfaces

The list/detail pane is not a fallback; it is a required first-class part of the
experience for accessibility, precision, and auditability.

### Repo-state panel

For review-driven runs, Dash must show repo-state context including:

- captured open PR count
- captured actionable PR count
- snapshot capture time
- current open/actionable counts when live inspection is available
- drift status and drift details when known
- actionable PR list
- impacted PR list

### Timeline

Dash must present a first-class event timeline that updates live during active
runs and remains readable afterward. Timeline events should be filterable at
least by run-wide vs task-scoped events.

### Report, status, provenance, and artifacts

Dash should expose status, report, provenance, and raw artifacts as primary
surfaces, not as buried debug links. The operator should be able to inspect:

- human-readable status summary
- rendered report
- provenance path and rendered provenance view
- raw artifact links/downloads for report, provenance, and logs

### Task detail

Per-task detail should include, when available:

- title and task id
- description, acceptance criteria, and demo plan
- task kind and execution mode
- dependencies and dependents
- current state
- branch name
- PR number
- PR URL
- worktree path
- runtime context summary
- summary/output text
- replacement lineage context for review-driven work

## Realtime Model

Dash uses Server-Sent Events as the default realtime transport.

### Realtime requirements

- The browser connects to an SSE stream after loading the workspace.
- The SSE stream is the primary source of live updates during an active Dash
  session.
- Browser commands use plain HTTP actions rather than long-lived bidirectional
  sockets.
- Refreshing the page reconnects to the SSE stream and reloads the current
  repo/run state from durable storage.
- Polling is not the primary model in v1.

### Event categories

The SSE contract must support structured events for:

- repo/run bootstrap state
- task state transitions
- timeline events
- DAG refreshes after planning or replanning
- delivery updates, including PR URLs
- run completion, blockage, or failure

The implementation does not need to freeze final endpoint paths in this PRD,
but it must commit to a structured command API plus a structured SSE event
model.

## Architecture

### Topology

- `night-shift dash` starts a localhost web server bound to `127.0.0.1`.
- The Dash process owns command execution for init, plan, resolve, start, and
  resume.
- The web app is implemented with Lustre in a Gleam-native stack.
- Existing journal and artifact persistence remain the source of truth.
- Live session state augments persisted run state for realtime rendering but
  does not replace the journal as the durable record.

### Reuse strategy

The implementation should bias toward reusing the existing Night Shift domain
and usecase layers rather than bypassing them:

- configuration and repo initialization logic
- planning and replanning flows
- resolve flow and decision model
- start and resume orchestration
- status/report/provenance rendering
- journal and artifact persistence
- repo-state and review-lineage projections

The current minimal dashboard/server may be evolved or replaced, but the new
Dash architecture should preserve existing durable state and existing business
rules wherever possible.

### Execution ownership

Dash owns execution directly inside its process. This means:

- browser actions do not shell out to `night-shift` subprocesses
- CLI output parsing is not the integration strategy
- a new daemon/control-plane service is not introduced for v1

This keeps the architecture closer to a pure application runtime and avoids the
usual class of bugs produced by treating stringly subprocess output as an API.

## Public Interface Changes

### CLI changes

Add:

- `night-shift dash`

Remove:

- `night-shift start --ui`
- `night-shift resume --ui`

Keep:

- `night-shift init`
- `night-shift plan`
- `night-shift resolve`
- `night-shift start`
- `night-shift resume`
- `night-shift status`
- `night-shift report`
- `night-shift provenance`
- other existing read/repair flows

The CLI remains a valid automation and escape-hatch surface, but Dash becomes
the intended human-first GUI entrypoint.

### Browser actions

Dash must expose browser-driven actions for:

- init
- plan with notes textarea and optional doc path
- plan from reviews
- resolve decisions
- start
- resume

### API contract shape

The implementation must define:

- a structured command API for browser actions
- a structured SSE stream for live updates
- a state bootstrap endpoint or equivalent mechanism for initial page load

Exact endpoint names are intentionally left open, but the contract must support
the workflows described in this document without scraping CLI text.

## Data And State Requirements

Dash must be able to render the following from current state plus live updates:

- repo initialization status
- latest and active run identity
- run status and timestamps
- task DAG, task metadata, and task state
- decision requests and recorded decisions
- repo-state review snapshot and drift
- lineage for superseded PR work
- timeline events
- report and provenance locations/content
- PR delivery information, including URL
- task worktree and runtime context

Where data already exists in persisted Night Shift artifacts, Dash should
consume it rather than inventing a parallel store.

## Audit Requirements

Dash is not only an execution view; it is an audit surface.

v1 must include:

- a first-class event timeline
- provenance visibility
- links to report, provenance, and raw log artifacts
- PR links from delivered tasks
- review-driven repo snapshot, actionable/impacted PR lists, and drift display
- durable post-refresh access to completed, blocked, and failed runs

The audit story should privilege inspectability over clever animation.

## Error Handling And Recovery

Dash must handle the following cleanly:

- local server startup failures
- inability to bind the localhost port
- malformed or failed command submissions
- SSE disconnect/reconnect
- browser refresh during active execution
- blocked runs
- failed runs
- interrupted runs that can be resumed
- runs that are no longer safe to resume

The UI should always preserve or restore enough context that the operator can
understand what happened and what to do next.

## Success Criteria

Dash is successful in v1 if a Night Shift operator can do the complete common
workflow from the browser:

1. initialize the repo if needed
2. plan work from notes or reviews
3. inspect the DAG before execution
4. start the run
5. watch it update live
6. resolve blocked planning decisions in the browser if necessary
7. resume if interrupted
8. audit the result, artifacts, and PRs afterward

## Acceptance Scenarios

The implementation must satisfy the following acceptance scenarios:

1. Running `night-shift dash` on an uninitialized repo opens a guided init flow
   and can complete initialization without restarting Dash.
2. Planning from pasted notes creates a pending run and renders the planned DAG
   before execution begins.
3. Planning from reviews renders repo-state snapshot data and
   actionable/impacted PR context.
4. Starting from Dash streams live task and timeline updates and eventually
   shows delivered PR links.
5. A blocked run can be resolved fully from the browser and replans without
   losing workspace context.
6. An interrupted run can be resumed from Dash with live updates.
7. Completed, blocked, and failed runs all remain auditable after refresh via
   report, provenance, timeline, and artifact links.
8. The DAG view remains synchronized between graph and list/detail panes.
9. Dash binds only to localhost and operates only on the current repo.
10. CLI read commands still work against runs created and driven through Dash.

## Assumptions And Defaults

- Output artifact: `night-shift-dash-prd.md` at the repo root.
- v1 is local-only, single-user, and repo-local.
- Realtime means SSE-driven live updates, not websocket-first and not
  polling-first.
- “Full front door” includes guided init and browser-based decision resolution,
  not merely `start` and `resume`.
- Visual polish is explicitly secondary to information architecture,
  interaction shape, and auditability.
- Lustre is the intended UI framework, and a pure Gleam/Lustre bias is a
  strategic constraint rather than an implementation afterthought.
