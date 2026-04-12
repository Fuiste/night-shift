import gleam/result
import night_shift/domain/status
import night_shift/types
import night_shift/usecase/result as workflow
import night_shift/usecase/shared

pub fn execute(
  repo_root: String,
  selector: types.RunSelector,
) -> Result(workflow.StatusResult, String) {
  use #(run, events) <- result.try(shared.load_display_run(repo_root, selector))
  let next_action = shared.next_action_for_run(run)
  Ok(workflow.StatusResult(
    run: run,
    events: events,
    summary: status.summary(run, events, next_action),
    next_action: next_action,
  ))
}
