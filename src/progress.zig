//! Actual kernel/HDA cursor qualification, separate from the original WAV case.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;

fn fail(ctx: anytype, stage: []const u8) i32 {
    ctx.sys.write("AUDIOD PROGRESS: FAILED ");
    ctx.sys.println(stage);
    return 1;
}

fn snapshot(ctx: anytype, id: u32, generation: u64, out: *a.AudioStreamProgress, deadline: u64) bool {
    while (ctx.sys.ticks() < deadline) {
        const rc = ctx.audio.raw.audioStreamProgress(id, generation, out);
        if (rc == 0) return out.version == 1 and out.size == @sizeOf(a.AudioStreamProgress) and
            out.stream_id == id and out.stream_generation != 0 and (out.flags & a.audio_progress_device_valid) != 0;
        if (rc != a.service_api_result_busy) return false;
        ctx.sys.sleepTicks(1);
    }
    return false;
}

fn expect(ctx: anytype, id: u32, value: *const a.AudioStreamExpectation, deadline: u64) bool {
    while (ctx.sys.ticks() < deadline) {
        const rc = ctx.audio.raw.audioSetStreamExpectation(id, value);
        if (rc == 0) return true;
        if (rc != a.service_api_result_busy) return false;
        ctx.sys.sleepTicks(1);
    }
    return false;
}

fn write(ctx: anytype, id: u32, bytes: []const u8, deadline: u64) bool {
    var offset: usize = 0;
    while (offset < bytes.len and ctx.sys.ticks() < deadline) {
        const rc = ctx.audio.raw.audioWrite(id, bytes[offset..]);
        if (rc == a.service_api_result_busy) {
            ctx.sys.sleepTicks(1);
            continue;
        }
        const count = std.math.cast(usize, rc) orelse return false;
        if (count == 0 or count > bytes.len - offset or count % 4 != 0) return false;
        offset += count;
    }
    return offset == bytes.len;
}

fn close(ctx: anytype, id: u32, generation: u64, out: *a.AudioStreamProgress, deadline: u64) bool {
    while (ctx.sys.ticks() < deadline) {
        const rc = ctx.audio.raw.audioCloseStreamProgress(id, generation, out);
        if (rc == 0) return (out.flags & a.audio_progress_closed) != 0;
        if (rc != a.service_api_result_busy) return false;
        ctx.sys.sleepTicks(1);
    }
    return false;
}

pub fn run(ctx: anytype) i32 {
    ctx.sys.println("AUDIOD PROGRESS: canonical48000Hz stereo-S16 DMA; no speaker receipt");
    const deadline = ctx.sys.ticks() +| ctx.sys.ticksFromMilliseconds(3000);
    var first: a.AudioStreamProgress = .{};
    const opened = ctx.audio.raw.audioOpenStream(48000, 2, .s16le);
    if (opened <= 0) return fail(ctx, "open");
    const id: u32 = @intCast(opened);
    var first_closed = false;
    defer if (!first_closed) {
        _ = ctx.audio.raw.audioClose(id);
    };
    if (!snapshot(ctx, id, 0, &first, deadline) or first.accepted_frames != 0 or first.consumed_frames != 0) return fail(ctx, "initial cursor");
    const due = (ctx.sys.monotonicNanoseconds() orelse return fail(ctx, "clock")) +| 20_000_000;
    var flow = a.AudioStreamExpectation{ .flags = a.audio_flow_continuous, .stream_generation = first.stream_generation, .source_due_ns = due };
    if (!expect(ctx, id, &flow, deadline)) return fail(ctx, "expectation");
    var signal: [1920]u8 = undefined;
    @import("pattern.zig").fillSquare(&signal, 0);
    if (!write(ctx, id, &signal, deadline)) return fail(ctx, "write");
    var current: a.AudioStreamProgress = .{};
    if (!snapshot(ctx, id, first.stream_generation, &current, deadline) or current.accepted_frames != 480) return fail(ctx, "acceptance");
    const distinct = current.consumed_frames < current.accepted_frames;
    while (ctx.sys.ticks() < deadline) {
        if (!snapshot(ctx, id, first.stream_generation, &current, deadline)) return fail(ctx, "cursor");
        if (current.consumed_frames == 480 and current.source_starvations != 0) break;
        ctx.sys.sleepTicks(1);
    }
    if (current.accepted_frames != 480 or current.backend_frames != 480 or current.submitted_frames != 480 or current.consumed_frames != 480 or
        current.unconfirmed_frames != 0 or current.queued_frames != 0 or current.source_starvations != 1) return fail(ctx, "consumed/source deadline");
    var closed: a.AudioStreamProgress = .{};
    if (!close(ctx, id, first.stream_generation, &closed, deadline) or closed.consumed_frames != 480 or closed.unconfirmed_frames != 0) return fail(ctx, "first close");
    first_closed = true;
    const second = ctx.audio.raw.audioOpenStream(48000, 2, .s16le);
    if (second <= 0) return fail(ctx, "second open");
    const next_id: u32 = @intCast(second);
    var next_closed = false;
    defer if (!next_closed) {
        _ = ctx.audio.raw.audioClose(next_id);
    };
    var next: a.AudioStreamProgress = .{};
    if (!snapshot(ctx, next_id, 0, &next, deadline) or next.stream_generation == first.stream_generation) return fail(ctx, "stream generation");
    var rejected = false;
    while (ctx.sys.ticks() < deadline) {
        const rc = ctx.audio.raw.audioStreamProgress(next_id, first.stream_generation, &closed);
        if (rc == a.service_api_result_not_found) {
            rejected = true;
            break;
        }
        if (rc != a.service_api_result_busy) break;
        ctx.sys.sleepTicks(1);
    }
    if (!rejected) return fail(ctx, "stale generation");
    flow.stream_generation = next.stream_generation;
    flow.source_due_ns = (ctx.sys.monotonicNanoseconds() orelse return fail(ctx, "second clock")) +| 20_000_000;
    if (!expect(ctx, next_id, &flow, deadline)) return fail(ctx, "second expectation");
    const silence = [_]u8{0} ** 1920;
    if (!write(ctx, next_id, &silence, deadline)) return fail(ctx, "clocked zero PCM");
    flow.flags = 0;
    flow.source_due_ns = 0;
    if (!expect(ctx, next_id, &flow, deadline)) return fail(ctx, "explicit end");
    const inspect_after = ctx.sys.ticks() +| ctx.sys.ticksFromMilliseconds(60);
    while (ctx.sys.ticks() < inspect_after and ctx.sys.ticks() < deadline) ctx.sys.sleepTicks(1);
    if (!snapshot(ctx, next_id, next.stream_generation, &next, deadline) or next.accepted_frames != 480 or next.consumed_frames != 480 or
        next.source_starvations != 0 or (next.flags & a.audio_progress_ended) == 0) return fail(ctx, "ended zero PCM");
    if (!close(ctx, next_id, next.stream_generation, &closed, deadline) or closed.consumed_frames != 480) return fail(ctx, "second close");
    next_closed = true;
    ctx.sys.write("AUDIOD PROGRESS accepted=480 backend=480 dma=480 consumed=480 unconfirmed=0 source-starvations=1 ended-starvations=0 generation-rejected=1 distinct-observed=");
    ctx.sys.printU64(@intFromBool(distinct));
    ctx.sys.println(" closed=2 [OK]");
    return 0;
}
