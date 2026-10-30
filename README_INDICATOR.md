# OrderFlowFP — FootprintChart indicator

`Indicators\OrderFlowFP\FootprintChart.mq5` turns an MT5 chart into a footprint and order-flow workspace. It covers the whole chart area with one canvas:

- a Minimalist footprint (`SELL x BUY` per price row) with its own price scale;
- a summary table;
- a header and style tabs;
- side panels: Chart Analyst, Signal Meter, DOM ladder, Time & Sales, RSI/MACD and VP Total.

It uses the same OrderFlowFP engine as the FootprintTrader EA, so the numbers are the same.

> **Display only.** The indicator never trades.
>
> The **Chart Analyst** text and the **Signal Meter** score are rule-generated descriptions for the eye. They are **not** the EA's entry logic and the EA does not read them. The EA's setups are described in `README_EA.md`.

## Install / build

1. `& .\tools\build.ps1 -Targets Indicators\OrderFlowFP\FootprintChart.mq5` copies the sources into the demo terminal and compiles them (0 errors, 0 warnings).
2. In MT5, drag **Indicators › OrderFlowFP › FootprintChart** onto an XAUUSD M5 chart (any symbol, M1–D1).
3. The EA can attach it itself (`InpAttachIndicator=true`). It then runs with the default inputs below.

The first load builds about 300 closed bars (plus whole sessions) from ticks, which takes about 15–20 s. Bars still loading show a dim `loading`. Bars without ticks in the terminal show `no data`. The indicator never estimates volumes from OHLC.

On XAUUSD the source is **QUOTE ticks**: every number is a tick count, i.e. relative activity, not traded lots. The status text in the tab row (or at the bottom-left) shows the source, the row size, the history progress and the draw time.

## Screen layout

| Area | What it shows |
|---|---|
| Header | First, the **FootprintTrader status badge** (v1.11): green = EA live and trading, blue = signals only / virtual, orange = entries paused, red = EA off or stopped. It reads the EA with magic `InpTradeMagic`; README_EA.md §6a lists every text. Then the toggles **SUPPLY & DEMAND ZONES**, FUNDAMENTALS (not implemented, greyed), **MINI SESSION CHART**. The ticker: symbol (gold), last price (blue), change vs the D1 open. Trend boxes 5M/15M/1H/4H/D1: ▲ if EMA(9) > EMA(21) on that timeframe's last closed bar, ▼ otherwise. Bias labels `HTF:` (H4 rule) and `<chart TF>:`. On the right the buttons below. |
| Style tabs | MINIMALIST is active. The other 8 styles are not implemented and are greyed. `−` collapses the row; `+` in the header brings it back. |
| Footprint | One column per bar, newest on the right. Each row reads `SELL x BUY`. The left number is volume that hit the bid, the right number volume that lifted the ask. Imbalances (diagonal, 3 tiers) are bold and larger: sellers red on the left number, buyers green on the right. Rows with no trades inside the bar show a dim `0 x 0`. Below 14 px row height the columns become compact candles. |
| Own price scale | Price labels, the current price tag (bull/bear colour of the forming bar, with a dim `BID` label), and the trade tags. |
| Session POC | Dashed purple line, labelled `POC`, at the point of control of the current session's closed bars. |
| Mini session chart | M1 closes since the session start, the session open (dashed) and the last price (dot). Caption: session move %, the session window in local time, M1 bar count. |
| Summary table | Per visible bar: Volume, Delta, Cum Delta (session), Ask (= buy volume), Bid (= sell volume), heat-coloured. The header row has the bar times and the countdown to bar close (green, then yellow ≤ 30 s, orange ≤ 20 s, red ≤ 10 s). `−` collapses it. |
| Chart Analyst | 9 sections of rule text: pair info, trend + HTF, DOM, Time & Sales, order flow, volume, imbalances, key levels, setup/advisor summary. Refreshed every 30 s and at every bar close. **Not trading advice.** |
| Signal Meter | Gauge from −100 to +100 with a verdict (STRONG SELL … STRONG BUY). 11 rows: RSI, MACD, MA 9/21/50, VWAP, ATR regime, POC position, Delta, Cum Delta, Vol B/S. Each row votes +1/0/−1 and the ATR regime scales the score. **Not the EA's signal.** |
| DOM ladder | Rows at the footprint row size around the price. Sold/Bot/D/Vol come from the forming bar. Bid/Ask come from the broker's market book; without one it shows `NO BOOK - FOOTPRINT ONLY` and never invents depth. |
| Time & Sales | The engine's classified prints, newest first: buys in the bull colour, sells in the bear colour, merged per side/price/second. **Bar Totals** shows B and S for the forming bar. |
| RSI(14) / MACD | Mini charts of the chart timeframe. |
| VP Total | Volume profile of the last 50 bars (or of the session), with VAH / POC / VAL. |

Side panels hide automatically when the chart is narrower than 1500 px × UI scale (e.g. a docked chart on a 150 % screen). Press **SIDE PANELS** to force them on.

## Buttons

| Button | Action |
|---|---|
| RESET | Default zoom, back to live, re-centre. Also reloads the history if some bars had no data. |
| ZOOM IN / ZOOM OUT | Row height ±2 px (6–40). Below 14 px you get compact candles. |
| UP / DOWN | Move the view 80 px up or down. This stops vertical auto-follow until LIVE or RESET. |
| BAR VOLUME PROFILE | A horizontal volume bar behind each column's numbers: sell part red, buy part green, POC row gold. |
| DELTA BARS | A box with the bar delta under each column. |
| SIDE PANELS | Show or hide the right column. |
| LIVE | Back to the newest bar with auto-follow (blue while live). |
| SUPPLY & DEMAND ZONES | Up to 4 pivot zones (strength 8, volume filter). They flip role on a close beyond the far edge and turn grey once their middle is touched. |
| MINI SESSION CHART | Show or hide the mini chart. |

## Mouse and keyboard

- **Wheel** over the footprint: zoom the row height.
- **Shift + wheel**: scroll through history (3 bars per notch).
- **Left-drag** on the footprint: pan horizontally through history and vertically through price.
- **Home**: LIVE.
- **← / →**: one bar older / newer.
- **↑ / ↓**: move 80 px.
- **+ / −**: zoom.
- **T**: next of the 16 bull/bear colour themes.
- **L**: switch Dark / Light panels.

While the indicator runs, the native chart's own keyboard scrolling and mouse scrolling are off. Every chart property the indicator changed is restored when it is removed.

In the Strategy Tester (visual mode) the buttons are shown inactive, because indicators receive no chart events there.

## EA trade overlay

With `InpShowTrades=true` (default), the trades of the EA (`InpTradeMagic`, default 240611; `-1` = all magics) on the chart symbol are drawn on the footprint. The overlay is read-only and polled every 500 ms.

- **Open positions:** entry line (BUY blue / SELL pink), SL line (red) and TP line (green) across the footprint. The left end shows side, lots, price, floating P/L and ticket. Tags on the price scale: `BUY 0.05`, `SL`, `TP`.
- **Pending orders:** the same, with dashed lines and outlined tags, e.g. `BUY STOP 0.05`.
- **Closed trades** whose bars are held: an entry triangle and an exit square at the bar column and price, joined by a dashed line. The line is in the theme's bull colour for a profit and the bear colour for a loss.

## Inputs

| Group | Input | Default | Meaning |
|---|---|---|---|
| Data | InpSource | AUTO | Volume source (AUTO / EXCHANGE_FLAGS / TRADE_TICKS / QUOTE_TICKS). Set it like the EA for identical numbers. |
| | InpBucketPoints | 0 | Row size in points (0 = preset/auto, XAUUSD = 0.40). |
| | InpQuotePrice | BID | QUOTE-mode row price (BID or MID). |
| | InpHistoryBars | 300 | Minimum number of closed bars to build. |
| | InpSessionStart | 00:00 | Session start, server time. Cum delta, session POC and VWAP reset here. |
| | InpValueAreaPct | 70 | Value area in % (VP Total). |
| Imbalance | InpImbRatio1/2/3 | 2 / 3 / 4 | Tier ratios. |
| | InpImbMinVolume | 10 | Minimum volume of the dominant side. |
| | InpImbBold, InpImbBoost1/2/3 | true, 1/2/3 | Bold numbers and font boost in px. |
| | InpBuyImbColor / InpSellImbColor | green / red | Imbalance colours. |
| | InpBuy/SellImbColorT1..T3 | None | Optional per-tier colours (None = base colour). |
| | InpThemeOverridesImbalance | false | Use the theme's bull/bear colours instead. |
| | InpStackMinRows | 3 | Rows for a stacked imbalance. |
| | InpShowStackZones / InpStackZoneBars / InpShowFilledZones | true / 20 / false | Stacked-imbalance zones: show, length in bars, show filled ones faintly. |
| Display | InpStyle | MINIMALIST | Only Minimalist is implemented. |
| | InpPanelTheme / InpColorTheme | DARK / 9 Orange-Dark grey | 2 × 16 themes. |
| | InpBarWidth / InpBarSpacing / InpRowHeight / InpMinCellHeight | 55 / 14 / 16 / 14 | Geometry in px at 100 % scale. |
| | InpFontNumbers / InpFontUI / InpNumberFontSize | Consolas / Segoe UI / 10 | Fonts. |
| | InpUIScalePct | 100 | UI scale, multiplied by the screen DPI / 96. |
| | InpShowSidePanels, InpShowSummaryTable, InpShowMiniChart, InpShowSessionPOC | true | Areas at start. |
| | InpShowPerBarPOC, InpShowDeltaBars, InpShowBarVP, InpShowSDZones | false | Optional overlays at start (the last three are also header buttons). |
| | InpShowFundamentals | false | Not implemented (MAY item). |
| | InpHideNativeChart | false | Hide the native chart entirely (CHART_SHOW = false). |
| Panels | InpVPMode / InpVPBars | BARS / 50 | VP Total range. |
| | InpTasRows / InpTasAggregate / InpTasBigSize | 30 / true / 0 | T&S rows (max), merging, bold size (0 = auto 95th percentile). |
| | InpUseMarketBook / InpDomLevels | true / 12 | DOM book subscription, levels above and below. |
| | InpAnalystRefreshSec | 30 | Chart Analyst refresh. |
| Studies | InpMA1/2/3, InpRSIPeriod, InpMACDFast/Slow/Signal, InpATRPeriod, InpATRBaseLen, InpATRTrend, InpATRChop, InpPOCAccBars, InpPOCAccTicks | 9/21/50, 14, 12/26/9, 14, 50, 1.15, 0.85, 3, 1.5 | Studies of the meter, analyst and header (EMAs). |
| S&D | InpSDSwing, InpSDLookback, InpSDVolLen, InpSDVolRatio, InpSDATRLen, InpSDWidthDiv, InpSDMaxZones | 8, 200, 20, 1.2, 50, 4, 4 | Supply & demand zone rules. |
| Performance | InpRedrawMs / InpLoadBudgetMs | 100 / 40 | Minimum time between redraws; history loading budget per 50 ms timer. |
| Alerts | InpAlertStack, InpAlertDeltaAbove, InpAlertDeltaBelow, InpAlertPopup, InpAlertSound | false, 0, 0, true, alert.wav | Once per closed live bar per type, never from history. `DeltaBelow` fires at delta ≤ −\|value\|. With popup off, the alert is logged and the sound is played. |
| Trades | InpShowTrades / InpTradeMagic | true / 240611 | EA trade overlay; −1 = all magics. |

## Data Window

There are 8 hidden plots per chart bar: FP Volume, FP Delta, FP CumDelta, FP POC price (bottom of the POC row), FP BuyImb count, FP SellImb count, FP BuyStack rows, FP SellStack rows. They are empty where the engine holds no finished data.

## Performance (measured on this PC)

| Chart area | Scale | Average redraw |
|---|---|---|
| 1857×978, side panels | 100 % | 4–5 ms |
| 2487×1408 | 150 % | ~8.4 ms |

The redraw time is logged every 100 frames. While history loads, the chart stays usable: about 50 ms of work per 50 ms timer, with occasional 0.1–1 s steps on a cold tick cache inside the engine.

## Known limitations

- Only the Minimalist style; no Fundamentals panel.
- Two FootprintChart instances on one chart work, but remove them in reverse order so the chart properties are restored correctly.
- The trade overlay has been verified by code review only. No EA trades existed during the build.
