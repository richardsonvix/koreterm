//! Send Files for a Remote Desktop tab whose connection shares a transfer
//! folder (`terminals_import.RdpOptions.transfer`, `/transfer:on`).
//!
//! Each such connection has a folder on this PC,
//! `%USERPROFILE%\koreterm-transfer\<connection>`. While its tab is open,
//! the session gets that folder, and only that folder, as a redirected
//! drive: the Remote Desktop control redirects drives, not folders, so the
//! folder gets a drive letter first (`mapDrive`, `DefineDosDeviceW`, in
//! this logon session only) and the control redirects that letter alone
//! (`rdp_pane.Pane.shareTransfer`). On the server it is `\\tsclient\<letter>`.
//!
//! The tab menu's Send Files copies the picked files into the folder
//! (`copyInto`): they are on the server at once, with nobody using the
//! session, and stay there for as long as the tab is connected. The files
//! live on this PC: they reach the server only through the session.
const std = @import("std");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.rdp_transfer);

const DDD_REMOVE_DEFINITION: u32 = 0x2;
extern "kernel32" fn DefineDosDeviceW(flags: u32, device: [*:0]const u16, target: ?[*:0]const u16) callconv(.winapi) std.os.windows.BOOL;
extern "kernel32" fn GetLogicalDrives() callconv(.winapi) u32;
extern "kernel32" fn CopyFileW(from: [*:0]const u16, to: [*:0]const u16, fail_if_exists: std.os.windows.BOOL) callconv(.winapi) std.os.windows.BOOL;

/// The folder's name for a connection: its profile id, else
/// `<server>_<port>`, with what a file name cannot hold as `_`.
pub fn folderName(buf: []u8, profile_id: ?[]const u8, server: []const u8, port: u16) []const u8 {
    const raw = if (profile_id) |id| (if (id.len != 0) id else null) else null;
    var fallback: [300]u8 = undefined;
    const name = raw orelse (std.fmt.bufPrint(&fallback, "{s}_{d}", .{ server, port }) catch server);
    var len: usize = 0;
    for (name) |byte| {
        if (len == buf.len) break;
        buf[len] = switch (byte) {
            '<', '>', ':', '"', '/', '\\', '|', '?', '*' => '_',
            else => if (byte < 0x20) '_' else byte,
        };
        len += 1;
    }
    while (len != 0 and (buf[len - 1] == '.' or buf[len - 1] == ' ')) len -= 1;
    if (len == 0) {
        const none = "remote";
        @memcpy(buf[0..none.len], none);
        len = none.len;
    }
    return buf[0..len];
}

/// The connection's folder (`folderName` under
/// `%USERPROFILE%\koreterm-transfer`), made when missing. Owned by `alloc`.
pub fn folder(alloc: Allocator, profile_id: ?[]const u8, server: []const u8, port: u16) ![]u8 {
    const home = try std.process.getEnvVarOwned(alloc, "USERPROFILE");
    defer alloc.free(home);
    var name_buf: [128]u8 = undefined;
    const name = folderName(&name_buf, profile_id, server, port);
    const path = try std.fs.path.join(alloc, &.{ home, "koreterm-transfer", name });
    errdefer alloc.free(path);
    try std.fs.cwd().makePath(path);
    return path;
}

/// The last free drive letter from Z down to H in `used` (`GetLogicalDrives`'
/// mask), or null.
pub fn freeLetter(used: u32) ?u8 {
    var letter: u8 = 'Z';
    while (letter >= 'H') : (letter -= 1) {
        if (used & (@as(u32, 1) << @intCast(letter - 'A')) == 0) return letter;
    }
    return null;
}

/// Give `path` (a folder) a drive letter in this logon session, for the
/// control to redirect. Null when no letter is free or Windows refused.
pub fn mapDrive(path: []const u8) ?u8 {
    const letter = freeLetter(GetLogicalDrives()) orelse {
        log.warn("rdp transfer: no free drive letter for the transfer folder", .{});
        return null;
    };
    var device = [_:0]u16{ letter, ':' };
    var target: [std.fs.max_path_bytes:0]u16 = undefined;
    const len = std.unicode.wtf8ToWtf16Le(&target, path) catch return null;
    if (len >= target.len) return null;
    target[len] = 0;
    if (DefineDosDeviceW(0, &device, target[0..len :0].ptr) == 0) {
        log.warn("rdp transfer: the transfer folder got no drive letter err={}", .{std.os.windows.kernel32.GetLastError()});
        return null;
    }
    return letter;
}

/// Take back the letter `mapDrive` gave.
pub fn unmapDrive(letter: u8) void {
    var device = [_:0]u16{ letter, ':' };
    _ = DefineDosDeviceW(DDD_REMOVE_DEFINITION, &device, null);
}

/// Copy each of `paths` into `dir`, replacing a file of the same name.
/// The number copied.
pub fn copyInto(alloc: Allocator, dir: []const u8, paths: []const []const u8) usize {
    var copied: usize = 0;
    for (paths) |from| {
        const to = std.fs.path.join(alloc, &.{ dir, std.fs.path.basenameWindows(from) }) catch continue;
        defer alloc.free(to);
        const from_w = std.unicode.wtf8ToWtf16LeAllocZ(alloc, from) catch continue;
        defer alloc.free(from_w);
        const to_w = std.unicode.wtf8ToWtf16LeAllocZ(alloc, to) catch continue;
        defer alloc.free(to_w);
        if (CopyFileW(from_w.ptr, to_w.ptr, 0) != 0) {
            copied += 1;
        } else {
            log.warn("rdp transfer: a file could not be copied err={}", .{std.os.windows.kernel32.GetLastError()});
        }
    }
    return copied;
}

test "folderName: the profile id, else server and port, as a file name" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("cnd-5006-cnd01", folderName(&buf, "cnd-5006-cnd01", "x", 1));
    try std.testing.expectEqualStrings("srv.example_5001", folderName(&buf, null, "srv.example", 5001));
    try std.testing.expectEqualStrings("fe80__1_4000", folderName(&buf, null, "fe80::1", 4000));
    try std.testing.expectEqualStrings("remote", folderName(&buf, " .", "x", 1));
}

test "freeLetter: the last free letter from Z down to H" {
    try std.testing.expectEqual(@as(?u8, 'Z'), freeLetter(0));
    const z: u32 = 1 << ('Z' - 'A');
    const y: u32 = 1 << ('Y' - 'A');
    try std.testing.expectEqual(@as(?u8, 'X'), freeLetter(z | y));
    try std.testing.expectEqual(@as(?u8, null), freeLetter(0x03FF_FFFF));
}

test "copyInto: copies and replaces by name" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("out");
    try tmp.dir.writeFile(.{ .sub_path = "a.txt", .data = "one" });
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const src = try std.fs.path.join(std.testing.allocator, &.{ root, "a.txt" });
    defer std.testing.allocator.free(src);
    const out = try std.fs.path.join(std.testing.allocator, &.{ root, "out" });
    defer std.testing.allocator.free(out);
    try std.testing.expectEqual(@as(usize, 1), copyInto(std.testing.allocator, out, &.{src}));
    try tmp.dir.writeFile(.{ .sub_path = "a.txt", .data = "two" });
    try std.testing.expectEqual(@as(usize, 1), copyInto(std.testing.allocator, out, &.{src}));
    const got = try tmp.dir.readFileAlloc(std.testing.allocator, "out/a.txt", 16);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("two", got);
}
