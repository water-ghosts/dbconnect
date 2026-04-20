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

const stringsMatch = common.stringsMatch;

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

const ReplMode = enum { STANDARD, TRANSPILE_LOOP };

const ParsedCommand = struct {
    command_type: CommandType,
    args: String,
};

const Config = struct { connection_string: String, query_dir: String, query_log_dir: String };

const ReplContext = struct {
    persistent_allocator: std.mem.Allocator,
    scratch_arena: std.heap.ArenaAllocator,
    dataset: datastores.DataSet,
    database_connection: db.DatabaseConnection,
    query_dir: String,
    query_log_dir: String,
    stdin: std.fs.File,
    stdout: std.fs.File,
    raw_query_buffer: ResizableBuffer,
    dataset_buffer: ResizableBuffer,
    current_mode: ReplMode,

    pub fn init(persistent_allocator: std.mem.Allocator) !ReplContext {
        var scratch_arena = std.heap.ArenaAllocator.init(persistent_allocator);
        const scratch_allocator = scratch_arena.allocator();

        // Load config
        const config_path = try getConfigPath(scratch_allocator);
        const config = try parseConfig(scratch_allocator, config_path);

        const query_dir = try persistent_allocator.dupe(u8, config.query_dir);
        errdefer persistent_allocator.free(query_dir);

        const query_log_dir = try persistent_allocator.dupe(u8, config.query_log_dir);
        errdefer persistent_allocator.free(query_log_dir);

        // Connect to DB, although maybe I want this optional?
        const database_connection = try db.DatabaseConnection.init(persistent_allocator, config.connection_string);

        var raw_query_buffer = try ResizableBuffer.init(persistent_allocator, 1024);
        errdefer raw_query_buffer.deinit();
        raw_query_buffer.appendSlice("<EMPTY>");

        var dataset_buffer = try ResizableBuffer.init(persistent_allocator, 1024);
        errdefer dataset_buffer.deinit();
        dataset_buffer.appendSlice("<EMPTY>");

        _ = scratch_arena.reset(.retain_capacity);

        return ReplContext{
            .persistent_allocator = persistent_allocator,
            .scratch_arena = scratch_arena,
            .dataset = datastores.NullDataset,
            .database_connection = database_connection,
            .query_dir = query_dir,
            .query_log_dir = query_log_dir,
            .stdin = std.fs.File.stdin(),
            .stdout = std.fs.File.stdout(),
            .raw_query_buffer = raw_query_buffer,
            .dataset_buffer = dataset_buffer,
            .current_mode = ReplMode.STANDARD,
        };
    }

    pub fn scratchAllocator(self: *ReplContext) std.mem.Allocator {
        return self.scratch_arena.allocator();
    }

    pub fn endFrame(self: *ReplContext) void {
        _ = self.scratch_arena.reset(.retain_capacity);
    }

    pub fn deinit(self: *ReplContext) void {
        self.scratch_arena.deinit();
        self.dataset.deinit();
        self.database_connection.deinit();
        self.persistent_allocator.free(self.query_dir);
        self.persistent_allocator.free(self.query_log_dir);
        self.raw_query_buffer.deinit();
        self.dataset_buffer.deinit();
    }
};

const CSV_PREVIEW_SIZE = 10;

pub fn parseCommand(raw_command: String) ParsedCommand {
    // Trim leading/trailing whitespace
    const command = std.mem.trim(u8, raw_command, &std.ascii.whitespace);

    // Find the first space to separate command from args
    const space_index = std.mem.indexOfScalar(u8, command, ' ');

    const first_word = if (space_index) |idx| command[0..idx] else command;
    const args = if (space_index) |idx| std.mem.trim(u8, command[idx + 1 ..], &std.ascii.whitespace) else "";

    // Determine command type based on first word
    const verb = if (stringsMatch(first_word, "quit"))
        CommandType.QUIT
    else if (stringsMatch(first_word, "load"))
        CommandType.LOAD
    else if (stringsMatch(first_word, "open"))
        CommandType.OPEN
    else if (stringsMatch(first_word, "preview"))
        CommandType.PREVIEW
    else if (stringsMatch(first_word, "print"))
        CommandType.PRINT
    else if (stringsMatch(first_word, "run"))
        CommandType.RUN
    else if (stringsMatch(first_word, "transpile"))
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
    std.debug.print("Query logged to {s}\n", .{filepath});
}

fn getConfigPath(allocator: std.mem.Allocator) !String {
    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();

    const home_dir = env_map.get("HOME") orelse "";
    const config_path = try std.fmt.allocPrint(allocator, "{s}/dbconnect_config.toml", .{home_dir});
    return config_path;
}

pub fn main_loop(context: *ReplContext) !void {
    const persistent_allocator = context.persistent_allocator;
    const scratch_allocator = context.scratchAllocator();

    var stdout_writer = context.stdout.writer(&.{});
    const stdout = &stdout_writer.interface;

    while (true) {
        defer context.endFrame();

        // Get input
        try stdout.print("> ", .{});
        try stdout.flush();
        var input_buffer: [4096]u8 = undefined;
        var stdin_reader = context.stdin.reader(&input_buffer);
        const raw_input = stdin_reader.interface.takeDelimiterExclusive('\n') catch "";

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
                const csv_data = try context.dataset.toCsv(scratch_allocator);

                // Get temp file name
                var buffer: [1024]u8 = undefined;
                const hash_value = std.hash.Wyhash.hash(0, csv_data);
                const filepath = try std.fmt.bufPrint(&buffer, "/tmp/dataset_{d}.csv", .{hash_value});

                // Write CSV to a temp file
                try logging.writeFile(csv_data, filepath);

                // Open that file
                try openFile(scratch_allocator, filepath);
            },
            CommandType.READ => {
                const filepath = try common.resolveFilepath(scratch_allocator, parsed_command.args, context.query_dir);

                common.readFileToBuffer(filepath, &context.raw_query_buffer) catch {
                    try stdout.print("Unable to read file at {s}\n", .{filepath});
                    continue;
                };
                try stdout.print("Loaded file\n", .{});
            },
            CommandType.LOAD => {
                const filepath = try common.resolveFilepath(scratch_allocator, parsed_command.args, context.query_dir);

                // Dispatch on file extension
                const extension = std.fs.path.extension(filepath);

                // For SQL/TXT files, read to context.raw_query_buffer
                if (stringsMatch(extension, ".sql") or stringsMatch(extension, ".txt")) {
                    common.readFileToBuffer(filepath, &context.raw_query_buffer) catch {
                        try stdout.print("Unable to read file at {s}\n", .{filepath});
                        continue;
                    };
                    try stdout.print("Loaded query from {s}\n", .{filepath});
                } else if (std.mem.eql(u8, extension, ".json")) {
                    // For JSON files, read to context.dataset_buffer and initialize dataset
                    common.readFileToBuffer(filepath, &context.dataset_buffer) catch {
                        try stdout.print("Unable to read file at {s}\n", .{filepath});
                        continue;
                    };
                    context.dataset.deinit();
                    context.dataset = datastores.DataSet.initFromJson(persistent_allocator, context.dataset_buffer.readVolatile()) catch {
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
                const csv_data = try context.dataset.toCsvPreview(scratch_allocator, CSV_PREVIEW_SIZE);
                try stdout.print("{s}\n", .{csv_data});
            },
            CommandType.PRINT => {
                try stdout.print("{s}\n", .{context.raw_query_buffer.readVolatile()});
            },
            CommandType.RUN => {
                context.dataset.deinit();

                const new_dataset = db.executeQuery(persistent_allocator, context.database_connection, context.raw_query_buffer.readVolatile()) catch {
                    context.dataset = datastores.NullDataset;
                    break;
                };

                context.dataset = new_dataset;

                try log_query(scratch_allocator, context.query_log_dir, context.raw_query_buffer.readVolatile(), &context.dataset);
            },
            CommandType.TRANSPILE => {
                const transpiled = try transpiler.transpile(scratch_allocator, context.raw_query_buffer.readVolatile());
                context.raw_query_buffer.clear();
                context.raw_query_buffer.appendSlice(transpiled.items);
            },
        }

        // // Render (perhaps with clear screen)
        // try stdout.print("{s}\n", .{input});
        // try stdout.flush();
    }
}

pub fn main() !void {
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

    var context = try ReplContext.init(allocator);
    defer context.deinit();

    try main_loop(&context);
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
