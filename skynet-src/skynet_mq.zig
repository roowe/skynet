const std = @import("std");

const default_capacity = 64;
const initial_overload_threshold = 1024;

extern fn malloc(size: usize) ?*anyopaque;
extern fn free(ptr: *anyopaque) void;

// Matches struct skynet_message in skynet_mq.h.
const Message = extern struct {
    source: u32,
    session: c_int,
    data: ?*anyopaque,
    sz: usize,
};

const Drop = *const fn (*Message, ?*anyopaque) callconv(.c) void;

const Spinlock = struct {
    state: std.atomic.Value(u32) = .init(0),

    fn lock(self: *Spinlock) void {
        while (self.state.swap(1, .acquire) != 0) {
            while (self.state.load(.monotonic) != 0) std.atomic.spinLoopHint();
        }
    }

    fn unlock(self: *Spinlock) void {
        self.state.store(0, .release);
    }
};

const MessageQueue = struct {
    lock: Spinlock = .{},
    handle: u32,
    buffer: []Message,
    head: usize = 0,
    tail: usize = 0,
    released: bool = false,
    // The creator owns the queue until initialization succeeds and it enqueues it.
    // Later this flag covers both the global ready list and worker ownership.
    in_global: bool = true,
    overload: c_int = 0,
    overload_threshold: usize = initial_overload_threshold,
    next: ?*MessageQueue = null,

    fn length(self: *const MessageQueue) usize {
        if (self.head <= self.tail) return self.tail - self.head;
        return self.buffer.len - self.head + self.tail;
    }

    fn grow(self: *MessageQueue) void {
        const capacity = self.buffer.len;
        const larger = allocate(Message, capacity * 2);
        const suffix = self.buffer[self.head..];
        @memcpy(larger[0..suffix.len], suffix);
        @memcpy(larger[suffix.len..capacity], self.buffer[0..self.head]);
        free(self.buffer.ptr);
        self.buffer = larger;
        self.head = 0;
        self.tail = capacity;
    }
};

const GlobalQueue = struct {
    lock: Spinlock = .{},
    head: ?*MessageQueue = null,
    tail: ?*MessageQueue = null,
};

var global_queue: *GlobalQueue = undefined;

fn allocate(comptime T: type, count: usize) []T {
    const memory = malloc(@sizeOf(T) * count) orelse @panic("out of memory allocating message queue");
    const items: [*]T = @ptrCast(@alignCast(memory));
    return items[0..count];
}

export fn skynet_globalmq_push(queue: *MessageQueue) void {
    const global = global_queue;
    global.lock.lock();
    defer global.lock.unlock();

    std.debug.assert(queue.next == null);
    if (global.tail) |tail| {
        tail.next = queue;
    } else {
        global.head = queue;
    }
    global.tail = queue;
}

export fn skynet_globalmq_pop() ?*MessageQueue {
    const global = global_queue;
    global.lock.lock();
    defer global.lock.unlock();

    const queue = global.head orelse return null;
    global.head = queue.next;
    if (global.head == null) {
        std.debug.assert(global.tail == queue);
        global.tail = null;
    }
    queue.next = null;
    return queue;
}

export fn skynet_mq_create(handle: u32) *MessageQueue {
    const queue = &allocate(MessageQueue, 1)[0];
    queue.* = .{ .handle = handle, .buffer = allocate(Message, default_capacity) };
    return queue;
}

export fn skynet_mq_handle(queue: *MessageQueue) u32 {
    return queue.handle;
}

export fn skynet_mq_length(queue: *MessageQueue) c_int {
    queue.lock.lock();
    defer queue.lock.unlock();
    return @intCast(queue.length());
}

export fn skynet_mq_overload(queue: *MessageQueue) c_int {
    // Only the worker currently owning this queue reads or updates overload.
    const overload = queue.overload;
    queue.overload = 0;
    return overload;
}

export fn skynet_mq_pop(queue: *MessageQueue, message: *Message) c_int {
    queue.lock.lock();
    defer queue.lock.unlock();

    if (queue.head == queue.tail) {
        queue.overload_threshold = initial_overload_threshold;
        queue.in_global = false;
        return 1;
    }

    message.* = queue.buffer[queue.head];
    queue.head += 1;
    if (queue.head == queue.buffer.len) queue.head = 0;
    const length = queue.length();
    while (length > queue.overload_threshold) {
        queue.overload = @intCast(length);
        queue.overload_threshold *= 2;
    }
    return 0;
}

export fn skynet_mq_push(queue: *MessageQueue, message: *Message) void {
    queue.lock.lock();
    defer queue.lock.unlock();

    queue.buffer[queue.tail] = message.*;
    queue.tail += 1;
    if (queue.tail == queue.buffer.len) queue.tail = 0;
    if (queue.head == queue.tail) queue.grow();

    if (!queue.in_global) {
        queue.in_global = true;
        skynet_globalmq_push(queue);
    }
}

export fn skynet_mq_init() void {
    global_queue = &allocate(GlobalQueue, 1)[0];
    global_queue.* = .{};
}

export fn skynet_mq_mark_release(queue: *MessageQueue) void {
    queue.lock.lock();
    defer queue.lock.unlock();

    std.debug.assert(!queue.released);
    queue.released = true;
    if (!queue.in_global) skynet_globalmq_push(queue);
}

export fn skynet_mq_release(queue: *MessageQueue, drop: ?Drop, ud: ?*anyopaque) void {
    queue.lock.lock();
    if (!queue.released) {
        skynet_globalmq_push(queue);
        queue.lock.unlock();
        return;
    }
    queue.lock.unlock();

    // The callback can enter the runtime again. Invoke it without either queue lock.
    var message: Message = undefined;
    while (skynet_mq_pop(queue, &message) == 0) {
        drop.?(&message, ud);
    }
    std.debug.assert(queue.next == null);
    free(queue.buffer.ptr);
    free(queue);
}
