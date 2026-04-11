import gleam/result
import night_shift/journal
import night_shift/orchestrator
import night_shift/types
import night_shift/usecase/result as workflow
import night_shift/usecase/shared

pub fn execute(
  repo_root: String,
  selector: types.RunSelector,
  config: types.Config,
) -> Result(workflow.ResumeResult, String) {
  use #(saved_run, _) <- result.try(journal.load(repo_root, selector))
  use _ <- result.try(shared.ensure_saved_environment_is_valid(
    repo_root,
    saved_run.environment_name,
  ))
  use resumed_run <- result.try(orchestrator.resume(saved_run, config))
  Ok(workflow.ResumeResult(
    run: resumed_run,
    warnings: [],
    next_action: shared.next_action_for_run(resumed_run),
  ))
}
