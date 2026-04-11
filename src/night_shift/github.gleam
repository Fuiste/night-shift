import filepath
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import night_shift/shell
import simplifile

pub type PullRequest {
  PullRequest(number: Int, url: String, head_ref_name: String, title: String)
}

pub type ReviewWorkItem {
  ReviewWorkItem(
    number: Int,
    title: String,
    body: String,
    head_ref_name: String,
    base_ref_name: String,
    url: String,
    review_decision: String,
    failing_checks: List(String),
    review_comments: List(String),
  )
}

pub fn open_or_update_pr(
  cwd: String,
  branch_name: String,
  base_ref: String,
  title: String,
  body: String,
  run_path: String,
  log_path: String,
) -> Result(PullRequest, String) {
  let safe_branch_name =
    branch_name
    |> string.replace(each: "/", with: "-")
    |> string.replace(each: ":", with: "-")
  let body_path =
    filepath.join(run_path, "logs/" <> safe_branch_name <> ".pr.md")
  use _ <- result.try(write_file(body_path, body))

  case find_pull_request(cwd, branch_name, log_path) {
    Ok(pull_request) -> {
      use _ <- result.try(edit_pull_request(
        cwd,
        pull_request.number,
        title,
        body_path,
        log_path,
      ))
      find_pull_request(cwd, branch_name, log_path)
    }
    Error(_) -> {
      use _ <- result.try(create_pull_request(
        cwd,
        branch_name,
        base_ref,
        title,
        body_path,
        log_path,
      ))
      find_pull_request(cwd, branch_name, log_path)
    }
  }
}

pub fn list_night_shift_prs(
  cwd: String,
  branch_prefix: String,
  log_path: String,
) -> Result(List(PullRequest), String) {
  use prs <- result.try(list_pull_requests(cwd, log_path))
  Ok(
    prs
    |> list.filter(fn(pr) {
      string.starts_with(pr.head_ref_name, branch_prefix)
    }),
  )
}

pub fn review_item(
  cwd: String,
  pr_number: Int,
  log_path: String,
) -> Result(ReviewWorkItem, String) {
  let command =
    "gh pr view "
    <> int.to_string(pr_number)
    <> " --json number,title,body,headRefName,baseRefName,url,reviewDecision,statusCheckRollup,reviews,comments"

  let result = shell.run(command, cwd, log_path)
  case shell.succeeded(result) {
    True ->
      json.parse(result.output, review_work_item_decoder())
      |> result.map_error(fn(_) { "Unable to decode PR review details." })
    False -> Error("Unable to inspect PR " <> int.to_string(pr_number))
  }
}

fn list_pull_requests(
  cwd: String,
  log_path: String,
) -> Result(List(PullRequest), String) {
  let result =
    shell.run(
      "gh pr list --state open --limit 100 --json number,url,headRefName,title",
      cwd,
      log_path,
    )

  case shell.succeeded(result) {
    True ->
      json.parse(result.output, decode.list(pull_request_decoder()))
      |> result.map_error(fn(_) { "Unable to decode PR list output." })
    False -> Error("Unable to list pull requests.")
  }
}

fn find_pull_request(
  cwd: String,
  branch_name: String,
  log_path: String,
) -> Result(PullRequest, String) {
  use prs <- result.try(list_pull_requests(cwd, log_path))
  prs
  |> list.find(fn(pr) { pr.head_ref_name == branch_name })
  |> result.map_error(fn(_) {
    "No existing pull request for branch " <> branch_name
  })
}

fn create_pull_request(
  cwd: String,
  branch_name: String,
  base_ref: String,
  title: String,
  body_path: String,
  log_path: String,
) -> Result(Nil, String) {
  let command =
    "gh pr create --title "
    <> shell.quote(title)
    <> " --body-file "
    <> shell.quote(body_path)
    <> " --base "
    <> shell.quote(base_ref)
    <> " --head "
    <> shell.quote(branch_name)

  run_gh(command, cwd, log_path)
}

fn edit_pull_request(
  cwd: String,
  pr_number: Int,
  title: String,
  body_path: String,
  log_path: String,
) -> Result(Nil, String) {
  let command =
    "gh pr edit "
    <> int.to_string(pr_number)
    <> " --title "
    <> shell.quote(title)
    <> " --body-file "
    <> shell.quote(body_path)

  run_gh(command, cwd, log_path)
}

fn run_gh(command: String, cwd: String, log_path: String) -> Result(Nil, String) {
  let result = shell.run(command, cwd, log_path)
  case shell.succeeded(result) {
    True -> Ok(Nil)
    False -> Error(string.trim(result.output))
  }
}

fn pull_request_decoder() -> decode.Decoder(PullRequest) {
  use number <- decode.field("number", decode.int)
  use url <- decode.field("url", decode.string)
  use head_ref_name <- decode.field("headRefName", decode.string)
  use title <- decode.field("title", decode.string)
  decode.success(PullRequest(
    number: number,
    url: url,
    head_ref_name: head_ref_name,
    title: title,
  ))
}

fn review_work_item_decoder() -> decode.Decoder(ReviewWorkItem) {
  use number <- decode.field("number", decode.int)
  use title <- decode.field("title", decode.string)
  use body <- decode.field("body", decode.string)
  use head_ref_name <- decode.field("headRefName", decode.string)
  use base_ref_name <- decode.field("baseRefName", decode.string)
  use url <- decode.field("url", decode.string)
  use review_decision <- decode.field("reviewDecision", decode.string)
  use failing_checks <- decode.field(
    "statusCheckRollup",
    decode.list(check_decoder()),
  )
  use reviews <- decode.field("reviews", decode.list(review_decoder()))
  use comments <- decode.field("comments", decode.list(comment_decoder()))
  decode.success(ReviewWorkItem(
    number: number,
    title: title,
    body: body,
    head_ref_name: head_ref_name,
    base_ref_name: base_ref_name,
    url: url,
    review_decision: review_decision,
    failing_checks: list.filter_map(failing_checks, identity),
    review_comments: list.append(reviews, comments),
  ))
}

fn check_decoder() -> decode.Decoder(Result(String, Nil)) {
  use name <- decode.field("name", decode.string)
  use conclusion <- decode.field("conclusion", decode.string)
  case conclusion {
    "SUCCESS" -> decode.success(Error(Nil))
    "NEUTRAL" -> decode.success(Error(Nil))
    _ -> decode.success(Ok(name <> ": " <> conclusion))
  }
}

fn review_decoder() -> decode.Decoder(String) {
  use state <- decode.field("state", decode.string)
  use body <- decode.field("body", decode.string)
  decode.success("Review " <> state <> ": " <> body)
}

fn comment_decoder() -> decode.Decoder(String) {
  use body <- decode.field("body", decode.string)
  decode.success("Comment: " <> body)
}

fn identity(value: Result(String, Nil)) -> Result(String, Nil) {
  value
}

fn write_file(path: String, contents: String) -> Result(Nil, String) {
  case simplifile.write(contents, to: path) {
    Ok(Nil) -> Ok(Nil)
    Error(error) ->
      Error(
        "Unable to write " <> path <> ": " <> simplifile.describe_error(error),
      )
  }
}
