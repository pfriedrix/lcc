//! `lcc clean` — reclaim build data left by worktrees that no longer exist.

const std = @import("std");
const app_mod = @import("../app.zig");
const dd = @import("../derived_data.zig");
const prompt = @import("../prompt.zig");
const ui = @import("../ui.zig");

pub fn run(app: app_mod.App, yes: bool) !void {
    const root = try dd.root(app.gpa, app.io, app.environ);
    const entries = try dd.list(app.gpa, app.io, root);
    if (entries.len == 0) {
        app.ui.warn("No Xcode build data found in {f}.", .{ui.dim(root)});
        return;
    }

    const dead = try dd.orphans(app.gpa, app.io, entries);
    if (dead.len == 0) {
        app.ui.success("Nothing to clean — no orphans among {d} folder{s}.", .{
            entries.len, plural(entries.len),
        });
        return;
    }

    app.ui.step("Measuring {d} orphaned folder{s}…", .{ dead.len, plural(dead.len) });
    app.ui.flush();

    const sized = try dd.withSizes(app.gpa, app.io, dead);
    std.mem.sort(dd.Sized, sized, {}, dd.sizeDesc);

    app.ui.info("{f} in {d} folder{s} whose project no longer exists.", .{
        ui.bold(try std.fmt.allocPrint(app.gpa, "{f}", .{ui.bytes(dd.totalSize(sized))})),
        sized.len,
        plural(sized.len),
    });

    const picked: []const dd.Sized = if (yes) sized else blk: {
        var width: usize = 0;
        const labels = try app.gpa.alloc([]const u8, sized.len);
        for (sized, 0..) |item, i| {
            labels[i] = try std.fmt.allocPrint(app.gpa, "{f}", .{ui.bytes(item.size)});
            width = @max(width, labels[i].len);
        }

        const items = try app.gpa.alloc(prompt.Item, sized.len);
        for (sized, 0..) |item, i| {
            items[i] = .{
                .label = try std.fmt.allocPrint(app.gpa, "{s}{s}  {s}  {s}", .{
                    labels[i],
                    try blanks(app.gpa, width - labels[i].len),
                    item.entry.name,
                    item.entry.workspace_path,
                }),
            };
        }

        app.ui.flush();
        const chosen = try prompt.checkbox(
            app.gpa,
            app.io,
            "Select build data to delete (space toggles, enter confirms):",
            items,
            true,
        ) orelse std.process.exit(app_mod.cancelled_exit_code);

        const subset = try app.gpa.alloc(dd.Sized, chosen.len);
        for (chosen, 0..) |index, i| subset[i] = sized[index];
        break :blk subset;
    };

    if (picked.len == 0) {
        app.ui.hint("Nothing selected.", .{});
        return;
    }

    app.ui.step("Deleting {d} folder{s}…", .{ picked.len, plural(picked.len) });
    var reclaimed: u64 = 0;
    for (picked) |item| {
        dd.remove(app.gpa, app.io, item.entry, root) catch |err| {
            app.ui.warn("Could not remove {s}: {s}", .{ item.entry.name, @errorName(err) });
            continue;
        };
        reclaimed += item.size;
        app.ui.success("{s} {f}", .{
            item.entry.name,
            ui.yellow(try std.fmt.allocPrint(app.gpa, "({f})", .{ui.bytes(item.size)})),
        });
    }
    app.ui.success("Reclaimed {f}.", .{
        ui.bold(try std.fmt.allocPrint(app.gpa, "{f}", .{ui.bytes(reclaimed)})),
    });
}

fn plural(n: usize) []const u8 {
    return if (n == 1) "" else "s";
}

fn blanks(gpa: std.mem.Allocator, n: usize) ![]u8 {
    const out = try gpa.alloc(u8, n);
    @memset(out, ' ');
    return out;
}
