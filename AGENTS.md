# Agent Notes

Keep repo-local guidance, workflows, and skills aligned with the actual Night
Shift product behavior.

When Night Shift changes, update the relevant repo guidance in the same change.
In particular:

- If Night Shift CLI flows, repo-state layout, safety rules, delivery behavior,
  or provider assumptions change, update
  `.codex/skills/qa-night-shift/SKILL.md`.
- If the local CLI install or swap workflow changes, update
  `.codex/skills/update-local-night-shift-cli/SKILL.md`.

Prefer small, direct maintenance updates so future agents can trust the repo's
guidance files.
