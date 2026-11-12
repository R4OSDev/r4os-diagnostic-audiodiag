//! Passive, copied output/capture discovery. No ADC is opened as a side effect.
const std = @import("std");
const r = @import("r4os");
const a = r.abi;
pub fn check(app: *r.App2, audio: *const r.Audio) bool {
    const sys = app.system();
    var budget = @import("budget.zig").milliseconds(&sys, 1000) catch return false;
    var outputs: [256]a.AudioOutputInfo = undefined;
    var catalog: a.AudioOutputCatalog = .{};
    while (true) {
        _ = budget.remainingTicks() catch return false;
        const result = audio.raw.audioOutputCatalog(&outputs, &catalog);
        if (result == a.service_api_result_busy) { sys.sleepTicks(1); continue; }
        if (result == a.err_no_fn or result == a.err_no_group) {
            sys.println("AUDIOD outputs: unavailable (no complete epoch provider)");
            break;
        }
        if (result != 1 or catalog.version != 1 or catalog.size != @sizeOf(a.AudioOutputCatalog) or
            catalog.registry_generation == 0 or catalog.count > outputs.len or catalog.provider_count > catalog.providers.len) return false;
        var count: u64 = 0;
        var active = catalog.active_registration == 0;
        for (catalog.providers[0..catalog.provider_count], 0..) |provider, index| {
            if (provider.registration == 0 or provider.generation == 0 or provider.count > 32 or
                provider.active_index < -1 or provider.active_index >= @as(i64, provider.count)) return false;
            for (catalog.providers[0..index]) |old| if (old.registration == provider.registration) return false;
            count += provider.count;
            active = active or catalog.active_registration == provider.registration;
        }
        if (!active or count != catalog.count) return false;
        for (outputs[0..catalog.count]) |output| {
            if (output.version != 1 or output.size != @sizeOf(a.AudioOutputInfo) or output.reserved != 0) return false;
        }
        sys.write("AUDIOD outputs: complete registry="); sys.printU64(catalog.registry_generation);
        sys.write(" providers="); sys.printU64(catalog.provider_count); sys.write(" outputs="); sys.printU64(catalog.count); sys.println("");
        break;
    }
    var client: r.audio_capture.Client = undefined;
    if (app.audioCapture(budget.remainingTicks() catch return false, &client) != 0) return false;
    defer _ = client.disconnect();
    var service: a.ProgramProcessHandle = .{};
    var adc: u32 = 0;
    var controlled: u32 = 0;
    for (0..256) |index| {
        client.transport_ticks = budget.remainingTicks() catch return false;
        var reply: a.AudioCaptureReply = .{};
        const result = client.catalog(index, &reply);
        if (result == a.audio_capture_error_unsupported) {
            if (index != 0) return false;
            sys.println("AUDIOD capture: unavailable (no input provider/ADC); no recorded audio or speaker receipt");
            return true;
        }
        if (result != 0) return false;
        if (reply.handle.service.instance_id == 0 or reply.handle.service.generation == 0) return false;
        if (index == 0) service = reply.handle.service else if (!std.meta.eql(service, reply.handle.service)) return false;
        if (reply.flags & a.audio_capture_reply_source == 0) {
            sys.write("AUDIOD capture: ADC="); sys.printU64(adc); sys.write(" controlled="); sys.printU64(controlled);
            sys.println(" (catalog only; no capture or speaker receipt)");
            return true;
        }
        const source = reply.source;
        if (source.version != 1 or source.size != @sizeOf(a.AudioCaptureSourceInfo) or source.id.registration == 0 or source.id.generation == 0) return false;
        const kind = source.flags & (a.audio_capture_source_adc | a.audio_capture_source_controlled);
        if (kind == a.audio_capture_source_adc) adc += 1 else if (kind == a.audio_capture_source_controlled) controlled += 1 else return false;
        if (source.flags & a.audio_capture_source_hardware_timestamp == 0 and
            (source.clock_id != 0 or source.clock_generation != 0 or source.clock_frequency != 0)) return false;
    }
    return false; // Never publish an incomplete catalog as empty or complete.
}
