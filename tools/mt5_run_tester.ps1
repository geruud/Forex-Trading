# mt5_run_tester.ps1 - run FootprintTrader in the STANDARD (demo) terminal's Strategy Tester
# (XAUUSD M5, every tick based on real ticks), one pass per run name, and collect the outputs
# into build\tester\<run>[_<Tag>]\ (agent log, signals/trades CSV, bar dump, HTML report).
# Runs:  signals   SIGNALS_ONLY + bar dump (dump-equality, determinism)
#        virtual   VIRTUAL
#        live      LIVE inside the tester (compare with virtual: E3)
#        hooks     LIVE with the E2 test hooks (daily loss at day 3, consecutive losses at day 9, kill switch at day 17)
#        research  VIRTUAL + InpResearchAllSignals + bar dump, every risk limit off: every signal is simulated
#                  as an independent trade (input of tools\fp_analyze.py --research)
# Inputs of a run = the EA defaults, overridden by -SetFile lines (e.g. MQL5\Presets\FootprintTrader_spec.set),
# then by the run's own lines, then by -Params "Name=value" (last one wins).
# Examples:
#   & .\tools\mt5_run_tester.ps1 -Runs signals,virtual,live -From 2026.09.07 -To 2026.09.26
#   & .\tools\mt5_run_tester.ps1 -Runs virtual -Tag spec_is -SetFile MQL5\Presets\FootprintTrader_spec.set -From 2026.06.01 -To 2026.09.01
#   & .\tools\mt5_run_tester.ps1 -Runs research -Tag is -Params "InpRevLookback=5","InpRevRows=2" -From 2026.06.01 -To 2026.09.01
# Pick a window the terminal has REAL ticks for: check the agent log for "real ticks absent" -
# the tester silently falls back to generated ticks for missing minutes, which makes footprints meaningless.
#
# TERMINAL LOCK: only one terminal instance per data folder can run, and other agents use the same terminal.
# Before each launch the script atomically creates <workspace>\build\terminal.lock (CreateNew), polls every
# 45 s while it exists, deletes it as soon as the terminal has exited, and waits -LockGapSec (90 s) before
# taking it again for the next run. A lock is stale only if it is older than 60 min AND no terminal64 from
# C:\Program Files\MetaTrader 5 is running. The script never kills a terminal it did not start.
param(
   [string[]]$Runs = @("signals", "virtual", "live"),
   [string]$From = "2026.09.07",
   [string]$To   = "2026.09.26",
   [string]$Tag  = "",
   [string]$SetFile = "",
   [string[]]$Params = @(),
   [int]$Deposit = 10000,
   [string]$Leverage = "1:100",
   [int]$TimeoutSec = 1500,
   [int]$LockGapSec = 90,
   [string]$LockOwner = "frequency-agent (mt5_run_tester.ps1)"
)
$Terminal   = "C:\Program Files\MetaTrader 5\terminal64.exe"
$DataDir    = "C:\Users\ganzo\AppData\Roaming\MetaQuotes\Terminal\D0E8209F77C8CF37AD8BF550E51FF075"
$TesterRoot = "C:\Users\ganzo\AppData\Roaming\MetaQuotes\Tester\D0E8209F77C8CF37AD8BF550E51FF075"
$Workspace  = Split-Path -Parent $PSScriptRoot
$OutRoot    = Join-Path $Workspace "build\tester"
$LockFile   = Join-Path $Workspace "build\terminal.lock"

function Get-OurTerminal { Get-Process terminal64 -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $Terminal } }

# Age of the lock = time since the NEWEST of its creation time, last write time and any timestamp written inside it.
# The workspace lives in OneDrive, which can restore old file times, so file times alone can make a fresh lock look stale.
function Get-LockAgeMinutes {
   $it = Get-Item $LockFile -ErrorAction Stop
   $newest = $it.LastWriteTime
   if ($it.CreationTime -gt $newest) { $newest = $it.CreationTime }
   $txt = (Get-Content $LockFile -Raw -ErrorAction SilentlyContinue)
   if ($txt) {
      foreach ($m in [regex]::Matches($txt, "\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}")) {
         $t = [datetime]::MinValue
         if ([datetime]::TryParse($m.Value, [ref]$t) -and $t -gt $newest) { $newest = $t }
      }
   }
   return ((Get-Date) - $newest).TotalMinutes
}

function Acquire-TerminalLock {
   while ($true) {
      try {
         $fs = [IO.File]::Open($LockFile, 'CreateNew', 'Write')
         $txt = [Text.Encoding]::UTF8.GetBytes("$LockOwner $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))`r`n")
         $fs.Write($txt, 0, $txt.Length)
         $fs.Close()
         return
      } catch {
         $age = $null
         try { $age = Get-LockAgeMinutes } catch { continue }
         if ($age -gt 60 -and -not (Get-OurTerminal)) {
            Write-Output "   stale lock ($([int]$age) min, no terminal running) - removing it"
            Remove-Item $LockFile -Force -ErrorAction SilentlyContinue
            continue
         }
         $who = (Get-Content $LockFile -ErrorAction SilentlyContinue | Select-Object -First 1)
         Write-Output "   terminal lock held by '$who' - waiting"
         Start-Sleep -Seconds 45
      }
   }
}
function Release-TerminalLock { Remove-Item $LockFile -Force -ErrorAction SilentlyContinue }

function Merge-Params([string[]]$lines) {
   # ordered "Name=value" merge, last one wins
   $map = [ordered]@{}
   foreach ($l in $lines) {
      $s = "$l".Trim()
      if ($s -eq "" -or $s.StartsWith(";") -or -not $s.Contains("=")) { continue }
      $k = $s.Substring(0, $s.IndexOf("=")).Trim()
      $map[$k] = $s
   }
   return @($map.Values)
}

$fromDt = [datetime]::ParseExact($From, "yyyy.MM.dd", $null)
function UnixAt([int]$days) { [int64]($fromDt.AddDays($days).AddHours(10) - [datetime]'1970-01-01').TotalSeconds }
$common = @("InpSource=3", "InpMaxSignalLagSec=10")      # explicit QUOTE_TICKS: AUTO waits for ticks in the tester
$sets = @{
   "signals"  = $common + @("InpTradeMode=0", "InpDumpBars=true")
   "virtual"  = $common + @("InpTradeMode=1")
   "live"     = $common + @("InpTradeMode=2")
   "hooks"    = $common + @("InpTradeMode=2", "InpTestResetKill=true",
                            "InpTestDailyLossAt=$(UnixAt 2)", "InpTestConsecLossAt=$(UnixAt 8)", "InpTestKillAt=$(UnixAt 16)")
   "research" = $common + @("InpTradeMode=1", "InpResearchAllSignals=true", "InpDumpBars=true",
                            "InpMaxTradesPerDay=0", "InpMaxDailyLossPct=0", "InpMaxConsecLosses=0", "InpMaxDDPct=0")
}
$base = @()
if ($SetFile -ne "") {
   $sf = if ([IO.Path]::IsPathRooted($SetFile)) { $SetFile } else { Join-Path $Workspace $SetFile }
   if (-not (Test-Path $sf)) { throw "set file not found: $sf" }
   $base = @(Get-Content $sf | Where-Object { $_ -match "=" })
}
$first = $true
foreach ($run in $Runs) {
   if (-not $sets.ContainsKey($run)) { Write-Output "unknown run '$run'"; continue }
   $name = if ($Tag -ne "") { "${run}_$Tag" } else { $run }
   $out = Join-Path $OutRoot $name
   New-Item -ItemType Directory -Force $out | Out-Null
   Get-ChildItem $out -File | Remove-Item -Force
   $lines = Merge-Params ($base + $sets[$run] + $Params)
   $setName = "FT_$name.set"
   $lines | Set-Content (Join-Path $DataDir "MQL5\Profiles\Tester\$setName") -Encoding Unicode
   $lines | Set-Content (Join-Path $out "inputs.set") -Encoding utf8
   $ini = Join-Path $out "tester.ini"
   @(
      "[Tester]", "Expert=OrderFlowFP\FootprintTrader", "ExpertParameters=$setName",
      "Symbol=XAUUSD", "Period=M5", "Model=4", "ExecutionMode=0", "Optimization=0",
      "FromDate=$From", "ToDate=$To", "ForwardMode=0", "Deposit=$Deposit", "Currency=USD", "Leverage=$Leverage",
      "Visual=0", "ReplaceReport=1", "Report=FT_$name", "ShutdownTerminal=1"
   ) | Set-Content $ini -Encoding Unicode

   if (-not $first) { Write-Output "   lock gap: waiting $LockGapSec s so other agents can take the terminal"; Start-Sleep -Seconds $LockGapSec }
   $first = $false
   Acquire-TerminalLock
   try {
      if (Get-OurTerminal) { throw "the standard terminal is already running although the lock was free - not started" }
      # the EA appends to its CSVs: clear our folder in every agent sandbox first
      Get-ChildItem $TesterRoot -Directory -Filter "Agent-*" -ErrorAction SilentlyContinue | ForEach-Object {
         $f = Join-Path $_.FullName "MQL5\Files\OrderFlowFP"
         if (Test-Path $f) { Remove-Item "$f\*" -Force -ErrorAction SilentlyContinue }
      }
      # agent logs are appended per day: remember their sizes so only this run's lines are kept
      $logName = (Get-Date).ToString("yyyyMMdd") + ".log"
      $before = @{}
      Get-ChildItem $TesterRoot -Directory -Filter "Agent-*" -ErrorAction SilentlyContinue | ForEach-Object {
         $lg = Join-Path $_.FullName "logs\$logName"
         $before[$_.Name] = if (Test-Path $lg) { (Get-Content $lg -Encoding Unicode | Measure-Object).Count } else { 0 }
      }
      $start = Get-Date
      Write-Output "== $name started $($start.ToString('HH:mm:ss'))  ($From .. $To)"
      $p = Start-Process -FilePath $Terminal -ArgumentList "/config:`"$ini`"" -PassThru
      if (-not $p.WaitForExit($TimeoutSec * 1000)) { Stop-Process -Id $p.Id -Force; Write-Output "   TIMEOUT after $TimeoutSec s (killed our own terminal)" }
      Write-Output "   finished in $([int]((Get-Date) - $start).TotalSeconds) s"
   } finally {
      Release-TerminalLock
   }

   Get-ChildItem $TesterRoot -Directory -Filter "Agent-*" -ErrorAction SilentlyContinue | ForEach-Object {
      $agent = $_
      $f = Join-Path $agent.FullName "MQL5\Files\OrderFlowFP"
      if (Test-Path $f) { Get-ChildItem $f -File | ForEach-Object { Copy-Item $_.FullName $out -Force } }
      $lg = Join-Path $agent.FullName "logs\$logName"
      if (Test-Path $lg) {
         $skip = if ($before.ContainsKey($agent.Name)) { $before[$agent.Name] } else { 0 }
         $new = @(Get-Content $lg -Encoding Unicode | Select-Object -Skip $skip)
         if ($new.Count -gt 0) { $new | Set-Content (Join-Path $out "agent_$($agent.Name).log") -Encoding utf8 }
      }
   }
   Get-ChildItem $DataDir -File -Filter "FT_$name*" | ForEach-Object { Copy-Item $_.FullName $out -Force }
   $agentLog = Get-ChildItem $out -Filter "agent_*.log" | Select-Object -First 1
   if ($agentLog) {
      Get-Content $agentLog.FullName | ForEach-Object { ($_ -split "`t")[-1] } |
         Select-String -Pattern "real ticks absent|history ready|FT WARMUP|ASSERT|KILL SWITCH|FT PERF|FT ONTESTER|final balance|Test passed|mismatches=[1-9]" |
         Select-Object -First 15 | ForEach-Object { Write-Output ("   " + $_.Line.Substring(0, [Math]::Min(200, $_.Line.Length))) }
   }
   Write-Output "   outputs: $out"
}
