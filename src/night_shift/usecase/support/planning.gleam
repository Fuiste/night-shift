import gleam/option.{None, Some}
import gleam/result
import night_shift/journal
import night_shift/types
import night_shift/usecase/support/filesystem
import simplifile

pub fn prepare_planning_run(
  repo_root: String,
  brief_path: String,
  planning_agent: types.ResolvedAgentConfig,
  execution_agent: types.ResolvedAgentConfig,
  environment_name: String,
  max_workers: Int,
  notes_source: types.NotesSource,
) -> Result(#(types.RunRecord, Bool), String) {
  case journal.latest_reusable_run(repo_root) {
    Ok(Some(existing_run)) -> {
      use brief_contents <- result.try(
        simplifile.read(brief_path)
        |> result.map_error(fn(error) {
          "Unable to read "
          <> brief_path
          <> ": "
          <> simplifile.describe_error(error)
        }),
      )
      use _ <- result.try(filesystem.write_string(
        existing_run.brief_path,
        brief_contents,
      ))
      let updated_run =
        types.RunRecord(
          ..existing_run,
          planning_agent: planning_agent,
          execution_agent: execution_agent,
          environment_name: environment_name,
          max_workers: max_workers,
          notes_source: Some(notes_source),
          planning_dirty: True,
        )
      use rewritten_run <- result.try(journal.rewrite_run(updated_run))
      Ok(#(rewritten_run, True))
    }
    Ok(None) -> {
      use pending_run <- result.try(journal.create_pending_run(
        repo_root,
        brief_path,
        planning_agent,
        execution_agent,
        environment_name,
        max_workers,
        Some(notes_source),
      ))
      let updated_run = types.RunRecord(..pending_run, planning_dirty: True)
      journal.rewrite_run(updated_run)
      |> result.map(fn(run) { #(run, False) })
    }
    Error(message) -> Error(message)
  }
}
