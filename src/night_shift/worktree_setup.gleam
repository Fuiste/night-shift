import gleam/option.{type Option}
import night_shift/codec/worktree_setup as codec
import night_shift/worktree_setup_model as model
import night_shift/worktree_setup_runtime as runtime

pub type BootstrapPhase =
  model.BootstrapPhase

pub type CommandSet =
  model.CommandSet

pub type WorktreeEnvironment =
  model.WorktreeEnvironment

pub type WorktreeSetupConfig =
  model.WorktreeSetupConfig

pub fn default_config() -> WorktreeSetupConfig {
  model.default_config()
}

pub fn default_template() -> String {
  codec.default_template()
}

pub fn load(path: String) -> Result(Option(WorktreeSetupConfig), String) {
  codec.load(path)
}

pub fn parse(contents: String) -> Result(WorktreeSetupConfig, String) {
  codec.parse(contents)
}

pub fn render(config: WorktreeSetupConfig) -> String {
  codec.render(config)
}

pub fn choose_environment(
  config: Option(WorktreeSetupConfig),
  requested: Option(String),
) -> Result(Option(WorktreeEnvironment), String) {
  codec.choose_environment(config, requested)
}

pub fn find_environment(
  config: WorktreeSetupConfig,
  name: String,
) -> Result(WorktreeEnvironment, String) {
  codec.find_environment(config, name)
}

pub fn commands_for_phase(
  environment: WorktreeEnvironment,
  phase: BootstrapPhase,
) -> List(String) {
  runtime.commands_for_phase(environment, phase)
}

pub fn env_vars_for(
  repo_root: String,
  environment_name: String,
  setup_path: String,
) -> Result(List(#(String, String)), String) {
  runtime.env_vars_for(repo_root, environment_name, setup_path)
}

pub fn prepare_worktree(
  repo_root: String,
  environment_name: String,
  setup_path: String,
  worktree_path: String,
  branch_name: String,
  phase: BootstrapPhase,
  log_path: String,
) -> Result(Nil, String) {
  runtime.prepare_worktree(
    repo_root,
    environment_name,
    setup_path,
    worktree_path,
    branch_name,
    phase,
    log_path,
  )
}

pub fn preflight_environment(
  repo_root: String,
  environment_name: String,
  setup_path: String,
  log_path: String,
) -> Result(Nil, String) {
  runtime.preflight_environment(
    repo_root,
    environment_name,
    setup_path,
    log_path,
  )
}

pub fn empty_command_set() -> CommandSet {
  model.empty_command_set()
}
