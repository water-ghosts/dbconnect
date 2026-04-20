const std = @import("std");
const transpiler = @import("./transpilation/transpiler.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer {
        const check = gpa.deinit();
        if (check == .leak) std.debug.print("Memory leak detected!\n", .{});
    }

    const stdin = std.fs.File.stdin();
    const stdout = std.fs.File.stdout();
    var stdout_writer = stdout.writer(&.{});
    const out = &stdout_writer.interface;

    try out.print("Transpile REPL — enter quasi-SQL, empty line to quit\n\n", .{});

    while (true) {
        try out.print("> ", .{});
        try out.flush();

        var input_buffer: [65536]u8 = undefined;
        var stdin_reader = stdin.reader(&input_buffer);
        const raw_input = stdin_reader.interface.takeDelimiterExclusive('\n') catch break;

        const input = std.mem.trim(u8, raw_input, &std.ascii.whitespace);
        if (input.len == 0) break;

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        const result = transpiler.transpile(arena.allocator(), input) catch |err| {
            try out.print("Error: {}\n\n", .{err});
            continue;
        };

        try out.print("{s}\n\n", .{result.items});
    }
}
