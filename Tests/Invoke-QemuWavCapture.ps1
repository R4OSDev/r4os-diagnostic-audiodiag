[CmdletBinding()]
param(
    [ValidateSet('Test', 'Full')]
    [string]$Profile = 'Test',

    [int]$TimeoutSeconds = 240
)

$ErrorActionPreference = 'Stop'
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\..'))
$profileDirectory = Join-Path $workspace "Artifacts\Distribution\Profiles\$Profile"
$logsDirectory = Join-Path $workspace 'Artifacts\Distribution\Logs'
$qemu = Join-Path $workspace 'DevKit\Emulation\QEMU\qemu-system-x86_64.exe'
$config = Join-Path $workspace 'Repositories\Distribution\QEMU\standard.conf'
$analyzer = Join-Path $PSScriptRoot 'Analyze-QemuWav.ps1'
$wavPath = Join-Path $logsDirectory 'qemu-audiod-capture.wav'
$logPath = Join-Path $logsDirectory 'qemu-audiod-capture.log'
$errorPath = Join-Path $logsDirectory 'qemu-audiod-capture.err'

function Assert-File([string]$Path, [string]$Label) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "$Label not found: $Path" }
}

function Quote-Argument([string]$Value) {
    if ($Value -match '[\s"]') { return '"' + ($Value -replace '"', '\"') + '"' }
    return $Value
}

function Assert-LogTarget([string]$Path) {
    $resolvedLogs = [IO.Path]::GetFullPath($logsDirectory).TrimEnd('\') + '\'
    $resolvedPath = [IO.Path]::GetFullPath($Path)
    if (-not $resolvedPath.StartsWith($resolvedLogs, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Capture output escapes the log directory: $resolvedPath"
    }
    return $resolvedPath
}

function Read-SharedText([string]$Path) {
    $stream = [IO.FileStream]::new($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8, $true)
        try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
    } finally {
        $stream.Dispose()
    }
}

function Get-FreeTcpPort {
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    try {
        $listener.Start()
        return ([Net.IPEndPoint]$listener.LocalEndpoint).Port
    } finally {
        $listener.Stop()
    }
}

function Stop-QemuThroughQmp([int]$Port) {
    $client = [Net.Sockets.TcpClient]::new()
    $client.ReceiveTimeout = 3000
    $client.SendTimeout = 3000
    try {
        $client.Connect('127.0.0.1', $Port)
        $stream = $client.GetStream()
        $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8, $false, 1024, $true)
        $writer = [IO.StreamWriter]::new($stream, [Text.UTF8Encoding]::new($false), 1024, $true)
        try {
            $writer.AutoFlush = $true
            if ([string]::IsNullOrWhiteSpace($reader.ReadLine())) { throw 'QMP greeting is missing.' }
            $writer.WriteLine('{"execute":"qmp_capabilities"}')
            if ([string]::IsNullOrWhiteSpace($reader.ReadLine())) { throw 'QMP capability response is missing.' }
            $writer.WriteLine('{"execute":"quit"}')
        } finally {
            $writer.Dispose()
            $reader.Dispose()
            $stream.Dispose()
        }
    } finally {
        $client.Dispose()
    }
}

Assert-File $qemu 'QEMU executable'
Assert-File $config 'QEMU configuration'
Assert-File (Join-Path $profileDirectory 'disk.img') 'Profile disk image'
Assert-File (Join-Path $profileDirectory 'data.img') 'Profile data image'
Assert-File $analyzer 'WAV analyzer'
if ($TimeoutSeconds -le 0) { throw 'TimeoutSeconds must be positive.' }
if (-not (Test-Path -LiteralPath $logsDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $logsDirectory -Force | Out-Null
}

$wavPath = Assert-LogTarget $wavPath
$logPath = Assert-LogTarget $logPath
$errorPath = Assert-LogTarget $errorPath
foreach ($target in @($wavPath, $logPath, $errorPath)) {
    if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force }
}

$qmpPort = Get-FreeTcpPort
$argumentLine = @(
    '-readconfig', (Quote-Argument $config),
    '-cpu', 'Haswell',
    '-m', '1G',
    '-smp', '1',
    '-nic', 'none',
    '-serial', (Quote-Argument ('file:' + $logPath)),
    '-display', 'none',
    '-no-reboot',
    '-audiodev', (Quote-Argument ('wav,id=audiodcapture,path=' + $wavPath)),
    '-global', 'hda-duplex.audiodev=audiodcapture',
    '-qmp', (Quote-Argument ("tcp:127.0.0.1:${qmpPort},server=on,wait=off")),
    '-name', (Quote-Argument 'R4OS AUDIOD WAV capture')
) -join ' '

Write-Host ("AUDIOD QEMU WAV capture: profile=$Profile timeout=${TimeoutSeconds}s")
$process = Start-Process -FilePath $qemu -ArgumentList $argumentLine -WorkingDirectory $profileDirectory -WindowStyle Hidden -RedirectStandardError $errorPath -PassThru
$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
$audioPassed = $false
$audioFailed = $false
while ([DateTime]::UtcNow -lt $deadline -and -not $process.HasExited) {
    if (Test-Path -LiteralPath $logPath -PathType Leaf) {
        $log = Read-SharedText $logPath
        $audioFailed = $log.Contains('Audio PCM continuity diagnostics: FAILED') -or $log.Contains('AUDIOD result: FAILED')
        $audioPassed = $log.Contains('HDA.R4D [active]') -and
            $log.Contains('AUDIOD path: upstreamDropped=0 driverUnderruns=0 driverErrors=0 backendFail=0 silencePeriods=0') -and
            $log.Contains('Audio PCM continuity diagnostics: OK') -and
            $log.Contains('AUDIOD result: OK')
    }
    if ($audioPassed -or $audioFailed) { break }
    Start-Sleep -Milliseconds 100
}

if (-not $audioPassed) {
    if (-not $process.HasExited) {
        $process.Kill()
        $process.WaitForExit(5000) | Out-Null
    }
    if ($audioFailed) { throw 'AUDIOD reported a failed PCM path during WAV capture.' }
    if (-not $process.HasExited) { throw "AUDIOD WAV capture timed out after $TimeoutSeconds seconds." }
    throw "AUDIOD WAV capture did not reach its success markers after $TimeoutSeconds seconds."
}

# The stream-close marker is emitted only after the HDA ring was drained.
# QEMU's real-time audio thread can still have roughly half a second of audio
# produced by launcher selftests ahead of the diagnostic stream. Give that
# host queue a bounded two-second flush window, then terminate the capture.
Start-Sleep -Milliseconds 2000
Stop-QemuThroughQmp $qmpPort
if (-not $process.WaitForExit(10000)) {
    $process.Kill()
    $process.WaitForExit(5000) | Out-Null
    throw 'QEMU did not exit after the QMP quit request.'
}
$process.WaitForExit()
$process.Refresh()
$exitCode = $process.ExitCode
if ($null -ne $exitCode -and $exitCode -ne 0) { throw "QEMU WAV capture exited with $exitCode." }

& $analyzer -Path $wavPath -Expected Continuous
exit $LASTEXITCODE
