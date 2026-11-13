<p align="center">
  <img src="images/koreterm-app-icon.svg" alt="koreterm" width="128" />
</p>

<h1 align="center">koreterm</h1>

<p align="center">
  <strong>A native Windows terminal built on Ghostty's terminal core, with Remote Desktop and SSH connections in its tabs.</strong>
  <br />
  Tabs, splits and session restore · Remote Desktop tabs · Connection profiles · Light on memory · No telemetry
</p>

<p align="center">
  <a href="docs/getting-started.md">Getting started</a>
  ·
  <a href="docs/windows.md">Windows guide</a>
  ·
  <a href="docs/status.md">Status</a>
  ·
  <a href="#build-from-source">Build from source</a>
  ·
  <a href="#thanks">Thanks</a>
</p>

---

koreterm is a Windows terminal that keeps your shells and your remote
connections in one window. It is a fork of
[noctty](https://github.com/amanthanvi/noctty), a native Win32 terminal built
on the terminal core of [Ghostty](https://github.com/ghostty-org/ghostty).
koreterm adds Remote Desktop sessions inside tabs, connection profiles with
saved logins, an import from the Terminals connection manager, and a profile
editor in Settings.

It runs on Windows only. It installs beside your current terminal and does
not replace it.

**Light on your PC.** koreterm is a native Win32 program with no browser
engine inside, so it asks little of your machine while you use it. Measured
on koreterm 1.3.142 (x64) with one Command Prompt tab open and idle: about
55 MB of private memory (about 117 MB working set), and between 0.2% and
2.5% of one CPU core, cursor blink included. The shell and the console host
it starts are separate processes and are not counted.

## Features

### Connections and profiles (added in koreterm)

- **Remote Desktop in a tab.** A profile that runs `mstsc.exe /v:<host>` opens
  the remote desktop inside its tab, named after its connection. It signs in
  with the saved login, or asks through Windows' credential prompt. The
  clipboard works both ways, the session scales to the tab
  (`rdp-scaling`), and <kbd>Ctrl</kbd>+<kbd>Alt</kbd>+<kbd>Home</kbd> gives
  the keyboard back to koreterm.
- **Remote Desktop that stays up.** An idle session sends a keep-alive every
  minute. After a network drop the tab reconnects by itself at most twice,
  15 seconds apart. A failed login is never retried, so a stale saved
  password cannot lock your account.
- **Remote Desktop quality settings** (color depth, compression, experience),
  for all connections in Settings > Shell or for each connection on its own.
  A server whose certificate cannot be checked can be trusted without
  asking, either everywhere or for each connection.
- **Saved logins stay out of the config file.** Passwords go to the Windows
  Credential Manager. A portable copy keeps them instead in DPAPI-encrypted
  files that only your Windows account can read.
- **Import from Terminals.** Settings > Profiles (<kbd>Ctrl</kbd>+<kbd>I</kbd>)
  reads a Terminals favorites XML and lets you tick the connections to bring
  in. SSH connections become `ssh` profiles and RDP connections become
  Remote Desktop profiles. **Export** writes your profiles back as a
  Terminals file. That file holds the passwords in plain text, and the
  export says so.
- **A profile editor.** Settings > Profiles lists one row per profile, and
  <kbd>Enter</kbd> opens its window. A terminal profile has a name, command
  line, starting folder, font size (zoom), tab color, tab icon, "open as
  administrator", environment variables and **notes**. An RDP connection has
  its server, port, user, password and quality.
- **Organizing the profile list.** Move up and Move down set the order of
  the profile menu. **Sort A to Z** lists the profiles alphabetically without
  changing that order. **Hide built-in profiles** lists only the profiles you
  made. Built-in rows have a tinted background, so your own stand apart.
- **Tab colors and icons.** A tab shows its profile's icon: the program's own
  by default, or a `.ico`, `.exe` or `.dll` file, an emoji, or none. The
  profile's color appears as a stripe along the top of the tab.
- **Profiles from tabs.** A tab's menu creates a profile from that tab: its
  command, folder and zoom. A built-in profile can also be the starting
  point for a new one ("New profile based on this one").
- **Open as administrator.** A profile can open as administrator, in its own
  window and in its own starting folder.
- **Backup.** "Back up all settings" writes one ZIP holding the config, the
  state folders (saved logins included) and a Terminals export.
- **Updates from a file, no internet needed.** Put an `update.zip` beside
  `koreterm.exe`. At the next start koreterm shows what is new, and **Update**
  closes it (saving the session), installs the new files and starts it again.
  Your config, logins and session are not in the package. Update checks over
  the internet are off unless you turn them on.
- **Shortcuts.** The window menu (the arrow beside the tabs) can create a
  koreterm shortcut on the Desktop and in the Start menu.

### Windows terminal (from noctty)

- **Native Win32 UI:** a tab bar with overflow, horizontal and vertical
  splits, drag a tab to split, right-click menus, an integrated title bar
  with Snap Layouts on Windows 11, per-monitor DPI scaling, and IME input for
  CJK and other composed text.
- **Your shells, found for you:** PowerShell 7, Windows PowerShell, Command
  Prompt, Git Bash, WSL distributions, Visual Studio developer shells, and
  the hosts in `%USERPROFILE%\.ssh\config`. Each is in the profile menu, the
  command palette and the taskbar jump list.
- **Session restore:** windows, tabs, splits, profiles, working directories
  and titles come back at the next launch. Running programs do not. **Named
  layouts** save a window's tabs and splits for later.
- **Undo:** closing a tab or adding a split can be undone, which brings back
  the exact panes and layout. `clear_screen` and `reset` have their own
  undo.
- **Universal command palette** (<kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>P</kbd>):
  actions, tabs, panes, profiles, layouts, themes, settings and recent
  commands in one fuzzy-searched list.
- **Settings window** (<kbd>Ctrl</kbd>+<kbd>,</kbd>): Appearance, Terminal,
  Shell, Profiles, Privacy, Updates, Keybindings, Advanced and an "All
  settings" reference. Edits wait until you save them, and saving changes
  only the lines it has to in your config file. The window has a live
  theme and opacity preview.
- **Search** (<kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>F</kbd>) through
  scrollback, with regex, case and whole-word modes. Matches are marked on
  the scrollbar.
- **Quick select** (<kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>Space</kbd>) labels
  URLs, paths, git hashes, IP addresses and UUIDs on screen, to copy or open
  from the keyboard. **Copy mode** (<kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>X</kbd>)
  moves through scrollback vi-style.
- **Knowing which tab needs you:** programs that report their status
  ([OSC 7501](docs/windows.md#program-status-osc-7501)) mark their tab as
  working, blocked, done or failed. Notifications and taskbar progress show
  when a background tab needs you. The bell marks its tab.
- **Quick terminal** on a screen edge or in the center, opened by a global
  hotkey.
- **Safe clipboard:** a paste that looks risky is confirmed first, and so is
  a program's clipboard read (OSC 52). Copy keeps HTML and plain text.
  Drag-and-drop works for files, text, URLs and HTML.
- **Renderers:** OpenGL 4.3 by default. Where OpenGL cannot start (often over
  Remote Desktop and in virtual machines), koreterm switches to Direct3D 11
  (beta) and then to Microsoft's WARP software renderer.
- **Accessibility:** UI Automation providers for the terminal text, tabs,
  palette and Settings, and High Contrast support.
- **Automation:** a local command line with JSON state for windows, tabs,
  splits, focus and actions. See [docs/automation.md](docs/automation.md).
- **Diagnostics:** `koreterm --safe-mode` starts with built-in defaults once,
  `koreterm +crash-report` lists local crash dumps, and
  `koreterm +diagnostic-bundle` writes a support bundle without terminal
  content or config values.

### Terminal core (from Ghostty)

- Fast, standards-compliant VT parsing, scrollback and the alternate screen.
- True color, ligatures, grapheme clusters, combining marks and
  bidirectional text.
- Kitty graphics protocol (inline images) and the Kitty keyboard protocol.
- OSC 8 hyperlinks, OSC 52 clipboard, bracketed paste and mouse reporting.
- Shell integration for PowerShell, cmd (with Clink), bash, zsh, fish,
  elvish and nushell, which marks prompts, tracks the working directory and
  reports exit codes.
- Ghostty's config format and hundreds of bundled themes
  (`koreterm +list-themes`), with live reload.

See [docs/status.md](docs/status.md) for what works and what is still
experimental.

## Requirements

Windows 10 version 1809 (build 17763) or later, or Windows 11, on x64 or
ARM64. The default renderer needs a GPU driver with OpenGL 4.3 or later.
Without one, koreterm uses Direct3D 11 or WARP (see above).

## Getting started

No release is published on this repository yet: [build from
source](#build-from-source) for now.

On first launch, koreterm writes a config template to
`%LOCALAPPDATA%\koreterm\config.ghostty`. A portable copy (a
`koreterm.portable` file beside the exe) keeps its data in its own folder
instead. Every default is built in, so the template sets nothing: add only
what you want to change, or press <kbd>Ctrl</kbd>+<kbd>,</kbd> for Settings.

```ini
font-family = JetBrains Mono
font-size = 12
theme = Dracula
```

A few keys to start with:

| Action             | Keys                                                                                          |
| ------------------ | --------------------------------------------------------------------------------------------- |
| Copy / paste       | <kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>C</kbd> / <kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>V</kbd> |
| New tab            | <kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>T</kbd>                                                 |
| Split right        | <kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>\\</kbd>                                                |
| Split down         | <kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>E</kbd>                                                 |
| Move between panes | <kbd>Alt</kbd>+arrow keys                                                                     |
| Command palette    | <kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>P</kbd>                                                 |
| Search             | <kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>F</kbd>                                                 |
| Zoom               | <kbd>Ctrl</kbd>+mouse wheel                                                                   |
| Settings           | <kbd>Ctrl</kbd>+<kbd>,</kbd>                                                                  |
| Reload config      | <kbd>Ctrl</kbd>+<kbd>Shift</kbd>+<kbd>,</kbd>                                                 |

The full list, and how to rebind keys, is in
[docs/getting-started.md](docs/getting-started.md#keybindings).

## Privacy

- **No telemetry.** koreterm does not check for updates over the internet
  unless you set `auto-update`. Updates come from an `update.zip` you place
  beside the exe.
- **Passwords** for saved connections are in the Windows Credential Manager,
  or DPAPI-encrypted in a portable copy, never in the config file. Two things
  hold them in plain text: a Terminals export, and the backup ZIP, which
  includes the saved logins. Keep both somewhere safe.
- **Crash dumps** stay on your PC in `%LOCALAPPDATA%\koreterm\crash` and are
  never uploaded.

See [PRIVACY.md](PRIVACY.md) for what koreterm stores and how to remove it.

## Build from source

You need:

- Zig 0.15.2 (or a later 0.15.x)
- Visual Studio 2022 or later with the MSVC toolchain
- Git for Windows

```powershell
git clone https://github.com/richardsonvix/koreterm.git
cd koreterm
scripts\dev-windows.cmd zig build
```

The app is built to `zig-out\bin\koreterm.exe`, beside Microsoft's pinned
ConPTY pair, which the first build downloads. Tests run with
`zig build test -Demit-test-exe=true --summary all`. If the repository and
Zig's global cache are on different drives, set `ZIG_GLOBAL_CACHE_DIR` to a
folder on the repository's drive first.

To make a portable package and an `update.zip`:

```powershell
pwsh scripts\package-windows.ps1 -Version 1.3.142
pwsh scripts\make-update-zip.ps1 -Version 1.3.142 -NotesFile dist\whats-new.txt
```

[HACKING.md](HACKING.md) covers the dev shell and tests, and
[PACKAGING.md](PACKAGING.md) covers the installer and portable ZIP.

## Thanks

koreterm stands on the work of others:

- **[Ghostty](https://github.com/ghostty-org/ghostty)**, by Mitchell
  Hashimoto and the Ghostty contributors. Ghostty's terminal core, font
  stack, renderer, config and shell integration are the heart of this
  terminal. Thank you for making them open source.
- **[noctty](https://github.com/amanthanvi/noctty)**, by
  [@amanthanvi](https://github.com/amanthanvi). noctty built the native
  Windows app that koreterm is forked from: the Win32 runtime, tabs and
  splits, session restore, the command palette, the Settings window, the
  updater and the Windows packaging. koreterm would not exist without it.
  Thank you.

koreterm is an independent project. It is not affiliated with Ghostty or
noctty, and problems in koreterm should be reported here, not to them.

## License

MIT, the same as Ghostty and noctty. Copyright © 2024 Mitchell Hashimoto and
the Ghostty contributors. The changes made in noctty and in koreterm are
released under the same license. See [LICENSE](LICENSE).
