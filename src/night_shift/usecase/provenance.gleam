import gleam/result
import gleam/option.{type Option}
import night_shift/domain/provenance as provenance_domain
import night_shift/journal
import night_shift/repo_state_runtime
import night_shift/types

pub fn execute(
  repo_root: String,
  selector: types.RunSelector,
  task_id: Option(String),
  format: types.ProvenanceFormat,
  config: types.Config,
) -> Result(String, String) {
  use #(run, events) <- result.try(journal.load(repo_root, selector))
  let repo_state_view = repo_state_runtime.inspect(run, config.branch_prefix).view
  provenance_domain.render(
    run,
    events,
    repo_state_view,
    task_id,
    format,
    config.verification_commands,
  )
}
