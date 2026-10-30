# build.ps1 - deploy the workspace MQL5 tree into the MT5 data folder and compile targets.
# Usage (PowerShell):
#   & ".\tools\build.ps1"                                  # deploy + compile all default targets
#   & ".\tools\build.ps1" -Targets Scripts\OrderFlowFP\FPTests.mq5
#   & ".\tools\build.ps1" -NoDeploy                        # compile what is already in the data folder
# Defaults target the STANDARD (demo/test) terminal, never the Exness live terminal.
param(
   [string[]]$Targets = @(
      "Scripts\OrderFlowFP\FPTests.mq5",
      "Scripts\OrderFlowFP\FPDumpBars.mq5",
      "Scripts\OrderFlowFP\FPSignalTests.mq5",
      "Experts\OrderFlowFP\FootprintTrader.mq5",
      "Indicators\OrderFlowFP\FootprintChart.mq5"),
   [string]$DataDir     = "C:\Users\ganzo\AppData\Roaming\MetaQuotes\Terminal\D0E8209F77C8CF37AD8BF550E51FF075",
   [string]$TerminalDir = "C:\Program Files\MetaTrader 5",
   [switch]$NoDeploy
)

$ErrorActionPreference = "Stop"
$Workspace = Split-Path -Parent $PSScriptRoot
$SrcRoot   = Join-Path $Workspace "MQL5"
$DstRoot   = Join-Path $DataDir "MQL5"
$LogDir    = Join-Path $Workspace "build\logs"
$Editor    = Join-Path $TerminalDir "MetaEditor64.exe"

if (-not (Test-Path $Editor)) { throw "MetaEditor not found: $Editor" }
if (-not (Test-Path $DstRoot)) { throw "MQL5 data folder not found: $DstRoot" }
New-Item -ItemType Directory -Force $LogDir | Out-Null

if (-not $NoDeploy) {
   foreach ($sub in @("Include\OrderFlowFP", "Experts\OrderFlowFP", "Scripts\OrderFlowFP", "Indicators\OrderFlowFP")) {
      $src = Join-Path $SrcRoot $sub
      if (-not (Test-Path $src)) { continue }
      $dst = Join-Path $DstRoot $sub
      # /E copies subfolders; no purge, so compiled .ex5 files in the data folder survive.
      robocopy $src $dst /E /NJH /NJS /NFL /NDL /NP /XF *.ex5 *.log | Out-Null
      if ($LASTEXITCODE -ge 8) { throw "robocopy failed for $sub (code $LASTEXITCODE)" }
   }
   Write-Output "Deployed $SrcRoot -> $DstRoot"
}

$failed = 0
foreach ($t in $Targets) {
   $file = Join-Path $DstRoot $t
   if (-not (Test-Path $file)) { Write-Output "SKIP (missing): $t"; continue }
   $name   = [IO.Path]::GetFileNameWithoutExtension($file)
   $rawLog = Join-Path $LogDir "$name.utf16.log"
   if (Test-Path $rawLog) { Remove-Item $rawLog -Force }
   $p = Start-Process -FilePath $Editor -ArgumentList "/compile:`"$file`"", "/include:`"$DstRoot`"", "/log:`"$rawLog`"" -Wait -PassThru -WindowStyle Hidden
   if (-not (Test-Path $rawLog)) { Write-Output "FAIL (no log): $t"; $failed++; continue }
   $lines = Get-Content $rawLog -Encoding Unicode
   $txtLog = Join-Path $LogDir "$name.log"
   $lines | Set-Content $txtLog -Encoding utf8
   Remove-Item $rawLog -Force
   $result = ($lines | Where-Object { $_ -match "Result:" } | Select-Object -Last 1)
   $issues = $lines | Where-Object { $_ -match ": (error|warning) " -or $_ -match " error | warning " }
   Write-Output "== $t"
   $issues | Select-Object -First 60 | ForEach-Object { Write-Output "   $_" }
   if ($result) { Write-Output "   $result" } else { Write-Output "   (no Result line - see $txtLog)" }
   if (-not $result -or $result -notmatch "0 errors, 0 warnings") { $failed++ }
}
if ($failed -gt 0) { Write-Output "BUILD: $failed target(s) not clean"; exit 1 }
Write-Output "BUILD: all targets clean (0 errors, 0 warnings)"
exit 0
