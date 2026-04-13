import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import night_shift/codec/provider_payload
import night_shift/domain/repo_state
import night_shift/types
import night_shift/worktree_setup

pub fn planner_prompt(
  brief_contents: String,
  decisions: List(types.RecordedDecision),
  completed_tasks: List(types.Task),
  repo_state_snapshot: Option(repo_state.RepoStateSnapshot),
) -> String {
  planner_prompt_with_feedback(
    brief_contents,
    decisions,
    completed_tasks,
    repo_state_snapshot,
    None,
  )
}

pub fn planner_prompt_with_feedback(
  brief_contents: String,
  decisions: List(types.RecordedDecision),
  completed_tasks: List(types.Task),
  repo_state_snapshot: Option(repo_state.RepoStateSnapshot),
  retry_feedback: Option(String),
) -> String {
  "You are Night Shift's planning provider.\n"
  <> "Break the supplied brief into a task DAG.\n"
  <> "Do not write files, apply patches, or make any repository changes.\n"
  <> "Read only the files you need to plan the work.\n"
  <> "Stay strictly within the brief. Do not create adjacent scope.\n"
  <> "Bias toward making a reasonable best-effort decision when the brief allows autonomy or calls the work a first pass.\n"
  <> "Use manual attention only for truly high-impact ambiguity that cannot be resolved from the repository or supplied brief.\n"
  <> "Use the minimum meaningful number of tasks.\n"
  <> "For docs-only or single-file micro changes, prefer one implementation task unless there is a real dependency boundary or a human decision is required.\n"
  <> "Do not emit context-gathering, review-only, or validation-only wrapper tasks for tiny scoped work.\n"
  <> "Return only one JSON object between the exact sentinel markers below.\n"
  <> "Each task must include: id, title, description, dependencies, acceptance, demo_plan, decision_requests, task_kind, execution_mode.\n"
  <> "Use task_kind = manual_attention only when the next step is a human decision or missing product direction. Manual-attention tasks will pause execution before any worktree bootstrap or coding work begins.\n"
  <> "For manual-attention tasks, include decision_requests with stable keys and enough structure for an interactive resolver: key, question, rationale, options, recommended_option, allow_freeform.\n"
  <> "Every manual-attention request must be answerable at runtime: either provide one or more options, or set allow_freeform = true.\n"
  <> "recommended_option is optional guidance and does not require an options list.\n"
  <> "For implementation tasks, set decision_requests to an empty list.\n"
  <> "For implementation tasks, always set superseded_pr_numbers to []. Night Shift derives review-driven PR lineage after planning.\n"
  <> "Use task_kind = implementation for normal coding or research work.\n"
  <> "Use execution_mode = parallel for independent low-conflict work, serial for normal implementation work that may share context, and exclusive only when the task must run alone.\n"
  <> "Dependencies must be task ids only.\n"
  <> "Never use file paths, branch names, acceptance items, or prose as dependency values.\n"
  <> "When a task depends on previously completed work, reference the completed task id exactly.\n"
  <> "Do not re-ask recorded decisions. Treat them as final unless the brief now explicitly conflicts.\n"
  <> "If a previously answered decision still applies after replanning, reuse its decision key verbatim and consume the recorded answer instead of asking again.\n"
  <> "Especially for file-location decisions, carry the accepted target forward directly rather than re-asking with a new key or wording.\n"
  <> "Do not emit tasks whose ids are already completed.\n"
  <> "Use lowercase kebab-case ids.\n"
  <> render_review_planning_guidance(repo_state_snapshot)
  <> render_retry_feedback(retry_feedback)
  <> "\n"
  <> provider_payload.start_marker
  <> "\n"
  <> "{\"tasks\":[{\"id\":\"...\",\"title\":\"...\",\"description\":\"...\",\"dependencies\":[\"...\"],\"acceptance\":[\"...\"],\"demo_plan\":[\"...\"],\"decision_requests\":[],\"superseded_pr_numbers\":[],\"task_kind\":\"implementation\",\"execution_mode\":\"serial\"}]}\n"
  <> provider_payload.end_marker
  <> "\n"
  <> "\n"
  <> "Recorded decisions:\n"
  <> render_recorded_decisions(decisions)
  <> "\n\n"
  <> "Completed tasks to preserve:\n"
  <> render_completed_tasks(completed_tasks)
  <> "\n\n"
  <> "Open PR review context:\n"
  <> render_repo_state_snapshot(repo_state_snapshot)
  <> "\n\n"
  <> "Brief:\n"
  <> brief_contents
}

pub fn planning_document_prompt(
  notes_contents notes_contents: Option(String),
  existing_doc_contents existing_doc_contents: String,
  doc_path doc_path: String,
  repo_state_snapshot repo_state_snapshot: Option(repo_state.RepoStateSnapshot),
) -> String {
  planning_document_prompt_with_feedback(
    notes_contents,
    existing_doc_contents,
    doc_path,
    repo_state_snapshot,
    None,
  )
}

pub fn planning_document_prompt_with_feedback(
  notes_contents notes_contents: Option(String),
  existing_doc_contents existing_doc_contents: String,
  doc_path doc_path: String,
  repo_state_snapshot repo_state_snapshot: Option(repo_state.RepoStateSnapshot),
  retry_feedback retry_feedback: Option(String),
) -> String {
  "You are Night Shift's planning provider.\n"
  <> "Update the repository's cumulative Night Shift brief.\n"
  <> "Do not write files, apply patches, or make any repository changes.\n"
  <> "Read only the files needed to ground the brief.\n"
  <> "Inspect the repository as needed to understand the work being added.\n"
  <> "Preserve valid prior brief content unless the new notes supersede it.\n"
  <> "If the new notes conflict with the prior brief, the new notes win.\n"
  <> "Stay within supplied scope and repository facts. Do not invent adjacent work.\n"
  <> "Return only the full Markdown brief between the exact sentinel markers below.\n"
  <> "Do not return prose outside the sentinel markers.\n"
  <> "The brief will later be passed directly to `night-shift start`.\n"
  <> "Use exactly these top-level sections in order:\n"
  <> "# Night Shift Brief\n"
  <> "## Objective\n"
  <> "## Scope\n"
  <> "## Constraints\n"
  <> "## Deliverables\n"
  <> "## Acceptance Criteria\n"
  <> "## Risks and Open Questions\n"
  <> "\n"
  <> provider_payload.start_marker
  <> "\n"
  <> "# Night Shift Brief\n"
  <> "## Objective\n"
  <> "...\n"
  <> provider_payload.end_marker
  <> "\n"
  <> render_retry_feedback(retry_feedback)
  <> "\n"
  <> "Destination path:\n"
  <> doc_path
  <> "\n"
  <> "\n"
  <> "Existing brief:\n"
  <> case string.trim(existing_doc_contents) {
    "" -> "(none)\n"
    _ -> existing_doc_contents
  }
  <> "\n"
  <> "\n"
  <> "Open PR review context:\n"
  <> render_repo_state_snapshot(repo_state_snapshot)
  <> "\n"
  <> "\n"
  <> "New notes:\n"
  <> render_optional_notes_contents(notes_contents)
}

pub fn execution_prompt(task: types.Task) -> String {
  "You are Night Shift's execution provider.\n"
  <> "Implement the task in the current git worktree.\n"
  <> "Run your own validation before responding.\n"
  <> "Do not exceed the task scope.\n"
  <> "Night Shift already prepared runtime identity artifacts for this worktree. Reuse them instead of inventing ad hoc ports or service names.\n"
  <> "If needed, inspect `NIGHT_SHIFT_RUNTIME_MANIFEST` or `NIGHT_SHIFT_HANDOFF_FILE` for the current runtime contract.\n"
  <> "Return only one JSON object between the exact sentinel markers below.\n"
  <> "The content between the markers must be exactly one valid JSON object with no trailing braces, notes, or extra text.\n"
  <> "Do not include shell transcripts, markdown fences, or explanatory prose inside the JSON payload.\n"
  <> "Status must be one of: completed, blocked, failed, manual_attention.\n"
  <> "Every `files_touched` entry must be a repo-relative path like `src/app.gleam`, never an absolute path.\n"
  <> "Every follow_up_tasks dependency must reference an existing task id or a follow-up task id created in the same follow_up_tasks array.\n"
  <> "Never use file paths, branch names, or acceptance items as follow_up_tasks dependencies.\n"
  <> "The JSON shape is:\n"
  <> provider_payload.start_marker
  <> "\n"
  <> "{\"status\":\"completed\",\"summary\":\"...\",\"files_touched\":[\"...\"],\"demo_evidence\":[\"...\"],\"pr\":{\"title\":\"...\",\"summary\":\"...\",\"demo\":[\"...\"],\"risks\":[\"...\"]},\"follow_up_tasks\":[{\"id\":\"...\",\"title\":\"...\",\"description\":\"...\",\"dependencies\":[\"...\"],\"acceptance\":[\"...\"],\"demo_plan\":[\"...\"],\"decision_requests\":[],\"superseded_pr_numbers\":[1],\"task_kind\":\"implementation\",\"execution_mode\":\"serial\"}]}\n"
  <> provider_payload.end_marker
  <> "\n"
  <> "\n"
  <> "Task:\n"
  <> render_task(task)
}

pub fn worktree_setup_prompt(output_path: String) -> String {
  "You are Night Shift's project setup provider.\n"
  <> "Draft a repo-scoped worktree environment file for Night Shift.\n"
  <> "Inspect the repository to infer likely setup and maintenance commands, but stay conservative.\n"
  <> "Prefer explicit, reproducible commands that prepare a fresh worktree for coding and verification.\n"
  <> "Do not include secrets. Do not write files or execute mutating commands.\n"
  <> "Return only TOML between the exact sentinel markers below.\n"
  <> "The TOML must parse against this v1 schema:\n"
  <> "version = 1\n"
  <> "default_environment = \"default\"\n"
  <> "[environments.<name>.env]\n"
  <> "KEY = \"value\"\n"
  <> "[environments.<name>.preflight]\n"
  <> "default = [\"bootstrap-tool\"]\n"
  <> "macos = []\n"
  <> "linux = []\n"
  <> "windows = []\n"
  <> "[environments.<name>.setup]\n"
  <> "default = [\"...\"]\n"
  <> "macos = []\n"
  <> "linux = []\n"
  <> "windows = []\n"
  <> "[environments.<name>.maintenance]\n"
  <> "default = [\"...\"]\n"
  <> "macos = []\n"
  <> "linux = []\n"
  <> "windows = []\n"
  <> "\n"
  <> "Use the optional preflight section to list only executables that must exist before setup begins.\n"
  <> "Do not list downstream tools that setup is expected to install or activate.\n"
  <> "Examples: corepack-backed pnpm => preflight default = [\"corepack\"]; direct pnpm => [\"pnpm\"]; uv-based Python => [\"uv\"].\n"
  <> "If you are unsure, keep commands empty instead of guessing.\n"
  <> "\n"
  <> provider_payload.start_marker
  <> "\n"
  <> worktree_setup.default_template()
  <> provider_payload.end_marker
  <> "\n\n"
  <> "Destination path:\n"
  <> output_path
}

pub fn repair_prompt(task: types.Task, verification_output: String) -> String {
  execution_prompt(task)
  <> "\n\n"
  <> "Repair this task using the failing verification output below.\n"
  <> verification_output
}

pub fn payload_repair_prompt(task: types.Task, decode_failure: String) -> String {
  "You are Night Shift's execution provider.\n"
  <> "Night Shift captured task worktree changes, but your previous structured execution result was invalid.\n"
  <> "Do not modify files, run mutating commands, apply patches, or change git state.\n"
  <> "Inspect the current worktree only and return one corrected execution JSON object between the exact sentinel markers below.\n"
  <> "The content between the markers must be exactly one valid JSON object with no trailing braces, notes, or extra text.\n"
  <> "Do not include shell transcripts, markdown fences, or explanatory prose inside the JSON payload.\n"
  <> "Status must be one of: completed, blocked, failed, manual_attention.\n"
  <> "Every `files_touched` entry must be a repo-relative path like `src/app.gleam`, never an absolute path.\n"
  <> "Include follow_up_tasks only if they are still warranted by the existing worktree state.\n"
  <> "The JSON shape is:\n"
  <> provider_payload.start_marker
  <> "\n"
  <> "{\"status\":\"completed\",\"summary\":\"...\",\"files_touched\":[\"...\"],\"demo_evidence\":[\"...\"],\"pr\":{\"title\":\"...\",\"summary\":\"...\",\"demo\":[\"...\"],\"risks\":[\"...\"]},\"follow_up_tasks\":[{\"id\":\"...\",\"title\":\"...\",\"description\":\"...\",\"dependencies\":[\"...\"],\"acceptance\":[\"...\"],\"demo_plan\":[\"...\"],\"decision_requests\":[],\"superseded_pr_numbers\":[1],\"task_kind\":\"implementation\",\"execution_mode\":\"serial\"}]}\n"
  <> provider_payload.end_marker
  <> "\n\n"
  <> "Previous decode failure:\n"
  <> decode_failure
  <> "\n\n"
  <> "Task:\n"
  <> render_task(task)
}

fn render_task(task: types.Task) -> String {
  "- ID: "
  <> task.id
  <> "\n- Title: "
  <> task.title
  <> "\n- Description: "
  <> task.description
  <> "\n- Acceptance:\n"
  <> render_lines(task.acceptance)
  <> "\n- Demo plan:\n"
  <> render_lines(task.demo_plan)
  <> "\n- Decision requests:\n"
  <> render_decision_requests(task.decision_requests)
  <> "\n- Supersedes:\n"
  <> render_superseded_pr_numbers(task.superseded_pr_numbers)
  <> render_runtime_context(task.runtime_context)
}

fn render_runtime_context(context: Option(types.RuntimeContext)) -> String {
  case context {
    None -> "\n- Runtime identity:\n  - not prepared yet"
    Some(runtime) ->
      "\n- Runtime identity:\n"
      <> "  - Worktree ID: "
      <> runtime.worktree_id
      <> "\n  - Compose project: "
      <> runtime.compose_project
      <> "\n  - Port base: "
      <> int.to_string(runtime.port_base)
      <> "\n  - Manifest: "
      <> runtime.manifest_path
      <> "\n  - Handoff: "
      <> runtime.handoff_path
      <> render_runtime_ports(runtime.named_ports)
  }
}

fn render_runtime_ports(named_ports: List(types.RuntimePort)) -> String {
  case named_ports {
    [] -> "\n  - Named ports: none"
    _ ->
      "\n  - Named ports:\n"
      <> {
        named_ports
        |> list.map(fn(port) {
          "    - " <> port.name <> ": " <> int.to_string(port.value)
        })
        |> string.join(with: "\n")
      }
  }
}

fn render_lines(lines: List(String)) -> String {
  case lines {
    [] -> "  - None supplied"
    _ ->
      lines
      |> list.map(fn(line) { "  - " <> line })
      |> string.join(with: "\n")
  }
}

fn render_decision_requests(requests: List(types.DecisionRequest)) -> String {
  case requests {
    [] -> "  - None"
    _ ->
      requests
      |> list.map(fn(request) {
        "  - " <> request.key <> ": " <> request.question
      })
      |> string.join(with: "\n")
  }
}

fn render_recorded_decisions(decisions: List(types.RecordedDecision)) -> String {
  case decisions {
    [] -> "(none)"
    _ ->
      decisions
      |> list.map(fn(decision) {
        "- " <> decision.key <> ": " <> decision.answer
      })
      |> string.join(with: "\n")
  }
}

fn render_completed_tasks(tasks: List(types.Task)) -> String {
  case tasks {
    [] -> "(none)"
    _ ->
      tasks
      |> list.map(fn(task) { "- " <> task.id <> ": " <> task.title })
      |> string.join(with: "\n")
  }
}

fn render_repo_state_snapshot(
  repo_state_snapshot: Option(repo_state.RepoStateSnapshot),
) -> String {
  case repo_state_snapshot {
    None -> "(none)"
    Some(snapshot) -> {
      let lines =
        snapshot.open_pull_requests
        |> list.map(fn(pr) {
          "- #"
          <> int.to_string(pr.number)
          <> " "
          <> pr.head_ref_name
          <> " <- "
          <> pr.base_ref_name
          <> " | actionable="
          <> bool_label(pr.actionable)
          <> " | impacted="
          <> bool_label(pr.impacted)
          <> " | decision="
          <> pr.review_decision
          <> " | failing_checks="
          <> render_inline_list(pr.failing_checks)
          <> " | comments="
          <> render_inline_list(pr.review_comments)
        })
      case lines {
        [] -> "(none)"
        _ -> string.join(lines, with: "\n")
      }
    }
  }
}

fn render_optional_notes_contents(notes_contents: Option(String)) -> String {
  case notes_contents {
    Some(contents) -> contents
    None -> "(none)"
  }
}

fn render_superseded_pr_numbers(pr_numbers: List(Int)) -> String {
  case pr_numbers {
    [] -> "  - None"
    _ ->
      pr_numbers
      |> list.map(fn(number) { "  - #" <> int.to_string(number) })
      |> string.join(with: "\n")
  }
}

fn render_inline_list(values: List(String)) -> String {
  case values {
    [] -> "(none)"
    _ -> string.join(values, with: " | ")
  }
}

fn render_review_planning_guidance(
  repo_state_snapshot: Option(repo_state.RepoStateSnapshot),
) -> String {
  case repo_state_snapshot {
    None -> ""
    Some(_) ->
      "When open PR review context is supplied, preserve human-auditable stack boundaries.\n"
      <> "Prefer the smallest successor subtree that resolves the feedback.\n"
      <> "Plan fresh replacement work instead of patching existing PR branches in place.\n"
  }
}

fn bool_label(value: Bool) -> String {
  case value {
    True -> "true"
    False -> "false"
  }
}

fn render_retry_feedback(retry_feedback: Option(String)) -> String {
  case retry_feedback {
    None -> ""
    Some(feedback) -> "\nRetry guidance:\n" <> feedback <> "\n"
  }
}
