import gleam/list
import gleam/string
import night_shift/codec/provider_payload
import night_shift/types
import night_shift/worktree_setup

pub fn planner_prompt(
  brief_contents: String,
  decisions: List(types.RecordedDecision),
  completed_tasks: List(types.Task),
) -> String {
  "You are Night Shift's planning provider.\n"
  <> "Break the supplied brief into a task DAG.\n"
  <> "Do not write files, apply patches, or make any repository changes.\n"
  <> "Read only the files you need to plan the work.\n"
  <> "Stay strictly within the brief. Do not create adjacent scope.\n"
  <> "Bias toward making a reasonable best-effort decision when the brief allows autonomy or calls the work a first pass.\n"
  <> "Use manual attention only for truly high-impact ambiguity that cannot be resolved from the repository or supplied brief.\n"
  <> "Return only one JSON object between the exact sentinel markers below.\n"
  <> "Each task must include: id, title, description, dependencies, acceptance, demo_plan, decision_requests, task_kind, execution_mode.\n"
  <> "Use task_kind = manual_attention only when the next step is a human decision or missing product direction. Manual-attention tasks will pause execution before any worktree bootstrap or coding work begins.\n"
  <> "For manual-attention tasks, include decision_requests with stable keys and enough structure for an interactive resolver: key, question, rationale, options, recommended_option, allow_freeform.\n"
  <> "Every manual-attention request must be answerable at runtime: either provide one or more options, or set allow_freeform = true.\n"
  <> "recommended_option is optional guidance and does not require an options list.\n"
  <> "For implementation tasks, set decision_requests to an empty list.\n"
  <> "Use task_kind = implementation for normal coding or research work.\n"
  <> "Use execution_mode = parallel for independent low-conflict work, serial for normal implementation work that may share context, and exclusive only when the task must run alone.\n"
  <> "Dependencies must be task ids only.\n"
  <> "Never use file paths, branch names, acceptance items, or prose as dependency values.\n"
  <> "When a task depends on previously completed work, reference the completed task id exactly.\n"
  <> "Do not re-ask recorded decisions. Treat them as final unless the brief now explicitly conflicts.\n"
  <> "Do not emit tasks whose ids are already completed.\n"
  <> "Use lowercase kebab-case ids.\n"
  <> "\n"
  <> provider_payload.start_marker
  <> "\n"
  <> "{\"tasks\":[...]}\n"
  <> provider_payload.end_marker
  <> "\n"
  <> "\n"
  <> "Recorded decisions:\n"
  <> render_recorded_decisions(decisions)
  <> "\n\n"
  <> "Completed tasks to preserve:\n"
  <> render_completed_tasks(completed_tasks)
  <> "\n\n"
  <> "Brief:\n"
  <> brief_contents
}

pub fn planning_document_prompt(
  notes_contents notes_contents: String,
  existing_doc_contents existing_doc_contents: String,
  doc_path doc_path: String,
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
  <> "New notes:\n"
  <> notes_contents
}

pub fn execution_prompt(task: types.Task) -> String {
  "You are Night Shift's execution provider.\n"
  <> "Implement the task in the current git worktree.\n"
  <> "Run your own validation before responding.\n"
  <> "Do not exceed the task scope.\n"
  <> "Return only one JSON object between the exact sentinel markers below.\n"
  <> "The content between the markers must be exactly one valid JSON object with no trailing braces, notes, or extra text.\n"
  <> "Status must be one of: completed, blocked, failed, manual_attention.\n"
  <> "Every follow_up_tasks dependency must reference an existing task id or a follow-up task id created in the same follow_up_tasks array.\n"
  <> "Never use file paths, branch names, or acceptance items as follow_up_tasks dependencies.\n"
  <> "The JSON shape is:\n"
  <> provider_payload.start_marker
  <> "\n"
  <> "{\"status\":\"completed\",\"summary\":\"...\",\"files_touched\":[\"...\"],\"demo_evidence\":[\"...\"],\"pr\":{\"title\":\"...\",\"summary\":\"...\",\"demo\":[\"...\"],\"risks\":[\"...\"]},\"follow_up_tasks\":[{\"id\":\"...\",\"title\":\"...\",\"description\":\"...\",\"dependencies\":[\"...\"],\"acceptance\":[\"...\"],\"demo_plan\":[\"...\"],\"decision_requests\":[],\"task_kind\":\"implementation\",\"execution_mode\":\"serial\"}]}\n"
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
