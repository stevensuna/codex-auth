const std = @import("std");
const types = @import("../types.zig");
const common = @import("common.zig");

pub fn parse(allocator: std.mem.Allocator, args: []const [:0]const u8) !types.ParseResult {
    if (args.len == 0) return .{ .command = .{ .repoprompt = .{} } };
    if (args.len == 1 and common.isHelpFlag(std.mem.sliceTo(args[0], 0))) {
        return .{ .command = .{ .help = .repoprompt } };
    }
    const action = std.mem.sliceTo(args[0], 0);
    if (!std.mem.eql(u8, action, "token")) {
        return common.usageErrorResult(allocator, .repoprompt, "unexpected argument `{s}` for `repoprompt`.", .{action});
    }
    if (args.len != 2 or !std.mem.eql(u8, std.mem.sliceTo(args[1], 0), "--json")) {
        return common.usageErrorResult(allocator, .repoprompt, "`repoprompt token` requires `--json`.", .{});
    }
    return .{ .command = .{ .repoprompt = .{ .action = .token, .json = true } } };
}
