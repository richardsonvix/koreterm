//! A Remote Desktop profile as a Windows `.rdp` file: the text mstsc.exe
//! saves and opens (`key:type:value` lines, UTF-16 LE with a BOM, CRLF).
//! The tab menu's "Export to Remote Desktop File (.rdp)..." and the
//! Profiles list menu's item of the same name write it.
//!
//! What goes in: the server and port, the user name kept for the profile,
//! and its quality settings (`terminals_import.RdpOptions`, each null one
//! taken from the config's `rdp-*` keys). The password never goes in: a
//! `.rdp` file can only hold it encrypted for this Windows account
//! (`password 51:b:`), so mstsc.exe asks for it.
const std = @import("std");
const Allocator = std.mem.Allocator;

const terminals_import = @import("terminals_import.zig");

/// The config's values for what a connection leaves at its default
/// (`rdp-color-depth`, `rdp-compression`, `rdp-experience`,
/// `rdp-trust-certificates`).
pub const Defaults = struct {
    colors: terminals_import.ColorDepth = .@"32",
    compression: bool = true,
    experience: terminals_import.Experience = .balanced,
    trust_certificates: bool = true,

    /// The defaults of `config` (a `Config`, taken by its fields).
    pub fn of(config: anytype) Defaults {
        return .{
            .colors = std.enums.fromInt(terminals_import.ColorDepth, @as(u8, @intCast(config.@"rdp-color-depth".bits()))) orelse .@"32",
            .compression = config.@"rdp-compression",
            .experience = switch (config.@"rdp-experience") {
                .fast => .fast,
                .balanced => .balanced,
                .rich => .rich,
            },
            .trust_certificates = config.@"rdp-trust-certificates",
        };
    }
};

/// The lines of the `.rdp` file of `connection`, signed in as `user`
/// (empty for none), as UTF-8 with CRLF line ends. A CR or LF in a value
/// is dropped: it would start a line of its own.
pub fn write(writer: *std.Io.Writer, connection: terminals_import.Connection, user: []const u8, defaults: Defaults) std.Io.Writer.Error!void {
    const options = connection.rdp;
    const colors = options.colors orelse defaults.colors;
    const compression = options.compression orelse defaults.compression;
    const experience = options.experience orelse defaults.experience;
    const trust = options.trust_certificates orelse defaults.trust_certificates;

    try line(writer, "screen mode id:i:2");
    try line(writer, "use multimon:i:0");
    try writer.print("session bpp:i:{d}\r\n", .{@intFromEnum(colors)});
    try writer.print("compression:i:{d}\r\n", .{@intFromBool(compression)});
    try line(writer, "keyboardhook:i:2");
    try line(writer, "audiomode:i:0");
    try line(writer, "redirectclipboard:i:1");
    try line(writer, "connection type:i:7");
    try line(writer, "networkautodetect:i:1");
    try line(writer, "bandwidthautodetect:i:1");
    try line(writer, "displayconnectionbar:i:1");
    try line(writer, "autoreconnection enabled:i:1");
    // 0 connects without asking about the server's identity; 2 shows
    // Windows' warning and lets the person go on.
    try writer.print("authentication level:i:{d}\r\n", .{@as(u8, if (trust) 0 else 2)});
    try line(writer, "prompt for credentials:i:0");
    try line(writer, "negotiate security layer:i:1");
    try line(writer, "bitmapcachepersistenable:i:1");

    // `rdp-experience`'s three looks, as its doc in Config.zig lists them.
    const look: struct { wallpaper: bool, themes: bool, smoothing: bool, composition: bool, anims: bool, drag: bool } = switch (experience) {
        .fast => .{ .wallpaper = false, .themes = false, .smoothing = false, .composition = false, .anims = false, .drag = false },
        .balanced => .{ .wallpaper = false, .themes = true, .smoothing = true, .composition = false, .anims = false, .drag = false },
        .rich => .{ .wallpaper = true, .themes = true, .smoothing = true, .composition = true, .anims = true, .drag = true },
    };
    try writer.print("disable wallpaper:i:{d}\r\n", .{@intFromBool(!look.wallpaper)});
    try writer.print("disable themes:i:{d}\r\n", .{@intFromBool(!look.themes)});
    try writer.print("allow font smoothing:i:{d}\r\n", .{@intFromBool(look.smoothing)});
    try writer.print("allow desktop composition:i:{d}\r\n", .{@intFromBool(look.composition)});
    try writer.print("disable menu anims:i:{d}\r\n", .{@intFromBool(!look.anims)});
    try writer.print("disable full window drag:i:{d}\r\n", .{@intFromBool(!look.drag)});

    try writer.writeAll("full address:s:");
    // An IPv6 address takes brackets before a port.
    const bracket = connection.port != 3389 and std.mem.indexOfScalar(u8, connection.server, ':') != null and
        (connection.server.len == 0 or connection.server[0] != '[');
    if (bracket) try writer.writeByte('[');
    try value(writer, connection.server);
    if (bracket) try writer.writeByte(']');
    if (connection.port != 3389) try writer.print(":{d}", .{connection.port});
    try writer.writeAll("\r\n");
    if (user.len != 0) {
        try writer.writeAll("username:s:");
        try value(writer, user);
        try writer.writeAll("\r\n");
    }
}

fn line(writer: *std.Io.Writer, comptime text: []const u8) std.Io.Writer.Error!void {
    try writer.writeAll(text ++ "\r\n");
}

fn value(writer: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    for (text) |byte| if (byte != '\r' and byte != '\n') try writer.writeByte(byte);
}

/// The file's bytes: `write`'s text as UTF-16 LE after a BOM, as mstsc.exe
/// saves it. Owned by `alloc`.
pub fn encode(a: Allocator, connection: terminals_import.Connection, user: []const u8, defaults: Defaults) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    write(&out.writer, connection, user, defaults) catch return error.OutOfMemory;
    const wide = std.unicode.wtf8ToWtf16LeAlloc(a, out.written()) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // Not WTF-8: each byte stands for itself.
        else => latin: {
            const units = try a.alloc(u16, out.written().len);
            for (out.written(), units) |byte, *unit| unit.* = byte;
            break :latin units;
        },
    };
    defer a.free(wide);
    const bytes = try a.alloc(u8, 2 + wide.len * 2);
    bytes[0] = 0xFF;
    bytes[1] = 0xFE;
    for (wide, 0..) |unit, i| std.mem.writeInt(u16, bytes[2 + i * 2 ..][0..2], unit, .little);
    return bytes;
}

/// `bytes` as the whole of the file at `path` (a plain Win32 path, as a
/// file dialog returns it), made or replaced.
pub fn writeFile(a: Allocator, path: [:0]const u16, bytes: []const u8) !void {
    // `std.fs` takes the path as WTF-8.
    const path_utf8 = try std.unicode.wtf16LeToWtf8Alloc(a, path);
    defer a.free(path_utf8);
    const file = try std.fs.createFileAbsolute(path_utf8, .{ .truncate = true });
    defer file.close();
    try file.writeAll(bytes);
}

/// A file name for the profile `name` (`fallback` when it has nothing a
/// name can hold): `<name>.rdp` in UTF-16, the characters Windows refuses
/// in a name as `_`, in `buf`.
pub fn fileName(buf: []u16, name: []const u8, fallback: []const u8) []const u16 {
    std.debug.assert(buf.len >= 16);
    const room = buf.len - 4;
    var len: usize = 0;
    var view = std.unicode.Utf8View.init(name) catch std.unicode.Utf8View.initUnchecked(fallback);
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        const units: usize = if (cp >= 0x10000) 2 else 1;
        if (len + units > room) break;
        const refused = cp < 0x20 or switch (cp) {
            '<', '>', ':', '"', '/', '\\', '|', '?', '*' => true,
            else => false,
        };
        if (refused) {
            buf[len] = '_';
            len += 1;
        } else if (units == 2) {
            const high: u16 = @intCast(0xD800 + ((cp - 0x10000) >> 10));
            const low: u16 = @intCast(0xDC00 + ((cp - 0x10000) & 0x3FF));
            buf[len] = high;
            buf[len + 1] = low;
            len += 2;
        } else {
            buf[len] = @intCast(cp);
            len += 1;
        }
    }
    // Windows drops trailing dots and spaces from a name.
    while (len != 0 and (buf[len - 1] == '.' or buf[len - 1] == ' ')) len -= 1;
    if (len == 0) {
        for (fallback[0..@min(fallback.len, room)]) |byte| {
            buf[len] = if (byte < 0x20 or byte >= 0x80) '_' else byte;
            len += 1;
        }
        if (len == 0) {
            for ("remote") |byte| {
                buf[len] = byte;
                len += 1;
            }
        }
    }
    for (".rdp") |byte| {
        buf[len] = byte;
        len += 1;
    }
    return buf[0..len];
}

test "write: server, port, user and the connection's own settings" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try write(&out.writer, .{
        .protocol = .rdp,
        .server = "srv.example",
        .port = 5006,
        .rdp = .{ .colors = .@"16", .compression = false, .experience = .fast, .trust_certificates = false },
    }, "DOMAIN\\ana", .{});
    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "full address:s:srv.example:5006\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "username:s:DOMAIN\\ana\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "session bpp:i:16\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "compression:i:0\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "authentication level:i:2\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "disable themes:i:1\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "allow font smoothing:i:0\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "password") == null);
}

test "write: defaults fill what the connection leaves out; 3389 is not written" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try write(&out.writer, .{ .protocol = .rdp, .server = "10.0.0.5", .port = 3389 }, "", .{ .colors = .@"24", .experience = .rich });
    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "full address:s:10.0.0.5\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "session bpp:i:24\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "authentication level:i:0\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "disable wallpaper:i:0\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "username:") == null);
}

test "write: IPv6 takes brackets before a port, and a newline in a value is dropped" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try write(&out.writer, .{ .protocol = .rdp, .server = "fe80::1", .port = 4000 }, "a\r\nfull address:s:evil", .{});
    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "full address:s:[fe80::1]:4000\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\r\nfull address:s:evil") == null);
}

test "encode: UTF-16 LE after a BOM" {
    const bytes = try encode(std.testing.allocator, .{ .protocol = .rdp, .server = "sé", .port = 3389 }, "", .{});
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xFF, 0xFE }, bytes[0..2]);
    try std.testing.expect(bytes.len % 2 == 0);
    try std.testing.expect(std.mem.indexOf(u8, bytes, &[_]u8{ ':', 0, 's', 0, 0xE9, 0, 0x0D, 0 }) != null);
}

test "fileName: refused characters, trailing dots and the fallback" {
    var buf: [64]u16 = undefined;
    try std.testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("a_b_c.rdp"), fileName(&buf, "a/b:c", "x"));
    try std.testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("srv.rdp"), fileName(&buf, " .", "srv"));
    try std.testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("CND01.rdp"), fileName(&buf, "CND01", "srv"));
}
