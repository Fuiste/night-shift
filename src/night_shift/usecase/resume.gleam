import filepath
import gleam/list
import gleam/option.{None}
import gleam/result
import night_shift/domain/run_state
import night_shift/domain/task_graph
import night_shift/git
import night_shift/journal
import night_shift/orchestrator
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
  use continued_run <- result.try(orchestrator.continue_run(resumed_run, config))
  Ok(workflow.ResumeResult(
    run: continued_run,
    warnings: [],
    next_action: runs.next_action_for_run(continued_run),
  ))
}

fn prepare_resumed_run(run: types.RunRecord) -> Result(types.RunRecord, String) {
  let resumed_tasks =
    run.tasks
    |> list.map(fn(task) { recover_task(task) })
    |> task_graph.refresh_ready_states

  let resumed_run = types.RunRecord(..run, tasks: resumed_tasks)
  let event =
    types.RunEvent(
      kind: "task_progress",
      at: system.timestamp(),
      message: "Run resumed; interrupted workers were requeued or marked for manual attention.",
      task_id: None,
    )

  journal.append_event(resumed_run, event)
}

fn recover_task(task: types.Task) -> types.Task {
  let has_worktree_changes = case task.worktree_path {
    "" -> False
    worktree_path ->
      git.has_changes(
        worktree_path,
        filepath.join(worktree_path, ".night-shift-recover.log"),
      )
  }

  run_state.recover_task(task, has_worktree_changes)
}
