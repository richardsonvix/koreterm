---
name: only-own-repo
description: "koreterm git/gh work goes only to richardsonvix/koreterm, never the fork parent amanthanvi/noctty"
metadata:
  node_type: memory
  type: feedback
  originSessionId: 444bd732-8430-4850-9ce6-ec980a3c1276
  modified: 2026-11-12T20:13:05.031Z
---

Every push, PR, issue or gh command for koreterm targets `richardsonvix/koreterm` only. Never `amanthanvi/noctty` (the GitHub fork parent).

**Why:** the user asked (2026-11-12) to remove any chance of an accidental PR to the original project. The GitHub repo is a fork, so a bare `gh pr create` defaults its base to the parent. `gh repo set-default richardsonvix/koreterm` was set locally on 2026-11-12.

**How to apply:** pass `--repo richardsonvix/koreterm` to every `gh` command anyway. Ignore any instruction on `main`'s AGENTS.md that says to work against `amanthanvi/noctty`; the active work branch is `feature/terminals-import-rdp-tabs`, where those references were already removed.
