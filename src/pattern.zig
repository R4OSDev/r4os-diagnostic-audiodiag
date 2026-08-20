pub const sample_rate: u32 = 48_000;
pub const channels: u16 = 2;
pub const frame_bytes: usize = 4;
pub const quantum_frames: usize = 480;
pub const quantum_bytes: usize = quantum_frames * frame_bytes;
pub const capture_quanta: usize = 16;
pub const long_quanta: usize = 6000;
pub const variable_frames = [_]usize{ 1, 239, 17, 310, 33 };

pub fn fillSquare(out: []u8, first_frame: u64) void {
    var frame: usize = 0;
    while (frame < out.len / frame_bytes) : (frame += 1) {
        const absolute_frame = first_frame + frame;
        const sample: i16 = if (((absolute_frame / 24) & 1) == 0) 4096 else -4096;
        writeI16(out, frame * frame_bytes, sample);
        writeI16(out, frame * frame_bytes + 2, sample);
    }
}

fn writeI16(out: []u8, index: usize, sample: i16) void {
    const bits: u16 = @bitCast(sample);
    out[index] = @intCast(bits & 0xFF);
    out[index + 1] = @intCast(bits >> 8);
}

test "capture pattern never emits a zero sample" {
    const std = @import("std");
    var block: [quantum_bytes]u8 = undefined;
    fillSquare(&block, 0);
    var frame: usize = 0;
    while (frame < quantum_frames) : (frame += 1) {
        const left = readI16(&block, frame * frame_bytes);
        const right = readI16(&block, frame * frame_bytes + 2);
        try std.testing.expect(left != 0);
        try std.testing.expectEqual(left, right);
    }
}

test "packet boundaries preserve square-wave phase" {
    const std = @import("std");
    var split_a: [239 * frame_bytes]u8 = undefined;
    var split_b: [241 * frame_bytes]u8 = undefined;
    var whole: [quantum_bytes]u8 = undefined;
    fillSquare(&split_a, 0);
    fillSquare(&split_b, 239);
    fillSquare(&whole, 0);
    try std.testing.expectEqualSlices(u8, whole[0..split_a.len], &split_a);
    try std.testing.expectEqualSlices(u8, whole[split_a.len..], &split_b);
}

fn readI16(data: []const u8, index: usize) i16 {
    const bits = @as(u16, data[index]) | (@as(u16, data[index + 1]) << 8);
    return @bitCast(bits);
}
