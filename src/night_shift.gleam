import gleam/io
import night_shift/app
import night_shift/cli
import night_shift/system

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
