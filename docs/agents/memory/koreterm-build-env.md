---
name: koreterm-build-env
description: "How builds, tests and packages actually run on this machine (D: repo needs ZIG_GLOBAL_CACHE_DIR on D:, update.zip flow)"
metadata:
  node_type: memory
  type: reference
  originSessionId: da8cd5e9-4537-4268-a1e1-03ae6e47f521
  modified: 2026-11-13T13:48:15.290Z
---

- Run `zig build` and the tests through `D:\Projetos\koreterm\scripts\dev-windows.cmd` with `ZIG_GLOBAL_CACHE_DIR=D:\Temp\zig-global-cache`. With the default cache on C:, the build runner panics in `Run.convertPathArg` (logged in `docs/agents/log/test-harnesses.md`, 2026-11-13).
- A known test failure is not caused by any change: `TABGAP integrated host tabs reach the maximized top and restore exactly`.
- The flagship contracts fail 6 inherited contracts.
- The user's updates are the update.zip flow:
  1. `pwsh scripts\package-windows.ps1 -Version X`
  2. `pwsh scripts\make-update-zip.ps1 -Version X -NotesFile dist\whats-new.txt`
- The result is `D:\Projetos\koreterm\dist\artifacts\koreterm-X-windows-x64\update.zip`. Bump the version above the last delivered one (1.3.148 was published on the GitHub release channel on 2026-11-16, so the next one is 1.3.149).
- The user's repo is richardsonvix/koreterm. `main` is pushed with fast-forwards from the feature branch. See [[only-own-repo]].
- Inno Setup 6.7.3 was installed per user with winget on 2026-11-16 (`%LOCALAPPDATA%\Programs\Inno Setup 6\ISCC.exe`), and package-windows.ps1 finds it, so packaging also builds the setup.
- GitHub channel: `pwsh scripts\publish-update.ps1 -Version X [-Push] [-Draft]` packages the version and publishes release vX on richardsonvix/koreterm with update.zip, update.zip.sha256, the setup and the portable ZIP. koreterm checks `releases/latest` at start (`src/apprt/win32/site_update.zig`). First release v1.3.147 published 2026-11-16 with the user's OK (pushed the branch too). Releases are public: confirm before each publish.
