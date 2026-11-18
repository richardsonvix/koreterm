---
name: rdp-file-export
description: "Export RDP profile to a standard .rdp file (tab menu + Profiles list menu), written 2026-11-18 uncompiled for 1.3.150"
metadata:
  node_type: memory
  type: project
  originSessionId: 7ebf02c6-1b15-4993-b5da-e31be4bb00ae
  modified: 2026-11-18T15:31:02.753Z
---

Written 2026-11-18, not compiled or tested (only `zig fmt` and `zig ast-check`, both clean). Nothing committed.

- New `src/apprt/win32/rdp_file.zig`: `write`, `encode` (UTF-16 LE + BOM, CRLF), `Defaults.of(config)`, `fileName`, `writeFile`, with 5 unit tests (registered in `src/apprt/win32.zig`).
- Tab menu: "Export to Remote Desktop File (.rdp)...", `CTX_TAB_RDP_EXPORT` = 4043, handler `Surface.exportRdpFile` in `terminal_window.zig`.
- Settings Profiles list menu (right click / Shift+F10) on an RDP profile: `profile_menu_export_rdp` = 18, `profileExportRdp`.
- The password is never written (a `.rdp` can only hold it DPAPI-encrypted as `password 51:b:`). The user can ask for that later.
- `dist/whats-new.txt` has a 1.3.150 section.

**How to apply:** when a build is asked for ([[no-build-unless-asked]]), run `zig build` and `-Dtest-filter=rdp_file` ([[targeted-tests]]). Then open an exported file in mstsc.exe and check the server, port, user and colors.

Same day, also uncompiled (fmt + ast-check only), for 1.3.150:
- Per-profile `/reconnect:persistent` (`RdpOptions.persistent_reconnect`, checkbox in `rdp_connection_dialog.zig`). In `rdp_pane.zig`, `afterDrop(DropState)`: bursts of 3, then pauses of 5/15/30/60 min; one try per pause after a refused burst; ends on `endsForGood` reasons. `Pane.isPaused`/`reconnectNow`, `Events.paused`. Tab menu Reconnect shows during a pause.
- A first connection that never came up retries once (`first_retry_done`), skipped when no password is kept. This explains the user's "placeholder text after a failed first connect".
- Session restore: `win32_session_state.Pane.rdp_group` (name, colors, profiles), captured by `sessionRdpGroup` and restored in `restoreSessionPane` via `rdp_group.Start{ .from_saved_line = false }`. Adopted RDP tabs get `launch_profile_key = "user:<id>"` in `adoptRdpPane`.
- Filters to run when a build is asked: `rdp`, `session`, `terminals_import`.
