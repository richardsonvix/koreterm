---
name: tab-detach-backlog
description: Pending: Detach to New Window / Dock for every tab (WSL, PowerShell...), menu only, build + filtered tests (decided 2026-11-16)
metadata:
  type: project
---

Asked 2026-11-16, paused for the RDP clipboard fix ([[rdp-clipboard-release]]). The user chose:
- Only the tab's right-click menu, with no drag-out.
- Build and filtered tests, this time.

What exists today:
- RDP only: `App.detachRdpTab` and `dockRdpTab` move the control.
- Same-window tab-into-split only: `Host.commitTabDropSplit` and `transfer_subtree`.
- The shell model has no move-tab-between-windows intent. A tab move needs:
  - SetParent of every surface hwnd, with `Surface.host` and `host_id` updated;
  - the search bar, scrollbar and quick-select windows recreated, since they are children of the host;
  - structural undo entries that reference the tab discarded;
  - DPI and opacity refreshed on both hosts;
  - the source window closed if it is left empty.

**Why:** RDP tabs can already move to another monitor, and terminal tabs cannot.
