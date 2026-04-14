//// Public facade for repo-local worktree environment configuration.

import gleam/option.{type Option}
import night_shift/codec/worktree_setup as codec
import night_shift/types
import night_shift/worktree_setup_model as model
import night_shift/worktree_setup_runtime as runtime

/// The bootstrap phases Night Shift can run for an environment.
pub type BootstrapPhase =
  model.BootstrapPhase

/// The command sets available for an environment phase.
pub type CommandSet =
  model.CommandSet

/// A named worktree environment with commands and environment variables.
pub type WorktreeEnvironment =
  model.WorktreeEnvironment

/// Optional runtime aliases configured for one environment.
pub type RuntimeConfig =
  model.RuntimeConfig

/// Full repo-local worktree setup configuration.
pub type WorktreeSetupConfig =
  model.WorktreeSetupConfig

/// Construct the default worktree setup configuration.
pub fn default_config() -> WorktreeSetupConfig {
  model.default_config()
}

/// Render the default template written by setup generation flows.
pub fn default_template() -> String {
  codec.default_template()
}

/// Load and parse a worktree setup file when it exists.
pub fn load(path: String) -> Result(Option(WorktreeSetupConfig), String) {
  codec.load(path)
}

/// Parse worktree setup contents into a typed configuration value.
pub fn parse(contents: String) -> Result(WorktreeSetupConfig, String) {
  codec.parse(contents)
}

/// Render a worktree setup config back to its file format.
pub fn render(config: WorktreeSetupConfig) -> String {
  codec.render(config)
}

/// Select an environment by explicit request or config default.
pub fn choose_environment(
  config: Option(WorktreeSetupConfig),
  requested: Option(String),
) -> Result(Option(WorktreeEnvironment), String) {
  codec.choose_environment(config, requested)
}

/// Look up a named environment in a parsed config.
pub fn find_environment(
  config: WorktreeSetupConfig,
  name: String,
) -> Result(WorktreeEnvironment, String) {
  codec.find_environment(config, name)
}

/// Return the shell commands configured for one environment phase.
pub fn commands_for_phase(
  environment: WorktreeEnvironment,
  phase: BootstrapPhase,
) -> List(String) {
  runtime.commands_for_phase(environment, phase)
}

/// Materialize the environment variables exposed to provider commands.
pub fn env_vars_for(
  repo_root: String,
  environment_name: String,
  setup_path: String,
  runtime_context: Option(types.RuntimeContext),
) -> Result(List(#(String, String)), String) {
  runtime.env_vars_for(repo_root, environment_name, setup_path, runtime_context)
}

/// Execute the commands required to prepare a worktree for one phase.
pub fn prepare_worktree(
  repo_root: String,
  environment_name: String,
  setup_path: String,
  worktree_path: String,
  branch_name: String,
  phase: BootstrapPhase,
  log_path: String,
  runtime_context: Option(types.RuntimeContext),
) -> Result(Nil, String) {
  runtime.prepare_worktree(
    repo_root,
    environment_name,
    setup_path,
    worktree_path,
    branch_name,
    phase,
    log_path,
    runtime_context,
  )
}

/// Run preflight checks for an environment before execution starts.
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

/// Construct an empty command set for callers building configs by hand.
pub fn empty_command_set() -> CommandSet {
  model.empty_command_set()
}
