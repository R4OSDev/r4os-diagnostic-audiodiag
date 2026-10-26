const r4os = @import("r4os");
const pattern = @import("pattern.zig");
const master_persist_wait_ms: u64 = 15_000;
const evidence_path_capacity: usize = 128;

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
    const args = app.args();
    const long_mode = containsIgnoreCase(args, "/LONG");
    var evidence_path: [evidence_path_capacity:0]u8 = .{0} ** evidence_path_capacity;
    const evidence_requested = argumentSpecified(args, "OUT");
    const evidence_path_value = argumentValue(args, "OUT");
    if (evidence_requested and evidence_path_value == null) {
        ctx.sys.println("AUDIOD option: FAILED /OUT requires a non-empty path shorter than 128 bytes without spaces");
        return 2;
    }
    if (evidence_path_value) |value| copyFixedZ(evidence_path[0..], value);
    var silence: [pattern.quantum_bytes]u8 = .{0} ** pattern.quantum_bytes;
    var pcm: [pattern.quantum_bytes]u8 = undefined;
    var variable_pcm: [pattern.quantum_bytes]u8 = undefined;

    ctx.sys.println("AUDIOD");
    const perf_before = ctx.performance.summary() orelse return fail(&ctx, "performance summary before playback");
    const work_before = ctx.performance.driverWork(0) orelse return fail(&ctx, "driver work before playback");

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

    const silent_written = switch (stream.write(&silence, r4os.time_contract.timeoutForever())) {
        .written => |bytes| bytes,
        else => 0,
    };
    var status_silent: r4os.abi.AudioServiceStatus = .{};
    const silent_status_ok = switch (ctx.audio.status(r4os.time_contract.timeoutForever(), &status_silent)) {
        .ok => true,
        else => false,
    };
    const lazy_silence_ok = silent_written == silence.len and silent_status_ok and
        status_silent.materialized_sessions == service_before.materialized_sessions and
        status_silent.lazy_open_count == service_before.lazy_open_count and
        status_silent.silence_write_count > service_before.silence_write_count and
        status_silent.silence_bytes >= service_before.silence_bytes + silence.len;
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
        const written = writePcmFully(&ctx, &stream, &pcm);
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
            const written = writePcmFully(&ctx, &stream, variable_pcm[0..bytes]);
            if (written != bytes) {
                writes_ok = false;
                break;
            }
            first_frame += frames;
            expected_bytes += bytes;
            write_count += 1;
        }
    }

    var status_signal: r4os.abi.AudioServiceStatus = .{};
    const signal_status_ok = switch (ctx.audio.status(r4os.time_contract.timeoutForever(), &status_signal)) {
        .ok => true,
        else => false,
    };
    const signal_materialized_ok = signal_status_ok and write_count > 0 and
        status_signal.materialized_sessions > service_before.materialized_sessions and
        status_signal.lazy_open_count > service_before.lazy_open_count and
        status_signal.last_write_bytes > 0 and
        status_signal.last_write_bytes <= variable_pcm.len;

    // Fast producers can submit the complete short capture before the first
    // DMA interrupt. Observe productive asynchronous work before idle/Close
    // switches the driver to synchronous drain; otherwise this check depends
    // on incidental producer latency rather than IRQ/worker correctness.
    const asynchronous_progress_ok = writes_ok and waitForDeadlineProgress(&ctx, work_before.deadline_submitted, work_before.deadline_started);

    const idle_written = switch (stream.write(&silence, r4os.time_contract.timeoutForever())) {
        .written => |bytes| bytes,
        else => 0,
    };

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
    const work_after = ctx.performance.driverWork(0) orelse return fail(&ctx, "driver work after playback");

    const upstream_dropped = delta(perf_before.audio_stream_dropped_bytes, perf_after.audio_stream_dropped_bytes);
    const backend_underruns = delta(perf_before.audio_backend_underruns, perf_after.audio_backend_underruns);
    const backend_errors = delta(perf_before.audio_backend_errors, perf_after.audio_backend_errors);
    const backend_failures = delta(perf_before.audio_backend_fail, perf_after.audio_backend_fail);
    const silence_periods = delta(perf_before.audio_backend_silence_refills, perf_after.audio_backend_silence_refills);

    const service_ok = service_status_after_ok and
        status_after.requests > service_before.requests and
        status_after.stream_write_requests >= service_before.stream_write_requests + write_count + 2 and
        status_after.bytes_written >= service_before.bytes_written + expected_bytes and
        status_after.materialized_sessions == service_before.materialized_sessions and
        status_after.idle_close_count > service_before.idle_close_count and
        status_after.silence_write_count >= service_before.silence_write_count + 2 and
        status_after.silence_bytes >= service_before.silence_bytes + silence.len * 2 and
        status_after.request_total_ticks >= service_before.request_total_ticks and
        status_after.request_max_ticks >= status_after.request_last_ticks and
        status_after.write_request_total_ticks >= service_before.write_request_total_ticks and
        status_after.write_request_max_ticks >= status_after.write_request_last_ticks;
    const performance_ok = perf_after.audio_stream_writes >= perf_before.audio_stream_writes + write_count and
        // The worker may coalesce input packets. Exact admitted byte work,
        // zero loss/errors and acknowledged drain remain separate requirements.
        perf_after.audio_backend_write_calls > perf_before.audio_backend_write_calls and
        perf_after.audio_backend_refills > perf_before.audio_backend_refills and
        perf_after.audio_stream_write_total_ticks >= perf_before.audio_stream_write_total_ticks and
        perf_after.audio_backend_write_total_ticks >= perf_before.audio_backend_write_total_ticks;
    const deadline_ok = asynchronous_progress_ok and work_after.version >= 2 and work_after.deadline_worker_count == 1 and
        work_after.deadline_worker_started != 0 and
        work_after.deadline_submitted > work_before.deadline_submitted and
        work_after.deadline_started > work_before.deadline_started and
        work_after.deadline_misses == work_before.deadline_misses and
        work_after.deadline_budget_overruns == work_before.deadline_budget_overruns and
        work_after.deadline_queue_rejections == work_before.deadline_queue_rejections;
    const path_ok = upstream_dropped == 0 and backend_underruns == 0 and backend_errors == 0 and backend_failures == 0 and silence_periods == 0;
    const continuity_ok = lazy_silence_ok and volume_ok and writes_ok and signal_materialized_ok and idle_written == silence.len and closed_ok and service_ok and performance_ok and deadline_ok and path_ok;

    var checks: [256]u8 = undefined;
    ctx.sys.println(@import("std").fmt.bufPrint(&checks, "AUDIOD checks: lazy={d} volume={d} writes={d} signal={d} service={d} performance={d} deadline={d} path={d} backendCalls={d}", .{ @intFromBool(lazy_silence_ok), @intFromBool(volume_ok), @intFromBool(writes_ok), @intFromBool(signal_materialized_ok), @intFromBool(service_ok), @intFromBool(performance_ok), @intFromBool(deadline_ok), @intFromBool(path_ok), delta(perf_before.audio_backend_write_calls, perf_after.audio_backend_write_calls) }) catch "AUDIOD checks unavailable");

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
    printIdlePath(&ctx, status_after, service_before);
    printDeadlinePath(&ctx, work_after, work_before);
    printLatency(&ctx, perf_after);
    printServiceLatency(&ctx, status_after);
    ctx.sys.print("Audio PCM continuity diagnostics: ");
    ctx.sys.println(if (continuity_ok) "OK" else "FAILED");
    const master_ok = runMasterContract(&ctx, pcm[0..]);
    const lifecycle_ok = if (master_ok) runLifecycleContract(&ctx) else false;
    const hda_diagnostic_ok = if (lifecycle_ok) waitForHdaDiagnostic(&ctx) else false;
    const evidence_ok = if (evidence_path_value != null and hda_diagnostic_ok)
        exportHdaEvidence(&ctx, @ptrCast(&evidence_path), evidence_path_value.?)
    else
        evidence_path_value == null;
    if (evidence_path_value != null and !hda_diagnostic_ok) ctx.sys.println("AUDIOD HDA evidence: FAILED diagnostic-unavailable");
    const ok = continuity_ok and master_ok and lifecycle_ok and hda_diagnostic_ok and evidence_ok;
    ctx.sys.print("AUDIOD result: ");
    ctx.sys.println(if (ok) "OK" else "FAILED");
    return if (ok) 0 else 1;
}

fn runMasterContract(ctx: *const DiagApi, pcm: []const u8) bool {
    var original: r4os.abi.AudioServiceMasterState = .{};
    if (ctx.sys.audioServiceMasterState(&original) != r4os.abi.service_api_result_ok) return masterFail(ctx, "state");
    var restore_needed = true;
    defer {
        if (restore_needed) {
            var ignored: r4os.abi.AudioServiceMasterState = .{};
            _ = restoreMasterState(&ctx.sys, original, &ignored);
        }
    }

    var status: r4os.abi.AudioServiceStatus = .{};
    if (ctx.sys.audioServiceSetMasterVolume(0x0000_8000, &status) != r4os.abi.service_api_result_ok or
        status.master_volume_fixed != 0x0000_8000)
        return masterFail(ctx, "volume");

    var request = r4os.abi.AudioServiceMasterRequest{
        .flags = r4os.abi.audio_master_request_flag_set_muted | r4os.abi.audio_master_request_flag_muted,
    };
    var state: r4os.abi.AudioServiceMasterState = .{};
    if (ctx.sys.audioServiceSetMasterState(&request, &state) != r4os.abi.service_api_result_ok or
        (state.flags & r4os.abi.audio_master_state_flag_muted) == 0 or state.effective_volume_fixed != 0)
        return masterFail(ctx, "mute");
    if (ctx.sys.audioServiceSetMasterVolume(0x0000_6000, &status) != r4os.abi.service_api_result_ok or
        ctx.sys.audioServiceMasterState(&state) != r4os.abi.service_api_result_ok or
        (state.flags & r4os.abi.audio_master_state_flag_muted) == 0 or state.selected_volume_fixed != 0x0000_6000)
        return masterFail(ctx, "legacy-muted");
    request = .{ .flags = r4os.abi.audio_master_request_flag_set_volume, .fixed_volume = 0x0000_8000 };
    if (ctx.sys.audioServiceSetMasterState(&request, &state) != r4os.abi.service_api_result_ok or
        (state.flags & r4os.abi.audio_master_state_flag_muted) != 0 or state.effective_volume_fixed != 0x0000_8000)
        return masterFail(ctx, "positive-unmute");
    if (!waitMasterPersisted(&ctx.sys, original.persist_writes, &state, ctx.sys.ticksFromMilliseconds(master_persist_wait_ms))) {
        ctx.sys.print("AUDIOD master persistence: flags=");
        ctx.sys.printU64(state.flags);
        ctx.sys.print(" writes=");
        ctx.sys.printU64(state.persist_writes);
        ctx.sys.print(" failures=");
        ctx.sys.printU64(state.persist_failures);
        ctx.sys.print(" changes=");
        ctx.sys.printU64(state.master_changes);
        ctx.sys.print(" loads=");
        ctx.sys.printU64(state.config_loads);
        ctx.sys.println("");
        return masterFail(ctx, "initial-persist");
    }

    const first_raw = ctx.sys.audioServiceOpenStream(pattern.sample_rate, pattern.channels, .s16le);
    if (first_raw < 0) return masterFail(ctx, "stream-a");
    var first: u32 = @intCast(first_raw);
    defer {
        if (first != 0) _ = ctx.sys.audioServiceClose(first);
    }
    const second_raw = ctx.sys.audioServiceOpenStream(pattern.sample_rate, pattern.channels, .s16le);
    if (second_raw < 0) return masterFail(ctx, "stream-b");
    var second: u32 = @intCast(second_raw);
    defer {
        if (second != 0) _ = ctx.sys.audioServiceClose(second);
    }
    const sample = pcm[0..@min(pcm.len, 256)];
    if (ctx.sys.audioServiceSetVolume(first, 0x0001_0000) < 0 or
        ctx.sys.audioServiceSetVolume(second, 0x0000_8000) < 0 or
        ctx.sys.audioServiceWrite(first, sample) <= 0 or ctx.sys.audioServiceWrite(second, sample) <= 0)
        return masterFail(ctx, "streams");
    if (ctx.sys.audioServiceStatus(&status) != r4os.abi.service_api_result_ok or status.materialized_sessions < 2)
        return masterFail(ctx, "stream-status");
    const backend_before = status.backend_ok;
    request = .{ .flags = r4os.abi.audio_master_request_flag_set_volume, .fixed_volume = 0x0000_7000 };
    if (ctx.sys.audioServiceSetMasterState(&request, &state) != r4os.abi.service_api_result_ok or
        ctx.sys.audioServiceStatus(&status) != r4os.abi.service_api_result_ok or status.backend_ok < backend_before + 2)
        return masterFail(ctx, "fanout");
    if (ctx.sys.audioServiceClose(first) != 0 or ctx.sys.audioServiceClose(second) != 0) return masterFail(ctx, "stream-close");
    first = 0;
    second = 0;

    if (ctx.sys.audioServiceMasterState(&state) != r4os.abi.service_api_result_ok) return masterFail(ctx, "persist-baseline");
    const writes_before = state.persist_writes;
    request = .{
        .flags = r4os.abi.audio_master_request_flag_set_volume | r4os.abi.audio_master_request_flag_set_muted | r4os.abi.audio_master_request_flag_muted,
        .fixed_volume = 0x0000_5000,
    };
    if (ctx.sys.audioServiceSetMasterState(&request, &state) != r4os.abi.service_api_result_ok or
        !waitMasterPersisted(&ctx.sys, writes_before, &state, ctx.sys.ticksFromMilliseconds(master_persist_wait_ms)))
    {
        return masterFail(ctx, "persist");
    }
    const persisted_epoch = state.service_epoch;

    var info: r4os.abi.ServiceInfo = .{};
    const restart = ctx.sys.serviceRestart("AUDSVC", &info);
    if (restart != r4os.abi.service_api_result_ok and restart != r4os.abi.service_api_result_running)
        return masterFail(ctx, "restart");
    if (!waitServiceStatus(&ctx.sys, &status, ctx.sys.ticksFromMilliseconds(5000)) or status.open_sessions != 0)
        return masterFail(ctx, "restart-status");
    if (!waitMasterState(&ctx.sys, &state, ctx.sys.ticksFromMilliseconds(5000)) or
        state.service_epoch == persisted_epoch or state.selected_volume_fixed != 0x0000_5000 or
        (state.flags & r4os.abi.audio_master_state_flag_muted) == 0 or state.effective_volume_fixed != 0)
        return masterFail(ctx, "restart-state");

    const restore_writes = state.persist_writes;
    if (!restoreMasterState(&ctx.sys, original, &state) or
        !waitMasterPersisted(&ctx.sys, restore_writes, &state, ctx.sys.ticksFromMilliseconds(master_persist_wait_ms)))
        return masterFail(ctx, "restore");
    restore_needed = false;
    ctx.sys.println("AUDIOD master: OK volume+mute streams=2 fanout=common persistence=restart");
    return true;
}

fn runLifecycleContract(ctx: *const DiagApi) bool {
    const cycles: usize = 4;
    var before: r4os.abi.AudioServiceStatus = .{};
    if (ctx.sys.audioServiceStatus(&before) != r4os.abi.service_api_result_ok or
        before.open_sessions != 0 or before.materialized_sessions != 0)
        return lifecycleFail(ctx, "baseline");
    const perf_before = ctx.performance.summary() orelse return lifecycleFail(ctx, "performance-before");

    // Keep the direct R4SYS request including its header below the service
    // message bound. A partial hardware period also exercises tail drain.
    var sample: [256]u8 = undefined;
    var cycle: usize = 0;
    while (cycle < cycles) : (cycle += 1) {
        pattern.fillSquare(&sample, @as(u64, @intCast(cycle * pattern.quantum_frames)));
        const raw = ctx.sys.audioServiceOpenStream(pattern.sample_rate, pattern.channels, .s16le);
        if (raw < 0) return lifecycleFail(ctx, "open");
        const stream_id: u32 = @intCast(raw);
        var close_needed = true;
        defer {
            if (close_needed) _ = ctx.sys.audioServiceClose(stream_id);
        }

        if (ctx.sys.audioServiceSetVolume(stream_id, 0x0001_0000) < 0 or
            !writeLifecycleSample(ctx, stream_id, sample[0..]))
            return lifecycleFail(ctx, "write");

        var active: r4os.abi.AudioServiceStatus = .{};
        if (ctx.sys.audioServiceStatus(&active) != r4os.abi.service_api_result_ok or
            active.open_sessions != before.open_sessions + 1 or
            active.materialized_sessions != before.materialized_sessions + 1 or
            active.last_write_bytes != sample.len)
            return lifecycleFail(ctx, "active-state");

        if (ctx.sys.audioServiceClose(stream_id) != r4os.abi.service_api_result_ok) return lifecycleFail(ctx, "close");
        close_needed = false;
        var closed: r4os.abi.AudioServiceStatus = .{};
        if (ctx.sys.audioServiceStatus(&closed) != r4os.abi.service_api_result_ok or
            closed.open_sessions != before.open_sessions or
            closed.materialized_sessions != before.materialized_sessions or
            closed.backend_fail != before.backend_fail)
            return lifecycleFail(ctx, "closed-state");
    }

    var after: r4os.abi.AudioServiceStatus = .{};
    if (ctx.sys.audioServiceStatus(&after) != r4os.abi.service_api_result_ok or
        after.stream_open_requests < before.stream_open_requests + @as(u64, cycles) or
        after.stream_write_requests < before.stream_write_requests + @as(u64, cycles) or
        after.stream_close_requests < before.stream_close_requests + @as(u64, cycles) or
        after.open_sessions != 0 or after.materialized_sessions != 0)
        return lifecycleFail(ctx, "counters");
    const perf_after = ctx.performance.summary() orelse return lifecycleFail(ctx, "performance-after");
    if (perf_after.audio_stream_dropped_bytes != perf_before.audio_stream_dropped_bytes or
        perf_after.audio_backend_underruns != perf_before.audio_backend_underruns or
        perf_after.audio_backend_errors != perf_before.audio_backend_errors or
        perf_after.audio_backend_fail != perf_before.audio_backend_fail)
        return lifecycleFail(ctx, "backend-path");

    ctx.sys.println("AUDIOD lifecycle: OK cycles=4 restart=replay multi=2 stale=none");
    return true;
}

fn lifecycleFail(ctx: *const DiagApi, stage: []const u8) bool {
    ctx.sys.print("AUDIOD lifecycle: FAILED stage=");
    ctx.sys.println(stage);
    return false;
}

fn writeLifecycleSample(ctx: *const DiagApi, stream_id: u32, sample: []const u8) bool {
    const started = ctx.sys.ticks();
    const max_ticks = ctx.sys.ticksFromMilliseconds(5000);
    const poll_ticks = @max(ctx.sys.ticksFromMilliseconds(10), 1);
    while (ctx.sys.ticks() -| started < max_ticks) {
        const result = ctx.sys.audioServiceWrite(stream_id, sample);
        if (result == @as(i32, @intCast(sample.len))) return true;
        if (result != r4os.abi.service_api_result_busy) {
            ctx.sys.print("AUDIOD lifecycle write result=");
            printSigned(ctx, result);
            ctx.sys.write("\r\n");
            printHdaRecord(ctx, "HDA.DIAG write-reject");
            return false;
        }
        ctx.sys.sleepTicks(poll_ticks);
    }
    ctx.sys.println("AUDIOD lifecycle write result=busy-timeout");
    return false;
}

fn printSigned(ctx: *const DiagApi, value: i32) void {
    if (value < 0) {
        ctx.sys.print("-");
        const wide: i64 = value;
        ctx.sys.printU64(@intCast(-wide));
    } else {
        ctx.sys.printU64(@intCast(value));
    }
}

fn printHdaRecord(ctx: *const DiagApi, search: []const u8) void {
    var query = r4os.abi.LogServiceRecordQuery{
        .source_id = r4os.abi.log_service_source_driver,
        .severity_min = r4os.abi.log_severity_debug,
    };
    copyFixedZ(query.search[0..], search);
    const started = ctx.sys.ticks();
    const max_ticks = ctx.sys.ticksFromMilliseconds(1000);
    while (ctx.sys.ticks() -| started < max_ticks) {
        var page = r4os.abi.LogServiceRecordPage{};
        if (ctx.sys.logServiceRecords(&query, &page) == r4os.abi.service_api_result_ok and page.count != 0) {
            const record = &page.records[page.count - 1];
            const text_len = @min(@as(usize, record.text_len), record.text.len);
            ctx.sys.print("AUDIOD driver record: ");
            ctx.sys.write(record.text[0..text_len]);
            ctx.sys.write("\r\n");
            return;
        }
        ctx.sys.sleepTicks(@max(ctx.sys.ticksFromMilliseconds(50), 1));
    }
    ctx.sys.println("AUDIOD driver record: missing");
}

fn waitForHdaDiagnostic(ctx: *const DiagApi) bool {
    const core_fields = [_][]const u8{
        "stage=ready", " pci=", " id=", " gcap=", " str=", " tr=", " codec=", " afg=", " route=", " pin=", " fmt=",
    };
    const runtime_fields = [_][]const u8{
        "phase=close", " irq=", " pos=", " pmis=", " pfb=", " wr=", " und=", " fifo=", " dese=", " prec=", " rec=", " to=", " drain=", " wdrop=", " own=",
    };
    const poll_ticks = @max(ctx.sys.ticksFromMilliseconds(100), 1);
    const started = ctx.sys.ticks();
    const max_ticks = ctx.sys.ticksFromMilliseconds(5000);
    var core_ok = false;
    var runtime_ok = false;
    while (ctx.sys.ticks() -| started < max_ticks) {
        if (!core_ok) core_ok = hdaRecordHasFields(&ctx.sys, "HDA.DIAG core", core_fields[0..]);
        if (!runtime_ok) runtime_ok = hdaRecordHasFields(&ctx.sys, "HDA.DIAG run phase=close", runtime_fields[0..]);
        if (core_ok and runtime_ok) {
            ctx.sys.println("AUDIOD HDA diagnostic: OK core=selection+transport+route+format runtime=irq+position counters=separate");
            return true;
        }
        ctx.sys.sleepTicks(poll_ticks);
    }
    ctx.sys.print("AUDIOD HDA diagnostic: FAILED core=");
    ctx.sys.print(if (core_ok) "ok" else "missing");
    ctx.sys.print(" runtime=");
    ctx.sys.println(if (runtime_ok) "ok" else "missing");
    return false;
}

fn hdaRecordHasFields(ctx: *const r4os.r4sys.Context, search: []const u8, fields: []const []const u8) bool {
    var query = r4os.abi.LogServiceRecordQuery{
        .source_id = r4os.abi.log_service_source_driver,
        .severity_min = r4os.abi.log_severity_debug,
    };
    copyFixedZ(query.search[0..], search);
    var page = r4os.abi.LogServiceRecordPage{};
    if (ctx.logServiceRecords(&query, &page) != r4os.abi.service_api_result_ok) return false;
    var record_index: usize = 0;
    while (record_index < page.count) : (record_index += 1) {
        const record = &page.records[record_index];
        const text_len = @min(@as(usize, record.text_len), record.text.len);
        const text = record.text[0..text_len];
        var field_index: usize = 0;
        while (field_index < fields.len and containsText(text, fields[field_index])) : (field_index += 1) {}
        if (field_index == fields.len) return true;
    }
    return false;
}

fn exportHdaEvidence(ctx: *const DiagApi, path: [*:0]const u8, path_text: []const u8) bool {
    const candidate_count = hdaRecordCount(&ctx.sys, "HDA.R4D controller candidate") orelse 0;
    const selected_count = hdaRecordCount(&ctx.sys, "HDA.R4D selected controller") orelse 0;
    const core_count = hdaRecordCount(&ctx.sys, "HDA.DIAG core") orelse 0;
    const runtime_count = hdaRecordCount(&ctx.sys, "HDA.DIAG run phase=close") orelse 0;
    if (candidate_count == 0 or selected_count == 0 or core_count == 0 or runtime_count == 0) {
        ctx.sys.print("AUDIOD HDA evidence: FAILED candidates=");
        ctx.sys.printU64(candidate_count);
        ctx.sys.print(" selected=");
        ctx.sys.printU64(selected_count);
        ctx.sys.print(" core=");
        ctx.sys.printU64(core_count);
        ctx.sys.print(" runtime=");
        ctx.sys.printU64(runtime_count);
        ctx.sys.println("");
        return false;
    }

    var query = r4os.abi.LogServiceRecordQuery{
        .source_id = r4os.abi.log_service_source_driver,
        .severity_min = r4os.abi.log_severity_debug,
    };
    copyFixedZ(query.search[0..], "HDA");
    _ = ctx.sys.fileDelete(path);
    var first = true;
    var pages: usize = 0;
    var total_bytes: usize = 0;
    while (pages < 64) : (pages += 1) {
        var page = r4os.abi.LogServiceExportPage{};
        if (ctx.sys.logServiceExport(&query, &page) != r4os.abi.service_api_result_ok) return hdaExportFail(ctx, "query");
        const len = @min(@as(usize, page.bytes), page.text.len);
        if (len != 0) {
            const written = if (first) ctx.sys.fileWrite(path, page.text[0..len]) else ctx.sys.fileAppend(path, page.text[0..len]);
            if (written != @as(i32, @intCast(len))) return hdaExportFail(ctx, "write");
            first = false;
            total_bytes += len;
        }
        if ((page.flags & r4os.abi.log_service_page_flag_more) == 0) break;
        if (page.next_index <= query.start_index) return hdaExportFail(ctx, "pagination");
        query.start_index = page.next_index;
    }
    if (first or pages >= 64) return hdaExportFail(ctx, if (first) "empty" else "page-limit");

    ctx.sys.print("AUDIOD HDA evidence: OK candidates=");
    ctx.sys.printU64(candidate_count);
    ctx.sys.print(" selected=");
    ctx.sys.printU64(selected_count);
    ctx.sys.print(" core=");
    ctx.sys.printU64(core_count);
    ctx.sys.print(" runtime=");
    ctx.sys.printU64(runtime_count);
    ctx.sys.print(" bytes=");
    ctx.sys.printU64(total_bytes);
    ctx.sys.print(" path=");
    ctx.sys.println(path_text);
    return true;
}

fn hdaRecordCount(ctx: *const r4os.r4sys.Context, search: []const u8) ?u32 {
    var query = r4os.abi.LogServiceRecordQuery{
        .source_id = r4os.abi.log_service_source_driver,
        .severity_min = r4os.abi.log_severity_debug,
    };
    copyFixedZ(query.search[0..], search);
    var page = r4os.abi.LogServiceRecordPage{};
    if (ctx.logServiceRecords(&query, &page) != r4os.abi.service_api_result_ok) return null;
    return page.total_matches;
}

fn hdaExportFail(ctx: *const DiagApi, stage: []const u8) bool {
    ctx.sys.print("AUDIOD HDA evidence: FAILED stage=");
    ctx.sys.println(stage);
    return false;
}

fn argumentValue(args: []const u8, name: []const u8) ?[]const u8 {
    var rest = trimSpaces(args);
    while (rest.len != 0) {
        var end: usize = 0;
        while (end < rest.len and rest[end] != ' ' and rest[end] != '\t') : (end += 1) {}
        var token = rest[0..end];
        if (token.len != 0 and (token[0] == '/' or token[0] == '-')) token = token[1..];
        if (token.len > name.len and token[name.len] == '=' and sameIgnoreCase(token[0..name.len], name)) {
            const value = token[name.len + 1 ..];
            if (value.len != 0 and value.len < evidence_path_capacity) return value;
            return null;
        }
        rest = trimSpaces(rest[end..]);
    }
    return null;
}

fn argumentSpecified(args: []const u8, name: []const u8) bool {
    var rest = trimSpaces(args);
    while (rest.len != 0) {
        var end: usize = 0;
        while (end < rest.len and rest[end] != ' ' and rest[end] != '\t') : (end += 1) {}
        var token = rest[0..end];
        if (token.len != 0 and (token[0] == '/' or token[0] == '-')) token = token[1..];
        if (token.len >= name.len and sameIgnoreCase(token[0..name.len], name) and
            (token.len == name.len or token[name.len] == '=')) return true;
        rest = trimSpaces(rest[end..]);
    }
    return false;
}

fn trimSpaces(value: []const u8) []const u8 {
    var start: usize = 0;
    var end = value.len;
    while (start < end and (value[start] == ' ' or value[start] == '\t')) : (start += 1) {}
    while (end > start and (value[end - 1] == ' ' or value[end - 1] == '\t')) : (end -= 1) {}
    return value[start..end];
}

fn sameIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| if (upper(left) != upper(right)) return false;
    return true;
}

fn copyFixedZ(target: []u8, value: []const u8) void {
    @memset(target, 0);
    if (target.len == 0) return;
    const count = @min(target.len - 1, value.len);
    @memcpy(target[0..count], value[0..count]);
}

fn containsText(value: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (value.len < needle.len) return false;
    var offset: usize = 0;
    while (offset + needle.len <= value.len) : (offset += 1) {
        var index: usize = 0;
        while (index < needle.len and value[offset + index] == needle[index]) : (index += 1) {}
        if (index == needle.len) return true;
    }
    return false;
}

// Explicit diagnostic producer: retain every acknowledged prefix on BUSY.
// A timeout has ambiguous remote acceptance and is never blindly resent.
fn writePcmFully(ctx: *const DiagApi, stream: *r4os.AudioStream, pcm: []const u8) usize {
    var cursor = r4os.app_audio.WriteCursor.init(pcm.len, pattern.frame_bytes) orelse return 0;
    const began = ctx.sys.ticks();
    const limit = @max(ctx.sys.ticksFromMilliseconds(1000), 1);
    while (!cursor.done()) {
        const elapsed = ctx.sys.ticks() -| began;
        if (elapsed >= limit) break;
        const duration = r4os.time_contract.durationFromTicks(limit - elapsed, ctx.sys.monotonicHz()) catch break;
        const advanced = cursor.apply(stream.write(pcm[cursor.accepted..], r4os.time_contract.timeoutFinite(duration)));
        switch (advanced.outcome) {
            .complete => return cursor.accepted,
            .retry => ctx.sys.sleepTicks(@max(ctx.sys.ticksFromMilliseconds(1), 1)),
            .timed_out, .failure, .invalid => break,
        }
    }
    return cursor.accepted;
}

fn waitForDeadlineProgress(ctx: *const DiagApi, submitted: u64, started: u64) bool {
    const began = ctx.sys.ticks();
    const timeout = @max(ctx.sys.ticksFromMilliseconds(100), 1);
    while (true) {
        const work = ctx.performance.driverWork(0) orelse return false;
        if (work.deadline_submitted > submitted and work.deadline_started > started) return true;
        if (ctx.sys.ticks() -| began >= timeout) return false;
        ctx.sys.sleepTicks(@max(ctx.sys.ticksFromMilliseconds(1), 1));
    }
}

fn waitServiceStatus(ctx: *const r4os.r4sys.Context, out: *r4os.abi.AudioServiceStatus, max_ticks: u64) bool {
    const poll_ticks = @max(ctx.ticksFromMilliseconds(100), 1);
    const started = ctx.ticks();
    while (ctx.ticks() -| started < max_ticks) {
        if (ctx.audioServiceStatus(out) == r4os.abi.service_api_result_ok) return true;
        ctx.sleepTicks(poll_ticks);
    }
    return false;
}

fn waitMasterState(ctx: *const r4os.r4sys.Context, out: *r4os.abi.AudioServiceMasterState, max_ticks: u64) bool {
    const poll_ticks = @max(ctx.ticksFromMilliseconds(100), 1);
    const started = ctx.ticks();
    while (ctx.ticks() -| started < max_ticks) {
        if (ctx.audioServiceMasterState(out) == r4os.abi.service_api_result_ok) return true;
        ctx.sleepTicks(poll_ticks);
    }
    return false;
}

fn waitMasterPersisted(ctx: *const r4os.r4sys.Context, baseline_writes: u64, out: *r4os.abi.AudioServiceMasterState, max_ticks: u64) bool {
    const poll_ticks = @max(ctx.ticksFromMilliseconds(100), 1);
    const started = ctx.ticks();
    while (ctx.ticks() -| started < max_ticks) {
        if (ctx.audioServiceMasterState(out) == r4os.abi.service_api_result_ok and
            out.persist_writes > baseline_writes and
            (out.flags & r4os.abi.audio_master_state_flag_persist_pending) == 0)
            return true;
        ctx.sleepTicks(poll_ticks);
    }
    return false;
}

fn restoreMasterState(ctx: *const r4os.r4sys.Context, original: r4os.abi.AudioServiceMasterState, out: *r4os.abi.AudioServiceMasterState) bool {
    var request = r4os.abi.AudioServiceMasterRequest{
        .flags = r4os.abi.audio_master_request_flag_set_volume,
        .fixed_volume = original.last_audible_volume_fixed,
    };
    if (ctx.audioServiceSetMasterState(&request, out) != r4os.abi.service_api_result_ok) return false;
    request = .{
        .flags = r4os.abi.audio_master_request_flag_set_volume | r4os.abi.audio_master_request_flag_set_muted |
            (if ((original.flags & r4os.abi.audio_master_state_flag_muted) != 0) r4os.abi.audio_master_request_flag_muted else 0),
        .fixed_volume = original.selected_volume_fixed,
    };
    return ctx.audioServiceSetMasterState(&request, out) == r4os.abi.service_api_result_ok;
}

fn masterFail(ctx: *const DiagApi, stage: []const u8) bool {
    ctx.sys.print("AUDIOD master: FAILED stage=");
    ctx.sys.println(stage);
    return false;
}

fn printIdlePath(ctx: *const DiagApi, after: r4os.abi.AudioServiceStatus, before: r4os.abi.AudioServiceStatus) void {
    ctx.sys.print("AUDIOD idle: lazyOpens=");
    ctx.sys.printU64(delta(before.lazy_open_count, after.lazy_open_count));
    ctx.sys.print(" silenceWrites=");
    ctx.sys.printU64(delta(before.silence_write_count, after.silence_write_count));
    ctx.sys.print(" silenceBytes=");
    ctx.sys.printU64(delta(before.silence_bytes, after.silence_bytes));
    ctx.sys.print(" idleCloses=");
    ctx.sys.printU64(delta(before.idle_close_count, after.idle_close_count));
    ctx.sys.write("\r\n");
}

fn printDeadlinePath(ctx: *const DiagApi, after: r4os.abi.ProgramDriverWorkPerformanceInfo, before: r4os.abi.ProgramDriverWorkPerformanceInfo) void {
    ctx.sys.print("AUDIOD deadline: submitted=");
    ctx.sys.printU64(delta(before.deadline_submitted, after.deadline_submitted));
    ctx.sys.print(" started=");
    ctx.sys.printU64(delta(before.deadline_started, after.deadline_started));
    ctx.sys.print(" misses=");
    ctx.sys.printU64(delta(before.deadline_misses, after.deadline_misses));
    ctx.sys.print(" overruns=");
    ctx.sys.printU64(delta(before.deadline_budget_overruns, after.deadline_budget_overruns));
    ctx.sys.print(" rejected=");
    ctx.sys.printU64(delta(before.deadline_queue_rejections, after.deadline_queue_rejections));
    ctx.sys.write("\r\n");
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
