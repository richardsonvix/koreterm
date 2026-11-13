---
name: targeted-tests
description: Pick the test scope by how big the change is; run focused -Dtest-filter mini-suites instead of the full suite by default
metadata:
  node_type: memory
  type: feedback
  originSessionId: 39093662-f6e5-459a-b784-01772057f623
  modified: 2026-11-13T16:37:35.608Z
---

Don't run the full suite (`zig build test -Demit-test-exe=true --summary all`) after every change. It takes over 10 minutes here. Scale the test run to the change:
- **UI or dialog code, a few files:** `zig build` first, which catches compile errors. Then run one `-Dtest-filter=<token>` per area touched, such as `settings patch`, `profile dialog`, `rdp`, `ipc`. Read the `N/M tests passed` count: a token that matches nothing still reports about 70 passes.
- **Shared core** (`src/terminal`, `Config.zig` loading, the renderer, `Surface.zig`), or **just before packaging a release:** the full suite.

**Why:** on 2026-11-13 the user said "você precisa otimizar sobre rodar suite de testes, saber qual grau de mudança que precisa realmente rodar a suite inteira de testes ou criar mini suites de testes."

**How to apply:** only test or build when the user asks ([[no-build-unless-asked]]). When reporting, name which filters ran, and say the full suite did not.
