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
    @cInclude("linux/securebits.h");
    @cInclude("sys/prctl.h");
    @cInclude("sys/types.h");
});

const socket_path = "/run/rundird.sock";
const rundir_parent = "/run/user";

pub fn main() !void {
    // This allows us to setuid() and create rundirs with the correct owner
    // while maintaining write permission to the root owned parent directory.
    if (c.prctl(c.PR_SET_SECUREBITS, @as(c_ulong, c.SECBIT_NO_SETUID_FIXUP)) < 0)
        return error.PermissonDenied;

    var server = std.net.StreamServer.init(.{});
    defer server.deinit();

    const addr = try std.net.Address.initUnix(socket_path);

    try server.listen(addr);

    var buf = [1]u8{undefined} ** std.fmt.count("{}/{}", .{ rundir_parent, std.math.maxInt(c.uid_t) });

    var sessions = std.ArrayList(struct {
        uid: c.uid_t,
        open_count: u32,
    }).init(std.heap.c_allocator);

    std.debug.warn("waiting for connections...\n", .{});
    while (true) {
        // TODO: we can probably continue on error in most cases
        const con = try server.accept();
        defer con.file.close();

        const reader = con.file.inStream();
        const message_type = try reader.readByte();
        const uid = try reader.readIntNative(c.uid_t);

        switch (message_type) {
            'O' => {
                for (sessions.items) |*session| {
                    if (uid == session.uid) {
                        session.open_count += 1;
                        std.debug.warn("user {} has {} open sessions\n", .{ uid, session.open_count });
                        break;
                    }
                } else {
                    try sessions.ensureCapacity(sessions.items.len + 1);
                    const path = std.fmt.bufPrint(&buf, "{}/{}", .{ rundir_parent, uid }) catch unreachable;

                    std.debug.warn("user {} has 1 open session\n", .{uid});
                    std.debug.warn("creating {}\n", .{path});

                    try std.os.setuid(uid);
                    try std.os.mkdir(path, 0o700);
                    try std.os.setuid(0);

                    sessions.appendAssumeCapacity(.{ .uid = uid, .open_count = 1 });
                }
            },
            'C' => {
                for (sessions.items) |*session, i| {
                    if (uid == session.uid) {
                        session.open_count -= 1;
                        std.debug.warn("user {} has {} open sessions\n", .{ uid, session.open_count });
                        if (session.open_count == 0) {
                            const path = std.fmt.bufPrint(&buf, "{}/{}", .{ rundir_parent, uid }) catch unreachable;
                            std.debug.warn("deleting {}\n", .{path});
                            try std.fs.deleteTreeAbsolute(path);
                            _ = sessions.swapRemove(i);
                        }
                        break;
                    }
                } else unreachable;
            },
            else => return error.InvalidMessageType,
        }
    }
}
