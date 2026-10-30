# mt5_run_script.ps1 - run one MQL5 script in the STANDARD (demo) terminal via a startup config,
# wait for its summary line, print FAIL lines, close the terminal.
# Examples:
#   & .\tools\mt5_run_script.ps1 -Script OrderFlowFP\FPTests       -Marker "FPTests:"
#   & .\tools\mt5_run_script.ps1 -Script OrderFlowFP\FPSignalTests -Marker "FPSignalTests:"
#   & .\tools\mt5_run_script.ps1 -Script OrderFlowFP\FPDumpBars    -Marker "FPDumpBars: wrote" -TimeoutSec 540 -Params "InpBars=11000","InpSource=3"
# The terminal must be closed before you start (one instance per data folder).
param(
   [Parameter(Mandatory = $true)][string]$Script,      # e.g. OrderFlowFP\FPTests
   [Parameter(Mandatory = $true)][string]$Marker,      # summary line text, e.g. "FPTests:"
   [string]$Symbol = "XAUUSD",
   [string]$Period = "M5",
   [int]$TimeoutSec = 180,
   [string[]]$Params = @()                              # "Name=value" script inputs (written to MQL5\Presets)
)
$Terminal = "C:\Program Files\MetaTrader 5\terminal64.exe"
$DataDir  = "C:\Users\ganzo\AppData\Roaming\MetaQuotes\Terminal\D0E8209F77C8CF37AD8BF550E51FF075"
$LogDir   = Join-Path $DataDir "MQL5\Logs"
$OutDir   = Join-Path (Split-Path -Parent $PSScriptRoot) "build\runs"
New-Item -ItemType Directory -Force $OutDir | Out-Null
$name = ($Script -split '\\')[-1]
$ini  = Join-Path $OutDir "startup_$name.ini"
$cfg  = @("[StartUp]", "Script=$Script", "Symbol=$Symbol", "Period=$Period")
if ($Params.Count -gt 0) {
   $presets = Join-Path $DataDir "MQL5\Presets"
   New-Item -ItemType Directory -Force $presets | Out-Null
   $Params | Set-Content (Join-Path $presets "${name}_run.set") -Encoding Unicode
   $cfg += "ScriptParameters=${name}_run.set"
}
$cfg | Set-Content $ini -Encoding Unicode

if (Get-Process terminal64 -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $Terminal }) { throw "the standard terminal is already running - close it first" }
$start = Get-Date
# today's log may already exist and is appended; NTFS LastWriteTime lags on open files, so diff by line count
$log  = Join-Path $LogDir ($start.ToString("yyyyMMdd") + ".log")
$base = 0
if (Test-Path $log) { $base = (Get-Content $log -Encoding Unicode | Measure-Object).Count }
$p = Start-Process -FilePath $Terminal -ArgumentList "/config:`"$ini`"" -PassThru
$found = $null
while (((Get-Date) - $start).TotalSeconds -lt $TimeoutSec -and -not $found) {
   Start-Sleep -Seconds 3
   if (-not (Test-Path $log)) { continue }
   $lines = @(Get-Content $log -Encoding Unicode -ErrorAction SilentlyContinue | Select-Object -Skip $base)
   $found = $lines | Where-Object { $_ -match [regex]::Escape($Marker) } | Select-Object -Last 1
}
if (Test-Path $log) {
   $lines = @(Get-Content $log -Encoding Unicode | Select-Object -Skip $base)
   $out = Join-Path $OutDir "log_$name.txt"
   $lines | Where-Object { $_ -match [regex]::Escape($name) } | Set-Content $out -Encoding utf8
   Write-Output "log: $out"
   $lines | Where-Object { $_ -match "\bFAIL\b|live-vs-rebuild mismatch" } | Select-Object -First 80 | ForEach-Object { Write-Output "  $_" }
}
if ($found) { Write-Output "SUMMARY: $(($found -split "`t")[-1])" } else { Write-Output "TIMEOUT: no '$Marker' line after $TimeoutSec s" }
if (-not $p.HasExited) { $null = $p.CloseMainWindow(); $p.WaitForExit(20000) | Out-Null }
if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
Write-Output "terminal closed"
