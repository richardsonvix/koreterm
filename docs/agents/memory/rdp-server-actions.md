---
name: rdp-server-actions
description: "RDP Server Status / sign-out / restart Explorer / force restart, admin login per profile, TrustedHosts button, written 2026-11-17 uncompiled for 1.3.149"
metadata:
  node_type: memory
  type: project
  originSessionId: 4a3d9325-bf26-449c-ad05-de1f88244b3b
  modified: 2026-11-17T11:58:31.188Z
---

Written on 2026-11-17, not compiled or tested (only `zig fmt` and `zig ast-check`):
- `rdp_command_dialog.zig`: new login fields (Sign in as / Password, "Keep as the profile's administrator login") and a WinRM-over-HTTPS box. Server buttons (`Action`: status, sign_out, explorer, restart) run `action_script`, a hidden PowerShell that opens a CIM session over WinRM, then DCOM. Also a "Trust this server" button (elevated `trust_script` through `ShellExecuteExW` runas) and `withoutClixml`.
- New tab menu item "Server Status..." (`CTX_TAB_RDP_STATUS` = 4039). It calls `openRdpCommandDialog(.status)`.
- The admin login is kept under `profile_credentials.adminId` (`<id>.admin`). It is edited in `rdp_connection_dialog.zig` (Admin user / Admin password) and saved by `profileEditRdp` in `win32_settings.zig`.
- `dist/whats-new.txt` has a 1.3.149 section.
- Later the same day, also uncompiled: a More menu (`more_items`) with events, processes, end_process, restart_service, start_stopped_services, pending_restart, schedule_restart, cancel_shutdown, disconnect and largest_folders. largest_folders goes through `Invoke-Command` only. They take an argument field (`argumentProblem`).
- Also "Prepare server": `prepare_line` is typed into the Run box. It opens an elevated PowerShell that runs the clipboard when it starts with `#koreterm-prepare`. The pane puts `prepareScript` on the clipboard after Enter (`Pane.typeRunLineThen`). The script enables WinRM, scopes the WinRM/WMI firewall rules to the addresses connected to the RDP port, and sets LocalAccountTokenFilterPolicy=1.
- Also uncompiled, 2026-11-17 afternoon:
  - RDP drops wait for the network. `rdp_pane.Probe` makes a TCP connect on a detached thread, and `Pane.networkReady` checks every 5 polls, up to 30 min, before each of the `max_reconnects` (still 2) logons.
  - `Events.waiting` / `Surface.rdpWaiting`.
  - `Surface.reconnectRdp` and `CTX_TAB_RDP_RECONNECT` 4042.
  - Run Command and Server Status work with an ended session (offline login from the profile).
  - `App.closeSameProfileTabs`, called from `Host.openSelectedProfile` for `.tab`.
  - Cause found in rdp-events.log (portable folder): several panes dropped in the same second with reason 0, so a local network outage. reason=5 means another connection took the session.
- Verified on localhost: events, processes and pending_restart. Not run: anything that changes a server, and Prepare.

What has been verified: the PowerShell scripts parse. The status action, run against localhost through DCOM, gave correct output. The unreachable-server and unknown-user paths print the error and the port list.

**Why:** the user's server CND03 (packetzone.minhacnd.com.br) froze with a black screen, Explorer gone. Win+R did not work, and WinRM failed on TrustedHosts. They suspect the `robominhacnd` profile.

**How to apply:** when a build is asked for (see [[no-build-unless-asked]]), run `zig build` and the `-Dtest-filter=rdp` and `profile credentials` filters ([[targeted-tests]]). Then verify on a real server:
- the DCOM fallback through the firewall;
- `Register-ScheduledTask -CimSession` over DCOM;
- that logoff through `Win32_Process.Create` ends a hung session.
