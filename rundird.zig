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
const os = std.os;
const log = std.log;

pub const io_mode = .evented;
pub const event_loop_mode = .single_threaded;

var allocator = std.heap.GeneralPurposeAllocator(.{}){};
const gpa = &allocator.allocator;

// Large enough to hold any runtime dir path
var buf = [1]u8{undefined} ** std.fmt.count("{}/{}", .{ build_options.rundir_parent, std.math.maxInt(os.uid_t) });

const Session = struct {
    uid: os.uid_t,
    open_count: u32,
};

const Context = struct {
    connection: std.fs.File,
    frame: @Frame(handleConnection),
    // Seems like this needs to be intrusive to avoid a circular dependency
    // of types.
    node: std.SinglyLinkedList(void).Node,
};

var sessions = std.SinglyLinkedList(Session){};
var free_list = std.SinglyLinkedList(void){};

pub fn main() !void {
    // This allows us to seteuid() and create rundirs with the correct owner
    // while maintaining write permission to the root owned parent directory.
    _ = try os.prctl(os.PR.SET_SECUREBITS, .{os.SECBIT_NO_SETUID_FIXUP});

    var server = std.net.StreamServer.init(.{});
    defer server.deinit();

    try server.listen(try std.net.Address.initUnix(build_options.socket_path));

    log.info("waiting for connections...", .{});
    while (true) {
        // TODO: we can probably continue on error in most cases
        const con = try server.accept();

        var context = try gpa.create(Context);
        context.* = .{
            .connection = con.file,
            .frame = undefined,
            .node = undefined,
        };

        context.frame = async handleConnection(context);

        while (free_list.popFirst()) |node|
            gpa.destroy(@fieldParentPtr(Context, "node", node));
    }
}

fn handleConnection(context: *Context) void {
    defer {
        free_list.prepend(&context.node);
        context.connection.close();
    }

    const reader = context.connection.reader();
    const uid = reader.readIntNative(os.uid_t) catch |err| {
        log.err("error reading uid from pam_rundird connection: {}", .{err});
        return;
    };

    var it = sessions.first;
    const session = while (it) |node| : (it = node.next) {
        if (node.data.uid == uid) break &node.data;
    } else
        addSession(uid) catch |err| {
            log.err("error creating directory: {}", .{err});
            return;
        };

    const writer = context.connection.writer();
    writer.writeByte('A') catch |err| {
        log.err("error sending ack to pam_rundird: {}", .{err});
        return;
    };
    session.open_count += 1;
    log.info("user {} has {} open sessions", .{ uid, session.open_count });

    const bytes_read = reader.read(&buf) catch |err| {
        // Don't want to delete the rundir while it is still in use, so handle
        // this error by "leaking" a session.
        log.err("error waiting for pam_rundird connection to be closed: {}", .{err});
        return;
    };
    std.debug.assert(bytes_read == 0);
    session.open_count -= 1;
    log.info("user {} has {} open sessions", .{ uid, session.open_count });

    if (session.open_count == 0) {
        const path = std.fmt.bufPrint(&buf, "{}/{}", .{ build_options.rundir_parent, uid }) catch unreachable;
        log.info("deleting {}", .{path});
        std.fs.deleteTreeAbsolute(path) catch |err| {
            log.err("error deleting {}: {}\n", .{ path, err });
        };

        const node = @fieldParentPtr(@TypeOf(sessions).Node, "data", session);
        sessions.remove(node);
        gpa.destroy(node);
    }
}

fn addSession(uid: os.uid_t) !*Session {
    const node = try gpa.create(std.SinglyLinkedList(Session).Node);
    errdefer gpa.destroy(node);

    const path = std.fmt.bufPrint(&buf, "{}/{}", .{ build_options.rundir_parent, uid }) catch unreachable;

    try os.seteuid(uid);
    defer os.seteuid(0) catch |err| {
        log.err("failed to set euid to 0, this should never happen: {}\n", .{err});
    };

    log.info("creating {}\n", .{path});
    try os.mkdir(path, 0o700);

    node.data = .{
        .uid = uid,
        .open_count = 0,
    };
    sessions.prepend(node);

    return &node.data;
}
