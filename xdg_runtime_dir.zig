// This file is part of xdg-runtime-dir, a pam module providing the
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

export fn pam_sm_open_session(pamh: *c.pam_handle_t, flags: c_int, argc: c_int, argv: [*][*:0]u8) c_int {
    handleOpen(pamh) catch return c.PAM_SESSION_ERR;
    return c.PAM_SUCCESS;
}

fn handleOpen(pamh: *c.pam_handle_t) !void {
    // Get the uid/gid of the user for which the session is being opened
    var user: ?[*:0]const u8 = undefined;
    if (c.pam_get_user(pamh, &user, null) != c.PAM_SUCCESS) return error.UnknownUser;
    const pw: *c.passwd = c.getpwnam(user) orelse return error.UnknownUser;

    // Construct a buffer large enough to contain the full string passed to
    // pam_putenv() and pre-populated with the compile time known parts.
    const env = "XDG_RUNTIME_DIR=";
    const path = "/run/user/";
    var buf = env.* ++ path.* ++
        [1]u8{undefined} ** std.fmt.count("{}", .{std.math.maxInt(@TypeOf(pw.pw_uid)) + 1});
    _ = std.fmt.bufPrint(buf[env.len + path.len ..], "{}\x00", .{pw.pw_uid}) catch unreachable;

    // Create the /run/user/$UID dir and give ownership to the user if it does
    // not already exist.
    if (std.os.mkdirZ(@ptrCast([*:0]u8, &buf[env.len]), 0o700)) {
        if (c.chown(&buf[env.len], pw.pw_uid, pw.pw_gid) < 0) return error.ChownFail;
    } else |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    }

    if (c.pam_putenv(pamh, &buf) != c.PAM_SUCCESS) return error.PutenvFail;
}
