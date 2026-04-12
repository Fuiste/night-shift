import gleam/option.{None}
import gleam/string
import night_shift/domain/decision_contract
import night_shift/types

pub fn reconcile_decision_requests_reuses_recorded_file_location_answer_test() {
  let decisions = [
    types.RecordedDecision(
      key: "target_file",
      question: "Which file should host the tiny next-day follow-up note that builds on QA_NOTES?",
      answer: "QA_NOTES.md",
      answered_at: "2026-04-12T10:27:22-07:00",
    ),
  ]
  let task =
    types.Task(
      id: "follow-up-note",
      title: "Add follow-up note",
      description: "Add the tiny follow-up note.",
      dependencies: [],
      acceptance: ["Update QA_NOTES.md."],
      demo_plan: ["Inspect QA_NOTES.md."],
      decision_requests: [
        types.DecisionRequest(
          key: "confirm-documentation-target",
          question: "Where should the one tiny follow-up note be added?",
          rationale: "Need the right documentation target.",
          options: [],
          recommended_option: None,
          allow_freeform: True,
        ),
      ],
      kind: types.ManualAttentionTask,
      execution_mode: types.Exclusive,
      state: types.Ready,
      worktree_path: "",
      branch_name: "",
      pr_number: "",
      summary: "",
    )

  let assert Ok(#([updated_task], warnings)) =
    decision_contract.reconcile_decision_requests(decisions, [task])
  let assert [warning] = warnings
  let assert [request] = updated_task.decision_requests

  assert request.key == "target_file"
  assert warning.previous_key == "confirm-documentation-target"
  assert warning.new_key == "target_file"
}

pub fn reconcile_decision_requests_rejects_ambiguous_matches_test() {
  let decisions = [
    types.RecordedDecision(
      key: "target_file",
      question: "Which file should host the tiny note?",
      answer: "QA_NOTES.md",
      answered_at: "2026-04-12T10:27:22-07:00",
    ),
    types.RecordedDecision(
      key: "release_notes_file",
      question: "Which documentation file should receive the tiny note?",
      answer: "RELEASE_NOTES.md",
      answered_at: "2026-04-12T10:27:23-07:00",
    ),
  ]
  let task =
    types.Task(
      id: "follow-up-note",
      title: "Add follow-up note",
      description: "Add the tiny follow-up note.",
      dependencies: [],
      acceptance: ["Update docs."],
      demo_plan: ["Inspect docs."],
      decision_requests: [
        types.DecisionRequest(
          key: "confirm-documentation-target",
          question: "Where should the one tiny follow-up note be added?",
          rationale: "Need the right documentation target.",
          options: [],
          recommended_option: None,
          allow_freeform: True,
        ),
      ],
      kind: types.ManualAttentionTask,
      execution_mode: types.Exclusive,
      state: types.Ready,
      worktree_path: "",
      branch_name: "",
      pr_number: "",
      summary: "",
    )

  let assert Error(message) =
    decision_contract.reconcile_decision_requests(decisions, [task])

  assert string.contains(does: message, contain: "ambiguously")
}
