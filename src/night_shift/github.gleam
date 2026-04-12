//// GitHub CLI integration for pull request delivery and review ingestion.
import filepath
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import night_shift/shell
import night_shift/system
import simplifile

/// Minimal pull request identity returned after delivery.
pub type PullRequest {
  PullRequest(number: Int, url: String, head_ref_name: String, title: String)
}

/// Review details ingested when Night Shift turns open PR feedback into work.
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

/// Create or update the pull request for a task branch.
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
      Ok(PullRequest(..pull_request, title: title))
    }
    Error(_) -> {
      use create_output <- result.try(create_pull_request(
        cwd,
        branch_name,
        base_ref,
        title,
        body_path,
        log_path,
      ))
      case pull_request_from_create_output(create_output, branch_name, title) {
        Ok(pull_request) -> Ok(pull_request)
        Error(_) ->
          find_pull_request_after_create(cwd, branch_name, title, log_path, 5)
      }
    }
  }
}

/// List open pull requests created by the configured Night Shift branch prefix.
pub fn list_night_shift_prs(
  cwd: String,
  branch_prefix: String,
  log_path: String,
) -> Result(List(PullRequest), String) {
  use prs <- result.try(list_pull_requests(cwd, "", log_path))
  Ok(
    prs
    |> list.filter(fn(pr) {
      string.starts_with(pr.head_ref_name, branch_prefix)
    }),
  )
}

/// Load review decision, failing checks, and comments for one pull request.
pub fn review_item(
  cwd: String,
  pr_number: Int,
  log_path: String,
) -> Result(ReviewWorkItem, String) {
  let command =
    gh_pr_command("view ")
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
  branch_name: String,
  log_path: String,
) -> Result(List(PullRequest), String) {
  let head_fragment = case branch_name {
    "" -> ""
    value -> " --head " <> shell.quote(value)
  }
  let result =
    shell.run(
      gh_pr_command("list --state open --limit 100")
        <> head_fragment
        <> " --json number,url,headRefName,title",
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
  use prs <- result.try(list_pull_requests(cwd, branch_name, log_path))
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
) -> Result(String, String) {
  let command =
    gh_pr_command("create --title ")
    <> shell.quote(title)
    <> " --body-file "
    <> shell.quote(body_path)
    <> " --base "
    <> shell.quote(base_ref)
    <> " --head "
    <> shell.quote(branch_name)

  let result = shell.run(command, cwd, log_path)
  case shell.succeeded(result) {
    True -> Ok(string.trim(result.output))
    False -> Error(string.trim(result.output))
  }
}

fn edit_pull_request(
  cwd: String,
  pr_number: Int,
  title: String,
  body_path: String,
  log_path: String,
) -> Result(Nil, String) {
  let command =
    gh_pr_command("edit ")
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

fn gh_pr_command(args: String) -> String {
  gh_executable() <> " pr " <> args
}

fn gh_executable() -> String {
  case system.get_env("NIGHT_SHIFT_GH_BIN") {
    "" -> "gh"
    path -> shell.quote(path)
  }
}

fn find_pull_request_after_create(
  cwd: String,
  branch_name: String,
  title: String,
  log_path: String,
  attempts_remaining: Int,
) -> Result(PullRequest, String) {
  case find_pull_request(cwd, branch_name, log_path) {
    Ok(pull_request) -> Ok(PullRequest(..pull_request, title: title))
    Error(message) ->
      case attempts_remaining <= 1 {
        True -> Error(message)
        False -> {
          system.sleep(200)
          find_pull_request_after_create(
            cwd,
            branch_name,
            title,
            log_path,
            attempts_remaining - 1,
          )
        }
      }
  }
}

fn pull_request_from_create_output(
  output: String,
  branch_name: String,
  title: String,
) -> Result(PullRequest, String) {
  use url <- result.try(first_pull_request_url(output))
  use number <- result.try(parse_pull_request_number(url))
  Ok(PullRequest(
    number: number,
    url: url,
    head_ref_name: branch_name,
    title: title,
  ))
}

fn first_pull_request_url(output: String) -> Result(String, String) {
  output
  |> string.split("\n")
  |> list.map(string.trim)
  |> list.filter(fn(line) {
    string.starts_with(line, "https://") || string.starts_with(line, "http://")
  })
  |> list.first
  |> result.map_error(fn(_) {
    "No pull request URL was returned by gh pr create."
  })
}

fn parse_pull_request_number(url: String) -> Result(Int, String) {
  let sanitized =
    url
    |> trim_url_suffix("?")
    |> trim_url_suffix("#")

  case
    sanitized
    |> string.split("/")
    |> list.filter(fn(segment) { segment != "" })
    |> list.reverse
    |> list.first
  {
    Ok(segment) ->
      case int.parse(segment) {
        Ok(number) -> Ok(number)
        Error(Nil) ->
          Error("Unable to determine a pull request number from " <> url)
      }
    Error(_) -> Error("Unable to determine a pull request number from " <> url)
  }
}

fn trim_url_suffix(url: String, delimiter: String) -> String {
  case string.split(url, delimiter) {
    [] -> url
    [head, ..] -> head
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
