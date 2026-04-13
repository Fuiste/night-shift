import gleam/result
import night_shift/domain/status
import night_shift/repo_state_runtime
import night_shift/types
import night_shift/usecase/result as workflow
import night_shift/usecase/support/runs

pub fn execute(
  repo_root: String,
  selector: types.RunSelector,
  config: types.Config,
) -> Result(workflow.StatusResult, String) {
  use #(run, events) <- result.try(runs.load_display_run(repo_root, selector))
  let next_action = runs.next_action_for_run(run)
  let inspection = repo_state_runtime.inspect(run, config.branch_prefix)
  Ok(workflow.StatusResult(
    run: run,
    events: events,
    repo_state_view: inspection.view,
    summary: status.summary(run, events, next_action),
    next_action: next_action,
  ))
}
