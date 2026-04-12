import gleam/option.{type Option, None}
import gleam/result
import night_shift/agent_config
import night_shift/orchestrator
import night_shift/provider
import night_shift/types
import night_shift/usecase/result as workflow
import night_shift/usecase/support/environment
import night_shift/usecase/support/filesystem
import night_shift/usecase/support/planning
import night_shift/usecase/support/runs

pub fn execute(
  repo_root: String,
  notes_value: String,
  doc_path: Option(String),
  planning_agent: types.ResolvedAgentConfig,
  config: types.Config,
) -> Result(workflow.PlanResult, String) {
  let target_doc_path = filesystem.resolve_doc_path(repo_root, doc_path)
  use notes_source <- result.try(filesystem.resolve_notes_source(
    repo_root,
    notes_value,
  ))
  use #(_default_plan_agent, execution_agent) <- result.try(
    agent_config.resolve_start_agents(config, types.empty_agent_overrides()),
  )
  use selected_environment <- result.try(environment.resolve_environment_name(
    repo_root,
    None,
  ))
  use #(document, artifact_path, resolved_notes_source) <- result.try(
    provider.plan_document(
      planning_agent,
      repo_root,
      notes_source,
      target_doc_path,
    ),
  )
  use _ <- result.try(filesystem.write_string(target_doc_path, document))
  use #(seeded_run, replanning) <- result.try(planning.prepare_planning_run(
    repo_root,
    target_doc_path,
    planning_agent,
    execution_agent,
    selected_environment,
    config.max_workers,
    resolved_notes_source,
  ))
  use planned_run <- result.try(case replanning {
    True -> orchestrator.replan(seeded_run)
    False -> orchestrator.plan(seeded_run)
  })
  Ok(workflow.PlanResult(
    run: planned_run,
    brief_path: target_doc_path,
    artifact_path: artifact_path,
    notes_source: resolved_notes_source,
    warnings: [],
    next_action: runs.next_action_for_run(planned_run),
  ))
}
