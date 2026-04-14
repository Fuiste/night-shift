import gleam/io
import gleam/result
import night_shift/dashboard
import night_shift/system

pub fn start(repo_root: String) -> Result(Nil, String) {
  use session <- result.try(dashboard.start_session(repo_root))
  io.println(render_dashboard_summary(session.url))
  system.wait_forever()
  Ok(Nil)
}

fn render_dashboard_summary(url: String) -> String {
  "Dash: " <> url
}
