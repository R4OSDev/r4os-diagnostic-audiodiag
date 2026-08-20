# AUDIOD.R4X

`AUDIOD.R4X` is an independent R4OS diagnostic program implemented in Zig.

## Package

- Version: `0.2.0`
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
errors, backend failures, and silence recovery. The WAV analyzer selects the
amplitude-4096 diagnostic tone, merges only sub-2-ms resampler crossings and
checks its observed duration within a five-percent tolerance.

Run `Build.bat test` for component and analyzer selftests. Run
`Tests/Invoke-QemuWavCapture.ps1` from the workspace for the full Test-image
capture. Detailed German notes are in `DOCUMENTATION.de.txt`; the system-wide
procedure is in `Docs/Audio/AudioDiagnostics.txt`.

## License

Original R4OS material is licensed under Apache License 2.0. See `LICENSE`
and `NOTICE`. Any repository-specific external material is documented in
`THIRD_PARTY_NOTICES.md`.
