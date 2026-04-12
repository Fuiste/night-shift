import gleam/option.{type Option}
import night_shift/infra/run_store
import night_shift/types

pub fn start_run(
  repo_root: String,
  brief_path: String,
  planning_agent: types.ResolvedAgentConfig,
  execution_agent: types.ResolvedAgentConfig,
  environment_name: String,
  max_workers: Int,
) -> Result(types.RunRecord, String) {
  run_store.start_run(
    repo_root,
    brief_path,
    planning_agent,
    execution_agent,
    environment_name,
    max_workers,
  )
}

pub fn create_pending_run(
  repo_root: String,
  brief_path: String,
  planning_agent: types.ResolvedAgentConfig,
  execution_agent: types.ResolvedAgentConfig,
  environment_name: String,
  max_workers: Int,
  notes_source: Option(types.NotesSource),
) -> Result(types.RunRecord, String) {
  run_store.create_pending_run(
    repo_root,
    brief_path,
    planning_agent,
    execution_agent,
    environment_name,
    max_workers,
    notes_source,
  )
}

pub fn activate_run(run: types.RunRecord) -> Result(types.RunRecord, String) {
  run_store.activate_run(run)
}

pub fn rewrite_run(run: types.RunRecord) -> Result(types.RunRecord, String) {
  run_store.rewrite_run(run)
}

pub fn latest_reusable_run(
  repo_root: String,
) -> Result(Option(types.RunRecord), String) {
  run_store.latest_reusable_run(repo_root)
}

pub fn load(
  repo_root: String,
  selector: types.RunSelector,
) -> Result(#(types.RunRecord, List(types.RunEvent)), String) {
  run_store.load(repo_root, selector)
}

pub fn list_runs(repo_root: String) -> Result(List(types.RunRecord), String) {
  run_store.list_runs(repo_root)
}

pub fn save(
  run: types.RunRecord,
  events: List(types.RunEvent),
) -> Result(Nil, String) {
  run_store.save(run, events)
}

pub fn append_event(
  run: types.RunRecord,
  event: types.RunEvent,
) -> Result(types.RunRecord, String) {
  run_store.append_event(run, event)
}

pub fn mark_status(
  run: types.RunRecord,
  status: types.RunStatus,
  message: String,
) -> Result(types.RunRecord, String) {
  run_store.mark_status(run, status, message)
}

pub fn read_report(
  repo_root: String,
  selector: types.RunSelector,
) -> Result(String, String) {
  run_store.read_report(repo_root, selector)
}

pub fn active_run_id(repo_root: String) -> Result(String, String) {
  run_store.active_run_id(repo_root)
}

pub fn state_root() -> String {
  run_store.state_root()
}

pub fn repo_state_path_for(repo_root: String) -> String {
  run_store.repo_state_path_for(repo_root)
}

pub fn planning_root_for(repo_root: String) -> String {
  run_store.planning_root_for(repo_root)
}
