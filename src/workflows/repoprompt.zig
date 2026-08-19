const std = @import("std");
const app_runtime = @import("../core/runtime.zig");
const auth = @import("../auth/auth.zig");
const oauth_refresh = @import("../auth/oauth_refresh.zig");
const cli = @import("../cli/root.zig");
const io_util = @import("../core/io_util.zig");
const registry = @import("../registry/root.zig");

pub fn handle(allocator: std.mem.Allocator, codex_home: []const u8, opts: cli.types.RepoPromptOptions) !void {
    return switch (opts.action) {
        .select => selectAccount(allocator, codex_home),
        .token => writeToken(allocator, codex_home),
    };
}

fn selectAccount(allocator: std.mem.Allocator, codex_home: []const u8) !void {
    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);
    if (try registry.syncActiveAccountFromAuth(allocator, codex_home, &reg)) {
        try registry.saveRegistry(allocator, codex_home, &reg);
    }
    const selected = try cli.picker.selectAccount(allocator, &reg) orelse return;
    const owned = try allocator.dupe(u8, selected);
    if (reg.repoprompt_account_key) |old| allocator.free(old);
    reg.repoprompt_account_key = owned;
    try registry.saveRegistry(allocator, codex_home, &reg);
    try printSelected(&reg, selected);
}

fn writeToken(allocator: std.mem.Allocator, codex_home: []const u8) !void {
    if (std.Io.File.stdout().isTty(app_runtime.io()) catch true) {
        try cli.json_output.printError("repoprompt_token_requires_pipe", "RepoPrompt token output must be consumed through a pipe.", null);
        return error.RepoPromptTokenRequiresPipe;
    }
    var reg = try registry.loadRegistry(allocator, codex_home);
    defer reg.deinit(allocator);
    const account_key = reg.repoprompt_account_key orelse {
        try cli.json_output.printError("repoprompt_account_not_selected", "Run `codex-auth -rp` to select a RepoPrompt account.", null);
        return error.RepoPromptAccountNotSelected;
    };
    const index = registry.findAccountIndexByAccountKey(&reg, account_key) orelse {
        try cli.json_output.printError("repoprompt_account_not_found", "The selected RepoPrompt account is no longer available. Run `codex-auth -rp` again.", null);
        return error.RepoPromptAccountNotFound;
    };
    const rec = &reg.accounts.items[index];
    if (rec.auth_mode != .chatgpt) {
        try cli.json_output.printError("repoprompt_account_unsupported", "RepoPrompt requires a ChatGPT-authenticated Codex account.", null);
        return error.RepoPromptAccountUnsupported;
    }
    _ = oauth_refresh.refreshAccount(allocator, codex_home, account_key, false, false) catch |err| {
        try cli.json_output.printError(refreshErrorCode(err), refreshErrorMessage(err), null);
        return error.RepoPromptAccountRefreshFailed;
    };
    const path = try registry.accountAuthPath(allocator, codex_home, account_key);
    defer allocator.free(path);
    const info = auth.parseAuthInfo(allocator, path) catch {
        try cli.json_output.printError("repoprompt_auth_invalid", "The selected RepoPrompt account has invalid authentication data.", null);
        return error.RepoPromptAuthInvalid;
    };
    defer info.deinit(allocator);
    const record_key = info.record_key orelse return invalidAuth();
    const access_token = info.access_token orelse return invalidAuth();
    const account_id = info.chatgpt_account_id orelse return invalidAuth();
    if (!std.mem.eql(u8, record_key, account_key)) {
        try cli.json_output.printError("repoprompt_account_mismatch", "The selected RepoPrompt account no longer matches its authentication snapshot.", null);
        return error.RepoPromptAccountMismatch;
    }
    try printToken(account_key, access_token, account_id, info.plan);
}

fn invalidAuth() error{RepoPromptAuthInvalid} {
    cli.json_output.printError("repoprompt_auth_invalid", "The selected RepoPrompt account has incomplete authentication data.", null) catch {};
    return error.RepoPromptAuthInvalid;
}

fn printSelected(reg: *const registry.Registry, account_key: []const u8) !void {
    const index = registry.findAccountIndexByAccountKey(reg, account_key) orelse return error.RepoPromptAccountNotFound;
    const rec = &reg.accounts.items[index];
    var stdout: io_util.Stdout = undefined;
    stdout.init();
    try stdout.out().print("RepoPrompt will use {s}.\n", .{if (rec.alias.len != 0) rec.alias else rec.email});
    try stdout.out().flush();
}

fn printToken(account_key: []const u8, access_token: []const u8, account_id: []const u8, plan: ?registry.PlanType) !void {
    var stdout: io_util.Stdout = undefined;
    stdout.init();
    const out = stdout.out();
    var jw: std.json.Stringify = .{ .writer = out, .options = .{} };
    try jw.beginObject();
    try jw.objectField("schema_version");
    try jw.write(1);
    try jw.objectField("account_key");
    try jw.write(account_key);
    try jw.objectField("access_token");
    try jw.write(access_token);
    try jw.objectField("chatgpt_account_id");
    try jw.write(account_id);
    try jw.objectField("chatgpt_plan_type");
    if (plan) |value| try jw.write(@tagName(value)) else try jw.write(null);
    try jw.endObject();
    try out.writeAll("\n");
    try out.flush();
}

fn refreshErrorCode(err: anyerror) []const u8 {
    return switch (err) {
        error.RefreshLoginRequired => "repoprompt_login_required",
        error.RefreshTransient => "repoprompt_refresh_transient",
        else => "repoprompt_refresh_failed",
    };
}

fn refreshErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.RefreshLoginRequired => "The selected RepoPrompt account must be logged in again.",
        error.RefreshTransient => "The selected RepoPrompt account could not be refreshed. Try again.",
        else => "The selected RepoPrompt account could not be refreshed.",
    };
}
