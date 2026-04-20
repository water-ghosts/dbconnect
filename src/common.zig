const std = @import("std");

pub const String = []const u8;
pub const CString = [:0]const u8;
pub const MutString = std.ArrayList(u8);

pub const ResizableBuffer = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
    capacity: usize,
    length: usize,

    pub fn init(allocator: std.mem.Allocator, size: usize) !ResizableBuffer {
        const bytes = try allocator.alloc(u8, size);

        return ResizableBuffer{
            .allocator = allocator,
            .bytes = bytes,
            .capacity = size,
            .length = 0,
        };
    }

    pub fn deinit(self: *ResizableBuffer) void {
        self.allocator.free(self.bytes);
        self.capacity = 0;
        self.length = 0;
    }

    fn getNewCapacity(self: *ResizableBuffer) usize {
        const proposed_capacity_growth = self.capacity; // Default to doubling

        // Not sure if this matters but prevent small or gigantic growth
        const actual_growth = if (proposed_capacity_growth < 1024)
            1024
        else if (proposed_capacity_growth > 65536)
            65536
        else
            proposed_capacity_growth;

        return self.capacity + actual_growth;
    }

    fn grow(self: *ResizableBuffer) !void {
        const new_capacity = self.getNewCapacity();

        self.bytes = try self.allocator.realloc(self.bytes, new_capacity);
        self.capacity = new_capacity;
    }

    pub fn clear(self: *ResizableBuffer) void {
        self.length = 0;
    }

    pub fn readVolatile(self: *ResizableBuffer) String {
        return self.bytes[0..self.length];
    }

    // TODO: Helper function to ensure 0 delimiter
    // pub fn toCString(self: *Vec) String {}

    pub fn append(self: *ResizableBuffer, byte: u8) void {
        if (self.length >= self.capacity) {
            self.grow() catch {
                return;
            };
        }

        self.bytes[self.length] = byte;
        self.length += 1;
    }

    pub fn appendSlice(self: *ResizableBuffer, bytes: String) void {
        for (bytes) |b| {
            self.append(b);
        }
    }
};

pub fn stringsMatch(first: String, second: String) bool {
    return std.mem.eql(u8, first, second);
}

// TODO: Clean this up. If you pass a new allocator there's no way to know which one to use for deinit.
pub fn quoteForCsv(allocator: std.mem.Allocator, input: String, buffer: *MutString) !String {
    buffer.clearRetainingCapacity();
    try buffer.append(allocator, '"');

    var requires_quote = false;

    for (input) |char| {
        if (char == ',') {
            requires_quote = true;
        } else if (char == '"') {
            requires_quote = true;
            try buffer.append(allocator, '"');
        } else if (char == 0) {
            break;
        }
        try buffer.append(allocator, char);
    }

    if (requires_quote) {
        try buffer.append(allocator, '"');
        return buffer.items;
    } else {
        return buffer.items[1..];
    }
}

pub fn escapeHtml(allocator: std.mem.Allocator, input: String, buffer: *MutString) !String {
    buffer.clearRetainingCapacity();

    for (input) |char| {
        switch (char) {
            0 => {
                break;
            },
            '&' => {
                try buffer.appendSlice(allocator, "&amp;");
            },
            '>' => {
                try buffer.appendSlice(allocator, "&gt;");
            },
            '<' => {
                try buffer.appendSlice(allocator, "&lt;");
            },
            '"' => {
                try buffer.appendSlice(allocator, "&quot;");
            },
            '\'' => {
                try buffer.appendSlice(allocator, "&#39;");
            },
            else => {
                try buffer.append(allocator, char);
            },
        }
    }

    return buffer.items;
}

pub const StringBuilder = struct {
    allocator: std.mem.Allocator,
    buffer: MutString,

    pub fn init(allocator: std.mem.Allocator) StringBuilder {
        return StringBuilder{ .allocator = allocator, .buffer = .empty };
    }

    pub fn deinit(self: *StringBuilder) void {
        self.buffer.deinit(self.allocator);
    }

    pub fn push(self: *StringBuilder, char: u8) void {
        self.buffer.append(self.allocator, char) catch {};
    }

    pub fn append(self: *StringBuilder, slice: String) void {
        self.buffer.appendSlice(self.allocator, slice) catch {};
    }

    pub fn viewString(self: *const StringBuilder) String {
        return self.buffer.items;
    }

    pub fn toOwnedMutString(self: *StringBuilder) MutString {
        const old_buffer = self.buffer;
        self.buffer = .empty;

        return old_buffer;
    }

    pub fn toOwnedString(self: *StringBuilder) !String {
        const owned_mut = self.toOwnedMutString();
        return owned_mut.toOwnedSlice(self.allocator);
    }

    pub fn clear(self: *StringBuilder) void {
        self.buffer.clearRetainingCapacity();
    }
};

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
pub fn resolveFilepath(allocator: std.mem.Allocator, raw_filepath: String, default_directory: String) !String {
    const filepath = std.mem.trim(u8, raw_filepath, &std.ascii.whitespace);

    // Check if the filepath is absolute (starts with '/' on Unix)
    if (startsWith(filepath, '/')) {
        // Absolute path - return a copy
        return try allocator.dupe(u8, filepath);
    }

    // Relative path - concatenate with default_directory
    // Ensure default_directory ends with '/' if it doesn't already
    const needs_slash = !endsWith(default_directory, '/');
    const total_length = default_directory.len + (if (needs_slash) @as(usize, 1) else 0) + filepath.len;

    const resolved = try allocator.alloc(u8, total_length);
    var write_position: usize = 0;

    // Copy default_directory
    @memcpy(resolved[write_position..][0..default_directory.len], default_directory);
    write_position += default_directory.len;

    // Add separator if needed
    if (needs_slash) {
        resolved[write_position] = '/';
        write_position += 1;
    }

    // Copy filepath
    @memcpy(resolved[write_position..][0..filepath.len], filepath);

    return resolved;
}
