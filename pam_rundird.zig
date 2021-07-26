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

const build_options = @import("build_options");
const std = @import("std");
const fmt = std.fmt;
const os = std.os;

const c = @cImport({
    @cInclude("security/pam_modules.h");
});

export fn pam_sm_open_session(pamh: *c.pam_handle_t, flags: c_int, argc: c_int, argv: [*][*:0]u8) c_int {
    handleOpen(pamh) catch return c.PAM_SESSION_ERR;
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

    // Get the uid of the user for which the session is being opened
    var user: ?[*:0]const u8 = undefined;
    if (c.pam_get_user(pamh, &user, null) != c.PAM_SUCCESS) return error.UnknownUser;
    const user_info = try std.process.getUserInfo(std.mem.span(user.?));

    const sock = try std.net.connectUnixSocket(build_options.socket_path);

    try sock.writer().writeIntNative(os.uid_t, user_info.uid);

    switch (try sock.reader().readByte()) {
        // Ack - rundird has created the directory if needed
        'A' => {
            // pam_putenv() could still fail, but that's orthogonal to the
            // communication with rundird.
            fd.* = sock.handle;

            // Add 1 for the 0 terminator
            const buf_len = comptime 1 + fmt.count("XDG_RUNTIME_DIR={s}/{d}", .{
                build_options.rundir_parent,
                std.math.maxInt(os.uid_t),
            });
            var buf: [buf_len]u8 = undefined;
            const path = fmt.bufPrintZ(&buf, "XDG_RUNTIME_DIR={s}/{d}", .{
                build_options.rundir_parent,
                user_info.uid,
            }) catch unreachable;

            if (c.pam_putenv(pamh, path.ptr) != c.PAM_SUCCESS) return error.PutenvFail;
        },
        else => {
            sock.close();
            return error.InvalidResponse;
        },
    }
}

export fn pam_sm_close_session(pamh: *c.pam_handle_t, flags: c_int, argc: c_int, argv: [*][*:0]u8) c_int {
    // No data or a value of -1 means that open_session failed, so there is
    // nothing to do. An error was already reported in open_session so don't
    // report another.
    var fd: ?*const os.fd_t = undefined;
    if (c.pam_get_data(pamh, "pam_rundird_fd", @ptrCast(*?*const c_void, &fd)) != c.PAM_SUCCESS) {
        return c.PAM_SUCCESS;
    }
    if (fd == null or fd.?.* == -1) {
        return c.PAM_SUCCESS;
    }
    // Closing the connection indicates to rundird that the session has closed.
    os.close(fd.?.*);
    return c.PAM_SUCCESS;
}
