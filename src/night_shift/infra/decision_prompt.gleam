import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import night_shift/infra/terminal_ui
import night_shift/system
import night_shift/types
import night_shift/usecase/render as usecase_render

pub fn collect_recorded_decisions(
  run: types.RunRecord,
  tasks: List(types.Task),
) -> Result(#(List(types.RecordedDecision), List(types.RunEvent)), String) {
  let prompts = pending_decision_prompts(run.decisions, tasks)
  case prompts {
    [] ->
      Error("No unresolved manual-attention decisions were found for this run.")
    _ -> {
      io.println(usecase_render.render_resolve_prompt(run))
      collect_request_answers(prompts, [])
    }
  }
}

fn collect_request_answers(
  prompts: List(#(types.Task, types.DecisionRequest)),
  acc: List(types.RecordedDecision),
) -> Result(#(List(types.RecordedDecision), List(types.RunEvent)), String) {
  collect_request_answers_with_warnings(
    prompts,
    acc,
    [],
    1,
    list.length(prompts),
  )
}

fn collect_request_answers_with_warnings(
  prompts: List(#(types.Task, types.DecisionRequest)),
  acc: List(types.RecordedDecision),
  warnings: List(types.RunEvent),
  index: Int,
  total: Int,
) -> Result(#(List(types.RecordedDecision), List(types.RunEvent)), String) {
  case prompts {
    [] -> Ok(#(list.reverse(acc), list.reverse(warnings)))
    [#(task, request), ..rest] -> {
      use #(answer, warning) <- result.try(prompt_for_decision(
        task,
        request,
        index,
        total,
      ))
      let recorded =
        types.RecordedDecision(
          key: request.key,
          question: request.question,
          answer: answer,
          answered_at: system.timestamp(),
        )
      let updated_warnings = case warning {
        Some(event) -> [event, ..warnings]
        None -> warnings
      }
      collect_request_answers_with_warnings(
        rest,
        [recorded, ..acc],
        updated_warnings,
        index + 1,
        total,
      )
    }
  }
}

fn pending_decision_prompts(
  decisions: List(types.RecordedDecision),
  tasks: List(types.Task),
) -> List(#(types.Task, types.DecisionRequest)) {
  tasks
  |> list.map(fn(task) {
    types.unresolved_decision_requests(decisions, task)
    |> list.map(fn(request) { #(task, request) })
  })
  |> list.flatten
}

fn prompt_for_decision(
  task: types.Task,
  request: types.DecisionRequest,
  index: Int,
  total: Int,
) -> Result(#(String, Option(types.RunEvent)), String) {
  io.println("")
  io.println("Question " <> int.to_string(index) <> "/" <> int.to_string(total))
  io.println("Task: " <> task.title)
  io.println("Question: " <> request.question)
  case string.trim(request.rationale) {
    "" -> Nil
    rationale -> io.println("Why this matters: " <> rationale)
  }

  case request.options {
    [] -> {
      let warning = case request.allow_freeform {
        True -> None
        False -> Some(decision_contract_warning_event(task, request))
      }
      use answer <- result.try(terminal_ui.prompt_for_freeform_answer(
        "Answer",
        request.key,
        request.recommended_option,
      ))
      Ok(#(answer, warning))
    }
    options -> {
      let labels =
        options
        |> list.map(fn(option) {
          case request.recommended_option {
            Some(recommended) if recommended == option.label ->
              option.label <> " (recommended) - " <> option.description
            _ -> option.label <> " - " <> option.description
          }
        })
      let final_labels = case request.allow_freeform {
        True -> list.append(labels, ["Enter a custom answer"])
        False -> labels
      }
      let selected =
        terminal_ui.select_from_labels(
          "Choose an answer:",
          final_labels,
          terminal_ui.recommended_option_index(
            options
              |> list.map(fn(option) { #(option.label, option.description) }),
            request.recommended_option,
          ),
        )
      case request.allow_freeform && selected == list.length(final_labels) - 1 {
        True ->
          terminal_ui.prompt_for_freeform_answer(
            "Answer",
            request.key,
            request.recommended_option,
          )
          |> result.map(fn(answer) { #(answer, None) })
        False ->
          case list.drop(options, selected) {
            [choice, ..] -> Ok(#(choice.label, None))
            [] -> Error("The selected decision option was out of range.")
          }
      }
    }
  }
}

fn decision_contract_warning_event(
  task: types.Task,
  request: types.DecisionRequest,
) -> types.RunEvent {
  types.RunEvent(
    kind: "decision_contract_warning",
    at: system.timestamp(),
    message: "Coerced `"
      <> request.key
      <> "` into a freeform prompt because the planner returned no options and disallowed freeform input.",
    task_id: Some(task.id),
  )
}
