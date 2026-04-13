//// Entry point for the Night Shift CLI.
////
//// Parsing and command execution live in neighboring modules so this file can
//// stay as the small composition root for the executable.

import gleam/io
import night_shift/app
import night_shift/cli
import night_shift/system

/// Parse process arguments and execute the requested command.
pub fn main() -> Nil {
  case cli.parse(system.argv()) {
    Ok(command) -> app.run(command)
    Error(message) -> {
      io.println(message)
      io.println("")
      io.println(cli.usage())
    }
  }
}
