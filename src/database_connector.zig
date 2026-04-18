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
    columnId: c.SQLUSMALLINT,
    columnName: [1024]u8,
    nameLength: c.SQLSMALLINT,
    dataType: c.SQLSMALLINT,
    columnSize: c.SQLULEN,
    decimalDigits: c.SQLSMALLINT,
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
    columnId: c.SQLUSMALLINT,
    builder: *datastores.ColumnBuilder,

    pub fn getValuePointer(self: *Self) *anyopaque {
        return &self.value;
    }

    pub fn getIndicatorPointer(self: *Self) *c.SQLLEN {
        return &self.indicator;
    }

    pub fn getColumnId(self: *Self) *c.SQLUSMALLINT {
        return self.columnId;
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
    environmentHandle: c.SQLHENV,
    connectionHandle: c.SQLHDBC,

    pub fn init(allocator: std.mem.Allocator, connection_string: common.String) !DatabaseConnection {
        var environmentHandle: c.SQLHENV = undefined;
        var connectionHandle: c.SQLHDBC = undefined;
        var sql_response: c.SQLRETURN = undefined;

        const raw_connection_string_output = std.mem.zeroes([1024]u8);
        var connection_string_output_length: c.SQLSMALLINT = 1024;

        sql_response = c.SQLAllocHandle(c.SQL_HANDLE_ENV, null, &environmentHandle);
        if (!c.SQL_SUCCEEDED(sql_response)) {
            _ = c.printf("Failed to allocate ODBC environment handle (return code: %d)\n", sql_response);
            return error.GeneralError;
        }

        sql_response = c.SQLSetEnvAttr(environmentHandle, c.SQL_ATTR_ODBC_VERSION, @ptrFromInt(c.SQL_OV_ODBC3), 0);
        if (!c.SQL_SUCCEEDED(sql_response)) {
            _ = c.printf("Failed to set ODBC version attribute (return code: %d)\n", sql_response);
            printODBCDiagnostics(c.SQL_HANDLE_ENV, environmentHandle);
            return error.GeneralError;
        }

        sql_response = c.SQLAllocHandle(c.SQL_HANDLE_DBC, environmentHandle, &connectionHandle);
        if (!c.SQL_SUCCEEDED(sql_response)) {
            _ = c.printf("Failed to allocate ODBC connection handle (return code: %d)\n", sql_response);
            printODBCDiagnostics(c.SQL_HANDLE_ENV, environmentHandle);
            return error.GeneralError;
        }

        const c_connection_string = try allocator.dupeZ(u8, connection_string);
        defer allocator.free(c_connection_string);

        const connection_string_output = try allocator.dupeZ(u8, &raw_connection_string_output);
        defer allocator.free(connection_string_output);

        sql_response = c.SQLDriverConnect(connectionHandle, null, c_connection_string, c.SQL_NTS, connection_string_output, 1024, &connection_string_output_length, c.SQL_DRIVER_COMPLETE);

        if (!c.SQL_SUCCEEDED(sql_response)) {
            _ = c.printf("SQLDriverConnect failed (return code: %d)\n", sql_response);
            printODBCDiagnostics(c.SQL_HANDLE_DBC, connectionHandle);
            return error.GeneralError;
        }

        return DatabaseConnection{
            .environmentHandle = environmentHandle,
            .connectionHandle = connectionHandle,
        };
    }

    pub fn deinit(self: *DatabaseConnection) void {
        _ = c.SQLFreeHandle(c.SQL_HANDLE_DBC, self.connectionHandle);
        _ = c.SQLFreeHandle(c.SQL_HANDLE_ENV, self.environmentHandle);
    }
};

fn bufferToString(buf: *const u8, max_length: usize) common.String {
    var i: usize = 0;
    const cBuffer: common.CString = @ptrCast(buf);

    while (i < max_length) {
        if (cBuffer[i] == 0) {
            break;
        }
        i += 1;
    }

    return cBuffer[0 .. i + 1];
}

fn printODBCDiagnostics(handleType: c.SQLSMALLINT, handle: c.SQLHANDLE) void {
    var i: c.SQLSMALLINT = 1;
    var sqlState: [6]u8 = undefined;
    var nativeError: c.SQLINTEGER = undefined;
    var messageText: [1024]u8 = undefined;
    var textLength: c.SQLSMALLINT = undefined;

    _ = c.printf("ODBC Error Details:\n");

    while (true) {
        const result = c.SQLGetDiagRec(
            handleType,
            handle,
            i,
            &sqlState,
            &nativeError,
            &messageText,
            1024,
            &textLength,
        );

        if (!c.SQL_SUCCEEDED(result)) {
            break;
        }

        _ = c.printf("  [%s] (%d) %s\n", &sqlState, nativeError, &messageText);
        i += 1;
    }
}

fn getColumnData(allocator: std.mem.Allocator, statementHandle: c.SQLHSTMT) !std.ArrayList(RawColumnData) {

    // Get data on how many columns there were
    var num_columns: c.SQLSMALLINT = 0;
    _ = c.SQLNumResultCols(statementHandle, &num_columns);

    var columns = try std.ArrayList(RawColumnData).initCapacity(allocator, @intCast(num_columns));

    // Describe each column
    for (1..@intCast(num_columns + 1)) |col| {
        const columnId: c.SQLUSMALLINT = @intCast(col);

        var raw_data: RawColumnData = undefined;
        raw_data.columnId = columnId;

        // This will populate the remaining fields of the column data
        _ = c.SQLDescribeCol(
            statementHandle,
            columnId,
            &raw_data.columnName,
            1024,
            &raw_data.nameLength,
            &raw_data.dataType,
            &raw_data.columnSize,
            &raw_data.decimalDigits,
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

    for (column_data.items) |col| {
        _ = c.printf("Column datatype: %d, digits: %d\n", col.dataType, col.decimalDigits);

        var value_buffer: ValueBuffer = undefined;
        var builder: datastores.ColumnBuilder = undefined;

        switch (col.dataType) {
            c.SQL_NUMERIC, c.SQL_DECIMAL, c.SQL_INTEGER, c.SQL_FLOAT, c.SQL_DOUBLE => {
                const use_float = (col.dataType == c.SQL_FLOAT or col.dataType == c.SQL_DOUBLE or col.decimalDigits > 0);

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
                _ = c.printf("Unsupported data type: %d\n", col.dataType);
                return DatabaseError.GeneralError;
            },
        }

        try builders.append(allocator, builder);
        const builder_ptr = &builders.items[builders.items.len - 1];

        builder_ptr.setName(col.columnName[0..256]);

        const feeder = ColumnFeeder{ .builder = builder_ptr, .indicator = undefined, .value = value_buffer, .columnId = col.columnId };

        try feeders.append(allocator, feeder);
    }

    return BuildersAndFeeders{
        .builders = builders,
        .feeders = feeders,
    };
}

pub fn executeQuery(allocator: std.mem.Allocator, connection: DatabaseConnection, query: []const u8) !datastores.DataSet {
    // Initialize Statement Handle
    var statementHandle: c.SQLHSTMT = null;
    _ = c.SQLAllocHandle(c.SQL_HANDLE_STMT, connection.connectionHandle, &statementHandle);
    defer _ = c.SQLFreeHandle(c.SQL_HANDLE_STMT, statementHandle);

    // Run the query
    const real_query = try allocator.dupeZ(u8, query);
    defer allocator.free(real_query);
    const execution_result = c.SQLExecDirect(statementHandle, real_query, c.SQL_NTS);

    if (!c.SQL_SUCCEEDED(execution_result)) {
        printODBCDiagnostics(c.SQL_HANDLE_STMT, statementHandle);
        return DatabaseError.GeneralError;
    }

    // Get data on columns
    var column_data = try getColumnData(allocator, statementHandle);
    defer column_data.deinit(allocator);

    // Create builders and feeders
    var bf = try createBuildersAndFeeders(allocator, column_data);
    defer bf.builders.deinit(allocator);
    defer bf.feeders.deinit(allocator);

    // Bind feeders to ODBC
    for (bf.feeders.items) |*feeder| {
        const value_pointer = feeder.getValuePointer();
        const indicator_pointer = feeder.getIndicatorPointer();
        const c_target_type = feeder.getTargetType();

        _ = c.SQLBindCol(statementHandle, feeder.columnId, c_target_type, value_pointer, BIND_BUFFER_LENGTH, indicator_pointer);
    }

    var num_rows: usize = 0;

    // For each row, ODBC writes to feeder buffers, then feeders push to builders
    while (c.SQL_SUCCEEDED(c.SQLFetch(statementHandle))) {
        num_rows += 1;

        for (bf.feeders.items) |*feeder| {

            // TODO: If indicator > buffer size, then fall back to SQLGetValue

            try feeder.commitFetch();
        }
    }

    // Commit builders to create final immutable columns
    var columns = try std.ArrayList(datastores.Column).initCapacity(allocator, column_data.items.len);
    for (bf.builders.items) |*builder| {
        const new_col = builder.commit();
        try columns.append(allocator, new_col);
    }

    const the_data = datastores.DataSet{ .allocator = allocator, .numRows = num_rows, .columns = columns };

    _ = c.printf("Data loaded!\n");
    return the_data;
}
