import filepath
import gleam/int
import gleam/result
import night_shift/domain/pull_request as pull_request_domain
import night_shift/domain/summary as domain_summary
import night_shift/git
import night_shift/github
import night_shift/provider
import night_shift/types

pub type DeliveryOutcome {
  NoDeliveredChanges(delivered_files: List(String))
  Delivered(pr_number: String, pr_url: String, delivered_files: List(String))
}

pub fn deliver_completed_task(
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
      let pr_body =
        pull_request_domain.render_body(
          run,
          task_run.task,
          execution_result,
          verification_output,
        )
      use pull_request <- result.try(
        github.open_or_update_pr(
          task_run.worktree_path,
          task_run.branch_name,
          task_run.base_ref,
          execution_result.pr.title,
          pr_body,
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
      Ok(Delivered(
        pr_number: int.to_string(pull_request.number),
        pr_url: pull_request.url,
        delivered_files: delivered_files,
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
