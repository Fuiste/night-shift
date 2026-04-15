import filepath
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import night_shift/domain/decisions as decision_domain
import night_shift/domain/summary as domain_summary
import night_shift/domain/task_graph
import night_shift/git
import night_shift/infra/terminal_ui
import night_shift/journal
import night_shift/orchestrator
import night_shift/project
import night_shift/shell
import night_shift/system
import night_shift/types
import night_shift/usecase/result as workflow
import night_shift/usecase/support/runs
import night_shift/worktree_setup
import simplifile

type InteractiveBlocker {
  SetupBlocker(blocker: types.RecoveryBlocker)
  ImplementationBlocker(task: types.Task)
  DecisionBlocker(tasks: List(types.Task))
  PlanningSyncBlocker
}

pub fn execute(
  repo_root: String,
  selector: types.RunSelector,
  task_id: Option(String),
  action: Option(types.ResolveAction),
  config: types.Config,
  collect_decisions: fn(types.RunRecord, List(types.Task)) ->
    Result(#(List(types.RecordedDecision), List(types.RunEvent)), String),
) -> Result(workflow.ResolveResult, String) {
  use run <- result.try(runs.load_resolvable_run(repo_root, selector))
  case task_id, action {
    Some(requested_task_id), Some(requested_action) ->
      resolve_action(run, requested_task_id, requested_action, config)
    None, None -> resolve_interactively(run, config, collect_decisions)
    None, Some(requested_action) ->
      resolve_run_recovery_action(run, requested_action, config)
    Some(_), None ->
      Error(
        "`night-shift resolve --task <task-id>` requires exactly one action flag.",
      )
  }
}

fn resolve_interactively(
  run: types.RunRecord,
  config: types.Config,
  collect_decisions: fn(types.RunRecord, List(types.Task)) ->
    Result(#(List(types.RecordedDecision), List(types.RunEvent)), String),
) -> Result(workflow.ResolveResult, String) {
  case next_interactive_blocker(run) {
    Some(SetupBlocker(blocker)) ->
      prompt_for_setup_recovery(run, blocker, config, collect_decisions)
    Some(ImplementationBlocker(task)) ->
      prompt_for_implementation_recovery(run, task, config, collect_decisions)
    Some(DecisionBlocker(tasks)) ->
      collect_decision_blockers(run, tasks, config, collect_decisions)
    Some(PlanningSyncBlocker) ->
      continue_resolve_run(run, config, collect_decisions)
    None ->
      Ok(workflow.ResolveResult(
        run: run,
        warnings: [],
        next_action: runs.next_action_for_run(run),
        summary: Some(
          "Run "
          <> run.run_id
          <> " has no remaining blockers for `night-shift resolve` to discharge.",
        ),
      ))
  }
}

fn next_interactive_blocker(run: types.RunRecord) -> Option(InteractiveBlocker) {
  case runs.active_recovery_blocker(run) {
    Some(blocker) -> Some(SetupBlocker(blocker))
    None ->
      case decision_domain.implementation_blocking_tasks(run) {
        [task, ..] -> Some(ImplementationBlocker(task))
        [] ->
          case decision_domain.unresolved_manual_attention_tasks(run) {
            [_, ..] as tasks -> Some(DecisionBlocker(tasks))
            [] ->
              case run.planning_dirty {
                True -> Some(PlanningSyncBlocker)
                False -> None
              }
          }
      }
  }
}

fn prompt_for_setup_recovery(
  run: types.RunRecord,
  blocker: types.RecoveryBlocker,
  config: types.Config,
  collect_decisions: fn(types.RunRecord, List(types.Task)) ->
    Result(#(List(types.RecordedDecision), List(types.RunEvent)), String),
) -> Result(workflow.ResolveResult, String) {
  let inspection = render_setup_inspection(run, blocker)
  io.println(inspection)
  let selection =
    terminal_ui.select_from_labels(
      "Choose a recovery action:",
      [
        "Inspect and stop",
        "Continue this run with a one-shot waiver of the failed gate",
        "Abandon this run",
        "Stop without changing the run",
      ],
      0,
    )

  case selection {
    0 ->
      Ok(workflow.ResolveResult(
        run: run,
        warnings: [],
        next_action: runs.next_action_for_run(run),
        summary: Some(inspection),
      ))
    1 -> {
      use resolved <- result.try(apply_setup_continue(run, blocker))
      resolve_interactively(resolved, config, collect_decisions)
    }
    2 ->
      apply_setup_abandon(run, blocker)
      |> result.map(as_resolve_result(
        _,
        Some(
          "Operator abandoned the blocked run before implementation resumed.",
        ),
      ))
    _ ->
      Ok(workflow.ResolveResult(
        run: run,
        warnings: [],
        next_action: runs.next_action_for_run(run),
        summary: Some(
          "Stopped without changing the blocked-before-implementation recovery state.",
        ),
      ))
  }
}

fn prompt_for_implementation_recovery(
  run: types.RunRecord,
  task: types.Task,
  config: types.Config,
  collect_decisions: fn(types.RunRecord, List(types.Task)) ->
    Result(#(List(types.RecordedDecision), List(types.RunEvent)), String),
) -> Result(workflow.ResolveResult, String) {
  let inspection = render_implementation_inspection(run, task)
  io.println(inspection)
  let selection =
    terminal_ui.select_from_labels(
      "Choose a recovery action:",
      [
        "Inspect and stop",
        "Continue this task from the retained worktree",
        "Mark this task complete and run verification",
        "Abandon this partial work and replan",
        "Stop without changing the run",
      ],
      0,
    )

  case selection {
    0 ->
      Ok(workflow.ResolveResult(
        run: run,
        warnings: [],
        next_action: runs.next_action_for_run(run),
        summary: Some(inspection),
      ))
    1 -> {
      use resolved <- result.try(apply_continue(run, task))
      resolve_interactively(resolved, config, collect_decisions)
    }
    2 -> {
      use resolved <- result.try(apply_complete(run, task, config))
      resolve_interactively(resolved, config, collect_decisions)
    }
    3 -> {
      use resolved <- result.try(apply_abandon(run, task, config))
      resolve_interactively(resolved, config, collect_decisions)
    }
    _ ->
      Ok(workflow.ResolveResult(
        run: run,
        warnings: [],
        next_action: runs.next_action_for_run(run),
        summary: Some(
          "Stopped without changing blocked implementation recovery for task `"
          <> task.id
          <> "`.",
        ),
      ))
  }
}

fn resolve_action(
  run: types.RunRecord,
  task_id: String,
  action: types.ResolveAction,
  config: types.Config,
) -> Result(workflow.ResolveResult, String) {
  use task <- result.try(find_implementation_task(run, task_id))
  case action {
    types.ResolveInspect ->
      Ok(workflow.ResolveResult(
        run: run,
        warnings: [],
        next_action: runs.next_action_for_run(run),
        summary: Some(render_implementation_inspection(run, task)),
      ))
    types.ResolveContinue ->
      apply_continue(run, task)
      |> result.map(as_resolve_result(_, None))
    types.ResolveComplete ->
      apply_complete(run, task, config)
      |> result.map(as_resolve_result(_, None))
    types.ResolveAbandon ->
      apply_abandon(run, task, config)
      |> result.map(as_resolve_result(_, None))
  }
}

fn resolve_run_recovery_action(
  run: types.RunRecord,
  action: types.ResolveAction,
  _config: types.Config,
) -> Result(workflow.ResolveResult, String) {
  use blocker <- result.try(case runs.active_recovery_blocker(run) {
    Some(active) -> Ok(active)
    None ->
      Error(
        "`night-shift resolve` action flags without `--task` are only valid for blocked setup recovery.",
      )
  })

  case action {
    types.ResolveInspect ->
      Ok(workflow.ResolveResult(
        run: run,
        warnings: [],
        next_action: runs.next_action_for_run(run),
        summary: Some(render_setup_inspection(run, blocker)),
      ))
    types.ResolveContinue ->
      apply_setup_continue(run, blocker)
      |> result.map(as_resolve_result(_, None))
    types.ResolveAbandon ->
      apply_setup_abandon(run, blocker)
      |> result.map(as_resolve_result(_, None))
    types.ResolveComplete ->
      Error(
        "Blocked setup recovery does not support `--complete`; use `--continue` or `--abandon` instead.",
      )
  }
}

fn collect_decision_blockers(
  run: types.RunRecord,
  blocked_tasks: List(types.Task),
  config: types.Config,
  collect_decisions: fn(types.RunRecord, List(types.Task)) ->
    Result(#(List(types.RecordedDecision), List(types.RunEvent)), String),
) -> Result(workflow.ResolveResult, String) {
  use #(new_decisions, warning_events) <- result.try(collect_decisions(
    run,
    blocked_tasks,
  ))
  let updated_run =
    types.RunRecord(
      ..run,
      decisions: decision_domain.merge_recorded_decisions(
        run.decisions,
        new_decisions,
      ),
      planning_dirty: True,
    )
  use rewritten_run <- result.try(journal.rewrite_run(updated_run))
  use warned_run <- result.try(append_run_events(rewritten_run, warning_events))
  use signaled_run <- result.try(append_decision_recorded_events(
    warned_run,
    new_decisions,
  ))
  use dirty_run <- result.try(
    append_run_events(signaled_run, [
      planning_sync_pending_event(),
    ]),
  )
  resolve_interactively(dirty_run, config, collect_decisions)
}

fn continue_resolve_run(
  run: types.RunRecord,
  config: types.Config,
  collect_decisions: fn(types.RunRecord, List(types.Task)) ->
    Result(#(List(types.RecordedDecision), List(types.RunEvent)), String),
) -> Result(workflow.ResolveResult, String) {
  use replanned_run <- result.try(orchestrator.replan(run))
  case next_interactive_blocker(replanned_run) {
    Some(SetupBlocker(_))
    | Some(DecisionBlocker(_))
    | Some(ImplementationBlocker(_))
    | Some(PlanningSyncBlocker) ->
      resolve_interactively(replanned_run, config, collect_decisions)
    None -> Ok(as_resolve_result(replanned_run, None))
  }
}

fn apply_continue(
  run: types.RunRecord,
  task: types.Task,
) -> Result(types.RunRecord, String) {
  use _ <- result.try(require_retained_worktree(task))
  let updated_task = types.Task(..task, state: types.Ready, summary: "")
  let updated_run =
    types.RunRecord(
      ..run,
      tasks: task_graph.replace_task(run.tasks, updated_task)
        |> task_graph.refresh_ready_states,
    )
  use rewritten_run <- result.try(journal.rewrite_run(updated_run))
  use evented_run <- result.try(journal.append_event(
    rewritten_run,
    types.RunEvent(
      kind: "task_progress",
      at: system.timestamp(),
      message: "Operator approved continuation from the retained worktree.",
      task_id: Some(task.id),
    ),
  ))
  persist_resolved_run(evented_run)
}

fn apply_setup_continue(
  run: types.RunRecord,
  blocker: types.RecoveryBlocker,
) -> Result(types.RunRecord, String) {
  let updated_tasks = case blocker.task_id {
    Some(task_id) -> mark_task_ready_for_retry(run.tasks, task_id)
    None -> run.tasks
  }
  let updated_run =
    types.RunRecord(
      ..run,
      status: types.RunPending,
      recovery_blocker: Some(
        types.RecoveryBlocker(..blocker, disposition: types.RecoveryWaivedOnce),
      ),
      tasks: task_graph.refresh_ready_states(updated_tasks),
    )
  use rewritten_run <- result.try(journal.rewrite_run(updated_run))
  use evented_run <- result.try(journal.append_event(
    rewritten_run,
    types.RunEvent(
      kind: "setup_recovery_approved",
      at: system.timestamp(),
      message: "Operator approved a one-shot waiver of the failed "
        <> types.recovery_blocker_phase_to_string(blocker.phase)
        <> " "
        <> types.recovery_blocker_kind_to_string(blocker.kind)
        <> " gate.",
      task_id: blocker.task_id,
    ),
  ))
  journal.mark_status(
    evented_run,
    types.RunPending,
    "Night Shift is ready to retry after operator-approved setup recovery.",
  )
}

fn apply_setup_abandon(
  run: types.RunRecord,
  blocker: types.RecoveryBlocker,
) -> Result(types.RunRecord, String) {
  let abandoned_run = types.RunRecord(..run, recovery_blocker: None)
  use rewritten_run <- result.try(journal.rewrite_run(abandoned_run))
  use evented_run <- result.try(journal.append_event(
    rewritten_run,
    types.RunEvent(
      kind: "run_abandoned",
      at: system.timestamp(),
      message: "Operator abandoned the blocked run after "
        <> types.recovery_blocker_phase_to_string(blocker.phase)
        <> " "
        <> types.recovery_blocker_kind_to_string(blocker.kind)
        <> " stopped execution before implementation.",
      task_id: blocker.task_id,
    ),
  ))
  journal.mark_status(
    evented_run,
    types.RunFailed,
    "Operator abandoned the blocked run before implementation could continue.",
  )
}

fn apply_complete(
  run: types.RunRecord,
  task: types.Task,
  config: types.Config,
) -> Result(types.RunRecord, String) {
  use worktree_path <- result.try(require_retained_worktree(task))
  let changed_files =
    git.changed_files(
      worktree_path,
      filepath.join(
        run.run_path,
        "logs/" <> task.id <> ".resolve.complete.git.log",
      ),
    )
  let verification_log =
    filepath.join(run.run_path, "logs/" <> task.id <> ".verify.log")

  case verify_retained_worktree(config, run, task, verification_log) {
    Ok(output) -> {
      let updated_task =
        types.Task(
          ..task,
          state: types.Completed,
          summary: "Operator completed retained work and verification passed."
            <> changed_files_summary(changed_files),
        )
      let updated_run =
        types.RunRecord(
          ..run,
          tasks: task_graph.replace_task(run.tasks, updated_task)
            |> task_graph.refresh_ready_states,
        )
      use rewritten_run <- result.try(journal.rewrite_run(updated_run))
      use progressed_run <- result.try(journal.append_event(
        rewritten_run,
        types.RunEvent(
          kind: "task_progress",
          at: system.timestamp(),
          message: "Operator marked retained work complete and verification passed.",
          task_id: Some(task.id),
        ),
      ))
      use verified_run <- result.try(journal.append_event(
        progressed_run,
        types.RunEvent(
          kind: "task_verified",
          at: system.timestamp(),
          message: "Verification passed for " <> task.title,
          task_id: Some(task.id),
        ),
      ))
      let _ = output
      persist_resolved_run(verified_run)
    }
    Error(output) -> {
      let updated_task =
        types.Task(
          ..task,
          state: types.ManualAttention,
          summary: "Primary blocker: verification failed.\n\nEnvironment notes:\nVerification log: "
            <> verification_log
            <> "\n"
            <> output,
        )
      let updated_run =
        types.RunRecord(
          ..run,
          tasks: task_graph.replace_task(run.tasks, updated_task),
        )
      use rewritten_run <- result.try(journal.rewrite_run(updated_run))
      use attention_run <- result.try(journal.append_event(
        rewritten_run,
        types.RunEvent(
          kind: "task_manual_attention",
          at: system.timestamp(),
          message: updated_task.summary,
          task_id: Some(task.id),
        ),
      ))
      persist_resolved_run(attention_run)
    }
  }
}

fn apply_abandon(
  run: types.RunRecord,
  task: types.Task,
  _config: types.Config,
) -> Result(types.RunRecord, String) {
  use _ <- result.try(append_recovery_note(run, task))
  use rewritten_run <- result.try(journal.rewrite_run(
    types.RunRecord(..run, planning_dirty: True),
  ))
  use evented_run <- result.try(journal.append_event(
    rewritten_run,
    types.RunEvent(
      kind: "task_progress",
      at: system.timestamp(),
      message: "Operator abandoned retained partial work and requested replanning.",
      task_id: Some(task.id),
    ),
  ))
  case orchestrator.replan(evented_run) {
    Ok(replanned_run) -> Ok(replanned_run)
    Error(message) -> {
      use failed_replan_run <- result.try(journal.append_event(
        evented_run,
        types.RunEvent(
          kind: "planning_recovery_failed",
          at: system.timestamp(),
          message: "Night Shift could not replan after abandoning retained work: "
            <> message,
          task_id: Some(task.id),
        ),
      ))
      journal.mark_status(
        failed_replan_run,
        types.RunBlocked,
        "Night Shift could not replan after abandoning retained work. Inspect the report and rerun `night-shift resolve`.",
      )
    }
  }
}

fn find_implementation_task(
  run: types.RunRecord,
  task_id: String,
) -> Result(types.Task, String) {
  case
    list.find(decision_domain.implementation_blocking_tasks(run), fn(task) {
      task.id == task_id
    })
  {
    Ok(task) -> Ok(task)
    Error(_) ->
      Error(
        "Task `"
        <> task_id
        <> "` is not a blocked implementation-recovery task for run "
        <> run.run_id
        <> ".",
      )
  }
}

fn require_retained_worktree(task: types.Task) -> Result(String, String) {
  case task.worktree_path {
    "" ->
      Error(
        "Task `"
        <> task.id
        <> "` has no retained worktree path recorded for recovery.",
      )
    path ->
      case simplifile.is_directory(path) {
        Ok(True) -> Ok(path)
        Ok(False) ->
          Error(
            "Task `"
            <> task.id
            <> "` retained worktree is missing from disk: "
            <> path,
          )
        Error(error) ->
          Error(
            "Unable to inspect retained worktree for task `"
            <> task.id
            <> "`: "
            <> simplifile.describe_error(error),
          )
      }
  }
}

fn append_recovery_note(
  run: types.RunRecord,
  task: types.Task,
) -> Result(Nil, String) {
  use existing <- result.try(case simplifile.read(run.brief_path) {
    Ok(contents) -> Ok(contents)
    Error(error) ->
      Error(
        "Unable to read "
        <> run.brief_path
        <> ": "
        <> simplifile.describe_error(error),
      )
  })
  let separator = case string.ends_with(existing, "\n") {
    True -> ""
    False -> "\n"
  }
  let note =
    separator
    <> "\n## Recovery Note: Abandoned Retained Work\n"
    <> "- Task: `"
    <> task.id
    <> "`\n"
    <> "- Decision: discard the retained partial work for this task during recovery.\n"
    <> "- Planner instruction: replace or omit this task when replanning remaining work; do not assume the discarded partial work was completed.\n"
  case simplifile.write(existing <> note, to: run.brief_path) {
    Ok(_) -> Ok(Nil)
    Error(error) ->
      Error(
        "Unable to append recovery note to "
        <> run.brief_path
        <> ": "
        <> simplifile.describe_error(error),
      )
  }
}

fn render_implementation_inspection(
  run: types.RunRecord,
  task: types.Task,
) -> String {
  let git_log =
    filepath.join(
      run.run_path,
      "logs/" <> task.id <> ".resolve.inspect.git.log",
    )
  let changed_files = case task.worktree_path {
    "" -> []
    worktree_path -> git.changed_files(worktree_path, git_log)
  }
  let changed_files_lines = case changed_files {
    [] -> "- Changed files: (none detected)"
    _ ->
      "- Changed files:\n"
      <> string.join(
        changed_files |> list.map(fn(path) { "  - " <> path }),
        with: "\n",
      )
  }

  "Task `"
  <> task.id
  <> "` is blocked by interrupted implementation work."
  <> "\nReport: "
  <> run.report_path
  <> "\nWorktree: "
  <> case task.worktree_path {
    "" -> "(missing)"
    path -> path
  }
  <> "\nTask log: "
  <> filepath.join(run.run_path, "logs/" <> task.id <> ".log")
  <> "\n"
  <> changed_files_lines
}

fn verify_retained_worktree(
  config: types.Config,
  run: types.RunRecord,
  task: types.Task,
  verification_log: String,
) -> Result(String, String) {
  use env_vars <- result.try(worktree_setup.env_vars_for(
    run.repo_root,
    run.environment_name,
    project.worktree_setup_path(run.repo_root),
    task.runtime_context,
  ))
  verify_commands(
    config.verification_commands,
    task.worktree_path,
    env_vars,
    verification_log,
    [],
  )
}

fn verify_commands(
  commands: List(String),
  cwd: String,
  env_vars: List(#(String, String)),
  log_path: String,
  acc: List(String),
) -> Result(String, String) {
  case commands {
    [] ->
      case acc {
        [] -> Ok("No verification commands configured.")
        _ -> Ok(string.join(list.reverse(acc), with: "\n\n"))
      }
    [command, ..rest] -> {
      let output = shell.run(shell.with_env(command, env_vars), cwd, log_path)
      let transcript = "$ " <> command <> "\n" <> output.output
      case shell.succeeded(output) {
        True ->
          verify_commands(rest, cwd, env_vars, log_path, [transcript, ..acc])
        False ->
          Error(string.join(list.reverse([transcript, ..acc]), with: "\n\n"))
      }
    }
  }
}

fn persist_resolved_run(run: types.RunRecord) -> Result(types.RunRecord, String) {
  let status = resolved_run_status(run)
  journal.mark_status(run, status, resolved_run_message(run, status))
}

fn resolved_run_status(run: types.RunRecord) -> types.RunStatus {
  case runs.active_recovery_blocker(run) {
    Some(_) -> types.RunBlocked
    None ->
      case list.any(run.tasks, fn(task) { task.state == types.Failed }) {
        True -> types.RunFailed
        False ->
          case
            list.any(run.tasks, fn(task) {
              task.state == types.Blocked || task.state == types.ManualAttention
            })
          {
            True -> types.RunBlocked
            False ->
              case
                list.all(run.tasks, fn(task) { task.state == types.Completed })
              {
                True -> types.RunCompleted
                False -> types.RunPending
              }
          }
      }
  }
}

fn resolved_run_message(run: types.RunRecord, status: types.RunStatus) -> String {
  case status {
    types.RunPending ->
      decision_domain.planning_status_message(run.decisions, run.tasks)
    types.RunCompleted -> "Night Shift completed all queued work."
    types.RunBlocked ->
      case runs.active_recovery_blocker(run) {
        Some(_) -> "Night Shift is blocked before implementation could begin."
        None -> domain_summary.blocked_run_message(run.tasks)
      }
    types.RunFailed -> "Night Shift encountered failed tasks."
    types.RunActive -> "Night Shift stopped."
  }
}

fn as_resolve_result(
  run: types.RunRecord,
  summary: Option(String),
) -> workflow.ResolveResult {
  workflow.ResolveResult(
    run: run,
    warnings: [],
    next_action: runs.next_action_for_run(run),
    summary: summary,
  )
}

fn changed_files_summary(files: List(String)) -> String {
  case files {
    [] -> ""
    _ -> " Changed files: " <> string.join(files, with: ", ")
  }
}

fn mark_task_ready_for_retry(
  tasks: List(types.Task),
  task_id: String,
) -> List(types.Task) {
  tasks
  |> list.map(fn(task) {
    case task.id == task_id {
      True ->
        types.Task(
          ..task,
          state: types.Ready,
          summary: "Operator waived the failed setup gate once; retry pending.",
        )
      False -> task
    }
  })
}

fn render_setup_inspection(
  run: types.RunRecord,
  blocker: types.RecoveryBlocker,
) -> String {
  let task_fragment = case blocker.task_id {
    Some(task_id) ->
      case find_task(run.tasks, task_id) {
        Some(task) ->
          "\nTask: `"
          <> task.id
          <> "`"
          <> "\nWorktree: "
          <> case task.worktree_path {
            "" -> "(none recorded)"
            path -> path
          }
        None -> "\nTask: `" <> task_id <> "`"
      }
    None -> ""
  }
  let replacement_lines = render_replacement_targets(run)

  "Review-driven planning succeeded, but execution stopped before implementation."
  <> "\nFailed gate: "
  <> types.recovery_blocker_phase_to_string(blocker.phase)
  <> " "
  <> types.recovery_blocker_kind_to_string(blocker.kind)
  <> "\nReason: "
  <> blocker.message
  <> "\nLog: "
  <> blocker.log_path
  <> task_fragment
  <> "\nNo new commits or PR updates were produced."
  <> replacement_lines
}

fn render_replacement_targets(run: types.RunRecord) -> String {
  case replacement_pr_numbers(run.tasks) {
    [] -> ""
    numbers ->
      "\nIntended replacements remain pending for: "
      <> string.join(numbers |> list.map(int.to_string), with: ", ")
      <> "\nExisting reviewed PRs remain unchanged until replacement delivery succeeds."
  }
}

fn replacement_pr_numbers(tasks: List(types.Task)) -> List(Int) {
  unique_pr_numbers(
    tasks
      |> list.flat_map(fn(task) { task.superseded_pr_numbers }),
    [],
  )
}

fn unique_pr_numbers(values: List(Int), acc: List(Int)) -> List(Int) {
  case values {
    [] -> list.reverse(acc)
    [value, ..rest] ->
      case list.contains(acc, value) {
        True -> unique_pr_numbers(rest, acc)
        False -> unique_pr_numbers(rest, [value, ..acc])
      }
  }
}

fn find_task(tasks: List(types.Task), task_id: String) -> Option(types.Task) {
  case list.find(tasks, fn(task) { task.id == task_id }) {
    Ok(task) -> Some(task)
    Error(_) -> None
  }
}

fn append_decision_recorded_events(
  run: types.RunRecord,
  decisions: List(types.RecordedDecision),
) -> Result(types.RunRecord, String) {
  case decisions {
    [] -> Ok(run)
    [decision, ..rest] -> {
      use updated_run <- result.try(journal.append_event(
        run,
        types.RunEvent(
          kind: "decision_recorded",
          at: decision.answered_at,
          message: decision.question <> " -> " <> decision.answer,
          task_id: None,
        ),
      ))
      append_decision_recorded_events(updated_run, rest)
    }
  }
}

fn append_run_events(
  run: types.RunRecord,
  events: List(types.RunEvent),
) -> Result(types.RunRecord, String) {
  case events {
    [] -> Ok(run)
    [event, ..rest] -> {
      use updated_run <- result.try(journal.append_event(run, event))
      append_run_events(updated_run, rest)
    }
  }
}

fn planning_sync_pending_event() -> types.RunEvent {
  types.RunEvent(
    kind: "planning_sync_pending",
    at: system.timestamp(),
    message: "Recorded new planning answers; Night Shift must replan before this run can start.",
    task_id: None,
  )
}
