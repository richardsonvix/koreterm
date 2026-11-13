---
name: rdp-run-command-uncompiled
description: "RDP \"Run Command on Remote Desktop\" modal and update.zip cleanup were written 2026-11-13 WITHOUT compiling; build/test and verify before packaging 1.3.143"
metadata:
  node_type: memory
  type: project
  originSessionId: da8cd5e9-4537-4268-a1e1-03ae6e47f521
  modified: 2026-11-13T15:26:53.967Z
---

On 2026-11-13 the user asked for these and said "não é para compilar". Only `zig fmt` and `zig ast-check` were run, both clean. No build, no tests, nothing committed.

- New `src/apprt/win32/rdp_command_dialog.zig`: a modal from the RDP tab's right-click menu ("Run Command on Remote Desktop...", `CTX_TAB_RDP_COMMAND` = 4027 in `consts.zig`, wired in `host.zig` `showTabContextMenu`). The surface entry point is `terminal_window.zig` `openRdpCommandDialog`. It has three modes:
  - Run box: Win+R, paste via the clipboard, Enter.
  - PowerShell window via Win+R.
  - WinRM `Invoke-Command`, run by a hidden powershell.exe with server/user/password/command passed as base64 lines on stdin. This mode is the only one with a real ran/failed result.
- The modal also has preset buttons (Explorer, Processes, Services, Events, Restart) and "Open Task Manager" (Ctrl+Shift+Esc, works without Explorer). A restart or shutdown asks first (`stopsComputer`).
- `rdp_pane.zig`: `typeRunLine`, `openTaskManager`, `sendKeys` through `IMsRdpClientNonScriptable::SendKeys`, a new `Events.sent` callback, and `Pane.server`.
- `local_update.zig`: the update script retries deleting update.zip. A start that finds a package no newer than itself deletes it (`isSpent`).
- `dist/whats-new.txt` already has a 1.3.143 section for these.

**Why:** the user wants to restart Explorer and run tools on remote machines from the tab. They wanted to see this code before any build.

**How to apply:** when the user asks for a build (never on your own, see [[no-build-unless-asked]]), build and run the full suite (`ZIG_GLOBAL_CACHE_DIR` on D:, see [[koreterm-build-env]]) before packaging 1.3.143. Then verify on a real RDP session:
- `SendKeys` is assumed to be vtable slot 14, pinned by a test.
- The Win key is assumed to be scan code 0x15B (0x100 = extended flag).
- Whether SendKeys needs the control focused.
- That the redirected clipboard paste lands in time (900 ms and 500 ms waits).

Also uncompiled and uncommitted (same day, later session), in the working tree:
- `profile-favorite` and `profile-notes`: new list keys, written whole by `settings_patch` as their own blocks, separate from order/hidden.
- The new-tab menu lists only favorites, or all profiles when there are none.
- New `preset_dialog.zig`, plus a Favorite checkbox in the profile window and the RDP window. The RDP window also gained Notes.
- A plain second launch sends an empty toast activation, so the running window comes to the front (`isPlainStartup` in `ipc_server.zig`).
- RDP: `UpdateSessionDisplaySettings` after a resize, through IDispatch `callI4s`. Verify it on a real session.

Only the WinRM mode proves execution. Tell the user this, as was done at handoff.
