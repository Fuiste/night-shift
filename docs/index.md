---
title: Home
description: Night Shift is a repo-local CLI for planning, executing, and reviewing autonomous coding work.
permalink: /
---

# Night Shift

Night Shift is a repo-local CLI for planning, executing, and reviewing
autonomous coding work against a single Git repository.

It keeps the brief, run journal, task graph, and execution artifacts local to
the project, then delegates planning and execution to external providers like
Codex CLI or Cursor Agent.

## Start Here

- [Getting Started]({{ '/getting-started/' | relative_url }})
- [Run Lifecycle]({{ '/run-lifecycle/' | relative_url }})
- [Configuration]({{ '/configuration/' | relative_url }})
- [Worktree Environments]({{ '/worktree-environments/' | relative_url }})
- [State and Artifacts]({{ '/state-and-artifacts/' | relative_url }})
- [Providers and Delivery]({{ '/providers-and-delivery/' | relative_url }})

## Canonical Flow

```sh
night-shift init
night-shift plan --notes notes/today.md
night-shift start
night-shift status
night-shift report
```

Use `resolve` when planning needs human decisions, `resume` when a run was
interrupted, `review` when open Night Shift PRs need stabilization, and
`reset` when you need to eject the repo-local control plane and start over.

## Repository

- [GitHub repository](https://github.com/Fuiste/night-shift)
- [Docs source tree](https://github.com/Fuiste/night-shift/tree/main/docs)
- [Release bundles](https://github.com/Fuiste/night-shift/releases)
