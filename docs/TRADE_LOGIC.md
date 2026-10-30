# How FootprintTrader trades (v1.11 defaults, XAUUSD M5)

> **v1.11 changes:** a signal now needs **at least 2 points** (was 1), each trade risks **0.25 %** (was 0.5 %), and the kill switch is at **10 %** (was 15 %). Expect about 3 trades a day instead of 7; in the June–August test those were the better ones. A new setup, **SIB** (below), is off by default. The rest of this page still describes the v1.10 numbers where it quotes test results.

This page is for traders who don't read code. It describes what the EA does with its **default inputs**. The original specification behaves differently; its values are in `MQL5\Presets\FootprintTrader_spec.set`. The reasons for each change are in `docs\decisions\frequency.md`.

> **Be realistic.** On XAUUSD the broker sends no real traded volume. A footprint "volume" here is the number of price quotes, and "buying/selling" is inferred from whether the mid price ticked up or down. Expect about 5–8 trades per day. The tests showed no proven edge:
- **June–August 2026** (the tuning window): 7.3 trades a day, +0.06 R per trade. Almost all of that profit came in June.
- **September 2026** (the test window): 7.4 trades a day, but −0.34 R per trade. The EA lost about 30 R (15 % of the account) in 12 trading days, and then the kill switch stopped it.

Treat it as an experiment on a demo account.

## 1. What happens every 5 minutes

At the first price tick of a new M5 bar, the bar that just closed is finished. Its footprint is rebuilt from every tick of that bar (each price row of 0.40 USD gets "sell × buy" counts). The row height is chosen automatically at start-up (0.40 for XAUUSD). If the market is extremely volatile at that moment, the EA picks coarser rows and then trades far less. Set `InpBucketPoints = 400` to pin 0.40. The EA then works through the following steps for that closed bar:

1. **Skip the bar if it is late or before a break.** It skips the bar if it closed before a market break (gold pauses daily 21:00–22:00 server time, and at the weekend). It also skips the bar if it is processed more than 10 seconds after its close. Exception: after a feed stall of up to 180 s, an untriggered stop order may still be placed.
2. **Look for setups** using only finished bars. The forming bar and the future are never used.
3. **Grade each signal and check the filters, then the risk limits.**
4. **Place the order** (in LIVE mode) or simulate it (VIRTUAL).
5. **Manage open trades:** expire stale stop orders, apply the time stop, trail the stop.

Between bar closes, on every tick, it does the following:
- watches the pending order: cancels it if price runs through the far side of the signal bar, or if the spread or session filter fails;
- takes the partial profit;
- moves the stop to break-even;
- trails the stop;
- checks the daily and kill-switch limits.

## 2. The setups

**EXH — exhaustion reversal (≈ 99 % of all trades).** The market makes a new 20-bar low. In the lowest price rows of that bar, selling **dries up**: the lowest row holds a tiny share of the bar's activity, and sell activity is smaller at each row going down. Buyers then pull the close back up. The idea is that sellers ran out at the low. Exact conditions for a long (shorts are the mirror image at a 20-bar high):
- the bar's low is at or below the lows of the previous **20** bars;
- the bar spans at least **7** price rows;
- the lowest row has at most **3 %** of the bar's volume;
- sell volume rises strictly over the bottom three rows: row 1 < row 2 < row 3, counting up from the low;
- the close is in the upper **60 %** of the bar's range.

**ABS — absorption reversal.** At a 20-bar low, heavy selling hits the bottom 3 rows (≥ 60 % of their volume is selling, and those rows carry ≥ 1.5× the average row volume), but price is held: the close is in the upper half and the bar volume is at least its 20-bar average. The idea is that a passive buyer absorbs the sellers. On this quote-tick feed the "heavy volume at the extreme" condition almost never occurs, because price only touches its extremes briefly. ABS is kept for exchange feeds but practically never fires on XAUUSD.

**SZR — stacked-imbalance zone retest (continuation, rare: about one trade a month).**
- **The zone.** A bar shows 3 or more stacked buy imbalances: rows where buying is at least 2–4× the selling diagonally below. Those rows form a support zone.
- **The trigger.** A long is taken when price first comes back into the zone within 30 bars, buyers defend it (delta ≥ 0), and the bar closes in the upper half of the zone.
- **The trend condition.** The trade must agree with the H1 trend (H1 close above its EMA 50).
- **The entry.** Market order at the next bar's open.

**SIB — stacked-imbalance breakout (v1.11, off by default, research).** The bar that *forms* a qualifying stack of buy imbalances (the SZR zone rules) also makes a new 10-bar high and closes above the stack. A buy-stop goes at that bar's high, the stop below the stack, and the order is cancelled if price falls back below the stack. It needs the H1 trend on its side, like SZR. The idea: SZR waits for a retest that comes about once a month; SIB trades the breakout itself. Untested: turn it on in VIRTUAL and compare it with the placebo before trading it.

**Delta divergence** is not traded on its own. It only adds a grade point.

## 3. Grade and filters

**Points.** Each reversal signal earns 1 point for each of the following:
- the H1 trend agrees with the trade;
- the extreme is within 0.25 ATR of a key level (session value-area edge, previous day high/low, previous session POC);
- a strong imbalance (tier ≥ 2) of the trapped side sits in the extreme rows;
- a delta divergence was confirmed within the last 3 bars;
- volatility is "normal" (ATR(14) between 0.85× and 1.15× its 50-bar average).

The grade follows from the points: **A** = 4–5, **B** = 3, **C** = 0–2. The EA trades **any grade with at least 2 points** (v1.11; v1.10 needed 1): grade C is allowed, but a signal with fewer than 2 confluences is not. Grades are logged for analysis.

**Filters**, checked when the signal appears:
- **Session:** all day, server time. No new entries on Friday after 18:00.
- **Spread:** at most 0.15 × ATR.
- **Activity:** at least 60 ticks in the bar.
- **Volatility regime** (reversals only): ATR is at most 1.6× its 50-bar average, so the EA does not fade a runaway move.
- **SZR only:** H1 trend agreement and ATR ≥ 0.85× its average.
- **News (live only):** no entries within 15 min of high-impact news.
- **One position:** only one trade or pending order at a time.

## 4. Entry, stop, targets, exits

| | Reversal (EXH/ABS), long | SZR, long |
|---|---|---|
| Entry | **Buy-stop** at the signal bar's high, plus the spread (buys fill at the ask). Valid for the next **2 bars** (10 min). Cancelled at once if the bid trades below the signal bar's low | Market order at the next bar's open |
| Stop | Signal-bar low − max(0.10 × ATR, 2 × spread) | Zone bottom − the same buffer |
| Target | **2.0 R** (R = the distance from entry to stop) | 2.0 R |

Shorts are the mirror image. Once a trade is open, the exits work as follows:
- **At +1 R:** close **50 %** and move the stop to **break-even**.
- **From +1.5 R:** trail the stop **1 × ATR** behind the price.
- **Time stop:** after **12 bars** (1 hour), close the trade if it is not at least +0.3 R.
- The stop is always placed with the order and is only ever moved in the trade's favour.

## 5. Size and daily limits

- **Size.** Each trade risks **0.25 % of equity** at the initial stop (v1.10: 0.5 %). Lots are rounded down to the broker's step, and trades below the minimum lot are skipped. There is no martingale, grid or averaging, and size never increases after a loss.
- **Daily limits** (server day):
  - at most **10** entries;
  - stop trading for the day after a loss of **2 %** of the day's starting equity (closed plus open P/L);
  - after **3 losses in a row**, pause new entries for **60 minutes**.
- **Kill switch.** At a **10 %** drawdown (v1.10: 15 %) from the equity peak, the EA closes everything and stops for good, and raises an alert. To re-enable it, delete the `FT_<symbol>_<magic>_KILL/PEAK` global variables (F3).
- **Restarts.** The EA rebuilds its state after a restart from the trade history and global variables.

## 6. What is logged where

- **`MQL5\Files\OrderFlowFP\signals_XAUUSD_M5.csv`** (in the tester: inside the agent's sandbox): one row per signal. It holds the bar data, the metrics, the grade, the context and the **decision**, which is one of:
  - `TAKEN`;
  - `FILTERED:<reasons>` (e.g. `GRADE`, `REGIME`, `POSITION`, `RISK_DAILY_LOSS`);
  - `SKIPPED:LATE`.
- **`trades_XAUUSD_M5.csv`**: one row per trade, with entry, stop, target, lots, risk, exit reason (`SL`, `TP`, `BE`, `TRAIL`, `TIME`, …), result in R, MAE/MFE and slippage. Stop orders that never filled appear as `EXPIRED` rows.
- **Experts log**: `FT SIGNAL`, `FT EXEC`/`FT VIRT` (order life cycle), `FT RISK` (limits), `FT ENGINE` (feed problems).
- **Analysis:** `py -3 tools\fp_analyze.py --trades trades_*.csv --signals signals_*.csv --funnel` gives the results per setup and grade, the trades per day, the signal funnel and a Monte-Carlo drawdown estimate.

## 7. Worked example (Strategy Tester, VIRTUAL, 2 June 2026)

**The signal bar: 09:00–09:05 server time.**
- High 4528.025, low 4525.359, close 4527.577.
- Its low undercut the previous 20 bars' lows.
- The three bottom rows, as sell × buy counts:

  | Row | Sell × buy |
  |---|---|
  | 4525.2 | **3** × 1 |
  | 4525.6 | **25** × 18 |
  | 4526.0 | **49** × 57 |

- The lowest row holds 4 of 483 quotes (0.8 % ≤ 3 %).
- Sells rise moving up from the low (3 < 25 < 49).
- The close sits at 83 % of the range (≥ 40 %).
- So the bar is **EXH long**.

**Points: 2, grade C.** The H1 trend was up (+1), and ATR was 0.86× its average, i.e. normal (+1). With at least 1 point, the signal is traded.

**At 09:05:00 the EA places the order.** Equity was 10 238 USD and the spread 0.114:

| | Price | How it is derived |
|---|---|---|
| Buy-stop | 4528.139 | high + spread |
| Stop | 4524.999 | low − 0.10 × ATR 3.60 |
| R | 3.14 USD | entry − stop |
| Target | 4534.419 | entry + 2 R |

Size: 0.16 lots, which risks 50.24 USD (≈ 0.5 %).

**What happened next:**

| Time | Event |
|---|---|
| 09:05:36 | The stop triggers; filled at 4528.155 (1.6 cents of slippage). |
| 09:11:38 | Price reaches +1 R. Half the position (0.08 lots) is closed at 4531.355 for +25.60 USD, and the stop moves to break-even (4528.155). |
| 09:15:12 | The target is hit at 4534.419 for the other half. |

Result: +75.71 USD = **+1.51 R** in 10 minutes. The worst point against the trade was −0.08 R and the best was +1.99 R.
