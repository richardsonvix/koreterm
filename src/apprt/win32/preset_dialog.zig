//! The modal window for a profile koreterm finds on this computer (a
//! preset: PowerShell, Command Prompt, WSL, an SSH host): Settings does not
//! change what it runs, so the window holds only what is the person's own,
//! whether it is a favorite (`profile-favorite`) and its notes
//! (`profile-notes`). Settings writes what it returns into the draft.
//!
//! Nothing here logs a value the person typed.
const std = @import("std");
const Allocator = std.mem.Allocator;

const win32_types = @import("../win32_types.zig");
const profile_dialog = @import("profile_dialog.zig");

const BOOL = win32_types.BOOL;
const HINSTANCE = win32_types.HINSTANCE;
const HWND = win32_types.HWND;
const LPARAM = win32_types.LPARAM;
const LPCWSTR = win32_types.LPCWSTR;
const LRESULT = win32_types.LRESULT;
const UINT = win32_types.UINT;
const WPARAM = win32_types.WPARAM;

const L = std.unicode.utf8ToUtf16LeStringLiteral;

/// What the window edits. In: as it is. Out, when the person pressed OK:
/// what they chose. Text lives in the `alloc` given to `edit`.
pub const Preset = struct {
    /// Shown, not edited: the profile's name.
    label: []const u8 = "",
    favorite: bool = false,
    /// Free text, any number of lines; empty for none.
    notes: []const u8 = "",
};

extern "user32" fn DialogBoxIndirectParamW(hInstance: ?HINSTANCE, template: *const anyopaque, parent: ?HWND, proc: *const fn (HWND, UINT, WPARAM, LPARAM) callconv(.winapi) isize, init: LPARAM) callconv(.winapi) isize;
extern "user32" fn EndDialog(hDlg: HWND, result: isize) callconv(.winapi) BOOL;
extern "user32" fn GetDlgItem(hDlg: HWND, id: i32) callconv(.winapi) ?HWND;
extern "user32" fn SendMessageW(hWnd: HWND, msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT;
extern "user32" fn SetWindowLongPtrW(hWnd: HWND, index: i32, value: isize) callconv(.winapi) isize;
extern "user32" fn GetWindowLongPtrW(hWnd: HWND, index: i32) callconv(.winapi) isize;
extern "kernel32" fn GetModuleHandleW(name: ?LPCWSTR) callconv(.winapi) ?HINSTANCE;

const IDOK: u16 = 1;
const IDCANCEL: u16 = 2;
const id_label: u16 = 110;
const id_favorite: u16 = 111;
const id_notes: u16 = 112;

const DWLP_USER: i32 = @sizeOf(usize) * 2;
const WM_INITDIALOG: UINT = 0x0110;
const WM_COMMAND: UINT = 0x0111;
const WM_CLOSE: UINT = 0x0010;
const BM_GETCHECK: UINT = 0x00F0;
const BM_SETCHECK: UINT = 0x00F1;

const State = struct {
    alloc: Allocator,
    preset: *Preset,
};

/// Edit `preset` in a modal window over `owner`. Returns whether OK was
/// pressed; `preset` then holds what was chosen, in `alloc`.
pub fn edit(alloc: Allocator, owner: ?HWND, preset: *Preset) Allocator.Error!bool {
    const template = try buildTemplate(alloc);
    defer alloc.free(template);
    var state: State = .{ .alloc = alloc, .preset = preset };
    return DialogBoxIndirectParamW(GetModuleHandleW(null), template.ptr, owner, dialogProc, @bitCast(@intFromPtr(&state))) == IDOK;
}

const Template = struct {
    bytes: std.ArrayListUnmanaged(u8) = .empty,
    alloc: Allocator,

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
    }
};

const item_count: u16 = 6;

fn buildTemplate(alloc: Allocator) Allocator.Error![]align(4) u8 {
    var t: Template = .{ .alloc = alloc };
    defer t.bytes.deinit(alloc);
    const WS_CHILD: u32 = 0x40000000;
    const WS_VISIBLE: u32 = 0x10000000;
    const WS_TABSTOP: u32 = 0x00010000;
    const WS_GROUP: u32 = 0x00020000;
    const WS_BORDER: u32 = 0x00800000;
    const WS_VSCROLL: u32 = 0x00200000;
    const child = WS_CHILD | WS_VISIBLE;
    const ES_MULTILINE: u32 = 0x4;
    const ES_AUTOVSCROLL: u32 = 0x40;
    const ES_WANTRETURN: u32 = 0x1000;
    const SS_NOPREFIX: u32 = 0x80;
    const BS_AUTOCHECKBOX: u32 = 0x3;
    const BS_DEFPUSHBUTTON: u32 = 0x1;
    const button: u16 = 0x0080;
    const edit_atom: u16 = 0x0081;
    const static: u16 = 0x0082;

    const w: i16 = 280;
    const h: i16 = 150;
    const label_w: i16 = 40;
    const field_x: i16 = 7 + label_w + 4;
    const field_w: i16 = w - field_x - 7;
    try t.int(u32, 0x80000000 | 0x00C00000 | 0x00080000 | 0x80 | 0x40 | 0x800); // popup, caption, sysmenu, modal frame, setfont, center
    try t.int(u32, 0);
    try t.int(u16, item_count);
    try t.int(i16, 0);
    try t.int(i16, 0);
    try t.int(i16, w);
    try t.int(i16, h);
    try t.int(u16, 0);
    try t.int(u16, 0);
    try t.wstr(L("Profile koreterm found"));
    try t.int(u16, 9);
    try t.wstr(L("Segoe UI"));

    // The name, then what can be changed here.
    try t.item(child | SS_NOPREFIX, 7, 9, w - 14, 18, id_label, static, L(""));
    try t.item(child | WS_TABSTOP | WS_GROUP | BS_AUTOCHECKBOX, field_x, 30, field_w, 12, id_favorite, button, L("★ Favo&rite: listed in the new-tab menu"));
    try t.item(child, 7, 50, label_w, 9, 0xFFFF, static, L("N&otes"));
    try t.item(child | WS_TABSTOP | WS_GROUP | WS_BORDER | WS_VSCROLL | ES_MULTILINE | ES_AUTOVSCROLL | ES_WANTRETURN, field_x, 48, field_w, 72, id_notes, edit_atom, L(""));
    try t.item(child | WS_TABSTOP | WS_GROUP | BS_DEFPUSHBUTTON, w - 7 - 50 - 4 - 50, h - 21, 50, 14, IDOK, button, L("OK"));
    try t.item(child | WS_TABSTOP, w - 7 - 50, h - 21, 50, 14, IDCANCEL, button, L("Cancel"));

    const out = try alloc.alignedAlloc(u8, .@"4", t.bytes.items.len);
    @memcpy(out, t.bytes.items);
    return out;
}

fn stateOf(hwnd: HWND) ?*State {
    const raw = GetWindowLongPtrW(hwnd, DWLP_USER);
    if (raw == 0) return null;
    return @ptrFromInt(@as(usize, @bitCast(raw)));
}

fn dialogProc(hwnd: HWND, msg: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) isize {
    switch (msg) {
        WM_INITDIALOG => {
            _ = SetWindowLongPtrW(hwnd, DWLP_USER, lparam);
            const state = stateOf(hwnd) orelse return 1;
            const p = state.preset;
            const a = state.alloc;
            const said = std.fmt.allocPrint(a, "{s}: koreterm found it on this computer, so what it runs is not changed here.", .{p.label}) catch "";
            profile_dialog.setText(hwnd, id_label, a, said);
            profile_dialog.setText(hwnd, id_notes, a, p.notes);
            if (GetDlgItem(hwnd, id_favorite)) |box| _ = SendMessageW(box, BM_SETCHECK, @intFromBool(p.favorite), 0);
            return 1;
        },
        WM_COMMAND => {
            const id: u16 = @truncate(wparam);
            switch (id) {
                IDOK => {
                    const state = stateOf(hwnd) orelse return 1;
                    const notes = profile_dialog.readText(hwnd, id_notes, state.alloc) orelse return 1;
                    state.preset.notes = notes;
                    state.preset.favorite = if (GetDlgItem(hwnd, id_favorite)) |box| SendMessageW(box, BM_GETCHECK, 0, 0) == 1 else false;
                    _ = EndDialog(hwnd, IDOK);
                    return 1;
                },
                IDCANCEL => {
                    _ = EndDialog(hwnd, IDCANCEL);
                    return 1;
                },
                else => return 0,
            }
        },
        WM_CLOSE => {
            _ = EndDialog(hwnd, IDCANCEL);
            return 1;
        },
        else => return 0,
    }
}

test "preset dialog: the template is DWORD aligned and counts its items" {
    const template = try buildTemplate(std.testing.allocator);
    defer std.testing.allocator.free(template);
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(template.ptr) % 4);
    try std.testing.expectEqual(item_count, std.mem.readInt(u16, template[8..10], .little));
}
