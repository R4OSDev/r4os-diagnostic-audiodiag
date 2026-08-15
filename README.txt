AUDIOD.R4X
==========

AUDIOD.R4X ist die Audio- und PCM-Stream-Diagnose.

Projektstruktur seit 0.51.21:
- `build.zig` baut die Diagnose als eigenes SDK-Projekt.
- `build.zig.zon` bindet `r4os_sdk` als Paket.
- `module.R4MF` beschreibt Artefakt, Zielpfad, R4L-Imports und Contract.

Build:

    cd Code\System\Diagnostics\AudioDiag
    ..\..\..\DevTools\Zig\zig.exe build

Ergebnis:

    Code\System\Diagnostics\AudioDiag\zig-out\AUDIOD.R4X

Contract:
- Build-Profil: `Zig/R4XStart`
- R4XStart-Entry: `audiod_main`
- App-Klasse: `console`
- R4L-Imports: `R4SYS`, `R4AUDIO`
- Zielpfad im Image: `C:\R4OS\SOFTWARE\TERMINAL\DIAG\AUDIOD.R4X`
