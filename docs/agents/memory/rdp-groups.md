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
