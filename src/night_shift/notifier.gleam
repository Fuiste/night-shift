import filepath
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import night_shift/discord
import night_shift/journal
import night_shift/system
import night_shift/types

pub fn notify_run_started(
  config: types.Config,
  run: types.RunRecord,
) -> Result(types.RunRecord, String) {
  notify_event(
    config,
    run,
    types.RunEvent(
      kind: "run_started",
      at: run.created_at,
      message: "Night Shift started.",
      task_id: None,
    ),
  )
}

pub fn append_event(
  config: types.Config,
  run: types.RunRecord,
  event: types.RunEvent,
) -> Result(types.RunRecord, String) {
  use updated_run <- result.try(journal.append_event(run, event))
  notify_event(config, updated_run, event)
}

pub fn mark_status(
  config: types.Config,
  run: types.RunRecord,
  status: types.RunStatus,
  message: String,
) -> Result(types.RunRecord, String) {
  use updated_run <- result.try(journal.mark_status(run, status, message))
  notify_event(
    config,
    updated_run,
    types.RunEvent(
      kind: run_status_event_kind(status),
      at: updated_run.updated_at,
      message: message,
      task_id: None,
    ),
  )
}

fn notify_event(
  config: types.Config,
  run: types.RunRecord,
  event: types.RunEvent,
) -> Result(types.RunRecord, String) {
  case should_send_discord(config, event) {
    False -> Ok(run)
    True -> append_notification_result(run, event, deliver_to_discord(config, run, event))
  }
}

fn should_send_discord(config: types.Config, event: types.RunEvent) -> Bool {
  list.contains(config.notifiers, types.DiscordNotifier) && is_supported_event(event.kind)
}

fn is_supported_event(kind: String) -> Bool {
  case kind {
    "run_started" -> True
    "pr_opened" -> True
    "task_blocked" -> True
    "run_completed" -> True
    "run_blocked" -> True
    "run_failed" -> True
    _ -> False
  }
}

type DeliveryOutcome {
  DeliverySent(String)
  DeliverySkipped(String)
  DeliveryFailed(String)
}

fn deliver_to_discord(
  config: types.Config,
  run: types.RunRecord,
  event: types.RunEvent,
) -> DeliveryOutcome {
  let env_name = config.discord.webhook_url_env
  let webhook_url = system.get_env(env_name)

  case webhook_url {
    "" ->
      DeliverySkipped(
        "Discord notifier skipped for "
        <> event.kind
        <> ": env "
        <> env_name
        <> " is not set.",
      )
    _ -> {
      let log_path = filepath.join(run.run_path, "logs/discord.log")
      case discord.post_message(webhook_url, render_message(run, event), log_path) {
        Ok(_) -> DeliverySent("Discord notification sent for " <> event.kind <> ".")
        Error(message) ->
          DeliveryFailed(
            "Discord notification failed for "
            <> event.kind
            <> ": "
            <> message,
          )
      }
    }
  }
}

fn render_message(run: types.RunRecord, event: types.RunEvent) -> String {
  case event.kind {
    "run_started" ->
      "Night Shift started run `"
      <> run.run_id
      <> "` in `"
      <> run.repo_root
      <> "` using `"
      <> types.harness_to_string(run.harness)
      <> "` with "
      <> int.to_string(run.max_workers)
      <> " worker(s)."
    "pr_opened" -> render_pr_opened_message(run, event)
    "task_blocked" -> render_blocked_message(run, event)
    "run_completed" | "run_blocked" | "run_failed" ->
      "Night Shift finished run `"
      <> run.run_id
      <> "` with status `"
      <> types.run_status_to_string(run.status)
      <> "`.\n"
      <> "Completed tasks: "
      <> int.to_string(completed_task_count(run.tasks))
      <> " | Needs attention: "
      <> int.to_string(attention_task_count(run.tasks))
      <> "\n"
      <> "Report: "
      <> run.report_path
    _ -> "Night Shift update for run `" <> run.run_id <> "`."
  }
}

fn render_pr_opened_message(run: types.RunRecord, event: types.RunEvent) -> String {
  case event.task_id |> task_for_event(run.tasks) {
    Ok(task) ->
      "Night Shift completed `"
      <> task.title
      <> "` in run `"
      <> run.run_id
      <> "`.\n"
      <> "Branch: `"
      <> task.branch_name
      <> "` | PR #"
      <> task.pr_number
      <> "\n"
      <> event.message
    Error(Nil) ->
      "Night Shift opened or updated a PR for run `"
      <> run.run_id
      <> "`.\n"
      <> event.message
  }
}

fn render_blocked_message(run: types.RunRecord, event: types.RunEvent) -> String {
  case event.task_id |> task_for_event(run.tasks) {
    Ok(task) ->
      "Night Shift needs attention on `"
      <> task.title
      <> "` in run `"
      <> run.run_id
      <> "`.\n"
      <> "State: `"
      <> types.task_state_to_string(task.state)
      <> "`\n"
      <> event.message
    Error(Nil) ->
      "Night Shift reported a blocker in run `"
      <> run.run_id
      <> "`.\n"
      <> event.message
  }
}

fn append_notification_result(
  run: types.RunRecord,
  event: types.RunEvent,
  outcome: DeliveryOutcome,
) -> Result(types.RunRecord, String) {
  let meta_event =
    case outcome {
      DeliverySent(message) ->
        types.RunEvent(
          kind: "discord_notification_sent",
          at: system.timestamp(),
          message: message,
          task_id: event.task_id,
        )
      DeliverySkipped(message) ->
        types.RunEvent(
          kind: "discord_notification_skipped",
          at: system.timestamp(),
          message: message,
          task_id: event.task_id,
        )
      DeliveryFailed(message) ->
        types.RunEvent(
          kind: "discord_notification_failed",
          at: system.timestamp(),
          message: message,
          task_id: event.task_id,
        )
    }

  journal.append_event(run, meta_event)
}

fn task_for_event(
  task_id: Option(String),
  tasks: List(types.Task),
) -> Result(types.Task, Nil) {
  case task_id {
    Some(id) -> list.find(tasks, fn(task) { task.id == id })
    None -> Error(Nil)
  }
}

fn completed_task_count(tasks: List(types.Task)) -> Int {
  tasks
  |> list.filter(fn(task) { task.state == types.Completed })
  |> list.length
}

fn attention_task_count(tasks: List(types.Task)) -> Int {
  tasks
  |> list.filter(fn(task) {
    task.state == types.Blocked
    || task.state == types.ManualAttention
    || task.state == types.Failed
  })
  |> list.length
}

fn run_status_event_kind(status: types.RunStatus) -> String {
  case status {
    types.RunPending -> "run_pending"
    types.RunActive -> "run_started"
    types.RunCompleted -> "run_completed"
    types.RunBlocked -> "run_blocked"
    types.RunFailed -> "run_failed"
  }
}
