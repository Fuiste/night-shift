import gleam/list
import gleam/result
import night_shift/journal
import night_shift/orchestrator
import night_shift/repo_state_runtime
import night_shift/types
import night_shift/usecase/result as workflow
import night_shift/usecase/support/repo_guard
import night_shift/usecase/support/runs

pub fn execute(
  repo_root: String,
  selector: types.RunSelector,
  config: types.Config,
) -> Result(workflow.StartResult, String) {
  use run <- result.try(runs.load_start_run(repo_root, selector))
  use warnings <- result.try(repo_guard.ensure_clean_repo_for_start(repo_root))
  use active_run <- result.try(journal.activate_run(run))
  let inspection = repo_state_runtime.inspect(active_run, config.branch_prefix)
  use inspected_run <- result.try(append_events(active_run, inspection.events))
  let all_warnings = list.append(warnings, inspection.warnings)
  case orchestrator.start(inspected_run, config) {
    Ok(updated_run) ->
      Ok(workflow.StartResult(
        run: updated_run,
        warnings: all_warnings,
        repo_state_view: inspection.view,
        next_action: runs.next_action_for_run(updated_run),
      ))
    Error(message) ->
      case runs.mark_latest_persisted_run_failed(inspected_run, message) {
        Ok(failed_run) ->
          Ok(workflow.StartResult(
            run: failed_run,
            warnings: all_warnings,
            repo_state_view: inspection.view,
            next_action: runs.next_action_for_run(failed_run),
          ))
        Error(_) -> Error(message)
      }
  }
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
