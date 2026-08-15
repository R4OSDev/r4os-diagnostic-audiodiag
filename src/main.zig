const r4os = @import("r4os");

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
    var pcm: [3840]u8 = undefined;
    fillSquare(&pcm);

    ctx.sys.println("AUDIOD");
    const perf_before = ctx.performance.summary() orelse {
        ctx.sys.println("Audio latency diagnostics: FAILED");
        ctx.sys.println("AUDIOD result: FAILED");
        return 1;
    };

    var status: r4os.abi.AudioServiceStatus = .{};
    const service_ready = switch (ctx.audio.status(r4os.time_contract.timeoutForever(), &status)) {
        .ok => true,
        else => false,
    };
    ctx.sys.print("AUDIOD service=AUDSVC status=");
    ctx.sys.println(if (service_ready) "OK" else "FAILED");
    if (!service_ready) {
        ctx.sys.println("Audio latency diagnostics: FAILED");
        ctx.sys.println("AUDIOD result: FAILED");
        return 1;
    }
    const service_before = status;

    var stream = switch (ctx.audio.openStream(48_000, 2, .s16le, 0x00010000, r4os.time_contract.timeoutForever())) {
        .stream => |value| value,
        else => {
            ctx.sys.println("audio_open_stream: FAILED");
            ctx.sys.println("Audio latency diagnostics: FAILED");
            ctx.sys.println("AUDIOD result: FAILED");
            return 1;
        },
    };
    ctx.sys.print("audio_open_stream: ");
    ctx.sys.printU64(stream.stream_id);
    ctx.sys.write("\r\n");
    const volume_ok = switch (stream.setVolume(0x00010000, r4os.time_contract.timeoutForever())) {
        .ok => true,
        else => false,
    };
    ctx.sys.print("audio_set_volume: ");
    ctx.sys.println(if (volume_ok) "OK" else "FAILED");

    const written: usize = switch (stream.write(pcm[0..], r4os.time_contract.timeoutForever())) {
        .written => |bytes| bytes,
        else => 0,
    };
    ctx.sys.print("audio_write: ");
    ctx.sys.printU64(written);
    ctx.sys.println(" bytes");
    ctx.sys.sleepTicks(15);

    const closed_ok = switch (stream.close(r4os.time_contract.timeoutForever())) {
        .ok => true,
        else => false,
    };
    ctx.sys.print("audio_close: ");
    ctx.sys.println(if (closed_ok) "OK" else "FAILED");

    var status_after: r4os.abi.AudioServiceStatus = .{};
    const service_status_after_ok = switch (ctx.audio.status(r4os.time_contract.timeoutForever(), &status_after)) {
        .ok => true,
        else => false,
    };
    const perf_after = ctx.performance.summary() orelse {
        ctx.sys.println("Audio latency diagnostics: FAILED");
        ctx.sys.println("AUDIOD result: FAILED");
        return 1;
    };

    const expected_written_u32: u32 = @intCast(pcm.len);
    const service_latency_ok = service_status_after_ok and
        status_after.requests > service_before.requests and
        status_after.stream_write_requests > service_before.stream_write_requests and
        status_after.bytes_written >= service_before.bytes_written + @as(u64, expected_written_u32) and
        status_after.last_write_bytes > 0 and
        status_after.last_write_bytes <= expected_written_u32 and
        status_after.request_total_ticks >= service_before.request_total_ticks and
        status_after.request_max_ticks >= status_after.request_last_ticks and
        status_after.write_request_total_ticks >= service_before.write_request_total_ticks and
        status_after.write_request_max_ticks >= status_after.write_request_last_ticks;
    const perf_latency_ok = perf_after.audio_stream_writes > perf_before.audio_stream_writes and
        perf_after.audio_stream_high_water_bytes > 0 and
        perf_after.audio_stream_write_total_ticks >= perf_before.audio_stream_write_total_ticks and
        perf_after.audio_stream_write_max_ticks >= perf_after.audio_stream_write_last_ticks and
        perf_after.audio_backend_write_total_ticks >= perf_before.audio_backend_write_total_ticks and
        perf_after.audio_backend_write_max_ticks >= perf_after.audio_backend_write_last_ticks and
        perf_after.audio_stream_dropped_bytes == perf_before.audio_stream_dropped_bytes;
    const ok = volume_ok and written == pcm.len and closed_ok and service_latency_ok and perf_latency_ok;
    ctx.sys.print("Audio latency diagnostics: ");
    ctx.sys.println(if (ok) "OK" else "FAILED");
    printLatency(&ctx, perf_after);
    printServiceLatency(&ctx, status_after);
    ctx.sys.print("AUDIOD result: ");
    ctx.sys.println(if (ok) "OK" else "FAILED");
    return if (ok) 0 else 1;
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

fn fillSquare(out: []u8) void {
    var frame: usize = 0;
    while (frame < out.len / 4) : (frame += 1) {
        const sample: i16 = if (((frame / 24) & 1) == 0) 3000 else -3000;
        writeI16(out, frame * 4, sample);
        writeI16(out, frame * 4 + 2, sample);
    }
}

fn writeI16(out: []u8, index: usize, sample: i16) void {
    const bits: u16 = @bitCast(sample);
    out[index] = @intCast(bits & 0xFF);
    out[index + 1] = @intCast(bits >> 8);
}
