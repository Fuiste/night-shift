import filepath
import gleam/list
import gleam/result
import gleam/string
import night_shift/dashboard
import night_shift/journal
import night_shift/orchestrator
import night_shift/shell
import night_shift/system
import night_shift/types
import simplifile

pub fn run(ui_enabled: Bool) -> Result(Nil, String) {
  let unique = system.unique_id()
  let base_dir = filepath.join(system.state_directory(), "night-shift-demo-" <> unique)
  let repo_root = filepath.join(base_dir, "repo")
  let remote_root = filepath.join(base_dir, "remote.git")
  let bin_dir = filepath.join(base_dir, "bin")
  let brief_path = filepath.join(base_dir, "brief.md")
  let fake_harness = filepath.join(bin_dir, "fake-harness")
  let fake_gh = filepath.join(bin_dir, "gh")
  let old_path = system.get_env("PATH")
  let old_fake_harness = system.get_env("NIGHT_SHIFT_FAKE_HARNESS")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
  let _ = simplifile.delete(file_or_dir_at: journal.repo_state_path_for(repo_root))

  let setup_result =
    setup_demo_environment(
      base_dir: base_dir,
      repo_root: repo_root,
      remote_root: remote_root,
      bin_dir: bin_dir,
      brief_path: brief_path,
      fake_harness: fake_harness,
      fake_gh: fake_gh,
    )

  case setup_result {
    Error(message) -> {
      cleanup(base_dir, repo_root)
      Error(message)
    }
    Ok(Nil) -> {
      system.set_env("NIGHT_SHIFT_FAKE_HARNESS", fake_harness)
      system.set_env("PATH", bin_dir <> ":" <> old_path)

      let outcome =
        case ui_enabled {
          True -> run_ui_demo(repo_root, brief_path)
          False -> run_headless_demo(repo_root, brief_path)
        }

      system.set_env("PATH", old_path)
      system.set_env("NIGHT_SHIFT_FAKE_HARNESS", old_fake_harness)
      cleanup(base_dir, repo_root)
      outcome
    }
  }
}

fn run_headless_demo(repo_root: String, brief_path: String) -> Result(Nil, String) {
  let config =
    types.Config(
      ..types.default_config(),
      verification_commands: [],
      max_workers: 1,
    )

  use run <- result.try(journal.start_run(repo_root, brief_path, types.Codex, 1))
  use completed_run <- result.try(orchestrator.start(run, config))
  use #(saved_run, events) <- result.try(journal.load(repo_root, types.LatestRun))
  use report_contents <- result.try(journal.read_report(repo_root, types.LatestRun))

  use _ <- result.try(assert_run_completed(completed_run.status))
  use _ <- result.try(assert_run_completed(saved_run.status))
  use _ <- result.try(assert_true(events != [], "Demo run did not record any events."))
  use _ <- result.try(assert_true(string.contains(does: report_contents, contain: "Night Shift Report"), "Demo report was not rendered."))

  let delivered_task =
    completed_run.tasks
    |> list.find(fn(task) { task.state == types.Completed && task.pr_number == "1" })

  case delivered_task {
    Ok(task) ->
      assert_true(
        string.contains(does: task.summary, contain: "Implemented"),
        "Demo task finished without the expected execution summary.",
      )
    Error(Nil) -> Error("Demo run did not deliver a completed PR-backed task.")
  }
}

fn run_ui_demo(repo_root: String, brief_path: String) -> Result(Nil, String) {
  let config =
    types.Config(
      ..types.default_config(),
      verification_commands: [],
      max_workers: 1,
    )

  use run <- result.try(journal.start_run(repo_root, brief_path, types.Codex, 1))
  use session <- result.try(dashboard.start_start_session(repo_root, run.run_id, run, config))
  let payload = wait_for_run_payload(session.url, run.run_id, 30)
  let _ = dashboard.stop_session(session)

  use _ <- result.try(assert_true(string.contains(does: payload, contain: "\"status\":\"completed\""), "UI demo did not reach a completed run state."))
  use _ <- result.try(assert_true(string.contains(does: payload, contain: "\"pr_number\":\"1\""), "UI demo did not surface the delivered PR in the dashboard payload."))
  Ok(Nil)
}

fn wait_for_run_payload(base_url: String, run_id: String, attempts: Int) -> String {
  let url = base_url <> "/api/runs/" <> run_id
  case attempts {
    value if value <= 0 ->
      dashboard.http_get(url)
      |> result.unwrap(or: "Unable to fetch dashboard payload.")
    _ ->
      case dashboard.http_get(url) {
        Ok(payload) ->
          case string.contains(does: payload, contain: "\"status\":\"completed\"") {
            True -> payload
            False -> {
              system.sleep(150)
              wait_for_run_payload(base_url, run_id, attempts - 1)
            }
          }
        Error(_) -> {
          system.sleep(150)
          wait_for_run_payload(base_url, run_id, attempts - 1)
        }
      }
  }
}

fn assert_run_completed(status: types.RunStatus) -> Result(Nil, String) {
  case status == types.RunCompleted {
    True -> Ok(Nil)
    False -> Error("Demo run did not finish successfully.")
  }
}

fn assert_true(condition: Bool, message: String) -> Result(Nil, String) {
  case condition {
    True -> Ok(Nil)
    False -> Error(message)
  }
}

fn cleanup(base_dir: String, repo_root: String) -> Nil {
  let _ = simplifile.delete(file_or_dir_at: journal.repo_state_path_for(repo_root))
  let _ = simplifile.delete(file_or_dir_at: base_dir)
  Nil
}

fn setup_demo_environment(
  base_dir base_dir: String,
  repo_root repo_root: String,
  remote_root remote_root: String,
  bin_dir bin_dir: String,
  brief_path brief_path: String,
  fake_harness fake_harness: String,
  fake_gh fake_gh: String,
) -> Result(Nil, String) {
  use _ <- result.try(create_directory(base_dir))
  use _ <- result.try(create_directory(bin_dir))
  use _ <- result.try(write_file(brief_path, "# Demo\n"))
  use _ <- result.try(write_fake_harness(fake_harness))
  use _ <- result.try(write_fake_gh(fake_gh))
  use _ <- result.try(run_checked("chmod +x " <> shell.quote(fake_harness) <> " " <> shell.quote(fake_gh), base_dir, filepath.join(base_dir, "chmod.log"), "Unable to make demo fixtures executable."))
  use _ <- result.try(run_checked("git init --bare " <> shell.quote(remote_root), base_dir, filepath.join(base_dir, "remote.log"), "Unable to initialize the demo remote."))
  use _ <- result.try(run_checked("git init --initial-branch=main " <> shell.quote(repo_root), base_dir, filepath.join(base_dir, "repo-init.log"), "Unable to initialize the demo repository."))
  use _ <- result.try(run_checked("git config user.name 'Night Shift Demo'", repo_root, filepath.join(base_dir, "git-user.log"), "Unable to configure the demo git user."))
  use _ <- result.try(run_checked("git config user.email 'night-shift-demo@example.com'", repo_root, filepath.join(base_dir, "git-email.log"), "Unable to configure the demo git email."))
  use _ <- result.try(write_file(filepath.join(repo_root, ".night-shift.toml"), ""))
  use _ <- result.try(write_file(filepath.join(repo_root, "README.md"), "# Demo\n"))
  use _ <- result.try(run_checked("git add README.md .night-shift.toml && git commit -m 'chore: seed demo repo'", repo_root, filepath.join(base_dir, "seed.log"), "Unable to create the demo seed commit."))
  use _ <- result.try(run_checked("git remote add origin " <> shell.quote(remote_root), repo_root, filepath.join(base_dir, "remote-add.log"), "Unable to connect the demo remote."))
  run_checked("git push -u origin main", repo_root, filepath.join(base_dir, "push-main.log"), "Unable to push the demo base branch.")
}

fn create_directory(path: String) -> Result(Nil, String) {
  case simplifile.create_directory_all(path) {
    Ok(Nil) -> Ok(Nil)
    Error(error) -> Error("Unable to create directory " <> path <> ": " <> simplifile.describe_error(error))
  }
}

fn write_file(path: String, contents: String) -> Result(Nil, String) {
  case simplifile.write(contents, to: path) {
    Ok(Nil) -> Ok(Nil)
    Error(error) -> Error("Unable to write " <> path <> ": " <> simplifile.describe_error(error))
  }
}

fn run_checked(
  command: String,
  cwd: String,
  log_path: String,
  error_message: String,
) -> Result(Nil, String) {
  let command_result = shell.run(command, cwd, log_path)
  case shell.succeeded(command_result) {
    True -> Ok(Nil)
    False ->
      Error(
        error_message
        <> " See "
        <> log_path
        <> "."
      )
  }
}

fn write_fake_harness(path: String) -> Result(Nil, String) {
  write_file(
    path,
    "#!/bin/sh\n"
    <> "MODE=$1\n"
    <> "PROMPT_FILE=$2\n"
    <> "if [ \"$MODE\" = \"plan\" ]; then\n"
    <> "  printf 'planning\\nNIGHT_SHIFT_RESULT_START\\n{\"tasks\":[{\"id\":\"demo-task\",\"title\":\"Implement demo task\",\"description\":\"Create a file to prove execution\",\"dependencies\":[],\"acceptance\":[\"Create IMPLEMENTED.md\"],\"demo_plan\":[\"Show the new file\"],\"parallel_safe\":false}]}\\nNIGHT_SHIFT_RESULT_END\\n'\n"
    <> "else\n"
    <> "  echo 'completed by fake harness' > IMPLEMENTED.md\n"
    <> "  printf 'execution\\nNIGHT_SHIFT_RESULT_START\\n{\"status\":\"completed\",\"summary\":\"Implemented demo task\",\"files_touched\":[\"IMPLEMENTED.md\"],\"demo_evidence\":[\"IMPLEMENTED.md created\"],\"pr\":{\"title\":\"[night-shift] Implement demo task\",\"summary\":\"Implemented the fake harness task.\",\"demo\":[\"IMPLEMENTED.md created\"],\"risks\":[]},\"follow_up_tasks\":[]}\\nNIGHT_SHIFT_RESULT_END\\n'\n"
    <> "fi\n",
  )
}

fn write_fake_gh(path: String) -> Result(Nil, String) {
  write_file(
    path,
    "#!/bin/sh\n"
    <> "if [ \"$1\" = \"pr\" ] && [ \"$2\" = \"list\" ]; then\n"
    <> "  BRANCH=$(git rev-parse --abbrev-ref HEAD)\n"
    <> "  printf '[{\"number\":1,\"url\":\"https://example.test/pr/1\",\"headRefName\":\"%s\",\"title\":\"Night Shift PR\"}]\\n' \"$BRANCH\"\n"
    <> "  exit 0\n"
    <> "fi\n"
    <> "if [ \"$1\" = \"pr\" ] && [ \"$2\" = \"edit\" ]; then\n"
    <> "  exit 0\n"
    <> "fi\n"
    <> "if [ \"$1\" = \"pr\" ] && [ \"$2\" = \"create\" ]; then\n"
    <> "  printf 'https://example.test/pr/1\\n'\n"
    <> "  exit 0\n"
    <> "fi\n"
    <> "if [ \"$1\" = \"pr\" ] && [ \"$2\" = \"view\" ]; then\n"
    <> "  BRANCH=$(git rev-parse --abbrev-ref HEAD)\n"
    <> "  printf '{\"number\":1,\"title\":\"Night Shift PR\",\"body\":\"Review body\",\"headRefName\":\"%s\",\"baseRefName\":\"main\",\"url\":\"https://example.test/pr/1\",\"reviewDecision\":\"REVIEW_REQUIRED\",\"statusCheckRollup\":[],\"reviews\":[],\"comments\":[]}' \"$BRANCH\"\n"
    <> "  exit 0\n"
    <> "fi\n"
    <> "printf 'unsupported gh invocation: %s %s\\n' \"$1\" \"$2\" >&2\n"
    <> "exit 1\n",
  )
}
