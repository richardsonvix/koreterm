//! The clipboard while a Remote Desktop session is hosted in a tab.
//!
//! The session's control (`rdp_pane.zig`, `RedirectClipboard`) runs in this
//! process. What is copied inside the remote desktop lands on this PC's
//! clipboard with delayed rendering: the control owns it, and the text is
//! fetched from the server only when something asks for it. That fetch is
//! answered on koreterm's UI thread, so a paste that asks for it from that
//! same thread (a terminal tab's Ctrl+Shift+V or context menu), or while
//! that thread is busy, waits on the server and can come back empty or
//! leave the window frozen; PSReadLine's own Ctrl+V, in the shell's process,
//! waits on it too.
//!
//! So the session holds the clipboard only while it has the focus:
//! - `release` (another tab takes the focus, or koreterm loses it) copies
//!   what the session owns into a plain local copy (text, image, HTML, RTF)
//!   on a worker thread, while the UI thread keeps answering the control.
//!   Copied files are left to the session: Explorer pastes them from it.
//! - `sessionOwns` tells a terminal's paste to read on a worker thread
//!   (`readText`) instead of the UI thread.
const std = @import("std");
const c = @import("consts.zig");
const sys = @import("sys.zig");
const types = @import("../win32_types.zig");

const HWND = types.HWND;
const UINT = types.UINT;
const DWORD = u32;
const L = std.unicode.utf8ToUtf16LeStringLiteral;
const log = std.log.scoped(.win32_rdp_clipboard);

extern "user32" fn GetClipboardOwner() callconv(.winapi) ?HWND;
extern "user32" fn GetWindowThreadProcessId(hwnd: HWND, process_id: ?*DWORD) callconv(.winapi) DWORD;

const CF_DIB: UINT = 8;

/// Open the clipboard from a worker thread, which may wait: another
/// program can hold it open for a moment. Not the facade's
/// `openClipboard`, whose 5 ms budget is for the UI thread. `owner` is the
/// window an `EmptyClipboard` makes the owner; null when only reading.
fn openClipboardFor(owner: ?HWND, attempts: usize) bool {
    for (0..attempts) |_| {
        if (sys.OpenClipboard(owner) != 0) return true;
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    return false;
}

/// 200 ms of tries: the release's own opens.
fn openClipboard() bool {
    return openClipboardFor(null, 20);
}

/// How long a paste's read waits for a release in progress (its fetch from
/// the server holds the clipboard open), then for the clipboard to open.
const read_wait_release_steps = 250; // 20 ms each: 5 s
const read_open_attempts = 100; // 10 ms each: 1 s

/// The worker threads take their memory here: never the app's allocator.
const worker_alloc = std.heap.page_allocator;

/// The clipboard's owner when it is a window of this process that koreterm
/// did not make: the session's control. Null otherwise (another program's
/// copy, koreterm's own copy, or a plain local copy with no owner).
pub fn sessionOwner() ?HWND {
    const owner = GetClipboardOwner() orelse return null;
    var pid: DWORD = 0;
    _ = GetWindowThreadProcessId(owner, &pid);
    if (pid != sys.GetCurrentProcessId()) return null;
    var name: [64]u16 = undefined;
    const len = sys.GetClassNameW(owner, &name, name.len);
    if (len <= 0) return owner;
    return if (isKoretermClass(name[0..@intCast(len)])) null else owner;
}

pub fn sessionOwns() bool {
    return sessionOwner() != null;
}

/// koreterm's own windows (`koreterm.win32*`) and the Win32 controls its
/// dialogs copy from write the clipboard at once, never delayed.
fn isKoretermClass(name: []const u16) bool {
    const prefix = L("koreterm.");
    if (name.len >= prefix.len and std.mem.eql(u16, name[0..prefix.len], prefix)) return true;
    for ([_][]const u16{ L("Edit"), L("EDIT"), L("RichEdit20W"), L("RICHEDIT50W") }) |control| {
        if (std.mem.eql(u16, name, control)) return true;
    }
    return false;
}

var releasing = std.atomic.Value(bool).init(false);

/// The session lost the focus: when it owns the clipboard, a worker thread
/// puts a local copy of it there instead, owned by `local_owner` (a
/// koreterm window, so `sessionOwner` never takes it for the session).
/// Nothing waits for it; a paste that finds the clipboard busy meanwhile
/// reads through `readText`, which waits for it.
pub fn release(local_owner: ?HWND) void {
    if (sessionOwner() == null) return;
    if (releasing.swap(true, .acq_rel)) return;
    const thread = std.Thread.spawn(.{}, releaseWorker, .{local_owner}) catch |err| {
        releasing.store(false, .release);
        log.warn("clipboard release thread failed err={}", .{err});
        return;
    };
    thread.detach();
}

const max_formats = 4;

const Held = struct {
    id: UINT,
    bytes: []u8,
};

fn releaseWorker(local_owner: ?HWND) void {
    defer releasing.store(false, .release);
    var held: [max_formats]Held = undefined;
    var count: usize = 0;
    defer for (held[0..count]) |entry| worker_alloc.free(entry.bytes);

    const owner = sessionOwner() orelse return;
    {
        if (!openClipboard()) return;
        defer _ = sys.CloseClipboard();
        // Copied files paste from the session itself (Explorer's paste
        // asks it for each file's bytes): leave them.
        if (sys.IsClipboardFormatAvailable(c.CF_HDROP) != 0) return;
        const file_group = sys.RegisterClipboardFormatW(L("FileGroupDescriptorW"));
        if (file_group != 0 and sys.IsClipboardFormatAvailable(file_group) != 0) return;
        const formats = [max_formats]UINT{
            c.CF_UNICODETEXT,
            CF_DIB,
            sys.RegisterClipboardFormatW(L("HTML Format")),
            sys.RegisterClipboardFormatW(L("Rich Text Format")),
        };
        for (formats) |id| {
            if (id == 0 or sys.IsClipboardFormatAvailable(id) == 0) continue;
            // The fetch from the server: the UI thread answers it.
            const bytes = copyFormat(id) orelse continue;
            held[count] = .{ .id = id, .bytes = bytes };
            count += 1;
        }
    }
    if (count == 0) return;
    // Something else was copied meanwhile: that copy stays.
    if (GetClipboardOwner() != owner) return;
    writeLocal(local_owner, held[0..count]);
}

/// The open clipboard's `id`, copied out of its global memory.
fn copyFormat(id: UINT) ?[]u8 {
    const handle = sys.GetClipboardData(id) orelse return null;
    const size = sys.GlobalSize(handle);
    if (size == 0) return null;
    const locked = sys.GlobalLock(handle) orelse return null;
    defer _ = sys.GlobalUnlock(handle);
    const from: [*]const u8 = @ptrCast(locked);
    return worker_alloc.dupe(u8, from[0..size]) catch null;
}

/// `held` on the clipboard, owned by `local_owner`: memory first, then the
/// empty (`clipboard_write`'s order), so a failed allocation loses nothing.
/// Not opened with a null owner when a window is at hand: EmptyClipboard
/// then leaves no owner, and the documentation says SetClipboardData fails
/// after that, which would leave the clipboard emptied.
fn writeLocal(local_owner: ?HWND, held: []const Held) void {
    var memory: [max_formats]?*anyopaque = .{null} ** max_formats;
    defer for (memory) |handle| if (handle) |h| {
        _ = sys.GlobalFree(h);
    };
    for (held, 0..) |entry, i| {
        const handle = sys.GlobalAlloc(c.GMEM_MOVEABLE, entry.bytes.len) orelse return;
        memory[i] = handle;
        const locked = sys.GlobalLock(handle) orelse return;
        const to: [*]u8 = @ptrCast(locked);
        @memcpy(to[0..entry.bytes.len], entry.bytes);
        _ = sys.GlobalUnlock(handle);
    }
    // The window may be gone (its pane closed): then no owner.
    if (!openClipboardFor(local_owner, 20) and
        (local_owner == null or !openClipboard()))
    {
        log.warn("session clipboard copy: the clipboard would not open", .{});
        return;
    }
    defer _ = sys.CloseClipboard();
    if (sys.EmptyClipboard() == 0) return;
    var set: usize = 0;
    for (held, 0..) |entry, i| {
        // The clipboard owns what it took.
        if (sys.SetClipboardData(entry.id, memory[i]) != null) {
            memory[i] = null;
            set += 1;
        }
    }
    if (set == 0) {
        log.warn("session clipboard copy set no format formats={}", .{held.len});
    } else {
        log.info("session clipboard kept as a local copy formats={} set={}", .{ held.len, set });
    }
}

/// What `readText` posts back: the clipboard's CF_UNICODETEXT, without its
/// terminator, in `worker_alloc`; null when there was none or it would not
/// open. `free` it.
pub const TextRead = struct {
    text_w: ?[]u16,
    opened: bool,

    pub fn free(self: *TextRead) void {
        if (self.text_w) |text| worker_alloc.free(text);
        worker_alloc.destroy(self);
    }
};

/// Read the clipboard's text on a worker thread, which posts `msg` to
/// `target` with `wparam` and a `*TextRead` as its lparam; the window's
/// handler frees it. When the window is gone the worker frees it. Used
/// while a session owns the clipboard, and for any paste whose UI-thread
/// open found the clipboard busy: it waits for a `release` in progress,
/// then tries to open it for a second.
pub fn readText(target: HWND, msg: UINT, wparam: usize) !void {
    const thread = try std.Thread.spawn(.{}, readWorker, .{ target, msg, wparam });
    thread.detach();
}

fn readWorker(target: HWND, msg: UINT, wparam: usize) void {
    const result = worker_alloc.create(TextRead) catch return;
    result.* = .{ .text_w = null, .opened = false };
    var waited: usize = 0;
    while (releasing.load(.acquire) and waited < read_wait_release_steps) : (waited += 1) {
        std.Thread.sleep(20 * std.time.ns_per_ms);
    }
    if (openClipboardFor(null, read_open_attempts)) {
        defer _ = sys.CloseClipboard();
        result.opened = true;
        if (sys.IsClipboardFormatAvailable(c.CF_UNICODETEXT) != 0) {
            if (sys.GetClipboardData(c.CF_UNICODETEXT)) |handle| {
                if (sys.GlobalLock(handle)) |locked| {
                    defer _ = sys.GlobalUnlock(handle);
                    const units = sys.GlobalSize(handle) / @sizeOf(u16);
                    const from: [*]const u16 = @ptrCast(@alignCast(locked));
                    const text = std.mem.sliceTo(from[0..units], 0);
                    result.text_w = worker_alloc.dupe(u16, text) catch null;
                }
            }
        }
    }
    if (sys.PostMessageW(target, msg, wparam, @bitCast(@intFromPtr(result))) == 0) result.free();
}

test "koreterm's own windows never count as the session" {
    try std.testing.expect(isKoretermClass(L("koreterm.win32")));
    try std.testing.expect(isKoretermClass(L("koreterm.win32.settings")));
    try std.testing.expect(isKoretermClass(L("Edit")));
    try std.testing.expect(!isKoretermClass(L("IHWindowClass")));
    try std.testing.expect(!isKoretermClass(L("kore")));
}
