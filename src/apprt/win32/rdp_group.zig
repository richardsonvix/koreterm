//! A group of Remote Desktop sessions watched together in one tab: a grid
//! that fills the tab, one cell a session, each under a strip with its name,
//! "Interact" and "Ungroup". A session joins from its own tab's menu (Add to
//! Group) and leaves with Ungroup, back to a tab of its own. The grid is
//! square, 2 x 2 to start, and grows a step when it is full (a fifth
//! session makes it 3 x 3); free cells say so. Closing the
//! group's tab lets every session go back to its own tab, none is closed.
//!
//! A watched session is light: the mouse and keys do not reach it until
//! Interact, its sound plays nowhere, the visual quality is the fastest,
//! compression is on, and its desktop starts at the monitor's size, scaled
//! down into its cell (Fit all; Keep size on its strip gives back the size
//! it had). The colors
//! are the group's choice (256, 65 thousand or 16 million), capped by how
//! many sessions are watched and by how busy koreterm is: a sample of the
//! process's CPU every few seconds raises or lowers an automatic level,
//! which first shrinks the remote desktops (no reconnect) and then lowers
//! the colors (a reconnect, so at most once a minute). A session that leaves
//! goes back to its connection's own settings.
//!
//! The group itself only knows its sessions (`rdp_pane.Pane`); the tab that
//! shows it opens a tab for a session that leaves (`Hooks.release`).
const std = @import("std");
const Allocator = std.mem.Allocator;

const win32_types = @import("../win32_types.zig");
const rdp_pane = @import("rdp_pane.zig");

const BOOL = win32_types.BOOL;
const HWND = win32_types.HWND;
const HINSTANCE = win32_types.HINSTANCE;
const LPARAM = win32_types.LPARAM;
const LPCWSTR = win32_types.LPCWSTR;
const LRESULT = win32_types.LRESULT;
const UINT = win32_types.UINT;
const WPARAM = win32_types.WPARAM;
const RECT = win32_types.RECT;
const PAINTSTRUCT = win32_types.PAINTSTRUCT;
const WNDCLASSEXW = win32_types.WNDCLASSEXW;
const MONITORINFO = win32_types.MONITORINFO;

const MONITOR_DEFAULTTONEAREST: u32 = 2;

/// winuser.h's TRACKMOUSEEVENT (24 bytes on 64-bit targets, pinned below).
const TRACKMOUSEEVENT = extern struct {
    cbSize: u32 = @sizeOf(TRACKMOUSEEVENT),
    dwFlags: u32,
    hwndTrack: HWND,
    dwHoverTime: u32,
};
const TME_HOVER: u32 = 0x1;
const TME_LEAVE: u32 = 0x2;

const L = std.unicode.utf8ToUtf16LeStringLiteral;
const log = std.log.scoped(.win32_rdp_group);

extern "user32" fn RegisterClassExW(class: *const WNDCLASSEXW) callconv(.winapi) u16;
extern "user32" fn CreateWindowExW(ex: u32, class: LPCWSTR, name: LPCWSTR, style: u32, x: i32, y: i32, w: i32, h: i32, parent: ?HWND, menu: ?*anyopaque, inst: ?HINSTANCE, param: ?*anyopaque) callconv(.winapi) ?HWND;
extern "user32" fn DestroyWindow(hwnd: HWND) callconv(.winapi) BOOL;
extern "user32" fn DefWindowProcW(hwnd: HWND, msg: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT;
extern "user32" fn MoveWindow(hwnd: HWND, x: i32, y: i32, w: i32, h: i32, repaint: BOOL) callconv(.winapi) BOOL;
extern "user32" fn GetClientRect(hwnd: HWND, rect: *RECT) callconv(.winapi) BOOL;
extern "user32" fn InvalidateRect(hwnd: HWND, rect: ?*const RECT, erase: BOOL) callconv(.winapi) BOOL;
extern "user32" fn BeginPaint(hwnd: HWND, ps: *PAINTSTRUCT) callconv(.winapi) ?*anyopaque;
extern "user32" fn EndPaint(hwnd: HWND, ps: *const PAINTSTRUCT) callconv(.winapi) BOOL;
extern "user32" fn FillRect(hdc: ?*anyopaque, rect: *const RECT, brush: ?*anyopaque) callconv(.winapi) i32;
extern "user32" fn DrawTextW(hdc: ?*anyopaque, text: [*]const u16, len: i32, rect: *RECT, format: UINT) callconv(.winapi) i32;
extern "user32" fn SetTimer(hwnd: ?HWND, id: usize, ms: u32, proc: ?*anyopaque) callconv(.winapi) usize;
extern "user32" fn KillTimer(hwnd: ?HWND, id: usize) callconv(.winapi) BOOL;
extern "user32" fn SetWindowLongPtrW(hwnd: HWND, index: i32, value: isize) callconv(.winapi) isize;
extern "user32" fn GetWindowLongPtrW(hwnd: HWND, index: i32) callconv(.winapi) isize;
extern "user32" fn GetDpiForWindow(hwnd: HWND) callconv(.winapi) UINT;
extern "user32" fn TrackMouseEvent(track: *TRACKMOUSEEVENT) callconv(.winapi) BOOL;
extern "user32" fn ShowWindow(hwnd: HWND, cmd: i32) callconv(.winapi) BOOL;
extern "user32" fn GetAncestor(hwnd: HWND, flags: UINT) callconv(.winapi) ?HWND;
extern "user32" fn PostMessageW(hwnd: HWND, msg: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) BOOL;
extern "user32" fn SetFocus(hwnd: HWND) callconv(.winapi) ?HWND;
extern "user32" fn MonitorFromWindow(hwnd: HWND, flags: u32) callconv(.winapi) ?*anyopaque;
extern "user32" fn GetMonitorInfoW(monitor: *anyopaque, info: *MONITORINFO) callconv(.winapi) BOOL;
extern "user32" fn LoadCursorW(inst: ?HINSTANCE, name: usize) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetModuleHandleW(name: ?LPCWSTR) callconv(.winapi) ?HINSTANCE;
extern "kernel32" fn GetCurrentProcess() callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetProcessTimes(process: ?*anyopaque, creation: *u64, exit: *u64, kernel: *u64, user: *u64) callconv(.winapi) BOOL;
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
extern "kernel32" fn GetActiveProcessorCount(group: u16) callconv(.winapi) u32;
extern "gdi32" fn CreateSolidBrush(color: u32) callconv(.winapi) ?*anyopaque;
extern "gdi32" fn DeleteObject(obj: ?*anyopaque) callconv(.winapi) BOOL;
extern "gdi32" fn SelectObject(hdc: ?*anyopaque, obj: ?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "gdi32" fn SetBkMode(hdc: ?*anyopaque, mode: i32) callconv(.winapi) i32;
extern "gdi32" fn SetTextColor(hdc: ?*anyopaque, color: u32) callconv(.winapi) u32;
extern "gdi32" fn CreateFontW(h: i32, w: i32, esc: i32, orient: i32, weight: i32, italic: u32, underline: u32, strike: u32, charset: u32, out_prec: u32, clip_prec: u32, quality: u32, pitch: u32, face: LPCWSTR) callconv(.winapi) ?*anyopaque;

const WM_DESTROY: UINT = 0x0002;
const WM_ACTIVATE: UINT = 0x0006;
const WM_CLOSE: UINT = 0x0010;
const WM_KEYDOWN: UINT = 0x0100;
const WM_MOUSEMOVE: UINT = 0x0200;
const WM_MOUSEHOVER: UINT = 0x02A1;
const WM_MOUSELEAVE: UINT = 0x02A3;
const WM_SIZE: UINT = 0x0005;
const WM_PAINT: UINT = 0x000F;
const WM_ERASEBKGND: UINT = 0x0014;
const WM_TIMER: UINT = 0x0113;
const WM_LBUTTONDOWN: UINT = 0x0201;
const WM_DPICHANGED_AFTERPARENT: UINT = 0x02E3;
const DT_SINGLELINE: UINT = 0x20;
const DT_VCENTER: UINT = 0x4;
const DT_CENTER: UINT = 0x1;
const DT_END_ELLIPSIS: UINT = 0x8000;
const DT_NOPREFIX: UINT = 0x800;
const GWLP_USERDATA: i32 = -21;
const TRANSPARENT: i32 = 1;

const class_name = L("koreterm.rdp_group");
const sample_timer: usize = 0x5247; // "RG"
const sample_ms: u32 = 3000;
const zoom_class_name = L("koreterm.rdp_group_zoom");
/// How long the mouse rests on a cell before its zoom opens.
const hover_ms: u32 = 800;

/// The colors a group asks its sessions for, before the automatic cap.
pub const Colors = enum(u8) {
    /// 256 colors: the lightest.
    c8 = 8,
    /// 65 thousand (16-bit).
    c16 = 16,
    /// 16 million (24-bit).
    c24 = 24,

    pub fn bits(self: Colors) i32 {
        return @intFromEnum(self);
    }

    pub fn fromBits(value: i32) ?Colors {
        return switch (value) {
            8 => .c8,
            16 => .c16,
            24 => .c24,
            else => null,
        };
    }
};

/// What the tab showing a group does for it.
pub const Hooks = struct {
    ctx: *anyopaque,
    /// A session leaves the group (Ungroup, or the group's tab closing):
    /// show it in a tab of its own. The pane is the callee's from then on,
    /// with the connection's own settings (`label` is its tab's name).
    release: *const fn (ctx: *anyopaque, pane: *rdp_pane.Pane, label: []const u8) void,
};

/// One session in the grid.
pub const Member = struct {
    group: *Group,
    pane: *rdp_pane.Pane,
    /// The tab name it had, shown on its strip; owned.
    label: []u8,
    /// The connection's own settings, which it gets back when it leaves.
    own: rdp_pane.Options,
    /// The mouse and keys reach it (Interact).
    interactive: bool = false,
    /// "Fit all": the session's desktop is the monitor's size, scaled down
    /// into the cell, so the windows open in it fit (small). Off, it keeps
    /// the size it had (`kept_w` x `kept_h`, given back when it is turned
    /// off).
    fit_all: bool = false,
    kept_w: i32 = 0,
    kept_h: i32 = 0,
    /// Its cell, strip included, in the grid's client coordinates.
    cell: RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },

    fn events(self: *Member) rdp_pane.Events {
        return .{ .ctx = self, .ended = &memberEnded, .released = &memberReleased, .connected = &memberConnected, .sent = &memberSent };
    }
};

/// The automatic level (`Group.level`): what it does to every session. A
/// level never changes a remote desktop's size: each keeps the one it had
/// and its cell scales it (`rdp_pane.Pane.keepDesktop`), since a server
/// asked for a smaller desktop rearranges the windows open in it.
pub const Level = struct {
    /// The most bits per pixel asked for.
    max_colors: i32,
};

pub const levels = [_]Level{
    .{ .max_colors = 24 },
    .{ .max_colors = 16 },
    .{ .max_colors = 16 },
    .{ .max_colors = 8 },
};

/// The level the number of sessions alone asks for.
pub fn levelForCount(count: usize) u8 {
    if (count <= 2) return 0;
    if (count <= 4) return 1;
    if (count <= 6) return 2;
    return 3;
}

/// The grid's side for `count` sessions: square and never smaller than
/// 2 x 2, growing a step when it is full (a fifth session makes it 3 x 3,
/// a tenth 4 x 4). The cells not taken show as free.
pub fn sideFor(count: usize) usize {
    var side: usize = 2;
    while (side * side < count) side += 1;
    return side;
}

/// How a group's tab starts: empty (a name is made), or a saved group, whose
/// sessions its tab opens from their profiles. Borrowed for the tab's
/// creation only.
pub const Start = struct {
    name: ?[]const u8 = null,
    colors: Colors = .c16,
    /// Profile ids of the sessions to open.
    saved_ids: []const []const u8 = &.{},
    /// Opened from its line in `rdp-groups.txt`, which a rename then moves.
    /// Off for a group session restore reopens, which may never have been
    /// saved there.
    from_saved_line: bool = true,
};

/// Every group open, for the tab menu's Add to Group. The UI thread's only.
var all: std.ArrayListUnmanaged(*Group) = .empty;

pub fn groups() []const *Group {
    return all.items;
}

pub const Group = struct {
    alloc: Allocator,
    hwnd: HWND,
    hooks: Hooks,
    /// "Group 1": the tab's name when it opens, and after a Rename Tab
    /// (`rename`); shown in Add to Group and saved under it.
    name: []u8,
    /// The name of its line in `rdp-groups.txt`, once it has one (saved,
    /// or opened from a saved line): a rename moves that line
    /// (`replaceSaved`'s `old_name`) instead of leaving it behind.
    saved_as: ?[]u8 = null,
    members: std.ArrayListUnmanaged(*Member) = .empty,
    colors: Colors = .c16,
    /// The automatic level from load (`sample`), 0 to `levels.len - 1`.
    pressure: u8 = 0,
    high_samples: u8 = 0,
    low_samples: u8 = 0,
    /// The last sample, percent of every processor.
    cpu_pct: u8 = 0,
    last_cpu_100ns: u64 = 0,
    last_tick_ms: u64 = 0,
    font: ?*anyopaque = null,
    font_dpi: u32 = 0,
    /// Its tab was closed (it is kept for undo): Add to Group leaves it out.
    closed: bool = false,
    /// The member shown large in the zoom window (`openZoom`): its session
    /// sits in that window until it closes.
    zoom: ?*Member = null,
    zoom_hwnd: ?HWND = null,
    /// The member whose zoom just closed: the mouse resting on it again
    /// does not reopen it until it leaves that cell.
    hover_blocked: ?*Member = null,

    /// A grid covering `parent`'s client area, empty.
    pub fn create(alloc: Allocator, parent: HWND, hooks: Hooks, name: ?[]const u8) !*Group {
        try registerClass();
        const self = try alloc.create(Group);
        errdefer alloc.destroy(self);
        const owned_name = if (name) |given| try alloc.dupe(u8, given) else try defaultName(alloc, "");
        errdefer alloc.free(owned_name);
        var rect: RECT = undefined;
        if (GetClientRect(parent, &rect) == 0) rect = .{ .left = 0, .top = 0, .right = 800, .bottom = 600 };
        const WS_CHILD: u32 = 0x40000000;
        const WS_VISIBLE: u32 = 0x10000000;
        const WS_CLIPCHILDREN: u32 = 0x02000000;
        const WS_CLIPSIBLINGS: u32 = 0x04000000;
        // The terminal's renderer must not paint over the grid.
        const GWL_STYLE: i32 = -16;
        _ = SetWindowLongPtrW(parent, GWL_STYLE, GetWindowLongPtrW(parent, GWL_STYLE) | WS_CLIPCHILDREN);
        const hwnd = CreateWindowExW(0, class_name, L(""), WS_CHILD | WS_VISIBLE | WS_CLIPCHILDREN | WS_CLIPSIBLINGS, 0, 0, rect.right, rect.bottom, parent, null, GetModuleHandleW(null), null) orelse return error.WindowCreationFailed;
        self.* = .{ .alloc = alloc, .hwnd = hwnd, .hooks = hooks, .name = owned_name };
        _ = SetWindowLongPtrW(hwnd, GWLP_USERDATA, @bitCast(@intFromPtr(self)));
        try all.append(std.heap.page_allocator, self);
        self.sampleStart();
        _ = SetTimer(hwnd, sample_timer, sample_ms, null);
        return self;
    }

    /// End the grid and every session still in it (its tab is going, with
    /// its window: a closing tab lets them go first, `releaseAll`).
    pub fn destroy(self: *Group) void {
        self.closeZoom();
        _ = KillTimer(self.hwnd, sample_timer);
        _ = SetWindowLongPtrW(self.hwnd, GWLP_USERDATA, 0);
        for (self.members.items) |member| {
            member.pane.destroy();
            self.freeMember(member);
        }
        self.members.deinit(self.alloc);
        for (all.items, 0..) |group, i| if (group == self) {
            _ = all.orderedRemove(i);
            break;
        };
        _ = DestroyWindow(self.hwnd);
        if (self.font) |font| _ = DeleteObject(font);
        self.alloc.free(self.name);
        if (self.saved_as) |saved| self.alloc.free(saved);
        self.alloc.destroy(self);
    }

    /// Its tab was renamed: the group takes the name (Add to Group, Save).
    /// False when it already had it.
    pub fn rename(self: *Group, name: []const u8) !bool {
        if (name.len == 0 or std.mem.eql(u8, self.name, name)) return false;
        const owned = try self.alloc.dupe(u8, name);
        self.alloc.free(self.name);
        self.name = owned;
        return true;
    }

    /// Its line in `rdp-groups.txt` is now the one named `name`.
    pub fn setSavedAs(self: *Group, name: []const u8) !void {
        const owned = try self.alloc.dupe(u8, name);
        if (self.saved_as) |old| self.alloc.free(old);
        self.saved_as = owned;
    }

    fn freeMember(self: *Group, member: *Member) void {
        self.alloc.free(member.label);
        self.alloc.destroy(member);
    }

    /// The grid covers `width` x `height` of its tab.
    pub fn resize(self: *Group, width: i32, height: i32) void {
        _ = MoveWindow(self.hwnd, 0, 0, width, height, 1);
        self.layout();
    }

    /// Take `pane` (a session that was in a tab) into the grid. `own` is the
    /// connection's own settings, given back when it leaves.
    pub fn add(self: *Group, pane: *rdp_pane.Pane, label: []const u8, own: rdp_pane.Options) !void {
        const member = try self.alloc.create(Member);
        errdefer self.alloc.destroy(member);
        member.* = .{ .group = self, .pane = pane, .label = try self.alloc.dupe(u8, label), .own = own };
        errdefer self.alloc.free(member.label);
        try self.members.append(self.alloc, member);
        pane.keepDesktop(true);
        pane.reparent(self.hwnd, member.events());
        pane.setInteractive(false);
        self.layout();
        // Fit all from the start: the whole desktop, small, nothing cut.
        self.fitAll(member);
        // No reconnect to join (`applyLevel`): the session keeps its
        // quality and sound until the group's colors are picked.
        self.applyLevel(false);
        _ = InvalidateRect(self.hwnd, null, 1);
    }

    /// A member about to be made: the session `make` creates is watched in
    /// the grid from its first connect (a saved group opening). `make` gets
    /// the grid window, the cell's size, the options and the events.
    pub fn addNew(
        self: *Group,
        label: []const u8,
        own: rdp_pane.Options,
        make: *const fn (ctx: *anyopaque, parent: HWND, width: i32, height: i32, options: rdp_pane.Options, events: rdp_pane.Events) ?*rdp_pane.Pane,
        ctx: *anyopaque,
    ) !void {
        const member = try self.alloc.create(Member);
        errdefer self.alloc.destroy(member);
        member.* = .{ .group = self, .pane = undefined, .label = try self.alloc.dupe(u8, label), .own = own };
        errdefer self.alloc.free(member.label);
        // The desktop a tab of the group's size would have: its cell only
        // scales it (`keepDesktop`).
        var area: RECT = undefined;
        if (GetClientRect(self.hwnd, &area) == 0 or area.right < 200 or area.bottom < 200) area = .{ .left = 0, .top = 0, .right = 1280, .bottom = 800 };
        // Fit all from the start: it connects at the monitor's size, and
        // Keep size gives it the grid's.
        const desk = self.monitorSize() orelse [2]i32{ area.right, area.bottom };
        const pane = make(ctx, self.hwnd, desk[0], desk[1], self.memberOptions(own), member.events()) orelse return error.PaneCreationFailed;
        pane.keepDesktop(true);
        member.pane = pane;
        member.fit_all = true;
        member.kept_w = area.right;
        member.kept_h = area.bottom;
        self.members.append(self.alloc, member) catch |err| {
            pane.destroy();
            return err;
        };
        pane.setInteractive(false);
        self.layout();
        self.applyLevel(false);
        _ = InvalidateRect(self.hwnd, null, 1);
    }

    /// Every session goes back to a tab of its own (the group's tab is
    /// closing), in the grid's order.
    pub fn releaseAll(self: *Group) void {
        while (self.members.items.len != 0) self.release(self.members.items[0]);
    }

    /// `member` goes back to a tab of its own, with its connection's own
    /// settings.
    pub fn release(self: *Group, member: *Member) void {
        if (self.zoom == member) self.closeZoom();
        if (self.hover_blocked == member) self.hover_blocked = null;
        for (self.members.items, 0..) |other, i| if (other == member) {
            _ = self.members.orderedRemove(i);
            break;
        };
        const pane = member.pane;
        pane.setInteractive(true);
        // Its tab's `resize` gives it that tab's size again.
        pane.keepDesktop(false);
        // No reconnect: the server may hand a disconnected session back to
        // its console at once (an agent's tscon), which ends the robots
        // running in it and refuses the reconnect (reason 5). Measured
        // 2026-11-19: CND03 ended 7 s after it left its group.
        pane.applyOptions(member.own.withoutReconnect(pane.options));
        self.hooks.release(self.hooks.ctx, pane, member.label);
        self.freeMember(member);
        self.layout();
        self.applyLevel(false);
        _ = InvalidateRect(self.hwnd, null, 1);
    }

    /// The colors chosen from the group tab's menu.
    pub fn setColors(self: *Group, colors: Colors) void {
        if (colors == self.colors) return;
        self.colors = colors;
        self.applyLevel(true);
        _ = InvalidateRect(self.hwnd, null, 1);
    }

    /// The level in force: the larger of what the count asks for and what
    /// the load asks for.
    pub fn level(self: *const Group) u8 {
        return @max(levelForCount(self.members.items.len), self.pressure);
    }

    /// The bits per pixel asked for now.
    pub fn effectiveColors(self: *const Group) i32 {
        return @min(self.colors.bits(), levels[self.level()].max_colors);
    }

    fn memberOptions(self: *const Group, own: rdp_pane.Options) rdp_pane.Options {
        return .{
            .colors = self.effectiveColors(),
            .compression = true,
            .experience = .fast,
            // The desktop keeps its size, so its cell keeps its proportions.
            .scaling = .proportional,
            .trust_certificates = own.trust_certificates,
            .audio = false,
        };
    }

    /// Give every session the level in force. What needs a reconnect
    /// (colors, compression, experience, audio) changes only when
    /// `colors_now`, the person's own pick of colors from the group tab's
    /// menu: joining, leaving, a session ending or the load never
    /// disconnects a session. A disconnected session may be handed back to
    /// the server's console at once (an agent's tscon), which ends what
    /// runs in it and refuses the reconnect (reason 5); measured
    /// 2026-11-19 on sessions running FlaUI robots.
    fn applyLevel(self: *Group, colors_now: bool) void {
        for (self.members.items) |member| {
            const options = self.memberOptions(member.own);
            if (colors_now or !member.pane.options.needsReconnect(options)) {
                member.pane.applyOptions(options);
            } else {
                member.pane.applyOptions(options.withoutReconnect(member.pane.options));
            }
        }
    }

    fn sampleStart(self: *Group) void {
        var creation: u64 = 0;
        var exit: u64 = 0;
        var kernel: u64 = 0;
        var user: u64 = 0;
        if (GetProcessTimes(GetCurrentProcess(), &creation, &exit, &kernel, &user) != 0) self.last_cpu_100ns = kernel + user;
        self.last_tick_ms = GetTickCount64();
    }

    /// One CPU sample of the whole process (the sessions decode in it):
    /// two in a row at 70% or more raise the automatic level, ten (30 s)
    /// at 30% or less lower it.
    fn sample(self: *Group) void {
        var creation: u64 = 0;
        var exit: u64 = 0;
        var kernel: u64 = 0;
        var user: u64 = 0;
        if (GetProcessTimes(GetCurrentProcess(), &creation, &exit, &kernel, &user) == 0) return;
        const now = GetTickCount64();
        const cpu = kernel + user;
        const wall_ms = now -| self.last_tick_ms;
        const used = cpu -| self.last_cpu_100ns;
        self.last_cpu_100ns = cpu;
        self.last_tick_ms = now;
        if (wall_ms == 0) return;
        const processors: u64 = @max(1, GetActiveProcessorCount(0xFFFF));
        // 100 ns units over milliseconds: 10_000 per millisecond.
        const pct = (used * 100) / (wall_ms * 10_000 * processors);
        self.cpu_pct = @intCast(@min(100, pct));
        const before = self.pressure;
        if (self.cpu_pct >= 70) {
            self.low_samples = 0;
            self.high_samples +|= 1;
            if (self.high_samples >= 2 and self.pressure + 1 < levels.len) {
                self.pressure += 1;
                self.high_samples = 0;
            }
        } else if (self.cpu_pct <= 30) {
            self.high_samples = 0;
            self.low_samples +|= 1;
            if (self.low_samples >= 10 and self.pressure > 0) {
                self.pressure -= 1;
                self.low_samples = 0;
            }
        } else {
            self.high_samples = 0;
            self.low_samples = 0;
        }
        if (self.pressure != before) {
            log.info("rdp group: load level {d} -> {d} cpu={d}%", .{ before, self.pressure, self.cpu_pct });
            self.applyLevel(false);
        }
        _ = InvalidateRect(self.hwnd, &self.headerRect(), 0);
    }

    fn scaled(self: *const Group, value: i32) i32 {
        const dpi: i32 = @intCast(@max(96, GetDpiForWindow(self.hwnd)));
        return @divTrunc(value * dpi, 96);
    }

    fn headerRect(self: *const Group) RECT {
        var rect: RECT = undefined;
        if (GetClientRect(self.hwnd, &rect) == 0) rect = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
        rect.bottom = rect.top + self.scaled(24);
        return rect;
    }

    fn stripHeight(self: *const Group) i32 {
        return self.scaled(22);
    }

    /// Cell `index` of the square grid (`sideFor`), row by row, under the
    /// header.
    fn cellRect(self: *const Group, index: usize) RECT {
        var client: RECT = undefined;
        if (GetClientRect(self.hwnd, &client) == 0) return .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
        const side = sideFor(self.members.items.len);
        const top = client.top + self.headerRect().bottom;
        const width = client.right - client.left;
        const height = client.bottom - top;
        const gap = self.scaled(2);
        const n: i32 = @intCast(side);
        const col: i32 = @intCast(index % side);
        const row: i32 = @intCast(index / side);
        return .{
            .left = client.left + @divTrunc(width * col, n),
            .top = top + @divTrunc(height * row, n),
            .right = client.left + @divTrunc(width * (col + 1), n) - gap,
            .bottom = top + @divTrunc(height * (row + 1), n) - gap,
        };
    }

    /// Each session in its cell, in the order they joined.
    fn layout(self: *Group) void {
        const strip = self.stripHeight();
        for (self.members.items, 0..) |member, i| {
            const cell = self.cellRect(i);
            member.cell = cell;
            // The zoomed session is in the zoom window.
            if (self.zoom == member) continue;
            member.pane.placeIn(cell.left, cell.top + strip, @max(1, cell.right - cell.left), @max(1, cell.bottom - cell.top - strip));
        }
    }

    /// A strip's buttons: Interact (or Watch only), Ungroup, and Fit all
    /// (or Keep size).
    fn stripButtons(self: *const Group, member: *const Member) [3]RECT {
        const strip = self.stripHeight();
        const w = self.scaled(76);
        const pad = self.scaled(4);
        const top = member.cell.top + self.scaled(2);
        const bottom = member.cell.top + strip - self.scaled(2);
        const ungroup: RECT = .{ .left = member.cell.right - pad - w, .top = top, .right = member.cell.right - pad, .bottom = bottom };
        const interact: RECT = .{ .left = ungroup.left - pad - w, .top = top, .right = ungroup.left - pad, .bottom = bottom };
        const fit: RECT = .{ .left = interact.left - pad - w, .top = top, .right = interact.left - pad, .bottom = bottom };
        return .{ interact, ungroup, fit };
    }

    fn ensureFont(self: *Group) ?*anyopaque {
        const dpi = GetDpiForWindow(self.hwnd);
        if (self.font != null and self.font_dpi == dpi) return self.font;
        if (self.font) |font| _ = DeleteObject(font);
        const height: i32 = -@as(i32, @intCast(@divTrunc(9 * @max(96, dpi), 72)));
        self.font = CreateFontW(height, 0, 0, 0, 400, 0, 0, 0, 1, 0, 0, 5, 0, L("Segoe UI"));
        self.font_dpi = dpi;
        return self.font;
    }

    fn paint(self: *Group) void {
        var ps: PAINTSTRUCT = undefined;
        const hdc = BeginPaint(self.hwnd, &ps);
        defer _ = EndPaint(self.hwnd, &ps);
        var client: RECT = undefined;
        if (GetClientRect(self.hwnd, &client) == 0) return;
        fill(hdc, client, 0x00181818);
        const old_font = SelectObject(hdc, self.ensureFont());
        defer _ = SelectObject(hdc, old_font);
        _ = SetBkMode(hdc, TRANSPARENT);

        // The header: what is watched, and koreterm's load.
        var header = self.headerRect();
        fill(hdc, header, 0x00242424);
        header.left += self.scaled(8);
        var buf: [256]u8 = undefined;
        // Each session keeps its own colors (`applyLevel`), so none are
        // named here.
        const header_text = std.fmt.bufPrint(&buf, "{s}: {d} Remote Desktop{s}, watch only. koreterm CPU {d}%.", .{
            self.name,
            self.members.items.len,
            if (self.members.items.len == 1) "" else "s",
            self.cpu_pct,
        }) catch "";
        text(hdc, header, header_text, 0x00C8C8C8, 0);

        // The free cells.
        const side = sideFor(self.members.items.len);
        var free = self.members.items.len;
        while (free < side * side) : (free += 1) {
            const cell = self.cellRect(free);
            fill(hdc, cell, 0x00202020);
            text(hdc, cell, if (free == 0)
                "Free. Right-click a Remote Desktop tab, Add to Group."
            else
                "Free", 0x00808080, DT_CENTER);
        }
        const strip = self.stripHeight();
        for (self.members.items) |member| {
            var bar: RECT = .{ .left = member.cell.left, .top = member.cell.top, .right = member.cell.right, .bottom = member.cell.top + strip };
            fill(hdc, bar, if (member.interactive) 0x00A05A1E else 0x002E2E2E);
            const buttons = self.stripButtons(member);
            bar.left += self.scaled(8);
            bar.right = buttons[2].left - self.scaled(4);
            text(hdc, bar, member.label, 0x00F0F0F0, 0);
            if (self.zoom == member) {
                const picture: RECT = .{ .left = member.cell.left, .top = member.cell.top + strip, .right = member.cell.right, .bottom = member.cell.bottom };
                fill(hdc, picture, 0x00202020);
                text(hdc, picture, "Shown in the zoom window.", 0x00808080, DT_CENTER);
            }
            for (buttons, 0..) |button, i| {
                fill(hdc, button, 0x00404040);
                var inner = button;
                const caption = switch (i) {
                    0 => if (member.interactive) "Watch only" else "Interact",
                    1 => "Ungroup",
                    else => if (member.fit_all) "Keep size" else "Fit all",
                };
                text(hdc, &inner, caption, 0x00F0F0F0, DT_CENTER);
            }
        }
    }

    fn click(self: *Group, x: i32, y: i32) void {
        for (self.members.items) |member| {
            const buttons = self.stripButtons(member);
            if (inside(buttons[1], x, y)) return self.release(member);
            if (inside(buttons[0], x, y)) return self.toggleInteract(member);
            if (inside(buttons[2], x, y)) return self.toggleFitAll(member);
        }
    }

    /// Fit all: ask the session for a desktop the size of the monitor the
    /// group is on, which its cell scales down (everything small, nothing
    /// cut). Keep size: the size it had before. Either way the server
    /// rearranges the windows open in it, as for any display change.
    fn toggleFitAll(self: *Group, member: *Member) void {
        self.closeZoom();
        if (!member.fit_all) {
            self.fitAll(member);
        } else {
            member.fit_all = false;
            if (member.kept_w > 0 and member.kept_h > 0) member.pane.setDesktopSize(member.kept_w, member.kept_h);
        }
        _ = InvalidateRect(self.hwnd, null, 0);
    }

    /// Fit all for `member` (a session joining starts so), keeping the
    /// size it had for Keep size.
    fn fitAll(self: *Group, member: *Member) void {
        const size = self.monitorSize() orelse return;
        const now = member.pane.desktopSize();
        member.kept_w = now[0];
        member.kept_h = now[1];
        member.fit_all = true;
        member.pane.setDesktopSize(size[0], size[1]);
    }

    /// The pixel size of the monitor the grid is on.
    fn monitorSize(self: *const Group) ?[2]i32 {
        const monitor = MonitorFromWindow(self.hwnd, MONITOR_DEFAULTTONEAREST) orelse return null;
        var info: MONITORINFO = .{ .cbSize = @sizeOf(MONITORINFO), .rcMonitor = undefined, .rcWork = undefined, .dwFlags = 0 };
        if (GetMonitorInfoW(monitor, &info) == 0) return null;
        const w = info.rcMonitor.right - info.rcMonitor.left;
        const h = info.rcMonitor.bottom - info.rcMonitor.top;
        if (w <= 0 or h <= 0) return null;
        return .{ w, h };
    }

    /// Interact: the mouse and keys reach this session (one at a time);
    /// Watch only takes them away again.
    fn toggleInteract(self: *Group, member: *Member) void {
        self.closeZoom();
        const on = !member.interactive;
        for (self.members.items) |other| if (other.interactive and other != member) {
            other.interactive = false;
            other.pane.setInteractive(false);
        };
        member.interactive = on;
        member.pane.setInteractive(on);
        if (on) member.pane.focus();
        _ = InvalidateRect(self.hwnd, null, 0);
    }

    /// The watched member whose picture (its cell below the strip) is at
    /// `x`, `y` in the grid.
    fn pictureAt(self: *const Group, x: i32, y: i32) ?*Member {
        const strip = self.stripHeight();
        for (self.members.items) |member| {
            const picture: RECT = .{ .left = member.cell.left, .top = member.cell.top + strip, .right = member.cell.right, .bottom = member.cell.bottom };
            if (inside(picture, x, y)) return member;
        }
        return null;
    }

    /// The mouse moved in the grid (a watched session's control is
    /// disabled, so the grid gets the mouse over it): wait for it to rest.
    fn mouseMoved(self: *Group, x: i32, y: i32) void {
        const member = self.pictureAt(x, y);
        if (member != self.hover_blocked) self.hover_blocked = null;
        var track: TRACKMOUSEEVENT = .{ .dwFlags = TME_HOVER | TME_LEAVE, .hwndTrack = self.hwnd, .dwHoverTime = hover_ms };
        _ = TrackMouseEvent(&track);
    }

    /// The mouse rested at `x`, `y`: the zoom of the session under it.
    fn mouseRested(self: *Group, x: i32, y: i32) void {
        const member = self.pictureAt(x, y) orelse return;
        if (member == self.hover_blocked or member.interactive or self.zoom != null) return;
        self.openZoom(member) catch |err| log.warn("rdp group: the zoom did not open err={}", .{err});
    }

    /// Show `member`'s session large, live and watch only, in a window of
    /// its own over the grid (80% of the monitor's work area): the control
    /// moves there without reconnecting (`Pane.reparent`) and back to its
    /// cell when the window closes (a click in it, Esc, its X, or a click
    /// anywhere else).
    fn openZoom(self: *Group, member: *Member) !void {
        try registerZoomClass();
        const monitor = MonitorFromWindow(self.hwnd, MONITOR_DEFAULTTONEAREST) orelse return error.NoMonitor;
        var info: MONITORINFO = .{ .cbSize = @sizeOf(MONITORINFO), .rcMonitor = undefined, .rcWork = undefined, .dwFlags = 0 };
        if (GetMonitorInfoW(monitor, &info) == 0) return error.NoMonitor;
        const work = info.rcWork;
        const w = @divTrunc((work.right - work.left) * 8, 10);
        const h = @divTrunc((work.bottom - work.top) * 8, 10);
        const x = work.left + @divTrunc(work.right - work.left - w, 2);
        const y = work.top + @divTrunc(work.bottom - work.top - h, 2);
        const title = try std.fmt.allocPrint(self.alloc, "{s} (zoom: click, Esc or click outside to close)", .{member.label});
        defer self.alloc.free(title);
        const wide = try std.unicode.utf8ToUtf16LeAllocZ(self.alloc, title);
        defer self.alloc.free(wide);
        const WS_POPUP: u32 = 0x80000000;
        const WS_CAPTION: u32 = 0x00C00000;
        const WS_SYSMENU: u32 = 0x00080000;
        const WS_THICKFRAME: u32 = 0x00040000;
        const WS_CLIPCHILDREN: u32 = 0x02000000;
        const GA_ROOT: UINT = 2;
        const owner = GetAncestor(self.hwnd, GA_ROOT);
        const hwnd = CreateWindowExW(0, zoom_class_name, wide.ptr, WS_POPUP | WS_CAPTION | WS_SYSMENU | WS_THICKFRAME | WS_CLIPCHILDREN, x, y, w, h, owner, null, GetModuleHandleW(null), null) orelse return error.WindowCreationFailed;
        _ = SetWindowLongPtrW(hwnd, GWLP_USERDATA, @bitCast(@intFromPtr(self)));
        self.zoom = member;
        self.zoom_hwnd = hwnd;
        member.pane.reparent(hwnd, member.events());
        var client: RECT = undefined;
        if (GetClientRect(hwnd, &client) != 0) member.pane.placeIn(0, 0, client.right, client.bottom);
        const SW_SHOW: i32 = 5;
        _ = ShowWindow(hwnd, SW_SHOW);
        _ = SetFocus(hwnd);
        _ = InvalidateRect(self.hwnd, null, 0);
    }

    /// The zoom window's session back in its cell, and the window gone.
    fn closeZoom(self: *Group) void {
        const member = self.zoom orelse return;
        const hwnd = self.zoom_hwnd.?;
        self.zoom = null;
        self.zoom_hwnd = null;
        self.hover_blocked = member;
        member.pane.reparent(self.hwnd, member.events());
        self.layout();
        _ = SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0);
        _ = DestroyWindow(hwnd);
        _ = InvalidateRect(self.hwnd, null, 0);
    }

    /// The zoom window's client area changed: the session follows.
    fn zoomResized(self: *Group) void {
        const member = self.zoom orelse return;
        var client: RECT = undefined;
        if (GetClientRect(self.zoom_hwnd.?, &client) != 0) member.pane.placeIn(0, 0, client.right, client.bottom);
    }

    /// Find the member a pane's events are for, still in the group.
    fn holds(self: *const Group, member: *const Member) bool {
        for (self.members.items) |other| if (other == member) return true;
        return false;
    }
};

fn memberEnded(ctx: *anyopaque) void {
    const member: *Member = @ptrCast(@alignCast(ctx));
    const group = member.group;
    if (!group.holds(member)) return;
    // The pane destroyed itself: only the cell goes (and the zoom window
    // it was shown in).
    if (group.zoom == member) {
        const hwnd = group.zoom_hwnd.?;
        group.zoom = null;
        group.zoom_hwnd = null;
        _ = SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0);
        _ = DestroyWindow(hwnd);
    }
    if (group.hover_blocked == member) group.hover_blocked = null;
    for (group.members.items, 0..) |other, i| if (other == member) {
        _ = group.members.orderedRemove(i);
        break;
    };
    group.freeMember(member);
    group.layout();
    group.applyLevel(false);
    _ = InvalidateRect(group.hwnd, null, 1);
}

fn memberReleased(ctx: *anyopaque) void {
    const member: *Member = @ptrCast(@alignCast(ctx));
    // Ctrl+Alt+Home: back to watching.
    if (member.interactive) member.group.toggleInteract(member);
}

fn memberConnected(ctx: *anyopaque) void {
    const member: *Member = @ptrCast(@alignCast(ctx));
    _ = InvalidateRect(member.group.hwnd, null, 0);
}

fn memberSent(_: *anyopaque, _: rdp_pane.Sent) void {}

fn inside(rect: RECT, x: i32, y: i32) bool {
    return x >= rect.left and x < rect.right and y >= rect.top and y < rect.bottom;
}

fn fill(hdc: ?*anyopaque, rect: RECT, color: u32) void {
    const brush = CreateSolidBrush(color) orelse return;
    defer _ = DeleteObject(brush);
    _ = FillRect(hdc, &rect, brush);
}

fn text(hdc: ?*anyopaque, rect_in: anytype, utf8: []const u8, color: u32, extra: UINT) void {
    var rect: RECT = if (@TypeOf(rect_in) == *RECT) rect_in.* else rect_in;
    var wide: [512]u16 = undefined;
    const len = std.unicode.utf8ToUtf16Le(&wide, utf8[0..@min(utf8.len, wide.len)]) catch return;
    _ = SetTextColor(hdc, color);
    _ = DrawTextW(hdc, &wide, @intCast(len), &rect, DT_SINGLELINE | DT_VCENTER | DT_END_ELLIPSIS | DT_NOPREFIX | extra);
}

var class_registered = false;

fn registerClass() !void {
    if (class_registered) return;
    const IDC_ARROW: usize = 32512;
    const class: WNDCLASSEXW = .{
        .cbSize = @sizeOf(WNDCLASSEXW),
        .style = 0,
        .lpfnWndProc = &wndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = GetModuleHandleW(null) orelse return error.ClassRegistrationFailed,
        .hIcon = null,
        .hCursor = LoadCursorW(null, IDC_ARROW),
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = class_name,
        .hIconSm = null,
    };
    if (RegisterClassExW(&class) == 0) return error.ClassRegistrationFailed;
    class_registered = true;
}

fn pointOf(lparam: LPARAM) [2]i32 {
    const bits: usize = @bitCast(lparam);
    return .{
        @as(i16, @bitCast(@as(u16, @truncate(bits)))),
        @as(i16, @bitCast(@as(u16, @truncate(bits >> 16)))),
    };
}

var zoom_class_registered = false;

fn registerZoomClass() !void {
    if (zoom_class_registered) return;
    const IDC_ARROW: usize = 32512;
    const class: WNDCLASSEXW = .{
        .cbSize = @sizeOf(WNDCLASSEXW),
        .style = 0,
        .lpfnWndProc = &zoomProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = GetModuleHandleW(null) orelse return error.ClassRegistrationFailed,
        .hIcon = null,
        .hCursor = LoadCursorW(null, IDC_ARROW),
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = zoom_class_name,
        .hIconSm = null,
    };
    if (RegisterClassExW(&class) == 0) return error.ClassRegistrationFailed;
    zoom_class_registered = true;
}

/// The zoom window (`Group.openZoom`). Its session's control is disabled,
/// so a click on it reaches this window, which closes. So does losing the
/// activation (a click anywhere else), posted so the window is not
/// destroyed inside its own activation change.
fn zoomProc(hwnd: HWND, msg: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT {
    const group = groupOf(hwnd) orelse return DefWindowProcW(hwnd, msg, wparam, lparam);
    const WA_INACTIVE: usize = 0;
    const VK_ESCAPE: usize = 0x1B;
    switch (msg) {
        WM_ERASEBKGND => return 1,
        WM_PAINT => {
            var ps: PAINTSTRUCT = undefined;
            const hdc = BeginPaint(hwnd, &ps);
            defer _ = EndPaint(hwnd, &ps);
            var client: RECT = undefined;
            if (GetClientRect(hwnd, &client) != 0) fill(hdc, client, 0x00000000);
            return 0;
        },
        WM_SIZE => {
            group.zoomResized();
            return 0;
        },
        WM_LBUTTONDOWN => {
            _ = PostMessageW(hwnd, WM_CLOSE, 0, 0);
            return 0;
        },
        WM_KEYDOWN => {
            if (wparam == VK_ESCAPE) _ = PostMessageW(hwnd, WM_CLOSE, 0, 0);
            return 0;
        },
        WM_ACTIVATE => {
            if ((wparam & 0xFFFF) == WA_INACTIVE) _ = PostMessageW(hwnd, WM_CLOSE, 0, 0);
            return DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        WM_CLOSE => {
            if (group.zoom_hwnd == hwnd) group.closeZoom();
            return 0;
        },
        else => return DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

fn groupOf(hwnd: HWND) ?*Group {
    const raw = GetWindowLongPtrW(hwnd, GWLP_USERDATA);
    if (raw == 0) return null;
    return @ptrFromInt(@as(usize, @bitCast(raw)));
}

fn wndProc(hwnd: HWND, msg: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT {
    const group = groupOf(hwnd) orelse return DefWindowProcW(hwnd, msg, wparam, lparam);
    switch (msg) {
        WM_ERASEBKGND => return 1,
        WM_PAINT => {
            group.paint();
            return 0;
        },
        WM_SIZE => {
            group.layout();
            _ = InvalidateRect(hwnd, null, 0);
            return 0;
        },
        WM_DPICHANGED_AFTERPARENT => {
            group.layout();
            _ = InvalidateRect(hwnd, null, 1);
            return 0;
        },
        WM_TIMER => {
            if (wparam == sample_timer) group.sample();
            return 0;
        },
        WM_LBUTTONDOWN => {
            const point = pointOf(lparam);
            group.click(point[0], point[1]);
            return 0;
        },
        WM_MOUSEMOVE => {
            const point = pointOf(lparam);
            group.mouseMoved(point[0], point[1]);
            return 0;
        },
        WM_MOUSEHOVER => {
            const point = pointOf(lparam);
            group.mouseRested(point[0], point[1]);
            return 0;
        },
        WM_MOUSELEAVE => {
            group.hover_blocked = null;
            return 0;
        },
        WM_DESTROY => {
            _ = SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0);
            return 0;
        },
        else => return DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

// --- Saved groups ----------------------------------------------------------

/// The file the saved groups are kept in, in koreterm's local data folder.
pub const saved_file = "rdp-groups.txt";

/// A saved group: a line of `rdp-groups.txt`, its name, its colors and the
/// profile ids of its sessions, separated by tabs.
pub const Saved = struct {
    name: []const u8,
    colors: Colors,
    ids: []const []const u8,
};

/// `group` as a saved line (no line ending), with the profile ids of its
/// sessions (those opened from a profile: the others cannot be opened
/// again). Null when none has one.
pub fn savedLine(alloc: Allocator, group: *const Group) !?[]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try writeClean(&out.writer, group.name);
    try out.writer.print("\t{d}", .{group.colors.bits()});
    var any = false;
    for (group.members.items) |member| {
        const id = member.pane.profile_id orelse continue;
        try out.writer.writeByte('\t');
        try writeClean(&out.writer, id);
        any = true;
    }
    if (!any) {
        out.deinit();
        return null;
    }
    return try out.toOwnedSlice();
}

fn writeClean(writer: *std.Io.Writer, value: []const u8) !void {
    for (value) |byte| try writer.writeByte(if (byte == '\t' or byte == '\r' or byte == '\n') ' ' else byte);
}

/// A saved line read back, its slices borrowed from `line`; the ids in
/// `ids_buf`. Null for a line that is not one.
pub fn parseSaved(line: []const u8, ids_buf: [][]const u8) ?Saved {
    var it = std.mem.splitScalar(u8, std.mem.trimRight(u8, line, "\r"), '\t');
    const name = it.next() orelse return null;
    if (name.len == 0) return null;
    const colors_text = it.next() orelse return null;
    const colors = Colors.fromBits(std.fmt.parseInt(i32, colors_text, 10) catch return null) orelse return null;
    var count: usize = 0;
    while (it.next()) |id| {
        if (id.len == 0 or count == ids_buf.len) continue;
        ids_buf[count] = id;
        count += 1;
    }
    if (count == 0) return null;
    return .{ .name = name, .colors = colors, .ids = ids_buf[0..count] };
}

/// `text` (the file) with `line` in place of the line of the same name, or
/// of `old_name` (the group was renamed since it was saved), or added last.
/// In `alloc`.
pub fn replaceSaved(alloc: Allocator, file_text: []const u8, line: []const u8, old_name: ?[]const u8) ![]u8 {
    const name_end = std.mem.indexOfScalar(u8, line, '\t') orelse line.len;
    const name = line[0..name_end];
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var replaced = false;
    var it = std.mem.splitScalar(u8, file_text, '\n');
    while (it.next()) |raw| {
        const existing = std.mem.trimRight(u8, raw, "\r");
        if (existing.len == 0) continue;
        const end = std.mem.indexOfScalar(u8, existing, '\t') orelse existing.len;
        const existing_name = existing[0..end];
        const was = if (old_name) |old| std.mem.eql(u8, existing_name, old) else false;
        if (was or std.mem.eql(u8, existing_name, name)) {
            if (!replaced) try out.writer.print("{s}\n", .{line});
            replaced = true;
            continue;
        }
        try out.writer.print("{s}\n", .{existing});
    }
    if (!replaced) try out.writer.print("{s}\n", .{line});
    return try out.toOwnedSlice();
}

/// "Group N" for a new group, N the smallest that no open group and no
/// line of `saved_text` (the file) has: the count starts again at every
/// launch, and a new "Group 1" saved over an old one would replace it.
pub fn defaultName(alloc: Allocator, saved_text: []const u8) ![]u8 {
    var n: u32 = 1;
    while (true) : (n += 1) {
        const name = try std.fmt.allocPrint(alloc, "Group {d}", .{n});
        if (!nameTaken(name, saved_text)) return name;
        alloc.free(name);
    }
}

fn nameTaken(name: []const u8, saved_text: []const u8) bool {
    for (all.items) |group| if (std.mem.eql(u8, group.name, name)) return true;
    var it = std.mem.splitScalar(u8, saved_text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimRight(u8, raw, "\r");
        const end = std.mem.indexOfScalar(u8, line, '\t') orelse line.len;
        if (std.mem.eql(u8, line[0..end], name)) return true;
    }
    return false;
}

test "rdp group: the grid is square, 2 x 2 at least, a step larger when full" {
    try std.testing.expectEqual(@as(usize, 2), sideFor(0));
    try std.testing.expectEqual(@as(usize, 2), sideFor(1));
    try std.testing.expectEqual(@as(usize, 2), sideFor(4));
    try std.testing.expectEqual(@as(usize, 3), sideFor(5));
    try std.testing.expectEqual(@as(usize, 3), sideFor(9));
    try std.testing.expectEqual(@as(usize, 4), sideFor(10));
}

test "rdp group: the level follows the count, and colors are capped" {
    try std.testing.expectEqual(@as(u8, 0), levelForCount(2));
    try std.testing.expectEqual(@as(u8, 1), levelForCount(4));
    try std.testing.expectEqual(@as(u8, 3), levelForCount(9));
    try std.testing.expectEqual(@as(i32, 8), @min(Colors.c24.bits(), levels[3].max_colors));
}

test "rdp group: a saved line reads back and replaces the one of its name" {
    var ids: [8][]const u8 = undefined;
    const saved = parseSaved("Servers\t16\tweb1\tdb1\r", &ids).?;
    try std.testing.expectEqualStrings("Servers", saved.name);
    try std.testing.expectEqual(Colors.c16, saved.colors);
    try std.testing.expectEqual(@as(usize, 2), saved.ids.len);
    try std.testing.expectEqualStrings("db1", saved.ids[1]);
    try std.testing.expect(parseSaved("Servers\t12\tweb1", &ids) == null);
    try std.testing.expect(parseSaved("Servers\t8", &ids) == null);

    const alloc = std.testing.allocator;
    const replaced = try replaceSaved(alloc, "A\t8\tx\nServers\t16\told\n", "Servers\t24\tnew", null);
    defer alloc.free(replaced);
    try std.testing.expectEqualStrings("A\t8\tx\nServers\t24\tnew\n", replaced);
    const added = try replaceSaved(alloc, "", "B\t8\ty", null);
    defer alloc.free(added);
    try std.testing.expectEqualStrings("B\t8\ty\n", added);
}

test "rdp group: a renamed group's line moves, and a new name skips saved ones" {
    const alloc = std.testing.allocator;
    const moved = try replaceSaved(alloc, "Group 1\t16\tweb\nB\t8\ty\n", "Servers\t16\tweb", "Group 1");
    defer alloc.free(moved);
    try std.testing.expectEqualStrings("Servers\t16\tweb\nB\t8\ty\n", moved);

    const name = try defaultName(alloc, "Group 1\t16\tweb\r\nGroup 3\t8\tx\n");
    defer alloc.free(name);
    try std.testing.expectEqualStrings("Group 2", name);
}

test "rdp group: TRACKMOUSEEVENT matches winuser.h" {
    try std.testing.expectEqual(@as(usize, if (@sizeOf(usize) == 8) 24 else 16), @sizeOf(TRACKMOUSEEVENT));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(TRACKMOUSEEVENT, "hwndTrack"));
    try std.testing.expectEqual(@as(usize, if (@sizeOf(usize) == 8) 16 else 12), @offsetOf(TRACKMOUSEEVENT, "dwHoverTime"));
}
