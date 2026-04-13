import gleam/int
import gleam/list
import gleam/string
import night_shift/types

@external(erlang, "night_shift_repo_state_ffi", "sha256_hex")
fn sha256_hex(value: String) -> String

pub fn snapshot(
  captured_at: String,
  open_pull_requests: List(types.RepoPullRequestSnapshot),
) -> types.RepoStateSnapshot {
  let impacted_heads =
    impacted_head_refs(
      open_pull_requests,
      actionable_head_refs(open_pull_requests),
    )
  let annotated =
    open_pull_requests
    |> list.map(fn(pr) {
      types.RepoPullRequestSnapshot(
        ..pr,
        impacted: list.contains(impacted_heads, pr.head_ref_name),
      )
    })

  types.RepoStateSnapshot(
    captured_at: captured_at,
    digest: digest(annotated),
    open_pull_requests: annotated,
  )
}

pub fn open_pr_count(snapshot: types.RepoStateSnapshot) -> Int {
  list.length(snapshot.open_pull_requests)
}

pub fn actionable_pr_count(snapshot: types.RepoStateSnapshot) -> Int {
  snapshot.open_pull_requests
  |> list.filter(fn(pr) { pr.actionable })
  |> list.length
}

pub fn drifted(
  stored: types.RepoStateSnapshot,
  live: types.RepoStateSnapshot,
) -> Bool {
  stored.digest != live.digest
}

fn actionable_head_refs(
  open_pull_requests: List(types.RepoPullRequestSnapshot),
) -> List(String) {
  open_pull_requests
  |> list.filter(fn(pr) { pr.actionable })
  |> list.map(fn(pr) { pr.head_ref_name })
}

fn impacted_head_refs(
  open_pull_requests: List(types.RepoPullRequestSnapshot),
  acc: List(String),
) -> List(String) {
  let expanded =
    open_pull_requests
    |> list.fold(acc, fn(acc, pr) {
      case
        list.contains(acc, pr.base_ref_name)
        && !list.contains(acc, pr.head_ref_name)
      {
        True -> [pr.head_ref_name, ..acc]
        False -> acc
      }
    })

  case list.length(expanded) == list.length(acc) {
    True -> expanded
    False -> impacted_head_refs(open_pull_requests, expanded)
  }
}

fn digest(open_pull_requests: List(types.RepoPullRequestSnapshot)) -> String {
  open_pull_requests
  |> list.map(canonical_pr_line)
  |> list.sort(fn(left, right) { string.compare(left, right) })
  |> string.join(with: "\n")
  |> sha256_hex
}

fn canonical_pr_line(pr: types.RepoPullRequestSnapshot) -> String {
  string.join(
    [
      "number=" <> int_string(pr.number),
      "head=" <> pr.head_ref_name,
      "base=" <> pr.base_ref_name,
      "title=" <> pr.title,
      "url=" <> pr.url,
      "review_decision=" <> pr.review_decision,
      "failing_checks="
        <> pr.failing_checks
      |> list.sort(fn(left, right) { string.compare(left, right) })
      |> string.join(with: "|"),
      "review_comments="
        <> pr.review_comments
      |> list.sort(fn(left, right) { string.compare(left, right) })
      |> string.join(with: "|"),
      "actionable=" <> bool_label(pr.actionable),
      "impacted=" <> bool_label(pr.impacted),
    ],
    with: "\n",
  )
}

fn int_string(value: Int) -> String {
  int.to_string(value)
}

fn bool_label(value: Bool) -> String {
  case value {
    True -> "true"
    False -> "false"
  }
}
