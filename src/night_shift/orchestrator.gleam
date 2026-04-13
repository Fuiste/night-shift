//// Core planning and execution coordinator for Night Shift runs.
////
//// The heavy lifting lives in lifecycle phase modules so this façade can keep
//// the public runtime API stable while composing the phases in order.

import gleam/result
import night_shift/domain/run_state
import night_shift/domain/summary as domain_summary
import night_shift/domain/task_graph
import night_shift/journal
import night_shift/orchestrator/execution_phase
import night_shift/orchestrator/planning_phase
import night_shift/orchestrator/supersession_phase
import night_shift/types

/// Start executing a run from its current persisted state.
pub fn start(
  run: types.RunRecord,
  config: types.Config,
) -> Result(types.RunRecord, String) {
  continue_run(run, config)
}

/// Continue a run that may already have planned or running tasks.
pub fn continue_run(
  run: types.RunRecord,
  config: types.Config,
) -> Result(types.RunRecord, String) {
  use prepared <- result.try(execution_phase.prepare_run(run))
  case prepared.proceed {
    True -> scheduler_loop(config, prepared.run)
    False -> Ok(prepared.run)
  }
}

/// Ask the planning provider to produce the initial task graph for a run.
pub fn plan(run: types.RunRecord) -> Result(types.RunRecord, String) {
  planning_phase.plan(run)
}

/// Re-run planning after decisions or follow-up work changed the graph.
pub fn replan(run: types.RunRecord) -> Result(types.RunRecord, String) {
  planning_phase.replan(run)
}

fn scheduler_loop(
  config: types.Config,
  run: types.RunRecord,
) -> Result(types.RunRecord, String) {
  let refreshed_run =
    types.RunRecord(..run, tasks: task_graph.refresh_ready_states(run.tasks))
  case run_state.has_blocking_attention(refreshed_run.tasks) {
    True -> finish_run(refreshed_run)
    False -> {
      let batch =
        task_graph.next_batch(refreshed_run.tasks, refreshed_run.max_workers)

      case batch {
        [] -> finish_run(refreshed_run)
        _ -> {
          use launched_batch <- result.try(execution_phase.launch_batch(
            config,
            refreshed_run,
            batch,
          ))
          use completed_run <- result.try(execution_phase.await_batch(
            config,
            launched_batch.run,
            launched_batch.task_runs,
          ))
          scheduler_loop(config, completed_run)
        }
      }
    }
  }
}

fn finish_run(run: types.RunRecord) -> Result(types.RunRecord, String) {
  let status = run_state.final_status(run.tasks)
  let message = case status {
    types.RunCompleted -> "Night Shift completed all queued work."
    types.RunFailed -> "Night Shift encountered failed tasks."
    types.RunBlocked -> domain_summary.blocked_run_message(run.tasks)
    _ -> "Night Shift stopped."
  }

  use finalized_run <- result.try(journal.mark_status(run, status, message))
  case status {
    types.RunCompleted ->
      supersession_phase.finalize_completed_run(finalized_run)
    _ -> Ok(finalized_run)
  }
}
