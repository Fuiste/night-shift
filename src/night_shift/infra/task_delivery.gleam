import filepath
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import night_shift/domain/pr_handoff
import night_shift/domain/pull_request as pull_request_domain
import night_shift/domain/summary as domain_summary
import night_shift/git
import night_shift/github
import night_shift/provider
import night_shift/repo_state_runtime
import night_shift/system
import night_shift/types
import simplifile

pub type DeliveryOutcome {
  NoDeliveredChanges(delivered_files: List(String))
  Delivered(
    pr_number: String,
    pr_url: String,
    delivered_files: List(String),
    handoff_state: types.TaskHandoffState,
    handoff_events: List(types.RunEvent),
  )
}

pub fn deliver_completed_task(
  config: types.Config,
  run: types.RunRecord,
  task_run: provider.TaskRun,
  execution_result: types.ExecutionResult,
  verification_output: String,
) -> Result(DeliveryOutcome, String) {
  let git_log =
    filepath.join(run.run_path, "logs/" <> task_run.task.id <> ".deliver.log")
  use _ <- result.try(commit_worktree_changes(task_run, git_log))
  use delivered_head <- result.try(
    git.head_commit(task_run.worktree_path, git_log)
    |> result.map_error(git_delivery_error),
  )
  let delivered_files =
    git.changed_files_between(
      task_run.worktree_path,
      task_run.start_head,
      "HEAD",
      git_log,
    )

  case delivered_head == task_run.start_head {
    True -> Ok(NoDeliveredChanges(delivered_files))
    False -> {
      use _ <- result.try(
        git.push_branch(task_run.worktree_path, task_run.branch_name, git_log)
        |> result.map_error(git_delivery_error),
      )
      let snippets_and_events = load_snippets(run.repo_root, config.handoff, task_run.task.id)
      let #(snippets, snippet_events) = snippets_and_events
      let legacy_body =
        pull_request_domain.render_legacy_body(
          run,
          task_run.task,
          execution_result,
          verification_output,
        )
      let handoff_region = case
        pr_handoff.body_region_enabled(config.handoff)
      {
        True ->
          Some(pr_handoff.render_body_region(
            config.handoff,
            run,
            task_run.task,
            execution_result,
            verification_output,
            snippets,
          ))
        False -> None
      }
      use pull_request <- result.try(
        github.open_or_update_pr(
          task_run.worktree_path,
          task_run.branch_name,
          task_run.base_ref,
          execution_result.pr.title,
          legacy_body,
          handoff_region,
          config.handoff,
          run.run_path,
          git_log,
        )
        |> result.map_error(fn(message) {
          domain_summary.task_failure_summary(
            "GitHub PR delivery failed.",
            message,
          )
        }),
      )
      let repo_state_status = case config.handoff.managed_comment {
        True ->
          case repo_state_runtime.inspect(run, config.branch_prefix).view {
            Some(view) ->
              Some(pr_handoff.RepoStateStatus(
                drift: repo_state_runtime.drift_label(view.drift),
                open_pr_count: view.open_pr_count,
                actionable_pr_count: view.actionable_pr_count,
              ))
            None -> None
          }
        False -> None
      }
      let previous_state =
        types.task_handoff_state(run.handoff_states, task_run.task.id)
      let #(managed_comment_present, comment_events) = case
        config.handoff.enabled && config.handoff.managed_comment
      {
        True -> {
          let comment_body =
            pr_handoff.render_managed_comment(
              run,
              task_run.task,
              execution_result,
              verification_output,
              previous_state,
              repo_state_status,
              snippets,
            )
          case
            github.upsert_handoff_comment(
              task_run.worktree_path,
              pull_request.number,
              task_run.task.id,
              comment_body,
              git_log,
            )
          {
            Ok(github.CommentCreated) ->
              #(
                True,
                [handoff_event(
                  "pr_handoff_created",
                  task_run.task.id,
                  "Created managed PR handoff comment for PR #"
                    <> int.to_string(pull_request.number)
                    <> ".",
                )],
              )
            Ok(github.CommentUpdated) ->
              #(
                True,
                [handoff_event(
                  "pr_handoff_updated",
                  task_run.task.id,
                  "Updated managed PR handoff comment for PR #"
                    <> int.to_string(pull_request.number)
                    <> ".",
                )],
              )
            Error(message) ->
              #(
                False,
                [handoff_event(
                  "pr_handoff_warning",
                  task_run.task.id,
                  "Unable to update the managed PR handoff comment: " <> message,
                )],
              )
          }
        }
        False -> #(False, [])
      }
      let body_region_present = case handoff_region {
        Some(_) -> True
        None -> False
      }
      let handoff_state =
        types.TaskHandoffState(
          task_id: task_run.task.id,
          delivered_pr_number: int.to_string(pull_request.number),
          last_delivered_commit_sha: delivered_head,
          last_handoff_files: execution_result.files_touched,
          last_verification_digest: pr_handoff.verification_digest(
            verification_output,
          ),
          last_risks: execution_result.pr.risks,
          last_handoff_updated_at: system.timestamp(),
          body_region_present: body_region_present,
          managed_comment_present: managed_comment_present,
        )
      let base_handoff_event = case previous_state {
        Some(_) ->
          [handoff_event(
            "pr_handoff_updated",
            task_run.task.id,
            case body_region_present {
              True -> "Updated Night Shift PR handoff metadata."
              False -> "Persisted Night Shift PR handoff state."
            },
          )]
        None ->
          [handoff_event(
            "pr_handoff_created",
            task_run.task.id,
            case body_region_present {
              True -> "Created Night Shift PR handoff metadata."
              False -> "Created Night Shift PR handoff state."
            },
          )]
      }
      Ok(Delivered(
        pr_number: int.to_string(pull_request.number),
        pr_url: pull_request.url,
        delivered_files: delivered_files,
        handoff_state: handoff_state,
        handoff_events: list.append(
          list.append(snippet_events, base_handoff_event),
          comment_events,
        ),
      ))
    }
  }
}

fn commit_worktree_changes(
  task_run: provider.TaskRun,
  git_log: String,
) -> Result(Nil, String) {
  case git.has_changes(task_run.worktree_path, git_log) {
    True ->
      git.commit_all(
        task_run.worktree_path,
        "feat(night-shift): " <> task_run.task.title,
        git_log,
      )
      |> result.map_error(git_delivery_error)
    False -> Ok(Nil)
  }
}

fn git_delivery_error(message: String) -> String {
  domain_summary.task_failure_summary("git delivery failed.", message)
}

fn load_snippets(
  repo_root: String,
  handoff: types.HandoffConfig,
  task_id: String,
) -> #(pr_handoff.Snippets, List(types.RunEvent)) {
  let #(body_prefix, body_prefix_events) =
    load_snippet(repo_root, handoff.pr_body_prefix_path, task_id)
  let #(body_suffix, body_suffix_events) =
    load_snippet(repo_root, handoff.pr_body_suffix_path, task_id)
  let #(comment_prefix, comment_prefix_events) =
    load_snippet(repo_root, handoff.comment_prefix_path, task_id)
  let #(comment_suffix, comment_suffix_events) =
    load_snippet(repo_root, handoff.comment_suffix_path, task_id)

  #(
    pr_handoff.Snippets(
      body_prefix: body_prefix,
      body_suffix: body_suffix,
      comment_prefix: comment_prefix,
      comment_suffix: comment_suffix,
    ),
    list.append(
      list.append(body_prefix_events, body_suffix_events),
      list.append(comment_prefix_events, comment_suffix_events),
    ),
  )
}

fn load_snippet(
  repo_root: String,
  configured_path: Option(String),
  task_id: String,
) -> #(Option(String), List(types.RunEvent)) {
  case configured_path {
    None -> #(None, [])
    Some(path) -> {
      let absolute_path = case string.starts_with(path, "/") {
        True -> path
        False -> filepath.join(repo_root, path)
      }

      case simplifile.read(absolute_path) {
        Ok(contents) -> #(Some(contents), [])
        Error(_) ->
          #(
            None,
            [handoff_event(
              "pr_handoff_warning",
              task_id,
              "Unable to read handoff snippet at " <> path <> ".",
            )],
          )
      }
    }
  }
}

fn handoff_event(kind: String, task_id: String, message: String) -> types.RunEvent {
  types.RunEvent(
    kind: kind,
    at: system.timestamp(),
    message: message,
    task_id: Some(task_id),
  )
}
