pub type BootstrapPhase {
  SetupPhase
  MaintenancePhase
}

pub type CommandSet {
  CommandSet(
    default: List(String),
    macos: List(String),
    linux: List(String),
    windows: List(String),
  )
}

pub type RuntimeConfig {
  RuntimeConfig(named_ports: List(String))
}

pub type WorktreeEnvironment {
  WorktreeEnvironment(
    name: String,
    env_vars: List(#(String, String)),
    runtime: RuntimeConfig,
    preflight: CommandSet,
    setup: CommandSet,
    maintenance: CommandSet,
  )
}

pub type WorktreeSetupConfig {
  WorktreeSetupConfig(
    version: Int,
    default_environment: String,
    environments: List(WorktreeEnvironment),
  )
}

pub fn default_config() -> WorktreeSetupConfig {
  WorktreeSetupConfig(version: 1, default_environment: "default", environments: [
    WorktreeEnvironment(
      name: "default",
      env_vars: [],
      runtime: empty_runtime_config(),
      preflight: empty_command_set(),
      setup: empty_command_set(),
      maintenance: empty_command_set(),
    ),
  ])
}

pub fn empty_command_set() -> CommandSet {
  CommandSet(default: [], macos: [], linux: [], windows: [])
}

pub fn empty_runtime_config() -> RuntimeConfig {
  RuntimeConfig(named_ports: [])
}
