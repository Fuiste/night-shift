import gleam/io
import gleam/option.{type Option, None, Some}
import gleam/string
import night_shift/system

pub fn select_from_labels(
  prompt: String,
  labels: List(String),
  default_index: Int,
) -> Int {
  system.select_option(prompt, labels, default_index)
}

pub fn can_prompt_interactively() -> Bool {
  case system.get_env("NIGHT_SHIFT_ASSUME_TTY") {
    "1" -> True
    _ -> system.stdin_is_tty() && system.stdout_is_tty()
  }
}

pub fn prompt_for_freeform_answer(
  prompt: String,
  key: String,
  default_answer: Option(String),
) -> Result(String, String) {
  case default_answer {
    Some(answer) -> {
      print_prompt(prompt <> " [default: " <> answer <> "]:")
      case string.trim(system.read_line()) {
        "" -> Ok(answer)
        custom -> Ok(custom)
      }
    }
    None -> {
      print_prompt(prompt <> ":")
      case string.trim(system.read_line()) {
        "" -> Error("Night Shift needs a non-empty answer for `" <> key <> "`.")
        answer -> Ok(answer)
      }
    }
  }
}

pub fn recommended_option_index(
  options: List(#(String, String)),
  recommended_option: Option(String),
) -> Int {
  case recommended_option {
    Some(recommended) -> find_option_index(options, recommended, 0)
    None -> 0
  }
}

fn find_option_index(
  options: List(#(String, String)),
  target: String,
  index: Int,
) -> Int {
  case options {
    [] -> 0
    [option, ..rest] ->
      case option.0 == target {
        True -> index
        False -> find_option_index(rest, target, index + 1)
      }
  }
}

fn print_prompt(message: String) -> Nil {
  io.println(message)
}
