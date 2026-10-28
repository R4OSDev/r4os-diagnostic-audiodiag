//! Explicit service signal/10ms-null/signal timeline and real terminal drain.
const std = @import("std");
const r = @import("r4os");
const a = r.abi;

fn fail(ctx: anytype, stage: []const u8) i32 {
    ctx.sys.write("AUDIOD GAP: FAILED ");
    ctx.sys.println(stage);
    return 1;
}

fn transportFailure(ctx: anytype, stage: []const u8, outcome: []const u8, raw: ?i32, stream: u32) void {
    var line: [256]u8 = undefined;
    ctx.sys.println(std.fmt.bufPrint(&line, "AUDIOD GAP detail stage={s} outcome={s} raw={?d} stream={d} rpc-timeout-ns=100000000", .{stage,outcome,raw,stream}) catch "AUDIOD GAP detail formatting failed");
}

fn query(ctx: anytype, stream: *r.AudioStream, key: a.AudioServiceStreamProgressRequest, out: *a.AudioServiceStreamProgressState, deadline: u64, closing: bool, close_attempts: *u32) bool {
    const op = if (closing) a.audio_service_op_close_stream_progress else a.audio_service_op_stream_progress;
    while (ctx.sys.ticks() < deadline) {
        if (closing) close_attempts.* += 1;
        const response = stream.connection.callTyped(a.AudioServiceStreamProgressRequest, a.AudioServiceStreamProgressState, op, &key, r.time_contract.timeoutFinite(.{ .nanoseconds = 100_000_000 }));
        switch (response) {
            .value => |value| {
                if (value.result == a.service_api_result_busy) {
                    ctx.sys.sleepTicks(1);
                    continue;
                }
                if (value.result != 0 or value.magic != (a.AudioServiceStreamProgressState{}).magic or value.version != 1 or value.size != @sizeOf(@TypeOf(value)) or value.stream_id != stream.stream_id or
                    value.service_epoch == 0 or value.stream_generation == 0 or value.progress.version != 1 or value.progress.size != @sizeOf(a.AudioStreamProgress)) {
                    transportFailure(ctx, if(closing) "terminal-close" else "progress", "invalid-response", value.result, stream.stream_id);
                    return false;
                }
                if (key.service_epoch != 0 and (value.service_epoch != key.service_epoch or value.stream_generation != key.stream_generation)) {
                    transportFailure(ctx, if(closing) "terminal-close" else "progress", "identity-changed", value.result, stream.stream_id);
                    return false;
                }
                out.* = value;
                return true;
            },
            .timed_out => { transportFailure(ctx, if(closing) "terminal-close" else "progress", "timed-out", a.service_api_result_timeout, stream.stream_id); return false; },
            .remote_failure => |raw| { transportFailure(ctx, if(closing) "terminal-close" else "progress", "remote-failure", raw, stream.stream_id); return false; },
            .failure => |raw| { transportFailure(ctx, if(closing) "terminal-close" else "progress", "call-failure", raw, stream.stream_id); return false; },
        }
    }
    transportFailure(ctx, if(closing) "terminal-close" else "progress", "overall-deadline-no-new-rpc", null, stream.stream_id);
    return false;
}

fn sameBackend(first: a.AudioServiceStreamProgressState, current: a.AudioServiceStreamProgressState) bool {
    return first.service_epoch == current.service_epoch and first.stream_generation == current.stream_generation and
        first.progress.stream_id != 0 and first.progress.stream_id == current.progress.stream_id and
        first.progress.stream_generation != 0 and first.progress.stream_generation == current.progress.stream_generation;
}

pub fn run(ctx: anytype) i32 {
    ctx.sys.println("AUDIOD GAP: service48000Hz stereo-S16 signal480/null480/signal480; no speaker receipt");
    const deadline = ctx.sys.ticks() +| ctx.sys.ticksFromMilliseconds(3000);
    const timeout = r.time_contract.timeoutFinite(.{ .nanoseconds = 100_000_000 });
    var before: a.AudioServiceStatus = .{};
    if (ctx.sys.audioServiceStatus(&before) != 0) return fail(ctx, "service before");
    var stream = switch (ctx.audio.openStream(48000, 2, .s16le, 0x10000, timeout)) {
        .stream => |s| s,
        .timed_out => { transportFailure(ctx, "open", "timed-out", a.service_api_result_timeout, 0); return fail(ctx, "open"); },
        .no_service => |raw| { transportFailure(ctx, "open", "no-service", raw, 0); return fail(ctx, "open"); },
        .failure => |raw| { transportFailure(ctx, "open", "facade-failure", raw, 0); return fail(ctx, "open"); },
    };
    defer if (stream.valid()) {
        _ = stream.close(timeout);
    };
    var signal: [1920]u8 = undefined;
    @import("pattern.zig").fillSquare(&signal, 0);
    const silence = [_]u8{0} ** 1920;
    var first: a.AudioServiceStreamProgressState = .{};
    var current: a.AudioServiceStreamProgressState = .{};
    var key = a.AudioServiceStreamProgressRequest{ .stream_id = stream.stream_id };
    var close_attempts: u32 = 0;
    for ([_][]const u8{ &signal, &silence, &signal }, 0..) |bytes, index| {
        const result = stream.write(bytes, timeout);
        switch (result) {
            .written => |n| if (n != bytes.len) return fail(ctx, "complete PCM write"),
            else => return fail(ctx, "write"),
        }
        if (!query(ctx, &stream, key, &current, deadline, false, &close_attempts)) return fail(ctx, "progress");
        if (index == 0) {
            first = current;
            key.service_epoch = first.service_epoch;
            key.stream_generation = first.stream_generation;
        }
        if (!sameBackend(first, current) or current.progress.accepted_frames != (index + 1) * 480 or current.suppressed_bytes != 0 or
            current.progress.unconfirmed_frames != 0) return fail(ctx, "same identity and real null PCM");
        var status: a.AudioServiceStatus = .{};
        if (ctx.sys.audioServiceStatus(&status) != 0 or status.materialized_sessions != before.materialized_sessions + 1 or
            status.lazy_open_count != before.lazy_open_count + 1 or status.idle_close_count != before.idle_close_count)
            return fail(ctx, "no silent close/reopen");
    }
    var closed: a.AudioServiceStreamProgressState = .{};
    if (!query(ctx, &stream, key, &closed, deadline, true, &close_attempts)) return fail(ctx, "terminal close");
    if (!sameBackend(first, closed) or (closed.progress.flags & a.audio_progress_closed) == 0 or
        (closed.progress.flags & a.audio_progress_device_valid) == 0 or closed.progress.accepted_frames != 1440 or
        closed.progress.backend_frames != 1440 or closed.progress.submitted_frames != 1440 or closed.progress.consumed_frames != 1440 or
        closed.progress.queued_frames != 0 or closed.progress.unconfirmed_frames != 0 or closed.suppressed_bytes != 0)
        return fail(ctx, "actual complete terminal drain");
    stream.owned = false;
    stream.stream_id = 0;
    stream.frame_bytes = 0;
    if (stream.connection.close() != 0) return fail(ctx, "connection release");
    var after: a.AudioServiceStatus = .{};
    if (ctx.sys.audioServiceStatus(&after) != 0 or after.open_sessions != before.open_sessions or
        after.materialized_sessions != before.materialized_sessions or after.lazy_open_count != before.lazy_open_count + 1 or
        after.idle_close_count != before.idle_close_count or close_attempts == 0 or after.stream_close_requests != before.stream_close_requests + close_attempts or
        after.backend_fail != before.backend_fail) return fail(ctx, "exact resource baseline");
    var line: [320]u8 = undefined;
    ctx.sys.println(std.fmt.bufPrint(&line, "AUDIOD GAP accepted=1440 backend=1440 dma=1440 consumed=1440 silent=480 suppressed=0 unconfirmed=0 same-stream=1 opens=1 silent-closes=0 closed=1 resources=restored kernel-stream={d} generation={d} close-attempts={d} [OK]", .{ closed.progress.stream_id, closed.progress.stream_generation, close_attempts }) catch return fail(ctx, "format"));
    return 0;
}
