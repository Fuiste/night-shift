import gleam/option.{None, Some}
import gleam/result
import night_shift/domain/decisions as decision_domain
import night_shift/journal
import night_shift/orchestrator
import night_shift/system
import night_shift/types
import night_shift/usecase/result as workflow
import night_shift/usecase/shared

pub fn execute(
  repo_root: String,
  selector: types.RunSelector,
  collect_decisions: fn(types.RunRecord, List(types.Task)) ->
    Result(#(List(types.RecordedDecision), List(types.RunEvent)), String),
) -> Result(workflow.ResolveResult, String) {
  use run <- result.try(shared.load_resolvable_run(repo_root, selector))
  resolve_loop(run, collect_decisions)
}

fn resolve_loop(
  run: types.RunRecord,
  collect_decisions: fn(types.RunRecord, List(types.Task)) ->
    Result(#(List(types.RecordedDecision), List(types.RunEvent)), String),
) -> Result(workflow.ResolveResult, String) {
  let blocked_tasks = decision_domain.unresolved_manual_attention_tasks(run)

  case blocked_tasks, run.planning_dirty {
    [], True -> continue_resolve_run(run, collect_decisions)
    [], False ->
      Ok(
        workflow.ResolveResult(
          run: run,
          warnings: [],
          next_action: shared.next_action_for_run(run),
          summary: case run.status {
            types.RunPending -> None
            _ ->
              Some(
                "Run "
                <> run.run_id
                <> " is blocked but has no unresolved decisions left to collect. Inspect "
                <> run.report_path
                <> " or rerun `night-shift plan --notes ...`.",
              )
          },
        ),
      )
    _, _ -> {
      use #(new_decisions, warning_events) <- result.try(collect_decisions(
        run,
        blocked_tasks,
      ))
      let updated_run =
        types.RunRecord(
          ..run,
          decisions: decision_domain.merge_recorded_decisions(
            run.decisions,
            new_decisions,
          ),
          planning_dirty: True,
        )
      use rewritten_run <- result.try(journal.rewrite_run(updated_run))
      use warned_run <- result.try(append_run_events(
        rewritten_run,
        warning_events,
      ))
      use signaled_run <- result.try(append_decision_recorded_events(
        warned_run,
        new_decisions,
      ))
      use dirty_run <- result.try(
        append_run_events(signaled_run, [
          planning_sync_pending_event(),
        ]),
      )
      continue_resolve_run(dirty_run, collect_decisions)
    }
  }
}

fn continue_resolve_run(
  run: types.RunRecord,
  collect_decisions: fn(types.RunRecord, List(types.Task)) ->
    Result(#(List(types.RecordedDecision), List(types.RunEvent)), String),
) -> Result(workflow.ResolveResult, String) {
  use replanned_run <- result.try(orchestrator.replan(run))
  case replanned_run.status {
    types.RunBlocked -> resolve_loop(replanned_run, collect_decisions)
    _ ->
      Ok(workflow.ResolveResult(
        run: replanned_run,
        warnings: [],
        next_action: shared.next_action_for_run(replanned_run),
        summary: None,
      ))
  }
}

fn append_decision_recorded_events(
  run: types.RunRecord,
  decisions: List(types.RecordedDecision),
) -> Result(types.RunRecord, String) {
  case decisions {
    [] -> Ok(run)
    [decision, ..rest] -> {
      use updated_run <- result.try(journal.append_event(
        run,
        types.RunEvent(
          kind: "decision_recorded",
          at: decision.answered_at,
          message: decision.question <> " -> " <> decision.answer,
          task_id: None,
        ),
      ))
      append_decision_recorded_events(updated_run, rest)
    }
  }
}

fn append_run_events(
  run: types.RunRecord,
  events: List(types.RunEvent),
) -> Result(types.RunRecord, String) {
  case events {
    [] -> Ok(run)
    [event, ..rest] -> {
      use updated_run <- result.try(journal.append_event(run, event))
      append_run_events(updated_run, rest)
    }
  }
}

fn planning_sync_pending_event() -> types.RunEvent {
  types.RunEvent(
    kind: "planning_sync_pending",
    at: system.timestamp(),
    message: "Recorded new planning answers; Night Shift must replan before this run can start.",
    task_id: None,
  )
}
