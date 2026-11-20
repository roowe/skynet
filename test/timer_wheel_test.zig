const std = @import("std");
const timer = @import("timer_wheel");

test "time wheel delivers once in deadline order and preserves FIFO at the same tick" {
    const live_handle = 0x100002a;
    const retired_handle = 0x100002b;
    // Start two ticks before each level boundary, including the u32 wrap.
    const starts = [_]u32{ 0xfe, 0x3ffe, 0xffffe, 0x3fffffe, std.math.maxInt(u32) - 1 };
    const expected = [_][]const usize{ &.{}, &.{1}, &.{2}, &.{ 0, 3 }, &.{4}, &.{} };
    const requests = [_]timer.Node{
        .{ .handle = live_handle, .session = 11 },
        .{ .handle = live_handle, .session = 12 },
        .{ .handle = live_handle, .session = 13 },
        .{ .handle = retired_handle, .session = 14 },
        .{ .handle = live_handle, .session = 15 },
    };
    const delays = [_]u32{ 3, 1, 2, 3, 4 };

    for (starts) |start| {
        var wheel: timer.Wheel = .{ .tick = start };
        var nodes = requests;
        for (&nodes, delays) |*node, delay| wheel.schedule(node, delay);

        for (expected) |due| {
            var ready = wheel.takeReady();
            for (due) |index| {
                const node = ready orelse return error.MissingTimer;
                try std.testing.expectEqual(requests[index].handle, node.handle);
                try std.testing.expectEqual(requests[index].session, node.session);
                ready = node.next;
            }
            try std.testing.expectEqual(null, ready);
            try std.testing.expectEqual(null, wheel.takeReady());
            wheel.advance();
        }
    }
}
