[CmdletBinding()]
param(
    [ValidateSet('Test','Full')][string]$Profile='Test',
    [ValidateSet(4)][int]$CpuCount=4,
    [ValidateRange(1,1200)][int]$TimeoutSeconds=360,
    [string]$SourceRoot='',
    [string]$OutputDirectory='',
    [switch]$AudioOnly
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$workspace=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../../..'))
$distribution=Join-Path $workspace 'Repositories/Distribution'
. (Join-Path $distribution 'Tools/Distribution.ps1')
. (Join-Path $distribution 'Tools/Qemu-Media.ps1')
$context=Get-R4DistributionContext $distribution
if(!$SourceRoot){$SourceRoot=Join-Path $context.output "Profiles/$Profile"}
if(!$OutputDirectory){$OutputDirectory=Join-Path $context.output ('Logs/AudioCapture/'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff'))}
$OutputDirectory=[IO.Path]::GetFullPath($OutputDirectory)
[IO.Directory]::CreateDirectory($OutputDirectory)|Out-Null
$wav=Join-Path $OutputDirectory 'audio.wav'
$serial=Join-Path $OutputDirectory 'serial.log'
$errors=Join-Path $OutputDirectory 'serial.err'
foreach($path in @($wav,$serial,$errors)){if(Test-Path -LiteralPath $path){throw "Capture evidence already exists: $path"}}
$run=New-R4QemuMedia -SourceRoot $SourceRoot -Mode Fresh -Name ('audio-'+[DateTime]::UtcNow.ToString('yyyyMMddHHmmssfff'))
$values=@{
 R4OS_QEMU_EXE=$context.qemu;R4OS_QEMU_CONFIG=Join-Path $distribution 'QEMU/standard.conf';
 R4OS_QEMU_LOG=$serial;R4OS_QEMU_ERROR_LOG=$errors;R4OS_QEMU_WORKING_DIRECTORY=$run;
 R4OS_QEMU_CPUS=[string]$CpuCount;R4OS_QEMU_STOP_MARKER='';
 R4OS_QEMU_WAV_OUTPUT=$wav;QEMU_TEST_TIMEOUT_SECONDS=[string]$TimeoutSeconds
}
$saved=@{}
try{
 foreach($key in $values.Keys){$saved[$key]=[Environment]::GetEnvironmentVariable($key);[Environment]::SetEnvironmentVariable($key,$values[$key])}
 & pwsh -NoProfile -File (Join-Path $distribution 'Tests/Invoke-QemuHeadless.ps1')
 if($LASTEXITCODE -ne 0){throw "QEMU capture exit $LASTEXITCODE"}
}finally{foreach($key in $saved.Keys){[Environment]::SetEnvironmentVariable($key,$saved[$key])}}
$text=[IO.File]::ReadAllText($serial)
$required=@('HDA.R4D [active]','AUDIOD path: upstreamDropped=0 driverUnderruns=0 driverErrors=0 backendFail=0 silencePeriods=0','Audio PCM continuity diagnostics: OK','AUDIOD result: OK','System poweroff.')
if(!$AudioOnly){$required+=@('R4GB APU runtime: OK rate=48000 channels=2 frames=6000 submitted=24000 drift=0 drops=0','R4GB long-run E2E: OK duration=60s instances=2 focus=alternating lifecycle=pause+resume+reset+mute endings=witness+close desktop=responsive')}
foreach($marker in $required){if(!$text.Contains($marker)){throw "Capture marker missing: $marker"}}
& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'Analyze-QemuWav.ps1') -Path $wav -Expected Continuous
if($LASTEXITCODE -ne 0){throw 'AudioDiag WAV verification failed'}
if(!$AudioOnly){
 & pwsh -NoProfile -File (Join-Path $workspace 'Repositories/Subsystems/R4GB/Tests/Analyze-QemuApuWav.ps1') -Path $wav -ExpectedFrames (60*48000) -DurationTolerancePercent 5
 if($LASTEXITCODE -ne 0){throw 'R4GB WAV verification failed'}
}
Write-Host "Audio capture verified: $OutputDirectory"
