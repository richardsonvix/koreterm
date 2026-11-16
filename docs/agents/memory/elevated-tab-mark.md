---
name: elevated-tab-mark
description: Elevated instance: the shell's "Administrator: " prefix comes off tab labels and the Run as administrator submenu is hidden; no color mark (user declined it). Written 2026-11-16, uncompiled
metadata:
  type: project
---

Written 2026-11-16 and built into 1.3.145 (full suite run: only the known TABGAP crash; a stale new_tab test was fixed).
- `syncTabButtons` strips the shell's "Administrator: " title prefix with `tab_label.withoutAdminPrefix`.
- The overflow menu hides the "Run as administrator" submenu inside an elevated process.
- The window caption keeps its prefix (`allocPrefixedTitle`).

The design the user settled on:
- Admin and non-admin tabs never share a process; mixing them was declined once explained as a UAC bypass.
- "Run as administrator" from a normal instance asks UAC and starts or reuses the elevated instance. The two talk over separate `.medium` and `.elevated` IPC pipes, and NO_WRITE_UP keeps a medium client from driving the elevated one.
- Every tab an elevated instance opens is elevated.

**Why:** the user asked for an amber tab bar and then dropped it, since every tab in an elevated instance is admin anyway.

**How to apply:** do not add a per-tab admin mark, and keep the pipe separation. The tab_label filter covers the prefix test.
