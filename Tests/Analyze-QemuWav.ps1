[CmdletBinding(DefaultParameterSetName = 'File')]
param(
    [Parameter(Mandatory, ParameterSetName = 'File')]
    [string]$Path,

    [Parameter(ParameterSetName = 'File')]
    [ValidateSet('Continuous', 'Broken')]
    [string]$Expected = 'Continuous',

    [Parameter(Mandatory, ParameterSetName = 'SelfTest')]
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
$captureFrames48k = 8280
$diagnosticThreshold = 2048

function Read-U16([byte[]]$Bytes, [int]$Offset) {
    return [uint16](([uint32]$Bytes[$Offset]) -bor (([uint32]$Bytes[$Offset + 1]) -shl 8))
}

function Read-U32([byte[]]$Bytes, [int]$Offset) {
    return [uint32](([uint32]$Bytes[$Offset]) -bor (([uint32]$Bytes[$Offset + 1]) -shl 8) -bor (([uint32]$Bytes[$Offset + 2]) -shl 16) -bor (([uint32]$Bytes[$Offset + 3]) -shl 24))
}

function Read-I16([byte[]]$Bytes, [int]$Offset) {
    return [BitConverter]::ToInt16($Bytes, $Offset)
}

function Measure-Activity([bool[]]$Active, [int]$SampleRate) {
    $totalActive = 0L
    $longestActive = 0
    $longestInternalSilence = 0
    $activeRun = 0
    $maximumInternalSilence = [int][Math]::Ceiling($SampleRate * 0.002)
    $clusters = [System.Collections.Generic.List[object]]::new()
    $clusterStart = -1
    $lastActive = -1

    for ($index = 0; $index -lt $Active.Length; $index++) {
        $isActive = $Active[$index]
        if ($isActive) {
            if ($lastActive -ge 0) {
                $silence = $index - $lastActive - 1
                if ($silence -gt $longestInternalSilence) { $longestInternalSilence = $silence }
                if ($silence -gt $maximumInternalSilence) {
                    $clusters.Add([pscustomobject]@{
                        Start = $clusterStart
                        End = $lastActive
                        Span = $lastActive - $clusterStart + 1
                    })
                    $clusterStart = $index
                }
            } else {
                $clusterStart = $index
            }
            $lastActive = $index
            $totalActive++
            $activeRun++
            if ($activeRun -gt $longestActive) { $longestActive = $activeRun }
        } else {
            $activeRun = 0
        }
    }
    if ($lastActive -ge 0) {
        $clusters.Add([pscustomobject]@{
            Start = $clusterStart
            End = $lastActive
            Span = $lastActive - $clusterStart + 1
        })
    }

    $longestContinuousSpan = 0L
    foreach ($cluster in $clusters) {
        if ($cluster.Span -gt $longestContinuousSpan) { $longestContinuousSpan = $cluster.Span }
    }

    $expectedSignalFrames = [int][Math]::Round($SampleRate * ($captureFrames48k / 48000.0))
    $minimumSignalFrames = [int][Math]::Floor($expectedSignalFrames * 0.95)
    $maximumSignalFrames = [int][Math]::Ceiling($expectedSignalFrames * 1.05)
    $quantumFrames = $SampleRate / 100.0
    $paddingFrames = $SampleRate * (544.0 / 48000.0)
    $knownPatternCount = 0
    for ($index = 0; $index + 1 -lt $clusters.Count; $index++) {
        $activeSpan = $clusters[$index].Span
        $silence = $clusters[$index + 1].Start - $clusters[$index].End - 1
        $activeNearQuantum = [Math]::Abs($activeSpan - $quantumFrames) -le ($quantumFrames * 0.15)
        $silenceNearPadding = [Math]::Abs($silence - $paddingFrames) -le ($paddingFrames * 0.20)
        if ($activeNearQuantum -and $silenceNearPadding) { $knownPatternCount++ }
    }

    $continuous = $longestContinuousSpan -ge $minimumSignalFrames -and $longestContinuousSpan -le $maximumSignalFrames
    return [pscustomobject]@{
        SampleRate = $SampleRate
        Frames = $Active.Length
        ActiveFrames = $totalActive
        ExpectedSignalFrames = $expectedSignalFrames
        LongestActiveFrames = $longestActive
        LongestContinuousActiveFrames = $longestContinuousSpan
        LongestContinuousSpanFrames = $longestContinuousSpan
        LongestInternalSilenceFrames = $longestInternalSilence
        DetectedClusters = $clusters.Count
        Known480_544Patterns = $knownPatternCount
        Continuous = $continuous
    }
}

function Read-WavActivity([string]$FilePath) {
    $fullPath = [IO.Path]::GetFullPath($FilePath)
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { throw "WAV file not found: $fullPath" }
    [byte[]]$bytes = [IO.File]::ReadAllBytes($fullPath)
    if ($bytes.Length -lt 44 -or [Text.Encoding]::ASCII.GetString($bytes, 0, 4) -cne 'RIFF' -or [Text.Encoding]::ASCII.GetString($bytes, 8, 4) -cne 'WAVE') {
        throw "Not a RIFF/WAVE file: $fullPath"
    }

    $formatOffset = -1
    $formatBytes = 0
    $dataOffset = -1
    $dataBytes = 0
    $cursor = 12
    while ($cursor + 8 -le $bytes.Length) {
        $chunk = [Text.Encoding]::ASCII.GetString($bytes, $cursor, 4)
        $length = [int](Read-U32 $bytes ($cursor + 4))
        $payload = $cursor + 8
        if ($chunk -ceq 'data' -and $length -eq 0 -and $payload -lt $bytes.Length) {
            # QEMU's WAV audiodev leaves the streaming RIFF/data sizes at zero
            # even after a normal guest poweroff. The PCM payload still runs
            # from the data chunk to EOF and is frame-aligned.
            $length = $bytes.Length - $payload
        }
        if ($payload + $length -gt $bytes.Length) { throw "Truncated WAV chunk: $chunk" }
        if ($chunk -ceq 'fmt ') {
            $formatOffset = $payload
            $formatBytes = $length
        } elseif ($chunk -ceq 'data') {
            $dataOffset = $payload
            $dataBytes = $length
        }
        $cursor = $payload + $length + ($length -band 1)
    }
    if ($formatOffset -lt 0 -or $formatBytes -lt 16 -or $dataOffset -lt 0) { throw 'WAV fmt or data chunk missing.' }

    $format = Read-U16 $bytes $formatOffset
    $channels = Read-U16 $bytes ($formatOffset + 2)
    $sampleRate = [int](Read-U32 $bytes ($formatOffset + 4))
    $bitsPerSample = Read-U16 $bytes ($formatOffset + 14)
    if ($format -ne 1 -or $channels -lt 1 -or $channels -gt 2 -or $sampleRate -le 0 -or $bitsPerSample -ne 16) {
        throw "Unsupported WAV format: format=$format channels=$channels rate=$sampleRate bits=$bitsPerSample"
    }

    $frameBytes = $channels * 2
    $frameCount = [int]($dataBytes / $frameBytes)
    [bool[]]$active = New-Object bool[] $frameCount
    for ($frame = 0; $frame -lt $frameCount; $frame++) {
        $offset = $dataOffset + ($frame * $frameBytes)
        $left = [Math]::Abs([int](Read-I16 $bytes $offset))
        $right = if ($channels -eq 2) { [Math]::Abs([int](Read-I16 $bytes ($offset + 2))) } else { $left }
        # AUDIOD uses amplitude 4096. The subsystem-runtime selftest in the
        # same image stays at or below 1536, so this selects only the intended
        # diagnostic tone even when QEMU buffers both sources into one WAV.
        $active[$frame] = $left -gt $diagnosticThreshold -or $right -gt $diagnosticThreshold
    }
    return Measure-Activity $active $sampleRate
}

function Assert-Condition([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

if ($SelfTest) {
    [bool[]]$continuous = New-Object bool[] ($captureFrames48k + 200)
    for ($index = 100; $index -lt 100 + $captureFrames48k; $index++) { $continuous[$index] = $true }
    $continuousResult = Measure-Activity $continuous 48000
    Assert-Condition $continuousResult.Continuous 'Continuous fixture was rejected.'
    Assert-Condition ($continuousResult.Known480_544Patterns -eq 0) 'Continuous fixture matched the legacy pattern.'

    [bool[]]$legacy = New-Object bool[] (16 * 1024)
    for ($packet = 0; $packet -lt 16; $packet++) {
        $start = $packet * 1024
        for ($frame = $start; $frame -lt $start + 480; $frame++) { $legacy[$frame] = $true }
    }
    $legacyResult = Measure-Activity $legacy 48000
    Assert-Condition (-not $legacyResult.Continuous) 'Legacy 480/544 fixture was accepted.'
    Assert-Condition ($legacyResult.Known480_544Patterns -ge 8) 'Legacy 480/544 fixture was not identified.'

    [bool[]]$loss = New-Object bool[] $captureFrames48k
    for ($frame = 0; $frame -lt $loss.Length; $frame++) { $loss[$frame] = $true }
    for ($frame = 4000; $frame -lt 4480; $frame++) { $loss[$frame] = $false }
    $lossResult = Measure-Activity $loss 48000
    Assert-Condition (-not $lossResult.Continuous) 'Injected sample-loss fixture was accepted.'

    Write-Host 'AUDIOD QEMU WAV analyzer self-test OK: continuous, 480/544 and sample-loss fixtures.'
    exit 0
}

$result = Read-WavActivity $Path
$result | Format-List
$matches = if ($Expected -eq 'Continuous') { $result.Continuous -and $result.Known480_544Patterns -eq 0 } else { -not $result.Continuous -and $result.Known480_544Patterns -gt 0 }
if (-not $matches) {
    Write-Host ("AUDIOD QEMU WAV analysis FAILED: expected=$Expected continuous=$($result.Continuous) known480_544=$($result.Known480_544Patterns)")
    exit 1
}
Write-Host ("AUDIOD QEMU WAV analysis OK: expected=$Expected continuous=$($result.Continuous) known480_544=$($result.Known480_544Patterns)")
exit 0
