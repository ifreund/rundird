// This file is part of rundird, a daemon + pam module providing the
// XDG_RUNTIME_DIR of the base directory spec.
//
// Copyright (C) 2020 Isaac Freund
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

const std = @import("std");

const c = @cImport({
    @cInclude("pwd.h");
    @cInclude("security/pam_modules.h");
    @cInclude("unistd.h");
});

const socket_path = "/run/rundird.sock";
const rundir_parent = "/run/user";

export fn pam_sm_open_session(pamh: *c.pam_handle_t, flags: c_int, argc: c_int, argv: [*][*:0]u8) c_int {
    handleOpen(pamh) catch return c.PAM_SESSION_ERR;
    return c.PAM_SUCCESS;
}

export fn pam_sm_close_session(pamh: *c.pam_handle_t, flags: c_int, argc: c_int, argv: [*][*:0]u8) c_int {
    handleClose(pamh) catch return c.PAM_SESSION_ERR;
    return c.PAM_SUCCESS;
}

fn handleOpen(pamh: *c.pam_handle_t) !void {
    const uid = try getUid(pamh);

    // Backdoor for testing, TODO: remove this
    if (uid == 0) return;

    // Construct a buffer large enough to contain the full string passed to
    // pam_putenv() and pre-populated with the compile time known parts.
    const base = "XDG_RUNTIME_DIR=" ++ rundir_parent ++ "/";
    var buf = base.* ++ [1]u8{undefined} ** std.fmt.count("{}\x00", .{std.math.maxInt(c.uid_t)});
    _ = std.fmt.bufPrint(buf[base.len..], "{}\x00", .{uid}) catch unreachable;

    if (c.pam_putenv(pamh, &buf) != c.PAM_SUCCESS) return error.PutenvFail;

    const sock = try std.net.connectUnixSocket(socket_path);
    defer sock.close();

    const writer = sock.outStream();
    try writer.writeByte('O');
    try writer.writeIntNative(c.uid_t, uid);
}

fn handleClose(pamh: *c.pam_handle_t) !void {
    const uid = try getUid(pamh);

    // Backdoor for testing, TODO: remove this
    if (uid == 0) return;

    const sock = try std.net.connectUnixSocket(socket_path);
    defer sock.close();

    const writer = sock.outStream();
    try writer.writeByte('C');
    try writer.writeIntNative(c.uid_t, uid);
}

/// Get the uid of the user for which the session is being opened
fn getUid(pamh: *c.pam_handle_t) !c.uid_t {
    var user: ?[*:0]const u8 = undefined;
    if (c.pam_get_user(pamh, &user, null) != c.PAM_SUCCESS) return error.UnknownUser;
    const pw: *c.passwd = c.getpwnam(user) orelse return error.UnknownUser;
    return pw.pw_uid;
}
