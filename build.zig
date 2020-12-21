const std = @import("std");

pub fn build(b: *std.build.Builder) !void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const socket_path = b.option(
        []const u8,
        "socket-path",
        "The socket path for rundird. Default is /run/rundird.sock",
    ) orelse "/run/rundird.sock";

    const rundir_parent = b.option(
        []const u8,
        "rundir-parent",
        "Absolute path to the parent directory for user dirs. Default is /run/user",
    ) orelse "/run/user";

    if (!std.fs.path.isAbsolute(rundir_parent)) return error.InvalidRundirParent;

    const rundird = b.addExecutable("rundird", "rundird.zig");
    rundird.setTarget(target);
    rundird.setBuildMode(mode);

    rundird.addBuildOption([]const u8, "socket_path", socket_path);
    rundird.addBuildOption([]const u8, "rundir_parent", rundir_parent);

    rundird.install();

    const pam_rundird = b.addSharedLibrary("pam_rundird", "pam_rundird.zig", .unversioned);
    pam_rundird.setTarget(target);
    pam_rundird.setBuildMode(mode);

    pam_rundird.addBuildOption([]const u8, "socket_path", socket_path);
    pam_rundird.addBuildOption([]const u8, "rundir_parent", rundir_parent);

    pam_rundird.linkLibC();
    pam_rundird.linkSystemLibrary("pam");

    pam_rundird.override_dest_dir = .{ .Custom = "lib/security" };
    pam_rundird.install();
}
