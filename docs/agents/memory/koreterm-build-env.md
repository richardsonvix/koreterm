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
- TABGAP was fixed on 2026-11-18 (fixture plus accent bar position): it should pass now. A TABGAP failure is real again.
- Since `c5613d499` (2026-11-13, Profiles page) three `win32_settings` tests fail. The page's `btn_profile_sort`/`btn_profile_detected` and two of its texts are never made by `makeAllSections`. The failing tests: "settings fields, labels and help live in a viewport that clips them" (panic), "settings generated form labels immediately precede their controls" (panic), and "settings sections shown in any order leave the window as one made whole at open" (no UIA provider). Found 2026-11-17 and not fixed yet. Adding a Settings row also changes the window counts in "a first visit create each window once" (+2 per row) and "sections shown in any order".
- The flagship contracts fail 6 inherited contracts.
- The user's updates are the update.zip flow:
  1. `pwsh scripts\package-windows.ps1 -Version X`
  2. `pwsh scripts\make-update-zip.ps1 -Version X -NotesFile dist\whats-new.txt`
- The result is `D:\Projetos\koreterm\dist\artifacts\koreterm-X-windows-x64\update.zip`. Bump the version above the last delivered one (1.3.149 was published on the GitHub release channel on 2026-11-17, so the next one is 1.3.150; 1.3.150 was published 2026-11-18, and 1.3.151 the same day, so the next one is 1.3.152; 1.3.152 was built 2026-11-19 and pushed to main unpublished as a release, so the next one is 1.3.153; 1.3.153 was built 2026-11-19, not released, so the next one is 1.3.154).
- The user's repo is richardsonvix/koreterm. `main` is pushed with fast-forwards from the feature branch. See [[only-own-repo]].
- Inno Setup 6.7.3 was installed per user with winget on 2026-11-16 (`%LOCALAPPDATA%\Programs\Inno Setup 6\ISCC.exe`), and package-windows.ps1 finds it, so packaging also builds the setup.
- GitHub channel: `pwsh scripts\publish-update.ps1 -Version X [-Push] [-Draft]` packages the version and publishes release vX on richardsonvix/koreterm with update.zip, update.zip.sha256, the setup and the portable ZIP. koreterm checks `releases/latest` at start (`src/apprt/win32/site_update.zig`). First release v1.3.147 published 2026-11-16 with the user's OK (pushed the branch too). Releases are public: confirm before each publish.
