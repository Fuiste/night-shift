//// Public report rendering facade.

import gleam/option.{type Option, None}
import night_shift/domain/report as domain_report
import night_shift/repo_state_runtime
import night_shift/types

/// Render the report shown to the operator after a run.
pub fn render(
  run: types.RunRecord,
  events: List(types.RunEvent),
  repo_state_view: Option(repo_state_runtime.RepoStateView),
) -> String {
  domain_report.render(run, events, repo_state_view)
}

pub fn render_live(
  run: types.RunRecord,
  events: List(types.RunEvent),
  repo_state_view: Option(repo_state_runtime.RepoStateView),
) -> String {
  domain_report.render(run, events, repo_state_view)
}

pub fn render_persisted(
  run: types.RunRecord,
  events: List(types.RunEvent),
) -> String {
  domain_report.render(run, events, None)
}
