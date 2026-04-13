import gleam/int
import gleam/list
import gleam/order
import gleam/result
import gleam/string
import night_shift/types

pub fn derive_superseded_pr_numbers(
  snapshot: types.RepoStateSnapshot,
  tasks: List(types.Task),
) -> Result(List(types.Task), String) {
  let impacted_prs =
    snapshot.open_pull_requests
    |> list.filter(fn(pr) { pr.impacted })

  case impacted_prs {
    [] -> Ok(tasks)
    _ -> {
      let implementation_tasks =
        tasks
        |> list.filter(fn(task) { task.kind == types.ImplementationTask })

      case implementation_tasks {
        [] ->
          Error(
            "Review-driven replacement planning must produce implementation tasks to replace the impacted PR subtree.",
          )
        _ -> {
          use impacted_layers <- result.try(impacted_pr_layers(impacted_prs))
          use implementation_layers <- result.try(
            implementation_task_layers(implementation_tasks),
          )
          use mappings <- result.try(match_layers(
            impacted_layers,
            implementation_layers,
          ))
          Ok(apply_mappings(tasks, mappings))
        }
      }
    }
  }
}

fn impacted_pr_layers(
  prs: List(types.RepoPullRequestSnapshot),
) -> Result(List(List(types.RepoPullRequestSnapshot)), String) {
  use depth_pairs <- result.try(prs |> list.try_map(fn(pr) {
    impacted_pr_depth(pr, prs, []) |> result.map(fn(depth) { #(depth, pr) })
  }))
  Ok(group_pr_layers(depth_pairs))
}

fn implementation_task_layers(
  tasks: List(types.Task),
) -> Result(List(List(types.Task)), String) {
  use depth_pairs <- result.try(tasks |> list.try_map(fn(task) {
    implementation_task_depth(task, tasks, [])
    |> result.map(fn(depth) { #(depth, task) })
  }))
  Ok(group_task_layers(depth_pairs))
}

fn impacted_pr_depth(
  pr: types.RepoPullRequestSnapshot,
  prs: List(types.RepoPullRequestSnapshot),
  seen_heads: List(String),
) -> Result(Int, String) {
  case list.contains(seen_heads, pr.head_ref_name) {
    True ->
      Error(
        "Night Shift could not derive impacted PR lineage because the review subtree contains a cycle.",
      )
    False ->
      case find_pr_by_head_ref(prs, pr.base_ref_name) {
        Ok(parent) ->
          impacted_pr_depth(parent, prs, [pr.head_ref_name, ..seen_heads])
          |> result.map(fn(depth) { depth + 1 })
        Error(_) -> Ok(0)
      }
  }
}

fn implementation_task_depth(
  task: types.Task,
  tasks: List(types.Task),
  seen_ids: List(String),
) -> Result(Int, String) {
  case list.contains(seen_ids, task.id) {
    True ->
      Error(
        "Night Shift could not derive replacement lineage because the implementation task graph contains a cycle.",
      )
    False -> {
      let parent_tasks = implementation_parent_tasks(task, tasks)
      case parent_tasks {
        [] -> Ok(0)
        _ ->
          parent_tasks
          |> list.try_map(fn(parent) {
            implementation_task_depth(parent, tasks, [task.id, ..seen_ids])
          })
          |> result.map(maximum_depth)
          |> result.map(fn(depth) { depth + 1 })
      }
    }
  }
}

fn match_layers(
  impacted_layers: List(List(types.RepoPullRequestSnapshot)),
  implementation_layers: List(List(types.Task)),
) -> Result(List(#(String, Int)), String) {
  case list.length(impacted_layers) == list.length(implementation_layers) {
    False ->
      Error(
        "Review-driven replacement plan does not match the impacted PR subtree shape. Expected "
        <> render_layer_shape(impacted_layers)
        <> " but got "
        <> render_layer_shape(implementation_layers)
        <> ".",
      )
    True ->
      case list.strict_zip(impacted_layers, implementation_layers) {
        Ok(layer_pairs) -> match_layer_pairs(layer_pairs)
        Error(_) ->
          Error(
            "Review-driven replacement plan does not match the impacted PR subtree shape.",
          )
      }
  }
}

fn match_layer_pairs(
  layer_pairs: List(#(List(types.RepoPullRequestSnapshot), List(types.Task))),
) -> Result(List(#(String, Int)), String) {
  layer_pairs
  |> list.try_fold([], fn(acc, pair) {
    let #(prs, tasks) = pair
    case list.length(prs) == list.length(tasks) {
      False ->
        Error(
          "Review-driven replacement plan does not match the impacted PR subtree shape. Expected "
          <> render_layer_shape_from_counts([list.length(prs)])
          <> " at one layer but got "
          <> render_layer_shape_from_counts([list.length(tasks)])
          <> ".",
        )
      True -> {
        let ordered_prs = prs |> list.sort(fn(left, right) {
          int.compare(left.number, right.number)
        })
        let ordered_tasks = tasks |> list.sort(fn(left, right) {
          string.compare(left.id, right.id)
        })
        let layer_mappings =
          ordered_tasks
          |> list.zip(ordered_prs)
          |> list.map(fn(pair) {
            let #(task, pr) = pair
            #(task.id, pr.number)
          })
        Ok(list.append(acc, layer_mappings))
      }
    }
  })
}

fn group_pr_layers(
  depth_pairs: List(#(Int, types.RepoPullRequestSnapshot)),
) -> List(List(types.RepoPullRequestSnapshot)) {
  depth_pairs
  |> list.sort(fn(left, right) {
    case int.compare(left.0, right.0) {
      order.Eq -> int.compare(left.1.number, right.1.number)
      other -> other
    }
  })
  |> list.fold([], fn(acc, pair) {
    append_pr_to_layer(acc, pair.0, pair.1)
  })
  |> list.reverse
  |> list.map(fn(layer) { list.reverse(layer.1) })
}

fn group_task_layers(
  depth_pairs: List(#(Int, types.Task)),
) -> List(List(types.Task)) {
  depth_pairs
  |> list.sort(fn(left, right) {
    case int.compare(left.0, right.0) {
      order.Eq -> string.compare(left.1.id, right.1.id)
      other -> other
    }
  })
  |> list.fold([], fn(acc, pair) {
    append_task_to_layer(acc, pair.0, pair.1)
  })
  |> list.reverse
  |> list.map(fn(layer) { list.reverse(layer.1) })
}

fn append_pr_to_layer(
  layers: List(#(Int, List(types.RepoPullRequestSnapshot))),
  depth: Int,
  pr: types.RepoPullRequestSnapshot,
) -> List(#(Int, List(types.RepoPullRequestSnapshot))) {
  case layers {
    [] -> [#(depth, [pr])]
    [#(existing_depth, prs), ..rest] ->
      case existing_depth == depth {
        True -> [#(existing_depth, [pr, ..prs]), ..rest]
        False -> [#(existing_depth, prs), ..append_pr_to_layer(rest, depth, pr)]
      }
  }
}

fn append_task_to_layer(
  layers: List(#(Int, List(types.Task))),
  depth: Int,
  task: types.Task,
) -> List(#(Int, List(types.Task))) {
  case layers {
    [] -> [#(depth, [task])]
    [#(existing_depth, tasks), ..rest] ->
      case existing_depth == depth {
        True -> [#(existing_depth, [task, ..tasks]), ..rest]
        False ->
          [#(existing_depth, tasks), ..append_task_to_layer(rest, depth, task)]
      }
  }
}

fn implementation_parent_tasks(
  task: types.Task,
  tasks: List(types.Task),
) -> List(types.Task) {
  task.dependencies
  |> list.fold([], fn(acc, dependency_id) {
    case tasks |> list.find(fn(candidate) { candidate.id == dependency_id }) {
      Ok(parent_task) -> [parent_task, ..acc]
      Error(_) -> acc
    }
  })
  |> list.reverse
}

fn find_pr_by_head_ref(
  prs: List(types.RepoPullRequestSnapshot),
  head_ref_name: String,
) -> Result(types.RepoPullRequestSnapshot, Nil) {
  prs
  |> list.find(fn(pr) { pr.head_ref_name == head_ref_name })
  |> result.map_error(fn(_) { Nil })
}

fn maximum_depth(depths: List(Int)) -> Int {
  case depths {
    [] -> 0
    [first, ..rest] ->
      rest
      |> list.fold(first, fn(acc, depth) {
        case depth > acc {
          True -> depth
          False -> acc
        }
      })
  }
}

fn apply_mappings(
  tasks: List(types.Task),
  mappings: List(#(String, Int)),
) -> List(types.Task) {
  tasks
  |> list.map(fn(task) {
    case mapped_pr_number(mappings, task.id) {
      Ok(pr_number) ->
        types.Task(..task, superseded_pr_numbers: [pr_number])
      Error(_) ->
        case task.kind == types.ImplementationTask {
          True -> types.Task(..task, superseded_pr_numbers: [])
          False -> task
        }
    }
  })
}

fn mapped_pr_number(
  mappings: List(#(String, Int)),
  task_id: String,
) -> Result(Int, Nil) {
  mappings
  |> list.find(fn(mapping) { mapping.0 == task_id })
  |> result.map(fn(mapping) { mapping.1 })
  |> result.map_error(fn(_) { Nil })
}

fn render_layer_shape(layers: List(List(a))) -> String {
  layers
  |> list.map(list.length)
  |> render_layer_shape_from_counts
}

fn render_layer_shape_from_counts(counts: List(Int)) -> String {
  case counts {
    [] -> "[]"
    _ ->
      "["
      <> {
        counts
        |> list.map(int.to_string)
        |> string.join(with: ", ")
      }
      <> "]"
  }
}
