import gleam/io
import gleam/list
import gleam/result
import night_shift/dashboard
import night_shift/journal
import night_shift/system
import night_shift/types
import night_shift/usecase/support/environment
import night_shift/usecase/support/repo_guard
import night_shift/usecase/support/runs

pub fn view(
  repo_root: String,
  selector: types.RunSelector,
) -> Result(Nil, String) {
  use initial_run_id <- result.try(resolve_initial_run_id(repo_root, selector))
  use session <- result.try(dashboard.start_view_session(
    repo_root,
    initial_run_id,
  ))
  io.println(render_dashboard_summary(session.url, initial_run_id))
  system.wait_forever()
  Ok(Nil)
}

pub fn start(
  repo_root: String,
  selector: types.RunSelector,
  config: types.Config,
) -> Result(Nil, String) {
  use run <- result.try(runs.load_start_run(repo_root, selector))
  use warnings <- result.try(repo_guard.ensure_clean_repo_for_start(repo_root))
  use active_run <- result.try(journal.activate_run(run))
  use session <- result.try(dashboard.start_start_session(
    repo_root,
    active_run.run_id,
    active_run,
    config,
  ))
  warnings |> list.each(io.println)
  io.println(render_dashboard_summary(session.url, active_run.run_id))
  system.wait_forever()
  Ok(Nil)
}

pub fn resume(
  repo_root: String,
  selector: types.RunSelector,
  config: types.Config,
) -> Result(Nil, String) {
  use #(saved_run, _) <- result.try(journal.load(repo_root, selector))
  use _ <- result.try(environment.ensure_saved_environment_is_valid(
    repo_root,
    saved_run.environment_name,
  ))
  use session <- result.try(dashboard.start_resume_session(
    repo_root,
    saved_run.run_id,
    saved_run,
    config,
  ))
  io.println(render_dashboard_summary(session.url, saved_run.run_id))
  system.wait_forever()
  Ok(Nil)
}

fn render_dashboard_summary(url: String, run_id: String) -> String {
  "Dashboard: "
  <> url
  <> "\nRun: "
  <> case run_id {
    "" -> "(auto)"
    value -> value
  }
}

fn resolve_initial_run_id(
  repo_root: String,
  selector: types.RunSelector,
) -> Result(String, String) {
  case selector {
    types.RunId(run_id) -> {
      use _ <- result.try(journal.load(repo_root, selector))
      Ok(run_id)
    }
    types.LatestRun -> {
      use run_list <- result.try(journal.list_runs(repo_root))
      Ok(case run_list {
        [run, ..] -> run.run_id
        [] -> ""
      })
    }
  }
}
