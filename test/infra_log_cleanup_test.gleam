import filepath
import gleam/string
import night_shift/infra/log_cleanup
import night_shift/system
import simplifile

pub fn clean_operator_log_filters_known_noise_and_keeps_raw_copy_test() {
  let unique = system.unique_id()
  let base_dir =
    filepath.join(system.state_directory(), "night-shift-log-clean-" <> unique)
  let log_path = filepath.join(base_dir, "demo.log")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
  let assert Ok(_) = simplifile.create_directory_all(base_dir)
  let assert Ok(_) =
    simplifile.write(
      "[session] demo\n"
        <> "[output] <!DOCTYPE html>\n"
        <> "[output] <html><body>challenge</body></html>\n"
        <> "[output] rmcp::transport::worker failed to connect\n"
        <> "[output] exec_command failed: bootstrap issue\n"
        <> "[assistant] All good now.\n",
      to: log_path,
    )

  let assert Ok(_) = log_cleanup.clean_operator_log(log_path)
  let assert Ok(cleaned) = simplifile.read(log_path)
  let assert Ok(raw) =
    simplifile.read(string.replace(in: log_path, each: ".log", with: ".raw.log"))

  assert string.contains(
    does: cleaned,
    contain: "Suppressed non-fatal harness noise",
  )
  assert string.contains(does: cleaned, contain: "[assistant] All good now.")
  assert !string.contains(does: cleaned, contain: "<!DOCTYPE html>")
  assert string.contains(does: raw, contain: "<!DOCTYPE html>")

  let _ = simplifile.delete(file_or_dir_at: base_dir)
}
