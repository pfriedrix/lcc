const app_mod = @import("../app.zig");
const config_cmd = @import("config.zig");

pub fn run(app: app_mod.App) !void {
    return config_cmd.run(app, .{});
}
