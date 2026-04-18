const std = @import("std");
const common = @import("common.zig");
const datastores = @import("./datastores.zig");
const db = @import("database_connector.zig");
const logging = @import("logging.zig");
const transpiler = @import("./transpilation//transpiler.zig");

const String = common.String;
const CString = common.CString;
const MutString = common.MutString;
const ResizableBuffer = common.ResizableBuffer;

const CommandType = enum {
    INVALID_COMMAND,
    LOAD,
    OPEN,
    PREVIEW,
    PRINT,
    QUIT,
    READ,
    RUN,
    TRANSPILE,
};

const ParsedCommand = struct {
    command_type: CommandType,
    args: String,
};

const Config = struct { connection_string: String, query_dir: String, query_log_dir: String };

const CSV_PREVIEW_SIZE = 10;

pub fn parseCommand(raw_command: String) ParsedCommand {
    // Trim leading/trailing whitespace
    const command = std.mem.trim(u8, raw_command, &std.ascii.whitespace);

    // Find the first space to separate command from args
    const space_index = std.mem.indexOfScalar(u8, command, ' ');

    const first_word = if (space_index) |idx| command[0..idx] else command;
    const args = if (space_index) |idx| std.mem.trim(u8, command[idx + 1 ..], &std.ascii.whitespace) else "";

    // Determine command type based on first word
    const verb = if (std.mem.eql(u8, first_word, "quit"))
        CommandType.QUIT
    else if (std.mem.eql(u8, first_word, "load"))
        CommandType.LOAD
    else if (std.mem.eql(u8, first_word, "open"))
        CommandType.OPEN
    else if (std.mem.eql(u8, first_word, "preview"))
        CommandType.PREVIEW
    else if (std.mem.eql(u8, first_word, "print"))
        CommandType.PRINT
    else if (std.mem.eql(u8, first_word, "run"))
        CommandType.RUN
    else if (std.mem.eql(u8, first_word, "transpile"))
        CommandType.TRANSPILE
    else
        CommandType.INVALID_COMMAND;

    return ParsedCommand{
        .command_type = verb,
        .args = args,
    };
}

pub fn openFile(allocator: std.mem.Allocator, filepath: String) !void {
    var child = std.process.Child.init(&[_][]const u8{ "open", filepath }, allocator);
    _ = try child.spawnAndWait();
}

pub fn parseConfig(allocator: std.mem.Allocator, config_path: String) !Config {
    const file = try std.fs.cwd().openFile(config_path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    var connection_string: ?String = null;
    var query_dir: ?String = null;
    var query_log_dir: ?String = null;

    errdefer {
        if (connection_string) |s| allocator.free(s);
        if (query_dir) |s| allocator.free(s);
        if (query_log_dir) |s| allocator.free(s);
    }

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (trimmed.len == 0) continue;

        const eq_idx = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
        const key = std.mem.trim(u8, trimmed[0..eq_idx], &std.ascii.whitespace);
        var value = std.mem.trim(u8, trimmed[eq_idx + 1 ..], &std.ascii.whitespace);

        if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
            value = value[1 .. value.len - 1];
        }

        if (std.mem.eql(u8, key, "CONNECTION_STRING")) {
            connection_string = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "QUERY_DIR")) {
            query_dir = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "QUERY_LOG_DIR")) {
            query_log_dir = try allocator.dupe(u8, value);
        }
    }

    return Config{
        .connection_string = connection_string orelse return error.MissingConfigField,
        .query_dir = query_dir orelse return error.MissingConfigField,
        .query_log_dir = query_log_dir orelse return error.MissingConfigField,
    };
}

/// Reads the entire contents of a file into a string.
/// The caller is responsible for freeing the returned memory using the same allocator.
/// Assumes the file contains valid UTF-8 text.
pub fn readFileToBuffer(filepath: []const u8, buffer: *ResizableBuffer) !void {
    const file = try std.fs.cwd().openFile(filepath, .{});
    defer file.close();

    buffer.clear();

    // Read file in chunks
    var read_buffer: [4096]u8 = undefined;
    while (true) {
        const bytes_read = try file.read(&read_buffer);
        if (bytes_read == 0) break;

        buffer.appendSlice(read_buffer[0..bytes_read]);
    }
}

pub fn startsWith(str: String, char: u8) bool {
    return str.len > 0 and str[0] == char;
}

pub fn endsWith(str: String, char: u8) bool {
    return str.len > 0 and str[str.len - 1] == char;
}

// TODO: Simplify this by writing to a provided buffer, hopefully avoiding allocation
pub fn resolveFilepath(allocator: std.mem.Allocator, rawFilepath: String, defaultDirectory: String) !String {
    const filepath = std.mem.trim(u8, rawFilepath, &std.ascii.whitespace);

    // Check if the filepath is absolute (starts with '/' on Unix)
    if (startsWith(filepath, '/')) {
        // Absolute path - return a copy
        return try allocator.dupe(u8, filepath);
    }

    // Relative path - concatenate with defaultDirectory
    // Ensure defaultDirectory ends with '/' if it doesn't already
    const needsSlash = !endsWith(defaultDirectory, '/');
    const totalLen = defaultDirectory.len + (if (needsSlash) @as(usize, 1) else 0) + filepath.len;

    const resolved = try allocator.alloc(u8, totalLen);
    var pos: usize = 0;

    // Copy defaultDirectory
    @memcpy(resolved[pos..][0..defaultDirectory.len], defaultDirectory);
    pos += defaultDirectory.len;

    // Add separator if needed
    if (needsSlash) {
        resolved[pos] = '/';
        pos += 1;
    }

    // Copy filepath
    @memcpy(resolved[pos..][0..filepath.len], filepath);

    return resolved;
}

// TODO: This is not actually valid TOML. Maybe I comment out the preview lines?
fn log_query(allocator: std.mem.Allocator, directory: String, query: String, dataset: *const datastores.DataSet) !void {
    var filepath_buffer: [1024]u8 = undefined;
    const filepath = try logging.get_dated_filepath(directory, &filepath_buffer);

    const csv = try dataset.toCsvPreview(allocator, CSV_PREVIEW_SIZE);
    defer allocator.free(csv);

    var toml = common.StringBuilder.init(allocator);
    defer toml.deinit();

    toml.append("[query]\n\n");
    toml.append(query);
    toml.append("\n[results]\n\n");
    toml.append(csv);

    try logging.writeFile(toml.viewString(), filepath);
    std.debug.print("Query logged to {s}", .{filepath});
}

fn getHomeDir(allocator: std.mem.Allocator) !String {
    const env_map = try std.process.getEnvMap(allocator);

    return env_map.get("HOME") orelse error.HomeDirNotFound;
}

pub fn main_loop() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    defer {
        const check = gpa.deinit();
        if (check == .leak) {
            std.debug.print("Memory leak detected!\n", .{});
        } else {
            std.debug.print("No leaks\n", .{});
        }
    }

    const home_dir = try getHomeDir(allocator);
    defer allocator.free(home_dir);
    const config_path = try std.fmt.allocPrint(allocator, "{s}/dbconnect_config.toml", .{home_dir});

    defer allocator.free(config_path);

    std.debug.print("{s}\n", .{config_path});
    const config = try parseConfig(allocator, config_path);

    const default_directory: String = config.query_dir;
    const log_directory: String = config.query_log_dir;
    const connection_string = config.connection_string;
    std.debug.print("{s}\n", .{connection_string});

    // Read filepath from user input
    var filepath_buffer: [1024]u8 = undefined;

    var stdin_reader = std.fs.File.stdin().reader(&filepath_buffer);
    const stdin = &stdin_reader.interface;

    var stdout_writer = std.fs.File.stdout().writer(&.{});
    const stdout = &stdout_writer.interface;

    var raw_query_buffer = try ResizableBuffer.init(allocator, 1024);
    defer raw_query_buffer.deinit();
    raw_query_buffer.appendSlice("<EMPTY>");

    var dataset_buffer = try ResizableBuffer.init(allocator, 1024);
    defer dataset_buffer.deinit();
    dataset_buffer.appendSlice("<EMPTY>");

    var dataset: datastores.DataSet = datastores.NullDataset;

    var database_connection = try db.DatabaseConnection.init(allocator, connection_string);
    defer database_connection.deinit();

    // For now, this can use standard stdin / stdout reading and printing.
    // V2 will actually update per character, perhaps.
    while (true) {
        // Get input
        try stdout.print("> ", .{});
        try stdout.flush();
        const raw_input = stdin.takeDelimiterExclusive('\n') catch "";

        // Parse command
        const parsed_command = parseCommand(raw_input);

        // Update State
        switch (parsed_command.command_type) {
            CommandType.INVALID_COMMAND => {
                try stdout.print("Invalid Command: {s}\n", .{raw_input});
                try stdout.flush();
            },
            CommandType.QUIT => {
                try stdout.print("Bye!\n", .{});
                try stdout.flush();
                break;
            },
            CommandType.OPEN => {
                const csv_data = try dataset.toCsv(allocator);
                defer allocator.free(csv_data);

                // Get temp file name
                var buffer: [1024]u8 = undefined;
                const hash_value = std.hash.Wyhash.hash(0, csv_data);
                const filepath = try std.fmt.bufPrint(&buffer, "/tmp/dataset_{d}.csv", .{hash_value});

                // Write CSV to a temp file
                try logging.writeFile(csv_data, filepath);

                // Open that file
                try openFile(allocator, filepath);
            },
            CommandType.READ => {
                const filepath = try resolveFilepath(allocator, parsed_command.args, default_directory);
                defer allocator.free(filepath);

                readFileToBuffer(filepath, &raw_query_buffer) catch {
                    try stdout.print("Unable to read file at {s}\n", .{filepath});
                    continue;
                };
                try stdout.print("Loaded file\n", .{});
            },
            CommandType.LOAD => {
                const filepath = try resolveFilepath(allocator, parsed_command.args, default_directory);
                defer allocator.free(filepath);

                // Dispatch on file extension
                const extension = std.fs.path.extension(filepath);

                if (std.mem.eql(u8, extension, ".sql") or std.mem.eql(u8, extension, ".txt")) {
                    // For SQL/TXT files, read to raw_query_buffer
                    readFileToBuffer(filepath, &raw_query_buffer) catch {
                        try stdout.print("Unable to read file at {s}\n", .{filepath});
                        continue;
                    };
                    try stdout.print("Loaded query from {s}\n", .{filepath});
                } else if (std.mem.eql(u8, extension, ".json")) {
                    // For JSON files, read to dataset_buffer and initialize dataset
                    readFileToBuffer(filepath, &dataset_buffer) catch {
                        try stdout.print("Unable to read file at {s}\n", .{filepath});
                        continue;
                    };
                    dataset.deinit();
                    dataset = datastores.DataSet.initFromJson(allocator, dataset_buffer.readVolatile()) catch {
                        try stdout.print("Unable to load data at {s}\n", .{filepath});
                        continue;
                    };
                    try stdout.print("Loaded dataset from {s}\n", .{filepath});
                } else {
                    // For any other extension, do nothing
                    try stdout.print("Unsupported file type: {s}\n", .{extension});
                }
            },
            CommandType.PREVIEW => {
                const csv_data = try dataset.toCsvPreview(allocator, CSV_PREVIEW_SIZE);
                defer allocator.free(csv_data);
                try stdout.print("{s}\n", .{csv_data});
            },
            CommandType.PRINT => {
                try stdout.print("{s}\n", .{raw_query_buffer.readVolatile()});
            },
            CommandType.RUN => {
                dataset.deinit();

                const new_dataset = db.executeQuery(allocator, database_connection, raw_query_buffer.readVolatile()) catch {
                    dataset = datastores.NullDataset;
                    break;
                };

                dataset = new_dataset;
                try log_query(allocator, log_directory, raw_query_buffer.readVolatile(), &dataset);
            },
            CommandType.TRANSPILE => {
                var transpiled = try transpiler.transpile(allocator, raw_query_buffer.readVolatile());
                defer transpiled.deinit(allocator);
                raw_query_buffer.clear();
                raw_query_buffer.appendSlice(transpiled.items);
            },
        }

        // // Render (perhaps with clear screen)
        // try stdout.print("{s}\n", .{input});
        // try stdout.flush();
    }

    dataset.deinit();
}

pub fn main_transpile() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    defer {
        const check = gpa.deinit();
        if (check == .leak) {
            std.debug.print("Memory leak detected!\n", .{});
        } else {
            std.debug.print("No leaks\n", .{});
        }
    }
    var filepath_buffer: [1024]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&filepath_buffer);
    const stdin = &stdin_reader.interface;

    var stdout_writer = std.fs.File.stdout().writer(&.{});
    const stdout = &stdout_writer.interface;

    // For now, this can use standard stdin / stdout reading and printing.
    // V2 will actually update per character, perhaps.
    while (true) {
        // Get input
        try stdout.print("> ", .{});
        try stdout.flush();
        const raw_input = stdin.takeDelimiterInclusive('\n') catch "";

        const input = raw_input;

        var transpiled = try transpiler.transpile(allocator, input);
        defer transpiled.deinit(allocator);

        try stdout.print("{s}\n", .{transpiled.items});
        try stdout.flush();
    }
}

pub fn main() !void {
    try main_loop();
    // try main_transpile();
}

test "JSONIntegrationTest" {
    var allocator = std.testing.allocator;

    const jsonSpec: String =
        \\{
        \\    "rowCount": 3,
        \\    "data": [
        \\        {
        \\            "name": "account_id",
        \\            "dtype": "INTEGER",
        \\            "values": [
        \\                123,
        \\                null,
        \\                789
        \\            ]
        \\        },
        \\        {
        \\            "name": "revenue",
        \\            "dtype": "FLOAT",
        \\            "values": [
        \\                1.2,
        \\                2.3,
        \\                null
        \\            ]
        \\        },
        \\        {
        \\            "name": "is_pretty_cool",
        \\            "dtype": "BOOLEAN",
        \\            "values": [
        \\                true,
        \\                false,
        \\                null
        \\            ]
        \\        },
        \\        {
        \\            "name": "eek, a string column",
        \\            "dtype": "STRING",
        \\            "values": [
        \\                "alas, this is text",
        \\                null,
        \\                "cats"
        \\            ]
        \\        }
        \\    ]
        \\}
    ;

    var dataset = try datastores.DataSet.initFromJson(allocator, jsonSpec);
    defer dataset.deinit();

    const the_csv = try dataset.toCsv(allocator);
    defer allocator.free(the_csv);

    const expected: String =
        \\account_id,revenue,is_pretty_cool,"eek, a string column"
        \\123,1.2,true,"alas, this is text"
        \\<NULL>,2.3,false,<NULL>
        \\789,<NULL>,<NULL>,cats
        \\
    ;

    try std.testing.expect(std.mem.eql(u8, the_csv, expected));
}

test {
    std.testing.refAllDecls(@This());
}
