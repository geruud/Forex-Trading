# mt5_screenshot.ps1 - screenshot loop for the FootprintChart indicator (STANDARD demo terminal only).
# Writes one chart template per variant (MQL5\Profiles\Templates\fp_shot_<name>.tpl, indicator + inputs),
# runs Scripts\OrderFlowFP\FPShot via a [StartUp] config (ShutdownTerminal=1), and copies the PNGs to build\shots\.
# Respects the shared terminal lock build\terminal.lock (see the other agent's protocol).
# Examples:
#   & .\tools\mt5_screenshot.ps1                                  # default variants
#   & .\tools\mt5_screenshot.ps1 -Variants dark_orange -TimeoutSec 400
param(
   [string[]]$Variants = @("dark_orange", "dark_green", "light_classic", "noside_light"),
   [string]$Symbol = "XAUUSD",
   [string]$Period = "M5",
   [int]$TimeoutSec = 900,
   [int]$SettleSec = 6,             # wait after ready=1 before each shot (longer = more frames for the draw-time log)
   [hashtable]$Extra = @{}          # extra indicator inputs for every variant, e.g. @{ InpShowDeltaBars = "true" }
)
$Terminal  = "C:\Program Files\MetaTrader 5\terminal64.exe"
$DataDir   = "C:\Users\ganzo\AppData\Roaming\MetaQuotes\Terminal\D0E8209F77C8CF37AD8BF550E51FF075"
$Workspace = Split-Path -Parent $PSScriptRoot
$OutDir    = Join-Path $Workspace "build\shots"
$RunDir    = Join-Path $Workspace "build\runs"
$Lock      = Join-Path $Workspace "build\terminal.lock"
New-Item -ItemType Directory -Force $OutDir, $RunDir | Out-Null

# --- variant definitions: indicator inputs (enum values as integers). "_float" = undocked chart window WxH in screen px
#     (the reference frames are 1920x1080 at 100 % scale; this screen is 150 % DPI, so InpUIScalePct=67 gives s = 1.0)
$refGeo = "1890x1090"
$defs = @{
   "dark_orange"     = @{ _float = $refGeo;    InpUIScalePct = "67";  InpPanelTheme = "0"; InpColorTheme = "8" }
   "dark_green"      = @{ _float = $refGeo;    InpUIScalePct = "67";  InpPanelTheme = "0"; InpColorTheme = "9" }
   "light_classic"   = @{ _float = $refGeo;    InpUIScalePct = "67";  InpPanelTheme = "1"; InpColorTheme = "0" }
   "light_blue"      = @{ _float = $refGeo;    InpUIScalePct = "67";  InpPanelTheme = "1"; InpColorTheme = "1" }
   "noside_light"    = @{ _float = $refGeo;    InpUIScalePct = "67";  InpPanelTheme = "1"; InpColorTheme = "1"; InpShowSidePanels = "false"; InpShowDeltaBars = "true"; InpShowSDZones = "true" }
   "noside_dark"     = @{ _float = $refGeo;    InpUIScalePct = "67";  InpPanelTheme = "0"; InpColorTheme = "8"; InpShowSidePanels = "false" }
   "dark_extras"     = @{ _float = $refGeo;    InpUIScalePct = "67";  InpPanelTheme = "0"; InpColorTheme = "8"; InpShowBarVP = "true"; InpShowDeltaBars = "true"; InpShowPerBarPOC = "true"; InpShowSDZones = "true" }
   "compact"         = @{ _float = $refGeo;    InpUIScalePct = "67";  InpPanelTheme = "0"; InpColorTheme = "9"; InpRowHeight = "8" }
   "default_big"     = @{ _float = "2520x1520" }                     # all defaults (what the EA attaches), 150 % DPI
   "default_docked"  = @{ }                                          # all defaults in the docked chart as the terminal opens it
   "zones"           = @{ _float = $refGeo;    InpUIScalePct = "67";  InpPanelTheme = "0"; InpColorTheme = "0"; InpShowSidePanels = "false"; InpShowFilledZones = "true"; InpStackMinRows = "2" }
   "alerts"          = @{ _float = $refGeo;    InpUIScalePct = "67";  InpPanelTheme = "0"; InpColorTheme = "8"; InpAlertStack = "true"; InpAlertDeltaAbove = "1"; InpAlertDeltaBelow = "1"; InpAlertPopup = "false"; InpAlertSound = "" }
   "nav"             = @{ _float = $refGeo;    InpUIScalePct = "67";  InpPanelTheme = "0"; InpColorTheme = "8" }   # buttons/keys via test hooks
   "icustom"         = @{ }                                       # no template: iCustom + ChartIndicatorAdd(0,0,h) like the EA, buffers read back
}

$tplDir = Join-Path $DataDir "MQL5\Profiles\Templates"
$names = @()
$specs = @()
foreach ($v in $Variants) {
   if (-not $defs.ContainsKey($v)) { throw "unknown variant '$v' (known: $($defs.Keys -join ', '))" }
   $inputs = $defs[$v].Clone()
   $float = ""
   if ($inputs.ContainsKey("_float")) { $float = $inputs["_float"]; $inputs.Remove("_float") }
   foreach ($k in $Extra.Keys) { $inputs[$k] = [string]$Extra[$k] }
   $inLines = ($inputs.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join "`r`n"
   $bg = if ($inputs["InpPanelTheme"] -eq "1") { "16316664" } else { "1511695" }
   $tpl = @"
<chart>
symbol=$Symbol
period_type=0
period_size=5
digits=2
tick_size=0.000000
position_time=0
scale_fix=0
scale_fixed_min=0.000000
scale_fixed_max=0.000000
scale_fix11=0
scale_bar=0
scale_bar_val=1.000000
scale=4
mode=1
fore=0
grid=0
volume=0
scroll=1
shift=1
shift_size=20.000000
fixed_pos=0.000000
ohlc=0
one_click=0
one_click_btn=0
bidline=0
askline=0
lastline=0
days=0
descriptions=0
tradelines=0
window_left=0
window_top=0
window_right=0
window_bottom=0
window_type=3
background_color=$bg
foreground_color=8421504
barup_color=8421504
bardown_color=8421504
bullcandle_color=8421504
bearcandle_color=8421504
chartline_color=8421504
volumes_color=8421504
grid_color=8421504
bidline_color=8421504
askline_color=8421504
lastline_color=8421504
stops_color=8421504
windows_total=1

<window>
height=100.000000
objects=0

<indicator>
name=Main
path=
apply=1
show_data=1
scale_inherit=0
scale_line=0
scale_line_percent=50
scale_line_value=0.000000
scale_fix_min=0
scale_fix_min_val=0.000000
scale_fix_max=0
scale_fix_max_val=0.000000
expertmode=0
fixed_height=-1
</indicator>

<indicator>
name=Custom Indicator
path=Indicators\OrderFlowFP\FootprintChart.ex5
apply=0
show_data=1
scale_inherit=0
scale_line=0
scale_line_percent=50
scale_line_value=0.000000
scale_fix_min=0
scale_fix_min_val=0.000000
scale_fix_max=0
scale_fix_max_val=0.000000
expertmode=0
fixed_height=-1

<inputs>
$inLines
</inputs>
</indicator>
</window>
</chart>
"@
   $name = "fp_shot_$v"
   $tpl | Set-Content (Join-Path $tplDir "$name.tpl") -Encoding Unicode
   $names += $name
   if ($float -ne "") { $specs += "$name`:$float" } else { $specs += $name }
}

# --- script parameters + startup config
$presets = Join-Path $DataDir "MQL5\Presets"
New-Item -ItemType Directory -Force $presets | Out-Null
@("InpVariants=$($specs -join ',')","InpMaxWaitSec=150", "InpSettleSec=$SettleSec","InpHideScales=true") | Set-Content (Join-Path $presets "FPShot_run.set") -Encoding Unicode
$ini = Join-Path $RunDir "startup_FPShot.ini"
@("[StartUp]", "Script=OrderFlowFP\FPShot", "Symbol=$Symbol", "Period=$Period", "ScriptParameters=FPShot_run.set", "ShutdownTerminal=1") | Set-Content $ini -Encoding Unicode

# --- acquire the shared terminal lock
$me = "ui-agent FPShot $($Variants -join ',')"
while ($true) {
   try {
      $fs = [IO.File]::Open($Lock, 'CreateNew', 'Write')
      $sw = New-Object IO.StreamWriter($fs)
      $sw.WriteLine("$me $(Get-Date -Format o)")
      $sw.Close()
      break
   } catch {
      $running = Get-Process terminal64 -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $Terminal }
      $age = 0
      if (Test-Path $Lock) { $age = ((Get-Date) - (Get-Item $Lock).LastWriteTime).TotalMinutes }
      if ($age -gt 60 -and -not $running) { Write-Output "stale lock ($([int]$age) min, no terminal) - removing"; Remove-Item $Lock -Force -ErrorAction SilentlyContinue; continue }
      $who = if (Test-Path $Lock) { (Get-Content $Lock -ErrorAction SilentlyContinue) -join ' ' } else { "?" }
      Write-Output "$(Get-Date -Format T) lock held by: $who - waiting"
      Start-Sleep -Seconds 45
   }
}

try {
   if (Get-Process terminal64 -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $Terminal }) { throw "the standard terminal is already running although the lock was free - not starting a second instance" }
   $start = Get-Date
   $log  = Join-Path $DataDir ("MQL5\Logs\" + $start.ToString("yyyyMMdd") + ".log")
   $base = 0
   if (Test-Path $log) { $base = (Get-Content $log -Encoding Unicode | Measure-Object).Count }
   $filesDir = Join-Path $DataDir "MQL5\Files\OrderFlowFP"
   foreach ($n in $names) { Get-ChildItem $filesDir -Filter "$n*.png" -ErrorAction SilentlyContinue | Remove-Item -Force }
   $p = Start-Process -FilePath $Terminal -ArgumentList "/config:`"$ini`"" -PassThru
   $exited = $p.WaitForExit($TimeoutSec * 1000)
   if (-not $exited) {
      Write-Output "TIMEOUT after $TimeoutSec s - closing the terminal I started"
      $null = $p.CloseMainWindow(); $p.WaitForExit(20000) | Out-Null
      if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
   }
   Write-Output "terminal exited after $([int]((Get-Date) - $start).TotalSeconds) s"
   if (Test-Path $log) {
      $lines = @(Get-Content $log -Encoding Unicode | Select-Object -Skip $base)
      $out = Join-Path $RunDir "log_FPShot.txt"
      $lines | Set-Content $out -Encoding utf8
      $lines | Where-Object { $_ -match "FPShot|OrderFlowFP UI|error|ERR|cannot|failed|array out|Stacked imbalance|Delta above|Delta below" } | Select-Object -First 120 | ForEach-Object { Write-Output "  $_" }
      Write-Output "log: $out"
   }
   foreach ($n in $names) {
      $found = @(Get-ChildItem $filesDir -Filter "$n*.png" -ErrorAction SilentlyContinue)
      if ($found.Count -eq 0) { Write-Output "MISSING: $n.png"; continue }
      foreach ($f in $found) { $dst = Join-Path $OutDir $f.Name; Copy-Item $f.FullName $dst -Force; Write-Output "SHOT: $dst" }
   }
}
finally {
   Remove-Item $Lock -Force -ErrorAction SilentlyContinue
   Write-Output "lock released"
}
