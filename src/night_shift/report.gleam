//// Public report rendering facade.
import night_shift/domain/report as domain_report
import night_shift/types

/// Render the report shown to the operator after a run.
pub fn render(run: types.RunRecord, events: List(types.RunEvent)) -> String {
  domain_report.render(run, events)
}
