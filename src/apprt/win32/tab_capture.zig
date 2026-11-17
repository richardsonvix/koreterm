//! A tab's snapshot and recording, from its right-click menu.
//!
//! Both read the tab's area off the screen (`Canvas.grab`, a BitBlt from the
//! screen's DC): a terminal pane is drawn by OpenGL or D3D11 and a Remote
//! Desktop pane is an ActiveX control, and `PrintWindow` leaves the first
//! white (docs/agents/log/docs-and-site.md, 2026-10-20). So only what can be
//! seen is captured: while the tab is hidden behind another tab, minimized
//! or covered by another window (`Target.rect` returns null), a recording
//! repeats its last frame, and nothing of the covering window gets in.
//!
//! - **Snapshot**: a PNG at the tab's full size, written by GDI+, a quarter
//!   of a second after the menu closed so the menu is not in it.
//! - **Recording**: an MP4 (H.264) written by Media Foundation's sink writer
//!   on its own thread (`Recorder.run`), at the preset's frame rate, width
//!   and bitrate (`preset`). The screen is read on the UI thread by a timer
//!   (`tick`); the encoder takes the latest frame it left. One tab records
//!   at a time.
//!
//! GDI+ and Media Foundation are loaded when first used (`Gdiplus.load`,
//! `Mf.load`), not imported: Windows "N" editions ship without Media
//! Foundation, and koreterm starts there all the same.
//!
//! Files go to `tab-capture-folder`, or the Downloads folder, named after
//! the tab and the time (`fileName`). Nothing here logs a path or a title.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const win32_types = @import("../win32_types.zig");
const BOOL = win32_types.BOOL;
const GUID = win32_types.GUID;
const HWND = win32_types.HWND;
const HRESULT = i32;

const log = std.log.scoped(.tab_capture);
const L = std.unicode.utf8ToUtf16LeStringLiteral;

// --- What is captured ------------------------------------------------------

/// `tab-capture-quality`.
pub const Quality = enum { low, normal, high };

pub const Preset = struct {
    fps: u32,
    /// Wider tabs are scaled down to this.
    max_width: u32,
    /// Bits a pixel a frame, in thousandths, for the bitrate.
    milli_bits_per_pixel: u32,
};

pub fn preset(quality: Quality) Preset {
    return switch (quality) {
        .low => .{ .fps = 5, .max_width = 1280, .milli_bits_per_pixel = 60 },
        .normal => .{ .fps = 10, .max_width = 1920, .milli_bits_per_pixel = 80 },
        .high => .{ .fps = 20, .max_width = 2560, .milli_bits_per_pixel = 100 },
    };
}

pub const Size = struct { width: u32, height: u32 };

/// The video's frame for a tab of `width` x `height`: scaled down to
/// `max_width`, keeping its shape, both sides even (H.264 takes 4:2:0) and
/// at least 2.
pub fn frameSize(width: u32, height: u32, max_width: u32) Size {
    var w: u64 = @max(width, 2);
    var h: u64 = @max(height, 2);
    if (w > max_width) {
        h = h * max_width / w;
        w = max_width;
    }
    return .{ .width = @intCast(@max(2, w & ~@as(u64, 1))), .height = @intCast(@max(2, h & ~@as(u64, 1))) };
}

/// The video's bitrate, in bits a second: at least 300 kbit/s.
pub fn bitrate(size: Size, p: Preset) u32 {
    const bits: u64 = @as(u64, size.width) * size.height * p.fps * p.milli_bits_per_pixel / 1000;
    return @intCast(std.math.clamp(bits, 300_000, 40_000_000));
}

/// A rectangle on the screen, in physical pixels.
pub const Rect = struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,

    pub fn width(self: Rect) i32 {
        return self.right - self.left;
    }
    pub fn height(self: Rect) i32 {
        return self.bottom - self.top;
    }
};

/// The tab a capture is of.
pub const Target = struct {
    ctx: *anyopaque,
    /// The tab's area on the screen, when it can be seen whole: null while
    /// it is behind another tab, minimized or covered.
    rect: *const fn (ctx: *anyopaque) ?Rect,
    /// Say how a capture went (a banner over the tab).
    notify: *const fn (ctx: *anyopaque, message: []const u8) void,
};

// --- Where it goes ---------------------------------------------------------

const FOLDERID_Downloads = GUID.parse("{374DE290-123F-4565-9164-39C4925E467B}");
extern "shell32" fn SHGetKnownFolderPath(id: *const GUID, flags: u32, token: ?*anyopaque, path: *?[*:0]u16) callconv(.winapi) HRESULT;
extern "ole32" fn CoTaskMemFree(memory: ?*anyopaque) callconv(.winapi) void;

/// The folder captures are saved in, WTF-8 in `alloc`: `configured` when it
/// is set, else the Downloads folder.
pub fn folder(alloc: Allocator, configured: ?[]const u8) ![]u8 {
    if (configured) |text| {
        const trimmed = std.mem.trim(u8, text, " \t\"");
        if (trimmed.len != 0) return alloc.dupe(u8, trimmed);
    }
    var path: ?[*:0]u16 = null;
    if (SHGetKnownFolderPath(&FOLDERID_Downloads, 0, null, &path) < 0) {
        CoTaskMemFree(path);
        return error.NoDownloadsFolder;
    }
    defer CoTaskMemFree(path);
    return std.unicode.wtf16LeToWtf8Alloc(alloc, std.mem.span(path orelse return error.NoDownloadsFolder));
}

const SYSTEMTIME = extern struct {
    year: u16,
    month: u16,
    day_of_week: u16,
    day: u16,
    hour: u16,
    minute: u16,
    second: u16,
    milliseconds: u16,
};
extern "kernel32" fn GetLocalTime(time: *SYSTEMTIME) callconv(.winapi) void;

/// `koreterm <title> <yyyy-mm-dd hh.mm.ss>.<ext>` in `buf`: the title with
/// what a file name cannot hold made `_`, at most 60 bytes of it, or `tab`.
pub fn fileName(buf: []u8, title: []const u8, ext: []const u8, time: SYSTEMTIME) ![]const u8 {
    var clean: [64]u8 = undefined;
    var len: usize = 0;
    var view = std.unicode.Utf8View.init(title) catch std.unicode.Utf8View.initUnchecked("");
    var it = view.iterator();
    while (it.nextCodepointSlice()) |slice| {
        if (len + slice.len > 60) break;
        if (slice.len == 1) {
            const byte = slice[0];
            const bad = byte < 0x20 or byte == 0x7F or std.mem.indexOfScalar(u8, "<>:\"/\\|?*", byte) != null;
            clean[len] = if (bad) '_' else byte;
            len += 1;
        } else {
            @memcpy(clean[len..][0..slice.len], slice);
            len += slice.len;
        }
    }
    const name = std.mem.trim(u8, clean[0..len], " .");
    return std.fmt.bufPrint(buf, "koreterm {s} {d:0>4}-{d:0>2}-{d:0>2} {d:0>2}.{d:0>2}.{d:0>2}.{s}", .{
        if (name.len == 0) "tab" else name,
        time.year,
        time.month,
        time.day,
        time.hour,
        time.minute,
        time.second,
        ext,
    });
}

/// A new file's path in `dir` for `title`, WTF-8 in `alloc`: ` (2)`, ` (3)`
/// ... before the extension when the name is taken. The folder is made
/// when it is missing.
fn newPath(alloc: Allocator, dir: []const u8, title: []const u8, ext: []const u8) ![]u8 {
    std.fs.cwd().makePath(dir) catch {};
    var time: SYSTEMTIME = undefined;
    GetLocalTime(&time);
    var name_buf: [160]u8 = undefined;
    const name = try fileName(&name_buf, title, ext, time);
    const stem = name[0 .. name.len - ext.len - 1];
    var n: u32 = 1;
    while (n < 100) : (n += 1) {
        const path = if (n == 1)
            try std.fs.path.join(alloc, &.{ dir, name })
        else path: {
            const numbered = try std.fmt.allocPrint(alloc, "{s} ({d}).{s}", .{ stem, n, ext });
            defer alloc.free(numbered);
            break :path try std.fs.path.join(alloc, &.{ dir, numbered });
        };
        std.fs.cwd().access(path, .{}) catch return path;
        alloc.free(path);
    }
    return error.NameTaken;
}

// --- The screen ------------------------------------------------------------

const BITMAPINFOHEADER = extern struct {
    biSize: u32 = @sizeOf(BITMAPINFOHEADER),
    biWidth: i32,
    biHeight: i32,
    biPlanes: u16 = 1,
    biBitCount: u16 = 32,
    biCompression: u32 = 0,
    biSizeImage: u32 = 0,
    biXPelsPerMeter: i32 = 0,
    biYPelsPerMeter: i32 = 0,
    biClrUsed: u32 = 0,
    biClrImportant: u32 = 0,
};

extern "user32" fn GetDC(hwnd: ?HWND) callconv(.winapi) ?*anyopaque;
extern "user32" fn ReleaseDC(hwnd: ?HWND, hdc: *anyopaque) callconv(.winapi) i32;
extern "gdi32" fn CreateCompatibleDC(hdc: ?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "gdi32" fn DeleteDC(hdc: *anyopaque) callconv(.winapi) BOOL;
extern "gdi32" fn CreateDIBSection(hdc: ?*anyopaque, info: *const BITMAPINFOHEADER, usage: u32, bits: *?*anyopaque, section: ?*anyopaque, offset: u32) callconv(.winapi) ?*anyopaque;
extern "gdi32" fn SelectObject(hdc: *anyopaque, object: ?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "gdi32" fn DeleteObject(object: *anyopaque) callconv(.winapi) BOOL;
extern "gdi32" fn BitBlt(dst: *anyopaque, x: i32, y: i32, cx: i32, cy: i32, src: ?*anyopaque, x1: i32, y1: i32, rop: u32) callconv(.winapi) BOOL;
extern "gdi32" fn StretchBlt(dst: *anyopaque, x: i32, y: i32, cx: i32, cy: i32, src: ?*anyopaque, x1: i32, y1: i32, cx1: i32, cy1: i32, rop: u32) callconv(.winapi) BOOL;
extern "gdi32" fn SetStretchBltMode(hdc: *anyopaque, mode: i32) callconv(.winapi) i32;
extern "gdi32" fn SetBrushOrgEx(hdc: *anyopaque, x: i32, y: i32, old: ?*anyopaque) callconv(.winapi) BOOL;
extern "gdi32" fn GdiFlush() callconv(.winapi) BOOL;

/// A 32-bit DIB the screen is copied into.
const Canvas = struct {
    dc: *anyopaque,
    bitmap: *anyopaque,
    old: ?*anyopaque,
    pixels: [*]u8,
    width: i32,
    height: i32,

    /// `top_down` for GDI+ (rows from the top), else bottom-up, as Media
    /// Foundation takes RGB32.
    fn init(width: i32, height: i32, top_down: bool) !Canvas {
        const dc = CreateCompatibleDC(null) orelse return error.CanvasFailed;
        errdefer _ = DeleteDC(dc);
        const info: BITMAPINFOHEADER = .{ .biWidth = width, .biHeight = if (top_down) -height else height };
        var bits: ?*anyopaque = null;
        const bitmap = CreateDIBSection(dc, &info, 0, &bits, null, 0) orelse return error.CanvasFailed;
        const pixels: [*]u8 = @ptrCast(bits orelse {
            _ = DeleteObject(bitmap);
            return error.CanvasFailed;
        });
        return .{ .dc = dc, .bitmap = bitmap, .old = SelectObject(dc, bitmap), .pixels = pixels, .width = width, .height = height };
    }

    fn deinit(self: *Canvas) void {
        _ = SelectObject(self.dc, self.old);
        _ = DeleteObject(self.bitmap);
        _ = DeleteDC(self.dc);
    }

    fn bytes(self: *const Canvas) []u8 {
        return self.pixels[0 .. @as(usize, @intCast(self.width)) * @as(usize, @intCast(self.height)) * 4];
    }

    /// Copy `rect` of the screen in, scaled to the canvas.
    fn grab(self: *Canvas, rect: Rect) bool {
        if (rect.width() <= 0 or rect.height() <= 0) return false;
        const screen = GetDC(null) orelse return false;
        defer _ = ReleaseDC(null, screen);
        const SRCCOPY: u32 = 0x00CC0020;
        const CAPTUREBLT: u32 = 0x40000000;
        const ok = if (rect.width() == self.width and rect.height() == self.height)
            BitBlt(self.dc, 0, 0, self.width, self.height, screen, rect.left, rect.top, SRCCOPY | CAPTUREBLT)
        else ok: {
            const HALFTONE: i32 = 4;
            _ = SetStretchBltMode(self.dc, HALFTONE);
            _ = SetBrushOrgEx(self.dc, 0, 0, null);
            break :ok StretchBlt(self.dc, 0, 0, self.width, self.height, screen, rect.left, rect.top, rect.width(), rect.height(), SRCCOPY | CAPTUREBLT);
        };
        _ = GdiFlush();
        return ok != 0;
    }
};

// --- Loading a system DLL --------------------------------------------------

extern "kernel32" fn LoadLibraryExW(name: [*:0]const u16, file: ?*anyopaque, flags: u32) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetProcAddress(module: *anyopaque, name: [*:0]const u8) callconv(.winapi) ?*const anyopaque;

fn loadSystem(name: [*:0]const u16) ?*anyopaque {
    const LOAD_LIBRARY_SEARCH_SYSTEM32: u32 = 0x00000800;
    return LoadLibraryExW(name, null, LOAD_LIBRARY_SEARCH_SYSTEM32);
}

/// Each function of `Fns` (a struct of function pointers) found by its
/// field's name in `module`; null when one is missing.
fn bind(comptime Fns: type, module: *anyopaque) ?Fns {
    var fns: Fns = undefined;
    inline for (std.meta.fields(Fns)) |field| {
        const found = GetProcAddress(module, field.name ++ "") orelse return null;
        @field(fns, field.name) = @ptrCast(found);
    }
    return fns;
}

// --- Snapshot: PNG through GDI+ --------------------------------------------

const Gdiplus = struct {
    GdiplusStartup: *const fn (token: *usize, input: *const StartupInput, output: ?*anyopaque) callconv(.winapi) i32,
    GdiplusShutdown: *const fn (token: usize) callconv(.winapi) void,
    GdipCreateBitmapFromScan0: *const fn (width: i32, height: i32, stride: i32, format: i32, scan0: ?[*]u8, bitmap: *?*anyopaque) callconv(.winapi) i32,
    GdipSaveImageToFile: *const fn (image: *anyopaque, file: [*:0]const u16, encoder: *const GUID, params: ?*anyopaque) callconv(.winapi) i32,
    GdipDisposeImage: *const fn (image: *anyopaque) callconv(.winapi) i32,

    const StartupInput = extern struct {
        GdiplusVersion: u32 = 1,
        DebugEventCallback: ?*anyopaque = null,
        SuppressBackgroundThread: BOOL = 0,
        SuppressExternalCodecs: BOOL = 0,
    };

    var loaded: ?Gdiplus = null;

    fn load() ?Gdiplus {
        if (loaded) |fns| return fns;
        const module = loadSystem(L("gdiplus.dll")) orelse return null;
        loaded = bind(Gdiplus, module);
        return loaded;
    }
};

const CLSID_PngEncoder = GUID.parse("{557CF406-1A04-11D3-9A73-0000F81EF32E}");
const PixelFormat32bppRGB: i32 = 0x00022009;

/// `canvas` (top-down) as a PNG at `path`.
fn savePng(canvas: *const Canvas, path: [:0]const u16) !void {
    const gdip = Gdiplus.load() orelse return error.GdiplusMissing;
    var token: usize = 0;
    if (gdip.GdiplusStartup(&token, &.{}, null) != 0) return error.GdiplusFailed;
    defer gdip.GdiplusShutdown(token);
    var bitmap: ?*anyopaque = null;
    if (gdip.GdipCreateBitmapFromScan0(canvas.width, canvas.height, canvas.width * 4, PixelFormat32bppRGB, canvas.pixels, &bitmap) != 0) return error.GdiplusFailed;
    const image = bitmap orelse return error.GdiplusFailed;
    defer _ = gdip.GdipDisposeImage(image);
    if (gdip.GdipSaveImageToFile(image, path.ptr, &CLSID_PngEncoder, null) != 0) return error.WriteFailed;
}

extern "user32" fn SetTimer(hwnd: ?HWND, id: usize, ms: u32, proc: ?*const anyopaque) callconv(.winapi) usize;
extern "user32" fn KillTimer(hwnd: ?HWND, id: usize) callconv(.winapi) BOOL;

/// A snapshot waiting for the menu to leave the screen.
const PendingSnapshot = struct {
    alloc: Allocator,
    owner: *anyopaque,
    target: Target,
    dir: []u8,
    title: []u8,
    timer: usize,

    fn free(self: *PendingSnapshot) void {
        self.alloc.free(self.dir);
        self.alloc.free(self.title);
        self.alloc.destroy(self);
    }
};
var pending_snapshot: ?*PendingSnapshot = null;

/// Take a snapshot of `target` in a quarter of a second, once the menu it
/// was asked from has gone, and save it as a PNG in `dir`. `owner` is what
/// `forget` cancels it by. It says how it went through `target.notify`.
pub fn snapshot(alloc: Allocator, owner: *anyopaque, target: Target, dir: []const u8, title: []const u8) !void {
    if (pending_snapshot != null) return error.Busy;
    const pending = try alloc.create(PendingSnapshot);
    errdefer alloc.destroy(pending);
    const dir_copy = try alloc.dupe(u8, dir);
    errdefer alloc.free(dir_copy);
    const title_copy = try alloc.dupe(u8, title);
    errdefer alloc.free(title_copy);
    const timer = SetTimer(null, 0, 250, @ptrCast(&snapshotTimer));
    if (timer == 0) return error.TimerFailed;
    pending.* = .{ .alloc = alloc, .owner = owner, .target = target, .dir = dir_copy, .title = title_copy, .timer = timer };
    pending_snapshot = pending;
}

fn snapshotTimer(_: ?HWND, _: u32, id: usize, _: u32) callconv(.winapi) void {
    _ = KillTimer(null, id);
    const pending = pending_snapshot orelse return;
    if (pending.timer != id) return;
    pending_snapshot = null;
    defer pending.free();
    const target = pending.target;
    const message = takeSnapshot(pending.alloc, pending) catch |err| switch (err) {
        error.NotVisible => "No snapshot: the tab is hidden, minimized or covered by another window. Bring it to the front and try again.",
        error.GdiplusMissing, error.GdiplusFailed => "No snapshot: Windows' image encoder (GDI+) failed.",
        error.WriteFailed, error.NameTaken => "No snapshot: the file could not be written in the snapshot folder (Settings > Terminal).",
        else => "No snapshot: it could not be taken.",
    };
    target.notify(target.ctx, message);
}

/// Take and write the snapshot. What to say, in a static buffer.
fn takeSnapshot(alloc: Allocator, pending: *PendingSnapshot) ![]const u8 {
    const rect = pending.target.rect(pending.target.ctx) orelse return error.NotVisible;
    var canvas = try Canvas.init(rect.width(), rect.height(), true);
    defer canvas.deinit();
    if (!canvas.grab(rect)) return error.NotVisible;
    const path = try newPath(alloc, pending.dir, pending.title, "png");
    defer alloc.free(path);
    const path_w = try std.unicode.wtf8ToWtf16LeAllocZ(alloc, path);
    defer alloc.free(path_w);
    try savePng(&canvas, path_w);
    log.info("snapshot saved width={d} height={d}", .{ rect.width(), rect.height() });
    const S = struct {
        var buf: [1024]u8 = undefined;
    };
    return std.fmt.bufPrint(&S.buf, "Snapshot saved: {s}", .{path}) catch "Snapshot saved.";
}

// --- Recording: MP4 through Media Foundation -------------------------------

/// A COM object: its first field points to its methods.
const Com = extern struct {
    vtbl: [*]const ?*const anyopaque,

    fn method(self: *Com, comptime F: type, index: usize) F {
        return @ptrCast(self.vtbl[index].?);
    }

    fn release(self: *Com) void {
        _ = self.method(*const fn (*Com) callconv(.winapi) u32, 2)(self);
    }

    // IMFAttributes (IMFMediaType, IMFSample and the writer's attributes).
    fn setUint32(self: *Com, key: *const GUID, value: u32) HRESULT {
        return self.method(*const fn (*Com, *const GUID, u32) callconv(.winapi) HRESULT, 21)(self, key, value);
    }
    fn setUint64(self: *Com, key: *const GUID, value: u64) HRESULT {
        return self.method(*const fn (*Com, *const GUID, u64) callconv(.winapi) HRESULT, 22)(self, key, value);
    }
    fn setGuid(self: *Com, key: *const GUID, value: *const GUID) HRESULT {
        return self.method(*const fn (*Com, *const GUID, *const GUID) callconv(.winapi) HRESULT, 24)(self, key, value);
    }
};

/// Fails with the HRESULT kept in `last_hr` when `hr` is a failure.
threadlocal var last_hr: HRESULT = 0;
fn check(hr: HRESULT) !void {
    if (hr < 0) {
        last_hr = hr;
        return error.MediaFoundationFailed;
    }
}

const MF_MT_MAJOR_TYPE = GUID.parse("{48eba18e-f8c9-4687-bf11-0a74c9f96a8f}");
const MF_MT_SUBTYPE = GUID.parse("{f7e34c9a-42e8-4714-b74b-cb29d72c35e5}");
const MF_MT_AVG_BITRATE = GUID.parse("{20332624-fb0d-4d9e-bd0d-cbf6786c102e}");
const MF_MT_INTERLACE_MODE = GUID.parse("{e2724bb8-e676-4806-b4b2-a8d6efb44ccd}");
const MF_MT_FRAME_SIZE = GUID.parse("{1652c33d-d6b2-4012-b834-72030849a37d}");
const MF_MT_FRAME_RATE = GUID.parse("{c459a2e8-3d2c-4e44-b132-fee5156c7bb0}");
const MF_MT_PIXEL_ASPECT_RATIO = GUID.parse("{c6376a1e-8d0a-4027-be45-6d9a0ad39bb6}");
const MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS = GUID.parse("{a634a91c-822b-41b9-a494-4de4643612b0}");
const MFMediaType_Video = GUID.parse("{73646976-0000-0010-8000-00AA00389B71}");
/// FCC('H264').
const MFVideoFormat_H264 = GUID.parse("{34363248-0000-0010-8000-00AA00389B71}");
/// D3DFMT_X8R8G8B8 (22).
const MFVideoFormat_RGB32 = GUID.parse("{00000016-0000-0010-8000-00AA00389B71}");
const MFVideoInterlace_Progressive: u32 = 2;
/// MF_SDK_VERSION 2, MF_API_VERSION 0x70.
const MF_VERSION: u32 = 0x00020070;

const Mf = struct {
    MFStartup: *const fn (version: u32, flags: u32) callconv(.winapi) HRESULT,
    MFShutdown: *const fn () callconv(.winapi) HRESULT,
    MFCreateAttributes: *const fn (out: *?*Com, size: u32) callconv(.winapi) HRESULT,
    MFCreateMediaType: *const fn (out: *?*Com) callconv(.winapi) HRESULT,
    MFCreateSample: *const fn (out: *?*Com) callconv(.winapi) HRESULT,
    MFCreateMemoryBuffer: *const fn (len: u32, out: *?*Com) callconv(.winapi) HRESULT,

    const ReadWrite = struct {
        MFCreateSinkWriterFromURL: *const fn (url: [*:0]const u16, stream: ?*Com, attributes: ?*Com, out: *?*Com) callconv(.winapi) HRESULT,
    };

    /// Loaded on the recorder's thread; the modules stay loaded.
    fn load() ?struct { Mf, ReadWrite } {
        const plat = loadSystem(L("mfplat.dll")) orelse return null;
        const rw = loadSystem(L("mfreadwrite.dll")) orelse return null;
        return .{ bind(Mf, plat) orelse return null, bind(ReadWrite, rw) orelse return null };
    }
};

/// The sink writer: an H.264 stream in an MP4 at `path`, fed RGB32
/// bottom-up frames of `size`.
const Writer = struct {
    writer: *Com,
    stream: u32,

    fn open(mf: Mf, rw: Mf.ReadWrite, path: [:0]const u16, size: Size, fps: u32, bits: u32, hardware: bool) !Writer {
        var attributes: ?*Com = null;
        defer if (attributes) |a| a.release();
        if (hardware) {
            try check(mf.MFCreateAttributes(&attributes, 1));
            try check(attributes.?.setUint32(&MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, 1));
        }
        var made: ?*Com = null;
        try check(rw.MFCreateSinkWriterFromURL(path.ptr, null, attributes, &made));
        const writer = made orelse return error.MediaFoundationFailed;
        errdefer writer.release();

        const frame_size = (@as(u64, size.width) << 32) | size.height;
        const frame_rate = (@as(u64, fps) << 32) | 1;
        const square = (@as(u64, 1) << 32) | 1;

        var out_type: ?*Com = null;
        try check(mf.MFCreateMediaType(&out_type));
        const out = out_type orelse return error.MediaFoundationFailed;
        defer out.release();
        try check(out.setGuid(&MF_MT_MAJOR_TYPE, &MFMediaType_Video));
        try check(out.setGuid(&MF_MT_SUBTYPE, &MFVideoFormat_H264));
        try check(out.setUint32(&MF_MT_AVG_BITRATE, bits));
        try check(out.setUint32(&MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive));
        try check(out.setUint64(&MF_MT_FRAME_SIZE, frame_size));
        try check(out.setUint64(&MF_MT_FRAME_RATE, frame_rate));
        try check(out.setUint64(&MF_MT_PIXEL_ASPECT_RATIO, square));
        var stream: u32 = 0;
        try check(writer.method(*const fn (*Com, *Com, *u32) callconv(.winapi) HRESULT, 3)(writer, out, &stream));

        var in_type: ?*Com = null;
        try check(mf.MFCreateMediaType(&in_type));
        const in = in_type orelse return error.MediaFoundationFailed;
        defer in.release();
        try check(in.setGuid(&MF_MT_MAJOR_TYPE, &MFMediaType_Video));
        try check(in.setGuid(&MF_MT_SUBTYPE, &MFVideoFormat_RGB32));
        try check(in.setUint32(&MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive));
        try check(in.setUint64(&MF_MT_FRAME_SIZE, frame_size));
        try check(in.setUint64(&MF_MT_FRAME_RATE, frame_rate));
        try check(in.setUint64(&MF_MT_PIXEL_ASPECT_RATIO, square));
        try check(writer.method(*const fn (*Com, u32, *Com, ?*Com) callconv(.winapi) HRESULT, 4)(writer, stream, in, null));

        try check(writer.method(*const fn (*Com) callconv(.winapi) HRESULT, 5)(writer));
        return .{ .writer = writer, .stream = stream };
    }

    /// One frame, `pixels`, shown from `time` for `duration` (100 ns units).
    fn write(self: Writer, mf: Mf, pixels: []const u8, time: i64, duration: i64) !void {
        var made_buffer: ?*Com = null;
        try check(mf.MFCreateMemoryBuffer(@intCast(pixels.len), &made_buffer));
        const buffer = made_buffer orelse return error.MediaFoundationFailed;
        defer buffer.release();
        var data: ?[*]u8 = null;
        try check(buffer.method(*const fn (*Com, *?[*]u8, ?*u32, ?*u32) callconv(.winapi) HRESULT, 3)(buffer, &data, null, null));
        @memcpy((data orelse return error.MediaFoundationFailed)[0..pixels.len], pixels);
        _ = buffer.method(*const fn (*Com) callconv(.winapi) HRESULT, 4)(buffer);
        try check(buffer.method(*const fn (*Com, u32) callconv(.winapi) HRESULT, 6)(buffer, @intCast(pixels.len)));

        var made_sample: ?*Com = null;
        try check(mf.MFCreateSample(&made_sample));
        const sample = made_sample orelse return error.MediaFoundationFailed;
        defer sample.release();
        try check(sample.method(*const fn (*Com, *Com) callconv(.winapi) HRESULT, 42)(sample, buffer));
        try check(sample.method(*const fn (*Com, i64) callconv(.winapi) HRESULT, 36)(sample, time));
        try check(sample.method(*const fn (*Com, i64) callconv(.winapi) HRESULT, 38)(sample, duration));
        try check(self.writer.method(*const fn (*Com, u32, *Com) callconv(.winapi) HRESULT, 6)(self.writer, self.stream, sample));
    }

    /// Finish the file (its index) and let the writer go.
    fn finish(self: Writer) !void {
        defer self.writer.release();
        try check(self.writer.method(*const fn (*Com) callconv(.winapi) HRESULT, 11)(self.writer));
    }
};

extern "ole32" fn CoInitializeEx(reserved: ?*anyopaque, flags: u32) callconv(.winapi) HRESULT;
extern "ole32" fn CoUninitialize() callconv(.winapi) void;

const Recorder = struct {
    alloc: Allocator,
    owner: *anyopaque,
    target: Target,
    path: []u8,
    path_w: [:0]u16,
    size: Size,
    fps: u32,
    bits: u32,
    /// The UI thread's copy of the screen.
    canvas: Canvas,
    /// The latest frame, which the encoder takes.
    latest: []u8,
    mutex: std.Thread.Mutex = .{},
    stopping: std.atomic.Value(bool) = .init(false),
    ready: std.Thread.ResetEvent = .{},
    start_error: ?anyerror = null,
    write_error: ?anyerror = null,
    frames: u64 = 0,
    thread: ?std.Thread = null,
    timer: usize = 0,
    started_ms: i64,

    /// The encoder's thread: Media Foundation started here, a frame written
    /// at each tick of its clock from the latest one the UI thread left,
    /// until `stopping`, then the file finished.
    fn run(self: *Recorder) void {
        const COINIT_MULTITHREADED: u32 = 0;
        const co = CoInitializeEx(null, COINIT_MULTITHREADED);
        defer if (co >= 0) CoUninitialize();
        const libs = Mf.load() orelse {
            self.start_error = error.MediaFoundationMissing;
            self.ready.set();
            return;
        };
        const mf = libs[0];
        if (mf.MFStartup(MF_VERSION, 0) < 0) {
            self.start_error = error.MediaFoundationMissing;
            self.ready.set();
            return;
        }
        defer _ = mf.MFShutdown();
        // A hardware encoder first; some take only some sizes.
        const writer = Writer.open(mf, libs[1], self.path_w, self.size, self.fps, self.bits, true) catch hw: {
            log.info("hardware encoder refused hr=0x{x}, trying software", .{@as(u32, @bitCast(last_hr))});
            std.fs.cwd().deleteFile(self.path) catch {};
            break :hw Writer.open(mf, libs[1], self.path_w, self.size, self.fps, self.bits, false) catch |err| {
                log.warn("encoder failed hr=0x{x}", .{@as(u32, @bitCast(last_hr))});
                self.start_error = err;
                self.ready.set();
                return;
            };
        };
        self.ready.set();

        const frame = self.alloc.alloc(u8, self.latest.len) catch {
            self.write_error = error.OutOfMemory;
            writer.finish() catch {};
            return;
        };
        defer self.alloc.free(frame);
        const interval_ns: u64 = std.time.ns_per_s / self.fps;
        const duration: i64 = @intCast(10_000_000 / self.fps);
        var timer = std.time.Timer.start() catch {
            self.write_error = error.NoClock;
            writer.finish() catch {};
            return;
        };
        var index: u64 = 0;
        while (!self.stopping.load(.acquire)) {
            const now = timer.read();
            const due = index * interval_ns;
            if (now < due) {
                std.Thread.sleep(@min(due - now, 50 * std.time.ns_per_ms));
                continue;
            }
            // Far behind (a slow encoder): skip to now; the frames keep
            // their times, so the video keeps the clock.
            if (now - due > std.time.ns_per_s) index = now / interval_ns;
            {
                self.mutex.lock();
                defer self.mutex.unlock();
                @memcpy(frame, self.latest);
            }
            writer.write(mf, frame, @as(i64, @intCast(index)) * duration, duration) catch |err| {
                log.warn("frame write failed hr=0x{x}", .{@as(u32, @bitCast(last_hr))});
                self.write_error = err;
                break;
            };
            self.frames = index + 1;
            index += 1;
        }
        writer.finish() catch |err| {
            log.warn("finishing the video failed hr=0x{x}", .{@as(u32, @bitCast(last_hr))});
            if (self.write_error == null) self.write_error = err;
        };
    }
};

var active: ?*Recorder = null;

/// Whose tab is recording, if one is.
pub fn recordingOwner() ?*anyopaque {
    const recorder = active orelse return null;
    return recorder.owner;
}

pub fn isRecording(owner: *anyopaque) bool {
    return recordingOwner() == owner;
}

/// The screen read for the recording, on the UI thread at the frame rate.
/// A tab that cannot be seen leaves the last frame as it is.
fn tick(_: ?HWND, _: u32, _: usize, _: u32) callconv(.winapi) void {
    const recorder = active orelse return;
    const rect = recorder.target.rect(recorder.target.ctx) orelse return;
    if (!recorder.canvas.grab(rect)) return;
    recorder.mutex.lock();
    defer recorder.mutex.unlock();
    @memcpy(recorder.latest, recorder.canvas.bytes());
}

pub const StartError = error{
    AlreadyRecording,
    NotVisible,
    MediaFoundationMissing,
    EncoderFailed,
    CanvasFailed,
    WriteFailed,
    OutOfMemory,
};

/// Start recording `target` into a new MP4 in `dir`. `owner` is what
/// `isRecording`, `stop` and `forget` know it by. Fails, with nothing
/// left behind, when another tab records, the tab cannot be seen, or the
/// encoder cannot start.
pub fn start(alloc: Allocator, owner: *anyopaque, target: Target, dir: []const u8, title: []const u8, quality: Quality) StartError!void {
    if (active != null) return error.AlreadyRecording;
    const rect = target.rect(target.ctx) orelse return error.NotVisible;
    if (rect.width() < 2 or rect.height() < 2) return error.NotVisible;
    const p = preset(quality);
    const size = frameSize(@intCast(rect.width()), @intCast(rect.height()), p.max_width);

    const recorder = try alloc.create(Recorder);
    errdefer alloc.destroy(recorder);
    const path = newPath(alloc, dir, title, "mp4") catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.WriteFailed,
    };
    errdefer alloc.free(path);
    const path_w = std.unicode.wtf8ToWtf16LeAllocZ(alloc, path) catch return error.OutOfMemory;
    errdefer alloc.free(path_w);
    var canvas = Canvas.init(@intCast(size.width), @intCast(size.height), false) catch return error.CanvasFailed;
    errdefer canvas.deinit();
    if (!canvas.grab(rect)) return error.NotVisible;
    const latest = try alloc.dupe(u8, canvas.bytes());
    errdefer alloc.free(latest);

    recorder.* = .{
        .alloc = alloc,
        .owner = owner,
        .target = target,
        .path = path,
        .path_w = path_w,
        .size = size,
        .fps = p.fps,
        .bits = bitrate(size, p),
        .canvas = canvas,
        .latest = latest,
        .started_ms = std.time.milliTimestamp(),
    };
    recorder.thread = std.Thread.spawn(.{}, Recorder.run, .{recorder}) catch return error.EncoderFailed;
    recorder.ready.wait();
    if (recorder.start_error) |err| {
        recorder.thread.?.join();
        std.fs.cwd().deleteFile(path) catch {};
        return if (err == error.MediaFoundationMissing) error.MediaFoundationMissing else error.EncoderFailed;
    }
    recorder.timer = SetTimer(null, 0, 1000 / p.fps, @ptrCast(&tick));
    active = recorder;
    log.info("recording started width={d} height={d} fps={d}", .{ size.width, size.height, p.fps });
}

/// A finished recording: its file (WTF-8, in the `alloc` given to `start`;
/// the caller frees it), how long it is, and whether the encoder failed on
/// the way (the file may then be cut short or unplayable).
pub const Stopped = struct {
    path: []u8,
    seconds: u64,
    failed: bool,
};

/// Stop the recording and finish its file. Null when nothing records.
pub fn stop() ?Stopped {
    const recorder = active orelse return null;
    active = null;
    if (recorder.timer != 0) _ = KillTimer(null, recorder.timer);
    recorder.stopping.store(true, .release);
    if (recorder.thread) |thread| thread.join();
    const path = recorder.path;
    const result: Stopped = .{
        .path = path,
        .seconds = recorder.frames / recorder.fps,
        .failed = recorder.write_error != null,
    };
    recorder.alloc.free(recorder.path_w);
    recorder.canvas.deinit();
    recorder.alloc.free(recorder.latest);
    recorder.alloc.destroy(recorder);
    log.info("recording stopped seconds={d} failed={}", .{ result.seconds, result.failed });
    return result;
}

/// `owner` is going away: its pending snapshot is dropped, and its
/// recording stopped and finished (nothing is said: the tab has gone).
pub fn forget(owner: *anyopaque) void {
    if (pending_snapshot) |pending| if (pending.owner == owner) {
        _ = KillTimer(null, pending.timer);
        pending_snapshot = null;
        pending.free();
    };
    if (active) |recorder| if (recorder.owner == owner) {
        const alloc = recorder.alloc;
        if (stop()) |stopped| alloc.free(stopped.path);
    };
}

test "tab capture: a wide tab is scaled down to the preset, both sides even" {
    const size = frameSize(3841, 2161, 1920);
    try std.testing.expectEqual(@as(u32, 1920), size.width);
    try std.testing.expectEqual(@as(u32, 1080), size.height);
    const small = frameSize(801, 601, 1920);
    try std.testing.expectEqual(@as(u32, 800), small.width);
    try std.testing.expectEqual(@as(u32, 600), small.height);
    const tiny = frameSize(1, 1, 1280);
    try std.testing.expectEqual(@as(u32, 2), tiny.width);
    try std.testing.expectEqual(@as(u32, 2), tiny.height);
}

test "tab capture: the bitrate follows the preset and stays in bounds" {
    const normal = preset(.normal);
    try std.testing.expectEqual(@as(u32, 1_658_880), bitrate(.{ .width = 1920, .height = 1080 }, normal));
    try std.testing.expectEqual(@as(u32, 300_000), bitrate(.{ .width = 2, .height = 2 }, preset(.low)));
    try std.testing.expect(preset(.low).fps < normal.fps and normal.fps < preset(.high).fps);
}

test "tab capture: a file name holds the title, made safe, and the time" {
    var buf: [160]u8 = undefined;
    const time: SYSTEMTIME = .{ .year = 2026, .month = 11, .day = 17, .day_of_week = 2, .hour = 9, .minute = 5, .second = 3, .milliseconds = 0 };
    try std.testing.expectEqualStrings("koreterm 5_ CND03 - BOTS DESKTOP 2026-11-17 09.05.03.png", try fileName(&buf, "5: CND03 - BOTS DESKTOP", "png", time));
    try std.testing.expectEqualStrings("koreterm a_b_c 2026-11-17 09.05.03.mp4", try fileName(&buf, "a\\b/c", "mp4", time));
    try std.testing.expectEqualStrings("koreterm tab 2026-11-17 09.05.03.mp4", try fileName(&buf, " .. ", "mp4", time));
    try std.testing.expectEqualStrings("koreterm Ação 2026-11-17 09.05.03.png", try fileName(&buf, "Ação", "png", time));
}

test "tab capture: BITMAPINFOHEADER matches the SDK" {
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(BITMAPINFOHEADER));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(SYSTEMTIME));
    if (builtin.cpu.arch != .x86_64 and builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(Gdiplus.StartupInput));
}
