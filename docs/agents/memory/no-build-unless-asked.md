---
name: no-build-unless-asked
description: "Never compile (zig build, zig build test, packaging) unless the user explicitly asks for it"
metadata:
  node_type: memory
  type: feedback
  originSessionId: 39093662-f6e5-459a-b784-01772057f623
  modified: 2026-11-13T15:05:55.198Z
---

Do not run `zig build`, `zig build test`, or any packaging/compile step unless the user explicitly asks. Cheap checks like `zig fmt` and `zig ast-check` are fine.

**Why:** the user said on 2026-11-13: "memorize que não é para compilar se eu não pedir." They want to review code before any build happens.

**How to apply:** after writing code, stop at fmt/ast-check, say it was not compiled, and wait for the user to ask for a build. This overrides AGENTS.md steps and other memories (e.g. [[rdp-run-command-uncompiled]], [[koreterm-build-env]]) that say to build.
