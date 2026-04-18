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
    nullMask: BooleanArray,
    array: GenericArray,

    fn deinit(self: *Column) void {
        self.nullMask.deinit();

        _ = switch (self.array) {
            inline else => |*array| array.deinit(),
        };
    }

    // fn getBoolean(self: *Column, index: u64) ?bool {
    //     const value = switch (self.array) {
    //         .booleans => |*bools| bools.getBoolean(index),
    //         else => false,
    //     };

    //     return value;
    // }

    // fn getInteger(self: *Column, index: u64) ?i64 {
    //     const value = switch (self.array) {
    //         .integers => |*ints| ints.getInteger(index),
    //         else => -999,
    //     };

    //     return value;
    // }

    // fn getFloat(self: *Column, index: u64) ?f64 {
    //     const value = switch (self.array) {
    //         .floats => |*floats| floats.getFloat(index),
    //         else => -9.9,
    //     };

    //     return value;
    // }

    // fn getString(self: *Column, index: u64) ?String {
    //     const value = switch (self.array) {
    //         .strings => |*strings| strings.getStringView(index),
    //         else => "<ERROR>",
    //     };

    //     return value;
    // }

    fn getColumnName(self: *const Column) String {
        var endIndex: usize = 0;
        for (0..COLUMN_NAME_MAX_BYTES) |i| {
            if (self.name[i] == 0) {
                break;
            }
            endIndex += 1;
        }

        return self.name[0..endIndex];
    }

    // TODO: This will explode for long strings.
    // TODO: Maybe pass in the buffer from outside? Or have an allocation fallback?
    fn writeAsString(self: *const Column, allocator: std.mem.Allocator, index: usize, buffer: *MutString) !String {
        buffer.clearRetainingCapacity();

        var stackBuffer: [1024]u8 = undefined;

        // If we're null, return NULL
        if (self.isNull(index)) {
            return "<NULL>"; // TODO: Maybe better to provide a sentinel value so HTML vs CSV can render this differently.
        }

        const slice = switch (self.array) {
            inline else => |*array| try array.toString(index, stackBuffer[0..]),
            // .dates => |array| try std.fmt.bufPrint(&stackBuffer, "{s}", .{array.getStringView(index)}),
        };

        try buffer.appendSlice(allocator, slice);

        return buffer.items;
    }

    fn isNull(self: *const Column, index: usize) bool {
        if (index < self.nullMask.len()) {
            return self.nullMask.getBoolean(index);
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

        pub fn append(self: *Self, maybeValue: ?T) !void {
            if (maybeValue) |value| {
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

            const typedArray = TypedArray{ .allocator = self.allocator, .data = self.values };

            // Use @field to dynamically set the union field at comptime
            const dataArray = @unionInit(GenericArray, array_field, typedArray);
            const nullMask = BooleanArray{ .allocator = self.allocator, .data = self.nulls };
            const col = Column{ .name = self.name, .nullMask = nullMask, .array = dataArray };

            self.values = .empty;
            self.nulls = .empty;

            return col;
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

        for (0..value.len) |i| {
            try self.bytes.append(self.allocator, value[i]);
        }
        try self.bytes.append(self.allocator, 0);

        try self.nulls.append(self.allocator, false);
    }

    // Requires a C style null delimited string
    pub fn appendNotNullUnchecked(self: *StringColumnBuilder, value: *anyopaque) !void {
        try self.offsets.append(self.allocator, self.getNextOffset());

        const str: [*:0]const u8 = @ptrCast(value);
        var i: usize = 0;
        while (str[i] != 0) {
            try self.bytes.append(self.allocator, str[i]);
            i += 1;
        }
        try self.bytes.append(self.allocator, 0);

        try self.nulls.append(self.allocator, false);
    }

    pub fn appendNull(self: *StringColumnBuilder) !void {
        try self.offsets.append(self.allocator, self.getNextOffset());
        try self.bytes.append(self.allocator, 0);
        try self.nulls.append(self.allocator, true);
    }

    pub fn append(self: *StringColumnBuilder, maybeValue: ?f64) !void {
        if (maybeValue == null) {
            try self.appendNull();
        } else {
            try self.appendNotNull(maybeValue.?);
        }
    }

    pub fn commit(self: *StringColumnBuilder) Column {
        const stringArray = StringArray{ .allocator = self.allocator, .bytes = self.bytes, .offsets = self.offsets }; // TODO: Figure out ownership here
        const dataArray = GenericArray{ .strings = stringArray };
        const nullMask = BooleanArray{ .allocator = self.allocator, .data = self.nulls };
        const col = Column{ .name = self.name, .nullMask = nullMask, .array = dataArray };

        return col;
    }
};

pub const DataSet = struct {
    allocator: ?std.mem.Allocator,
    numRows: u64,
    columns: std.ArrayList(Column),

    pub fn initFromJson(allocator: std.mem.Allocator, jsonSpec: String) !DataSet {
        const vagueSpec: std.json.Parsed(std.json.Value) = try std.json.parseFromSlice(std.json.Value, allocator, jsonSpec, .{});
        defer vagueSpec.deinit();

        const spec = vagueSpec.value.object;

        // const specData: std.array_list.AlignedManaged(std.json.Value) = spec.get("data").?.array;
        const specData = spec.get("data").?.array;

        var columnList = try std.ArrayList(Column).initCapacity(allocator, 8);

        for (specData.items) |col| {
            const colName = col.object.get("name").?.string;
            const dtype = col.object.get("dtype").?.string;
            const values = col.object.get("values").?.array;

            if (std.mem.eql(u8, dtype, "INTEGER")) {
                var builder = try IntegerColumnBuilder.init(allocator);
                builder.setName(colName);

                for (values.items) |genericValue| {
                    switch (genericValue) {
                        .integer => |value| {
                            try builder.appendNotNull(value);
                        },
                        .null => {
                            try builder.appendNull();
                        },
                        else => {
                            // std.debug.print("Not an integer: {}", .{genericValue});
                            continue;
                        },
                    }
                }
                const builtColumn = builder.commit();
                try columnList.append(allocator, builtColumn);
            } else if (std.mem.eql(u8, dtype, "FLOAT")) {
                var builder = try FloatColumnBuilder.init(allocator);
                builder.setName(colName);

                for (values.items) |genericValue| {
                    switch (genericValue) {
                        .float => |value| {
                            try builder.appendNotNull(value);
                        },
                        .null => {
                            try builder.appendNull();
                        },
                        else => {
                            // std.debug.print("Not an integer: {}", .{genericValue});
                            continue;
                        },
                    }
                }
                const builtColumn = builder.commit();
                try columnList.append(allocator, builtColumn);
            } else if (std.mem.eql(u8, dtype, "BOOLEAN")) {
                var builder = try BooleanColumnBuilder.init(allocator);
                builder.setName(colName);

                for (values.items) |genericValue| {
                    switch (genericValue) {
                        .bool => |value| {
                            try builder.appendNotNull(value);
                        },
                        .null => {
                            try builder.appendNull();
                        },
                        else => {
                            // std.debug.print("Not an integer: {}", .{genericValue});
                            continue;
                        },
                    }
                }
                const builtColumn = builder.commit();
                try columnList.append(allocator, builtColumn);
            } else if (std.mem.eql(u8, dtype, "STRING")) {
                var builder = try StringColumnBuilder.init(allocator);
                builder.setName(colName);

                // TODO: Maybe add this dispatch to the builder?
                for (values.items) |genericValue| {
                    switch (genericValue) {
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
                const builtColumn = builder.commit();
                try columnList.append(allocator, builtColumn);
            } else {
                std.debug.print("Not a bool: {s}", .{dtype});
                continue;
            }
        }

        const dataset = DataSet{ .allocator = allocator, .numRows = 3, .columns = columnList };

        return dataset;
    }

    pub fn deinit(self: *DataSet) void {
        for (self.columns.items) |*col| {
            col.deinit();
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

        var workBuffer = try std.ArrayList(u8).initCapacity(allocator, 1024);
        var quoteBuffer = try std.ArrayList(u8).initCapacity(allocator, 1024);
        defer workBuffer.deinit(allocator);
        defer quoteBuffer.deinit(allocator);

        var isFirstColumn = true;

        // Iterate through the cols
        var row_count: usize = 0;
        for (self.columns.items) |col| {
            if (row_count > limit) {
                break;
            }

            const rawColName = col.getColumnName();

            const colName = try common.quoteForCsv(allocator, rawColName, &quoteBuffer);

            if (!isFirstColumn) {
                try output.append(allocator, ',');
            }
            try output.appendSlice(allocator, colName);
            isFirstColumn = false;

            row_count += 1;
        }

        try output.append(allocator, '\n');

        // Iterate through the rows
        for (0..self.numRows) |rowIndex| {
            isFirstColumn = true;

            for (self.columns.items) |col| {
                if (!isFirstColumn) {
                    try output.append(allocator, ',');
                }
                isFirstColumn = false;

                const rawSlice = try col.writeAsString(allocator, rowIndex, &workBuffer);
                const slice = try common.quoteForCsv(allocator, rawSlice, &quoteBuffer);

                try output.appendSlice(allocator, slice);
            }
            try output.append(allocator, '\n');
        }

        return output.toOwnedSlice(allocator);
    }

    pub fn toHtmlTable(self: *DataSet, allocator: std.mem.Allocator) !String {
        // Allocate a bunch of space for the string
        var output = try MutString.initCapacity(allocator, 1024);

        var workBuffer = try MutString.initCapacity(allocator, 1024);
        var escapeBuffer = try MutString.initCapacity(allocator, 1024);

        try output.appendSlice(allocator, "<table>\n<thead>\n<tr>");

        // Iterate through the cols to write thead
        for (self.columns.items) |col| {
            const rawColName = col.getColumnName();
            const colName = try common.escapeHtml(allocator, rawColName, &escapeBuffer);

            try output.appendSlice(allocator, "\n<th>");
            try output.appendSlice(allocator, colName);
            try output.appendSlice(allocator, "</th>");
        }

        try output.appendSlice(allocator, "\n</tr>\n</thead>\n</tbody>");

        // Iterate through the rows
        for (0..self.numRows) |rowIndex| {
            try output.appendSlice(allocator, "\n<tr>");

            for (self.columns.items) |col| {
                const rawSlice = try col.writeAsString(rowIndex, &workBuffer);
                const slice = try common.escapeHtml(allocator, rawSlice, &escapeBuffer);

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
    .numRows = 0,
    .columns = .empty,
};
