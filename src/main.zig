const std = @import("std");
const Io = std.Io;

const unityz = @import("unityz");

const usage =
    \\unityz — read, extract, and edit Unity assets
    \\
    \\Usage:
    \\  unityz <command> <path>
    \\  unityz --help | --version
    \\
    \\Commands:
    \\  info <path>     Print what unityz can read from a Unity asset file
    \\  extract <path>  Extract embedded assets from a Unity asset file
    \\  edit <path>     Apply edits to a Unity asset file
    \\
    \\Unity asset parsing is not implemented yet — these commands land as the
    \\format support milestones ship.
;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    // The args slice includes argv[0]; drop it.
    const args = (try init.minimal.args.toSlice(arena))[1..];

    var out_buffer: [1024]u8 = undefined;
    var out_writer: Io.File.Writer = .init(.stdout(), io, &out_buffer);
    const stdout = &out_writer.interface;

    var err_buffer: [1024]u8 = undefined;
    var err_writer: Io.File.Writer = .init(.stderr(), io, &err_buffer);
    const stderr = &err_writer.interface;

    if (args.len == 0) {
        try stderr.print("{s}\n", .{usage});
        try stderr.flush();
        std.process.exit(2);
    }

    const arg0 = args[0];
    if (std.mem.eql(u8, arg0, "--help") or std.mem.eql(u8, arg0, "-h")) {
        try stdout.print("{s}\n", .{usage});
        try stdout.flush();
        return;
    }

    if (std.mem.eql(u8, arg0, "--version") or std.mem.eql(u8, arg0, "-V")) {
        const v = unityz.version;
        try stdout.print("unityz {d}.{d}.{d}\n", .{ v.major, v.minor, v.patch });
        try stdout.flush();
        return;
    }

    const command = parseCommand(arg0) orelse {
        try stderr.print("unityz: unknown command '{s}'\n\n{s}\n", .{ arg0, usage });
        try stderr.flush();
        std.process.exit(2);
    };
    _ = command;

    if (args.len < 2) {
        try stderr.print("unityz: '{s}' needs a path argument\n\n{s}\n", .{ arg0, usage });
        try stderr.flush();
        std.process.exit(2);
    }

    // Format support is a later milestone; fail loudly and honestly until then.
    try stderr.print(
        "unityz: {s}: not implemented yet — Unity asset parsing is a later milestone\n",
        .{arg0},
    );
    try stderr.flush();
    std.process.exit(1);
}

const Command = enum { info, extract, edit };

fn parseCommand(arg: []const u8) ?Command {
    inline for (std.meta.fields(Command)) |field| {
        if (std.mem.eql(u8, arg, field.name)) return @enumFromInt(field.value);
    }
    return null;
}

test "parseCommand recognizes known subcommands" {
    try std.testing.expectEqual(Command.info, parseCommand("info"));
    try std.testing.expectEqual(Command.extract, parseCommand("extract"));
    try std.testing.expectEqual(Command.edit, parseCommand("edit"));
    try std.testing.expect(parseCommand("bogus") == null);
    try std.testing.expect(parseCommand("--version") == null);
}
