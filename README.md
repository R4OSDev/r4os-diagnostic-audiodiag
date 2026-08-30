# AUDIOD.R4X

`AUDIOD.R4X` is an independent R4OS diagnostic program implemented in Zig.

## Package

- Version: `0.2.5`
- Image target: `/R4OS/SOFTWARE/TERMINAL/DIAG/AUDIOD.R4X`
- Image scope: `test`
- Canonical project manifest: `module.R4MF`

The manifest is the single source of truth for the artifact, imports, image
target, and package metadata.

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
