import filepath
import gleam/string
import night_shift/system

pub fn timestamped_directory(root: String) -> String {
  filepath.join(root, timestamped_id())
}

pub fn timestamped_id() -> String {
  system.timestamp()
  |> string.replace(each: ":", with: "-")
  |> string.replace(each: "T", with: "_")
  |> string.replace(each: "+", with: "_")
  |> string.replace(each: "Z", with: "")
  |> string.append("-")
  |> string.append(system.unique_id())
}
