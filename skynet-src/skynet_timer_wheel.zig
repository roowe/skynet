const near_bits = 8;
const level_bits = 6;
const level_count = 4;
const near_size = 1 << near_bits;
const level_size = 1 << level_bits;
const near_mask = near_size - 1;
const level_mask = level_size - 1;

pub const Node = struct {
    next: ?*Node = null,
    expires: u32 = undefined,
    handle: u32,
    session: c_int,
};

const Bucket = struct {
    head: ?*Node = null,
    tail: ?*Node = null,

    fn append(self: *Bucket, node: *Node) void {
        node.next = null;
        if (self.tail) |tail| {
            tail.next = node;
        } else {
            self.head = node;
        }
        self.tail = node;
    }

    fn take(self: *Bucket) ?*Node {
        const head = self.head;
        self.* = .{};
        return head;
    }
};

pub const Wheel = struct {
    tick: u32 = 0,
    near: [near_size]Bucket = @splat(.{}),
    levels: [level_count][level_size]Bucket = @splat(@splat(.{})),

    pub fn schedule(self: *Wheel, node: *Node, delay: u32) void {
        node.expires = self.tick +% delay;
        self.insert(node);
    }

    pub fn takeReady(self: *Wheel) ?*Node {
        return self.near[self.tick & near_mask].take();
    }

    // Drain the current bucket before advancing to the next tick.
    pub fn advance(self: *Wheel) void {
        self.tick +%= 1;
        if (self.tick == 0) {
            self.cascade(level_count - 1, 0);
            return;
        }
        if (self.tick & near_mask != 0) return;

        // Cascade the first coarse bucket that did not wrap to zero.
        var slots = self.tick >> near_bits;
        for (0..level_count) |level| {
            const slot = slots & level_mask;
            if (slot != 0) {
                self.cascade(level, slot);
                return;
            }
            slots >>= level_bits;
        }
        unreachable;
    }

    fn insert(self: *Wheel, node: *Node) void {
        const differing_bits = node.expires ^ self.tick;
        if (differing_bits >> near_bits == 0) {
            self.near[node.expires & near_mask].append(node);
            return;
        }

        var level: usize = 0;
        while (level < level_count - 1 and differing_bits >> levelShift(level + 1) != 0) : (level += 1) {}
        const slot = (node.expires >> levelShift(level)) & level_mask;
        self.levels[level][slot].append(node);
    }

    fn cascade(self: *Wheel, level: usize, slot: usize) void {
        var chain = self.levels[level][slot].take();
        while (chain) |node| {
            chain = node.next;
            self.insert(node);
        }
    }
};

fn levelShift(level: usize) u5 {
    return @intCast(near_bits + level * level_bits);
}
