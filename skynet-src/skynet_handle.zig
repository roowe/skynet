const std = @import("std");

const handle_mask: u32 = 0x00ff_ffff;
const remote_shift = 24;
const max_name_capacity = 0x4000_0000;
const cache_line = 64;

const Context = opaque {};

extern fn malloc(size: usize) ?*anyopaque;
extern fn free(ptr: *anyopaque) void;
extern fn strcmp(a: [*:0]const u8, b: [*:0]const u8) c_int;
extern fn skynet_strdup(name: [*:0]const u8) ?[*:0]u8;
extern fn skynet_context_handle(ctx: *Context) u32;
extern fn skynet_context_grab(ctx: *Context) void;
extern fn skynet_context_release(ctx: *Context) void;

const AtomicInt = std.atomic.Value(c_int);

const ReaderSlot = struct {
    active: AtomicInt = .init(0),
    padding: [cache_line - @sizeOf(AtomicInt)]u8 = undefined,
};

const Name = struct {
    text: [*:0]u8,
    handle: u32,
};

const NameSearch = struct {
    index: usize,
    found: bool,
};

threadlocal var reader_index: ?usize = null;
var storage: ?*Storage = null;

const Storage = struct {
    writer: AtomicInt = .init(0),
    shared_readers: AtomicInt = .init(0),
    next_reader: std.atomic.Value(usize) = .init(0),
    readers: []ReaderSlot,
    harbor: u32,
    next_handle: u32 = 1,
    slots: []?*Context,
    names: []Name,
    name_count: usize = 0,

    fn readLock(self: *Storage) void {
        // Publish the reader before checking the writer; the writer does the reverse.
        // Keep both sides sequentially consistent, as in the C locks.
        if (reader_index) |index| {
            const slot = &self.readers[index];
            while (true) {
                slot.active.store(1, .seq_cst);
                if (self.writer.load(.seq_cst) == 0) return;
                slot.active.store(0, .seq_cst);
                while (self.writer.load(.seq_cst) != 0) std.atomic.spinLoopHint();
            }
        }
        while (true) {
            while (self.writer.load(.seq_cst) != 0) std.atomic.spinLoopHint();
            _ = self.shared_readers.fetchAdd(1, .seq_cst);
            if (self.writer.load(.seq_cst) == 0) return;
            _ = self.shared_readers.fetchSub(1, .seq_cst);
        }
    }

    fn readUnlock(self: *Storage) void {
        if (reader_index) |index| {
            self.readers[index].active.store(0, .seq_cst);
        } else {
            _ = self.shared_readers.fetchSub(1, .seq_cst);
        }
    }

    fn writeLock(self: *Storage) void {
        while (self.writer.cmpxchgWeak(0, 1, .seq_cst, .seq_cst) != null) std.atomic.spinLoopHint();
        while (self.shared_readers.load(.seq_cst) != 0) std.atomic.spinLoopHint();
        for (self.readers) |*slot| {
            while (slot.active.load(.seq_cst) != 0) std.atomic.spinLoopHint();
        }
    }

    fn writeUnlock(self: *Storage) void {
        self.writer.store(0, .seq_cst);
    }

    fn growSlots(self: *Storage) void {
        const capacity = self.slots.len * 2;
        std.debug.assert(capacity - 1 <= handle_mask);
        const larger = allocate(?*Context, capacity);
        @memset(larger, null);
        for (self.slots) |entry| {
            const ctx = entry orelse continue;
            const index = slotIndex(skynet_context_handle(ctx), capacity);
            std.debug.assert(larger[index] == null);
            larger[index] = ctx;
        }
        free(@ptrCast(self.slots.ptr));
        self.slots = larger;
    }

    fn findName(self: *const Storage, name: [*:0]const u8) NameSearch {
        var begin: usize = 0;
        var end = self.name_count;
        while (begin < end) {
            const mid = begin + (end - begin) / 2;
            const order = strcmp(self.names[mid].text, name);
            if (order == 0) return .{ .index = mid, .found = true };
            if (order < 0) {
                begin = mid + 1;
            } else {
                end = mid;
            }
        }
        return .{ .index = begin, .found = false };
    }
};

fn slotIndex(handle: u32, capacity: usize) usize {
    return handle & (capacity - 1);
}

fn allocate(comptime T: type, count: usize) []T {
    const memory = malloc(@sizeOf(T) * count) orelse @panic("out of memory allocating handle storage");
    const items: [*]T = @ptrCast(@alignCast(memory));
    return items[0..count];
}

export fn skynet_handle_init(harbor: c_int, thread_count: c_int) void {
    std.debug.assert(storage == null);
    const s = &allocate(Storage, 1)[0];
    // One slot per worker plus monitor, timer and socket.
    const readers = allocate(ReaderSlot, @intCast(thread_count + 3));
    @memset(readers, .{});
    const slots = allocate(?*Context, 4);
    @memset(slots, null);
    s.* = .{
        .readers = readers,
        .harbor = @as(u32, @intCast(harbor & 0xff)) << remote_shift,
        .slots = slots,
        .names = allocate(Name, 2),
    };
    storage = s;
}

export fn skynet_handle_register_thread() void {
    const s = storage.?;
    const index = s.next_reader.fetchAdd(1, .seq_cst);
    if (index < s.readers.len) reader_index = index;
}

export fn skynet_handle_register(ctx: *Context) u32 {
    const s = storage.?;
    s.writeLock();
    defer s.writeUnlock();

    while (true) {
        var handle = s.next_handle;
        for (0..s.slots.len) |_| {
            if (handle > handle_mask) handle = 1; // 0 is reserved.
            const index = slotIndex(handle, s.slots.len);
            if (s.slots[index] == null) {
                s.slots[index] = ctx;
                s.next_handle = handle + 1;
                return handle | s.harbor;
            }
            handle += 1;
        }
        s.growSlots();
    }
}

export fn skynet_handle_grab(handle: u32) ?*Context {
    const s = storage.?;
    s.readLock();
    defer s.readUnlock();

    const ctx = s.slots[slotIndex(handle, s.slots.len)] orelse return null;
    if (skynet_context_handle(ctx) != handle) return null;
    // Acquire the reference before a writer can remove the table entry.
    skynet_context_grab(ctx);
    return ctx;
}

export fn skynet_handle_retire(handle: u32) c_int {
    const s = storage.?;
    s.writeLock();
    const ctx = blk: {
        defer s.writeUnlock();
        const index = slotIndex(handle, s.slots.len);
        const ctx = s.slots[index] orelse return 0;
        if (skynet_context_handle(ctx) != handle) return 0;
        s.slots[index] = null;

        var kept: usize = 0;
        for (s.names[0..s.name_count]) |entry| {
            if (entry.handle == handle) {
                free(entry.text);
            } else {
                s.names[kept] = entry;
                kept += 1;
            }
        }
        s.name_count = kept;
        break :blk ctx;
    };

    // Destroying a context can re-enter the handle registry.
    skynet_context_release(ctx);
    return 1;
}

export fn skynet_handle_retireall() void {
    const s = storage.?;
    while (true) {
        var found_context = false;
        var index: usize = 0;
        while (true) : (index += 1) {
            s.readLock();
            if (index == s.slots.len) {
                s.readUnlock();
                break;
            }
            const handle = if (s.slots[index]) |ctx| blk: {
                found_context = true;
                break :blk skynet_context_handle(ctx);
            } else 0;
            s.readUnlock();
            if (handle != 0) _ = skynet_handle_retire(handle);
        }
        if (!found_context) return;
    }
}

export fn skynet_handle_findname(name: [*:0]const u8) u32 {
    const s = storage.?;
    s.readLock();
    defer s.readUnlock();

    const result = s.findName(name);
    return if (result.found) s.names[result.index].handle else 0;
}

export fn skynet_handle_namehandle(handle: u32, name: [*:0]const u8) ?[*:0]const u8 {
    const s = storage.?;
    s.writeLock();
    defer s.writeUnlock();

    const result = s.findName(name);
    if (result.found) return null;
    const index = result.index;

    const copy = skynet_strdup(name) orelse @panic("out of memory duplicating handle name");
    if (s.name_count == s.names.len) {
        const capacity = s.names.len * 2;
        std.debug.assert(capacity <= max_name_capacity);
        const larger = allocate(Name, capacity);
        @memcpy(larger[0..s.name_count], s.names[0..s.name_count]);
        free(s.names.ptr);
        s.names = larger;
    }
    var end = s.name_count;
    while (end > index) : (end -= 1) s.names[end] = s.names[end - 1];
    s.names[index] = .{ .text = copy, .handle = handle };
    s.name_count += 1;
    return copy;
}
