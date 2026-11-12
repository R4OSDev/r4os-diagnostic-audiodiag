//! Every polling phase retains one SDK deadline and the actual clock identity.
const r = @import("r4os");
pub fn ticks(sys: *const r.r4sys.Context, count: u64) r.rpc_budget.Error!r.rpc_budget.Budget {
    const context = sys.base.generation2 orelse return error.ClockUnavailable;
    const read = r.platform2.abi.function(r.platform2.abi.R4SysFns2, context.system(), "monotonic_clock");
    return r.rpc_budget.Budget.fromTicks(read, @max(count, 1));
}
pub fn milliseconds(sys: *const r.r4sys.Context, count: u64) r.rpc_budget.Error!r.rpc_budget.Budget {
    return ticks(sys, sys.ticksFromMilliseconds(count));
}
