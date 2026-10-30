//! Bounded reassembly of explicitly requested HDA LogService snapshots.
const std = @import("std");
pub const max_lines = 32;
pub const max_body_bytes = 512;
pub const fragment_bytes = 72;
const max_parts = 8;

fn value(text: []const u8, key: []const u8) ?[]const u8 {
    var tokens = std.mem.tokenizeScalar(u8, text, ' ');
    var found: ?[]const u8 = null;
    while (tokens.next()) |token| {
        if (!std.mem.startsWith(u8, token, key)) continue;
        if (found != null) return null;
        found = token[key.len..];
    }
    return found;
}
fn number(text: []const u8, base: u8) ?u64 {
    if (text.len == 0) return null;
    for (text) |byte| {
        if (byte >= '0' and byte <= '9') continue;
        if (base == 16 and ((byte >= 'a' and byte <= 'f') or (byte >= 'A' and byte <= 'F'))) continue;
        return null;
    }
    return std.fmt.parseUnsigned(u64, text, base) catch null;
}
fn hex(text: []const u8, key: []const u8, width: usize) ?u64 {
    const token = value(text, key) orelse return null;
    if (token.len != width) return null;
    return number(token, 16);
}
fn decimal(text: []const u8, key: []const u8) ?u64 {
    return number(value(text, key) orelse return null, 10);
}

pub const Snapshot = struct {
    epoch: u64 = 0,
    sequence: u64 = 0,
    handle: u64 = 0,
    output: u64 = 0,
    reset: u64 = 0,
    pci: u32 = 0,
    begin_sequence: u64 = 0,
    end_sequence: u64 = 0,
    newest_part_sequence: u64 = 0,
    time_sequence: u64 = 0,
    capture_tick: u64 = 0,
    time_seen: bool = false,
    failed: bool = false,
    ended: bool = false,
    expected_lines: usize = 0,
    expected_parts: usize = 0,
    received_parts: usize = 0,
    bodies: [max_lines][max_body_bytes]u8 = undefined,
    totals: [max_lines]u8 = .{0} ** max_lines,
    masks: [max_lines]u8 = .{0} ** max_lines,
    body_lengths: [max_lines]u16 = .{0} ** max_lines,
    lengths: [max_lines][max_parts]u8 = .{.{0} ** max_parts} ** max_lines,

    pub fn start(self: *Snapshot, text: []const u8, log_sequence: u64, after: u64) bool {
        if (!std.mem.startsWith(u8, text, "HDA.SNAP begin ") or log_sequence <= after) return false;
        if (!std.mem.eql(u8, value(text, "v=") orelse return false, "1") or
            !std.mem.eql(u8, value(text, "phase=") orelse return false, "close")) return false;
        const epoch = hex(text, "e=", 16) orelse return false;
        const sequence = hex(text, "s=", 16) orelse return false;
        const handle = hex(text, "h=", 16) orelse return false;
        const output = hex(text, "o=", 16) orelse return false;
        const reset = hex(text, "r=", 16) orelse return false;
        const pci = hex(text, "pci=", 6) orelse return false;
        if (epoch == 0 or sequence == 0 or handle == 0 or output == 0 or reset == 0) return false;
        self.* = .{ .epoch = epoch, .sequence = sequence, .handle = handle, .output = output, .reset = reset, .pci = @intCast(pci), .begin_sequence = log_sequence };
        return true;
    }

    pub fn ingest(self: *Snapshot, text: []const u8, log_sequence: u64) void {
        if (self.epoch == 0 or self.failed or log_sequence <= self.begin_sequence) return;
        const is_part = std.mem.startsWith(u8, text, "HDA.DET ");
        const is_time = std.mem.startsWith(u8, text, "HDA.SNAP time ");
        const is_end = std.mem.startsWith(u8, text, "HDA.SNAP end ");
        if (!is_part and !is_time and !is_end) return;
        const header_end = if (is_part) blk: {
            const position = std.mem.indexOf(u8, text, " p=") orelse return;
            break :blk std.mem.indexOfScalarPos(u8, text, position + 3, ' ') orelse return;
        } else text.len;
        const metadata = text[0..header_end];
        if ((hex(metadata, "e=", 16) orelse return) != self.epoch or (hex(metadata, "s=", 16) orelse return) != self.sequence) return;
        if (!std.mem.eql(u8, value(metadata, "v=") orelse "", "1")) {
            self.failed = true;
            return;
        }
        if (is_time) {
            const tick = hex(metadata, "t=", 16) orelse {
                self.failed = true;
                return;
            };
            if (self.time_seen and self.capture_tick != tick) {
                self.failed = true;
                return;
            }
            self.time_seen = true;
            self.capture_tick = tick;
            self.time_sequence = @max(self.time_sequence, log_sequence);
            return;
        }
        if (is_end) {
            const lines = decimal(metadata, "lines=") orelse {
                self.failed = true;
                return;
            };
            const parts = decimal(metadata, "parts=") orelse {
                self.failed = true;
                return;
            };
            if ((decimal(metadata, "ok=") orelse 0) != 1 or lines == 0 or lines > max_lines or parts == 0 or parts > max_lines * max_parts) {
                self.failed = true;
                return;
            }
            if (self.ended and (self.expected_lines != lines or self.expected_parts != parts)) {
                self.failed = true;
                return;
            }
            self.ended = true;
            self.expected_lines = @intCast(lines);
            self.expected_parts = @intCast(parts);
            self.end_sequence = @max(self.end_sequence, log_sequence);
            return;
        }
        self.part(metadata, text[header_end + 1 ..], log_sequence);
    }

    fn part(self: *Snapshot, metadata: []const u8, body: []const u8, log_sequence: u64) void {
        const line = decimal(metadata, "l=") orelse {
            self.failed = true;
            return;
        };
        const pair = value(metadata, "p=") orelse {
            self.failed = true;
            return;
        };
        const slash = std.mem.indexOfScalar(u8, pair, '/') orelse {
            self.failed = true;
            return;
        };
        const index = number(pair[0..slash], 10) orelse {
            self.failed = true;
            return;
        };
        const total = number(pair[slash + 1 ..], 10) orelse {
            self.failed = true;
            return;
        };
        const body_length = decimal(metadata, "b=") orelse {
            self.failed = true;
            return;
        };
        if (line >= max_lines or total == 0 or total > max_parts or index >= total or body_length == 0 or body_length >= max_body_bytes or total != (body_length + fragment_bytes - 1) / fragment_bytes or body.len == 0 or body.len > fragment_bytes or std.mem.indexOfScalar(u8, body, 0) != null) {
            self.failed = true;
            return;
        }
        const row: usize = @intCast(line);
        const column: usize = @intCast(index);
        const offset = column * fragment_bytes;
        if (offset >= body_length or body.len != @min(fragment_bytes, body_length - offset) or (self.totals[row] != 0 and (self.totals[row] != total or self.body_lengths[row] != body_length))) {
            self.failed = true;
            return;
        }
        const bit = @as(u8, 1) << @as(u3, @intCast(column));
        if ((self.masks[row] & bit) != 0) {
            if (self.lengths[row][column] != body.len or !std.mem.eql(u8, self.bodies[row][offset..][0..body.len], body)) self.failed = true;
            return;
        }
        self.totals[row] = @intCast(total);
        self.body_lengths[row] = @intCast(body_length);
        self.lengths[row][column] = @intCast(body.len);
        self.masks[row] |= bit;
        @memcpy(self.bodies[row][offset..][0..body.len], body);
        self.received_parts += 1;
        self.newest_part_sequence = @max(self.newest_part_sequence, log_sequence);
    }

    pub fn complete(self: *const Snapshot, not_before_tick: u64) bool {
        if (self.failed or !self.ended or !self.time_seen or self.capture_tick < not_before_tick or self.end_sequence <= self.time_sequence or self.end_sequence <= self.newest_part_sequence or self.received_parts != self.expected_parts) return false;
        for (0..max_lines) |line| {
            const total = self.totals[line];
            if (line >= self.expected_lines) {
                if (total != 0) return false;
                continue;
            }
            if (total == 0 or total > max_parts) return false;
            const mask: u8 = @intCast((@as(u16, 1) << @as(u4, @intCast(total))) - 1);
            if (self.masks[line] != mask or self.lengths[line][total - 1] == 0) return false;
        }
        return true;
    }

    pub fn bodyAt(self: *const Snapshot, index: usize) []const u8 {
        std.debug.assert(index < self.expected_lines and self.totals[index] != 0);
        const total = self.totals[index];
        const length = (@as(usize, total) - 1) * fragment_bytes + self.lengths[index][total - 1];
        return self.bodies[index][0..length];
    }

    pub fn contains(self: *const Snapshot, prefix: []const u8, fields: []const []const u8) bool {
        if (!self.complete(0)) return false;
        for (0..self.expected_lines) |index| {
            const text = self.bodyAt(index);
            if (!std.mem.startsWith(u8, text, prefix)) continue;
            var found = true;
            for (fields) |field| {
                if (std.mem.indexOf(u8, text, field) == null) {
                    found = false;
                    break;
                }
            }
            if (found) return true;
        }
        return false;
    }
};

const sample_begin = "HDA.SNAP begin v=1 e=8000000000000001 s=0000000000000002 h=f000000000000003 o=0000000000000004 r=0000000000000005 pci=001b00 phase=close";
const sample_time = "HDA.SNAP time v=1 e=8000000000000001 s=0000000000000002 t=0000000000000014";
const sample_part = "HDA.DET v=1 e=8000000000000001 s=0000000000000002 l=0 b=34 p=0/1 HDA.DIAG core stage=ready fmt=0011";
const sample_end = "HDA.SNAP end v=1 e=8000000000000001 s=0000000000000002 lines=1 parts=1 ok=1";
fn sample() Snapshot {
    var result = Snapshot{};
    std.debug.assert(result.start(sample_begin, 10, 9));
    result.ingest(sample_time, 11);
    result.ingest(sample_part, 12);
    result.ingest(sample_end, 13);
    return result;
}

test "full width owner keys and exact source fields require a fresh complete snapshot" {
    const snapshot = sample();
    try std.testing.expectEqual(@as(u64, 0x8000000000000001), snapshot.epoch);
    try std.testing.expectEqual(@as(u64, 0xf000000000000003), snapshot.handle);
    try std.testing.expect(snapshot.complete(20));
    try std.testing.expect(!snapshot.complete(21));
    try std.testing.expect(snapshot.contains("HDA.DIAG core", &.{ "stage=ready", "fmt=0011" }));
    var older = Snapshot{};
    try std.testing.expect(!older.start(sample_begin, 10, 10));
    try std.testing.expect(!older.start("HDA.SNAP begin v=2 e=8000000000000001", 11, 10));
}

test "out of order pages reconstruct every byte of a maximum size logical line" {
    var snapshot = Snapshot{};
    try std.testing.expect(snapshot.start(sample_begin, 10, 0));
    snapshot.ingest(sample_time, 11);
    snapshot.ingest("HDA.SNAP end v=1 e=8000000000000001 s=0000000000000002 lines=1 parts=8 ok=1", 30);
    var expected: [511]u8 = undefined;
    for (&expected, 0..) |*byte, i| byte.* = 'a' + @as(u8, @intCast(i % 26));
    for (0..8) |order| {
        const part = 7 - order;
        const offset = part * fragment_bytes;
        var wire: [160]u8 = undefined;
        const text = try std.fmt.bufPrint(&wire, "HDA.DET v=1 e=8000000000000001 s=0000000000000002 l=0 b=511 p={d}/8 {s}", .{ part, expected[offset..@min(expected.len, offset + fragment_bytes)] });
        snapshot.ingest(text, 12 + part);
    }
    try std.testing.expect(snapshot.complete(20));
    try std.testing.expectEqualSlices(u8, &expected, snapshot.bodyAt(0));
}

test "identical duplicate parts are idempotent but conflicting content is rejected" {
    var snapshot = sample();
    snapshot.ingest(sample_part, 12);
    try std.testing.expect(snapshot.complete(20));
    try std.testing.expectEqual(@as(usize, 1), snapshot.received_parts);
    snapshot.ingest("HDA.DET v=1 e=8000000000000001 s=0000000000000002 l=0 b=34 p=0/1 HDA.DIAG core stage=other fmt=0011", 12);
    try std.testing.expect(!snapshot.complete(20));
}

test "other epochs and sequences cannot supply missing snapshot parts" {
    var snapshot = Snapshot{};
    try std.testing.expect(snapshot.start(sample_begin, 10, 0));
    snapshot.ingest(sample_time, 11);
    snapshot.ingest("HDA.DET v=1 e=8000000000000000 s=0000000000000002 l=0 b=11 p=0/1 wrong epoch", 12);
    snapshot.ingest("HDA.DET v=1 e=8000000000000001 s=0000000000000003 l=0 b=14 p=0/1 wrong sequence", 12);
    snapshot.ingest(sample_end, 13);
    try std.testing.expect(!snapshot.complete(20));
    try std.testing.expect(!snapshot.contains("HDA.DIAG", &.{}));
    snapshot.ingest(sample_part, 12);
    try std.testing.expect(snapshot.complete(20));
}

test "missing data timestamps failed receipts and conflicting totals never become evidence" {
    var snapshot = Snapshot{};
    try std.testing.expect(snapshot.start(sample_begin, 10, 0));
    snapshot.ingest(sample_part, 12);
    snapshot.ingest(sample_end, 13);
    try std.testing.expect(!snapshot.complete(0));
    snapshot.ingest(sample_time, 11);
    try std.testing.expect(snapshot.complete(0));
    snapshot.ingest("HDA.SNAP end v=1 e=8000000000000001 s=0000000000000002 lines=1 parts=1 ok=0", 14);
    try std.testing.expect(!snapshot.complete(0));
    snapshot = sample();
    snapshot.ingest("HDA.SNAP end v=1 e=8000000000000001 s=0000000000000002 lines=2 parts=1 ok=1", 14);
    try std.testing.expect(!snapshot.complete(0));
}

test "invalid bounds short nonfinal fragments and rows outside the footer are rejected" {
    for ([_][]const u8{
        "HDA.DET v=1 e=8000000000000001 s=0000000000000002 l=32 b=1 p=0/1 x",
        "HDA.DET v=1 e=8000000000000001 s=0000000000000002 l=0 b=511 p=0/9 x",
        "HDA.DET v=1 e=8000000000000001 s=0000000000000002 l=0 b=144 p=0/2 short",
        "HDA.DET v=2 e=8000000000000001 s=0000000000000002 l=0 b=1 p=0/1 x",
    }) |wire| {
        var snapshot = Snapshot{};
        try std.testing.expect(snapshot.start(sample_begin, 10, 0));
        snapshot.ingest(sample_time, 11);
        snapshot.ingest(wire, 12);
        snapshot.ingest(sample_end, 13);
        try std.testing.expect(!snapshot.complete(0));
    }
    var snapshot = sample();
    snapshot.ingest("HDA.DET v=1 e=8000000000000001 s=0000000000000002 l=1 b=5 p=0/1 extra", 12);
    try std.testing.expect(!snapshot.complete(0));
}

test "a shortened final fragment cannot pass a matching terminal part count" {
    var snapshot = Snapshot{};
    try std.testing.expect(snapshot.start(sample_begin, 10, 0));
    snapshot.ingest(sample_time, 11);
    var wire: [160]u8 = undefined;
    const first = try std.fmt.bufPrint(&wire, "HDA.DET v=1 e=8000000000000001 s=0000000000000002 l=0 b=74 p=0/2 {s}", .{&([_]u8{'a'} ** 72)});
    snapshot.ingest(first, 12);
    snapshot.ingest("HDA.DET v=1 e=8000000000000001 s=0000000000000002 l=0 b=74 p=1/2 x", 13);
    snapshot.ingest("HDA.SNAP end v=1 e=8000000000000001 s=0000000000000002 lines=1 parts=2 ok=1", 14);
    try std.testing.expect(!snapshot.complete(0));
}
