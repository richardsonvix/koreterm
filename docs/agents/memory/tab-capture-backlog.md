---
name: tab-capture-backlog
description: "Requested 2026-11-13, not started - right-click any tab to screenshot it, record video with start/stop (both saved to Downloads), and fullscreen"
metadata:
  node_type: memory
  type: project
  originSessionId: da8cd5e9-4537-4268-a1e1-03ae6e47f521
  modified: 2026-11-13T13:48:10.449Z
---

The user asked on 2026-11-13 to remember these for later. Not implemented yet.

- **Screenshot of a tab:** for any tab (terminal or Remote Desktop), from the tab's right-click menu. The image is saved to the user's Downloads folder.
- **Video recording of a tab:** with a Start button and a Stop button, from the same menu. The video is saved to Downloads.
- **Fullscreen for any tab:** from the tab's right-click menu.

The tab menu lives in `src/apprt/win32/host.zig` `showTabContextMenu`. The RDP tab's "Run Command" item is next to where these would go (see [[rdp-run-command-uncompiled]]).

**Why:** the user mostly works with Remote Desktop tabs and wants to record what happens in them.

**How to apply:** raise this when the user asks what is pending, or when they next work on the tab menu. Things to settle when it is built:
- An RDP pane is an ActiveX child window, so a capture has to grab the screen area, not the terminal's renderer.
- The video format and encoder (Windows Media Foundation, for example).
- The Downloads folder comes from the `FOLDERID_Downloads` known folder.
