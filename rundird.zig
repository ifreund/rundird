// This file is part of rundird, a daemon + pam module providing the
// XDG_RUNTIME_DIR of the base directory spec.
//
// Copyright (C) 2020 Isaac Freund
// Copyright (C) 2020 Marten Ringwelski
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
const fs = std.fs;
const os = std.os;
const log = std.log;

const c = @cImport({
    @cInclude("pwd.h");
    @cInclude("grp.h");
    @cInclude("unistd.h");
    @cInclude("sys/types.h");
});

pub const io_mode = .evented;
pub const event_loop_mode = .single_threaded;

var allocator = std.heap.GeneralPurposeAllocator(.{}){};
const gpa = &allocator.allocator;

// Large enough to hold any runtime dir path
var buf: [std.fmt.count("{}/{}", .{
    build_options.rundir_parent,
    std.math.maxInt(os.uid_t),
})]u8 = undefined;

const Session = struct {
    uid: os.uid_t,
    open_count: u32,
    child: os.pid_t,
};

const Context = struct {
    connection: fs.File,
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

    log.info("creating {}\n", .{build_options.rundir_parent});
    std.fs.cwd().makePath(build_options.rundir_parent) catch |err| switch (err) {
        error.PathAlreadyExists => {
            log.warn("rundir already exists, skipping creation", .{});
        },
        else => return err,
    };

    var server = std.net.StreamServer.init(.{});
    defer server.deinit();

    const addr = comptime std.net.Address.initUnix(build_options.socket_path) catch unreachable;
    try server.listen(addr);

    log.info("waiting for connections...", .{});
    while (true) {
        const con = server.accept() catch |err| switch (err) {
            // None of these are fatal, we can just try again
            error.ConnectionAborted,
            error.ProcessFdQuotaExceeded,
            error.SystemFdQuotaExceeded,
            error.SystemResources,
            error.ProtocolFailure,
            error.BlockedByFirewall,
            => {
                log.notice("accept returned with error {}, retrying...", .{err});
                continue;
            },
            // We call listen above and exit on error
            error.SocketNotListening,
            // We require root access with the prctl call above
            error.PermissionDenied,
            error.FileDescriptorNotASocket,
            // The following are windows only... we need better std.os organization
            error.ConnectionResetByPeer,
            error.NetworkSubsystemFailed,
            error.OperationNotSupported,
            error.Unexpected,
            // These could likely all be unreachable except error.Unexpected.
            // However, the std is not stable yet so let's make sure we get
            // an error trace if something goes wrong.
            => return err,
        };

        var context = gpa.create(Context) catch {
            log.crit("out of memory, closing connection early", .{});
            con.file.close();
            continue;
        };
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

    // Check if the session exists, if not add a new one
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
        // log.info("deleting {}", .{path});
        // fs.deleteTreeAbsolute(path) catch |err| {
        //     log.err("error deleting {}: {}\n", .{ path, err });
        // };

        const node = @fieldParentPtr(@TypeOf(sessions).Node, "data", session);

        log.info("killing pid {}", .{node.data.child});
        std.os.kill(node.data.child, std.os.SIGTERM) catch |err| {
            log.err("failed to kill startup process: {}", .{err});
        };

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
    os.mkdir(path, 0o700) catch |err| switch (err) {
        error.PathAlreadyExists => {
            // try fs.deleteTreeAbsolute(path);
            // try os.mkdir(path, 0o700);
        },
        else => return err,
    };

    // It would be preferable to use ChildProcess here, but we're unable due to
    // https://github.com/ziglang/zig/issues/6682
    var fork_pid = std.c.fork();
    if (fork_pid == 0) {
        const pwd = c.getpwuid(uid);
        const homedir = std.mem.span(pwd.*.pw_dir);

        const script = fs.path.join(gpa, &[_][]const u8{ homedir, ".config/rundird" }) catch std.os.exit(1);
        defer gpa.free(script);

        var scriptZ = try gpa.dupeZ(u8, script);
        defer gpa.free(scriptZ);
        log.info("Executing {}", .{scriptZ});

        // While we are seteuid already, there's security benefit to
        // permanently locking ourselves down but also bash won't run
        // unless this is done.
        // TODO: Can't get to NGROUPS_MAX as is macro, hardcoded for now
        var groups = [1]c.gid_t{undefined} ** 65536;
        var ngroups: c_int = 65536;
        _ = c.getgrouplist(pwd.*.pw_name, pwd.*.pw_gid, &groups, &ngroups);
        ngroups = std.math.min(ngroups, 65536);
        log.info("Got {} groups for {}, e.g. {}", .{ ngroups, pwd.*.pw_name, groups[1] });
        _ = c.setgroups(@intCast(usize, ngroups), &groups);
        try os.setuid(pwd.*.pw_uid);
        try os.setgid(pwd.*.pw_gid);

        const runtime_env_base = "XDG_RUNTIME_DIR=" ++ build_options.rundir_parent ++ "/";
        var runtime_env = runtime_env_base.* ++ [1]u8{undefined} ** std.fmt.count("{}\x00", .{std.math.maxInt(os.uid_t)});
        _ = std.fmt.bufPrint(runtime_env[runtime_env_base.len..], "{}\x00", .{uid}) catch unreachable;

        const home_env = std.fmt.allocPrint(gpa, "HOME={}", .{homedir}) catch "HOME=";
        defer gpa.free(home_env);
        const home_envZ = try gpa.dupeZ(u8, home_env);
        defer gpa.free(home_envZ);

        var path_env = for (std.os.environ) |value, i| {
            const cmpable = std.mem.span(value);
            if (std.mem.startsWith(u8, cmpable, "PATH=")) break value;
        } else null;

        const env = &[_:null]?[*:0]const u8{ &runtime_env, home_envZ, path_env, null };

        _ = std.os.execveZ(
            scriptZ,
            &[_:null]?[*:0]const u8{ scriptZ, null },
            env,
        ) catch std.os.exit(1);
    }

    node.data = .{
        .uid = uid,
        .open_count = 0,
        .child = fork_pid,
    };
    sessions.prepend(node);

    return &node.data;
}
