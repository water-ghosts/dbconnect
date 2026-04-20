const std = @import("std");
const common = @import("common.zig");
const datastores = @import("datastores.zig");

const c = @cImport({
    @cInclude("../include/sql.h");
    @cInclude("../include/sqlext.h");
    @cInclude("../include/sqltypes.h");
    @cInclude("stdio.h");
    @cInclude("string.h");
});

const BIND_BUFFER_LENGTH = 4096;

const DatabaseError = error{
    GeneralError,
};

const RawColumnData = struct {
    column_id: c.SQLUSMALLINT,
    column_name: [1024]u8,
    name_length: c.SQLSMALLINT,
    data_type: c.SQLSMALLINT,
    column_size: c.SQLULEN,
    decimal_digits: c.SQLSMALLINT,
    nullable: c.SQLSMALLINT,
};

const ValueBuffer = union(enum) {
    boolean: c.u_int8_t,
    integer: i64,
    float: f64,
    string: [4096]u8,
    date: c.SQL_DATE_STRUCT,
    datetime: c.SQL_TIMESTAMP_STRUCT,
    time: c.TIME_STRUCT,
};

const ColumnFeeder = struct {
    const Self = @This();

    value: ValueBuffer,
    indicator: c.SQLLEN,
    column_id: c.SQLUSMALLINT,
    builder: *datastores.ColumnBuilder,

    pub fn getValuePointer(self: *Self) *anyopaque {
        return &self.value;
    }

    pub fn getIndicatorPointer(self: *Self) *c.SQLLEN {
        return &self.indicator;
    }

    pub fn getColumnId(self: *Self) *c.SQLUSMALLINT {
        return self.column_id;
    }

    pub fn commitFetch(self: *Self) !void {
        if (self.indicator == c.SQL_NULL_DATA) {
            try self.builder.appendNull();
        } else {
            const opaque_value: *anyopaque = @ptrCast(&self.value);
            try self.builder.appendNotNullUnchecked(opaque_value);
        }
    }

    fn getTargetType(self: *ColumnFeeder) c_short {
        const target_type = switch (self.value) {
            .boolean => c.SQL_C_BIT,
            .integer => c.SQL_C_LONG,
            .float => c.SQL_C_DOUBLE,
            .string => c.SQL_C_CHAR,
            .date => c.SQL_C_DATE,
            .datetime => c.SQL_C_TIMESTAMP,
            .time => c.SQL_C_TIME,
        };

        return @intCast(target_type);
    }
};

const BuildersAndFeeders = struct {
    builders: std.ArrayList(datastores.ColumnBuilder),
    feeders: std.ArrayList(ColumnFeeder),
};

pub const DatabaseConnection = struct {
    environment_handle: c.SQLHENV,
    connection_handle: c.SQLHDBC,

    pub fn init(allocator: std.mem.Allocator, connection_string: common.String) !DatabaseConnection {
        var environment_handle: c.SQLHENV = undefined;
        var connection_handle: c.SQLHDBC = undefined;
        var sql_response: c.SQLRETURN = undefined;

        const raw_connection_string_output = std.mem.zeroes([1024]u8);
        var connection_string_output_length: c.SQLSMALLINT = 1024;

        sql_response = c.SQLAllocHandle(c.SQL_HANDLE_ENV, null, &environment_handle);
        if (!c.SQL_SUCCEEDED(sql_response)) {
            _ = c.printf("Failed to allocate ODBC environment handle (return code: %d)\n", sql_response);
            return error.GeneralError;
        }

        sql_response = c.SQLSetEnvAttr(environment_handle, c.SQL_ATTR_ODBC_VERSION, @ptrFromInt(c.SQL_OV_ODBC3), 0);
        if (!c.SQL_SUCCEEDED(sql_response)) {
            _ = c.printf("Failed to set ODBC version attribute (return code: %d)\n", sql_response);
            printODBCDiagnostics(c.SQL_HANDLE_ENV, environment_handle);
            return error.GeneralError;
        }

        sql_response = c.SQLAllocHandle(c.SQL_HANDLE_DBC, environment_handle, &connection_handle);
        if (!c.SQL_SUCCEEDED(sql_response)) {
            _ = c.printf("Failed to allocate ODBC connection handle (return code: %d)\n", sql_response);
            printODBCDiagnostics(c.SQL_HANDLE_ENV, environment_handle);
            return error.GeneralError;
        }

        const c_connection_string = try allocator.dupeZ(u8, connection_string);
        defer allocator.free(c_connection_string);

        const connection_string_output = try allocator.dupeZ(u8, &raw_connection_string_output);
        defer allocator.free(connection_string_output);

        sql_response = c.SQLDriverConnect(connection_handle, null, c_connection_string, c.SQL_NTS, connection_string_output, 1024, &connection_string_output_length, c.SQL_DRIVER_COMPLETE);

        if (!c.SQL_SUCCEEDED(sql_response)) {
            _ = c.printf("SQLDriverConnect failed (return code: %d)\n", sql_response);
            printODBCDiagnostics(c.SQL_HANDLE_DBC, connection_handle);
            return error.GeneralError;
        }

        return DatabaseConnection{
            .environment_handle = environment_handle,
            .connection_handle = connection_handle,
        };
    }

    pub fn deinit(self: *DatabaseConnection) void {
        _ = c.SQLFreeHandle(c.SQL_HANDLE_DBC, self.connection_handle);
        _ = c.SQLFreeHandle(c.SQL_HANDLE_ENV, self.environment_handle);
    }
};

fn bufferToString(buffer: *const u8, max_length: usize) common.String {
    var position: usize = 0;
    const c_buffer: common.CString = @ptrCast(buffer);

    while (position < max_length) {
        if (c_buffer[position] == 0) {
            break;
        }
        position += 1;
    }

    return c_buffer[0 .. position + 1];
}

fn printODBCDiagnostics(handle_type: c.SQLSMALLINT, handle: c.SQLHANDLE) void {
    var record_index: c.SQLSMALLINT = 1;
    var sql_state: [6]u8 = undefined;
    var native_error: c.SQLINTEGER = undefined;
    var message_text: [1024]u8 = undefined;
    var text_length: c.SQLSMALLINT = undefined;

    _ = c.printf("ODBC Error Details:\n");

    while (true) {
        const result = c.SQLGetDiagRec(
            handle_type,
            handle,
            record_index,
            &sql_state,
            &native_error,
            &message_text,
            1024,
            &text_length,
        );

        if (!c.SQL_SUCCEEDED(result)) {
            break;
        }

        _ = c.printf("  [%s] (%d) %s\n", &sql_state, native_error, &message_text);
        record_index += 1;
    }
}

fn getColumnData(allocator: std.mem.Allocator, statement_handle: c.SQLHSTMT) !std.ArrayList(RawColumnData) {

    // Get data on how many columns there were
    var num_columns: c.SQLSMALLINT = 0;
    _ = c.SQLNumResultCols(statement_handle, &num_columns);

    var columns = try std.ArrayList(RawColumnData).initCapacity(allocator, @intCast(num_columns));

    // Describe each column
    for (1..@intCast(num_columns + 1)) |column_index| {
        const column_id: c.SQLUSMALLINT = @intCast(column_index);

        var raw_data: RawColumnData = undefined;
        raw_data.column_id = column_id;

        // This will populate the remaining fields of the column data
        _ = c.SQLDescribeCol(
            statement_handle,
            column_id,
            &raw_data.column_name,
            1024,
            &raw_data.name_length,
            &raw_data.data_type,
            &raw_data.column_size,
            &raw_data.decimal_digits,
            &raw_data.nullable,
        );

        try columns.append(allocator, raw_data);
    }

    return columns;
}

fn createBuildersAndFeeders(
    allocator: std.mem.Allocator,
    column_data: std.ArrayList(RawColumnData),
) !BuildersAndFeeders {
    var builders = try std.ArrayList(datastores.ColumnBuilder).initCapacity(allocator, column_data.items.len);
    errdefer builders.deinit(allocator);

    var feeders = try std.ArrayList(ColumnFeeder).initCapacity(allocator, column_data.items.len);
    errdefer feeders.deinit(allocator);

    for (column_data.items) |column| {
        _ = c.printf("Column datatype: %d, digits: %d\n", column.data_type, column.decimal_digits);

        var value_buffer: ValueBuffer = undefined;
        var builder: datastores.ColumnBuilder = undefined;

        switch (column.data_type) {
            c.SQL_NUMERIC, c.SQL_DECIMAL, c.SQL_INTEGER, c.SQL_FLOAT, c.SQL_DOUBLE => {
                const use_float = (column.data_type == c.SQL_FLOAT or column.data_type == c.SQL_DOUBLE or column.decimal_digits > 0);

                if (use_float) {
                    const raw_builder = try datastores.FloatColumnBuilder.init(allocator);
                    builder = datastores.ColumnBuilder{ .float = raw_builder };
                    value_buffer = ValueBuffer{ .float = undefined };
                } else {
                    const raw_builder = try datastores.IntegerColumnBuilder.init(allocator);
                    builder = datastores.ColumnBuilder{ .integer = raw_builder };
                    value_buffer = ValueBuffer{ .integer = undefined };
                }
            },
            c.SQL_BIT => {
                const raw_builder = try datastores.BooleanColumnBuilder.init(allocator);
                builder = datastores.ColumnBuilder{ .boolean = raw_builder };
                value_buffer = ValueBuffer{ .boolean = undefined };
            },
            c.SQL_VARCHAR => {
                const raw_builder = try datastores.StringColumnBuilder.init(allocator);
                builder = datastores.ColumnBuilder{ .string = raw_builder };
                value_buffer = ValueBuffer{ .string = undefined };
            },
            c.SQL_TYPE_DATE => {
                const raw_builder = try datastores.DateColumnBuilder.init(allocator);
                builder = datastores.ColumnBuilder{ .date = raw_builder };
                value_buffer = ValueBuffer{ .date = undefined };
            },
            c.SQL_TYPE_TIMESTAMP => {
                const raw_builder = try datastores.DateTimeColumnBuilder.init(allocator);
                builder = datastores.ColumnBuilder{ .datetime = raw_builder };
                value_buffer = ValueBuffer{ .datetime = undefined };
            },
            c.SQL_TYPE_TIME => {
                const raw_builder = try datastores.TimeColumnBuilder.init(allocator);
                builder = datastores.ColumnBuilder{ .time = raw_builder };
                value_buffer = ValueBuffer{ .time = undefined };
            },
            else => {
                _ = c.printf("Unsupported data type: %d\n", column.data_type);
                return DatabaseError.GeneralError;
            },
        }

        try builders.append(allocator, builder);
        const builder_ptr = &builders.items[builders.items.len - 1];

        builder_ptr.setName(column.column_name[0..256]);

        const feeder = ColumnFeeder{ .builder = builder_ptr, .indicator = undefined, .value = value_buffer, .column_id = column.column_id };

        try feeders.append(allocator, feeder);
    }

    return BuildersAndFeeders{
        .builders = builders,
        .feeders = feeders,
    };
}

pub fn executeQuery(allocator: std.mem.Allocator, connection: DatabaseConnection, query: []const u8) !datastores.DataSet {
    // Initialize Statement Handle
    var statement_handle: c.SQLHSTMT = null;
    _ = c.SQLAllocHandle(c.SQL_HANDLE_STMT, connection.connection_handle, &statement_handle);
    defer _ = c.SQLFreeHandle(c.SQL_HANDLE_STMT, statement_handle);

    // Run the query
    const real_query = try allocator.dupeZ(u8, query);
    defer allocator.free(real_query);
    const execution_result = c.SQLExecDirect(statement_handle, real_query, c.SQL_NTS);

    if (!c.SQL_SUCCEEDED(execution_result)) {
        printODBCDiagnostics(c.SQL_HANDLE_STMT, statement_handle);
        return DatabaseError.GeneralError;
    }

    // Get data on columns
    var column_data = try getColumnData(allocator, statement_handle);
    defer column_data.deinit(allocator);

    // Create builders and feeders
    var builders_and_feeders = try createBuildersAndFeeders(allocator, column_data);
    defer builders_and_feeders.builders.deinit(allocator);
    defer builders_and_feeders.feeders.deinit(allocator);

    // Bind feeders to ODBC
    for (builders_and_feeders.feeders.items) |*feeder| {
        const value_pointer = feeder.getValuePointer();
        const indicator_pointer = feeder.getIndicatorPointer();
        const c_target_type = feeder.getTargetType();

        _ = c.SQLBindCol(statement_handle, feeder.column_id, c_target_type, value_pointer, BIND_BUFFER_LENGTH, indicator_pointer);
    }

    var num_rows: usize = 0;

    // For each row, ODBC writes to feeder buffers, then feeders push to builders
    while (c.SQL_SUCCEEDED(c.SQLFetch(statement_handle))) {
        num_rows += 1;

        for (builders_and_feeders.feeders.items) |*feeder| {

            // TODO: If indicator > buffer size, then fall back to SQLGetValue

            try feeder.commitFetch();
        }
    }

    // Commit builders to create final immutable columns
    var columns = try std.ArrayList(datastores.Column).initCapacity(allocator, column_data.items.len);
    for (builders_and_feeders.builders.items) |*builder| {
        const new_column = builder.commit();
        try columns.append(allocator, new_column);
    }

    const dataset = datastores.DataSet{ .allocator = allocator, .num_rows = num_rows, .columns = columns };

    _ = c.printf("Data loaded!\n");
    return dataset;
}
