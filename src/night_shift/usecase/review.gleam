import gleam/option.{type Option}
import gleam/result
import night_shift/agent_config
import night_shift/journal
import night_shift/orchestrator
import night_shift/project
import night_shift/types
import night_shift/usecase/result as workflow
import night_shift/usecase/shared

pub fn execute(
  repo_root: String,
  agent_overrides: types.AgentOverrides,
  environment_name: Option(String),
  config: types.Config,
) -> Result(workflow.ReviewResult, String) {
  use selected_environment <- result.try(shared.resolve_environment_name(
    repo_root,
    environment_name,
  ))
  use review_agent <- result.try(agent_config.resolve_review_agent(
    config,
    agent_overrides,
  ))
  use run <- result.try(journal.start_run(
    repo_root,
    project.config_path(repo_root),
    review_agent,
    review_agent,
    selected_environment,
    1,
  ))
  use reviewed_run <- result.try(orchestrator.review(run, config))
  Ok(workflow.ReviewResult(
    run: reviewed_run,
    warnings: [],
    next_action: shared.next_action_for_run(reviewed_run),
  ))
}
