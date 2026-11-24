---
name: rdp-clipboard-release
description: An open RDP tab froze pastes in other tabs; rdp_clipboard.zig keeps the session's clipboard only while it has the focus (2026-11-16, built, not verified on a real session)
metadata:
  type: project
---

2026-11-16: the user reported that, with an RDP tab open, PowerShell tabs would not paste (Ctrl+V, the context menu). The user's idea, which was adopted: the session holds the clipboard only while it is in focus.

`src/apprt/win32/rdp_clipboard.zig`:
- `release` runs when a non-RDP pane takes the focus or the app is deactivated. It copies text, DIB, HTML and RTF on a worker thread into a local copy with no owner. Files stay with the session.
- A terminal paste that still finds the session as owner reads on a worker (`readText`, then `WM_WINHOSTTY_CLIPBOARD_TEXT`).

Built, and the `clipboard` test filter passes. In the 1.3.146 update.zip (commit b7b138d29). Not tested on a real RDP session.

**Why:** the hosted RDP control renders delayed clipboard data on koreterm's UI thread.

**How to apply:** if pastes still fail, check whether `sessionOwner` sees the control's clipboard window class (log `win32_rdp_clipboard`). See [[rdp-groups]].

2026-11-24 follow-up (built into 1.3.155, filters pass, not verified on a real session; user reported pastes still failing and `[200~`/`[201~` around pastes in PowerShell):
- A paste whose UI-thread open fails (5 ms) now reads on a worker (`readText`), which waits up to 5 s for a `release` in progress. `release` takes the focused pane's hwnd as the local copy's owner instead of a null owner.
- The prompt integrations (PowerShell, cmd, Clink) now also send `ESC[?2004l`: the fences came from a TUI that left bracketed paste on.
