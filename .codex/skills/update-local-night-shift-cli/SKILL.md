---
name: update-local-night-shift-cli
description: Use when the user wants to update or swap their local Night Shift CLI install from the current repo worktree or another audited worktree. Builds the selected worktree, publishes a versioned bundle under ~/.local/share/night-shift, repoints the current symlink, and verifies the local night-shift launcher uses the new install.
---

# Update Local Night Shift CLI

Use this skill when the goal is to make the user's normal `night-shift` command
run the code from a specific worktree.

## What this skill does

- Builds the selected worktree with `gleam build`.
- Creates a versioned install bundle under `~/.local/share/night-shift/<label>`.
- Copies the compiled Erlang package directories from `build/dev/erlang/`.
- Writes stable `entrypoint.sh` and `entrypoint.ps1` launchers into that bundle.
- Repoints `~/.local/share/night-shift/current` to the new bundle.
- Ensures `~/.local/bin/night-shift` exists and launches `current/entrypoint.sh run`.
- Smoke-tests the install through the normal `night-shift` launcher.

## Default behavior

- If the user does not specify a source worktree, use the current repo.
- If the user does not specify a label, derive one from the worktree's short git
  SHA, falling back to the directory name.
- Use the bundled script instead of retyping the copy/symlink steps manually.

## Script

Run:

```sh
.codex/skills/update-local-night-shift-cli/scripts/install_local_cli.sh
```

Useful variants:

```sh
.codex/skills/update-local-night-shift-cli/scripts/install_local_cli.sh --source /path/to/worktree
.codex/skills/update-local-night-shift-cli/scripts/install_local_cli.sh --label ui-pass-2
```

## Verification

After the script finishes:

- Confirm `readlink ~/.local/share/night-shift/current` points at the new bundle.
- Run `night-shift plan` and expect the normal usage error:
  `The plan command requires --notes <path>.`

If the smoke test fails, inspect the bundle layout under
`~/.local/share/night-shift/<label>` before changing anything else.
