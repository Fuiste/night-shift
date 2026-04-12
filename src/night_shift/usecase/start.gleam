import gleam/result
import night_shift/journal
import night_shift/orchestrator
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
  case orchestrator.start(active_run, config) {
    Ok(updated_run) ->
      Ok(workflow.StartResult(
        run: updated_run,
        warnings: warnings,
        next_action: runs.next_action_for_run(updated_run),
      ))
    Error(message) ->
      case runs.mark_latest_persisted_run_failed(active_run, message) {
        Ok(failed_run) ->
          Ok(workflow.StartResult(
            run: failed_run,
            warnings: warnings,
            next_action: runs.next_action_for_run(failed_run),
          ))
        Error(_) -> Error(message)
      }
  }
}
