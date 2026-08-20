const r4os = @import("r4os");
const pattern = @import("pattern.zig");

const DiagApi = struct {
    sys: r4os.r4sys.Context,
    audio: r4os.Audio,
    performance: r4os.PerformanceView,

    fn init(app: *r4os.App) ?DiagApi {
        return .{ .sys = app.system(), .audio = app.audio() orelse return null, .performance = (app.devices() orelse return null).performance() };
    }
};

pub fn r4_app_main(app: *r4os.App) i32 {
    var ctx = DiagApi.init(app) orelse return r4os.abi.err_no_group;
    const long_mode = containsIgnoreCase(app.args(), "/LONG");
    var pcm: [pattern.quantum_bytes]u8 = undefined;
    var variable_pcm: [pattern.quantum_bytes]u8 = undefined;

    ctx.sys.println("AUDIOD");
    const perf_before = ctx.performance.summary() orelse return fail(&ctx, "performance summary before playback");

    var status: r4os.abi.AudioServiceStatus = .{};
    const service_ready = waitForAudioService(&ctx, &status);
    ctx.sys.print("AUDIOD service=AUDSVC status=");
    ctx.sys.println(if (service_ready) "OK" else "FAILED");
    if (!service_ready) return fail(&ctx, "audio service status");
    const service_before = status;

    var stream = switch (ctx.audio.openStream(pattern.sample_rate, pattern.channels, .s16le, 0x00010000, r4os.time_contract.timeoutForever())) {
        .stream => |value| value,
        else => return fail(&ctx, "audio_open_stream"),
    };
    ctx.sys.print("audio_open_stream: ");
    ctx.sys.printU64(stream.stream_id);
    ctx.sys.write("\r\n");
    const volume_ok = switch (stream.setVolume(0x00010000, r4os.time_contract.timeoutForever())) {
        .ok => true,
        else => false,
    };

    var first_frame: u64 = 0;
    var expected_bytes: u64 = 0;
    var write_count: u64 = 0;
    var writes_ok = true;
    const quanta = if (long_mode) pattern.long_quanta else pattern.capture_quanta;
    var quantum: usize = 0;
    while (quantum < quanta) : (quantum += 1) {
        if (long_mode and !waitForBackendQueueRoom(&ctx, 16)) {
            writes_ok = false;
            break;
        }
        pattern.fillSquare(&pcm, first_frame);
        const written = switch (stream.write(&pcm, r4os.time_contract.timeoutForever())) {
            .written => |bytes| bytes,
            else => 0,
        };
        if (written != pcm.len) {
            writes_ok = false;
            break;
        }
        first_frame += pattern.quantum_frames;
        expected_bytes += pcm.len;
        write_count += 1;
    }

    if (!long_mode and writes_ok) {
        for (pattern.variable_frames) |frames| {
            const bytes = frames * pattern.frame_bytes;
            pattern.fillSquare(variable_pcm[0..bytes], first_frame);
            const written = switch (stream.write(variable_pcm[0..bytes], r4os.time_contract.timeoutForever())) {
                .written => |count| count,
                else => 0,
            };
            if (written != bytes) {
                writes_ok = false;
                break;
            }
            first_frame += frames;
            expected_bytes += bytes;
            write_count += 1;
        }
    }

    const closed_ok = switch (stream.close(r4os.time_contract.timeoutForever())) {
        .ok => true,
        else => false,
    };

    var status_after: r4os.abi.AudioServiceStatus = .{};
    const service_status_after_ok = switch (ctx.audio.status(r4os.time_contract.timeoutForever(), &status_after)) {
        .ok => true,
        else => false,
    };
    const perf_after = ctx.performance.summary() orelse return fail(&ctx, "performance summary after playback");

    const upstream_dropped = delta(perf_before.audio_stream_dropped_bytes, perf_after.audio_stream_dropped_bytes);
    const backend_underruns = delta(perf_before.audio_backend_underruns, perf_after.audio_backend_underruns);
    const backend_errors = delta(perf_before.audio_backend_errors, perf_after.audio_backend_errors);
    const backend_failures = delta(perf_before.audio_backend_fail, perf_after.audio_backend_fail);
    const silence_periods = delta(perf_before.audio_backend_silence_refills, perf_after.audio_backend_silence_refills);

    const service_ok = service_status_after_ok and
        status_after.requests > service_before.requests and
        status_after.stream_write_requests >= service_before.stream_write_requests + write_count and
        status_after.bytes_written >= service_before.bytes_written + expected_bytes and
        status_after.last_write_bytes > 0 and
        status_after.last_write_bytes <= variable_pcm.len and
        status_after.request_total_ticks >= service_before.request_total_ticks and
        status_after.request_max_ticks >= status_after.request_last_ticks and
        status_after.write_request_total_ticks >= service_before.write_request_total_ticks and
        status_after.write_request_max_ticks >= status_after.write_request_last_ticks;
    const performance_ok = perf_after.audio_stream_writes >= perf_before.audio_stream_writes + write_count and
        perf_after.audio_backend_write_calls >= perf_before.audio_backend_write_calls + write_count and
        perf_after.audio_backend_refills > perf_before.audio_backend_refills and
        perf_after.audio_stream_write_total_ticks >= perf_before.audio_stream_write_total_ticks and
        perf_after.audio_backend_write_total_ticks >= perf_before.audio_backend_write_total_ticks;
    const path_ok = upstream_dropped == 0 and backend_underruns == 0 and backend_errors == 0 and backend_failures == 0 and silence_periods == 0;
    const ok = volume_ok and writes_ok and closed_ok and service_ok and performance_ok and path_ok;

    ctx.sys.print("AUDIOD pattern: mode=");
    ctx.sys.print(if (long_mode) "long" else "capture");
    ctx.sys.print(" frames=");
    ctx.sys.printU64(first_frame);
    ctx.sys.print(" writes=");
    ctx.sys.printU64(write_count);
    ctx.sys.print(" bytes=");
    ctx.sys.printU64(expected_bytes);
    ctx.sys.write("\r\n");
    printPathDeltas(&ctx, upstream_dropped, backend_underruns, backend_errors, backend_failures, silence_periods);
    printLatency(&ctx, perf_after);
    printServiceLatency(&ctx, status_after);
    ctx.sys.print("Audio PCM continuity diagnostics: ");
    ctx.sys.println(if (ok) "OK" else "FAILED");
    ctx.sys.print("AUDIOD result: ");
    ctx.sys.println(if (ok) "OK" else "FAILED");
    return if (ok) 0 else 1;
}

fn waitForAudioService(ctx: *const DiagApi, status: *r4os.abi.AudioServiceStatus) bool {
    const state = ctx.sys.timeState();
    const deadline = ctx.sys.ticks() +| @as(u64, @max(state.monotonic_hz, 1)) * 30;
    while (ctx.sys.ticks() < deadline) {
        switch (ctx.audio.status(r4os.time_contract.timeoutForever(), status)) {
            .ok => return true,
            else => ctx.sys.sleepTicks(1),
        }
    }
    return false;
}

fn waitForBackendQueueRoom(ctx: *const DiagApi, target_periods: u64) bool {
    const state = ctx.sys.timeState();
    const deadline = ctx.sys.ticks() +| @as(u64, @max(state.monotonic_hz, 1)) * 5;
    while (ctx.sys.ticks() < deadline) {
        const summary = ctx.performance.summary() orelse return false;
        if (summary.audio_backend_queued_buffers < target_periods) return true;
        ctx.sys.sleepTicks(1);
    }
    return false;
}

fn fail(ctx: *const DiagApi, stage: []const u8) i32 {
    ctx.sys.print("AUDIOD failure stage: ");
    ctx.sys.println(stage);
    ctx.sys.println("Audio PCM continuity diagnostics: FAILED");
    ctx.sys.println("AUDIOD result: FAILED");
    return 1;
}

fn printPathDeltas(ctx: *const DiagApi, upstream_dropped: u64, backend_underruns: u64, backend_errors: u64, backend_failures: u64, silence_periods: u64) void {
    ctx.sys.print("AUDIOD path: upstreamDropped=");
    ctx.sys.printU64(upstream_dropped);
    ctx.sys.print(" driverUnderruns=");
    ctx.sys.printU64(backend_underruns);
    ctx.sys.print(" driverErrors=");
    ctx.sys.printU64(backend_errors);
    ctx.sys.print(" backendFail=");
    ctx.sys.printU64(backend_failures);
    ctx.sys.print(" silencePeriods=");
    ctx.sys.printU64(silence_periods);
    ctx.sys.write("\r\n");
}

fn printLatency(ctx: *const DiagApi, summary: r4os.abi.ProgramPerformanceSummary) void {
    ctx.sys.print("AUDIOD latency: writes=");
    ctx.sys.printU64(summary.audio_stream_writes);
    ctx.sys.print(" high=");
    ctx.sys.printU64(summary.audio_stream_high_water_bytes);
    ctx.sys.print(" dropped=");
    ctx.sys.printU64(summary.audio_stream_dropped_bytes);
    ctx.sys.print(" streamTicks=");
    ctx.sys.printU64(summary.audio_stream_write_last_ticks);
    ctx.sys.print("/");
    ctx.sys.printU64(summary.audio_stream_write_max_ticks);
    ctx.sys.print(" backendTicks=");
    ctx.sys.printU64(summary.audio_backend_write_last_ticks);
    ctx.sys.print("/");
    ctx.sys.printU64(summary.audio_backend_write_max_ticks);
    ctx.sys.print(" refills=");
    ctx.sys.printU64(summary.audio_backend_refills);
    ctx.sys.print(" queued=");
    ctx.sys.printU64(summary.audio_backend_queued_buffers);
    ctx.sys.write("\r\n");
}

fn printServiceLatency(ctx: *const DiagApi, status: r4os.abi.AudioServiceStatus) void {
    ctx.sys.print("AUDIOD service latency: reqTicks=");
    ctx.sys.printU64(status.request_last_ticks);
    ctx.sys.print("/");
    ctx.sys.printU64(status.request_max_ticks);
    ctx.sys.print(" writeTicks=");
    ctx.sys.printU64(status.write_request_last_ticks);
    ctx.sys.print("/");
    ctx.sys.printU64(status.write_request_max_ticks);
    ctx.sys.print(" lastBytes=");
    ctx.sys.printU64(@intCast(status.last_write_bytes));
    ctx.sys.write("\r\n");
}

fn delta(before: u64, after: u64) u64 {
    return if (after >= before) after - before else 0;
}

fn containsIgnoreCase(value: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or value.len < needle.len) return false;
    var offset: usize = 0;
    while (offset + needle.len <= value.len) : (offset += 1) {
        var index: usize = 0;
        while (index < needle.len and upper(value[offset + index]) == upper(needle[index])) : (index += 1) {}
        if (index == needle.len) return true;
    }
    return false;
}

fn upper(value: u8) u8 {
    return if (value >= 'a' and value <= 'z') value - ('a' - 'A') else value;
}
