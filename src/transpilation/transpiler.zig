const std = @import("std");
const common = @import("../common.zig");
const lexing = @import("./lexing.zig");
const parsing = @import("./parsing.zig");

const String = []const u8;
const CString = [:0]const u8;
const MutString = std.ArrayList(u8);

pub fn transpile(allocator: std.mem.Allocator, input: String) !MutString {
    var lexer = try lexing.Lexer.init(allocator, input);
    defer lexer.deinit();

    _ = try lexer.lex();
    const lexed_result = try lexer.getOwnedResult();

    std.debug.print("Lexed: {any}\n", .{lexed_result.tokens.items});

    // TODO: Fix up this allocation pattern
    var parser = try parsing.Parser.init(allocator, lexed_result);
    defer parser.deinit();

    var parsed_result = try parser.parse(allocator);
    defer parsed_result.deinit();

    const output = try parsed_result.render(allocator);

    return output;
}

fn testHarness(input: String, expected: String) !void {
    const allocator = std.testing.allocator;

    var transpiled = try transpile(allocator, input);
    defer transpiled.deinit(allocator);

    std.debug.print("Got:      '{s}'\n", .{transpiled.items});

    try std.testing.expect(std.mem.eql(u8, transpiled.items, expected));
}

test "basic e2e transpile" {
    const input = "  select  c1,   c2   ";
    const expected = "select c1, c2";

    _ = try testHarness(input, expected);
}

// test "transpile multiple clauses" {
//     const input = "select c1, c2 from xyz where true";

//     _ = try testHarness(input, input);
// }
