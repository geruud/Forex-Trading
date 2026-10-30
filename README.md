# Forex-Trading — OrderFlowFP footprint indicator and FootprintTrader EA (MQL5)

An MT5 order-flow footprint engine shared by two programs: the **FootprintChart** indicator (display only) and the **FootprintTrader** Expert Advisor.

> On Forex/CFD symbols such as XAUUSD, "volume" is the count of quote ticks, not exchange volume. The v1.10 defaults showed no robust edge in testing (see `docs/decisions/frequency.md`). Demo only.

## Layout

The `MQL5/` tree mirrors the MT5 data folder, so `tools\build.ps1` can copy it there as is.

| Path | Contents |
|---|---|
| `MQL5/Include/OrderFlowFP/` | Engine (`FPTypes`, `FPClassifier`, `FPAnalytics`, `FPPresets`, `FPEngine`, `FPDump`) and signal layer (`FPSignalTypes`, `FPSignals`) |
| `MQL5/Include/OrderFlowFP/Trade/` | `FPFilters`, `FPRisk`, `FPExecution`, `FPJournal` (EA only) |
| `MQL5/Include/OrderFlowFP/UI/` | Canvas, layout, renderer, panels, themes (indicator only; the EA never includes these) |
| `MQL5/Experts/OrderFlowFP/FootprintTrader.mq5` | The EA |
| `MQL5/Indicators/OrderFlowFP/FootprintChart.mq5` | The footprint indicator |
| `MQL5/Scripts/OrderFlowFP/` | `FPTests`, `FPSignalTests`, `FPDumpBars`, `FPShot` |
| `MQL5/Presets/FootprintTrader_spec.set` | Every EA input at its original spec value |
| `tools/` | `build.ps1` (deploy + compile), `mt5_run_script.ps1`, `mt5_run_tester.ps1`, `mt5_screenshot.ps1`, `fp_analyze.py` |
| `docs/` | `TRADE_LOGIC.md`, `EA_ARCHITECTURE.md`, `decisions/` (engine, signals, trade, ui, frequency), the 2026-10-27 handover note |
| `spec/` | The video analysis and the two build prompts, with their `reference/` images |
| `build/` | Last compile logs, test-run logs and indicator screenshots from the demo terminal |

Start with `README_EA.md` (EA: install, modes, inputs, validation protocol), `README_INDICATOR.md` and `DECISIONS.md`.

## Build

From PowerShell in the repository root:

```powershell
& .\tools\build.ps1
```

`build.ps1` defaults to the author's demo-terminal paths; pass `-DataDir` and `-TerminalDir` on another machine.
