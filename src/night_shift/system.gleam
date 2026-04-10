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

@external(erlang, "night_shift_system", "timestamp")
pub fn timestamp() -> String

@external(erlang, "night_shift_system", "unique_id")
pub fn unique_id() -> String
