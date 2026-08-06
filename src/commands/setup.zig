//! `lcc setup` — the name people already type for `lcc config`.
//!
//! It used to be its own walk through five settings in a fixed order, which
//! meant every setting added afterwards was simply absent from it, and there
//! were two places to remember when adding one. There is now a single settings
//! table and a single editor; this is a second door into them.

const app_mod = @import("../app.zig");
const config_cmd = @import("config.zig");

pub fn run(app: app_mod.App) !void {
    return config_cmd.run(app, .{});
}
