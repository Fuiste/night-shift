import night_shift/domain/report as domain_report
import night_shift/types

pub fn render(run: types.RunRecord, events: List(types.RunEvent)) -> String {
  domain_report.render(run, events)
}
