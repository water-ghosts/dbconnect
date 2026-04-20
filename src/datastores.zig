const std = @import("std");
const common = @import("./common.zig");

const c = @cImport({
    @cInclude("../include/sqltypes.h");
});

const String = []const u8;
const CString = [:0]const u8;
const MutString = std.ArrayList(u8);

const COLUMN_NAME_MAX_BYTES = 256;

const DataType = enum {
    BOOLEAN,
    INTEGER, // Same as bigint! Just use 64 bit longs everywhere
    FLOAT,
    STRING,

    // NOT IMPLEMENTED - DATE
    DATE,
    DATETIME,
    TIME,

    // NOT IMPLEMENTED - COMPLEX
    // ARRAY,
    // OBJECT,
    // VARIANT?

    // NOT IMPLEMENTED - OTHER
    // BINARY (which I've literally never used)
};

// I could make this a bitfield as a later optimization / fun project
pub const BooleanArray = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    data: std.ArrayList(bool),

    fn getBoolean(self: *const Self, index: usize) bool {
        return self.data.items[index];
    }

    fn toString(self: *const Self, index: usize, buffer: []u8) ![]u8 {
        const raw = self.data.items[index];
        const slice = try std.fmt.bufPrint(buffer, "{}", .{raw});
        return slice;
    }

    fn len(self: *const Self) usize {
        return self.data.items.len;
    }

    fn deinit(self: *Self) void {
        self.data.deinit(self.allocator);
    }
};

pub const IntegerArray = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    data: std.ArrayList(i64),

    fn getInteger(self: *const Self, index: u64) i64 {
        return self.data.items[index];
    }

    fn toString(self: *const Self, index: usize, buffer: []u8) ![]u8 {
        const raw = self.data.items[index];
        const slice = try std.fmt.bufPrint(buffer, "{}", .{raw});
        return slice;
    }

    fn len(self: *const Self) usize {
        return self.data.items.len;
    }

    fn deinit(self: *Self) void {
        self.data.deinit(self.allocator);
    }
};

pub const FloatArray = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    data: std.ArrayList(f64),

    fn getFloat(self: *const Self, index: u64) f64 {
        return self.data.items[index];
    }

    fn toString(self: *const Self, index: usize, buffer: []u8) ![]u8 {
        const raw = self.data.items[index];
        const slice = try std.fmt.bufPrint(buffer, "{d}", .{raw});
        return slice;
    }

    fn len(self: *const Self) usize {
        return self.data.items.len;
    }

    fn deinit(self: *Self) void {
        self.data.deinit(self.allocator);
    }
};

pub const DateArray = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    data: std.ArrayList(c.SQL_DATE_STRUCT),

    fn getDate(self: *const Self, index: u64) c.SQL_DATE_STRUCT {
        return self.data.items[index];
    }

    fn toString(self: *const Self, index: usize, buffer: []u8) ![]u8 {
        const raw = self.data.items[index];
        const slice = try std.fmt.bufPrint(buffer, "{d}-{d:02}-{d:02}", .{ raw.year, raw.month, raw.day });
        return slice;
    }

    fn len(self: *const Self) usize {
        return self.data.items.len;
    }

    fn deinit(self: *Self) void {
        self.data.deinit(self.allocator);
    }
};

pub const DateTimeArray = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    data: std.ArrayList(c.SQL_TIMESTAMP_STRUCT),

    fn getDatetime(self: *const Self, index: u64) c.SQL_TIMESTAMP_STRUCT {
        return self.data.items[index];
    }

    fn toString(self: *const Self, index: usize, buffer: []u8) ![]u8 {
        const raw = self.data.items[index];
        const slice = try std.fmt.bufPrint(buffer, "{d}-{d:02}-{d:02} {d:02}:{d:02}:{d:02}.{d}", .{ raw.year, raw.month, raw.day, raw.hour, raw.minute, raw.second, raw.fraction });
        return slice;
    }

    fn len(self: *const Self) usize {
        return self.data.items.len;
    }

    fn deinit(self: *Self) void {
        self.data.deinit(self.allocator);
    }
};

pub const TimeArray = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    data: std.ArrayList(c.SQL_TIME_STRUCT),

    fn getDatetime(self: *const Self, index: u64) c.SQL_TIME_STRUCT {
        return self.data.items[index];
    }

    fn toString(self: *const Self, index: usize, buffer: []u8) ![]u8 {
        const raw = self.data.items[index];
        const slice = try std.fmt.bufPrint(buffer, "{d:02}:{d:02}:{d:02}", .{ raw.hour, raw.minute, raw.second });
        return slice;
    }

    fn len(self: *const Self) usize {
        return self.data.items.len;
    }

    fn deinit(self: *Self) void {
        self.data.deinit(self.allocator);
    }
};

pub const StringArray = struct {
    const Self = @This();

    // All bytes for all strings are contiguous, null delimited.
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8),
    offsets: std.ArrayList(usize),

    fn getStringView(self: *const Self, index: u64) String {
        const start_index = self.offsets.items[index];
        var end_index = start_index;

        while (end_index < self.bytes.items.len and self.bytes.items[end_index] != 0) {
            end_index += 1;
        }

        return self.bytes.items[start_index..end_index];
    }

    fn toString(self: *const Self, index: usize, buffer: []u8) ![]u8 {
        const raw = self.getStringView(index);
        const truncated = if (raw.len > buffer.len) raw[0..buffer.len] else raw; // TODO: This could lead to invalid UTF-8 since it splits on bytes

        const slice = try std.fmt.bufPrint(buffer, "{s}", .{truncated});
        return slice;
    }

    fn len(self: *const Self) usize {
        return self.offsets.items.len;
    }

    fn deinit(self: *Self) void {
        self.bytes.deinit(self.allocator);
        self.offsets.deinit(self.allocator);
    }
};

pub const GenericArray = union(enum) {
    booleans: BooleanArray,
    integers: IntegerArray,
    floats: FloatArray,
    strings: StringArray,
    dates: DateArray,
    datetimes: DateTimeArray,
    times: TimeArray,
};

pub const Column = struct {
    name: [COLUMN_NAME_MAX_BYTES]u8, // I want the Column to own this, right? I don't want a slice to random memory
    null_mask: BooleanArray,
    array: GenericArray,

    fn deinit(self: *Column) void {
        self.null_mask.deinit();

        _ = switch (self.array) {
            inline else => |*array| array.deinit(),
        };
    }

    fn getColumnName(self: *const Column) String {
        var end_index: usize = 0;
        for (0..COLUMN_NAME_MAX_BYTES) |byte_index| {
            if (self.name[byte_index] == 0) {
                break;
            }
            end_index += 1;
        }

        return self.name[0..end_index];
    }

    // TODO: This will explode for long strings.
    // TODO: Maybe pass in the buffer from outside? Or have an allocation fallback?
    fn writeAsString(self: *const Column, allocator: std.mem.Allocator, index: usize, buffer: *MutString) !String {
        buffer.clearRetainingCapacity();

        var stack_buffer: [1024]u8 = undefined;

        // If we're null, return NULL
        if (self.isNull(index)) {
            return "<NULL>"; // TODO: Maybe better to provide a sentinel value so HTML vs CSV can render this differently.
        }

        const slice = switch (self.array) {
            inline else => |*array| try array.toString(index, stack_buffer[0..]),
        };

        try buffer.appendSlice(allocator, slice);

        return buffer.items;
    }

    fn isNull(self: *const Column, index: usize) bool {
        if (index < self.null_mask.len()) {
            return self.null_mask.getBoolean(index);
        } else {
            return false;
        }
    }
};

pub const ColumnBuilder = union(enum) {
    boolean: BooleanColumnBuilder,
    integer: IntegerColumnBuilder,
    float: FloatColumnBuilder,
    string: StringColumnBuilder,
    date: DateColumnBuilder,
    datetime: DateTimeColumnBuilder,
    time: TimeColumnBuilder,

    pub fn setName(self: *ColumnBuilder, name: String) void {
        switch (self.*) {
            inline else => |*builder| builder.setName(name),
        }
    }

    pub fn appendNull(self: *ColumnBuilder) !void {
        switch (self.*) {
            inline else => |*builder| try builder.appendNull(),
        }
    }

    pub fn appendNotNullUnchecked(self: *ColumnBuilder, value: *anyopaque) !void {
        switch (self.*) {
            inline else => |*builder| try builder.appendNotNullUnchecked(value),
        }
    }

    pub fn commit(self: *ColumnBuilder) Column {
        return switch (self.*) {
            inline else => |*builder| builder.commit(),
        };
    }
};

// Generic builder for fixed-size primitive types (bool, i64, f64)
// This eliminates code duplication across Boolean, Integer, and Float builders
pub fn PrimitiveColumnBuilder(comptime T: type, comptime array_field: []const u8) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        name: [COLUMN_NAME_MAX_BYTES]u8,
        values: std.ArrayList(T),
        nulls: std.ArrayList(bool),

        pub fn init(allocator: std.mem.Allocator) !Self {
            var name: [COLUMN_NAME_MAX_BYTES]u8 = undefined;
            @memset(&name, 0);

            return Self{
                .allocator = allocator,
                .name = name,
                .values = .empty,
                .nulls = .empty,
            };
        }

        pub fn deinit(self: *Self) void {
            self.values.deinit(self.allocator);
            self.nulls.deinit(self.allocator);
        }

        pub fn setName(self: *Self, name: String) void {
            std.mem.copyForwards(u8, &self.name, name);
        }

        pub fn appendNull(self: *Self) !void {
            try self.values.append(self.allocator, undefined);
            try self.nulls.append(self.allocator, true);
        }

        pub fn appendNotNull(self: *Self, value: T) !void {
            try self.values.append(self.allocator, value);
            try self.nulls.append(self.allocator, false);
        }

        pub fn appendNotNullUnchecked(self: *Self, raw_value: *anyopaque) !void {
            const value: T = @as(*const T, @ptrCast(@alignCast(raw_value))).*;
            try self.values.append(self.allocator, value);
            try self.nulls.append(self.allocator, false);
        }

        pub fn append(self: *Self, maybe_value: ?T) !void {
            if (maybe_value) |value| {
                try self.values.append(self.allocator, value);
                try self.nulls.append(self.allocator, false);
            } else {
                try self.values.append(self.allocator, undefined);
                try self.nulls.append(self.allocator, true);
            }
        }

        pub fn commit(self: *Self) Column {
            // Use comptime to create the appropriate array type
            const TypedArray = switch (T) {
                bool => BooleanArray,
                i64 => IntegerArray,
                f64 => FloatArray,
                c.SQL_DATE_STRUCT => DateArray,
                c.SQL_TIMESTAMP_STRUCT => DateTimeArray,
                c.SQL_TIME_STRUCT => TimeArray,
                else => @compileError("Unsupported type for PrimitiveColumnBuilder"),
            };

            const typed_array = TypedArray{ .allocator = self.allocator, .data = self.values };

            // Use @field to dynamically set the union field at comptime
            const data_array = @unionInit(GenericArray, array_field, typed_array);
            const null_mask = BooleanArray{ .allocator = self.allocator, .data = self.nulls };
            const column = Column{ .name = self.name, .null_mask = null_mask, .array = data_array };

            self.values = .empty;
            self.nulls = .empty;

            return column;
        }
    };
}

// Type aliases for convenience - these provide the same interface as before
pub const BooleanColumnBuilder = PrimitiveColumnBuilder(bool, "booleans");
pub const IntegerColumnBuilder = PrimitiveColumnBuilder(i64, "integers");
pub const FloatColumnBuilder = PrimitiveColumnBuilder(f64, "floats");
pub const DateColumnBuilder = PrimitiveColumnBuilder(c.SQL_DATE_STRUCT, "dates");
pub const DateTimeColumnBuilder = PrimitiveColumnBuilder(c.SQL_TIMESTAMP_STRUCT, "datetimes");
pub const TimeColumnBuilder = PrimitiveColumnBuilder(c.SQL_TIME_STRUCT, "times");

// TODO: Use a hashmap to save space and re-use offsets
pub const StringColumnBuilder = struct {
    allocator: std.mem.Allocator,
    name: [COLUMN_NAME_MAX_BYTES]u8,
    bytes: MutString,
    offsets: std.ArrayList(usize),
    nulls: std.ArrayList(bool),

    pub fn init(allocator: std.mem.Allocator) !StringColumnBuilder {
        var name: [COLUMN_NAME_MAX_BYTES]u8 = undefined;
        @memset(&name, 0);

        const bytes: MutString = .empty;
        const offsets: std.ArrayList(usize) = .empty;
        const nulls: std.ArrayList(bool) = .empty;

        return StringColumnBuilder{ .allocator = allocator, .name = name, .bytes = bytes, .offsets = offsets, .nulls = nulls };
    }

    pub fn setName(self: *StringColumnBuilder, name: String) void {
        std.mem.copyForwards(u8, &self.name, name);
    }

    fn getNextOffset(self: *StringColumnBuilder) usize {
        if (self.bytes.items.len == 0) {
            return 0;
        }

        return self.bytes.items.len;
    }

    pub fn appendNotNull(self: *StringColumnBuilder, value: String) !void {
        try self.offsets.append(self.allocator, self.getNextOffset());

        for (0..value.len) |byte_index| {
            try self.bytes.append(self.allocator, value[byte_index]);
        }
        try self.bytes.append(self.allocator, 0);

        try self.nulls.append(self.allocator, false);
    }

    // Requires a C style null delimited string
    pub fn appendNotNullUnchecked(self: *StringColumnBuilder, value: *anyopaque) !void {
        try self.offsets.append(self.allocator, self.getNextOffset());

        const str: [*:0]const u8 = @ptrCast(value);
        var byte_index: usize = 0;
        while (str[byte_index] != 0) {
            try self.bytes.append(self.allocator, str[byte_index]);
            byte_index += 1;
        }
        try self.bytes.append(self.allocator, 0);

        try self.nulls.append(self.allocator, false);
    }

    pub fn appendNull(self: *StringColumnBuilder) !void {
        try self.offsets.append(self.allocator, self.getNextOffset());
        try self.bytes.append(self.allocator, 0);
        try self.nulls.append(self.allocator, true);
    }

    pub fn append(self: *StringColumnBuilder, maybe_value: ?f64) !void {
        if (maybe_value == null) {
            try self.appendNull();
        } else {
            try self.appendNotNull(maybe_value.?);
        }
    }

    pub fn commit(self: *StringColumnBuilder) Column {
        const string_array = StringArray{ .allocator = self.allocator, .bytes = self.bytes, .offsets = self.offsets }; // TODO: Figure out ownership here
        const data_array = GenericArray{ .strings = string_array };
        const null_mask = BooleanArray{ .allocator = self.allocator, .data = self.nulls };
        const column = Column{ .name = self.name, .null_mask = null_mask, .array = data_array };

        return column;
    }
};

pub const DataSet = struct {
    allocator: ?std.mem.Allocator,
    num_rows: u64,
    columns: std.ArrayList(Column),

    pub fn initFromJson(allocator: std.mem.Allocator, json_spec: String) !DataSet {
        const vague_spec: std.json.Parsed(std.json.Value) = try std.json.parseFromSlice(std.json.Value, allocator, json_spec, .{});
        defer vague_spec.deinit();

        const spec = vague_spec.value.object;

        const spec_data = spec.get("data").?.array;

        var column_list = try std.ArrayList(Column).initCapacity(allocator, 8);

        for (spec_data.items) |column_spec| {
            const column_name = column_spec.object.get("name").?.string;
            const dtype = column_spec.object.get("dtype").?.string;
            const values = column_spec.object.get("values").?.array;

            if (std.mem.eql(u8, dtype, "INTEGER")) {
                var builder = try IntegerColumnBuilder.init(allocator);
                builder.setName(column_name);

                for (values.items) |generic_value| {
                    switch (generic_value) {
                        .integer => |value| {
                            try builder.appendNotNull(value);
                        },
                        .null => {
                            try builder.appendNull();
                        },
                        else => {
                            continue;
                        },
                    }
                }
                const built_column = builder.commit();
                try column_list.append(allocator, built_column);
            } else if (std.mem.eql(u8, dtype, "FLOAT")) {
                var builder = try FloatColumnBuilder.init(allocator);
                builder.setName(column_name);

                for (values.items) |generic_value| {
                    switch (generic_value) {
                        .float => |value| {
                            try builder.appendNotNull(value);
                        },
                        .null => {
                            try builder.appendNull();
                        },
                        else => {
                            continue;
                        },
                    }
                }
                const built_column = builder.commit();
                try column_list.append(allocator, built_column);
            } else if (std.mem.eql(u8, dtype, "BOOLEAN")) {
                var builder = try BooleanColumnBuilder.init(allocator);
                builder.setName(column_name);

                for (values.items) |generic_value| {
                    switch (generic_value) {
                        .bool => |value| {
                            try builder.appendNotNull(value);
                        },
                        .null => {
                            try builder.appendNull();
                        },
                        else => {
                            continue;
                        },
                    }
                }
                const built_column = builder.commit();
                try column_list.append(allocator, built_column);
            } else if (std.mem.eql(u8, dtype, "STRING")) {
                var builder = try StringColumnBuilder.init(allocator);
                builder.setName(column_name);

                // TODO: Maybe add this dispatch to the builder?
                for (values.items) |generic_value| {
                    switch (generic_value) {
                        .string => |value| {
                            try builder.appendNotNull(value);
                        },
                        .null => {
                            try builder.appendNull();
                        },
                        else => {
                            continue; // TODO: stringify, maybe?
                        },
                    }
                }
                const built_column = builder.commit();
                try column_list.append(allocator, built_column);
            } else {
                std.debug.print("Not a bool: {s}", .{dtype});
                continue;
            }
        }

        const dataset = DataSet{ .allocator = allocator, .num_rows = 3, .columns = column_list };

        return dataset;
    }

    pub fn deinit(self: *DataSet) void {
        for (self.columns.items) |*column| {
            column.deinit();
        }
        if (self.allocator) |alloc| {
            self.columns.deinit(alloc);
        }
    }

    pub fn toCsv(self: *const DataSet, allocator: std.mem.Allocator) !String {
        return self.toCsvInner(allocator, std.math.maxInt(usize));
    }

    pub fn toCsvPreview(self: *const DataSet, allocator: std.mem.Allocator, limit: usize) !String {
        return self.toCsvInner(allocator, limit);
    }

    // TODO: There should be a way to stream this to a file without storing all the data in memory
    fn toCsvInner(self: *const DataSet, allocator: std.mem.Allocator, limit: usize) !String {
        // Allocate a bunch of space for the string
        var output = try std.ArrayList(u8).initCapacity(allocator, 1024);

        var work_buffer = try std.ArrayList(u8).initCapacity(allocator, 1024);
        var quote_buffer = try std.ArrayList(u8).initCapacity(allocator, 1024);
        defer work_buffer.deinit(allocator);
        defer quote_buffer.deinit(allocator);

        var is_first_column = true;

        // Iterate through the cols
        var row_count: usize = 0;
        for (self.columns.items) |column| {
            if (row_count > limit) {
                break;
            }

            const raw_column_name = column.getColumnName();

            const column_name = try common.quoteForCsv(allocator, raw_column_name, &quote_buffer);

            if (!is_first_column) {
                try output.append(allocator, ',');
            }
            try output.appendSlice(allocator, column_name);
            is_first_column = false;

            row_count += 1;
        }

        try output.append(allocator, '\n');

        // Iterate through the rows
        for (0..self.num_rows) |row_index| {
            is_first_column = true;

            for (self.columns.items) |column| {
                if (!is_first_column) {
                    try output.append(allocator, ',');
                }
                is_first_column = false;

                const raw_slice = try column.writeAsString(allocator, row_index, &work_buffer);
                const slice = try common.quoteForCsv(allocator, raw_slice, &quote_buffer);

                try output.appendSlice(allocator, slice);
            }
            try output.append(allocator, '\n');
        }

        return output.toOwnedSlice(allocator);
    }

    pub fn toHtmlTable(self: *DataSet, allocator: std.mem.Allocator) !String {
        // Allocate a bunch of space for the string
        var output = try MutString.initCapacity(allocator, 1024);

        var work_buffer = try MutString.initCapacity(allocator, 1024);
        var escape_buffer = try MutString.initCapacity(allocator, 1024);

        try output.appendSlice(allocator, "<table>\n<thead>\n<tr>");

        // Iterate through the cols to write thead
        for (self.columns.items) |column| {
            const raw_column_name = column.getColumnName();
            const column_name = try common.escapeHtml(allocator, raw_column_name, &escape_buffer);

            try output.appendSlice(allocator, "\n<th>");
            try output.appendSlice(allocator, column_name);
            try output.appendSlice(allocator, "</th>");
        }

        try output.appendSlice(allocator, "\n</tr>\n</thead>\n</tbody>");

        // Iterate through the rows
        for (0..self.num_rows) |row_index| {
            try output.appendSlice(allocator, "\n<tr>");

            for (self.columns.items) |column| {
                const raw_slice = try column.writeAsString(row_index, &work_buffer);
                const slice = try common.escapeHtml(allocator, raw_slice, &escape_buffer);

                try output.appendSlice(allocator, "\n<td>");
                try output.appendSlice(allocator, slice);
                try output.appendSlice(allocator, "</td>");
            }
            try output.appendSlice(allocator, "\n</tr>");
        }

        try output.appendSlice(allocator, "\n</tbody>\n</table>\n");
        // try output.append(0);

        return output.toOwnedSlice();
    }
};

pub const NullDataset = DataSet{
    .allocator = null,
    .num_rows = 0,
    .columns = .empty,
};
