import gleam/int
import gleam/list
import gleam/string
import night_shift/types

pub fn render_body(
  run: types.RunRecord,
  task: types.Task,
  execution_result: types.ExecutionResult,
  verification_output: String,
) -> String {
  "## Summary\n"
  <> execution_result.pr.summary
  <> "\n\n## Demo\n"
  <> bullet_list(execution_result.pr.demo)
  <> "\n\n## Verification\n```\n"
  <> verification_output
  <> "\n```\n\n## Known Risks\n"
  <> bullet_list(execution_result.pr.risks)
  <> "\n\n<!-- night-shift:run="
  <> run.run_id
  <> ";task="
  <> task.id
  <> ";brief="
  <> run.brief_path
  <> " -->"
}

pub fn review_task(
  number: Int,
  url: String,
  body: String,
  head_ref_name: String,
  review_comments: List(String),
  failing_checks: List(String),
) -> types.Task {
  let description =
    "Stabilize PR #"
    <> int.to_string(number)
    <> " ("
    <> url
    <> ") by addressing review comments and failing checks.\n\n"
    <> body
    <> "\n\nReview notes:\n"
    <> bullet_list(review_comments)
    <> "\n\nFailing checks:\n"
    <> bullet_list(failing_checks)

  types.Task(
    id: "review-pr-" <> int.to_string(number),
    title: "Stabilize PR #" <> int.to_string(number),
    description: description,
    dependencies: [],
    acceptance: [
      "Resolve requested review feedback when possible.",
      "Leave the PR in a green or clearly blocked state.",
    ],
    demo_plan: ["Summarize the fixes and checks in the PR body."],
    decision_requests: [],
    kind: types.ImplementationTask,
    execution_mode: types.Exclusive,
    state: types.Ready,
    worktree_path: "",
    branch_name: head_ref_name,
    pr_number: int.to_string(number),
    summary: "",
  )
}

fn bullet_list(items: List(String)) -> String {
  case items {
    [] -> "- None"
    _ ->
      items
      |> list.map(fn(item) { "- " <> item })
      |> string.join(with: "\n")
  }
}
