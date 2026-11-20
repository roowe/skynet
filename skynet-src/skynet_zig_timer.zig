const std = @import("std");
const timer = @import("skynet_timer_wheel.zig");

extern fn skynet_zig_timer_alloc(size: usize) ?*anyopaque;
extern fn skynet_zig_timer_free(ptr: *anyopaque) void;
extern fn skynet_zig_timer_dispatch(handle: u32, session: c_int) void;

var wheel: timer.Wheel = .{};
var wheel_lock = std.atomic.Value(u32).init(0);

export fn skynet_zig_timer_add(handle: u32, delay: u32, session: c_int) void {
    const allocation = skynet_zig_timer_alloc(@sizeOf(timer.Node)) orelse @panic("out of memory scheduling timer");
    const node: *timer.Node = @ptrCast(@alignCast(allocation));
    node.* = .{ .handle = handle, .session = session };

    lockWheel();
    defer unlockWheel();
    wheel.schedule(node, delay);
}

export fn skynet_zig_timer_tick() void {
    lockWheel();
    defer unlockWheel();
    dispatchReady();
    wheel.advance();
    dispatchReady();
}

fn lockWheel() void {
    while (wheel_lock.swap(1, .acquire) != 0) {
        while (wheel_lock.load(.monotonic) != 0) std.atomic.spinLoopHint();
    }
}

fn unlockWheel() void {
    wheel_lock.store(0, .release);
}

// Called with the lock held. Deliver each detached chain outside the lock.
fn dispatchReady() void {
    while (wheel.takeReady()) |head| {
        unlockWheel();
        var chain: ?*timer.Node = head;
        while (chain) |node| {
            chain = node.next;
            skynet_zig_timer_dispatch(node.handle, node.session);
            skynet_zig_timer_free(node);
        }
        lockWheel();
    }
}
