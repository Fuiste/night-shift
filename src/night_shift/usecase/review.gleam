import filepath
import gleam/int
import gleam/list
import gleam/option.{type Option, None}
import gleam/result
import night_shift/agent_config
import night_shift/domain/pull_request as pull_request_domain
import night_shift/domain/task_graph
import night_shift/github
import night_shift/journal
import night_shift/orchestrator
import night_shift/project
import night_shift/system
import night_shift/types
import night_shift/usecase/result as workflow
import night_shift/usecase/support/environment
import night_shift/usecase/support/runs

pub fn execute(
  repo_root: String,
  agent_overrides: types.AgentOverrides,
  environment_name: Option(String),
  config: types.Config,
) -> Result(workflow.ReviewResult, String) {
  use selected_environment <- result.try(environment.resolve_environment_name(
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
  use review_tasks <- result.try(load_review_tasks(
    run.repo_root,
    config.branch_prefix,
    run.run_path,
  ))
  use seeded_run <- result.try(seed_review_run(run, review_tasks))
  use reviewed_run <- result.try(orchestrator.continue_run(seeded_run, config))
  Ok(workflow.ReviewResult(
    run: reviewed_run,
    warnings: [],
    next_action: runs.next_action_for_run(reviewed_run),
  ))
}

fn load_review_tasks(
  repo_root: String,
  branch_prefix: String,
  run_path: String,
) -> Result(List(types.Task), String) {
  let log_path = filepath.join(run_path, "logs/review.log")
  use prs <- result.try(github.list_night_shift_prs(
    repo_root,
    branch_prefix,
    log_path,
  ))

  prs
  |> list.try_map(fn(pr) {
    use details <- result.try(github.review_item(repo_root, pr.number, log_path))
    Ok(pull_request_domain.review_task(
      details.number,
      details.url,
      details.body,
      details.head_ref_name,
      details.review_comments,
      details.failing_checks,
    ))
  })
}

fn seed_review_run(
  run: types.RunRecord,
  tasks: List(types.Task),
) -> Result(types.RunRecord, String) {
  let seeded_run =
    types.RunRecord(..run, tasks: task_graph.normalize_tasks(tasks))
  let event =
    types.RunEvent(
      kind: "task_progress",
      at: system.timestamp(),
      message: "Review mode loaded "
        <> int.to_string(list.length(tasks))
        <> " stabilization tasks.",
      task_id: None,
    )

  journal.append_event(seeded_run, event)
}
