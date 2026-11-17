//! The modal window behind a Remote Desktop tab's "Run Command on Remote
//! Desktop..." and "Server Status...": a login, a command, how to send it, a
//! few ready-made ones, what runs on the server without its screen, and what
//! came of it.
//!
//! Three ways to send a command:
//! - **Run box**: typed into the remote desktop's Run box (Win+R, paste,
//!   Enter) by the pane (`rdp_pane.Pane.typeRunLine`), on the screen of the
//!   session. The window closes first, so the keys reach the session; the
//!   tab's banner says how it went. koreterm sees only that the keys went:
//!   not whether the program started.
//! - **PowerShell window**: the same, with the command wrapped in
//!   `powershell.exe -NoExit -Command "..."`, so it runs in a PowerShell
//!   window on the remote screen.
//! - **PowerShell on the server (WinRM)**: `Invoke-Command` from this PC
//!   (`remoting_script`), over HTTPS when that box is checked. The window
//!   stays open and shows whether it ran and its output. It runs in a
//!   background session of the server, not on its screen.
//!
//! The Server buttons (`Action`) work when the session's screen does not
//! (Explorer gone, a frozen profile): status (CPU, memory, disks, sessions,
//! the busiest processes), sign a user out, restart Explorer in a user's
//! session, force a restart. They run through the server's management, CIM
//! over WinRM and, when that fails, over DCOM (`action_script`), with the
//! login the window shows: the profile's administrator login when it keeps
//! one (`profile_credentials.adminId`). When the server cannot be reached,
//! the result lists which of its ports answer.
//!
//! "Trust this server" adds it to this PC's WinRM TrustedHosts, through an
//! elevated PowerShell (`trust_script`), which a server outside the domain,
//! or named by its address, needs for WinRM over HTTP.
//!
//! "Open Task Manager" sends Ctrl+Shift+Esc, which works when Explorer, and
//! with it the Run box, is gone. A command that restarts or shuts down the
//! computer (`stopsComputer`), a sign-out and a forced restart are asked
//! about first.
//!
//! Nothing here logs a command, a server, a user name or a password. A
//! password reaches PowerShell through its standard input, never its command
//! line.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const win32_types = @import("../win32_types.zig");
const profile_credentials = @import("profile_credentials.zig");

const BOOL = win32_types.BOOL;
const HINSTANCE = win32_types.HINSTANCE;
const HWND = win32_types.HWND;
const LPARAM = win32_types.LPARAM;
const LPCWSTR = win32_types.LPCWSTR;
const LRESULT = win32_types.LRESULT;
const UINT = win32_types.UINT;
const WPARAM = win32_types.WPARAM;

const L = std.unicode.utf8ToUtf16LeStringLiteral;

/// The connection the window works on. Copies the caller owns for the whole
/// call: the window's message loop can end the session and free the pane.
pub const Remote = struct {
    /// The server, without its port.
    server: []const u8,
    /// The login the session signs in with.
    user: []const u8 = "",
    password: ?[]const u8 = null,
    /// The tab's name, for the window's title.
    title: []const u8 = "",
    /// The profile's administrator login, when it keeps one.
    admin_user: []const u8 = "",
    admin_password: ?[]const u8 = null,
    /// The profile the connection is, which can keep an administrator login.
    profile_id: ?[]const u8 = null,
    /// The Remote Desktop port (Prepare server finds this PC's address on
    /// the server by the connection to it).
    port: u16 = 3389,
};

/// What the window does once open: wait for a command, or show the
/// server's status straight away.
pub const Start = enum { command, status };

/// What the caller sends into the session once the window has closed.
pub const Request = union(enum) {
    none,
    /// A line for the remote Run box, in the `alloc` given to `run`.
    run_line: []const u8,
    /// Ctrl+Shift+Esc.
    task_manager,
    /// Prepare server: `line` typed into the Run box, then `clipboard` put
    /// on the clipboard for the elevated PowerShell it opens to run
    /// (`prepareLine`, `prepareScript`). Both in the `alloc` given to `run`.
    prepare: struct { line: []const u8, clipboard: []const u8 },
};

/// The Run box takes a line of up to 259 characters.
pub const run_box_max_len: usize = 259;
/// What a WinRM command may hold, and what of its output is kept.
const remoting_command_max_len: usize = 16 * 1024;
const output_max_len: usize = 64 * 1024;
/// How long a WinRM command, or a Server button, may take before the window
/// stops it.
const remoting_timeout_ms: i64 = 120 * std.time.ms_per_s;
const action_timeout_ms: i64 = 240 * std.time.ms_per_s;

pub const Mode = enum { run_box, powershell_window, remoting };

/// The Server buttons, then the More menu's. Their tag names are what
/// `action_script` reads.
pub const Action = enum {
    status,
    sign_out,
    explorer,
    restart,
    events,
    processes,
    end_process,
    restart_service,
    start_stopped_services,
    pending_restart,
    schedule_restart,
    cancel_shutdown,
    disconnect,
    largest_folders,

    /// The ones with a button of their own; the rest are in More.
    const buttons = 4;

    /// Whether it needs the name of the user whose session it acts on.
    fn needsSessionUser(self: Action) bool {
        return self == .sign_out or self == .explorer or self == .disconnect;
    }

    fn title(self: Action) []const u8 {
        return switch (self) {
            .status => "Status",
            .sign_out => "Sign out",
            .explorer => "Restart Explorer",
            .restart => "Forced restart",
            .events => "Critical events",
            .processes => "Processes",
            .end_process => "End process",
            .restart_service => "Restart service",
            .start_stopped_services => "Start stopped services",
            .pending_restart => "Pending restart",
            .schedule_restart => "Scheduled restart",
            .cancel_shutdown => "Cancel scheduled restart",
            .disconnect => "Disconnect session",
            .largest_folders => "Largest folders",
        };
    }
};

/// The More menu: an action, or Prepare server.
const MoreItem = struct { label: []const u16, pick: ?Action };
const more_items = more: {
    // Its labels are UTF-16 literals made at compile time.
    @setEvalBranchQuota(40000);
    break :more [_]MoreItem{
        .{ .label = L("Critical events (last 48 hours)"), .pick = .events },
        .{ .label = L("Processes (most CPU and memory)"), .pick = .processes },
        .{ .label = L("End process (PID in the field)..."), .pick = .end_process },
        .{ .label = L("Restart service (name in the field)..."), .pick = .restart_service },
        .{ .label = L("Start stopped automatic services..."), .pick = .start_stopped_services },
        .{ .label = L("Pending restart (Windows Update)?"), .pick = .pending_restart },
        .{ .label = L("Schedule restart (HH:MM in the field)..."), .pick = .schedule_restart },
        .{ .label = L("Cancel scheduled restart"), .pick = .cancel_shutdown },
        .{ .label = L("Disconnect session (keeps its programs)"), .pick = .disconnect },
        .{ .label = L("Largest folders (folder in the field, C:\\ by default)"), .pick = .largest_folders },
        .{ .label = L("Prepare server for remote management (through the session)..."), .pick = null },
    };
};
const more_first_id: usize = 2000;

/// What the field beside Session user must hold for `action`, checked
/// before it runs: null when it fits, else what to say.
pub fn argumentProblem(action: Action, argument: []const u8) ?[]const u8 {
    switch (action) {
        .end_process => {
            _ = std.fmt.parseInt(u32, argument, 10) catch return "Type the process's PID (a number; Processes lists them) in the field.";
        },
        .restart_service => {
            if (argument.len == 0 or argument.len > 256) return "Type the service's name (as in services.msc, such as Spooler) in the field.";
            for (argument) |byte| switch (byte) {
                'a'...'z', 'A'...'Z', '0'...'9', '_', '-', '.', '$', ' ', '(', ')' => {},
                else => return "A service name holds letters, digits, spaces and _ - . $ ( ) only.",
            };
        },
        .schedule_restart => {
            _ = parseTime(argument) orelse return "Type the time as HH:MM (24 hours, the server's clock) in the field.";
        },
        .largest_folders => {
            if (argument.len > 240) return "The folder is too long.";
        },
        else => {},
    }
    return null;
}

/// `HH:MM` on a 24-hour clock.
pub fn parseTime(text: []const u8) ?struct { hour: u8, minute: u8 } {
    const colon = std.mem.indexOfScalar(u8, text, ':') orelse return null;
    const hour = std.fmt.parseInt(u8, text[0..colon], 10) catch return null;
    const minute = std.fmt.parseInt(u8, text[colon + 1 ..], 10) catch return null;
    if (colon == 0 or colon > 2 or text.len - colon - 1 != 2 or hour > 23 or minute > 59) return null;
    return .{ .hour = hour, .minute = minute };
}

/// The ready-made commands: what each button puts in the Command field, by
/// mode.
const Preset = enum {
    explorer,
    processes,
    services,
    events,
    restart,

    fn command(self: Preset, mode: Mode) []const u8 {
        return switch (self) {
            .explorer => switch (mode) {
                .run_box => "explorer.exe",
                .powershell_window => "Start-Process explorer.exe",
                // Windows starts the shell again after it ends.
                .remoting => "Stop-Process -Name explorer -Force",
            },
            .processes => switch (mode) {
                .run_box => "taskmgr.exe",
                else => "Get-Process | Sort-Object CPU -Descending | Select-Object -First 15 Name, Id, CPU, WS",
            },
            .services => switch (mode) {
                .run_box => "services.msc",
                else => "Get-Service | Where-Object StartType -eq 'Automatic' | Where-Object Status -ne 'Running' | Select-Object Name, Status, DisplayName",
            },
            .events => switch (mode) {
                .run_box => "eventvwr.msc",
                else => "Get-WinEvent -LogName System -MaxEvents 15 | Select-Object TimeCreated, Id, LevelDisplayName, Message | Format-List",
            },
            .restart => switch (mode) {
                .run_box => "shutdown.exe /r /t 0",
                else => "Restart-Computer -Force",
            },
        };
    }
};

const intro_text = intro: {
    // A long UTF-16 literal made at compile time.
    @setEvalBranchQuota(10000);
    break :intro L("Run box and PowerShell window type the command into the session's screen (Win+R): koreterm sees only that the keys went. PowerShell on the server, and the Server buttons, go through the server's management (WinRM, or WMI over DCOM), not its screen, and show the result. They need an administrator of the server.");
};

const IDOK: u16 = 1;
const IDCANCEL: u16 = 2;
const id_mode_run: u16 = 140;
const id_mode_window: u16 = 141;
const id_mode_remoting: u16 = 142;
const id_command: u16 = 143;
const id_output: u16 = 144;
const id_task_manager: u16 = 145;
const id_user: u16 = 146;
const id_password: u16 = 147;
const id_keep_admin: u16 = 148;
const id_https: u16 = 149;
const id_preset_first: u16 = 150; // + @intFromEnum(Preset)
const id_session_user: u16 = 160;
const id_login_note: u16 = 161;
const id_trust: u16 = 162;
const id_argument: u16 = 163;
const id_more: u16 = 164;
const id_action_first: u16 = 170; // + @intFromEnum(Action)
const job_timer: usize = 0x524A; // "RJ"

const DWLP_USER: i32 = @sizeOf(usize) * 2;
const WM_INITDIALOG: UINT = 0x0110;
const WM_COMMAND: UINT = 0x0111;
const WM_CLOSE: UINT = 0x0010;
const WM_TIMER: UINT = 0x0113;
const BN_CLICKED: u16 = 0;
const BST_CHECKED: u32 = 1;
const BM_SETCHECK: UINT = 0x00F1;
const EM_LIMITTEXT: UINT = 0x00C5;

extern "user32" fn DialogBoxIndirectParamW(hInstance: ?HINSTANCE, template: *const anyopaque, parent: ?HWND, proc: *const fn (HWND, UINT, WPARAM, LPARAM) callconv(.winapi) isize, init: LPARAM) callconv(.winapi) isize;
extern "user32" fn EndDialog(hDlg: HWND, result: isize) callconv(.winapi) BOOL;
extern "user32" fn GetDlgItem(hDlg: HWND, id: i32) callconv(.winapi) ?HWND;
extern "user32" fn SetWindowLongPtrW(hWnd: HWND, index: i32, value: isize) callconv(.winapi) isize;
extern "user32" fn GetWindowLongPtrW(hWnd: HWND, index: i32) callconv(.winapi) isize;
extern "user32" fn SetWindowTextW(hWnd: HWND, text: LPCWSTR) callconv(.winapi) BOOL;
extern "user32" fn GetWindowTextW(hWnd: HWND, text: [*]u16, max: i32) callconv(.winapi) i32;
extern "user32" fn GetWindowTextLengthW(hWnd: HWND) callconv(.winapi) i32;
extern "user32" fn MessageBoxW(hwnd: ?HWND, text: [*:0]const u16, caption: [*:0]const u16, kind: u32) callconv(.winapi) i32;
extern "user32" fn SetFocus(hWnd: HWND) callconv(.winapi) ?HWND;
extern "user32" fn EnableWindow(hWnd: HWND, enable: BOOL) callconv(.winapi) BOOL;
extern "user32" fn CheckRadioButton(hDlg: HWND, first: i32, last: i32, check: i32) callconv(.winapi) BOOL;
extern "user32" fn IsDlgButtonChecked(hDlg: HWND, id: i32) callconv(.winapi) u32;
extern "user32" fn SendMessageW(hWnd: HWND, msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT;
extern "user32" fn SetTimer(hwnd: ?HWND, id: usize, ms: u32, proc: ?*const anyopaque) callconv(.winapi) usize;
extern "user32" fn KillTimer(hwnd: ?HWND, id: usize) callconv(.winapi) BOOL;
extern "kernel32" fn GetModuleHandleW(name: ?LPCWSTR) callconv(.winapi) ?HINSTANCE;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;

/// What the running job is: a WinRM command, or a Server button.
const JobKind = union(enum) {
    command,
    action: Action,
};

const State = struct {
    alloc: Allocator,
    remote: Remote,
    title: [:0]const u16,
    start: Start = .command,
    request: Request = .none,
    job: ?Job = null,
    job_kind: JobKind = .command,
    /// The elevated PowerShell that adds the server to TrustedHosts.
    trust: ?HANDLE = null,
    output: std.ArrayListUnmanaged(u8) = .empty,
};

/// Show the window over `owner` until it is closed. What it returns, the
/// caller sends into the session (`Request`); a WinRM command or a Server
/// button has already run by then.
pub fn run(alloc: Allocator, owner: ?HWND, remote: Remote, start: Start) Allocator.Error!Request {
    const template = try buildTemplate(alloc);
    defer alloc.free(template);
    const shown = if (remote.title.len != 0) remote.title else remote.server;
    const title_text = try std.fmt.allocPrint(alloc, "Remote commands: {s}", .{shown});
    defer alloc.free(title_text);
    // The server name came through the config, so it is valid UTF-8.
    const title = std.unicode.utf8ToUtf16LeAllocZ(alloc, title_text) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidUtf8 => try alloc.dupeZ(u16, std.unicode.utf8ToUtf16LeStringLiteral("Remote commands")),
    };
    defer alloc.free(title);
    var state: State = .{ .alloc = alloc, .remote = remote, .title = title, .start = start };
    defer state.output.deinit(alloc);
    _ = DialogBoxIndirectParamW(GetModuleHandleW(null), template.ptr, owner, dialogProc, @bitCast(@intFromPtr(&state)));
    // A job the window's close did not stop (it always does): stopped here.
    if (state.job) |job| job.stop();
    if (state.trust) |process| _ = CloseHandle(process);
    return state.request;
}

// --- The template --------------------------------------------------------

const Template = struct {
    bytes: std.ArrayListUnmanaged(u8) = .empty,
    alloc: Allocator,
    items: u16 = 0,

    fn int(self: *Template, comptime I: type, value: I) Allocator.Error!void {
        var buf: [@sizeOf(I)]u8 = undefined;
        std.mem.writeInt(I, &buf, value, .little);
        try self.bytes.appendSlice(self.alloc, &buf);
    }
    fn wstr(self: *Template, text: []const u16) Allocator.Error!void {
        for (text) |unit| try self.int(u16, unit);
        try self.int(u16, 0);
    }
    fn item(self: *Template, style: u32, x: i16, y: i16, cx: i16, cy: i16, id: u16, atom: u16, title: []const u16) Allocator.Error!void {
        while (self.bytes.items.len % 4 != 0) try self.bytes.append(self.alloc, 0);
        try self.int(u32, style);
        try self.int(u32, 0);
        try self.int(i16, x);
        try self.int(i16, y);
        try self.int(i16, cx);
        try self.int(i16, cy);
        try self.int(u16, id);
        try self.int(u16, 0xFFFF);
        try self.int(u16, atom);
        try self.wstr(title);
        try self.int(u16, 0);
        self.items += 1;
    }
};

const preset_labels = [_][]const u16{ L("&Explorer"), L("&Processes"), L("Se&rvices"), L("E&vents"), L("Re&start...") };
const action_labels = [_][]const u16{ L("Server st&atus"), L("Sign &out user..."), L("Restart E&xplorer"), L("&Force restart...") };

fn buildTemplate(alloc: Allocator) Allocator.Error![]align(4) u8 {
    // Its labels are UTF-16 literals made at compile time.
    @setEvalBranchQuota(40000);
    var t: Template = .{ .alloc = alloc };
    defer t.bytes.deinit(alloc);
    const WS_CHILD: u32 = 0x40000000;
    const WS_VISIBLE: u32 = 0x10000000;
    const WS_TABSTOP: u32 = 0x00010000;
    const WS_GROUP: u32 = 0x00020000;
    const WS_BORDER: u32 = 0x00800000;
    const WS_VSCROLL: u32 = 0x00200000;
    const child = WS_CHILD | WS_VISIBLE;
    const ES_AUTOHSCROLL: u32 = 0x80;
    const ES_AUTOVSCROLL: u32 = 0x40;
    const ES_MULTILINE: u32 = 0x4;
    const ES_READONLY: u32 = 0x800;
    const ES_PASSWORD: u32 = 0x20;
    const BS_AUTOCHECKBOX: u32 = 0x3;
    const BS_AUTORADIOBUTTON: u32 = 0x9;
    const BS_DEFPUSHBUTTON: u32 = 0x1;
    const BS_GROUPBOX: u32 = 0x7;
    const button: u16 = 0x0080;
    const edit_atom: u16 = 0x0081;
    const static: u16 = 0x0082;
    const field = child | WS_TABSTOP | WS_GROUP | WS_BORDER | ES_AUTOHSCROLL;

    const w: i16 = 360;
    const h: i16 = 440;
    const inner: i16 = w - 14;
    // The header; its item count is written once the items are made.
    try t.int(u32, 0x80000000 | 0x00C00000 | 0x00080000 | 0x80 | 0x40 | 0x800);
    try t.int(u32, 0);
    try t.int(u16, 0);
    try t.int(i16, 0);
    try t.int(i16, 0);
    try t.int(i16, w);
    try t.int(i16, h);
    try t.int(u16, 0);
    try t.int(u16, 0);
    try t.wstr(L("Remote commands"));
    try t.int(u16, 9);
    try t.wstr(L("Segoe UI"));

    var y: i16 = 7;
    try t.item(child, 7, y, inner, 26, 0xFFFF, static, intro_text);
    y += 29;
    // The login: the administrator's when the profile keeps one.
    try t.item(child, 7, y + 2, 46, 9, 0xFFFF, static, L("Sign &in as"));
    try t.item(field, 56, y, 120, 12, id_user, edit_atom, L(""));
    try t.item(child, 182, y + 2, 40, 9, 0xFFFF, static, L("Passwor&d"));
    try t.item(field | ES_PASSWORD, 224, y, w - 7 - 224, 12, id_password, edit_atom, L(""));
    y += 14;
    try t.item(child, 56, y, w - 7 - 56, 9, id_login_note, static, L(""));
    y += 11;
    try t.item(child | WS_TABSTOP | WS_GROUP | BS_AUTOCHECKBOX, 56, y, w - 7 - 56, 10, id_keep_admin, button, L("&Keep this login as the profile's administrator login"));
    y += 15;
    try t.item(child | WS_TABSTOP | WS_GROUP | BS_AUTORADIOBUTTON, 7, y, inner, 10, id_mode_run, button, L("Run &box (Win+R), on the remote screen"));
    y += 12;
    try t.item(child | BS_AUTORADIOBUTTON, 7, y, inner, 10, id_mode_window, button, L("PowerShell &window (Win+R), on the remote screen"));
    y += 12;
    try t.item(child | BS_AUTORADIOBUTTON, 7, y, inner, 10, id_mode_remoting, button, L("PowerShell on the server (Win&RM), with the result"));
    y += 12;
    try t.item(child | WS_TABSTOP | WS_GROUP | BS_AUTOCHECKBOX, 7, y, inner, 10, id_https, button, L("WinRM over HTTPS (port 5986: the server needs an HTTPS listener)"));
    y += 15;
    try t.item(child, 7, y, inner, 9, 0xFFFF, static, L("&Command"));
    y += 10;
    try t.item(field, 7, y, inner, 13, id_command, edit_atom, L(""));
    y += 17;
    const preset_w: i16 = 62;
    const preset_gap: i16 = @divTrunc(inner - preset_w * @as(i16, preset_labels.len), @as(i16, preset_labels.len - 1));
    for (preset_labels, 0..) |label, i| {
        const style = child | WS_TABSTOP | if (i == 0) WS_GROUP else 0;
        try t.item(style, 7 + @as(i16, @intCast(i)) * (preset_w + preset_gap), y, preset_w, 14, id_preset_first + @as(u16, @intCast(i)), button, label);
    }
    y += 20;
    // The Server buttons: through the server's management, not its screen.
    try t.item(child | BS_GROUPBOX, 7, y, inner, 48, 0xFFFF, button, L("Server, without its screen (an administrator login)"));
    y += 12;
    try t.item(child, 14, y + 2, 50, 9, 0xFFFF, static, L("Session &user"));
    try t.item(field, 66, y, 90, 12, id_session_user, edit_atom, L(""));
    try t.item(child, 162, y + 2, 92, 9, 0xFFFF, static, L("PID, service, HH:MM or folder"));
    try t.item(field, 256, y, w - 14 - 256, 12, id_argument, edit_atom, L(""));
    y += 16;
    // Four buttons, and More, whose menu holds the other actions.
    const action_gap: i16 = 4;
    const slots: i16 = @as(i16, action_labels.len) + 1;
    const action_w: i16 = @divTrunc(inner - 14 - action_gap * (slots - 1), slots);
    for (action_labels, 0..) |label, i| {
        const style = child | WS_TABSTOP | if (i == 0) WS_GROUP else 0;
        try t.item(style, 14 + @as(i16, @intCast(i)) * (action_w + action_gap), y, action_w, 14, id_action_first + @as(u16, @intCast(i)), button, label);
    }
    try t.item(child | WS_TABSTOP, 14 + @as(i16, action_labels.len) * (action_w + action_gap), y, action_w, 14, id_more, button, L("More ▾"));
    y += 25;
    try t.item(child, 7, y, inner, 9, 0xFFFF, static, L("Result"));
    y += 10;
    try t.item(child | WS_TABSTOP | WS_GROUP | WS_BORDER | WS_VSCROLL | ES_MULTILINE | ES_AUTOVSCROLL | ES_READONLY, 7, y, inner, h - 25 - y, id_output, edit_atom, L(""));
    try t.item(child | WS_TABSTOP | WS_GROUP, 7, h - 21, 80, 14, id_task_manager, button, L("Open &Task Manager"));
    try t.item(child | WS_TABSTOP, 91, h - 21, 104, 14, id_trust, button, L("Trust t&his server (WinRM)..."));
    try t.item(child | WS_TABSTOP | WS_GROUP | BS_DEFPUSHBUTTON, w - 7 - 50 - 4 - 50, h - 21, 50, 14, IDOK, button, L("Se&nd"));
    try t.item(child | WS_TABSTOP, w - 7 - 50, h - 21, 50, 14, IDCANCEL, button, L("Close"));

    std.mem.writeInt(u16, t.bytes.items[8..10], t.items, .little);
    const out = try alloc.alignedAlloc(u8, .@"4", t.bytes.items.len);
    @memcpy(out, t.bytes.items);
    return out;
}

// --- The window ----------------------------------------------------------

fn stateOf(hwnd: HWND) ?*State {
    const raw = GetWindowLongPtrW(hwnd, DWLP_USER);
    if (raw == 0) return null;
    return @ptrFromInt(@as(usize, @bitCast(raw)));
}

fn modeOf(hwnd: HWND) Mode {
    if (IsDlgButtonChecked(hwnd, id_mode_window) == BST_CHECKED) return .powershell_window;
    if (IsDlgButtonChecked(hwnd, id_mode_remoting) == BST_CHECKED) return .remoting;
    return .run_box;
}

fn checked(hwnd: HWND, id: u16) bool {
    return IsDlgButtonChecked(hwnd, id) == BST_CHECKED;
}

/// `text` in control `id`, every lone `\n` written as `\r\n`.
fn setText(hwnd: HWND, id: u16, alloc: Allocator, text: []const u8) void {
    const control = GetDlgItem(hwnd, id) orelse return;
    var crlf: std.ArrayListUnmanaged(u8) = .empty;
    defer crlf.deinit(alloc);
    for (text, 0..) |byte, i| {
        if (byte == '\n' and (i == 0 or text[i - 1] != '\r')) crlf.append(alloc, '\r') catch return;
        crlf.append(alloc, byte) catch return;
    }
    // Output can hold bytes that are not UTF-8: shown as `?`, not refused.
    if (!std.unicode.utf8ValidateSlice(crlf.items)) for (crlf.items) |*byte| {
        if (byte.* >= 0x80) byte.* = '?';
    };
    const wide = std.unicode.utf8ToUtf16LeAllocZ(alloc, crlf.items) catch return;
    defer alloc.free(wide);
    _ = SetWindowTextW(control, wide.ptr);
}

/// Control `id`'s text, trimmed, in `alloc`.
fn readText(hwnd: HWND, id: u16, alloc: Allocator) ?[]u8 {
    const control = GetDlgItem(hwnd, id) orelse return null;
    const len: usize = @intCast(@max(0, GetWindowTextLengthW(control)));
    const buf = alloc.alloc(u16, len + 1) catch return null;
    defer alloc.free(buf);
    const got = GetWindowTextW(control, buf.ptr, @intCast(buf.len));
    const text = std.unicode.utf16LeToUtf8Alloc(alloc, buf[0..@intCast(@max(0, got))]) catch return null;
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == text.len) return text;
    const copy = alloc.dupe(u8, trimmed) catch return null;
    alloc.free(text);
    return copy;
}

/// The password field's text, untrimmed, in `alloc`; null when it is empty.
/// The wide copy is zeroed.
fn readSecret(hwnd: HWND, id: u16, alloc: Allocator) ?[]u8 {
    const control = GetDlgItem(hwnd, id) orelse return null;
    var buf: [512]u16 = undefined;
    defer @memset(&buf, 0);
    const len = GetWindowTextW(control, &buf, buf.len);
    if (len <= 0) return null;
    return std.unicode.utf16LeToUtf8Alloc(alloc, buf[0..@intCast(len)]) catch null;
}

fn say(hwnd: HWND, text: []const u8) void {
    var buf: [1024]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(buf[0 .. buf.len - 1], text) catch return;
    buf[n] = 0;
    _ = MessageBoxW(hwnd, buf[0..n :0].ptr, L("Remote commands"), 0x30);
}

/// A Yes/No question, No the default.
fn ask(hwnd: HWND, alloc: Allocator, caption: [:0]const u16, question: []const u8) bool {
    const MB_YESNO: u32 = 0x4;
    const MB_ICONWARNING: u32 = 0x30;
    const MB_DEFBUTTON2: u32 = 0x100;
    const IDYES: i32 = 6;
    const question_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, question) catch return false;
    defer alloc.free(question_w);
    return MessageBoxW(hwnd, question_w.ptr, caption.ptr, MB_YESNO | MB_ICONWARNING | MB_DEFBUTTON2) == IDYES;
}

fn focus(hwnd: HWND, id: u16) void {
    if (GetDlgItem(hwnd, id)) |control| _ = SetFocus(control);
}

fn focusCommand(hwnd: HWND) void {
    focus(hwnd, id_command);
}

const RECT = extern struct { left: i32, top: i32, right: i32, bottom: i32 };
extern "user32" fn GetWindowRect(hwnd: HWND, rect: *RECT) callconv(.winapi) BOOL;
extern "user32" fn CreatePopupMenu() callconv(.winapi) ?*anyopaque;
extern "user32" fn DestroyMenu(menu: *anyopaque) callconv(.winapi) BOOL;
extern "user32" fn AppendMenuW(menu: *anyopaque, flags: u32, id: usize, text: ?[*:0]const u16) callconv(.winapi) BOOL;
extern "user32" fn TrackPopupMenu(menu: *anyopaque, flags: u32, x: i32, y: i32, reserved: i32, hwnd: HWND, rect: ?*const RECT) callconv(.winapi) i32;

/// More: the other actions, and Prepare server, in a menu under the button.
fn showMore(hwnd: HWND, state: *State) void {
    if (busy(state)) return;
    const menu = CreatePopupMenu() orelse return;
    defer _ = DestroyMenu(menu);
    const MF_STRING: u32 = 0;
    const MF_SEPARATOR: u32 = 0x800;
    inline for (more_items, 0..) |item, i| {
        if (item.pick == null) _ = AppendMenuW(menu, MF_SEPARATOR, 0, null);
        const label: [*:0]const u16 = @ptrCast(item.label.ptr);
        _ = AppendMenuW(menu, MF_STRING, more_first_id + i, label);
    }
    var rect: RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    if (GetDlgItem(hwnd, id_more)) |button| _ = GetWindowRect(button, &rect);
    const TPM_RETURNCMD: u32 = 0x100;
    const TPM_RIGHTBUTTON: u32 = 0x2;
    const picked = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON, rect.left, rect.bottom, 0, hwnd, null);
    if (picked < more_first_id or picked >= more_first_id + more_items.len) return;
    const item = more_items[@as(usize, @intCast(picked)) - more_first_id];
    if (item.pick) |action| return startAction(hwnd, state, action);
    prepareServer(hwnd, state);
}

/// While a job runs, nothing else can start.
fn setBusy(hwnd: HWND, running: bool) void {
    const enable: BOOL = @intFromBool(!running);
    if (GetDlgItem(hwnd, IDOK)) |control| _ = EnableWindow(control, enable);
    if (GetDlgItem(hwnd, id_trust)) |control| _ = EnableWindow(control, enable);
    if (GetDlgItem(hwnd, id_more)) |control| _ = EnableWindow(control, enable);
    for (0..action_labels.len) |i| {
        if (GetDlgItem(hwnd, id_action_first + @as(u16, @intCast(i)))) |control| _ = EnableWindow(control, enable);
    }
}

fn busy(state: *const State) bool {
    return state.job != null or state.trust != null;
}

fn dialogProc(hwnd: HWND, msg: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) isize {
    switch (msg) {
        WM_INITDIALOG => {
            _ = SetWindowLongPtrW(hwnd, DWLP_USER, lparam);
            const state = stateOf(hwnd) orelse return 1;
            init(hwnd, state);
            // The focus is set here: returning 0 keeps it.
            return 0;
        },
        WM_COMMAND => {
            const id: u16 = @truncate(wparam);
            const code: u16 = @truncate(wparam >> 16);
            const state = stateOf(hwnd) orelse return 0;
            switch (id) {
                IDOK => {
                    send(hwnd, state);
                    return 1;
                },
                IDCANCEL => {
                    close(hwnd, state);
                    return 1;
                },
                id_task_manager => {
                    if (code != BN_CLICKED) return 0;
                    if (busy(state)) return 1;
                    state.request = .task_manager;
                    _ = EndDialog(hwnd, IDOK);
                    return 1;
                },
                id_trust => {
                    if (code != BN_CLICKED) return 0;
                    trustServer(hwnd, state);
                    return 1;
                },
                id_more => {
                    if (code != BN_CLICKED) return 0;
                    showMore(hwnd, state);
                    return 1;
                },
                else => {
                    if (code != BN_CLICKED) return 0;
                    if (id >= id_action_first and id < id_action_first + action_labels.len) {
                        startAction(hwnd, state, @enumFromInt(id - id_action_first));
                        return 1;
                    }
                    if (id < id_preset_first or id >= id_preset_first + preset_labels.len) return 0;
                    const preset: Preset = @enumFromInt(id - id_preset_first);
                    setText(hwnd, id_command, state.alloc, preset.command(modeOf(hwnd)));
                    focusCommand(hwnd);
                    return 1;
                },
            }
        },
        WM_TIMER => {
            if (wparam != job_timer) return 0;
            const state = stateOf(hwnd) orelse return 1;
            poll(hwnd, state);
            return 1;
        },
        WM_CLOSE => {
            const state = stateOf(hwnd) orelse {
                _ = EndDialog(hwnd, IDCANCEL);
                return 1;
            };
            close(hwnd, state);
            return 1;
        },
        else => return 0,
    }
}

fn init(hwnd: HWND, state: *State) void {
    const alloc = state.alloc;
    const remote = state.remote;
    _ = SetWindowTextW(hwnd, state.title.ptr);
    _ = CheckRadioButton(hwnd, id_mode_run, id_mode_remoting, id_mode_run);
    const has_admin = remote.admin_user.len != 0;
    setText(hwnd, id_user, alloc, if (has_admin) remote.admin_user else remote.user);
    setText(hwnd, id_login_note, alloc, if (has_admin)
        "The profile's administrator login. A blank password uses the saved one."
    else if (remote.password != null)
        "The connection's login. A blank password uses the saved one."
    else
        "No password saved: type one, or leave both blank for this PC's Windows login.");
    if (GetDlgItem(hwnd, id_keep_admin)) |box| {
        if (remote.profile_id == null) _ = EnableWindow(box, 0);
    }
    if (GetDlgItem(hwnd, id_password)) |control| _ = SendMessageW(control, EM_LIMITTEXT, 500, 0);
    setText(hwnd, id_session_user, alloc, remote.user);
    switch (state.start) {
        .command => {
            setText(hwnd, id_output, alloc, "Nothing sent yet.");
            focusCommand(hwnd);
        },
        .status => {
            focus(hwnd, id_action_first + @intFromEnum(Action.status));
            startAction(hwnd, state, .status);
        },
    }
}

/// Close, or Escape: a job still running is stopped. An elevated
/// PowerShell is left to finish.
fn close(hwnd: HWND, state: *State) void {
    _ = KillTimer(hwnd, job_timer);
    if (state.job) |job| {
        job.stop();
        state.job = null;
    }
    if (state.trust) |process| {
        _ = CloseHandle(process);
        state.trust = null;
    }
    _ = EndDialog(hwnd, IDCANCEL);
}

// --- The login -------------------------------------------------------------

/// The login a job signs in with, in the state's `alloc`. The caller zeroes
/// the password (`forget`).
const Login = struct {
    user: []u8,
    password: ?[]u8,

    fn forget(self: Login) void {
        if (self.password) |text| @memset(text, 0);
    }
};

/// The password kept for `user`: the administrator login's, or the
/// connection's, when the name is theirs. Null when none is kept for it.
pub fn keptPassword(remote: Remote, user: []const u8) ?[]const u8 {
    if (remote.admin_user.len != 0 and std.ascii.eqlIgnoreCase(user, remote.admin_user)) return remote.admin_password;
    if (remote.user.len != 0 and std.ascii.eqlIgnoreCase(user, remote.user)) return remote.password;
    return null;
}

/// The login fields: the user name, and the password typed or, left blank,
/// the one kept for that name. Null, said, when a name has no password.
fn readLogin(hwnd: HWND, state: *State) ?Login {
    const alloc = state.alloc;
    const user = readText(hwnd, id_user, alloc) orelse return null;
    const typed = readSecret(hwnd, id_password, alloc);
    const password: ?[]u8 = typed orelse kept: {
        const kept = keptPassword(state.remote, user) orelse break :kept null;
        break :kept alloc.dupe(u8, kept) catch null;
    };
    if (user.len != 0 and password == null) {
        say(hwnd, "Type the password of the user in Sign in as, or leave both blank for this PC's Windows login.");
        focus(hwnd, id_password);
        return null;
    }
    const login: Login = .{ .user = user, .password = password };
    if (typed != null) keepAdmin(hwnd, state, login);
    return login;
}

/// With its box checked, a typed login becomes the profile's administrator
/// login, for the next time.
fn keepAdmin(hwnd: HWND, state: *State, login: Login) void {
    if (!checked(hwnd, id_keep_admin) or login.user.len == 0) return;
    const id = state.remote.profile_id orelse return;
    var buf: [128]u8 = undefined;
    const admin_id = profile_credentials.adminId(&buf, id) orelse return;
    const password = login.password orelse return;
    profile_credentials.store(admin_id, login.user, password) catch {
        say(hwnd, "The administrator login could not be kept. It is used this time only.");
        return;
    };
    state.remote.admin_user = login.user;
    state.remote.admin_password = state.alloc.dupe(u8, password) catch null;
    setText(hwnd, id_login_note, state.alloc, "Kept as the profile's administrator login. A blank password uses the saved one.");
    if (GetDlgItem(hwnd, id_keep_admin)) |box| _ = SendMessageW(box, BM_SETCHECK, 0, 0);
}

// --- Send ------------------------------------------------------------------

/// Send: checked, asked about when it would restart or shut the computer
/// down, then handed to the caller (Run box, PowerShell window) or run here
/// (WinRM).
fn send(hwnd: HWND, state: *State) void {
    if (busy(state)) return;
    const alloc = state.alloc;
    const command = readText(hwnd, id_command, alloc) orelse return;
    defer alloc.free(command);
    if (command.len == 0) {
        say(hwnd, "Type a command, or pick one of the buttons under the field.");
        return focusCommand(hwnd);
    }
    const mode = modeOf(hwnd);
    if (stopsComputer(command)) {
        const question = std.fmt.allocPrint(alloc, "This restarts or shuts down {s}. Everyone signed in to it is signed out and loses what they have not saved, and this session ends.\n\nSend it?", .{state.remote.server}) catch return;
        defer alloc.free(question);
        if (!ask(hwnd, alloc, L("Restart the remote computer?"), question)) return focusCommand(hwnd);
    }
    switch (mode) {
        .run_box, .powershell_window => {
            const line = (if (mode == .run_box) alloc.dupe(u8, command) else powershellWindowLine(alloc, command)) catch return;
            if (line.len > run_box_max_len) {
                alloc.free(line);
                say(hwnd, if (mode == .run_box)
                    "The Run box takes at most 259 characters. Shorten the command, or use PowerShell on the server."
                else
                    "With powershell.exe around it, the command is longer than the Run box's 259 characters. Shorten it, or use PowerShell on the server.");
                return focusCommand(hwnd);
            }
            state.request = .{ .run_line = line };
            _ = EndDialog(hwnd, IDOK);
        },
        .remoting => {
            if (command.len > remoting_command_max_len) {
                say(hwnd, "The command is too long (16 KB at most).");
                return focusCommand(hwnd);
            }
            const login = readLogin(hwnd, state) orelse return;
            defer login.forget();
            const fields = [_][]const u8{ state.remote.server, login.user, login.password orelse "", command, if (checked(hwnd, id_https)) "1" else "" };
            const running = std.fmt.allocPrint(alloc, "Running on {s} through PowerShell remoting...", .{state.remote.server}) catch return;
            defer alloc.free(running);
            begin(hwnd, state, .command, remoting_script, &fields, running);
        },
    }
}

/// A Server button: asked about first when it signs a user out or restarts
/// the server, then run by a hidden PowerShell.
fn startAction(hwnd: HWND, state: *State, action: Action) void {
    if (busy(state)) return;
    const alloc = state.alloc;
    const session_user = readText(hwnd, id_session_user, alloc) orelse return;
    if (action.needsSessionUser() and session_user.len == 0) {
        say(hwnd, "Type the user whose session it is in Session user.");
        return focus(hwnd, id_session_user);
    }
    const argument = readText(hwnd, id_argument, alloc) orelse return;
    if (argumentProblem(action, argument)) |problem| {
        say(hwnd, problem);
        return focus(hwnd, id_argument);
    }
    const server = state.remote.server;
    // What changes the server is asked about first.
    const question: ?[]const u8 = switch (action) {
        .sign_out => std.fmt.allocPrint(alloc, "Sign {s} out of {s}?\n\nEvery program open in that session is closed without saving. If the session does not end, its programs are ended.", .{ session_user, server }) catch return,
        .restart => std.fmt.allocPrint(alloc, "Force {s} to restart now?\n\nEveryone signed in to it is signed out and loses what they have not saved, and this session ends.", .{server}) catch return,
        .end_process => std.fmt.allocPrint(alloc, "End process {s} on {s}?\n\nWhat it has not saved is lost.", .{ argument, server }) catch return,
        .restart_service => std.fmt.allocPrint(alloc, "Restart the service {s} on {s}?\n\nWhen it does not stop in 30 seconds, its process is ended (unless other services share it).", .{ argument, server }) catch return,
        .start_stopped_services => std.fmt.allocPrint(alloc, "Start every automatic service that is stopped on {s}?\n\nSome stop by design (they start when needed); starting them does no harm.", .{server}) catch return,
        .schedule_restart => std.fmt.allocPrint(alloc, "Restart {s} at {s} (its own clock)?\n\nIt restarts by force then: everyone signed in loses what they have not saved. Cancel scheduled restart undoes it.", .{ server, argument }) catch return,
        else => null,
    };
    if (question) |text| {
        defer alloc.free(text);
        if (!ask(hwnd, alloc, L("Change the remote computer?"), text)) return;
    }
    const login = readLogin(hwnd, state) orelse return;
    defer login.forget();
    const fields = [_][]const u8{ server, login.user, login.password orelse "", @tagName(action), session_user, argument, if (checked(hwnd, id_https)) "1" else "" };
    const running = std.fmt.allocPrint(alloc, "{s} on {s}: {s}...", .{ action.title(), server, if (action == .largest_folders)
        "counting through PowerShell remoting (WinRM), up to 2 minutes"
    else
        "connecting to its management (WinRM, then WMI over DCOM)" }) catch return;
    defer alloc.free(running);
    begin(hwnd, state, .{ .action = action }, action_script, &fields, running);
}

/// Start the hidden PowerShell for a job.
fn begin(hwnd: HWND, state: *State, kind: JobKind, script: []const u8, fields: []const []const u8, running: []const u8) void {
    const alloc = state.alloc;
    state.output.clearRetainingCapacity();
    const job = Job.start(alloc, script, fields) catch {
        setText(hwnd, id_output, alloc, "PowerShell could not be started on this PC, so nothing ran.");
        return;
    };
    state.job = job;
    state.job_kind = kind;
    setText(hwnd, id_output, alloc, running);
    setBusy(hwnd, true);
    _ = SetTimer(hwnd, job_timer, 250, null);
}

/// The running job's output so far; once it is over, what came of it. And
/// the elevated PowerShell of Trust this server.
fn poll(hwnd: HWND, state: *State) void {
    const WAIT_OBJECT_0: u32 = 0;
    if (state.trust) |process| {
        if (WaitForSingleObject(process, 0) == WAIT_OBJECT_0) {
            var code: u32 = 1;
            _ = GetExitCodeProcess(process, &code);
            _ = CloseHandle(process);
            state.trust = null;
            setText(hwnd, id_output, state.alloc, if (code == 0)
                "This PC trusts the server for WinRM now (TrustedHosts). Try again: PowerShell on the server, or a Server button."
            else
                "The server could not be added to TrustedHosts (the WinRM service of this PC did not start, or the change was refused). Nothing changed.");
            setBusy(hwnd, false);
        }
    }
    const job = state.job orelse {
        if (state.trust == null) _ = KillTimer(hwnd, job_timer);
        return;
    };
    job.drain(state.alloc, &state.output);
    if (WaitForSingleObject(job.process, 0) != WAIT_OBJECT_0) {
        const limit = if (state.job_kind == .command) remoting_timeout_ms else action_timeout_ms;
        if (std.time.milliTimestamp() - job.started_ms < limit) return;
        job.stop();
        return finish(hwnd, state, .timed_out);
    }
    job.drain(state.alloc, &state.output);
    var code: u32 = 1;
    _ = GetExitCodeProcess(job.process, &code);
    job.close();
    finish(hwnd, state, if (code == 0) .ran else .failed);
}

const action_hint =
    \\The Server buttons need an administrator login of the server, and its
    \\management reachable from this PC: WinRM (port 5985, or 5986 with
    \\HTTPS; a server outside your domain, or named by its address, needs
    \\Trust this server) or WMI over DCOM (port 135 and the dynamic RPC ports,
    \\the firewall's "Windows Management Instrumentation" rules). A local
    \\account other than Administrator also needs remote UAC off on the
    \\server (LocalAccountTokenFilterPolicy = 1).
    \\
    \\A server whose network or kernel is frozen answers none of these: then
    \\only its console (the hypervisor, iDRAC or iLO) or a power cycle helps.
;

fn finish(hwnd: HWND, state: *State, outcome: enum { ran, failed, timed_out }) void {
    _ = KillTimer(hwnd, job_timer);
    state.job = null;
    const alloc = state.alloc;
    const clean = withoutClixml(alloc, state.output.items) catch state.output.items;
    const output = std.mem.trim(u8, clean, " \t\r\n");
    const server = state.remote.server;
    const text = switch (state.job_kind) {
        .command => switch (outcome) {
            .ran => std.fmt.allocPrint(alloc, "Done: the command ran on {s}.\n\n{s}", .{ server, if (output.len == 0) "(no output)" else output }),
            .failed => std.fmt.allocPrint(alloc, "It did not run, or it failed, on {s}:\n\n{s}\n\nPowerShell remoting needs WinRM on the server (Enable-PSRemoting, as administrator there). For a server outside your domain, or named by its address, this PC needs it in TrustedHosts: the Trust this server button. Or check WinRM over HTTPS, when the server has an HTTPS listener.", .{ server, if (output.len == 0) "(no message)" else output }),
            .timed_out => std.fmt.allocPrint(alloc, "No answer from {s} after 2 minutes: stopped. Whether the command ran there is not known.", .{server}),
        },
        .action => switch (outcome) {
            .ran => std.fmt.allocPrint(alloc, "{s}", .{if (output.len == 0) "Done." else output}),
            .failed => std.fmt.allocPrint(alloc, "{s}\n\n{s}", .{ if (output.len == 0) "It failed, with no message." else output, action_hint }),
            .timed_out => std.fmt.allocPrint(alloc, "No answer from {s} after 4 minutes: stopped. What it did there is not known.\n\n{s}\n\n{s}", .{ server, output, action_hint }),
        },
    } catch return;
    defer alloc.free(text);
    setText(hwnd, id_output, alloc, text);
    setBusy(hwnd, false);
}

// --- Trust this server -----------------------------------------------------

/// Whether `server` can go into a PowerShell string and TrustedHosts as it
/// is: a host name, an IPv4 or an IPv6 address.
pub fn trustableName(server: []const u8) bool {
    if (server.len == 0 or server.len > 253) return false;
    for (server) |byte| switch (byte) {
        'a'...'z', 'A'...'Z', '0'...'9', '.', '-', '_', ':' => {},
        else => return false,
    };
    return true;
}

/// What the elevated PowerShell runs, `@SERVER@` replaced: the WinRM
/// service started (Set-Item WSMan: needs it), then the server added to
/// TrustedHosts unless it, or `*`, is there. Exit 0 when it is there.
const trust_script =
    \\$ErrorActionPreference = 'Stop'
    \\try {
    \\  if ((Get-Service WinRM).Status -ne 'Running') { Start-Service WinRM }
    \\  $have = @(((Get-Item WSMan:\localhost\Client\TrustedHosts).Value -split ',') | ForEach-Object { $_.Trim() })
    \\  if ($have -notcontains '@SERVER@' -and $have -notcontains '*') {
    \\    Set-Item WSMan:\localhost\Client\TrustedHosts -Value '@SERVER@' -Concatenate -Force
    \\  }
    \\  exit 0
    \\} catch { exit 2 }
;

/// shellapi.h's SHELLEXECUTEINFOW, natural alignment (112 bytes
/// on x64, pinned below).
const SHELLEXECUTEINFOW = extern struct {
    cbSize: u32 = @sizeOf(SHELLEXECUTEINFOW),
    fMask: u32 = 0,
    hwnd: ?HWND = null,
    lpVerb: ?[*:0]const u16 = null,
    lpFile: ?[*:0]const u16 = null,
    lpParameters: ?[*:0]const u16 = null,
    lpDirectory: ?[*:0]const u16 = null,
    nShow: i32 = 0,
    hInstApp: ?*anyopaque = null,
    lpIDList: ?*anyopaque = null,
    lpClass: ?[*:0]const u16 = null,
    hkeyClass: ?*anyopaque = null,
    dwHotKey: u32 = 0,
    hIconOrMonitor: ?*anyopaque = null,
    hProcess: ?HANDLE = null,
};
extern "shell32" fn ShellExecuteExW(info: *SHELLEXECUTEINFOW) callconv(.winapi) BOOL;

fn trustServer(hwnd: HWND, state: *State) void {
    if (busy(state)) return;
    const alloc = state.alloc;
    const server = state.remote.server;
    if (!trustableName(server)) return say(hwnd, "The server's name has characters TrustedHosts does not take.");
    const question = std.fmt.allocPrint(alloc, "Add {s} to this PC's WinRM TrustedHosts?\n\nWindows asks for administrator permission, and the WinRM service of this PC is started. TrustedHosts lets this PC send a login to {s} without checking that the server is the one it claims to be: use it on a network you trust (a VPN, your office), or set up HTTPS on the server instead.", .{ server, server }) catch return;
    defer alloc.free(question);
    if (!ask(hwnd, alloc, L("Trust this server?"), question)) return;
    const script = std.mem.replaceOwned(u8, alloc, trust_script, "@SERVER@", server) catch return;
    defer alloc.free(script);
    const parameters = encodedParameters(alloc, script, "-WindowStyle Hidden ") catch return;
    defer alloc.free(parameters);
    const SEE_MASK_NOCLOSEPROCESS: u32 = 0x40;
    const SEE_MASK_NOASYNC: u32 = 0x100;
    var info: SHELLEXECUTEINFOW = .{
        .fMask = SEE_MASK_NOCLOSEPROCESS | SEE_MASK_NOASYNC,
        .hwnd = hwnd,
        .lpVerb = L("runas"),
        .lpFile = L("powershell.exe"),
        .lpParameters = parameters.ptr,
        .nShow = 0,
    };
    if (ShellExecuteExW(&info) == 0) {
        const ERROR_CANCELLED: u32 = 1223;
        setText(hwnd, id_output, alloc, if (GetLastError() == ERROR_CANCELLED)
            "Cancelled: TrustedHosts was not changed."
        else
            "The administrator PowerShell could not be started: TrustedHosts was not changed.");
        return;
    }
    const process = info.hProcess orelse {
        setText(hwnd, id_output, alloc, "The administrator PowerShell started; its result is not known. Try again.");
        return;
    };
    state.trust = process;
    setText(hwnd, id_output, alloc, "Adding the server to TrustedHosts, as administrator...");
    setBusy(hwnd, true);
    _ = SetTimer(hwnd, job_timer, 250, null);
}

// --- Prepare server --------------------------------------------------------

/// What Prepare server types into the session's Run box: a PowerShell that
/// opens an elevated one (Windows asks on the remote screen), which runs
/// the clipboard, the session's copy of this PC's, only when it starts with
/// `#koreterm-prepare` (`prepareScript`). The pane puts the script there
/// right after Enter (`Pane.typeRunLineThen`).
pub const prepare_line = "powershell -NoProfile -Command \"Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile','-NoExit','-Command','$c=Get-Clipboard -Raw;if($c -like ''#koreterm-prepare*''){iex $c}else{''The clipboard changed: use Prepare again.''}'\"";

/// What the elevated PowerShell on the server runs, `@PORT@` replaced by
/// the Remote Desktop port: PowerShell remoting on (`Enable-PSRemoting`);
/// the WinRM and WMI firewall rules on, and open only to the addresses
/// connected to the Remote Desktop port (this PC, as the server sees it);
/// and `LocalAccountTokenFilterPolicy = 1`, so a local administrator other
/// than Administrator is an administrator remotely too.
const prepare_script =
    \\#koreterm-prepare
    \\Set-Clipboard -Value ' '
    \\$ErrorActionPreference = 'Continue'
    \\Write-Host 'koreterm: preparing this server for remote management (WinRM and WMI)...' -ForegroundColor Cyan
    \\$port = @PORT@
    \\$ips = @(Get-NetTCPConnection -LocalPort $port -State Established -ErrorAction SilentlyContinue | Select-Object -ExpandProperty RemoteAddress -Unique | Where-Object { $_ -notmatch '^(127\.|::1$)' })
    \\Enable-PSRemoting -Force -SkipNetworkProfileCheck
    \\$rules = 'WINRM-HTTP-In-TCP', 'WINRM-HTTP-In-TCP-PUBLIC', 'WINRM-HTTP-In-TCP-NoScope', 'WMI-RPCSS-In-TCP', 'WMI-WINMGMT-In-TCP', 'WMI-ASYNC-In-TCP'
    \\foreach ($name in $rules) {
    \\  if (-not (Get-NetFirewallRule -Name $name -ErrorAction SilentlyContinue)) { continue }
    \\  Enable-NetFirewallRule -Name $name
    \\  if ($ips.Count -gt 0) { Set-NetFirewallRule -Name $name -RemoteAddress $ips }
    \\}
    \\New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name LocalAccountTokenFilterPolicy -Value 1 -PropertyType DWord -Force | Out-Null
    \\Write-Host ''
    \\if ($ips.Count -gt 0) {
    \\  Write-Host ('WinRM (5985) and WMI (135 and its dynamic ports) now answer only: ' + ($ips -join ', ')) -ForegroundColor Green
    \\} else {
    \\  Write-Host "No address connected to port $port was found: the firewall rules keep the addresses they had." -ForegroundColor Yellow
    \\}
    \\Write-Host 'A firewall in front of this server (a router, a cloud security group) must let 5985 and 135 through from that address too.'
    \\Write-Host 'On the koreterm PC, outside a domain: Trust this server, in the Run command window.'
    \\Write-Host 'Done. You can close this window.' -ForegroundColor Green
;

/// The script with the port in.
pub fn prepareScript(alloc: Allocator, port: u16) Allocator.Error![]u8 {
    var buf: [8]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}", .{port}) catch unreachable;
    return std.mem.replaceOwned(u8, alloc, prepare_script, "@PORT@", text);
}

/// More > Prepare server: asked about, then handed to the caller, which
/// types `prepare_line` into the session once the window has closed.
fn prepareServer(hwnd: HWND, state: *State) void {
    const alloc = state.alloc;
    const question = std.fmt.allocPrint(alloc, "Prepare {s} so the Server buttons reach it when its screen does not?\n\n" ++
        "koreterm types a command into the session (Win+R). Windows asks for administrator permission on the remote screen: click Yes there. An administrator PowerShell window then:\n" ++
        "- turns PowerShell remoting (WinRM) on;\n" ++
        "- turns on the WinRM and WMI firewall rules, open only to the address this PC connects from;\n" ++
        "- sets LocalAccountTokenFilterPolicy = 1, so a local administrator account is one remotely too.\n\n" ++
        "Do it while the server works. Prepare it?", .{state.remote.server}) catch return;
    defer alloc.free(question);
    if (!ask(hwnd, alloc, L("Prepare the server?"), question)) return;
    const script = prepareScript(alloc, state.remote.port) catch return;
    state.request = .{ .prepare = .{ .line = prepare_line, .clipboard = script } };
    _ = EndDialog(hwnd, IDOK);
}

// --- What a command line says ----------------------------------------------

/// Whether `command` restarts, shuts down or powers off the computer:
/// `Restart-Computer`, `Stop-Computer`, or `shutdown` with /r, /s, /p, /g
/// (or the `-` forms). Asked about before it is sent.
pub fn stopsComputer(command: []const u8) bool {
    var buf: [4096]u8 = undefined;
    const lower = std.ascii.lowerString(buf[0..@min(buf.len, command.len)], command[0..@min(buf.len, command.len)]);
    if (std.mem.indexOf(u8, lower, "restart-computer") != null) return true;
    if (std.mem.indexOf(u8, lower, "stop-computer") != null) return true;
    if (std.mem.indexOf(u8, lower, "shutdown") == null) return false;
    var words = std.mem.tokenizeAny(u8, lower, " \t");
    while (words.next()) |word| {
        if (word.len != 2 or (word[0] != '/' and word[0] != '-')) continue;
        switch (word[1]) {
            'r', 's', 'p', 'g' => return true,
            else => {},
        }
    }
    return false;
}

/// `powershell.exe -NoExit -Command "<command>"`, the command quoted as the
/// Windows command line reads it back (`CommandLineToArgvW`): a quote as
/// `\"`, and the backslashes before a quote, or before the closing one,
/// doubled. In `alloc`.
pub fn powershellWindowLine(alloc: Allocator, command: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "powershell.exe -NoExit -Command \"");
    var backslashes: usize = 0;
    for (command) |byte| {
        switch (byte) {
            '\\' => backslashes += 1,
            '"' => {
                try out.appendNTimes(alloc, '\\', backslashes * 2 + 1);
                try out.append(alloc, '"');
                backslashes = 0;
                continue;
            },
            else => {
                try out.appendNTimes(alloc, '\\', backslashes);
                backslashes = 0;
                try out.append(alloc, byte);
                continue;
            },
        }
    }
    try out.appendNTimes(alloc, '\\', backslashes * 2);
    try out.append(alloc, '"');
    return out.toOwnedSlice(alloc);
}

/// `text` without what PowerShell writes as CLIXML when its error stream is
/// redirected (`#< CLIXML` and the `<Objs ...>...</Objs>` records, such as
/// "Preparing modules for first use."). In `alloc`.
pub fn withoutClixml(alloc: Allocator, text: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    var rest = text;
    while (rest.len != 0) {
        const marker = std.mem.indexOf(u8, rest, "#< CLIXML");
        const objs = std.mem.indexOf(u8, rest, "<Objs ");
        const at = if (marker != null and objs != null) @min(marker.?, objs.?) else marker orelse objs orelse {
            try out.appendSlice(alloc, rest);
            break;
        };
        try out.appendSlice(alloc, rest[0..at]);
        rest = rest[at..];
        if (std.mem.startsWith(u8, rest, "#< CLIXML")) {
            rest = rest["#< CLIXML".len..];
            rest = std.mem.trimLeft(u8, rest, "\r\n");
        } else {
            const end = std.mem.indexOf(u8, rest, "</Objs>") orelse break;
            rest = rest[end + "</Objs>".len ..];
        }
    }
    return out.toOwnedSlice(alloc);
}

// --- The hidden PowerShell -------------------------------------------------

const HANDLE = *anyopaque;

const SECURITY_ATTRIBUTES = extern struct {
    nLength: u32,
    lpSecurityDescriptor: ?*anyopaque = null,
    bInheritHandle: BOOL,
};
const STARTUPINFOW = extern struct {
    cb: u32,
    lpReserved: ?[*:0]u16 = null,
    lpDesktop: ?[*:0]u16 = null,
    lpTitle: ?[*:0]u16 = null,
    dwX: u32 = 0,
    dwY: u32 = 0,
    dwXSize: u32 = 0,
    dwYSize: u32 = 0,
    dwXCountChars: u32 = 0,
    dwYCountChars: u32 = 0,
    dwFillAttribute: u32 = 0,
    dwFlags: u32 = 0,
    wShowWindow: u16 = 0,
    cbReserved2: u16 = 0,
    lpReserved2: ?*u8 = null,
    hStdInput: ?HANDLE = null,
    hStdOutput: ?HANDLE = null,
    hStdError: ?HANDLE = null,
};
const PROCESS_INFORMATION = extern struct {
    hProcess: ?HANDLE,
    hThread: ?HANDLE,
    dwProcessId: u32,
    dwThreadId: u32,
};

extern "kernel32" fn CreatePipe(read: *?HANDLE, write: *?HANDLE, attributes: ?*const SECURITY_ATTRIBUTES, size: u32) callconv(.winapi) BOOL;
extern "kernel32" fn SetHandleInformation(handle: HANDLE, mask: u32, flags: u32) callconv(.winapi) BOOL;
extern "kernel32" fn PeekNamedPipe(pipe: HANDLE, buf: ?*anyopaque, size: u32, read: ?*u32, available: ?*u32, left: ?*u32) callconv(.winapi) BOOL;
extern "kernel32" fn ReadFile(file: HANDLE, buf: [*]u8, size: u32, read: *u32, overlapped: ?*anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn WriteFile(file: HANDLE, buf: [*]const u8, size: u32, written: *u32, overlapped: ?*anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn WaitForSingleObject(handle: HANDLE, ms: u32) callconv(.winapi) u32;
extern "kernel32" fn GetExitCodeProcess(process: HANDLE, code: *u32) callconv(.winapi) BOOL;
extern "kernel32" fn TerminateProcess(process: HANDLE, code: u32) callconv(.winapi) BOOL;
extern "kernel32" fn CloseHandle(handle: ?HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn CreateProcessW(app: ?[*:0]const u16, cmd: [*:0]u16, pa: ?*anyopaque, ta: ?*anyopaque, inherit: BOOL, flags: u32, env: ?*anyopaque, cwd: ?[*:0]const u16, si: *STARTUPINFOW, pi: *PROCESS_INFORMATION) callconv(.winapi) BOOL;

/// The start of every hidden script: no progress records (which a
/// redirected PowerShell writes as CLIXML), UTF-8 out, and its input lines,
/// each base64 of UTF-8, read by `D`.
const script_prelude =
    \\$ErrorActionPreference = 'Stop'
    \\$ProgressPreference = 'SilentlyContinue'
    \\[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    \\function D([string]$s) { [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($s)) }
    \\function Say([string]$t) { [Console]::Out.WriteLine($t) }
    \\function Ports([string]$server) {
    \\  $lines = @()
    \\  foreach ($port in 3389, 5985, 5986, 135, 445) {
    \\    $c = New-Object System.Net.Sockets.TcpClient
    \\    $ok = $false
    \\    try { $ok = $c.ConnectAsync($server, $port).Wait(3000) -and $c.Connected } catch { $ok = $false } finally { $c.Close() }
    \\    $lines += ('  {0,-5} {1}' -f $port, $(if ($ok) { 'answers' } else { 'no answer' }))
    \\  }
    \\  "Ports of $server seen from this PC (3389 Remote Desktop, 5985/5986 WinRM, 135 WMI over DCOM, 445 file sharing):`n" + ($lines -join "`n")
    \\}
    \\
;

/// What the hidden PowerShell runs for PowerShell on the server: five input
/// lines (server, user, password, command, "1" for HTTPS), then
/// `Invoke-Command`. Exit 0 when it ran, 1 with the error's message and the
/// server's ports when it did not.
const remoting_script = script_prelude ++
    \\$server = D ([Console]::In.ReadLine())
    \\$user = D ([Console]::In.ReadLine())
    \\$pass = D ([Console]::In.ReadLine())
    \\$command = D ([Console]::In.ReadLine())
    \\$ssl = (D ([Console]::In.ReadLine())) -eq '1'
    \\try {
    \\  $p = @{ ComputerName = $server; ScriptBlock = [ScriptBlock]::Create($command); ErrorAction = 'Stop' }
    \\  if ($ssl) { $p.UseSSL = $true }
    \\  if ($user -ne '' -and $pass -ne '') {
    \\    $secure = ConvertTo-SecureString $pass -AsPlainText -Force
    \\    $p.Credential = New-Object System.Management.Automation.PSCredential($user, $secure)
    \\  }
    \\  $pass = $null
    \\  $out = Invoke-Command @p 2>&1 | Out-String -Width 160
    \\  [Console]::Out.Write($out)
    \\  exit 0
    \\} catch {
    \\  Say $_.Exception.Message.Trim()
    \\  Say ''
    \\  Say (Ports $server)
    \\  exit 1
    \\}
;

/// What the hidden PowerShell runs for a Server button or a More action:
/// seven input lines (server, user, password, the action's tag name, the
/// session user, the field's argument, "1" for HTTPS). It opens a CIM
/// session, over WinRM and, when that fails, over DCOM, and works through
/// it: Win32_OperatingSystem, Win32_Processor, Win32_LogicalDisk and
/// Win32_Process for the status; logoff.exe started by Win32_Process.Create
/// for a sign-out, then the session's processes ended when it stays;
/// Explorer ended in the session, and started again in it through a
/// scheduled task that runs as the signed-in user; shutdown.exe /r /f for a
/// restart (with /t for a scheduled one, /a to cancel); Win32_NTLogEvent for
/// the events; Win32_Service for the services; StdRegProv for a pending
/// restart; tsdiscon.exe for a disconnect. Largest folders alone goes
/// through `Invoke-Command`. Exit 0 when it did it, 1 with what failed.
const action_script = script_prelude ++
    \\$server = D ([Console]::In.ReadLine())
    \\$user = D ([Console]::In.ReadLine())
    \\$pass = D ([Console]::In.ReadLine())
    \\$action = D ([Console]::In.ReadLine())
    \\$target = D ([Console]::In.ReadLine())
    \\$arg = (D ([Console]::In.ReadLine())).Trim()
    \\$ssl = (D ([Console]::In.ReadLine())) -eq '1'
    \\$cred = $null
    \\if ($user -ne '' -and $pass -ne '') {
    \\  $cred = New-Object System.Management.Automation.PSCredential($user, (ConvertTo-SecureString $pass -AsPlainText -Force))
    \\}
    \\$pass = $null
    \\$system = @('csrss.exe', 'winlogon.exe', 'smss.exe', 'wininit.exe', 'dwm.exe', 'fontdrvhost.exe', 'LogonUI.exe', 'System', 'Idle')
    \\
    \\function Connect {
    \\  $errs = @()
    \\  foreach ($proto in 'WinRM', 'DCOM') {
    \\    try {
    \\      if ($proto -eq 'DCOM') { $o = New-CimSessionOption -Protocol Dcom }
    \\      elseif ($ssl) { $o = New-CimSessionOption -UseSsl }
    \\      else { $o = New-CimSessionOption -Protocol Wsman }
    \\      $p = @{ ComputerName = $server; SessionOption = $o; OperationTimeoutSec = 30 }
    \\      if ($cred) { $p.Credential = $cred }
    \\      $s = New-CimSession @p
    \\      $null = Get-CimInstance -CimSession $s -ClassName Win32_OperatingSystem -Property Caption -OperationTimeoutSec 30
    \\      return @{ Session = $s; Protocol = $proto }
    \\    } catch { $errs += ('  ' + $proto + ': ' + $_.Exception.Message.Trim()) }
    \\  }
    \\  throw ("Could not reach the management of $server, through WinRM or through WMI over DCOM:`n" + ($errs -join "`n"))
    \\}
    \\
    \\function Sessions($s) {
    \\  $procs = @(Get-CimInstance -CimSession $s -ClassName Win32_Process -OperationTimeoutSec 60)
    \\  $list = @()
    \\  foreach ($g in ($procs | Where-Object { $_.SessionId -gt 0 } | Group-Object SessionId)) {
    \\    $owner = $null
    \\    $tries = 0
    \\    $mine = $g.Group | Where-Object { $system -notcontains $_.Name } | Sort-Object { if ($_.Name -eq 'explorer.exe') { 0 } else { 1 } }
    \\    foreach ($pr in $mine) {
    \\      if ($tries -ge 6) { break }
    \\      $tries++
    \\      try { $o = Invoke-CimMethod -CimSession $s -InputObject $pr -MethodName GetOwner -OperationTimeoutSec 20 } catch { continue }
    \\      if ($o.ReturnValue -eq 0 -and $o.User) { $owner = $o; break }
    \\    }
    \\    $mem = ($g.Group | Measure-Object -Property WorkingSetSize -Sum).Sum
    \\    $list += [pscustomobject]@{
    \\      Id = [int]$g.Name
    \\      Name = $(if ($owner) { $owner.User } else { '' })
    \\      User = $(if ($owner) { if ($owner.Domain) { $owner.Domain + '\' + $owner.User } else { $owner.User } } else { '(nobody: logon screen)' })
    \\      Processes = $g.Count
    \\      Explorer = [bool]($g.Group | Where-Object { $_.Name -eq 'explorer.exe' })
    \\      MemoryMB = [math]::Round($mem / 1MB)
    \\    }
    \\  }
    \\  return ,$list
    \\}
    \\
    \\function SessionLines($list) {
    \\  if ($list.Count -eq 0) { return '  (no session with a user)' }
    \\  ($list | ForEach-Object { '  {0,3}  {1,-32} {2,4} processes  {3,6} MB  {4}' -f $_.Id, $_.User, $_.Processes, $_.MemoryMB, $(if ($_.Explorer) { 'Explorer running' } else { 'NO EXPLORER' }) }) -join "`n"
    \\}
    \\
    \\function Find($s) {
    \\  $want = ($target -split '\\')[-1]
    \\  $all = Sessions $s
    \\  $found = @($all | Where-Object { $_.Name -ieq $want })
    \\  if ($found.Count -eq 0) {
    \\    Say "No session of $target on $server. Its sessions:"
    \\    Say (SessionLines $all)
    \\    exit 1
    \\  }
    \\  return ,$found
    \\}
    \\
    \\function Status($s, $proto) {
    \\  $os = Get-CimInstance -CimSession $s -ClassName Win32_OperatingSystem
    \\  $cs = Get-CimInstance -CimSession $s -ClassName Win32_ComputerSystem
    \\  $cpu = [math]::Round((Get-CimInstance -CimSession $s -ClassName Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average)
    \\  $memTotal = $os.TotalVisibleMemorySize / 1MB
    \\  $memFree = $os.FreePhysicalMemory / 1MB
    \\  $memUsed = 100 - [math]::Round($memFree / $memTotal * 100)
    \\  $commitUsed = 100 - [math]::Round($os.FreeVirtualMemory / $os.TotalVirtualMemorySize * 100)
    \\  $up = $os.LocalDateTime - $os.LastBootUpTime
    \\  $disks = @(Get-CimInstance -CimSession $s -ClassName Win32_LogicalDisk -Filter 'DriveType=3')
    \\  $procs = @(Get-CimInstance -CimSession $s -ClassName Win32_Process)
    \\  $problems = @()
    \\  if ($cpu -ge 90) { $problems += "CPU at $cpu%" }
    \\  if ($memUsed -ge 90) { $problems += "memory $memUsed% used" }
    \\  if ($commitUsed -ge 90) { $problems += "commit (memory plus page file) $commitUsed% used" }
    \\  $diskLines = @()
    \\  foreach ($d in $disks) {
    \\    if (-not $d.Size) { continue }
    \\    $freePct = [math]::Round($d.FreeSpace / $d.Size * 100)
    \\    $freeGB = [math]::Round($d.FreeSpace / 1GB, 1)
    \\    if ($freePct -lt 10 -or $freeGB -lt 2) { $problems += ('disk {0} {1} GB free ({2}%)' -f $d.DeviceID, $freeGB, $freePct) }
    \\    $diskLines += ('  {0}  {1,7} GB free of {2,7} GB  ({3}% free)' -f $d.DeviceID, $freeGB, [math]::Round($d.Size / 1GB, 1), $freePct)
    \\  }
    \\  Say ("{0}: {1}, up {2} d {3} h {4} min (through {5})" -f $server, $os.Caption, $up.Days, $up.Hours, $up.Minutes, $proto)
    \\  Say ''
    \\  if ($problems.Count -eq 0) { Say 'Problems: none found in CPU, memory or disks.' } else { Say ('PROBLEMS: ' + ($problems -join '; ')) }
    \\  Say ''
    \\  Say ("CPU      {0}% ({1} logical processors)" -f $cpu, $cs.NumberOfLogicalProcessors)
    \\  Say ("Memory   {0}% used: {1:N1} GB free of {2:N1} GB" -f $memUsed, $memFree, $memTotal)
    \\  Say ("Commit   {0}% used" -f $commitUsed)
    \\  Say 'Disks'
    \\  Say ($diskLines -join "`n")
    \\  Say ''
    \\  Say 'Sessions (id, user, processes, memory)'
    \\  Say (SessionLines (Sessions $s))
    \\  Say ''
    \\  Say 'Most memory (working set)'
    \\  foreach ($p in ($procs | Sort-Object WorkingSetSize -Descending | Select-Object -First 8)) {
    \\    Say ('  {0,-28} pid {1,6}  session {2,2}  {3,6} MB' -f $p.Name, $p.ProcessId, $p.SessionId, [math]::Round($p.WorkingSetSize / 1MB))
    \\  }
    \\  try {
    \\    $perf = @(Get-CimInstance -CimSession $s -ClassName Win32_PerfFormattedData_PerfProc_Process -OperationTimeoutSec 60 | Where-Object { $_.Name -ne '_Total' -and $_.Name -ne 'Idle' } | Sort-Object PercentProcessorTime -Descending | Select-Object -First 8)
    \\    $n = [math]::Max(1, [int]$cs.NumberOfLogicalProcessors)
    \\    Say ''
    \\    Say 'Most CPU now'
    \\    foreach ($p in $perf) { Say ('  {0,-28} pid {1,6}  {2,5}%' -f $p.Name, $p.IDProcess, [math]::Round($p.PercentProcessorTime / $n)) }
    \\  } catch {}
    \\  try {
    \\    $stopped = @(Get-CimInstance -CimSession $s -ClassName Win32_Service -Filter "StartMode='Auto' AND State<>'Running'" -OperationTimeoutSec 60 | Select-Object -First 12)
    \\    if ($stopped.Count -ne 0) {
    \\      Say ''
    \\      Say 'Automatic services not running (some stop by design)'
    \\      foreach ($v in $stopped) { Say ('  {0,-28} {1}' -f $v.Name, $v.State) }
    \\    }
    \\  } catch {}
    \\}
    \\
    \\function Left($s, $id) {
    \\  @(Get-CimInstance -CimSession $s -ClassName Win32_Process -Filter "SessionId=$id" -OperationTimeoutSec 30)
    \\}
    \\
    \\function SignOut($s) {
    \\  foreach ($x in (Find $s)) {
    \\    $r = Invoke-CimMethod -CimSession $s -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = "logoff.exe $($x.Id)" }
    \\    if ($r.ReturnValue -ne 0) { Say "logoff.exe did not start on $server (code $($r.ReturnValue))." }
    \\    else { Say "Signing $($x.User) out of session $($x.Id)..." }
    \\    $gone = $false
    \\    for ($i = 0; $i -lt 15; $i++) { Start-Sleep -Seconds 2; if ((Left $s $x.Id).Count -eq 0) { $gone = $true; break } }
    \\    if (-not $gone) {
    \\      Say 'The session did not end in 30 seconds: ending its programs...'
    \\      foreach ($p in (Left $s $x.Id)) {
    \\        if (@('csrss.exe', 'smss.exe', 'wininit.exe') -contains $p.Name) { continue }
    \\        try { $null = Invoke-CimMethod -CimSession $s -InputObject $p -MethodName Terminate -OperationTimeoutSec 20 } catch {}
    \\      }
    \\      $null = Invoke-CimMethod -CimSession $s -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = "logoff.exe $($x.Id)" }
    \\      for ($i = 0; $i -lt 10; $i++) { Start-Sleep -Seconds 2; if ((Left $s $x.Id).Count -eq 0) { $gone = $true; break } }
    \\    }
    \\    if ($gone) { Say "Done: session $($x.Id) of $($x.User) ended. Connect again to sign in fresh." }
    \\    else {
    \\      Say "Session $($x.Id) is still there, with these programs:"
    \\      foreach ($p in (Left $s $x.Id)) { Say ('  {0} (pid {1})' -f $p.Name, $p.ProcessId) }
    \\      Say 'Force restart is what is left.'
    \\      exit 1
    \\    }
    \\  }
    \\}
    \\
    \\function Explorer($s) {
    \\  foreach ($x in (Find $s)) {
    \\    $old = @(Get-CimInstance -CimSession $s -ClassName Win32_Process -Filter "Name='explorer.exe' AND SessionId=$($x.Id)")
    \\    foreach ($e in $old) { try { $null = Invoke-CimMethod -CimSession $s -InputObject $e -MethodName Terminate -OperationTimeoutSec 20 } catch {} }
    \\    if ($old.Count -ne 0) { Say "Ended Explorer in session $($x.Id) ($($old.Count) process(es)); waiting for Windows to start it again..."; Start-Sleep -Seconds 6 }
    \\    $now = @(Get-CimInstance -CimSession $s -ClassName Win32_Process -Filter "Name='explorer.exe' AND SessionId=$($x.Id)")
    \\    if ($now.Count -eq 0) {
    \\      Say "Starting Explorer in session $($x.Id), as $($x.User) (a scheduled task)..."
    \\      $name = 'koreterm-explorer-' + $x.Id
    \\      $act = New-ScheduledTaskAction -Execute 'explorer.exe'
    \\      $who = New-ScheduledTaskPrincipal -UserId $x.User -LogonType Interactive
    \\      $null = Register-ScheduledTask -CimSession $s -TaskName $name -Action $act -Principal $who -Force
    \\      Start-ScheduledTask -CimSession $s -TaskName $name
    \\      Start-Sleep -Seconds 6
    \\      try { Unregister-ScheduledTask -CimSession $s -TaskName $name -Confirm:$false } catch {}
    \\      $now = @(Get-CimInstance -CimSession $s -ClassName Win32_Process -Filter "Name='explorer.exe' AND SessionId=$($x.Id)")
    \\    }
    \\    if ($now.Count -ne 0) { Say "Done: Explorer runs in session $($x.Id) of $($x.User)." }
    \\    else { Say "Explorer did not start in session $($x.Id). Sign out user is the next step."; exit 1 }
    \\  }
    \\}
    \\
    \\function Restart($s) {
    \\  $r = Invoke-CimMethod -CimSession $s -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = 'shutdown.exe /r /f /t 0 /d p:0:0 /c "koreterm: forced restart"' }
    \\  if ($r.ReturnValue -ne 0) { Say "shutdown.exe did not start on $server (code $($r.ReturnValue))."; exit 1 }
    \\  Say "Done: $server is restarting (shutdown.exe /r /f). Its sessions end; connect again in a few minutes."
    \\}
    \\
    \\function Run($s, [string]$line) {
    \\  (Invoke-CimMethod -CimSession $s -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $line }).ReturnValue
    \\}
    \\
    \\function EventSection($s, [string]$title, [string]$query, [int]$max) {
    \\  Say ''
    \\  Say $title
    \\  try {
    \\    $ev = @(Get-CimInstance -CimSession $s -ClassName Win32_NTLogEvent -Filter $query -OperationTimeoutSec 120 | Sort-Object TimeGenerated -Descending | Select-Object -First $max)
    \\  } catch { Say ('  (could not be read: ' + $_.Exception.Message.Trim() + ')'); return }
    \\  if ($ev.Count -eq 0) { Say '  (none)'; return }
    \\  foreach ($e in $ev) {
    \\    $m = if ($e.Message) { ($e.Message -split "`r?`n")[0] } else { ($e.InsertionStrings -join ' ') }
    \\    if ($m.Length -gt 150) { $m = $m.Substring(0, 150) + '...' }
    \\    Say ('  {0:dd/MM HH:mm}  {1,5}  {2,-28} {3}' -f $e.TimeGenerated, $e.EventCode, $e.SourceName, $m)
    \\  }
    \\}
    \\
    \\function Events($s) {
    \\  $since = (Get-Date).AddHours(-48).ToUniversalTime().ToString('yyyyMMddHHmmss') + '.000000+000'
    \\  Say "The last 48 hours on $server (times in this PC's time zone)"
    \\  EventSection $s 'Restarts and shutdowns (41: it stopped without shutting down, 6008: unexpected shutdown, 1074: someone or something asked, 6005/6006: the event log started/stopped)' "Logfile='System' AND (EventCode=41 OR EventCode=6008 OR EventCode=1074 OR EventCode=6005 OR EventCode=6006) AND TimeWritten>='$since'" 20
    \\  EventSection $s 'User profile problems (1500, 1508, 1511 temporary profile, 1515, 1530 registry still in use, 1534)' "Logfile='Application' AND (EventCode=1500 OR EventCode=1508 OR EventCode=1511 OR EventCode=1515 OR EventCode=1530 OR EventCode=1534) AND TimeWritten>='$since'" 20
    \\  EventSection $s 'Errors in the System log' "Logfile='System' AND EventType=1 AND TimeWritten>='$since'" 15
    \\  EventSection $s 'Errors in the Application log' "Logfile='Application' AND EventType=1 AND TimeWritten>='$since'" 15
    \\}
    \\
    \\function Processes($s) {
    \\  $cs = Get-CimInstance -CimSession $s -ClassName Win32_ComputerSystem
    \\  $n = [math]::Max(1, [int]$cs.NumberOfLogicalProcessors)
    \\  $procs = @(Get-CimInstance -CimSession $s -ClassName Win32_Process)
    \\  $byId = @{}
    \\  foreach ($p in $procs) { $byId[[int]$p.ProcessId] = $p }
    \\  Say "Most CPU now on $server (name, pid, session, CPU, private memory)"
    \\  try {
    \\    $perf = @(Get-CimInstance -CimSession $s -ClassName Win32_PerfFormattedData_PerfProc_Process -OperationTimeoutSec 60 | Where-Object { $_.Name -ne '_Total' -and $_.Name -ne 'Idle' } | Sort-Object PercentProcessorTime -Descending | Select-Object -First 15)
    \\    foreach ($q in $perf) {
    \\      $p = $byId[[int]$q.IDProcess]
    \\      $sess = if ($p) { $p.SessionId } else { '?' }
    \\      Say ('  {0,-30} pid {1,6}  session {2,2}  {3,5}%  {4,6} MB' -f $q.Name, $q.IDProcess, $sess, [math]::Round($q.PercentProcessorTime / $n), [math]::Round($q.WorkingSetPrivate / 1MB))
    \\    }
    \\  } catch { Say '  (the CPU counters could not be read)' }
    \\  Say ''
    \\  Say 'Most memory (working set)'
    \\  foreach ($p in ($procs | Sort-Object WorkingSetSize -Descending | Select-Object -First 15)) {
    \\    Say ('  {0,-30} pid {1,6}  session {2,2}  {3,6} MB' -f $p.Name, $p.ProcessId, $p.SessionId, [math]::Round($p.WorkingSetSize / 1MB))
    \\  }
    \\  Say ''
    \\  Say 'To end one: its PID in the field, then More > End process.'
    \\}
    \\
    \\function EndProcess($s) {
    \\  if ($arg -notmatch '^\d+$') { Say 'Type the PID in the field.'; exit 1 }
    \\  $p = Get-CimInstance -CimSession $s -ClassName Win32_Process -Filter "ProcessId=$arg"
    \\  if (-not $p) { Say "No process $arg on $server."; exit 1 }
    \\  $r = Invoke-CimMethod -CimSession $s -InputObject $p -MethodName Terminate
    \\  if ($r.ReturnValue -ne 0) { Say "Process $arg did not end (code $($r.ReturnValue); 2 is access denied)."; exit 1 }
    \\  Say ('Done: ended {0} (pid {1}, session {2}) on {3}.' -f $p.Name, $arg, $p.SessionId, $server)
    \\}
    \\
    \\function Service($s, [string]$name) {
    \\  @(Get-CimInstance -CimSession $s -ClassName Win32_Service | Where-Object { $_.Name -ieq $name -or $_.DisplayName -ieq $name }) | Select-Object -First 1
    \\}
    \\
    \\function RestartService($s) {
    \\  $v = Service $s $arg
    \\  if (-not $v) { Say "No service named $arg on $server (its name as services.msc shows it, or its display name)."; exit 1 }
    \\  $name = $v.Name
    \\  if ($v.State -ne 'Stopped') {
    \\    Say "Stopping $name..."
    \\    $null = Invoke-CimMethod -CimSession $s -InputObject $v -MethodName StopService
    \\    for ($i = 0; $i -lt 15; $i++) { Start-Sleep -Seconds 2; $v = Service $s $name; if ($v.State -eq 'Stopped') { break } }
    \\    if ($v.State -ne 'Stopped') {
    \\      $own = $v.ProcessId -gt 0 -and @(Get-CimInstance -CimSession $s -ClassName Win32_Service -Filter "ProcessId=$($v.ProcessId)").Count -eq 1
    \\      if (-not $own) { Say "$name did not stop in 30 seconds, and its process holds other services too: it was left as it is."; exit 1 }
    \\      Say "$name did not stop in 30 seconds: ending its process (pid $($v.ProcessId))..."
    \\      $p = Get-CimInstance -CimSession $s -ClassName Win32_Process -Filter "ProcessId=$($v.ProcessId)"
    \\      if ($p) { $null = Invoke-CimMethod -CimSession $s -InputObject $p -MethodName Terminate }
    \\      Start-Sleep -Seconds 3
    \\    }
    \\  }
    \\  Say "Starting $name..."
    \\  $r = Invoke-CimMethod -CimSession $s -InputObject (Service $s $name) -MethodName StartService
    \\  for ($i = 0; $i -lt 15; $i++) { Start-Sleep -Seconds 2; $v = Service $s $name; if ($v.State -eq 'Running') { break } }
    \\  if ($v.State -ne 'Running') { Say "$name is $($v.State) (StartService code $($r.ReturnValue))."; exit 1 }
    \\  Say "Done: $name ($($v.DisplayName)) runs again on $server."
    \\}
    \\
    \\function StartStopped($s) {
    \\  $filter = "StartMode='Auto' AND State<>'Running'"
    \\  $list = @(Get-CimInstance -CimSession $s -ClassName Win32_Service -Filter $filter)
    \\  if ($list.Count -eq 0) { Say "Every automatic service runs on $server."; return }
    \\  Say "Starting the automatic services that are stopped on ${server}:"
    \\  foreach ($v in $list) {
    \\    $r = Invoke-CimMethod -CimSession $s -InputObject $v -MethodName StartService
    \\    $what = switch ($r.ReturnValue) { 0 { 'start asked' } 2 { 'access denied' } 10 { 'already running' } 14 { 'disabled' } 15 { 'it failed to start' } default { "code $($r.ReturnValue)" } }
    \\    Say ('  {0,-40} {1}' -f $v.Name, $what)
    \\  }
    \\  Start-Sleep -Seconds 5
    \\  $still = @(Get-CimInstance -CimSession $s -ClassName Win32_Service -Filter $filter)
    \\  Say ''
    \\  Say ('Still stopped 5 seconds later: ' + $(if ($still.Count -ne 0) { ($still | ForEach-Object { $_.Name }) -join ', ' } else { 'none' }))
    \\}
    \\
    \\function PendingRestart($s) {
    \\  $hklm = [uint32]2147483650
    \\  function Has([string]$key) {
    \\    $r = Invoke-CimMethod -CimSession $s -Namespace root/default -ClassName StdRegProv -MethodName EnumKey -Arguments @{ hDefKey = $hklm; sSubKeyName = $key }
    \\    return ($r.ReturnValue -eq 0)
    \\  }
    \\  $wu = Has 'SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    \\  $cbs = Has 'SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
    \\  $r = Invoke-CimMethod -CimSession $s -Namespace root/default -ClassName StdRegProv -MethodName GetMultiStringValue -Arguments @{ hDefKey = $hklm; sSubKeyName = 'SYSTEM\CurrentControlSet\Control\Session Manager'; sValueName = 'PendingFileRenameOperations' }
    \\  $files = ($r.ReturnValue -eq 0) -and ($r.sValue.Count -gt 0)
    \\  $os = Get-CimInstance -CimSession $s -ClassName Win32_OperatingSystem
    \\  $up = $os.LocalDateTime - $os.LastBootUpTime
    \\  $yes = { param($b) if ($b) { 'YES' } else { 'no' } }
    \\  Say ("{0}: up {1} d {2} h {3} min" -f $server, $up.Days, $up.Hours, $up.Minutes)
    \\  Say ('  Windows Update waits for a restart:         ' + (& $yes $wu))
    \\  Say ('  An installed component waits for a restart: ' + (& $yes $cbs))
    \\  Say ('  Files to replace at the next restart:       ' + (& $yes $files))
    \\  if ($wu -or $cbs) { Say ''; Say 'A pending restart can leave the server slow or half updated: More > Schedule restart sets one for a quiet hour.' }
    \\}
    \\
    \\function ScheduleRestart($s) {
    \\  if ($arg -notmatch '^(\d{1,2}):(\d{2})$') { Say 'Type the time as HH:MM in the field.'; exit 1 }
    \\  $h = [int]$Matches[1]
    \\  $m = [int]$Matches[2]
    \\  $os = Get-CimInstance -CimSession $s -ClassName Win32_OperatingSystem
    \\  # The server's own clock: UTC plus its offset.
    \\  $now = $os.LocalDateTime.ToUniversalTime().AddMinutes([int]$os.CurrentTimeZone)
    \\  $at = $now.Date.AddHours($h).AddMinutes($m)
    \\  if ($at -le $now) { $at = $at.AddDays(1) }
    \\  $secs = [int][math]::Ceiling(($at - $now).TotalSeconds)
    \\  $code = Run $s "shutdown.exe /r /f /t $secs /d p:0:0"
    \\  if ($code -ne 0) { Say "shutdown.exe did not start on $server (code $code)."; exit 1 }
    \\  Say ('Done: {0} restarts at {1:dd/MM HH:mm} by its clock, in {2} h {3} min. Users signed in are warned. More > Cancel scheduled restart undoes it.' -f $server, $at, [math]::Floor($secs / 3600), [math]::Floor(($secs % 3600) / 60))
    \\}
    \\
    \\function CancelShutdown($s) {
    \\  $code = Run $s 'shutdown.exe /a'
    \\  if ($code -ne 0) { Say "shutdown.exe did not start on $server (code $code)."; exit 1 }
    \\  Say "Sent shutdown /a to ${server}: a restart or shutdown scheduled there is cancelled (when none was, nothing changes)."
    \\}
    \\
    \\function Disconnect($s) {
    \\  foreach ($x in (Find $s)) {
    \\    $code = Run $s "tsdiscon.exe $($x.Id)"
    \\    if ($code -ne 0) { Say "tsdiscon.exe did not start on $server (code $code)."; exit 1 }
    \\    Say "Disconnected session $($x.Id) of $($x.User): its programs keep running, and connecting again goes back to it."
    \\  }
    \\}
    \\
    \\function LargestFolders {
    \\  $root = if ($arg) { $arg } else { 'C:\' }
    \\  $p = @{ ComputerName = $server; ErrorAction = 'Stop'; ArgumentList = @($root); ScriptBlock = {
    \\    param($root)
    \\    $script:partial = $false
    \\    $sw = [Diagnostics.Stopwatch]::StartNew()
    \\    function Size([string]$path) {
    \\      $total = [int64]0
    \\      $stack = New-Object 'System.Collections.Generic.Stack[string]'
    \\      $stack.Push($path)
    \\      while ($stack.Count -gt 0) {
    \\        if ($sw.Elapsed.TotalSeconds -gt 100) { $script:partial = $true; break }
    \\        $dir = $stack.Pop()
    \\        try {
    \\          foreach ($e in ([IO.DirectoryInfo]$dir).EnumerateFileSystemInfos()) {
    \\            if ($e -is [IO.FileInfo]) { $total += $e.Length }
    \\            elseif (-not ($e.Attributes -band [IO.FileAttributes]::ReparsePoint)) { $stack.Push($e.FullName) }
    \\          }
    \\        } catch {}
    \\      }
    \\      $total
    \\    }
    \\    $dirs = @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue | Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) })
    \\    $rows = foreach ($d in $dirs) { [pscustomobject]@{ Name = $d.Name; Bytes = (Size $d.FullName) } }
    \\    $files = [int64](Get-ChildItem -LiteralPath $root -File -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
    \\    "Largest folders in $root on $env:COMPUTERNAME" + $(if ($script:partial) { ' (counting stopped after 100 seconds: the sizes are at least these)' } else { '' })
    \\    $drive = Get-PSDrive -Name $root.Substring(0, 1) -PSProvider FileSystem -ErrorAction SilentlyContinue
    \\    if ($drive) { 'Drive {0}: {1:N1} GB free of {2:N1} GB' -f $drive.Name, ($drive.Free / 1GB), (($drive.Used + $drive.Free) / 1GB) }
    \\    ''
    \\    foreach ($r in ($rows | Sort-Object Bytes -Descending | Select-Object -First 20)) { '  {0,9:N1} GB  {1}' -f ($r.Bytes / 1GB), $r.Name }
    \\    '  {0,9:N1} GB  (files right in {1})' -f ($files / 1GB), $root
    \\  } }
    \\  if ($ssl) { $p.UseSSL = $true }
    \\  if ($cred) { $p.Credential = $cred }
    \\  $out = Invoke-Command @p | Out-String -Width 200
    \\  [Console]::Out.Write($out)
    \\}
    \\
    \\try {
    \\  # Counting folders needs PowerShell remoting (WinRM): CIM cannot.
    \\  if ($action -eq 'largest_folders') { LargestFolders; exit 0 }
    \\  $c = Connect
    \\  $s = $c.Session
    \\  switch ($action) {
    \\    'status' { Status $s $c.Protocol }
    \\    'sign_out' { SignOut $s }
    \\    'explorer' { Explorer $s }
    \\    'restart' { Restart $s }
    \\    'events' { Events $s }
    \\    'processes' { Processes $s }
    \\    'end_process' { EndProcess $s }
    \\    'restart_service' { RestartService $s }
    \\    'start_stopped_services' { StartStopped $s }
    \\    'pending_restart' { PendingRestart $s }
    \\    'schedule_restart' { ScheduleRestart $s }
    \\    'cancel_shutdown' { CancelShutdown $s }
    \\    'disconnect' { Disconnect $s }
    \\  }
    \\  exit 0
    \\} catch {
    \\  Say $_.Exception.Message.Trim()
    \\  Say ''
    \\  Say (Ports $server)
    \\  exit 1
    \\}
;

const Job = struct {
    process: HANDLE,
    stdout: HANDLE,
    started_ms: i64 = 0,

    /// Start a hidden PowerShell on `script` and hand it `fields` on its
    /// standard input (`encodeLines`).
    fn start(alloc: Allocator, script: []const u8, fields: []const []const u8) !Job {
        const HANDLE_FLAG_INHERIT: u32 = 0x1;
        const attributes: SECURITY_ATTRIBUTES = .{ .nLength = @sizeOf(SECURITY_ATTRIBUTES), .bInheritHandle = 1 };
        var in_read: ?HANDLE = null;
        var in_write: ?HANDLE = null;
        // Room for the whole input: the write never waits for PowerShell.
        if (CreatePipe(&in_read, &in_write, &attributes, 64 * 1024) == 0) return error.PipeFailed;
        defer _ = CloseHandle(in_read);
        var in_write_open = true;
        defer if (in_write_open) {
            _ = CloseHandle(in_write);
        };
        var out_read: ?HANDLE = null;
        var out_write: ?HANDLE = null;
        if (CreatePipe(&out_read, &out_write, &attributes, 64 * 1024) == 0) return error.PipeFailed;
        defer _ = CloseHandle(out_write);
        var out_read_kept = false;
        defer if (!out_read_kept) {
            _ = CloseHandle(out_read);
        };
        // This side's ends stay out of the child.
        _ = SetHandleInformation(in_write.?, HANDLE_FLAG_INHERIT, 0);
        _ = SetHandleInformation(out_read.?, HANDLE_FLAG_INHERIT, 0);

        const parameters = try encodedParameters(alloc, script, "");
        defer alloc.free(parameters);
        const command_line = try std.mem.concatWithSentinel(alloc, u16, &.{ L("powershell.exe "), parameters }, 0);
        defer alloc.free(command_line);
        const STARTF_USESHOWWINDOW: u32 = 0x1;
        const STARTF_USESTDHANDLES: u32 = 0x100;
        var si: STARTUPINFOW = .{
            .cb = @sizeOf(STARTUPINFOW),
            .dwFlags = STARTF_USESHOWWINDOW | STARTF_USESTDHANDLES,
            .wShowWindow = 0,
            .hStdInput = in_read,
            .hStdOutput = out_write,
            .hStdError = out_write,
        };
        var pi: PROCESS_INFORMATION = undefined;
        const CREATE_NO_WINDOW: u32 = 0x08000000;
        if (CreateProcessW(null, command_line.ptr, null, null, 1, CREATE_NO_WINDOW, null, null, &si, &pi) == 0) return error.ProcessFailed;
        _ = CloseHandle(pi.hThread);
        const process = pi.hProcess orelse return error.ProcessFailed;

        const input = try encodeLines(alloc, fields);
        defer {
            @memset(input, 0);
            alloc.free(input);
        }
        var written: u32 = 0;
        if (WriteFile(in_write.?, input.ptr, @intCast(input.len), &written, null) == 0 or written != input.len) {
            _ = TerminateProcess(process, 1);
            _ = CloseHandle(process);
            return error.PipeFailed;
        }
        // Closed: PowerShell reads to the end of its input.
        _ = CloseHandle(in_write);
        in_write_open = false;
        out_read_kept = true;
        return .{ .process = process, .stdout = out_read.?, .started_ms = std.time.milliTimestamp() };
    }

    /// What the process wrote so far, up to `output_max_len` in all.
    fn drain(self: Job, alloc: Allocator, output: *std.ArrayListUnmanaged(u8)) void {
        var buf: [4096]u8 = undefined;
        while (true) {
            var available: u32 = 0;
            if (PeekNamedPipe(self.stdout, null, 0, null, &available, null) == 0 or available == 0) return;
            var got: u32 = 0;
            if (ReadFile(self.stdout, &buf, @min(available, buf.len), &got, null) == 0 or got == 0) return;
            const room = output_max_len -| output.items.len;
            output.appendSlice(alloc, buf[0..@min(room, got)]) catch return;
        }
    }

    fn stop(self: Job) void {
        _ = TerminateProcess(self.process, 1);
        self.close();
    }

    fn close(self: Job) void {
        _ = CloseHandle(self.process);
        _ = CloseHandle(self.stdout);
    }
};

/// `-NoProfile -NonInteractive -ExecutionPolicy Bypass <extra>-EncodedCommand
/// <script as base64 UTF-16>`, NUL-terminated UTF-16, in `alloc`.
fn encodedParameters(alloc: Allocator, script: []const u8, extra: []const u8) ![:0]u16 {
    const script_w = try std.unicode.utf8ToUtf16LeAlloc(alloc, script);
    defer alloc.free(script_w);
    const bytes = std.mem.sliceAsBytes(script_w);
    const encoder = std.base64.standard.Encoder;
    const encoded = try alloc.alloc(u8, encoder.calcSize(bytes.len));
    defer alloc.free(encoded);
    _ = encoder.encode(encoded, bytes);
    const line = try std.fmt.allocPrint(alloc, "-NoProfile -NonInteractive -ExecutionPolicy Bypass {s}-EncodedCommand {s}", .{ extra, encoded });
    defer alloc.free(line);
    return std.unicode.utf8ToUtf16LeAllocZ(alloc, line);
}

/// The scripts' input lines: each field as base64 of its UTF-8 and CRLF. In
/// `alloc`; the caller zeroes it (it holds the password).
pub fn encodeLines(alloc: Allocator, fields: []const []const u8) Allocator.Error![]u8 {
    const encoder = std.base64.standard.Encoder;
    var size: usize = 0;
    for (fields) |field| size += encoder.calcSize(field.len) + 2;
    const out = try alloc.alloc(u8, size);
    var at: usize = 0;
    for (fields) |field| {
        const n = encoder.calcSize(field.len);
        _ = encoder.encode(out[at..][0..n], field);
        at += n;
        out[at] = '\r';
        out[at + 1] = '\n';
        at += 2;
    }
    return out;
}

test "rdp command: a restart or a shutdown is recognized, other commands are not" {
    try std.testing.expect(stopsComputer("shutdown.exe /r /t 0"));
    try std.testing.expect(stopsComputer("SHUTDOWN -s -t 60"));
    try std.testing.expect(stopsComputer("Restart-Computer -Force"));
    try std.testing.expect(stopsComputer("stop-computer"));
    try std.testing.expect(!stopsComputer("shutdown /a"));
    try std.testing.expect(!stopsComputer("explorer.exe"));
    try std.testing.expect(!stopsComputer("Restart-Service Spooler"));
    try std.testing.expect(!stopsComputer("services.msc /s"));
}

test "rdp command: a PowerShell window's command is quoted as the command line reads it back" {
    const alloc = std.testing.allocator;
    const plain = try powershellWindowLine(alloc, "Get-Service");
    defer alloc.free(plain);
    try std.testing.expectEqualStrings("powershell.exe -NoExit -Command \"Get-Service\"", plain);
    const quoted = try powershellWindowLine(alloc, "Write-Host \"a\\\" C:\\dir\\");
    defer alloc.free(quoted);
    try std.testing.expectEqualStrings("powershell.exe -NoExit -Command \"Write-Host \\\"a\\\\\\\" C:\\dir\\\\\"", quoted);
}

test "rdp command: the input is one base64 line a field" {
    const alloc = std.testing.allocator;
    const input = try encodeLines(alloc, &.{ "srv", "u", "", "dir", "1" });
    defer alloc.free(input);
    try std.testing.expectEqualStrings("c3J2\r\ndQ==\r\n\r\nZGly\r\nMQ==\r\n", input);
}

test "rdp command: a blank password takes the one kept for the user name" {
    const remote: Remote = .{ .server = "srv", .user = "robo", .password = "p1", .admin_user = "CORP\\admin", .admin_password = "p2" };
    try std.testing.expectEqualStrings("p2", keptPassword(remote, "corp\\ADMIN").?);
    try std.testing.expectEqualStrings("p1", keptPassword(remote, "Robo").?);
    try std.testing.expect(keptPassword(remote, "other") == null);
    try std.testing.expect(keptPassword(.{ .server = "srv" }, "") == null);
}

test "rdp command: CLIXML records are taken out of the output" {
    const alloc = std.testing.allocator;
    const text = "#< CLIXML\r\nFalha ao conectar ao servidor.<Objs Version=\"1.1.0.1\"><Obj S=\"progress\"></Obj></Objs>\nmore";
    const clean = try withoutClixml(alloc, text);
    defer alloc.free(clean);
    try std.testing.expectEqualStrings("Falha ao conectar ao servidor.\nmore", clean);
    const plain = try withoutClixml(alloc, "nothing to take");
    defer alloc.free(plain);
    try std.testing.expectEqualStrings("nothing to take", plain);
    const cut = try withoutClixml(alloc, "a<Objs never closed");
    defer alloc.free(cut);
    try std.testing.expectEqualStrings("a", cut);
}

test "rdp command: TrustedHosts takes host names and addresses only" {
    try std.testing.expect(trustableName("packetzone.minhacnd.com.br"));
    try std.testing.expect(trustableName("10.0.0.5"));
    try std.testing.expect(trustableName("fe80::1"));
    try std.testing.expect(!trustableName("srv'; Remove-Item x"));
    try std.testing.expect(!trustableName(""));
}

test "rdp command: SHELLEXECUTEINFOW matches the SDK" {
    if (builtin.cpu.arch != .x86_64 and builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    try std.testing.expectEqual(@as(usize, 112), @sizeOf(SHELLEXECUTEINFOW));
    try std.testing.expectEqual(@as(usize, 104), @offsetOf(SHELLEXECUTEINFOW, "hProcess"));
    try std.testing.expectEqual(@as(usize, 48), @offsetOf(SHELLEXECUTEINFOW, "nShow"));
}

test "rdp command: the template is DWORD aligned and counts every item" {
    const template = try buildTemplate(std.testing.allocator);
    defer std.testing.allocator.free(template);
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(template.ptr) % 4);
    // Intro; the login's two labels, two fields, note and box; three modes
    // and HTTPS; the command's label and field; five presets; the Server
    // group, its two labels and two fields, four buttons and More; the
    // result's label and field; and the four bottom buttons.
    try std.testing.expectEqual(@as(u16, 1 + 6 + 4 + 2 + 5 + 5 + 5 + 2 + 4), std.mem.readInt(u16, template[8..10], .little));
}

test "rdp command: an action's field is checked before it runs" {
    try std.testing.expect(argumentProblem(.end_process, "4312") == null);
    try std.testing.expect(argumentProblem(.end_process, "explorer") != null);
    try std.testing.expect(argumentProblem(.restart_service, "Spooler") == null);
    try std.testing.expect(argumentProblem(.restart_service, "Print Spooler") == null);
    try std.testing.expect(argumentProblem(.restart_service, "x'; Stop-Computer") != null);
    try std.testing.expect(argumentProblem(.restart_service, "") != null);
    try std.testing.expect(argumentProblem(.schedule_restart, "3:30") == null);
    try std.testing.expect(argumentProblem(.schedule_restart, "23:59") == null);
    try std.testing.expect(argumentProblem(.schedule_restart, "24:00") != null);
    try std.testing.expect(argumentProblem(.schedule_restart, "3:3") != null);
    try std.testing.expect(argumentProblem(.largest_folders, "") == null);
    try std.testing.expect(argumentProblem(.status, "anything") == null);
    try std.testing.expectEqual(@as(u8, 3), parseTime("03:30").?.hour);
}

test "rdp command: Prepare server's line fits the Run box and its script takes the port" {
    try std.testing.expect(prepare_line.len <= run_box_max_len);
    const script = try prepareScript(std.testing.allocator, 3390);
    defer std.testing.allocator.free(script);
    try std.testing.expect(std.mem.startsWith(u8, script, "#koreterm-prepare"));
    try std.testing.expect(std.mem.indexOf(u8, script, "$port = 3390") != null);
    try std.testing.expect(std.mem.indexOf(u8, script, "@PORT@") == null);
}

test "rdp command: every More item names an action once, and Prepare" {
    var seen = std.EnumSet(Action).initEmpty();
    var prepare: usize = 0;
    for (more_items) |item| {
        if (item.pick) |action| {
            try std.testing.expect(@intFromEnum(action) >= Action.buttons);
            try std.testing.expect(!seen.contains(action));
            seen.insert(action);
        } else prepare += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), prepare);
    try std.testing.expectEqual(@as(usize, std.meta.fields(Action).len - Action.buttons), seen.count());
}
