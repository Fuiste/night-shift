import gleam/list
import gleam/option.{None, Some}
import night_shift/domain/decisions
import night_shift/types

pub fn apply_decision_states_marks_manual_attention_until_answered_test() {
  let task = manual_attention_task()
  let assert [updated] = decisions.apply_decision_states([task], [])

  assert updated.state == types.ManualAttention
  assert list.length(types.unresolved_decision_requests([], updated)) == 1
}

pub fn apply_decision_states_marks_answered_manual_attention_completed_test() {
  let task = manual_attention_task()
  let decisions_record = [
    types.RecordedDecision(
      key: "wiki-location",
      question: "Where should the wiki live?",
      answer: "docs/wiki",
      answered_at: "2026-04-11T00:00:00Z",
    ),
  ]

  let assert [updated] =
    decisions.apply_decision_states([task], decisions_record)

  assert updated.state == types.Completed
}

pub fn merge_recorded_decisions_replaces_matching_keys_test() {
  let existing = [
    types.RecordedDecision(
      key: "wiki-location",
      question: "Where should the wiki live?",
      answer: "docs/old",
      answered_at: "2026-04-11T00:00:00Z",
    ),
  ]
  let incoming = [
    types.RecordedDecision(
      key: "wiki-location",
      question: "Where should the wiki live?",
      answer: "docs/wiki",
      answered_at: "2026-04-11T01:00:00Z",
    ),
  ]

  let merged = decisions.merge_recorded_decisions(existing, incoming)

  let assert [decision] = merged
  assert decision.answer == "docs/wiki"
}

pub fn pending_decision_prompts_flattens_requests_test() {
  let prompts =
    decisions.pending_decision_prompts([], [manual_attention_task()])

  assert list.length(prompts) == 1
}

fn manual_attention_task() -> types.Task {
  types.Task(
    id: "docs-wiki",
    title: "Docs wiki",
    description: "Decide where the new docs wiki should live.",
    dependencies: [],
    acceptance: [],
    demo_plan: [],
    decision_requests: [
      types.DecisionRequest(
        key: "wiki-location",
        question: "Where should the wiki live?",
        rationale: "This determines the implementation path.",
        options: [
          types.DecisionOption(
            label: "docs/wiki",
            description: "Create a dedicated docs wiki directory.",
          ),
        ],
        recommended_option: Some("docs/wiki"),
        allow_freeform: True,
      ),
    ],
    superseded_pr_numbers: [],
    kind: types.ManualAttentionTask,
    execution_mode: types.Exclusive,
    state: types.Ready,
    worktree_path: "",
    branch_name: "",
    pr_number: "",
    summary: "",
    runtime_context: None,
  )
}
