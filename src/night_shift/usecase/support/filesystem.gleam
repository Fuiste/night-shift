import filepath
import gleam/option.{type Option, None, Some}
import gleam/result
import night_shift/project
import night_shift/system
import night_shift/types
import simplifile

pub fn resolve_doc_path(repo_root: String, doc_path: Option(String)) -> String {
  case doc_path {
    Some(path) -> path
    None -> project.default_brief_path(repo_root)
  }
}

pub fn resolve_notes_source(
  repo_root: String,
  notes_value: String,
) -> Result(types.NotesSource, String) {
  case simplifile.read(notes_value) {
    Ok(_) -> Ok(types.NotesFile(notes_value))
    Error(_) -> {
      let artifact_path =
        filepath.join(project.planning_root(repo_root), system.unique_id())
      let saved_path = filepath.join(artifact_path, "inline-notes.md")
      use _ <- result.try(create_directory(artifact_path))
      use _ <- result.try(write_string(saved_path, notes_value))
      Ok(types.InlineNotes(saved_path))
    }
  }
}

pub fn create_directory(path: String) -> Result(Nil, String) {
  case simplifile.create_directory_all(path) {
    Ok(Nil) -> Ok(Nil)
    Error(error) ->
      Error(
        "Unable to create directory "
        <> path
        <> ": "
        <> simplifile.describe_error(error),
      )
  }
}

pub fn write_string(path: String, contents: String) -> Result(Nil, String) {
  case simplifile.write(contents, to: path) {
    Ok(Nil) -> Ok(Nil)
    Error(error) ->
      Error(
        "Unable to write " <> path <> ": " <> simplifile.describe_error(error),
      )
  }
}
