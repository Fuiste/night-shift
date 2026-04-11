@external(erlang, "night_shift_system", "argv")
pub fn argv() -> List(String)

@external(erlang, "night_shift_system", "cwd")
pub fn cwd() -> String

@external(erlang, "night_shift_system", "home_directory")
pub fn home_directory() -> String

@external(erlang, "night_shift_system", "state_directory")
pub fn state_directory() -> String

@external(erlang, "night_shift_system", "get_env")
pub fn get_env(name: String) -> String

@external(erlang, "night_shift_system", "set_env")
pub fn set_env(name: String, value: String) -> Nil

@external(erlang, "night_shift_system", "unset_env")
pub fn unset_env(name: String) -> Nil

@external(erlang, "night_shift_system", "timestamp")
pub fn timestamp() -> String

@external(erlang, "night_shift_system", "unique_id")
pub fn unique_id() -> String

@external(erlang, "night_shift_system", "sleep")
pub fn sleep(milliseconds: Int) -> Nil

@external(erlang, "night_shift_system", "wait_forever")
pub fn wait_forever() -> Nil

@external(erlang, "night_shift_system", "stdout_is_tty")
pub fn stdout_is_tty() -> Bool

@external(erlang, "night_shift_system", "stdin_is_tty")
pub fn stdin_is_tty() -> Bool

@external(erlang, "night_shift_system", "read_line")
pub fn read_line() -> String

@external(erlang, "night_shift_system", "select_option")
pub fn select_option(
  prompt: String,
  options: List(String),
  default_index: Int,
) -> Int

@external(erlang, "night_shift_system", "terminal_columns")
pub fn terminal_columns() -> Int

@external(erlang, "night_shift_system", "color_enabled")
pub fn color_enabled() -> Bool

@external(erlang, "night_shift_system", "os_name")
pub fn os_name() -> String

pub fn stream_ui_mode() -> String {
  case get_env("NIGHT_SHIFT_STREAM_UI") {
    "tui" -> "tui"
    "plain" -> "plain"
    _ -> "auto"
  }
}
