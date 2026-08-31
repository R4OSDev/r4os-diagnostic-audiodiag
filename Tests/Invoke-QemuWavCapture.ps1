[CmdletBinding()]
param(
    [ValidateSet('Test', 'Full')]
    [string]$Profile = 'Test',

    [ValidateSet(1, 4)]
    [int]$CpuCount = 1,

    [int]$TimeoutSeconds = 360
)

$ErrorActionPreference = 'Stop'
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\..'))
$profileDirectory = Join-Path $workspace "Artifacts\Distribution\Profiles\$Profile"
$logsDirectory = Join-Path $workspace 'Artifacts\Distribution\Logs'
$qemuName = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
    'qemu-system-x86_64.exe'
} else {
    'qemu-system-x86_64'
}
$qemu = Join-Path $workspace "DevKit\Emulation\QEMU\$qemuName"
$config = Join-Path $workspace 'Repositories\Distribution\QEMU\standard.conf'
$analyzer = Join-Path $PSScriptRoot 'Analyze-QemuWav.ps1'
$r4gbAnalyzer = Join-Path $workspace 'Repositories\Subsystems\R4GB\Tests\Analyze-QemuApuWav.ps1'
$wavPath = Join-Path $logsDirectory "qemu-audiod-capture-smp$CpuCount.wav"
$logPath = Join-Path $logsDirectory "qemu-audiod-capture-smp$CpuCount.log"
$errorPath = Join-Path $logsDirectory "qemu-audiod-capture-smp$CpuCount.err"
$kvmAvailable = $IsLinux -and (Test-Path -LiteralPath '/dev/kvm')
$accelerators = if ($kvmAvailable) {
    'kvm:tcg'
} elseif ($IsWindows) {
    'whpx:tcg'
} elseif ($IsMacOS) {
    'hvf:tcg'
} else {
    'tcg'
}
$cpuModel = if ($kvmAvailable) { 'host' } else { 'Haswell' }

function Assert-File([string]$Path, [string]$Label) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "$Label not found: $Path" }
}

function Quote-Argument([string]$Value) {
    if ($Value -match '[\s"]') { return '"' + ($Value -replace '"', '\"') + '"' }
    return $Value
}

function Normalize-StartProcessEnvironment {
    $pathEntries = @([Environment]::GetEnvironmentVariables().GetEnumerator() |
        Where-Object { [string]$_.Key -ieq 'Path' })
    if ($pathEntries.Count -le 1) { return }
    $canonical = @($pathEntries | Where-Object { [string]$_.Key -ceq 'Path' } | Select-Object -First 1)
    $pathValue = if ($canonical.Count -eq 1) { [string]$canonical[0].Value } else { [string]$pathEntries[0].Value }
    [Environment]::SetEnvironmentVariable('PATH', $null, 'Process')
    [Environment]::SetEnvironmentVariable('Path', $pathValue, 'Process')
}

function Assert-LogTarget([string]$Path) {
    $resolvedLogs = [IO.Path]::GetFullPath($logsDirectory)
    $resolvedPath = [IO.Path]::GetFullPath($Path)
    $relativePath = [IO.Path]::GetRelativePath($resolvedLogs, $resolvedPath)
    $parentPrefix = '..' + [IO.Path]::DirectorySeparatorChar
    if ([IO.Path]::IsPathRooted($relativePath) -or
        $relativePath -eq '..' -or
        $relativePath.StartsWith($parentPrefix, [StringComparison]::Ordinal)) {
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
Assert-File $r4gbAnalyzer 'R4GB WAV analyzer'
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
    '-cpu', $cpuModel,
    '-m', '1G',
    '-smp', "$CpuCount",
    '-machine', (Quote-Argument ('accel=' + $accelerators)),
    '-nic', 'none',
    '-serial', (Quote-Argument ('file:' + $logPath)),
    '-display', 'none',
    '-no-reboot',
    '-audiodev', (Quote-Argument ('wav,id=audiodcapture,path=' + $wavPath)),
    '-global', 'hda-duplex.audiodev=audiodcapture',
    '-qmp', (Quote-Argument ("tcp:127.0.0.1:${qmpPort},server=on,wait=off")),
    '-name', (Quote-Argument 'R4OS AUDIOD WAV capture')
) -join ' '

Write-Host ("AUDIOD QEMU WAV capture: profile=$Profile cpus=$CpuCount timeout=${TimeoutSeconds}s")
Normalize-StartProcessEnvironment
$startParameters = @{
    FilePath = $qemu
    ArgumentList = $argumentLine
    WorkingDirectory = $profileDirectory
    RedirectStandardError = $errorPath
    PassThru = $true
}
if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
    $startParameters.WindowStyle = 'Hidden'
}
$process = Start-Process @startParameters
$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
$audioPassed = $false
$audioFailed = $false
while ([DateTime]::UtcNow -lt $deadline -and -not $process.HasExited) {
    if (Test-Path -LiteralPath $logPath -PathType Leaf) {
        $log = Read-SharedText $logPath
        $audioFailed = $log.Contains('Audio PCM continuity diagnostics: FAILED') -or
            $log.Contains('AUDIOD result: FAILED') -or
            $log.Contains('R4GB APU runtime: FAILED') -or
            $log.Contains('R4GB E2E runtime: FAILED') -or
            $log.Contains('SUBSYSTEM runtime bootstrap FAILED')
        $audioPassed = $log.Contains('HDA.R4D [active]') -and
            $log.Contains('AUDIOD path: upstreamDropped=0 driverUnderruns=0 driverErrors=0 backendFail=0 silencePeriods=0') -and
            $log.Contains('Audio PCM continuity diagnostics: OK') -and
            $log.Contains('AUDIOD result: OK') -and
            $log.Contains('R4GB APU runtime: OK rate=48000 channels=2 frames=6000 submitted=24000 drift=0 drops=0') -and
            $log.Contains('R4GB long-run E2E: OK duration=60s instances=2 focus=alternating lifecycle=pause+resume+reset+mute endings=witness+close desktop=responsive')
    }
    if ($audioPassed -or $audioFailed) { break }
    Start-Sleep -Milliseconds 100
}

if (-not $audioPassed) {
    if (-not $process.HasExited) {
        $process.Kill()
        $process.WaitForExit(5000) | Out-Null
    }
    if ($audioFailed) { throw 'The audio diagnostics reported a failed PCM path during WAV capture.' }
    if (-not $process.HasExited) { throw "AUDIOD WAV capture timed out after $TimeoutSeconds seconds." }
    throw "Audio WAV capture did not reach its AUDIOD and R4GB success markers after $TimeoutSeconds seconds."
}

# The long-run marker is emitted only after both productive R4GB streams have
# closed. Give QEMU's real-time WAV backend one bounded queue flush interval.
Start-Sleep -Milliseconds 1000
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
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& $r4gbAnalyzer -Path $wavPath -ExpectedFrames (60 * 48000) -DurationTolerancePercent 5
exit $LASTEXITCODE
