---
name: rdp-groups
description: RDP group grid (watch-only multi-session tab) written 2026-11-13 uncompiled for 1.3.144; detach/dock RDP tabs is the next request
metadata:
  type: project
---

Written on 2026-11-13, not compiled:
- `src/apprt/win32/rdp_group.zig`: a grid window inside a group tab. Each cell has a strip with Interact and Ungroup.
- The CPU sampler raises or lowers `pressure`. `levels` sets the desktop scale and a color cap.
- Saved groups go to `rdp-groups.txt` (`localAppDataPath`).
- A session moves without reconnecting: `rdp_pane.Pane.reparent` and `placeIn`, plus `applyOptions`, which reconnects only for color, compression, experience or audio.
- The surface takes `SurfaceInitOptions.adopt_rdp` or `.rdp_group`.
- Closing a group tab runs `App.closeTabUndoable`, which releases the members first.

Known gaps:
- An adopted RDP tab or a group tab has no launch stamp, so session restore brings it back as a plain terminal. Reopening a saved group is the way back.
- "Close other tabs" and closing the window do not release members; they end those sessions.

**Why:** the user watches several servers at once. They asked that a closed group never close its sessions, and that the load lower itself automatically.

**How to apply:** after building, verify on real sessions:
- `EnableWindow(false)` blocks input but still draws.
- `UpdateSessionDisplaySettings` resizes.
- The Disconnect-then-Connect options reconnect works.

Detach and dock are also written, uncompiled, in the same change:
- `App.detachRdpTab` opens a new window with `adopt_rdp` and sets `Surface.rdp_dock_host`.
- `App.dockRdpTab` / `dockTarget` move the session back.
- The tab hover hint for RDP (`Surface.rdpHint`) shows server:port and user.

2026-11-16, built into 1.3.145: Save Group used `Group.name`, which Rename Tab never changed, and "Group N" restarted at 1 every launch, so a new "Group 1" save replaced an older one. Now `setTabTitleOverride` calls `Group.rename`. A group with a saved line (`Group.saved_as`) rewrites that line on rename (`replaceSaved`'s `old_name`). New names skip saved ones (`defaultName`). Covered by the test "a renamed group's line moves". Still missing: an open group does not come back by itself at the next launch.

2026-11-16, built into 1.3.145: a group no longer resizes the remote desktop. The user reported that asking the server for a cell-sized desktop (`UpdateSessionDisplaySettings`, `Level.scale_pct`) rearranged the windows open on it.
- Members get `Pane.keepDesktop(true)`, with SmartSizing scaling the desktop into the cell, and use `.proportional` scaling.
- A saved group's new member starts at the grid's full size.
- Levels lower colors only.
- `release` turns keepDesktop off, and the adopting tab's `resize` sizes the session again.

2026-11-19, built into 1.3.152 (build + `rdp` filter, 103/104): joining, leaving, a session ending and the CPU load no longer reconnect a session to change its options (`applyLevel` uses `Options.withoutReconnect`; `release` too). Only picking the group's colors from its menu reconnects. **Why:** the user's servers run an agent (FlaUI robots, "CNDSpiderBot") that hands a disconnected RDP session back to the console with tscon at once. Our disconnect-to-reconnect then ended the session with reason 5 (CND03 ended 7 s after leaving a group). `rdp_pane` also waits 3 polls after an options Disconnect and retries an options connect up to 3 times (`options_wait`, `max_options_attempts`). Verify on the real servers.

2026-11-23, built (build + `rdp` filter, 107/108, 1 skipped), not packaged:
- A session joining a group starts in Fit all (`add` and `addNew`). Each cell's strip has a third button, "Fit all" / "Keep size" (`Group.toggleFitAll`). Fit all asks the session for a desktop the size of the grid's monitor (`Pane.setDesktopSize`, which works even with `keep_desktop`), and SmartSizing scales it into the cell. Keep size gives back the size it had before (`Member.kept_w`/`kept_h`).
- **Why:** the user saw windows cut off in a cell and wanted to pick between the desktop's own size and "everything small but visible".
- A watched member no longer keeps the keyboard focus. `Pane.setInteractive(false)` moves focus to the grid first, because a Windows key typed in koreterm opened the remote Start menu (CND03).
- Hover zoom (same day, built, `rdp` filter 108/109): the mouse resting 800 ms on a watched cell's picture opens a popup at 80% of the monitor's work area. The session's control moves into it with `Pane.reparent`, so it stays live, with no reconnect (`Group.openZoom`, `zoomProc`). It closes on a click, Esc, its X or deactivation, and goes back to the cell (`closeZoom`, then `hover_blocked` until the mouse leaves that cell). This works because the grid gets mouse messages over a disabled control. Verify on real sessions.
