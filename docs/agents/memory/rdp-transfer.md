---
name: rdp-transfer
description: RDP Send Files to Server via a shared transfer folder (\tsclient\<letter>), built into 1.3.152 on 2026-11-19, unverified on a real server
metadata:
  type: project
---

Built 2026-11-19 into 1.3.152. Tests: build + filters `rdp`, `splitPicked`, `terminals_import`.
- A profile flag `/transfer:on` (`RdpOptions.transfer`) has a checkbox in the RDP connection window.
- The tab gets `%USERPROFILE%\koreterm-transfer\<profile id>` (`rdp_transfer.folder`) as a drive letter, via `DefineDosDeviceW` in koreterm's logon session (Z down to H).
- The control redirects only that drive: `rdp_pane.redirectDrive`, `IMsRdpClientNonScriptable3.DriveCollection`. Slots were read from mstscax.dll's type library.
- Tab menu: "Send Files to Server..." (copies the files in) and "Open Transfer Folder".

**Why:** the user wants to drop files on a server whose session runs robots, without touching the session, and handle them later.

**How to apply:** verify on a real server that `\tsclient\<letter>` appears. The server's policy may block drive redirection. Also check that the letter shows in this PC's Explorer while the tab is open. Files live on this PC and reach the server only while the tab is connected.
