import filepath
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import night_shift/git
import night_shift/github
import night_shift/journal
import night_shift/provider
import night_shift/project
import night_shift/shell
import night_shift/system
import night_shift/types
import night_shift/worktree_setup

pub fn start(
  run: types.RunRecord,
  config: types.Config,
) -> Result(types.RunRecord, String) {
  use planned_tasks <- result.try(provider.plan_tasks(
    run.planning_agent,
    run.repo_root,
    run.brief_path,
    run.run_path,
  ))

  let normalized_tasks = normalize_tasks(planned_tasks)
  let planned_run = types.RunRecord(..run, tasks: normalized_tasks)
  let planned_event =
    types.RunEvent(
      kind: "task_progress",
      at: system.timestamp(),
      message: "Planner produced "
        <> int.to_string(list.length(normalized_tasks))
        <> " tasks.",
      task_id: None,
    )

  use persisted_run <- result.try(journal.append_event(
    planned_run,
    planned_event,
  ))
  scheduler_loop(config, persisted_run)
}

pub fn resume(
  run: types.RunRecord,
  config: types.Config,
) -> Result(types.RunRecord, String) {
  let resumed_tasks =
    run.tasks
    |> list.map(fn(task) { recover_task(task) })
    |> refresh_ready_states

  let resumed_run = types.RunRecord(..run, tasks: resumed_tasks)
  let event =
    types.RunEvent(
      kind: "task_progress",
      at: system.timestamp(),
      message: "Run resumed; interrupted workers were requeued or marked for manual attention.",
      task_id: None,
    )

  use persisted_run <- result.try(journal.append_event(resumed_run, event))
  scheduler_loop(config, persisted_run)
}

pub fn review(
  run: types.RunRecord,
  config: types.Config,
) -> Result(types.RunRecord, String) {
  let log_path = filepath.join(run.run_path, "logs/review.log")
  use prs <- result.try(github.list_night_shift_prs(
    run.repo_root,
    config.branch_prefix,
    log_path,
  ))

  let review_tasks =
    prs
    |> list.try_map(fn(pr) {
      use details <- result.try(github.review_item(
        run.repo_root,
        pr.number,
        log_path,
      ))
      Ok(review_task_from_pr(details))
    })

  use tasks <- result.try(review_tasks)
  let seeded_run = types.RunRecord(..run, tasks: normalize_tasks(tasks))
  let event =
    types.RunEvent(
      kind: "task_progress",
      at: system.timestamp(),
      message: "Review mode loaded "
        <> int.to_string(list.length(tasks))
        <> " stabilization tasks.",
      task_id: None,
    )

  use persisted_run <- result.try(journal.append_event(seeded_run, event))
  scheduler_loop(config, persisted_run)
}

fn scheduler_loop(
  config: types.Config,
  run: types.RunRecord,
) -> Result(types.RunRecord, String) {
  let refreshed_run =
    types.RunRecord(..run, tasks: refresh_ready_states(run.tasks))
  let batch = next_batch(refreshed_run.tasks, refreshed_run.max_workers)

  case batch {
    [] -> finish_run(refreshed_run)
    _ -> {
      use #(running_run, task_runs) <- result.try(launch_batch(
        config,
        refreshed_run,
        batch,
      ))
      use completed_run <- result.try(await_batch(
        config,
        running_run,
        task_runs,
      ))
      scheduler_loop(config, completed_run)
    }
  }
}

fn finish_run(run: types.RunRecord) -> Result(types.RunRecord, String) {
  let status = final_status(run.tasks)
  let message = case status {
    types.RunCompleted -> "Night Shift completed all queued work."
    types.RunFailed -> "Night Shift encountered failed tasks."
    types.RunBlocked -> blocked_run_message(run.tasks)
    _ -> "Night Shift stopped."
  }

  journal.mark_status(run, status, message)
}

fn launch_batch(
  config: types.Config,
  run: types.RunRecord,
  tasks: List(types.Task),
) -> Result(#(types.RunRecord, List(provider.TaskRun)), String) {
  launch_batch_loop(config, run, tasks, [])
}

fn launch_batch_loop(
  config: types.Config,
  run: types.RunRecord,
  tasks: List(types.Task),
  acc: List(provider.TaskRun),
) -> Result(#(types.RunRecord, List(provider.TaskRun)), String) {
  case tasks {
    [] -> Ok(#(run, list.reverse(acc)))
    [task, ..rest] -> {
      let branch_name = case task.branch_name {
        "" -> build_branch_name(config.branch_prefix, run.run_id, task.id)
        existing_branch -> existing_branch
      }
      let worktree_path = filepath.join(run.run_path, "worktrees/" <> task.id)
      let base_ref = case task.branch_name {
        "" -> task_base_ref(task, run.tasks, config.base_branch)
        existing_branch -> existing_branch
      }
      let git_log =
        filepath.join(run.run_path, "logs/" <> task.id <> ".git.log")
      let env_log =
        filepath.join(run.run_path, "logs/" <> task.id <> ".env.log")
      let worktree_result = case task.branch_name {
        "" ->
          git.create_worktree(
            run.repo_root,
            worktree_path,
            branch_name,
            base_ref,
            git_log,
          )
        _ ->
          git.attach_worktree(
            run.repo_root,
            worktree_path,
            branch_name,
            git_log,
          )
      }

      case worktree_result {
        Ok(_) -> {
          let running_task =
            types.Task(
              ..task,
              state: types.Running,
              worktree_path: worktree_path,
              branch_name: branch_name,
            )
          let updated_run =
            types.RunRecord(..run, tasks: replace_task(run.tasks, running_task))
          let event =
            types.RunEvent(
              kind: "task_started",
              at: system.timestamp(),
              message: "Started task " <> task.title,
              task_id: Some(task.id),
            )

          use persisted_run <- result.try(journal.append_event(
            updated_run,
            event,
          ))
          case
            start_task_run(
              persisted_run,
              running_task,
              worktree_path,
              branch_name,
              base_ref,
              git_log,
              env_log,
            )
          {
            Ok(#(started_run, task_run)) ->
              launch_batch_loop(config, started_run, rest, [task_run, ..acc])

            Error(message) -> {
              use failed_run <- result.try(mark_task_with_event(
                persisted_run,
                running_task,
                types.Failed,
                message,
                "task_failed",
              ))
              launch_batch_loop(config, failed_run, rest, acc)
            }
          }
        }
        Error(message) -> {
          let failed_task =
            types.Task(..task, state: types.Failed, summary: message)
          let failed_run =
            types.RunRecord(..run, tasks: replace_task(run.tasks, failed_task))
          let event =
            types.RunEvent(
              kind: "task_failed",
              at: system.timestamp(),
              message: message,
              task_id: Some(task.id),
            )
          use persisted_run <- result.try(journal.append_event(
            failed_run,
            event,
          ))
          launch_batch_loop(config, persisted_run, rest, acc)
        }
      }
    }
  }
}

fn await_batch(
  config: types.Config,
  run: types.RunRecord,
  task_runs: List(provider.TaskRun),
) -> Result(types.RunRecord, String) {
  case task_runs {
    [] -> Ok(run)
    [task_run, ..rest] -> {
      use execution_result <- result.try(provider.await_task(task_run))
      use updated_run <- result.try(complete_task(
        config,
        run,
        task_run,
        execution_result,
      ))
      await_batch(config, updated_run, rest)
    }
  }
}

fn complete_task(
  config: types.Config,
  run: types.RunRecord,
  task_run: provider.TaskRun,
  execution_result: types.ExecutionResult,
) -> Result(types.RunRecord, String) {
  case execution_result.status {
    types.Completed -> finalize_success(config, run, task_run, execution_result)
    types.Blocked | types.ManualAttention | types.Failed ->
      finalize_non_success(run, task_run.task, execution_result)
    _ -> finalize_non_success(run, task_run.task, execution_result)
  }
}

fn finalize_non_success(
  run: types.RunRecord,
  task: types.Task,
  execution_result: types.ExecutionResult,
) -> Result(types.RunRecord, String) {
  let event_kind = event_kind_for_state(execution_result.status)
  mark_task_with_event(
    run,
    task,
    execution_result.status,
    execution_result.summary,
    event_kind,
  )
}

fn finalize_success(
  config: types.Config,
  run: types.RunRecord,
  task_run: provider.TaskRun,
  execution_result: types.ExecutionResult,
) -> Result(types.RunRecord, String) {
  let verification_log =
    filepath.join(run.run_path, "logs/" <> task_run.task.id <> ".verify.log")
  use env_vars <- result.try(worktree_setup.env_vars_for(
    run.repo_root,
    run.environment_name,
    project.worktree_setup_path(run.repo_root),
  ))
  let verify_result =
    verify_commands(
      config.verification_commands,
      task_run.worktree_path,
      env_vars,
      verification_log,
    )

  let final_result = case verify_result {
    Ok(output) -> Ok(#(execution_result, output))
    Error(output) ->
      case
        provider.repair_task(
          run.execution_agent,
          run.repo_root,
          task_run.worktree_path,
          env_vars,
          run.run_path,
          task_run.task,
          output,
        )
      {
        Ok(repaired_result) ->
          case
            verify_commands(
              config.verification_commands,
              task_run.worktree_path,
              env_vars,
              verification_log,
            )
          {
            Ok(repaired_output) -> Ok(#(repaired_result, repaired_output))
            Error(repaired_output) -> Error(repaired_output)
          }
        Error(_) -> Error(output)
      }
  }

  case final_result {
    Ok(#(final_execution, verification_output)) -> {
      let git_log =
        filepath.join(
          run.run_path,
          "logs/" <> task_run.task.id <> ".deliver.log",
        )
      let had_worktree_changes =
        git.has_changes(task_run.worktree_path, git_log)

      let delivery_result = case had_worktree_changes {
        True ->
          git.commit_all(
            task_run.worktree_path,
            "feat(night-shift): " <> task_run.task.title,
            git_log,
          )
        False -> Ok(Nil)
      }

      use _ <- result.try(delivery_result)
      use delivered_head <- result.try(git.head_commit(
        task_run.worktree_path,
        git_log,
      ))
      let delivered_files =
        git.changed_files_between(
          task_run.worktree_path,
          task_run.start_head,
          "HEAD",
          git_log,
        )

      case delivered_head == task_run.start_head {
        True -> {
          mark_task_with_event(
            run,
            task_run.task,
            types.ManualAttention,
            "Primary blocker: provider reported completion but the task worktree produced no committed or uncommitted changes.\n\nEnvironment notes: verification completed, but there was nothing new to deliver.",
            "task_manual_attention",
          )
        }
        False -> {
          use _ <- result.try(git.push_branch(
            task_run.worktree_path,
            task_run.branch_name,
            git_log,
          ))
          let pr_body =
            build_pr_body(
              run,
              task_run.task,
              final_execution,
              verification_output,
            )
          use pull_request <- result.try(github.open_or_update_pr(
            task_run.worktree_path,
            task_run.branch_name,
            task_run.base_ref,
            final_execution.pr.title,
            pr_body,
            run.run_path,
            git_log,
          ))

          let completed_task =
            types.Task(
              ..task_run.task,
              state: types.Completed,
              worktree_path: task_run.worktree_path,
              branch_name: task_run.branch_name,
              pr_number: int.to_string(pull_request.number),
              summary: final_execution.summary,
            )

          let merged_tasks =
            merge_follow_up_tasks(
              replace_task(run.tasks, completed_task),
              final_execution.follow_up_tasks,
            )
          let updated_run = types.RunRecord(..run, tasks: merged_tasks)
          let verified_event =
            types.RunEvent(
              kind: "task_verified",
              at: system.timestamp(),
              message: "Verification passed for " <> task_run.task.title,
              task_id: Some(task_run.task.id),
            )
          use verified_run <- result.try(journal.append_event(
            updated_run,
            verified_event,
          ))
          journal.append_event(
            types.RunRecord(
              ..verified_run,
              tasks: replace_task(
                verified_run.tasks,
                types.Task(
                  ..completed_task,
                  summary: final_execution.summary
                    <> " Changed files: "
                    <> string.join(delivered_files, ", "),
                ),
              ),
            ),
            types.RunEvent(
              kind: "pr_opened",
              at: system.timestamp(),
              message: pull_request.url,
              task_id: Some(task_run.task.id),
            ),
          )
        }
      }
    }
    Error(output) -> {
      mark_task_with_event(
        run,
        task_run.task,
        types.Failed,
        "Primary blocker: verification failed.\n\nEnvironment notes:\n"
          <> output,
        "task_failed",
      )
    }
  }
}

fn verify_commands(
  commands: List(String),
  cwd: String,
  env_vars: List(#(String, String)),
  log_path: String,
) -> Result(String, String) {
  case commands {
    [] -> Ok("No verification commands configured.")
    _ -> verify_loop(commands, cwd, env_vars, log_path, [])
  }
}

fn verify_loop(
  commands: List(String),
  cwd: String,
  env_vars: List(#(String, String)),
  log_path: String,
  acc: List(String),
) -> Result(String, String) {
  case commands {
    [] -> Ok(string.join(list.reverse(acc), "\n\n"))
    [command, ..rest] -> {
      let output = shell.run(shell.with_env(command, env_vars), cwd, log_path)
      let transcript = "$ " <> command <> "\n" <> output.output

      case shell.succeeded(output) {
        True -> verify_loop(rest, cwd, env_vars, log_path, [transcript, ..acc])
        False -> Error(string.join(list.reverse([transcript, ..acc]), "\n\n"))
      }
    }
  }
}

fn normalize_tasks(tasks: List(types.Task)) -> List(types.Task) {
  tasks
  |> list.map(fn(task) {
    case task.dependencies {
      [] -> types.Task(..task, state: types.Ready)
      _ -> types.Task(..task, state: types.Queued)
    }
  })
}

fn refresh_ready_states(tasks: List(types.Task)) -> List(types.Task) {
  let completed_ids =
    tasks
    |> list.filter(fn(task) { task.state == types.Completed })
    |> list.map(fn(task) { task.id })

  tasks
  |> list.map(fn(task) {
    case task.state {
      types.Queued ->
        case types.is_task_ready(task, completed_ids) {
          True -> types.Task(..task, state: types.Ready)
          False -> task
        }
      _ -> task
    }
  })
}

fn next_batch(tasks: List(types.Task), max_workers: Int) -> List(types.Task) {
  tasks
  |> list.filter(fn(task) { task.state == types.Ready })
  |> build_batch(max_workers, [], False)
  |> list.reverse
}

fn replace_task(
  tasks: List(types.Task),
  updated: types.Task,
) -> List(types.Task) {
  tasks
  |> list.map(fn(task) {
    case task.id == updated.id {
      True -> updated
      False -> task
    }
  })
}

fn merge_follow_up_tasks(
  tasks: List(types.Task),
  follow_up_tasks: List(types.FollowUpTask),
) -> List(types.Task) {
  follow_up_tasks
  |> list.fold(tasks, fn(acc, follow_up) {
    case list.any(acc, fn(task) { task.id == follow_up.id }) {
      True -> acc
      False -> [
        types.Task(
          id: follow_up.id,
          title: follow_up.title,
          description: follow_up.description,
          dependencies: follow_up.dependencies,
          acceptance: follow_up.acceptance,
          demo_plan: follow_up.demo_plan,
          execution_mode: follow_up.execution_mode,
          state: types.Queued,
          worktree_path: "",
          branch_name: "",
          pr_number: "",
          summary: "",
        ),
        ..acc
      ]
    }
  })
  |> list.reverse
  |> refresh_ready_states
}

fn task_base_ref(
  task: types.Task,
  tasks: List(types.Task),
  default_base: String,
) -> String {
  case task.dependencies {
    [] -> default_base
    [dependency, ..] ->
      tasks
      |> list.find(fn(candidate) { candidate.id == dependency })
      |> result.map(fn(found) {
        case found.branch_name {
          "" -> default_base
          branch_name -> branch_name
        }
      })
      |> result.unwrap(or: default_base)
  }
}

fn build_branch_name(prefix: String, run_id: String, task_id: String) -> String {
  prefix <> "/" <> sanitize_segment(run_id) <> "-" <> sanitize_segment(task_id)
}

fn sanitize_segment(value: String) -> String {
  value
  |> string.replace(each: "/", with: "-")
  |> string.replace(each: " ", with: "-")
  |> string.replace(each: ":", with: "-")
}

fn final_status(tasks: List(types.Task)) -> types.RunStatus {
  case list.any(tasks, fn(task) { task.state == types.Failed }) {
    True -> types.RunFailed
    False ->
      case
        list.any(tasks, fn(task) {
          task.state == types.Blocked || task.state == types.ManualAttention
        })
      {
        True -> types.RunBlocked
        False -> types.RunCompleted
      }
  }
}

fn recover_task(task: types.Task) -> types.Task {
  case task.state {
    types.Running ->
      case task.worktree_path {
        "" -> types.Task(..task, state: types.Queued)
        _ ->
          case
            git.has_changes(
              task.worktree_path,
              filepath.join(task.worktree_path, ".night-shift-recover.log"),
            )
          {
            True ->
              types.Task(
                ..task,
                state: types.ManualAttention,
                summary: "Interrupted run left changes in the worktree.",
              )
            False -> types.Task(..task, state: types.Queued)
          }
      }
    _ -> task
  }
}

fn build_pr_body(
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

fn bullet_list(items: List(String)) -> String {
  case items {
    [] -> "- None"
    _ ->
      items
      |> list.map(fn(item) { "- " <> item })
      |> string.join(with: "\n")
  }
}

fn review_task_from_pr(pr: github.ReviewWorkItem) -> types.Task {
  let description =
    "Stabilize PR #"
    <> int.to_string(pr.number)
    <> " ("
    <> pr.url
    <> ") by addressing review comments and failing checks.\n\n"
    <> pr.body
    <> "\n\nReview notes:\n"
    <> bullet_list(pr.review_comments)
    <> "\n\nFailing checks:\n"
    <> bullet_list(pr.failing_checks)

  types.Task(
    id: "review-pr-" <> int.to_string(pr.number),
    title: "Stabilize PR #" <> int.to_string(pr.number),
    description: description,
    dependencies: [],
    acceptance: [
      "Resolve requested review feedback when possible.",
      "Leave the PR in a green or clearly blocked state.",
    ],
    demo_plan: ["Summarize the fixes and checks in the PR body."],
    execution_mode: types.Exclusive,
    state: types.Ready,
    worktree_path: "",
    branch_name: pr.head_ref_name,
    pr_number: int.to_string(pr.number),
    summary: "",
  )
}

fn start_task_run(
  run: types.RunRecord,
  task: types.Task,
  worktree_path: String,
  branch_name: String,
  base_ref: String,
  git_log: String,
  env_log: String,
) -> Result(#(types.RunRecord, provider.TaskRun), String) {
  let bootstrap_phase = case task.branch_name {
    "" -> worktree_setup.SetupPhase
    _ -> worktree_setup.MaintenancePhase
  }
  use _ <- result.try(worktree_setup.prepare_worktree(
    run.repo_root,
    run.environment_name,
    project.worktree_setup_path(run.repo_root),
    worktree_path,
    branch_name,
    bootstrap_phase,
    env_log,
  ))
  use env_vars <- result.try(worktree_setup.env_vars_for(
    run.repo_root,
    run.environment_name,
    project.worktree_setup_path(run.repo_root),
  ))
  use start_head <- result.try(git.head_commit(worktree_path, git_log))
  use task_run <- result.try(provider.start_task(
    run.execution_agent,
    run.repo_root,
    run.run_path,
    task,
    worktree_path,
    env_vars,
    start_head,
    branch_name,
    base_ref,
  ))
  Ok(#(run, task_run))
}

fn mark_task_with_event(
  run: types.RunRecord,
  task: types.Task,
  state: types.TaskState,
  summary: String,
  event_kind: String,
) -> Result(types.RunRecord, String) {
  let updated_task = types.Task(..task, state: state, summary: summary)
  let updated_run =
    types.RunRecord(..run, tasks: replace_task(run.tasks, updated_task))
  journal.append_event(
    updated_run,
    types.RunEvent(
      kind: event_kind,
      at: system.timestamp(),
      message: summary,
      task_id: Some(task.id),
    ),
  )
}

fn event_kind_for_state(state: types.TaskState) -> String {
  case state {
    types.ManualAttention -> "task_manual_attention"
    types.Failed -> "task_failed"
    types.Blocked -> "task_blocked"
    _ -> "task_failed"
  }
}

fn build_batch(
  ready_tasks: List(types.Task),
  max_workers: Int,
  acc: List(types.Task),
  has_serial: Bool,
) -> List(types.Task) {
  case ready_tasks, list.length(acc) >= max_workers {
    _, True -> acc
    [], False -> acc
    [task, ..rest], False ->
      case task.execution_mode, acc {
        types.Exclusive, [] -> [task]
        types.Exclusive, _ -> acc
        types.Parallel, _ ->
          build_batch(rest, max_workers, [task, ..acc], has_serial)
        types.Serial, _ ->
          case has_serial {
            True -> acc
            False -> build_batch(rest, max_workers, [task, ..acc], True)
          }
      }
  }
}

fn blocked_run_message(tasks: List(types.Task)) -> String {
  let pr_count =
    tasks
    |> list.filter(fn(task) { task.pr_number != "" })
    |> list.length
  let manual_attention_count =
    tasks
    |> list.filter(fn(task) { task.state == types.ManualAttention })
    |> list.length
  let blocked_count =
    tasks
    |> list.filter(fn(task) { task.state == types.Blocked })
    |> list.length

  "Night Shift opened "
  <> pluralize(pr_count, "PR")
  <> " and is awaiting manual review for "
  <> pluralize(manual_attention_count, "task")
  <> blocked_suffix(blocked_count)
}

fn blocked_suffix(blocked_count: Int) -> String {
  case blocked_count {
    0 -> "."
    _ -> " while " <> pluralize(blocked_count, "task") <> " remain blocked."
  }
}

fn pluralize(count: Int, noun: String) -> String {
  case count == 1 {
    True -> "1 " <> noun
    False -> int.to_string(count) <> " " <> noun <> "s"
  }
}
