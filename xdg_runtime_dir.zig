const std = @import("std");

const c = @cImport({
    @cInclude("security/pam_modules.h");
});

export fn pam_sm_open_session(
    pamh: *c.pam_handle_t,
    flags: c_int,
    argc: c_int,
    argv: [*][*:0]u8,
) callconv(.C) c_int {
    doTheThings() catch return c.PAM_SESSION_ERR;
    return c.PAM_SUCCESS;
}

fn doTheThings() !void {
    const file = try std.fs.createFileAbsoluteZ("/tmp/hello.txt", .{});
    try file.writeAll("hello pam!\n");
}
