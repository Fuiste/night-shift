import filepath
import gleam/option.{type Option, None, Some}
import gleam/result
import night_shift/agent_config
import night_shift/domain/repo_state
import night_shift/github
import night_shift/orchestrator
import night_shift/project
import night_shift/provider
import night_shift/system
import night_shift/types
import night_shift/usecase/result as workflow
import night_shift/usecase/support/environment
import night_shift/usecase/support/filesystem
import night_shift/usecase/support/planning
import night_shift/usecase/support/runs

pub fn execute(
  repo_root: String,
  notes_value: Option(String),
  from_reviews: Bool,
  doc_path: Option(String),
  planning_agent: types.ResolvedAgentConfig,
  config: types.Config,
) -> Result(workflow.PlanResult, String) {
  let target_doc_path = filesystem.resolve_doc_path(repo_root, doc_path)
  use notes_source <- result.try(filesystem.resolve_optional_notes_source(
    repo_root,
    notes_value,
  ))
  use planning_provenance <- result.try(resolve_planning_provenance(
    from_reviews,
    notes_source,
  ))
  use repo_state_snapshot <- result.try(load_repo_state_snapshot(
    repo_root,
    from_reviews,
    config,
  ))
  use #(_default_plan_agent, execution_agent) <- result.try(
    agent_config.resolve_start_agents(config, types.empty_agent_overrides()),
  )
  use selected_environment <- result.try(environment.resolve_environment_name(
    repo_root,
    None,
  ))
  use #(document, artifact_path) <- result.try(provider.plan_document(
    planning_agent,
    repo_root,
    notes_source,
    target_doc_path,
    repo_state_snapshot,
  ))
  use _ <- result.try(filesystem.write_string(target_doc_path, document))
  use #(seeded_run, replanning) <- result.try(planning.prepare_planning_run(
    repo_root,
    target_doc_path,
    planning_agent,
    execution_agent,
    selected_environment,
    config.max_workers,
    notes_source,
    planning_provenance,
    repo_state_snapshot,
  ))
  use planned_run <- result.try(case replanning {
    True -> orchestrator.replan(seeded_run)
    False -> orchestrator.plan(seeded_run)
  })
  Ok(workflow.PlanResult(
    run: planned_run,
    brief_path: target_doc_path,
    artifact_path: artifact_path,
    planning_provenance: planning_provenance,
    warnings: config_warnings(config),
    next_action: runs.next_action_for_run(planned_run),
  ))
}

fn resolve_planning_provenance(
  from_reviews: Bool,
  notes_source: Option(types.NotesSource),
) -> Result(types.PlanningProvenance, String) {
  case from_reviews, notes_source {
    True, Some(source) -> Ok(types.ReviewsAndNotes(source))
    True, None -> Ok(types.ReviewsOnly)
    False, Some(source) -> Ok(types.NotesOnly(source))
    False, None ->
      Error("The plan command requires --notes <file-or-inline-text>.")
  }
}

fn load_repo_state_snapshot(
  repo_root: String,
  from_reviews: Bool,
  config: types.Config,
) -> Result(Option(repo_state.RepoStateSnapshot), String) {
  case from_reviews {
    False -> Ok(None)
    True -> {
      let log_path =
        filepath.join(
          project.planning_root(repo_root),
          system.unique_id() <> "-repo-state.log",
        )
      github.repo_state_snapshot(repo_root, config.branch_prefix, log_path)
      |> result.map(Some)
    }
  }
}

fn config_warnings(config: types.Config) -> List(String) {
  case config.review_profile {
    "" -> []
    _ -> [
      "Config warning: `review_profile` is deprecated; `planning_profile` now governs review-driven planning.",
    ]
  }
}
