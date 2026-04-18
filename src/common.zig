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
        const proposedCapacityGrowth = self.capacity; // Default to doubling

        // Not sure if this matters but prevent small or gigantic growth
        const actualGrowth = if (proposedCapacityGrowth < 1024)
            1024
        else if (proposedCapacityGrowth > 65536)
            65536
        else
            proposedCapacityGrowth;

        return self.capacity + actualGrowth;
    }

    fn grow(self: *ResizableBuffer) !void {
        const newCapacity = self.getNewCapacity();

        self.bytes = try self.allocator.realloc(self.bytes, newCapacity);
        self.capacity = newCapacity;
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

// TODO: Clean this up. If you pass a new allocator there's no way to know which one to use for deinit.
pub fn quoteForCsv(allocator: std.mem.Allocator, input: String, buffer: *MutString) !String {
    buffer.clearRetainingCapacity();
    try buffer.append(allocator, '"');

    var requiresQuote = false;

    for (input) |char| {
        if (char == ',') {
            requiresQuote = true;
        } else if (char == '"') {
            requiresQuote = true;
            try buffer.append(allocator, '"');
        } else if (char == 0) {
            break;
        }
        try buffer.append(allocator, char);
    }

    if (requiresQuote) {
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
        const oldBuffer = self.buffer;
        self.buffer = .empty;

        return oldBuffer;
    }

    pub fn toOwnedString(self: *StringBuilder) !String {
        const ownedMut = self.toOwnedMutString();
        return ownedMut.toOwnedSlice(self.allocator);
    }

    pub fn clear(self: *StringBuilder) void {
        self.buffer.clearRetainingCapacity();
    }
};
