# Video analysis & reconstruction spec — MT5 "Minimalist" Footprint / Order-Flow chart

Source video: "The Cleanest MT5 Footprint Chart: Minimalist Order Flow & Imbalances" (YouTube `XM19uVHeKJo`, channel Silver Sleek FX, 2026-03-28, 6:30, music only — no narration).
It is a promo for the MQL5 Market product #160805 ("Order flow footprint chart", vendor brand RETAILBERG, v6.3x at the time of the video, v7.0 today).

How this was analysed: the video was downloaded and sampled every 2 s (195 frames). Key regions were cropped and zoomed, and colours were pixel-sampled. The vendor's public documentation was read in full: the 150-page v7 manual, the settings guide, the change log, the buyer comments and the narrated 56-min walkthrough `BSAyYeZd7Tw`. Confidence tags: **HIGH** = seen clearly in several frames and/or documented; **MED** = one source or indirect; **LOW / ASSUMPTION** = our design choice where nothing shows the answer.

Files in this folder:

| File | Purpose |
|---|---|
| `01_Video_Analysis_and_Spec.md` | This document: what the video shows and the decisions behind the prompts |
| `02_PROMPT_Footprint_Indicator.md` | Paste into an AI coder (Claude Code / Codex / ChatGPT) to build the MT5 footprint indicator |
| `03_PROMPT_Footprint_EA.md` | Paste **after** the indicator project exists, to build the trading EA on the same engine |
| `reference/` | 12 images to attach to the coder if it accepts images |

---

## 1. Key findings (read these first)

1. **What the video shows is a workspace, not just a footprint (HIGH).** It is one full-window drawing with these parts:
   - a header bar and a style-tab row;
   - the footprint panel, with a mini session chart overlaid top-left;
   - a bottom summary table;
   - a right-hand column of panels: Chart Analyst, Signal Meter, DOM ladder, Time & Sales with RSI/MACD, and a "VP Total" volume profile.

   The vendor ships it as an *Expert Advisor that never trades*. It draws everything itself and hides the native MT5 candles.
2. **"Minimalist" = numbers only (HIGH).** Each bar is a column of `sell x buy` number pairs, one per price row. There is no body, wick or frame. Imbalanced numbers are coloured: sell imbalance in red/pink on the left number, buy imbalance in green on the right number. The separator is a small dim "x".
3. **The volumes in the video are estimates (HIGH, from the vendor's own v7 manual).** v6.3x estimated the buy/sell split from price movement and OHLC; v7 switched to a real tick engine. ⇒ **Reproduce the look and the rules, not the exact numbers.** Our build uses a proper tick engine:
   - If the feed has exchange buy/sell flags, use them.
   - Otherwise classify by bid/ask quote.
   - Otherwise use the tick rule.
4. **The imbalance rule is diagonal (HIGH, documented and verified on the vendor's figures).**
   - Buy imbalance at row *p* when `Buy[p] ≥ R × Sell[p−1]` (the row below).
   - Sell imbalance at row *p* when `Sell[p] ≥ R × Buy[p+1]` (the row above).
   - Three tiers, R = 2.0 / 3.0 / 4.0, minimum volume 10. Tiers get bold text and a +1/+2/+3 size boost.
   - The colouring in the video frames does **not** fit this rule exactly (e.g. `283` red vs `178` above = 1.59×). That is consistent with the estimated v6 numbers. We use the documented rule, fully parameterised.
5. **On Forex/CFD symbols (e.g. XAUUSD at your broker) there is no real traded volume.** Each quote change counts as 1 and the side comes from price direction, exactly like MT5 tick volume. This is "relative activity", not institutional volume. Futures feeds with `TICK_FLAG_BUY/SELL` give real footprints. The video's `@GCE / @MES / @ENQ` symbols are futures on an exchange-feed broker. This matters a lot for the EA (§10).

---

## 2. Video timeline

| Time | Content |
|---|---|
| 0:00–0:05 | Logo intro, then a "MINIMALIST STYLE" title overlay |
| 0:05–3:25 | Dark panel theme, full workspace. Cycles through the colour themes (orange/dark-grey, green, blue, grey/white, crimson, teal, gold, purple…). Symbols `@GCE` (gold futures), `@MES`, `@ENQ`; timeframe M5 |
| 3:30–4:25 | Light theme with **side panels hidden**, so the footprint is full width. Shows supply & demand zones (shaded bands with a border, extending right) and the dashed session-POC line |
| 4:30–6:30 | Light themes, full workspace; from about 5:35 the symbol is `XAUUSD` (CFD), then another symbol (price ≈ 231) |

---

## 3. Layout map (video frame 1920×1080; chart client area ≈ 1875×1040)

The vendor's settings guide defaults match the measured frames (HIGH). Main panel X −20, Y 0, W 1230, H 945. Analyst X 1210, W 470, H 470. Signal X 1685, W 180, H 470. DOM X 1210, Y 470, W 280, H 475. T&S X 1495, W 185, H 475, with RSI and MACD at 100 px each inside it. Session VP X 1685, W 180, H 475.

```
y=0   ┌───────────────────────────── HEADER (≈34 px) ─────────────────────────────────────────┐
      │[SUPPLY & DEMAND ZONES][FUNDAMENTALS][MINI SESSION CHART]  @GCE 4392.1 +29.6(+0.68%)     │
      │ 5M:▲ 15M:▲ 1H:▲ 4H:▼ D1:▲ │ HTF: BEAR  M5: BULL │ RESET ZOOM IN ZOOM OUT UP DOWN BAR VOLUME PROFILE DELTA BARS SIDE PANELS
y≈34  ├── STYLE TABS: MINIMALIST│BACKGROUND CELLS│CANDLE FRAME│VOLUME PROFILE CANDLE│FRAMELESS│MIDDLE CANDLE│DELTA CELLS│BID x ASK PROFILE│BID x ASK CELLS│ − ┤
y≈60  ├──────────── FOOTPRINT PANEL (x 0…≈1180) ────────────────┬── CHART ANALYST (470×470) ──┬ SIGNAL METER (180) ┤
      │ ┌MINI SESSION CHART┐   columns of "sell x buy" rows    │ 9 rule-generated sections    │ gauge + 11 rows     │
      │ └──────(330×230)──┘   own price scale on the right    ├── DOM LADDER (280) ─┬ T&S (185) ┬ VP TOTAL (180) ┤
      │                       session POC dashed line          │ Bid Sold Price Bot  │ Time Price│ horizontal      │
      │                                                        │ Ask D Vol           │ Size      │ profile,VAH/POC/│
y≈870 ├──── SUMMARY TABLE: Volume / Delta / Cum Delta / Ask / Bid + countdown ──────┤ RSI(14)   │ VAL             │
y≈1035└────────────────────────────────────────────────────────┴─────────────────────┴ MACD ──────┴─────────────────┘
```

---

## 4. Footprint panel — Minimalist style (HIGH unless noted)

- **Cell grammar:** `SELL x BUY` per row. The sell (bid-hit) number is right-aligned to the left of centre, the dim small "x" sits in the centre, and the buy (ask-lift) number is left-aligned to the right. Integers only, no thousands separator (values seen up to 4 digits; for ≥10 000 we use `12.3k`, ASSUMPTION).
- **Font:** monospace (Consolas), about 11–12 px tall; row pitch about 15.5 px at 1080p (vendor minimum cell height 14 px).
- **Rows:** one row = one price bucket = `bucketPoints × _Point`. In the video (`@GCE`) the row is 0.50 (labels 4394.0, 4393.0… each span 2 rows).
- **Columns:** bar pitch about 69 px at 1080p (vendor: bar width 55 + spacing). Newest bar on the right; about 14–16 bars visible with side panels on, more with them off.
- **Text colours:** normal numbers are off-white (dark theme) or near-black (light theme). Imbalance numbers are coloured and bold: seller ≈ (239,68,68) and buyer ≈ (34,197,94). The video renders them a bit softer (sampled #459E70 green). Imbalance colours are **independent of the theme**.
- **No candle body, wick or frame.** The OHLC is only implied by the extent of the rows.
- **POC:** the session POC is a dashed purple horizontal line ≈ (168,85,247) labelled "POC" at its right end (HIGH). A per-bar POC outline (fuchsia box) exists in the vendor's v7 but is **not visible in the video** → optional, default off.
- **Current price:** a filled tag on the footprint's own price scale (orange = theme bull colour) with a horizontal line to the last bar and a small "ASK" label.
- **Own price scale:** labels every 2 rows, 1 decimal; faint grid; very faint vertical separators between bar columns.
- **Zoomed out:** when rows get shorter than the minimum cell height, the numbers are hidden and compact candles are drawn instead (vendor behaviour).

## 5. Summary table (HIGH — verified against the numbers in `reference/03_summary_table_dark.png`)

- Header row: the bar times `HH:MM`. Top-right cell: the countdown timer `mm:ss` (vendor: green → yellow ≤30 s → orange ≤20 s → red ≤10 s), plus a "−" collapse button.
- Rows, labels on the right: **Volume, Delta, Cum Delta, Ask, Bid**.
- Colour logic (verified):

| Row | Colour | Intensity |
|---|---|---|
| Volume | Bull/bear colour of the bar's **delta sign** | Volume ÷ max visible volume |
| Delta | Sign colour | Magnitude ÷ max magnitude |
| Cum Delta | Sign colour | Magnitude ÷ max magnitude |
| Ask | Always the bull colour | Value ÷ row max |
| Bid | Always the bear colour | Value ÷ row max |

  In the Orange/dark-grey theme "bear" *is* dark grey, which is why negative cells look grey rather than red.

## 6. Header and tabs (HIGH)

- **Toggle buttons:** SUPPLY & DEMAND ZONES · FUNDAMENTALS · MINI SESSION CHART. Active buttons have blue text.
- **Ticker:** symbol (gold), last price (blue), daily change `+29.6 (+0.68%)` (bull/bear colour).
- **Trend arrows:** `5M 15M 1H 4H D1`, each with ▲ (bull colour) or ▼ (bear colour).
- **Bias labels:** `HTF: BEAR` (the H4 bias) and `M5: BULL` (the chart timeframe), coloured bull/bear.
- **Buttons:** RESET · ZOOM IN · ZOOM OUT · UP · DOWN · BAR VOLUME PROFILE · DELTA BARS · SIDE PANELS. Active toggles have blue text.
- **Style tabs:** the 9 styles in letter-spaced caps; the active one has blue text.

## 7. Mini session chart (HIGH)

- About 330×230 px, top-left over the footprint panel.
- An area/line chart of M1 closes since the session start, in theme colours.
- A dashed horizontal line at the session open, and a white dot at the last price.
- Caption: `Session Move: +0.70%   Local 00:00-00:00   M1 Bars: 382`.

## 8. Right panels (HIGH for the text; scoring rules are ASSUMPTIONS where noted)

- **Chart Analyst**
  - Title, plus `Updated: 14s ago`; it refreshes every 30 s.
  - Nine sections: PAIR INFO, TREND + HIGHER TF | ATR, DOM ANALYSIS, TIME & SALES, ORDER FLOW, VOLUME, IMBALANCES, KEY LEVELS, SETUP + ADVISOR SUMMARY.
  - The sentences are rule-generated templates. Verbatim examples:
    - "Strong bullish trend. Price above all MAs with bullish alignment."
    - "Mixed HTF signals. H4/Daily showing divergence. Trade with caution."
    - "Balanced DOM. Bid/Ask ratio near 1:1. No clear directional bias from order book."
    - "Moderate sell pressure (60%). Sellers slightly more active."
    - "Active moderate buying detected. Delta positive, cumulative delta rising."
    - "Balanced volume (ratio: 1.03). Neither side dominant."
    - "Multiple sell imbalances (16) detected. Institutional selling likely."
    - "Session POC: 4387.5. Daily range: 4354.5 - 4395.0"
    - "CAUTION: Price near daily high. Watch for rejection or breakout above 4395.0"
    - "MIXED SIGNALS (2 bull, 1 bear). Wait for alignment before committing."
    - "BULLISH BIAS (4/6 factors). Consider long positions with proper risk management."
  - Text colours: bull colour / bear colour / grey neutral / blue levels / yellow summary.
- **Signal Meter**
  - A semicircular gauge from −100 to +100: bear arc, neutral arc, bull arc, gold needle. Label and score below it, e.g. `STRONG BUY +72`.
  - Rows: RSI · MACD · MA 9 · MA 21 · MA 50 · VWAP (`UP ABOVE` / `DOWN BELOW`) · ATR Reg (`BASE 0.98x`, `CHOP 0.77x`) · POC Pos (`ABV ACC 9.4t`) · Delta · Cum Delta · Vol B/S.
  - Thresholds: the ATR regime is trend above 1.15 and chop below 0.85. POC acceptance needs 3 bars and at least 1.5 ticks. **The vendor's weighting is undocumented → our formula is in the prompt (ASSUMPTION).**
- **DOM ladder**
  - Columns `Bid | Sold | Price | Bot | Ask | D | Vol`, with rows at the footprint row size.
  - Bid and Ask are depth sizes with bars. Sold and Bot are the current bar's traded volume at that price; D = Bot − Sold.
  - The current-price rows are highlighted. Footer `Bar Totals: B:315 S:338`.
  - Uses broker market depth if available, otherwise a footprint fallback.
- **Time & Sales:** columns `Time (HH:MM:SS) | Price | Size`, newest first. Buys in the bull colour, sells in the bear colour. RSI(14) and MACD(12,26,9) minis sit underneath.
- **VP Total ("50 bars"):** a horizontal volume profile with VAH, POC (yellow) and VAL lines and labels. Value area 70 % (MED: sibling products use 70 %).

## 9. Themes

- Panel theme Dark (bg ≈ 15,17,23 — sampled #101012) or Light (bg #F8F8F8).
- 16 bull/bear accent pairs: Classic green/red, Blue/orange, Cyan/magenta, Lime/pink, Gold/purple, Teal/coral, Sky/crimson, Mint/rose, Orange/dark grey, Green/dark grey, Navy/slate, Navy/gold, White/dark grey, Emerald/white, Cherry/teal, Olive/sandy.
- The video cycles them in dark, then in light. Sampled orange accent ≈ #D96B00. The light-theme S&D zone fill is #D8E8F8 with a #2889E8 border.
- Exact RGBs for the other pairs are our approximations (in the prompt; tune against `reference/`).

## 10. What this means for the EA

- The footprint rules (imbalances, stacks, absorption, delta) are objective and codeable on **closed bars**. The EA must compile the **same engine** as the indicator so its numbers are identical; it must not read indicator buffers via `iCustom`.
- On CFD/forex the "volume" is quote-tick counts. The edge is weaker and broker-dependent, so prefer ratio- and percentage-based thresholds and validate per broker and symbol.
- Backtests are only meaningful in the Strategy Tester with **"Every tick based on real ticks"**.
- The vendor itself provides no trading logic. The EA setups in `03_PROMPT_Footprint_EA.md` are standard order-flow setups: stacked-imbalance zone retest, absorption/exhaustion reversal, and delta divergence as confluence. They come with a strict validation protocol. **No edge is guaranteed — demo first.**

## 11. Decisions & assumptions

| Topic | Decision | Why |
|---|---|---|
| Tool type | Indicator (canvas-drawn), not an EA like the vendor's | So the trading EA can run on the same chart. Heavy tick loading is done in time-budgeted steps on a timer, because all indicators on a symbol share one thread |
| Engine | Shared `.mqh` library used by indicator + EA + a dump script | Identical numbers; testable |
| Volume source | AUTO: exchange flags → trade ticks with quote rule + tick rule → quote ticks (1 per change, side by mid-price direction) | Vendor v7 cascade |
| Row size | `bucketPoints × _Point`, rows anchored at 0 (floor division on integer points) | Deterministic; vendor uses points |
| Imbalance | Diagonal; tiers 2/3/4; min volume 10 on the dominant side; inclusive ≥ | Vendor v7 defaults, verified on figures |
| Stacks | ≥ 3 consecutive same-side rows (vendor default 2; 3 is the common practitioner default) → zone extends right until price trades through | Better signal quality; parameter |
| Per-bar POC outline | Optional, default off | Not visible in the video |
| Session | Server-time session start 00:00 (input) | Determinism between live and tester |
| Signal Meter & Analyst formulas | Our explicit formulas (in the prompt) | Vendor weighting undocumented |
| Horizontal scroll | Add it (drag / Shift+wheel) and a LIVE button | The vendor's most common complaint |
