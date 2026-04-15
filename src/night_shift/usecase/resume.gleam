import filepath
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import night_shift/domain/run_state
import night_shift/domain/task_graph
import night_shift/git
import night_shift/journal
import night_shift/orchestrator
import night_shift/repo_state_runtime
import night_shift/system
import night_shift/types
import night_shift/usecase/result as workflow
import night_shift/usecase/support/environment
import night_shift/usecase/support/runs

pub fn execute(
  repo_root: String,
  selector: types.RunSelector,
  config: types.Config,
) -> Result(workflow.ResumeResult, String) {
  use #(saved_run, _) <- result.try(journal.load(repo_root, selector))
  use _ <- result.try(environment.ensure_saved_environment_is_valid(
    repo_root,
    saved_run.environment_name,
  ))
  use resumed_run <- result.try(prepare_resumed_run(saved_run))
  let inspection = repo_state_runtime.inspect(resumed_run, config.branch_prefix)
  use inspected_run <- result.try(append_events(resumed_run, inspection.events))
  use continued_run <- result.try(orchestrator.continue_run(
    inspected_run,
    config,
  ))
  Ok(workflow.ResumeResult(
    run: continued_run,
    warnings: inspection.warnings,
    repo_state_view: inspection.view,
    next_action: runs.next_action_for_run(continued_run),
  ))
}

pub fn prepare_resumed_run(
  run: types.RunRecord,
) -> Result(types.RunRecord, String) {
  let resumed_tasks =
    run.tasks
    |> list.map(fn(task) { recover_task(run.run_path, task) })
    |> task_graph.refresh_ready_states

  let resumed_run = types.RunRecord(..run, tasks: resumed_tasks)
  case recovery_event(run.tasks, resumed_tasks) {
    Some(event) -> journal.append_event(resumed_run, event)
    None -> Ok(resumed_run)
  }
}

fn recover_task(run_path: String, task: types.Task) -> types.Task {
  let has_worktree_changes = case task.worktree_path {
    "" -> False
    worktree_path ->
      git.has_changes(
        worktree_path,
        filepath.join(
          run_path,
          "logs/" <> task.id <> ".recover.has-changes.log",
        ),
      )
  }

  run_state.recover_task(task, has_worktree_changes)
}

fn append_events(
  run: types.RunRecord,
  events: List(types.RunEvent),
) -> Result(types.RunRecord, String) {
  case events {
    [] -> Ok(run)
    [event, ..rest] -> {
      use updated_run <- result.try(journal.append_event(run, event))
      append_events(updated_run, rest)
    }
  }
}

fn recovery_event(
  original_tasks: List(types.Task),
  resumed_tasks: List(types.Task),
) -> Option(types.RunEvent) {
  let #(requeued_count, manual_attention_count) =
    recovery_counts(original_tasks, resumed_tasks, 0, 0)

  case requeued_count, manual_attention_count {
    0, 0 -> None
    _, 0 ->
      Some(types.RunEvent(
        kind: "task_progress",
        at: system.timestamp(),
        message: "Recovery requeued "
          <> int.to_string(requeued_count)
          <> " interrupted task"
          <> plural_suffix(requeued_count)
          <> ".",
        task_id: None,
      ))
    0, _ ->
      Some(types.RunEvent(
        kind: "task_progress",
        at: system.timestamp(),
        message: "Recovery marked "
          <> int.to_string(manual_attention_count)
          <> " interrupted task"
          <> plural_suffix(manual_attention_count)
          <> " for manual attention; no tasks were requeued.",
        task_id: None,
      ))
    _, _ ->
      Some(types.RunEvent(
        kind: "task_progress",
        at: system.timestamp(),
        message: "Recovery requeued "
          <> int.to_string(requeued_count)
          <> " interrupted task"
          <> plural_suffix(requeued_count)
          <> " and marked "
          <> int.to_string(manual_attention_count)
          <> " for manual attention.",
        task_id: None,
      ))
  }
}

fn recovery_counts(
  original_tasks: List(types.Task),
  resumed_tasks: List(types.Task),
  requeued_count: Int,
  manual_attention_count: Int,
) -> #(Int, Int) {
  case original_tasks, resumed_tasks {
    [], _ -> #(requeued_count, manual_attention_count)
    _, [] -> #(requeued_count, manual_attention_count)
    [original, ..original_rest], [resumed, ..resumed_rest] -> {
      let next_counts = case original.state == types.Running {
        False -> #(requeued_count, manual_attention_count)
        True ->
          case resumed.state {
            types.ManualAttention -> #(
              requeued_count,
              manual_attention_count + 1,
            )
            _ -> #(requeued_count + 1, manual_attention_count)
          }
      }
      recovery_counts(original_rest, resumed_rest, next_counts.0, next_counts.1)
    }
  }
}

fn plural_suffix(count: Int) -> String {
  case count == 1 {
    True -> ""
    False -> "s"
  }
}
