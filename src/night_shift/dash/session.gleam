import gleam/io
import gleam/option.{type Option}
import gleam/result
import night_shift/dash/assets
import night_shift/journal
import night_shift/system
import night_shift/types

pub type Session {
  Session(url: String, handle: String)
}

pub type CommandState {
  CommandState(
    name: String,
    run_id: Option(String),
    started_at: String,
    summary: String,
  )
}

@external(erlang, "night_shift_dashboard_server", "start_session")
fn start_session_raw(
  repo_root: String,
  initial_run_id: String,
) -> Result(Session, String)

@external(erlang, "night_shift_dashboard_server", "stop_session")
pub fn stop_session(session: Session) -> Nil

@external(erlang, "night_shift_dashboard_server", "command_state")
pub fn command_state(repo_root: String) -> Option(CommandState)

pub fn open(
  repo_root: String,
  initial_run_id: String,
) -> Result(Session, String) {
  start_session_raw(repo_root, initial_run_id)
}

pub fn view(
  repo_root: String,
  selector: types.RunSelector,
) -> Result(Nil, String) {
  use _ <- result.try(assets.ensure_assets_ready())
  use initial_run_id <- result.try(resolve_initial_run_id(repo_root, selector))
  use session <- result.try(open(repo_root, initial_run_id))
  io.println(render_dashboard_summary(session.url, initial_run_id))
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
