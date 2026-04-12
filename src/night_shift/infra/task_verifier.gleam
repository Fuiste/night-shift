import filepath
import gleam/list
import gleam/result
import gleam/string
import night_shift/project
import night_shift/provider
import night_shift/shell
import night_shift/types
import night_shift/worktree_setup

pub type VerifiedExecution {
  VerifiedExecution(
    execution_result: types.ExecutionResult,
    verification_output: String,
  )
}

pub fn verify_completed_task(
  config: types.Config,
  run: types.RunRecord,
  task_run: provider.TaskRun,
  execution_result: types.ExecutionResult,
) -> Result(VerifiedExecution, String) {
  let verification_log =
    filepath.join(run.run_path, "logs/" <> task_run.task.id <> ".verify.log")
  use env_vars <- result.try(worktree_setup.env_vars_for(
    run.repo_root,
    run.environment_name,
    project.worktree_setup_path(run.repo_root),
  ))

  case
    verify_or_repair(
      config,
      run,
      task_run,
      execution_result,
      env_vars,
      verification_log,
    )
  {
    Ok(#(final_execution, verification_output)) ->
      Ok(VerifiedExecution(
        execution_result: final_execution,
        verification_output: verification_output,
      ))
    Error(message) -> Error(message)
  }
}

fn verify_or_repair(
  config: types.Config,
  run: types.RunRecord,
  task_run: provider.TaskRun,
  execution_result: types.ExecutionResult,
  env_vars: List(#(String, String)),
  verification_log: String,
) -> Result(#(types.ExecutionResult, String), String) {
  case
    verify_commands(
      config.verification_commands,
      task_run.worktree_path,
      env_vars,
      verification_log,
    )
  {
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
