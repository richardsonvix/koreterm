---
name: tab-capture-backlog
description: "Tab snapshot (PNG) and recording (MP4, red tab, one at a time) written 2026-11-17 uncompiled for 1.3.149; fullscreen-per-tab still pending"
metadata:
  node_type: memory
  type: project
  originSessionId: 4a3d9325-bf26-449c-ad05-de1f88244b3b
  modified: 2026-11-17T12:20:33.300Z
---

Requested 2026-11-13. Written 2026-11-17, not compiled (only `zig fmt` and `ast-check`):
- `src/apprt/win32/tab_capture.zig` reads the tab's screen area with a BitBlt from the screen DC.
  - Snapshot: a PNG through GDI+, 250 ms after the menu closes.
  - Recording: MP4/H.264 through the Media Foundation sink writer, on its own thread. The UI thread grabs frames from a timer. The writer tries hardware first, then falls back to software.
  - The DLLs are loaded with LoadLibraryExW (Windows N editions lack MF).
- `Surface.snapshotTab` / `toggleTabRecording` / `captureRect` live in `terminal_window.zig`.
  - `captureRect` returns null when the tab is hidden, minimized or covered (`WindowFromPoint` probes). The video then holds its last frame.
  - `tab_capture.forget(self)` in `Surface.destroy` finishes the file.
- Menu items `CTX_TAB_SNAPSHOT` 4040 and `CTX_TAB_RECORD` 4041 are in `host.zig`. The red tab is `recording_tab_bg` in drawButton.
- Config keys `tab-capture-folder` (?[:0]const u8; blank means Downloads) and `tab-capture-quality` (low/normal/high). Both are in Settings > Terminal: a new field Kind `.folder` and a new `OwnedSettingField.tab_capture_folder`.
- The user suggested WebP. Recommended instead: PNG for snapshots and H.264 MP4 for video (WebP has no native Windows encoder, and animated WebP compresses video badly).

Still pending from the original request: **fullscreen for any tab** from its right-click menu.

**How to apply:** at the next build, run the `tab capture`, `settings model` and `settings field` filters ([[targeted-tests]]). Settings has many comptime coverage checks, so expect compile fixes there. Then verify a real recording plays, that the colors and orientation are right (bottom-up RGB32), and that the hardware encoder accepts odd sizes.
