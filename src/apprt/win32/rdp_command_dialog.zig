//! The modal window behind a Remote Desktop tab's "Run Command on Remote
//! Desktop...": a command, how to send it, a few ready-made ones, and what
//! came of it.
//!
//! Three ways to send it:
//! - **Run box**: typed into the remote desktop's Run box (Win+R, paste,
//!   Enter) by the pane (`rdp_pane.Pane.typeRunLine`), on the screen of the
//!   session. The window closes first, so the keys reach the session; the
//!   tab's banner says how it went. koreterm sees only that the keys went:
//!   not whether the program started.
//! - **PowerShell window**: the same, with the command wrapped in
//!   `powershell.exe -NoExit -Command "..."`, so it runs in a PowerShell
//!   window on the remote screen.
//! - **PowerShell on the server (WinRM)**: `Invoke-Command` from this PC,
//!   signed in with the connection's login (`runRemoting`). The window
//!   stays open and shows whether it ran and its output: the one way that
//!   proves the command ran. It runs in a background session of the server,
//!   not on its screen, and needs PowerShell remoting there.
//!
//! "Open Task Manager" sends Ctrl+Shift+Esc, which works when Explorer, and
//! with it the Run box, is gone. A command that restarts or shuts down the
//! computer (`stopsComputer`) is asked about first.
//!
//! Nothing here logs a command, a server, a user name or a password. The
//! password reaches the PowerShell process through its standard input, never
//! its command line.
const std = @import("std");
const Allocator = std.mem.Allocator;

const win32_types = @import("../win32_types.zig");

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
    user: []const u8 = "",
    password: ?[]const u8 = null,
    /// The tab's name, for the window's title.
    title: []const u8 = "",
};

/// What the caller sends into the session once the window has closed.
pub const Request = union(enum) {
    none,
    /// A line for the remote Run box, in the `alloc` given to `run`.
    run_line: []const u8,
    /// Ctrl+Shift+Esc.
    task_manager,
};

/// The Run box takes a line of up to 259 characters.
pub const run_box_max_len: usize = 259;
/// What a WinRM command may hold, and what of its output is kept.
const remoting_command_max_len: usize = 16 * 1024;
const output_max_len: usize = 64 * 1024;
/// How long a WinRM command may take before the window stops it.
const remoting_timeout_ms: i64 = 120 * std.time.ms_per_s;

pub const Mode = enum { run_box, powershell_window, remoting };

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

const intro_text = L("Sends a command to this remote desktop. Run box and PowerShell window type it into the session (Win+R), on its screen: koreterm sees only that the keys went, so check the session. PowerShell on the server runs it through WinRM and shows whether it ran and its output, but not on the screen.");
const tips_text = L("Run box: explorer.exe (Explorer and the taskbar), taskmgr.exe, services.msc, eventvwr.msc, compmgmt.msc, control.exe, cmd.exe.\r\n" ++
    "Explorer gone (black screen, no taskbar)? Win+R needs Explorer: use Open Task Manager, then Run new task, explorer.exe.\r\n" ++
    "PowerShell: Restart-Service Spooler, Get-Service, Get-Process, Restart-Computer -Force. The command goes through this PC's clipboard.");

const IDOK: u16 = 1;
const IDCANCEL: u16 = 2;
const id_mode_run: u16 = 140;
const id_mode_window: u16 = 141;
const id_mode_remoting: u16 = 142;
const id_command: u16 = 143;
const id_output: u16 = 144;
const id_task_manager: u16 = 145;
const id_preset_first: u16 = 150; // + @intFromEnum(Preset)
const job_timer: usize = 0x524A; // "RJ"

const DWLP_USER: i32 = @sizeOf(usize) * 2;
const WM_INITDIALOG: UINT = 0x0110;
const WM_COMMAND: UINT = 0x0111;
const WM_CLOSE: UINT = 0x0010;
const WM_TIMER: UINT = 0x0113;
const BN_CLICKED: u16 = 0;
const BST_CHECKED: u32 = 1;

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
extern "user32" fn SetTimer(hwnd: ?HWND, id: usize, ms: u32, proc: ?*const anyopaque) callconv(.winapi) usize;
extern "user32" fn KillTimer(hwnd: ?HWND, id: usize) callconv(.winapi) BOOL;
extern "kernel32" fn GetModuleHandleW(name: ?LPCWSTR) callconv(.winapi) ?HINSTANCE;

const State = struct {
    alloc: Allocator,
    remote: Remote,
    title: [:0]const u16,
    request: Request = .none,
    job: ?Job = null,
    output: std.ArrayListUnmanaged(u8) = .empty,
};

/// Show the window over `owner` until it is closed. What it returns, the
/// caller sends into the session (`Request`); a WinRM command has already
/// run by then.
pub fn run(alloc: Allocator, owner: ?HWND, remote: Remote) Allocator.Error!Request {
    const template = try buildTemplate(alloc);
    defer alloc.free(template);
    const shown = if (remote.title.len != 0) remote.title else remote.server;
    const title_text = try std.fmt.allocPrint(alloc, "Run command: {s}", .{shown});
    defer alloc.free(title_text);
    const title = try std.unicode.utf8ToUtf16LeAllocZ(alloc, title_text);
    defer alloc.free(title);
    var state: State = .{ .alloc = alloc, .remote = remote, .title = title };
    defer state.output.deinit(alloc);
    _ = DialogBoxIndirectParamW(GetModuleHandleW(null), template.ptr, owner, dialogProc, @bitCast(@intFromPtr(&state)));
    // A job the window's close did not stop (it always does): stopped here.
    if (state.job) |job| job.stop();
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

fn buildTemplate(alloc: Allocator) Allocator.Error![]align(4) u8 {
    // Its labels are UTF-16 literals made at compile time.
    @setEvalBranchQuota(20000);
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
    const BS_AUTORADIOBUTTON: u32 = 0x9;
    const BS_DEFPUSHBUTTON: u32 = 0x1;
    const button: u16 = 0x0080;
    const edit_atom: u16 = 0x0081;
    const static: u16 = 0x0082;

    const w: i16 = 340;
    const h: i16 = 330;
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
    try t.wstr(L("Run command"));
    try t.int(u16, 9);
    try t.wstr(L("Segoe UI"));

    var y: i16 = 7;
    try t.item(child, 7, y, inner, 42, 0xFFFF, static, intro_text);
    y += 46;
    try t.item(child | WS_TABSTOP | WS_GROUP | BS_AUTORADIOBUTTON, 7, y, inner, 10, id_mode_run, button, L("R&un box (Win+R), on the remote screen"));
    y += 12;
    try t.item(child | BS_AUTORADIOBUTTON, 7, y, inner, 10, id_mode_window, button, L("PowerShell &window (Win+R), on the remote screen"));
    y += 12;
    try t.item(child | BS_AUTORADIOBUTTON, 7, y, inner, 10, id_mode_remoting, button, L("PowerShell on the ser&ver (WinRM), with the result"));
    y += 16;
    try t.item(child, 7, y, inner, 9, 0xFFFF, static, L("&Command"));
    y += 10;
    try t.item(child | WS_TABSTOP | WS_GROUP | WS_BORDER | ES_AUTOHSCROLL, 7, y, inner, 13, id_command, edit_atom, L(""));
    y += 18;
    const preset_w: i16 = 60;
    const preset_gap: i16 = @divTrunc(inner - preset_w * @as(i16, preset_labels.len), @as(i16, preset_labels.len - 1));
    for (preset_labels, 0..) |label, i| {
        const style = child | WS_TABSTOP | if (i == 0) WS_GROUP else 0;
        try t.item(style, 7 + @as(i16, @intCast(i)) * (preset_w + preset_gap), y, preset_w, 14, id_preset_first + @as(u16, @intCast(i)), button, label);
    }
    y += 19;
    try t.item(child, 7, y, inner, 58, 0xFFFF, static, tips_text);
    y += 62;
    try t.item(child, 7, y, inner, 9, 0xFFFF, static, L("Result"));
    y += 10;
    try t.item(child | WS_TABSTOP | WS_GROUP | WS_BORDER | WS_VSCROLL | ES_MULTILINE | ES_AUTOVSCROLL | ES_READONLY, 7, y, inner, h - 25 - y, id_output, edit_atom, L(""));
    try t.item(child | WS_TABSTOP | WS_GROUP, 7, h - 21, 96, 14, id_task_manager, button, L("Open &Task Manager"));
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

fn say(hwnd: HWND, text: []const u8) void {
    var buf: [512]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(buf[0 .. buf.len - 1], text) catch return;
    buf[n] = 0;
    _ = MessageBoxW(hwnd, buf[0..n :0].ptr, L("Run command"), 0x30);
}

fn focusCommand(hwnd: HWND) void {
    if (GetDlgItem(hwnd, id_command)) |control| _ = SetFocus(control);
}

fn dialogProc(hwnd: HWND, msg: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) isize {
    switch (msg) {
        WM_INITDIALOG => {
            _ = SetWindowLongPtrW(hwnd, DWLP_USER, lparam);
            const state = stateOf(hwnd) orelse return 1;
            _ = SetWindowTextW(hwnd, state.title.ptr);
            _ = CheckRadioButton(hwnd, id_mode_run, id_mode_remoting, id_mode_run);
            setText(hwnd, id_output, state.alloc, "Nothing sent yet.");
            focusCommand(hwnd);
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
                    if (state.job != null) return 1;
                    state.request = .task_manager;
                    _ = EndDialog(hwnd, IDOK);
                    return 1;
                },
                else => {
                    if (code != BN_CLICKED) return 0;
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

/// Close, or Escape: a WinRM command still running is stopped.
fn close(hwnd: HWND, state: *State) void {
    if (state.job) |job| {
        _ = KillTimer(hwnd, job_timer);
        job.stop();
        state.job = null;
    }
    _ = EndDialog(hwnd, IDCANCEL);
}

/// Send: checked, asked about when it would restart or shut the computer
/// down, then handed to the caller (Run box, PowerShell window) or run here
/// (WinRM).
fn send(hwnd: HWND, state: *State) void {
    if (state.job != null) return;
    const alloc = state.alloc;
    const command = readText(hwnd, id_command, alloc) orelse return;
    defer alloc.free(command);
    if (command.len == 0) {
        say(hwnd, "Type a command, or pick one of the buttons under the field.");
        return focusCommand(hwnd);
    }
    const mode = modeOf(hwnd);
    if (stopsComputer(command)) {
        const MB_YESNO: u32 = 0x4;
        const MB_ICONWARNING: u32 = 0x30;
        const MB_DEFBUTTON2: u32 = 0x100;
        const IDYES: i32 = 6;
        const question = std.fmt.allocPrint(alloc, "This restarts or shuts down {s}. Everyone signed in to it is signed out and loses what they have not saved, and this session ends.\n\nSend it?", .{state.remote.server}) catch return;
        defer alloc.free(question);
        const question_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, question) catch return;
        defer alloc.free(question_w);
        if (MessageBoxW(hwnd, question_w.ptr, L("Restart the remote computer?"), MB_YESNO | MB_ICONWARNING | MB_DEFBUTTON2) != IDYES) return focusCommand(hwnd);
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
            state.output.clearRetainingCapacity();
            const job = Job.start(alloc, state.remote, command) catch {
                setText(hwnd, id_output, alloc, "PowerShell could not be started on this PC, so nothing ran.");
                return;
            };
            state.job = job;
            const running = std.fmt.allocPrint(alloc, "Running on {s} through PowerShell remoting...", .{state.remote.server}) catch return;
            defer alloc.free(running);
            setText(hwnd, id_output, alloc, running);
            if (GetDlgItem(hwnd, IDOK)) |button| _ = EnableWindow(button, 0);
            _ = SetTimer(hwnd, job_timer, 250, null);
        },
    }
}

/// The running WinRM job's output so far; once it is over, what came of it.
fn poll(hwnd: HWND, state: *State) void {
    const job = state.job orelse return;
    job.drain(state.alloc, &state.output);
    const WAIT_OBJECT_0: u32 = 0;
    if (WaitForSingleObject(job.process, 0) != WAIT_OBJECT_0) {
        if (std.time.milliTimestamp() - job.started_ms < remoting_timeout_ms) return;
        job.stop();
        return finish(hwnd, state, .timed_out);
    }
    job.drain(state.alloc, &state.output);
    var code: u32 = 1;
    _ = GetExitCodeProcess(job.process, &code);
    job.close();
    finish(hwnd, state, if (code == 0) .ran else .failed);
}

fn finish(hwnd: HWND, state: *State, outcome: enum { ran, failed, timed_out }) void {
    _ = KillTimer(hwnd, job_timer);
    state.job = null;
    const alloc = state.alloc;
    const output = std.mem.trim(u8, state.output.items, " \t\r\n");
    const text = switch (outcome) {
        .ran => std.fmt.allocPrint(alloc, "Done: the command ran on {s}.\n\n{s}", .{ state.remote.server, if (output.len == 0) "(no output)" else output }),
        .failed => std.fmt.allocPrint(alloc, "It did not run, or it failed, on {s}:\n\n{s}\n\nPowerShell remoting needs WinRM on the server (Enable-PSRemoting, as administrator there). For a server outside your domain, or named by its IP address, this PC needs it in TrustedHosts (Set-Item WSMan:\\localhost\\Client\\TrustedHosts, as administrator here).", .{ state.remote.server, if (output.len == 0) "(no message)" else output }),
        .timed_out => std.fmt.allocPrint(alloc, "No answer from {s} after 2 minutes: stopped. Whether the command ran there is not known.", .{state.remote.server}),
    } catch return;
    defer alloc.free(text);
    setText(hwnd, id_output, alloc, text);
    if (GetDlgItem(hwnd, IDOK)) |button| _ = EnableWindow(button, 1);
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

// --- PowerShell remoting ---------------------------------------------------

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

/// What the hidden PowerShell runs: four lines on its standard input, each
/// base64 of UTF-8 (server, user, password, command), then `Invoke-Command`.
/// Exit 0 when it ran, 1 with the error's message when it did not.
const remoting_script =
    \\$ErrorActionPreference = 'Stop'
    \\[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    \\function D([string]$s) { [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($s)) }
    \\$server = D ([Console]::In.ReadLine())
    \\$user = D ([Console]::In.ReadLine())
    \\$pass = D ([Console]::In.ReadLine())
    \\$command = D ([Console]::In.ReadLine())
    \\try {
    \\  $p = @{ ComputerName = $server; ScriptBlock = [ScriptBlock]::Create($command); ErrorAction = 'Stop' }
    \\  if ($user -ne '' -and $pass -ne '') {
    \\    $secure = ConvertTo-SecureString $pass -AsPlainText -Force
    \\    $p.Credential = New-Object System.Management.Automation.PSCredential($user, $secure)
    \\  }
    \\  $out = Invoke-Command @p 2>&1 | Out-String -Width 160
    \\  [Console]::Out.Write($out)
    \\  exit 0
    \\} catch {
    \\  [Console]::Out.Write($_.Exception.Message)
    \\  exit 1
    \\}
;

const Job = struct {
    process: HANDLE,
    stdout: HANDLE,
    started_ms: i64 = 0,

    /// Start the hidden PowerShell and hand it the connection and the
    /// command on its standard input.
    fn start(alloc: Allocator, remote: Remote, command: []const u8) !Job {
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

        const command_line = try remotingCommandLine(alloc);
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

        const input = try remotingInput(alloc, remote, command);
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

/// `powershell.exe ... -EncodedCommand <remoting_script as base64 UTF-16>`,
/// NUL-terminated UTF-16, in `alloc`.
fn remotingCommandLine(alloc: Allocator) ![:0]u16 {
    const script_w = try std.unicode.utf8ToUtf16LeAlloc(alloc, remoting_script);
    defer alloc.free(script_w);
    const bytes = std.mem.sliceAsBytes(script_w);
    const encoder = std.base64.standard.Encoder;
    const encoded = try alloc.alloc(u8, encoder.calcSize(bytes.len));
    defer alloc.free(encoded);
    _ = encoder.encode(encoded, bytes);
    const line = try std.fmt.allocPrint(alloc, "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand {s}", .{encoded});
    defer alloc.free(line);
    return std.unicode.utf8ToUtf16LeAllocZ(alloc, line);
}

/// The script's four input lines: server, user, password, command, each
/// base64 of its UTF-8. In `alloc`; the caller zeroes it (it holds the
/// password).
pub fn remotingInput(alloc: Allocator, remote: Remote, command: []const u8) Allocator.Error![]u8 {
    const encoder = std.base64.standard.Encoder;
    const fields = [_][]const u8{ remote.server, remote.user, remote.password orelse "", command };
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

test "rdp command: the remoting input is four base64 lines" {
    const alloc = std.testing.allocator;
    const input = try remotingInput(alloc, .{ .server = "srv", .user = "u", .password = null }, "dir");
    defer alloc.free(input);
    try std.testing.expectEqualStrings("c3J2\r\ndQ==\r\n\r\nZGly\r\n", input);
}

test "rdp command: the template is DWORD aligned and counts every item" {
    const template = try buildTemplate(std.testing.allocator);
    defer std.testing.allocator.free(template);
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(template.ptr) % 4);
    // Intro, three modes, the label and field, five presets, tips, the
    // result's label and field, and the three buttons.
    try std.testing.expectEqual(@as(u16, 1 + 3 + 2 + 5 + 1 + 2 + 3), std.mem.readInt(u16, template[8..10], .little));
}
