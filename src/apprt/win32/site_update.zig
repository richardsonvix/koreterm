//! A newer `update.zip` from the fork's GitHub releases.
//!
//! Once per launch, when no `update.zip` beside the executable is waiting
//! (`local_update.find`), a worker thread asks GitHub for the latest release
//! of `richardsonvix/koreterm`. If that release is newer than this koreterm,
//! newer than any local package, and not ignored (`update.ignored`), the
//! worker downloads its `update.zip` asset beside the executable. The file
//! is checked against the release's `update.zip.sha256` asset and against
//! the `version.txt` inside it before it is put in place. Then the worker
//! posts `msg` to the UI thread, which runs the local package's usual dialog
//! (Update or Ignore), or installs it at exit.
//!
//! The packages are not Authenticode-signed (the inherited updater in
//! `src/update/github_releases.zig` requires the upstream publisher's
//! signature, which this fork's builds lack). Trust rests on HTTPS to
//! GitHub and on the release belonging to this repository; the checksum
//! catches a damaged download. `scripts/publish-update.ps1` makes the
//! release.
const std = @import("std");
const local_update = @import("local_update.zig");
const releases = @import("../../update/github_releases.zig");
const sys = @import("sys.zig");
const types = @import("../win32_types.zig");

const UINT = types.UINT;
const log = std.log.scoped(.win32_site_update);

pub const latest_release_url = "https://api.github.com/repos/richardsonvix/koreterm/releases/latest";
pub const zip_asset = "update.zip";
pub const sha_asset = "update.zip.sha256";
/// Where the download waits until it is checked.
const download_name = "update-download.zip";

/// Start the check on a worker thread; nothing waits for it. `current` is
/// this koreterm's version and must live as long as the process
/// (`build_config.version_string`).
pub fn start(ui_thread: u32, msg: UINT, current: []const u8) void {
    const thread = std.Thread.spawn(.{}, worker, .{ ui_thread, msg, current }) catch |err| {
        log.warn("site update thread failed err={}", .{err});
        return;
    };
    thread.detach();
}

fn worker(ui_thread: u32, msg: UINT, current: []const u8) void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const ready = check(arena.allocator(), current) catch |err| {
        log.info("site update check ended err={}", .{err});
        return;
    };
    if (ready) _ = sys.PostThreadMessageW(ui_thread, msg, 0, 0);
}

/// A newer release's package was put beside the executable.
fn check(a: std.mem.Allocator, current_text: []const u8) !bool {
    const current = local_update.Version.parse(current_text) orelse return error.UnknownVersion;
    const body = try releases.fetchText(a, latest_release_url, "application/vnd.github+json", 4 * 1024 * 1024);
    const release = try parseRelease(a, body);
    const site = local_update.Version.parse(release.version) orelse return error.UnknownVersion;
    if (!site.newerThan(current)) return false;

    const dir = try std.fs.selfExeDirPathAlloc(a);
    // A local package as new or newer is the one offered.
    if (localVersion(a, dir)) |local| if (!site.newerThan(local)) return false;
    const ignored_path = try std.fs.path.join(a, &.{ dir, local_update.ignored_name });
    if (std.fs.cwd().readFileAlloc(a, ignored_path, 256)) |ignored| {
        if (std.mem.eql(u8, std.mem.trim(u8, ignored, " \t\r\n"), release.version)) return false;
    } else |_| {}

    const sha_text = try releases.fetchText(a, release.sha_url, "application/octet-stream", 4096);
    const expected = parseSha256(sha_text) orelse return error.InvalidChecksum;

    const download_path = try std.fs.path.join(a, &.{ dir, download_name });
    defer std.fs.cwd().deleteFile(download_path) catch {};
    try releases.downloadFile(a, release.zip_url, download_path);
    const bytes = try std.fs.cwd().readFileAlloc(a, download_path, 512 * 1024 * 1024);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    if (!std.mem.eql(u8, &digest, &expected)) return error.ChecksumMismatch;
    const inner = local_update.storedEntry(bytes, "version.txt") orelse return error.NotAnUpdate;
    if (!std.mem.eql(u8, std.mem.trim(u8, inner, " \t\r\n\xEF\xBB\xBF"), release.version)) return error.VersionMismatch;

    const zip_path = try std.fs.path.join(a, &.{ dir, local_update.zip_name });
    try std.fs.renameAbsolute(download_path, zip_path);
    log.info("site update downloaded version={s}", .{release.version});
    return true;
}

/// The version inside a waiting local `update.zip`, if there is one.
fn localVersion(a: std.mem.Allocator, dir: []const u8) ?local_update.Version {
    const path = std.fs.path.join(a, &.{ dir, local_update.zip_name }) catch return null;
    const bytes = std.fs.cwd().readFileAlloc(a, path, 512 * 1024 * 1024) catch return null;
    const text = local_update.storedEntry(bytes, "version.txt") orelse return null;
    return local_update.Version.parse(text);
}

pub const Release = struct {
    /// `tag_name` without its leading `v`: `1.3.147`.
    version: []const u8,
    zip_url: []const u8,
    sha_url: []const u8,
};

/// GitHub's latest-release JSON: its tag and the two assets' download URLs.
pub fn parseRelease(a: std.mem.Allocator, body: []const u8) !Release {
    const root = try std.json.parseFromSliceLeaky(std.json.Value, a, body, .{});
    if (root != .object) return error.InvalidRelease;
    const tag = switch (root.object.get("tag_name") orelse return error.InvalidRelease) {
        .string => |text| text,
        else => return error.InvalidRelease,
    };
    const version = if (tag.len > 0 and (tag[0] == 'v' or tag[0] == 'V')) tag[1..] else tag;
    const assets = switch (root.object.get("assets") orelse return error.NoUpdateAsset) {
        .array => |list| list.items,
        else => return error.NoUpdateAsset,
    };
    var zip_url: ?[]const u8 = null;
    var sha_url: ?[]const u8 = null;
    for (assets) |asset| {
        if (asset != .object) continue;
        const name = switch (asset.object.get("name") orelse continue) {
            .string => |text| text,
            else => continue,
        };
        const url = switch (asset.object.get("browser_download_url") orelse continue) {
            .string => |text| text,
            else => continue,
        };
        if (!std.mem.startsWith(u8, url, "https://")) continue;
        if (std.ascii.eqlIgnoreCase(name, zip_asset)) zip_url = url;
        if (std.ascii.eqlIgnoreCase(name, sha_asset)) sha_url = url;
    }
    return .{
        .version = version,
        .zip_url = zip_url orelse return error.NoUpdateAsset,
        .sha_url = sha_url orelse return error.NoUpdateAsset,
    };
}

/// The first 64 hex digits of a `sha256sum`-style line.
pub fn parseSha256(text: []const u8) ?[32]u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n\xEF\xBB\xBF");
    if (trimmed.len < 64) return null;
    var out: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, trimmed[0..64]) catch return null;
    return out;
}

test "site update: a release names its version and both assets" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const body =
        \\{"tag_name":"v1.3.147","assets":[
        \\ {"name":"koreterm-1.3.147-setup.exe","browser_download_url":"https://github.com/x/setup.exe"},
        \\ {"name":"update.zip","browser_download_url":"https://github.com/x/update.zip"},
        \\ {"name":"update.zip.sha256","browser_download_url":"https://github.com/x/update.zip.sha256"}]}
    ;
    const release = try parseRelease(arena.allocator(), body);
    try std.testing.expectEqualStrings("1.3.147", release.version);
    try std.testing.expectEqualStrings("https://github.com/x/update.zip", release.zip_url);
    try std.testing.expectEqualStrings("https://github.com/x/update.zip.sha256", release.sha_url);
    try std.testing.expectError(error.NoUpdateAsset, parseRelease(arena.allocator(), "{\"tag_name\":\"v1\",\"assets\":[]}"));
}

test "site update: a checksum line gives its digest" {
    const line = "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08  update.zip\r\n";
    const digest = parseSha256(line).?;
    try std.testing.expectEqual(@as(u8, 0x9f), digest[0]);
    try std.testing.expectEqual(@as(u8, 0x08), digest[31]);
    try std.testing.expect(parseSha256("abc") == null);
}
