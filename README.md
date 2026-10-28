# AUDIOD.R4X

`AUDIOD.R4X` is an independent R4OS diagnostic program implemented in Zig.

## Package

- Version: `0.2.15`
- Image target: `/R4OS/SOFTWARE/TERMINAL/DIAG/AUDIOD.R4X`
- Image scope: `test`
- Canonical project manifest: `module.R4MF`

The manifest is the single source of truth for the artifact, imports, image
target, and package metadata.

Version0.2.15 adds failure-only GAP Open/Progress/Close evidence: the typed
outcome, actual transport/response code when one exists, exact stream identity,
and the unchanged100ms RPC budget. An overall3s expiry reports no invented
RPC code. This adds neither retries nor a normal-operation sampler and keeps
the original frame, terminal Close and resource oracles. A current KVM mixed
run passed all eight original GAPs; an earlier fifth Open failure remains
unexplained. Native417/16 with15 passes the original GAP1440/terminal Close/
restored resources, full8280-frame PCM/HDA/lifecycle checks and Progress480.
HDA control reports793 turns/474 continuations/max16; physical hearing is skipped.
Separate integrated57/55 and59 failure observations remain open in66.

Version0.2.14 checks a real BUSY terminal Close against its exact stream and
keeps the original bounded wait and final resource checks.

Version0.2.13 adds `AUDIOD /GAP`: the real AudioService receives480 signal,
480 zero and480 signal frames on one ordinary logical/backend generation.
It requires1440 actual backend/DMA/consumed frames, no suppressed or unknown
remainder, no silent Close/reopen, a real terminal Close and restored session
resources. This is a bounded explicit diagnostic, with no speaker receipt.
Normal AudioDiag now requires an active zero block to retain its stream
until the explicit Close instead of expecting the old premature idle close.

Version0.2.12 added `AUDIOD /PROGRESS`, a bounded real-device check separate
from the original PCM/lifecycle/WAV cases. It observes exact stream identity,
480 accepted/backend/DMA/consumed canonical frames and zero unknown residue;
an intentionally interrupted continuous source reports one undersupply
episode. A newly opened stream rejects the old generation. Clocked zero PCM
with explicit end stays regular idle and closes cleanly. MMIO progress is a
device receipt, not a claim about audible speaker output. The existing normal
AudioDiag and its strict original WAV/count/drop/error checks remain required.

## Build

On Windows:

    Build.bat

On Linux or macOS:

    ./Build.sh

The build starters resolve the current local R4OS dependency checkouts through
`Settings.R4S`. The URL and hash entries in `build.zig.zon` record the
last verified standalone dependency identities; workspace builds use the
mapped local checkouts.

## Documentation

Default mode emits deterministic 480-frame and variable-size packets for the
QEMU WAV continuity gate. `/LONG` feeds a 60-second tone against the reported
backend fill level. The result separates upstream drops, HDA underruns, stream
errors, backend failures, and silence recovery. The WAV analyzer identifies
the stable stereo diagnostic plateau by shape and expected duration, so louder
boot or subsystem audio in the same capture cannot mask it. It merges only
sub-2-ms resampler crossings and checks the observed duration within a
five-percent tolerance.
The default run also proves a silent logical stream stays unmaterialized,
signal lazily opens the backend, later silence closes it once, and the
DriverApi-v20 audio lane records productive work without a new deadline miss,
budget overrun, or admission rejection.
It then restarts AUDSVC, replays four bounded partial-period
Open/Write/Close cycles, proves all logical and materialized sessions return
to zero, and validates the HDA core/runtime diagnostic records through
LogService. The serial lifecycle and diagnostic markers are part of the
existing Test-profile acceptance contract.
The runtime record must also expose position-source mismatch and fallback
counters, so physical LPIB fallback cannot be mislabeled as active DMA merely
because a DMA position buffer was configured.
The final cold and warm Lenovo acceptance produced six complete runtime groups
per boot with `pos=lpib-fallback pmis=3 pfb=3`, advancing writes and every
stream, recovery, timeout and work-drop counter at zero.

For physical evidence, `/OUT=<path>` atomically exports the still-current HDA
driver records before AUDIOD exits. The run fails unless candidate decisions,
the selected controller, the compact core record and a close-runtime record
are all present. This avoids relying on unsupported external redirection or a
later GUI export after the bounded log window has advanced.

Run `Build.bat test` for component and analyzer selftests. Run
`Tests/Invoke-QemuWavCapture.ps1` from the workspace for the full Test-image
capture on Windows or Debian Linux. Detailed German notes are in
`DOCUMENTATION.de.txt`; the system-wide
procedure is in `Docs/Audio/AudioDiagnostics.txt`.

## License

Original R4OS material is licensed under Apache License 2.0. See `LICENSE`
and `NOTICE`. Any repository-specific external material is documented in
`THIRD_PARTY_NOTICES.md`.

Short capture IRQ witness (0.81.17)
---------------------------------
Before idle/Close starts synchronous drain, AudioDiag waits at most 100 ms
for one submitted and started audio deadline job, checking once per ms.
The 8,280-frame signal is unchanged. A fast producer must not fail the
asynchronous-lane check merely because all writes precede the first IRQ.
A missing worker or timeout still fails; zero new misses, overruns, drops
and backend errors remain mandatory.
