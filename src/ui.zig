//! Terminal output — the `picocolors` replacement plus lcc's log prefixes.

const std = @import("std");
const Io = std.Io;

var color_enabled: bool = true;

/// Honours `NO_COLOR` and a non-tty stdout, like picocolors does.
pub fn detectColor(io: Io, environ: *const std.process.Environ.Map) void {
    if (environ.get("NO_COLOR")) |v| {
        if (v.len > 0) {
            color_enabled = false;
            return;
        }
    }
    color_enabled = Io.File.stdout().isTty(io) catch false;
}

pub fn setColor(on: bool) void {
    color_enabled = on;
}

pub fn colorEnabled() bool {
    return color_enabled;
}

/// Escape sequences for code that builds its own frames (the prompts), so they
/// honour `NO_COLOR` and non-tty output like everything else.
pub const Palette = struct {
    reset: []const u8,
    bold: []const u8,
    dim: []const u8,
    green: []const u8,
    cyan: []const u8,
};

pub fn palette() Palette {
    if (!color_enabled) return .{ .reset = "", .bold = "", .dim = "", .green = "", .cyan = "" };
    return .{
        .reset = Code.reset,
        .bold = Code.bold,
        .dim = Code.dim,
        .green = Code.green,
        .cyan = Code.cyan,
    };
}

const Code = struct {
    const reset = "\x1b[0m";
    const bold = "\x1b[1m";
    const dim = "\x1b[2m";
    const red = "\x1b[31m";
    const green = "\x1b[32m";
    const yellow = "\x1b[33m";
    const cyan = "\x1b[36m";
};

/// A string plus the escape it should be wrapped in. Rendered with `{f}`, so
/// nothing is allocated and disabling colour is a single branch at write time.
pub const Painted = struct {
    code: []const u8,
    text: []const u8,

    pub fn format(self: Painted, w: *Io.Writer) Io.Writer.Error!void {
        // Empty text writes nothing at all, so callers can pass conditional
        // fragments without emitting stray escape sequences.
        if (self.text.len == 0) return;
        if (!color_enabled) return w.writeAll(self.text);
        try w.writeAll(self.code);
        try w.writeAll(self.text);
        try w.writeAll(Code.reset);
    }
};

pub fn bold(text: []const u8) Painted {
    return .{ .code = Code.bold, .text = text };
}
pub fn dim(text: []const u8) Painted {
    return .{ .code = Code.dim, .text = text };
}
pub fn red(text: []const u8) Painted {
    return .{ .code = Code.red, .text = text };
}
pub fn green(text: []const u8) Painted {
    return .{ .code = Code.green, .text = text };
}
pub fn yellow(text: []const u8) Painted {
    return .{ .code = Code.yellow, .text = text };
}
pub fn cyan(text: []const u8) Painted {
    return .{ .code = Code.cyan, .text = text };
}

/// Buffered stdout/stderr with lcc's log vocabulary. Writes are best-effort:
/// a CLI that fails because its own logging failed is worse than a lost line.
pub const Ui = struct {
    io: Io,
    out: *Io.Writer,
    err: *Io.Writer,
    /// Send the log vocabulary to stderr instead of stdout, leaving stdout for
    /// `payload` alone. What `--json` turns on: a caller parsing stdout must not
    /// have to filter progress lines out of it, and a human running the same
    /// command still sees them.
    divert: bool = false,

    fn log(self: Ui) *Io.Writer {
        return if (self.divert) self.err else self.out;
    }

    pub fn info(self: Ui, comptime fmt: []const u8, args: anytype) void {
        self.log().print(fmt ++ "\n", args) catch {};
    }

    pub fn success(self: Ui, comptime fmt: []const u8, args: anytype) void {
        self.log().print("{f} " ++ fmt ++ "\n", .{green("✓")} ++ args) catch {};
    }

    pub fn warn(self: Ui, comptime fmt: []const u8, args: anytype) void {
        self.log().print("{f} " ++ fmt ++ "\n", .{yellow("!")} ++ args) catch {};
    }

    pub fn step(self: Ui, comptime fmt: []const u8, args: anytype) void {
        self.log().print("{f} " ++ fmt ++ "\n", .{cyan("›")} ++ args) catch {};
    }

    pub fn hint(self: Ui, comptime fmt: []const u8, args: anytype) void {
        // `log.dim` in the TypeScript version.
        const w = self.log();
        if (color_enabled) w.writeAll(Code.dim) catch {};
        w.print(fmt, args) catch {};
        if (color_enabled) w.writeAll(Code.reset) catch {};
        w.writeAll("\n") catch {};
    }

    pub fn fail(self: Ui, comptime fmt: []const u8, args: anytype) void {
        self.flush();
        self.err.print("{f} " ++ fmt ++ "\n", .{red("✗")} ++ args) catch {};
        self.err.flush() catch {};
    }

    /// Machine-readable output — never coloured, never diverted, always the only
    /// thing on stdout when `divert` is set.
    pub fn payload(self: Ui, comptime fmt: []const u8, args: anytype) void {
        self.out.print(fmt, args) catch {};
    }

    pub fn flush(self: Ui) void {
        self.out.flush() catch {};
        if (self.divert) self.err.flush() catch {};
    }
};

/// Pads `text` to `width` *display* columns, counting codepoints rather than
/// bytes so non-ASCII issue titles do not shift the columns.
pub const Padded = struct {
    text: []const u8,
    width: usize,

    pub fn format(self: Padded, w: *Io.Writer) Io.Writer.Error!void {
        try w.writeAll(self.text);
        const len = displayWidth(self.text);
        if (len < self.width) try w.splatByteAll(' ', self.width - len);
    }
};

pub fn pad(text: []const u8, width: usize) Padded {
    return .{ .text = text, .width = width };
}

/// Codepoint count — close enough to display width for the Latin/Cyrillic text
/// that shows up in Linear titles and branch names.
pub fn displayWidth(text: []const u8) usize {
    var cols: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        i += @min(len, text.len - i);
        cols += 1;
    }
    return cols;
}

/// Human-readable byte count, matching `formatBytes` in derived-data.ts.
pub const Bytes = struct {
    value: u64,

    pub fn format(self: Bytes, w: *Io.Writer) Io.Writer.Error!void {
        if (self.value < 1024) return w.print("{d} B", .{self.value});
        const units = [_][]const u8{ "KB", "MB", "GB", "TB" };
        var v: f64 = @as(f64, @floatFromInt(self.value)) / 1024.0;
        var unit: usize = 0;
        while (v >= 1024 and unit < units.len - 1) {
            v /= 1024;
            unit += 1;
        }
        if (v < 10) {
            try w.print("{d:.1} {s}", .{ v, units[unit] });
        } else {
            try w.print("{d:.0} {s}", .{ v, units[unit] });
        }
    }
};

pub fn bytes(value: u64) Bytes {
    return .{ .value = value };
}

/// Human-readable count — `812`, `3.7k`, `62.2M`. Token counts reach nine
/// digits, which no table column can carry and no reader wants to parse.
pub const Count = struct {
    value: u64,

    pub fn format(self: Count, w: *Io.Writer) Io.Writer.Error!void {
        if (self.value < 1000) return w.print("{d}", .{self.value});
        const units = [_][]const u8{ "k", "M", "B" };
        var v: f64 = @as(f64, @floatFromInt(self.value)) / 1000.0;
        var unit: usize = 0;
        while (v >= 1000 and unit < units.len - 1) {
            v /= 1000;
            unit += 1;
        }
        if (v < 10) {
            try w.print("{d:.1}{s}", .{ v, units[unit] });
        } else {
            try w.print("{d:.0}{s}", .{ v, units[unit] });
        }
    }
};

pub fn count(value: u64) Count {
    return .{ .value = value };
}

/// Coarse elapsed time in one or two characters plus a unit — `2h`, `6d`, `3w`.
/// A dashboard column wants "roughly how stale", not a duration.
pub const Age = struct {
    seconds: i64,

    pub fn format(self: Age, w: *Io.Writer) Io.Writer.Error!void {
        // A tip committed in the future (clock skew, a rebase with an old date)
        // is not worth a negative number.
        if (self.seconds <= 0) return w.writeAll("now");
        const s: u64 = @intCast(self.seconds);
        const minute = 60;
        const hour = 60 * minute;
        const day = 24 * hour;
        const week = 7 * day;
        const month = 30 * day;
        const year = 365 * day;

        if (s < minute) return w.writeAll("now");
        if (s < hour) return w.print("{d}m", .{s / minute});
        if (s < day) return w.print("{d}h", .{s / hour});
        if (s < week) return w.print("{d}d", .{s / day});
        if (s < month) return w.print("{d}w", .{s / week});
        if (s < year) return w.print("{d}mo", .{s / month});
        return w.print("{d}y", .{s / year});
    }
};

pub fn age(seconds: i64) Age {
    return .{ .seconds = seconds };
}

/// A worked length of time, in two units at most — `0m`, `12m`, `9h40m`, `2d3h`.
///
/// Deliberately not `Age`, which rounds to one unit because "roughly how stale"
/// is all a staleness column can honestly claim. This is a duration someone is
/// meant to weigh against a working day, and there `9h` and `9h40m` are
/// different answers.
pub const Duration = struct {
    seconds: i64,

    pub fn format(self: Duration, w: *Io.Writer) Io.Writer.Error!void {
        if (self.seconds <= 0) return w.writeAll("0m");
        const s: u64 = @intCast(self.seconds);
        const minute = 60;
        const hour = 60 * minute;
        const day = 24 * hour;

        if (s < hour) return w.print("{d}m", .{s / minute});
        if (s < day) {
            const hours = s / hour;
            const minutes = (s % hour) / minute;
            if (minutes == 0) return w.print("{d}h", .{hours});
            return w.print("{d}h{d}m", .{ hours, minutes });
        }
        const days = s / day;
        const hours = (s % day) / hour;
        if (hours == 0) return w.print("{d}d", .{days});
        return w.print("{d}d{d}h", .{ days, hours });
    }
};

pub fn duration(seconds: i64) Duration {
    return .{ .seconds = seconds };
}

test "duration keeps the second unit that age rounds away" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { seconds: i64, want: []const u8 }{
        .{ .seconds = -1, .want = "0m" },
        .{ .seconds = 0, .want = "0m" },
        // Under a minute is real time worked, but there is no unit below `m`
        // worth a column — it rounds down rather than inventing one.
        .{ .seconds = 59, .want = "0m" },
        .{ .seconds = 12 * 60, .want = "12m" },
        .{ .seconds = 3600, .want = "1h" },
        .{ .seconds = 9 * 3600 + 40 * 60, .want = "9h40m" },
        // Seconds never surface: the trailing 30 is dropped, not rounded up.
        .{ .seconds = 9 * 3600 + 40 * 60 + 30, .want = "9h40m" },
        .{ .seconds = 24 * 3600, .want = "1d" },
        .{ .seconds = 2 * 24 * 3600 + 3 * 3600, .want = "2d3h" },
    };
    for (cases) |case| {
        const got = try std.fmt.allocPrint(gpa, "{f}", .{duration(case.seconds)});
        defer gpa.free(got);
        try std.testing.expectEqualStrings(case.want, got);
    }
}

test "age renders the coarsest unit that fits" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { seconds: i64, want: []const u8 }{
        .{ .seconds = -30, .want = "now" },
        .{ .seconds = 0, .want = "now" },
        .{ .seconds = 59, .want = "now" },
        .{ .seconds = 60, .want = "1m" },
        .{ .seconds = 59 * 60, .want = "59m" },
        .{ .seconds = 2 * 3600, .want = "2h" },
        .{ .seconds = 23 * 3600, .want = "23h" },
        .{ .seconds = 6 * 24 * 3600, .want = "6d" },
        .{ .seconds = 11 * 24 * 3600, .want = "1w" },
        .{ .seconds = 29 * 24 * 3600, .want = "4w" },
        .{ .seconds = 90 * 24 * 3600, .want = "3mo" },
        .{ .seconds = 800 * 24 * 3600, .want = "2y" },
    };
    for (cases) |case| {
        const got = try std.fmt.allocPrint(gpa, "{f}", .{age(case.seconds)});
        defer gpa.free(got);
        try std.testing.expectEqualStrings(case.want, got);
    }
}

test "count switches unit at a thousand, not a kibibyte" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { value: u64, want: []const u8 }{
        .{ .value = 0, .want = "0" },
        .{ .value = 999, .want = "999" },
        .{ .value = 1000, .want = "1.0k" },
        .{ .value = 3675, .want = "3.7k" },
        .{ .value = 417_196, .want = "417k" },
        .{ .value = 62_246_287, .want = "62M" },
        .{ .value = 1_526_969, .want = "1.5M" },
        .{ .value = 2_400_000_000, .want = "2.4B" },
    };
    for (cases) |case| {
        const got = try std.fmt.allocPrint(gpa, "{f}", .{count(case.value)});
        defer gpa.free(got);
        try std.testing.expectEqualStrings(case.want, got);
    }
}

test "bytes keeps one decimal only below ten units" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { value: u64, want: []const u8 }{
        .{ .value = 512, .want = "512 B" },
        .{ .value = 1536, .want = "1.5 KB" },
        .{ .value = 12 * 1024, .want = "12 KB" },
        .{ .value = 2 * 1024 * 1024 * 1024, .want = "2.0 GB" },
    };
    for (cases) |case| {
        const got = try std.fmt.allocPrint(gpa, "{f}", .{bytes(case.value)});
        defer gpa.free(got);
        try std.testing.expectEqualStrings(case.want, got);
    }
}
