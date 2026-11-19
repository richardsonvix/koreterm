//! The session an elevated koreterm (a split token's full half) saves and
//! restores: a file of its own, `elevated\session-state.json` in the data
//! folder, apart from the ordinary instance's `session-state.json`, so
//! neither replaces the other's windows.
//!
//! What a restore reopens runs as administrator, so a process at medium
//! integrity must not be able to write it. The elevated process makes the
//! folder itself (`ensureDir`) with the Administrators group as owner and a
//! protected DACL: SYSTEM and Administrators full, the user read. Files made
//! in it inherit that. Before a restore the file is checked (`openChecked`,
//! `adminOnly`) through a handle that, while it is open, keeps the file from
//! being changed or renamed and its folder from being renamed, so what is
//! read is what was checked. A folder or file a medium process made or can
//! write is refused, and the elevated instance then keeps no session.
//!
//! An ordinary instance reads only the file's time (`savedLater`), to say at
//! startup that the last tabs were saved by an elevated instance.
const std = @import("std");
const windows = std.os.windows;

const sys = @import("sys.zig");
const c = @import("consts.zig");

const log = std.log.scoped(.win32_session);

/// The folder, under the data folder.
pub const dir_name = "elevated";
/// The session file, under the data folder.
pub const file_name = "elevated\\session-state.json";
/// The ordinary instance's session file, under the data folder.
pub const ordinary_file_name = "session-state.json";

const SE_FILE_OBJECT: u32 = 1;
const OWNER_SECURITY_INFORMATION: u32 = 0x1;
const DACL_SECURITY_INFORMATION: u32 = 0x4;
const SDDL_REVISION_1: u32 = 1;
const WinLocalSystemSid: u32 = 22;
const WinBuiltinAdministratorsSid: u32 = 26;
const INHERIT_ONLY_ACE: u8 = 0x08;
const ERROR_ALREADY_EXISTS: u32 = 183;

/// Rights that let a holder change what is restored: the data (for a
/// folder, adding files or folders, deleting children), the DACL or owner,
/// and the generic rights that include them.
const write_rights: u32 = 0x2 | 0x4 | 0x40 | 0x40000 | 0x80000 | 0x10000000 | 0x40000000;

const ACE_HEADER = extern struct { AceType: u8, AceFlags: u8, AceSize: u16 };
const ACCESS_ALLOWED_ACE = extern struct { Header: ACE_HEADER, Mask: u32, SidStart: u32 };
const ACL = extern struct { AclRevision: u8, Sbz1: u8, AclSize: u16, AceCount: u16, Sbz2: u16 };

extern "advapi32" fn IsWellKnownSid(sid: *anyopaque, kind: u32) callconv(.winapi) windows.BOOL;
extern "advapi32" fn GetAce(acl: *anyopaque, index: u32, ace: *?*anyopaque) callconv(.winapi) windows.BOOL;
extern "advapi32" fn GetSecurityDescriptorDacl(sd: *anyopaque, present: *windows.BOOL, dacl: *?*anyopaque, defaulted: *windows.BOOL) callconv(.winapi) windows.BOOL;
extern "kernel32" fn CreateDirectoryW(path: [*:0]const u16, attributes: ?*windows.SECURITY_ATTRIBUTES) callconv(.winapi) windows.BOOL;

fn isAdminSid(sid: *anyopaque) bool {
    return IsWellKnownSid(sid, WinBuiltinAdministratorsSid) != 0 or IsWellKnownSid(sid, WinLocalSystemSid) != 0;
}

/// Whether only Administrators and SYSTEM may write through `dacl`. A
/// deny ACE never lets anyone in; an inherit-only one does not apply to
/// the object itself. An allow ACE whose SID cannot be read here (object
/// and compound types) is refused when it grants a write.
fn aclAdminWriteOnly(dacl: *anyopaque) bool {
    const acl: *const ACL = @ptrCast(@alignCast(dacl));
    var i: u32 = 0;
    while (i < acl.AceCount) : (i += 1) {
        var raw: ?*anyopaque = null;
        if (GetAce(dacl, i, &raw) == 0) return false;
        const header: *const ACE_HEADER = @ptrCast(@alignCast(raw orelse return false));
        if (header.AceFlags & INHERIT_ONLY_ACE != 0) continue;
        switch (header.AceType) {
            // Deny: plain, object, callback, callback object.
            1, 6, 10, 12 => continue,
            // Allow, plain or callback: the SID follows the mask.
            0, 9 => {
                const ace: *ACCESS_ALLOWED_ACE = @ptrCast(@alignCast(raw.?));
                if (ace.Mask & write_rights == 0) continue;
                if (!isAdminSid(@ptrCast(&ace.SidStart))) return false;
            },
            else => {
                const ace: *const ACCESS_ALLOWED_ACE = @ptrCast(@alignCast(raw.?));
                if (ace.Mask & write_rights != 0) return false;
            },
        }
    }
    return true;
}

/// Whether the file or folder open as `handle` is owned by Administrators
/// (or SYSTEM) and only they may write it.
pub fn adminOnly(handle: windows.HANDLE) bool {
    var owner: ?*anyopaque = null;
    var dacl: ?*anyopaque = null;
    var sd: ?*anyopaque = null;
    if (sys.GetSecurityInfo(handle, SE_FILE_OBJECT, OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION, &owner, null, &dacl, null, &sd) != 0) return false;
    defer _ = sys.LocalFree(sd);
    if (!isAdminSid(owner orelse return false)) return false;
    // A null DACL lets everyone in.
    return aclAdminWriteOnly(dacl orelse return false);
}

/// Open `path` (a file, or a folder with `folder`) to check it: read
/// access, shared only for reading, so while the handle is open nobody
/// writes, deletes or renames it, nor renames the folder it is in.
fn openForCheck(path: []const u8, folder: bool) ?windows.HANDLE {
    var buf: [std.fs.max_path_bytes]u16 = undefined;
    const len = std.unicode.wtf8ToWtf16Le(&buf, path) catch return null;
    if (len >= buf.len) return null;
    buf[len] = 0;
    const FILE_FLAG_BACKUP_SEMANTICS: u32 = 0x02000000;
    const handle = windows.kernel32.CreateFileW(
        buf[0..len :0].ptr,
        windows.GENERIC_READ,
        windows.FILE_SHARE_READ,
        null,
        windows.OPEN_EXISTING,
        if (folder) FILE_FLAG_BACKUP_SEMANTICS else 0,
        null,
    );
    if (handle == windows.INVALID_HANDLE_VALUE) return null;
    return handle;
}

/// The session file at `path`, opened and checked (`adminOnly`). Null when
/// it is missing or a medium process could have written it (logged). The
/// caller reads the file by its path while the handle is open, then closes
/// it.
pub fn openChecked(path: []const u8) ?windows.HANDLE {
    const handle = openForCheck(path, false) orelse return null;
    if (adminOnly(handle)) return handle;
    windows.CloseHandle(handle);
    log.warn("win32 session: the elevated session file is not admin-only; not restoring it", .{});
    return null;
}

/// The user's SID as SDDL text, in `out`.
fn userSid(out: []u16) ?[]const u16 {
    var token: windows.HANDLE = undefined;
    if (sys.OpenProcessToken(windows.kernel32.GetCurrentProcess(), c.TOKEN_QUERY, &token) == 0) return null;
    defer windows.CloseHandle(token);
    var buf: [256]u8 align(@alignOf(sys.TOKEN_USER)) = undefined;
    var len: u32 = 0;
    if (sys.GetTokenInformation(token, c.TokenUser, &buf, buf.len, &len) == 0) return null;
    const user: *const sys.TOKEN_USER = @ptrCast(&buf);
    var text: ?[*:0]u16 = null;
    if (sys.ConvertSidToStringSidW(user.User.Sid, &text) == 0) return null;
    const sid = text orelse return null;
    defer _ = sys.LocalFree(@ptrCast(sid));
    const span = std.mem.span(sid);
    if (span.len > out.len) return null;
    @memcpy(out[0..span.len], span);
    return out[0..span.len];
}

/// The folder's descriptor: owner Administrators, a protected DACL with
/// SYSTEM and Administrators full and `user` read, inherited by what is
/// made in it.
fn folderSddl(buf: []u16, user: []const u16) ?[:0]const u16 {
    const head = std.unicode.utf8ToUtf16LeStringLiteral("O:BAD:PAI(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;FR;;;");
    const tail = std.unicode.utf8ToUtf16LeStringLiteral(")");
    const len = head.len + user.len + tail.len;
    if (len + 1 > buf.len) return null;
    @memcpy(buf[0..head.len], head);
    @memcpy(buf[head.len..][0..user.len], user);
    @memcpy(buf[head.len + user.len ..][0..tail.len], tail);
    buf[len] = 0;
    return buf[0..len :0];
}

/// Make the folder at `dir_path` (`dir_name` in the data folder) admin-only,
/// or check the one there. False when it cannot be made, or one is there
/// that a medium process made or can write (logged): the elevated instance
/// then keeps no session.
pub fn ensureDir(dir_path: []const u8) bool {
    if (std.fs.path.dirname(dir_path)) |parent| std.fs.cwd().makePath(parent) catch {};
    var path_buf: [std.fs.max_path_bytes]u16 = undefined;
    const len = std.unicode.wtf8ToWtf16Le(&path_buf, dir_path) catch return false;
    if (len >= path_buf.len) return false;
    path_buf[len] = 0;

    var sid_buf: [184]u16 = undefined;
    const sid = userSid(&sid_buf) orelse return false;
    var sddl_buf: [320]u16 = undefined;
    const sddl = folderSddl(&sddl_buf, sid) orelse return false;
    var sd: ?*anyopaque = null;
    if (sys.ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl.ptr, SDDL_REVISION_1, &sd, null) == 0) return false;
    defer _ = sys.LocalFree(sd);
    var attributes: windows.SECURITY_ATTRIBUTES = .{
        .nLength = @sizeOf(windows.SECURITY_ATTRIBUTES),
        .lpSecurityDescriptor = sd,
        .bInheritHandle = windows.FALSE,
    };
    if (CreateDirectoryW(path_buf[0..len :0].ptr, &attributes) != 0) return true;
    const err: u32 = @intFromEnum(windows.kernel32.GetLastError());
    if (err != ERROR_ALREADY_EXISTS) {
        log.warn("win32 session: the elevated session folder could not be made err={d}", .{err});
        return false;
    }
    const handle = openForCheck(dir_path, true) orelse return false;
    defer windows.CloseHandle(handle);
    if (adminOnly(handle)) return true;
    log.warn("win32 session: the elevated session folder is not admin-only; the elevated instance keeps no session", .{});
    return false;
}

/// Whether the elevated session file at `elevated_path` was written after
/// the ordinary one at `ordinary_path` (or there is no ordinary one): the
/// last tabs saved were an elevated instance's.
pub fn savedLater(elevated_path: []const u8, ordinary_path: []const u8) bool {
    const elevated = std.fs.cwd().statFile(elevated_path) catch return false;
    const ordinary = std.fs.cwd().statFile(ordinary_path) catch return true;
    return elevated.mtime > ordinary.mtime;
}

/// What an ordinary instance says at startup when `savedLater`.
pub const saved_later_notice = "The last tabs were saved by koreterm running as administrator, so they are not restored here. Run koreterm as administrator to get them back.";

fn testDacl(sddl: []const u8) !struct { sd: *anyopaque, dacl: *anyopaque } {
    var buf: [256]u16 = undefined;
    const len = try std.unicode.utf8ToUtf16Le(&buf, sddl);
    buf[len] = 0;
    var sd: ?*anyopaque = null;
    if (sys.ConvertStringSecurityDescriptorToSecurityDescriptorW(buf[0..len :0].ptr, SDDL_REVISION_1, &sd, null) == 0) return error.Sddl;
    var present: windows.BOOL = 0;
    var defaulted: windows.BOOL = 0;
    var dacl: ?*anyopaque = null;
    if (GetSecurityDescriptorDacl(sd.?, &present, &dacl, &defaulted) == 0 or present == 0) return error.Dacl;
    return .{ .sd = sd.?, .dacl = dacl.? };
}

test "aclAdminWriteOnly: SYSTEM and Administrators full with the user reading passes" {
    const t = try testDacl("D:PAI(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;FR;;;S-1-5-21-1-2-3-1001)");
    defer _ = sys.LocalFree(t.sd);
    try std.testing.expect(aclAdminWriteOnly(t.dacl));
}

test "aclAdminWriteOnly: a user or Everyone who may write is refused" {
    const user = try testDacl("D:(A;;FA;;;SY)(A;;FA;;;BA)(A;;FA;;;S-1-5-21-1-2-3-1001)");
    defer _ = sys.LocalFree(user.sd);
    try std.testing.expect(!aclAdminWriteOnly(user.dacl));
    const everyone = try testDacl("D:(A;;FA;;;BA)(A;;FW;;;WD)");
    defer _ = sys.LocalFree(everyone.sd);
    try std.testing.expect(!aclAdminWriteOnly(everyone.dacl));
    const dacl_writer = try testDacl("D:(A;;FA;;;BA)(A;;WD;;;AU)");
    defer _ = sys.LocalFree(dacl_writer.sd);
    try std.testing.expect(!aclAdminWriteOnly(dacl_writer.dacl));
}

test "aclAdminWriteOnly: deny and inherit-only ACEs do not count" {
    const t = try testDacl("D:(D;;FA;;;WD)(A;OICIIO;FA;;;AU)(A;;FA;;;BA)");
    defer _ = sys.LocalFree(t.sd);
    try std.testing.expect(aclAdminWriteOnly(t.dacl));
}

test "folderSddl: the user's SID goes in the read ACE" {
    var buf: [320]u16 = undefined;
    const sddl = folderSddl(&buf, std.unicode.utf8ToUtf16LeStringLiteral("S-1-5-21-9")).?;
    var out: [320]u8 = undefined;
    const n = try std.unicode.utf16LeToUtf8(&out, sddl);
    try std.testing.expectEqualStrings("O:BAD:PAI(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;FR;;;S-1-5-21-9)", out[0..n]);
}

test "savedLater: only an elevated file newer than the ordinary one counts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const elevated = try std.fs.path.join(std.testing.allocator, &.{ root, "e.json" });
    defer std.testing.allocator.free(elevated);
    const ordinary = try std.fs.path.join(std.testing.allocator, &.{ root, "o.json" });
    defer std.testing.allocator.free(ordinary);
    try std.testing.expect(!savedLater(elevated, ordinary));
    try tmp.dir.writeFile(.{ .sub_path = "e.json", .data = "{}" });
    try std.testing.expect(savedLater(elevated, ordinary));
    try tmp.dir.writeFile(.{ .sub_path = "o.json", .data = "{}" });
    const e = try tmp.dir.openFile("e.json", .{ .mode = .read_write });
    defer e.close();
    try e.updateTimes(0, 1_000_000_000);
    try std.testing.expect(!savedLater(elevated, ordinary));
}
