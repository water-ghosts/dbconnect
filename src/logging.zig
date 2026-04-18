// Use C library's localtime to get local timezone date
const c = @cImport({
    @cInclude("time.h");
});

const std = @import("std");
const common = @import("common.zig");

const String = common.String;

pub fn writeFile(content: String, filepath: String) !void {
    // Extract directory path from filepath
    const dirname = std.fs.path.dirname(filepath);

    // Create directory if it doesn't exist (including parent directories)
    if (dirname) |dir| {
        std.fs.cwd().makePath(dir) catch |err| switch (err) {
            error.PathAlreadyExists => {}, // Directory already exists, continue
            else => return err,
        };
    }

    // Create/overwrite the file
    const file = try std.fs.cwd().createFile(filepath, .{});
    defer file.close();

    // Write the content
    try file.writeAll(content);
}

pub fn get_dated_filepath(directory: String, buffer: []u8) !String {
    // Get current unix timestamp
    const timestamp = std.time.timestamp();

    var time_val: c.time_t = @intCast(timestamp);
    const local_time = c.localtime(&time_val);

    if (local_time == null) return error.LocalTimeConversionFailed;

    const year = local_time.*.tm_year + 1900;
    const month: u32 = @intCast(local_time.*.tm_mon + 1);
    const day: u32 = @intCast(local_time.*.tm_mday);

    // Build filepath: QUERY_LOG_DIR/year/month/day/timestamp.sql
    const filepath = std.fmt.bufPrint(buffer, "{s}/{d}/{d:02}/{d:02}/{d}.toml", .{
        directory,
        year,
        month,
        day,
        timestamp,
    }) catch return error.PathTooLong;

    return filepath;
}
