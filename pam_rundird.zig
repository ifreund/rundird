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

const os = std.os;

const c = @cImport({
    @cInclude("security/pam_modules.h");
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

fn freeFd(pamh: ?*c.pam_handle_t, data: ?*c_void, error_status: c_int) callconv(.C) void {
    std.heap.c_allocator.destroy(@intToPtr(*os.fd_t, @ptrToInt(data)));
}

fn handleOpen(pamh: *c.pam_handle_t) !void {
    const fd = try std.heap.c_allocator.create(os.fd_t);
    fd.* = -1;
    if (c.pam_set_data(pamh, "pam_rundird_fd", fd, freeFd) != c.PAM_SUCCESS) {
        std.heap.c_allocator.destroy(fd);
        // Technically there's another possible error as well but it can never
        // happen since we are a module not an application.
        return error.OutOfMemory;
    }

    const uid = try getUid(pamh);

    const sock = try std.net.connectUnixSocket(socket_path);

    const writer = sock.outStream();
    try writer.writeIntNative(os.uid_t, uid);

    const reader = sock.inStream();
    switch (try reader.readByte()) {
        // Ack - rundird has created the directory if needed
        'A' => {
            fd.* = sock.handle;
            // Construct a buffer large enough to contain the full string passed to
            // pam_putenv() and pre-populated with the compile time known parts.
            const base = "XDG_RUNTIME_DIR=" ++ rundir_parent ++ "/";
            var buf = base.* ++ [1]u8{undefined} ** std.fmt.count("{}\x00", .{std.math.maxInt(os.uid_t)});
            _ = std.fmt.bufPrint(buf[base.len..], "{}\x00", .{uid}) catch unreachable;

            if (c.pam_putenv(pamh, &buf) != c.PAM_SUCCESS) return error.PutenvFail;
        },
        else => {
            sock.close();
            return error.InvalidResponse;
        },
    }
}

fn handleClose(pamh: *c.pam_handle_t) !void {
    // No data or a value of -1 means that open_session failed, so there is
    // nothing to do. An error was already reported in open_session so don't
    // report another.
    var fd: ?*const os.fd_t = undefined;
    if (c.pam_get_data(pamh, "pam_rundird_fd", @ptrCast(*?*const c_void, &fd)) != c.PAM_SUCCESS) return;
    if (fd == null or fd.?.* == -1) return;

    const sock = std.fs.File{ .handle = fd.?.* };
    defer sock.close();

    const uid = try getUid(pamh);

    // TODO: just close the fd instead
    const writer = sock.outStream();
    try writer.writeByte('C'); // C is for close
}

/// Get the uid of the user for which the session is being opened
fn getUid(pamh: *c.pam_handle_t) !os.uid_t {
    var user: ?[*:0]const u8 = undefined;
    if (c.pam_get_user(pamh, &user, null) != c.PAM_SUCCESS) return error.UnknownUser;
    const user_info = try std.process.getUserInfo(std.mem.span(user.?));
    return user_info.uid;
}
