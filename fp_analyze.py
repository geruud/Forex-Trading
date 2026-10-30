#!/usr/bin/env python3
"""fp_analyze.py - FootprintTrader signal / trade study (03 section 11.3, 11.7, 11.8, 11.10).

Reads the CSV journals of docs/EA_ARCHITECTURE.md section 7:
  signals_<sym>_<tf>.csv  (one row per signal or skipped bar)
  trades_<sym>_<tf>.csv   (one row per POSITION, partial closes merged; rMultiple = money P/L / initial risk)

Python 3, standard library only. Deterministic for a given --seed.
"""
from __future__ import annotations

import argparse
import csv
import math
import random
import sys
from collections import Counter, OrderedDict, defaultdict
from datetime import datetime, timedelta

TIME_FORMATS = ("%Y.%m.%d %H:%M:%S", "%Y.%m.%d %H:%M", "%Y-%m-%d %H:%M:%S", "%Y-%m-%d %H:%M", "%Y.%m.%d", "%Y-%m-%d")
GRADE_ORDER = {"A": 2, "B": 1, "C": 0}
SETUP_ORDER = ["SZR", "ABS", "EXH", "DIV"]

TRADE_COLUMNS = ["tradeId", "signalId", "ticket", "setup", "dir", "grade", "mode", "entryTime", "entryPrice", "sl", "tp",
                 "lots", "riskMoney", "exitTime", "exitPrice", "exitReason", "rMultiple", "maeR", "mfeR", "barsHeld",
                 "spreadAtEntry", "slippagePts", "profitMoney", "partialDone"]
SIGNAL_COLUMNS = ["signalId", "barTime", "setup", "dir", "grade", "points", "decision"]


# ----------------------------------------------------------------------------- parsing
def parse_time(s: str) -> datetime | None:
    s = (s or "").strip()
    for f in TIME_FORMATS:
        try:
            return datetime.strptime(s, f)
        except ValueError:
            continue
    return None


def to_float(s: str, default: float = float("nan")) -> float:
    try:
        return float((s or "").strip())
    except ValueError:
        return default


def read_csv_rows(paths: list[str], required: list[str], label: str) -> list[dict]:
    rows: list[dict] = []
    for p in paths:
        try:
            fh = open(p, newline="", encoding="utf-8-sig")
        except OSError as e:
            sys.exit(f"error: cannot open {label} file {p}: {e}")
        with fh:
            rd = csv.DictReader(fh)
            missing = [c for c in required if c not in (rd.fieldnames or [])]
            if missing:
                sys.exit(f"error: {p} is not a {label} file (missing columns: {', '.join(missing)})")
            for r in rd:
                if r.get(rd.fieldnames[0]) == rd.fieldnames[0]:
                    continue  # repeated header line (appended files)
                r["_file"] = p
                rows.append(r)
    return rows


class Trade:
    __slots__ = ("setup", "grade", "dir", "mode", "entry", "exit", "r", "net", "mae", "mfe", "spread", "risk_dist",
                 "exit_reason", "key")

    def __init__(self, row: dict):
        self.setup = (row.get("setup") or "").strip().upper()
        self.grade = (row.get("grade") or "").strip().upper()
        self.dir = int(to_float(row.get("dir"), 0))
        self.mode = (row.get("mode") or "").strip().upper()
        self.entry = parse_time(row.get("entryTime"))
        self.exit = parse_time(row.get("exitTime"))
        self.r = to_float(row.get("rMultiple"))
        self.mae = to_float(row.get("maeR"))
        self.mfe = to_float(row.get("mfeR"))
        self.spread = to_float(row.get("spreadAtEntry"), 0.0)
        ep, sl = to_float(row.get("entryPrice")), to_float(row.get("sl"))
        self.risk_dist = abs(ep - sl) if not (math.isnan(ep) or math.isnan(sl)) else float("nan")
        self.exit_reason = (row.get("exitReason") or "").strip().upper()
        self.key = (row.get("tradeId"), self.mode, row.get("entryTime"), row.get("signalId"))
        self.net = self.r


def load_trades(paths: list[str], args, label: str) -> list[Trade]:
    rows = read_csv_rows(paths, ["setup", "grade", "mode", "entryTime", "exitTime", "rMultiple", "entryPrice", "sl"],
                         label)
    out, bad, seen, dup, unfilled = [], 0, set(), 0, 0
    for row in rows:
        # pending orders that never filled are journalled with exitReason=EXPIRED and empty R fields; not trades
        if (row.get("exitReason") or "").strip().upper() == "EXPIRED":
            unfilled += 1
            continue
        t = Trade(row)
        if t.entry is None or math.isnan(t.r):
            bad += 1
            continue
        if t.exit is None:
            t.exit = t.entry
        if args.mode and t.mode != args.mode.upper():
            continue
        if args.setup and t.setup not in args.setup:
            continue
        if args.min_grade and GRADE_ORDER.get(t.grade, -1) < GRADE_ORDER[args.min_grade]:
            continue
        if args.date_from and t.entry < args.date_from:
            continue
        if args.date_to and t.entry >= args.date_to:
            continue
        if t.key in seen:
            dup += 1
        seen.add(t.key)
        t.net = t.r - trade_cost(t, args)
        out.append(t)
    if unfilled:
        print(f"info: {label}: {unfilled} unfilled pending order(s) (exitReason=EXPIRED) excluded")
    if bad:
        print(f"warning: {label}: {bad} malformed row(s) skipped")
    if dup:
        print(f"warning: {label}: {dup} duplicate trade row(s) (same tradeId/mode/entryTime/signalId) - "
              "files from several runs appended? They are counted.")
    modes = sorted({t.mode for t in out})
    if len(modes) > 1:
        print(f"warning: {label}: mixed modes {modes}; use --mode to analyse one")
    out.sort(key=lambda t: (t.exit, t.entry))
    return out


def trade_cost(t: Trade, args) -> float:
    """Per-trade cost in R: fixed --cost-r plus optional stress terms (need --point and a known stop distance)."""
    c = args.cost_r
    if args.point and t.risk_dist and not math.isnan(t.risk_dist) and t.risk_dist > 0:
        if args.stress_spread_mult > 1.0:
            c += (args.stress_spread_mult - 1.0) * t.spread * args.point / t.risk_dist
        if args.stress_slip_pts > 0:
            c += 2.0 * args.stress_slip_pts * args.point / t.risk_dist  # entry + exit
    return c


# ----------------------------------------------------------------------------- statistics
def percentile(values: list[float], q: float) -> float:
    v = sorted(x for x in values if not math.isnan(x))
    if not v:
        return float("nan")
    if len(v) == 1:
        return v[0]
    pos = (len(v) - 1) * q / 100.0
    lo = int(math.floor(pos))
    hi = min(lo + 1, len(v) - 1)
    return v[lo] + (v[hi] - v[lo]) * (pos - lo)


def profit_factor(rs: list[float]) -> float:
    gain = sum(r for r in rs if r > 0)
    loss = -sum(r for r in rs if r < 0)
    if loss == 0:
        return float("inf") if gain > 0 else float("nan")
    return gain / loss


def fmt(x: float, nd: int = 2) -> str:
    if x is None or (isinstance(x, float) and math.isnan(x)):
        return "-"
    if isinstance(x, float) and math.isinf(x):
        return "inf"
    return f"{x:.{nd}f}"


def summarize(ts: list[Trade]) -> dict:
    n = len(ts)
    gross = [t.r for t in ts]
    net = [t.net for t in ts]
    return {
        "n": n,
        "win": (sum(1 for r in net if r > 0) / n * 100.0) if n else float("nan"),
        "avgR": (sum(gross) / n) if n else float("nan"),
        "exp": (sum(net) / n) if n else float("nan"),
        "pf": profit_factor(net) if n else float("nan"),
        "sumR": sum(net),
        "mfe": [percentile([t.mfe for t in ts], q) for q in (25, 50, 75, 90)],
        "mae": [percentile([t.mae for t in ts], q) for q in (25, 50, 75, 90)],
    }


def print_table(title: str, groups: "OrderedDict[str, list[Trade]]") -> None:
    print(f"\n== {title}")
    hdr = (f"{'group':<12}{'n':>6}{'win%':>8}{'avgR':>8}{'expNet':>8}{'PF':>7}{'sumR':>9}"
           f"   MFE p25/p50/p75/p90        MAE p25/p50/p75/p90")
    print(hdr)
    print("-" * len(hdr))
    for name, ts in groups.items():
        if not ts:
            continue
        s = summarize(ts)
        mfe = "/".join(fmt(x) for x in s["mfe"])
        mae = "/".join(fmt(x) for x in s["mae"])
        print(f"{name:<12}{s['n']:>6}{fmt(s['win'], 1):>8}{fmt(s['avgR']):>8}{fmt(s['exp']):>8}{fmt(s['pf']):>7}"
              f"{fmt(s['sumR'], 1):>9}   {mfe:<27}{mae}")


def group_by_setup_grade(ts: list[Trade]) -> "OrderedDict[str, list[Trade]]":
    g: "OrderedDict[str, list[Trade]]" = OrderedDict()
    setups = [s for s in SETUP_ORDER if any(t.setup == s for t in ts)] + \
             sorted({t.setup for t in ts} - set(SETUP_ORDER))
    for s in setups:
        sub = [t for t in ts if t.setup == s]
        g[f"{s}"] = sub
        for gr in ("A", "B", "C"):
            gg = [t for t in sub if t.grade == gr]
            if gg:
                g[f"  {s}/{gr}"] = gg
    g["ALL"] = list(ts)
    return g


# ----------------------------------------------------------------------------- Monte Carlo
def monte_carlo(rs: list[float], paths: int, seed: int, risk_pct: float) -> dict:
    """Bootstrap WITH replacement: each path draws len(rs) trades. Max drawdown in R (additive)
    and in % of equity (compounded at risk_pct per 1R)."""
    rng = random.Random(seed)
    n = len(rs)
    dd_r, dd_p, final_r = [], [], []
    f = risk_pct / 100.0
    for _ in range(paths):
        cum = peak = 0.0
        mdd = 0.0
        eq = peak_eq = 1.0
        mddp = 0.0
        for _ in range(n):
            r = rs[rng.randrange(n)]
            cum += r
            if cum > peak:
                peak = cum
            elif peak - cum > mdd:
                mdd = peak - cum
            eq = max(0.0, eq * (1.0 + r * f))
            if eq > peak_eq:
                peak_eq = eq
            elif peak_eq > 0 and (peak_eq - eq) / peak_eq > mddp:
                mddp = (peak_eq - eq) / peak_eq
        dd_r.append(mdd)
        dd_p.append(mddp * 100.0)
        final_r.append(cum)
    return {"dd_r": dd_r, "dd_p": dd_p, "final_r": final_r}


def historical_dd(rs: list[float]) -> float:
    cum = peak = mdd = 0.0
    for r in rs:
        cum += r
        peak = max(peak, cum)
        mdd = max(mdd, peak - cum)
    return mdd


# ----------------------------------------------------------------------------- monthly concentration
def monthly(ts: list[Trade]) -> tuple["OrderedDict[str, float]", float, float]:
    m: "OrderedDict[str, float]" = OrderedDict()
    for t in sorted(ts, key=lambda x: x.exit):
        k = t.exit.strftime("%Y-%m")
        m[k] = m.get(k, 0.0) + t.net
    total = sum(m.values())
    max_share = max((v / total for v in m.values()), default=float("nan")) if total > 0 else float("nan")
    return m, total, max_share


# ----------------------------------------------------------------------------- signals
def report_signals(paths: list[str], label: str) -> Counter:
    rows = read_csv_rows(paths, SIGNAL_COLUMNS, label)
    by = Counter()
    reasons = Counter()
    skipped = Counter()
    for r in rows:
        setup = (r.get("setup") or "").strip().upper()
        dec = (r.get("decision") or "").strip()
        if setup == "NONE" or dec.startswith("SKIPPED"):
            skipped[dec.split(":", 1)[1] if ":" in dec else dec] += 1
            continue
        cls = dec.split(":", 1)[0] if dec else "?"
        by[(setup, (r.get("grade") or "").strip().upper(), cls)] += 1
        if dec.startswith("FILTERED:"):
            for code in dec.split(":", 1)[1].split("|"):
                if code:
                    reasons[code] += 1
    print(f"\n== {label}: signal counts by setup / grade / decision ({len(rows)} rows)")
    setups = [s for s in SETUP_ORDER if any(k[0] == s for k in by)] + sorted({k[0] for k in by} - set(SETUP_ORDER))
    classes = sorted({k[2] for k in by})
    print(f"{'setup/grade':<14}" + "".join(f"{c:>14}" for c in classes) + f"{'total':>10}")
    totals = Counter()
    for s in setups:
        for g in ("A", "B", "C"):
            cnt = [by.get((s, g, c), 0) for c in classes]
            if sum(cnt):
                print(f"{s + '/' + g:<14}" + "".join(f"{x:>14}" for x in cnt) + f"{sum(cnt):>10}")
                totals[s] += sum(cnt)
    if reasons:
        print("filter reasons (a signal can carry several): " +
              ", ".join(f"{k}={v}" for k, v in reasons.most_common()))
    if skipped:
        print("skipped bars: " + ", ".join(f"{k}={v}" for k, v in skipped.most_common()))
    return totals


# ----------------------------------------------------------------------------- trades per trading day
def trading_day(d: datetime):
    """Server date of an entry; Sunday-evening entries (XAUUSD opens Sunday 22:00) count for Monday."""
    day = d.date()
    return day + timedelta(days=1) if day.weekday() == 6 else day


def weekdays(d0: datetime, d1: datetime) -> list:
    out, d = [], d0.date()
    while d < d1.date():
        if d.weekday() < 5:
            out.append(d)
        d += timedelta(days=1)
    return out


def per_day_stats(entries: list[datetime], days: list) -> dict:
    cnt = Counter(trading_day(e) for e in entries)
    counts = sorted(cnt.get(d, 0) for d in days)
    n = len(counts)
    if n == 0:
        return {"days": 0, "mean": float("nan"), "median": float("nan"), "ge5": float("nan"), "min": 0, "max": 0}
    med = counts[n // 2] if n % 2 else 0.5 * (counts[n // 2 - 1] + counts[n // 2])
    return {"days": n, "mean": sum(counts) / n, "median": med, "ge5": sum(1 for c in counts if c >= 5) / n * 100.0,
            "min": counts[0], "max": counts[-1]}


def report_per_day(ts: list[Trade], d0: datetime | None, d1: datetime | None) -> None:
    if not ts:
        return
    a = d0 or min(t.entry for t in ts)
    b = d1 or (max(t.entry for t in ts) + timedelta(days=1))
    days = weekdays(datetime(a.year, a.month, a.day), datetime(b.year, b.month, b.day))
    print(f"\n== filled trades per trading day (Mon-Fri {days[0]} .. {days[-1]}, {len(days)} days; "
          "Sunday-evening entries count for Monday; days without any bar, e.g. holidays, count as 0)")
    groups = OrderedDict([("ALL", ts)] + [(s, [t for t in ts if t.setup == s]) for s in SETUP_ORDER])
    for name, g in groups.items():
        if not g and name != "ALL":
            continue
        s = per_day_stats([t.entry for t in g], days)
        print(f"  {name:<5} mean {fmt(s['mean'])}  median {fmt(s['median'], 1)}  days >= 5: {fmt(s['ge5'], 1)} %  "
              f"min {s['min']}  max {s['max']}")


# ----------------------------------------------------------------------------- funnel
FUNNEL_ORDER = ["SKIPPED", "WARMUP", "DATA_STATE", "DATA_TICKS", "DATA_SOURCE", "SESSION", "FRIDAY", "SPREAD", "ATR_MIN",
                "REGIME", "HTF", "NEWS", "LATE", "GRADE", "POSITION", "RISK_DAILY_TRADES", "RISK_DAILY_LOSS",
                "RISK_CONSEC_LOSSES", "RISK_KILL", "RISK_MIN_LOT", "RISK_MARGIN", "PLAN", "FLAT", "TRADE_DISABLED", "FILTER"]


def report_funnel(sig_paths: list[str], trade_paths: list[str] | None) -> None:
    """Where candidates are lost: each signal is charged to the FIRST failing stage in FUNNEL_ORDER."""
    rows = read_csv_rows(sig_paths, SIGNAL_COLUMNS, "signals")
    stage, n_sig = Counter(), 0
    per_setup = defaultdict(Counter)
    for r in rows:
        setup = (r.get("setup") or "").strip().upper()
        dec = (r.get("decision") or "").strip()
        if setup == "NONE" or dec.startswith("SKIPPED"):
            continue
        n_sig += 1
        if dec in ("TAKEN", "SIGNALS_ONLY") or dec.startswith("RESEARCH:"):
            key = dec.split(":", 1)[0]
        else:
            codes = set(dec.split(":", 1)[1].split("|")) if ":" in dec else {dec}
            key = next((c for c in FUNNEL_ORDER if c in codes), sorted(codes)[0] if codes else "?")
        stage[key] += 1
        per_setup[setup][key] += 1
    print(f"\n== funnel ({n_sig} signals; each charged to its first blocking stage)")
    for k in FUNNEL_ORDER + ["TAKEN", "SIGNALS_ONLY", "RESEARCH"]:
        if stage.get(k):
            by = ", ".join(f"{s}={per_setup[s][k]}" for s in SETUP_ORDER if per_setup[s].get(k))
            print(f"  {k:<20}{stage[k]:>7}   ({by})")
    if trade_paths:
        trs = read_csv_rows(trade_paths, ["exitReason"], "trades")
        filled = sum(1 for t in trs if (t.get("exitReason") or "").strip().upper() != "EXPIRED")
        print(f"  -> orders {len(trs)}: filled {filled}, unfilled (EXPIRED) {len(trs) - filled}"
              f"{f' ({filled / len(trs) * 100:.0f}% fill rate)' if trs else ''}")


# ----------------------------------------------------------------------------- research replay
# A research run (EA InpTradeMode=VIRTUAL + InpResearchAllSignals=true + InpDumpBars=true, every risk limit off;
# tools\mt5_run_tester.ps1 -Runs research) simulates EVERY signal of a LOOSE detector configuration as an
# independent virtual trade. The replay below rebuilds each reversal candidate's detector metrics from the bar
# dump, so any TIGHTER configuration is a subset; it then applies filters, grade, the one-position rule, the daily
# trade cap, the consecutive-loss pause, the daily loss limit and the kill switch in time order. It reproduced the
# EA's own VIRTUAL run trade for trade (docs\decisions\frequency.md). Trade management is fixed per research run.
RESEARCH_DEFAULT = {
    "setups": ["EXH", "ABS", "SZR"], "L": 20, "k": 3,
    "abs_share": 0.60, "abs_conc": 1.5, "abs_cf": 0.50, "abs_volx": 1.0,
    "exh_pct": 0.03, "exh_cf": 0.40, "szr_rows": 3, "szr_odp": 0.10, "szr_age": 30,
    "min_grade": 0, "min_points": 1,
    "session": [0, 0], "friday": 1080, "rev_max_ratio": 1.6, "szr_min_ratio": 0.85,
    "max_spread_atr": 0.15, "min_ticks": 60, "point": 0.001, "period": 300,
    "max_pos": 1, "max_day": 10, "consec": 3, "consec_pause_min": 60, "day_loss_pct": 2.0, "kill_pct": 15.0,
    "risk_pct": 0.5,
}


class RBar:
    __slots__ = ("t", "o", "h", "l", "c", "vol", "delta", "ticks", "state", "sell", "buy", "isell", "ibuy", "prev")

    def __init__(self):
        self.sell, self.buy, self.isell, self.ibuy, self.prev, self.state, self.ticks = [], [], [], [], None, 0, 0


class RCand:
    __slots__ = ("sid", "T", "setup", "dir", "points", "atr", "ratio", "spread", "htf", "items", "info", "bar",
                 "filled", "entry", "exit", "R", "placed", "m")


def _one(d: str, pattern: str) -> str:
    import glob
    import os
    hits = sorted(glob.glob(os.path.join(d, pattern)))
    if not hits:
        sys.exit(f"error: {d} has no {pattern} (a research run needs signals, trades and the bar dump)")
    return hits[0]


def load_research(d: str, cfg: dict):
    bars: dict = {}
    with open(_one(d, "dump_*_bars.csv"), newline="", encoding="utf-8-sig") as fh:
        for r in csv.DictReader(fh):
            b = RBar()
            b.t = parse_time(r["time"])
            b.o, b.h, b.l, b.c = (to_float(r[k]) for k in ("open", "high", "low", "close"))
            b.vol, b.delta, b.ticks, b.state = to_float(r["volume"]), to_float(r["delta"]), int(to_float(r["ticks"], 0)), \
                int(to_float(r["state"], 0))
            bars[b.t] = b
    with open(_one(d, "dump_*_rows.csv"), newline="", encoding="utf-8-sig") as fh:
        for r in csv.DictReader(fh):
            b = bars.get(parse_time(r["time"]))
            if b is not None:
                b.sell.append(to_float(r["sell"]))
                b.buy.append(to_float(r["buy"]))
                b.isell.append(int(to_float(r["imbSell"], 0)))
                b.ibuy.append(int(to_float(r["imbBuy"], 0)))
    cands = []
    with open(_one(d, "signals_*.csv"), newline="", encoding="utf-8-sig") as fh:
        for r in csv.DictReader(fh):
            T = parse_time(r["barTime"])
            if r["setup"] == "NONE":
                if T not in bars:                            # skipped bar: OHLC only (keeps the lookback walk exact)
                    b = RBar()
                    b.t = T
                    b.o, b.h, b.l, b.c = (to_float(r[k]) for k in ("open", "high", "low", "close"))
                    b.vol, b.state = to_float(r["volume"]), 9
                    bars[T] = b
                continue
            if not r["decision"].startswith("RESEARCH:"):
                continue
            c = RCand()
            c.sid, c.T, c.setup, c.dir = int(r["signalId"]), T, r["setup"], int(r["dir"])
            c.points, c.atr, c.ratio = int(to_float(r["points"], 0)), to_float(r["atr"]), to_float(r["atrRatio"])
            c.spread, c.htf = to_float(r["spreadPts"]) * cfg["point"], int(to_float(r["htfBias"], 0))
            c.info = dict(kv.split("=", 1) for kv in r["info"].split(";") if "=" in kv)
            c.items = set((c.info.get("pts") or "").split("+")) - {""}
            c.filled, c.m = None, {}
            cands.append(c)
    times = sorted(bars)
    for i in range(1, len(times)):
        bars[times[i]].prev = bars[times[i - 1]]
    byid = {c.sid: c for c in cands}
    with open(_one(d, "trades_*.csv"), newline="", encoding="utf-8-sig") as fh:
        for r in csv.DictReader(fh):
            c = byid.get(int(r["signalId"]))
            if c is not None:
                c.filled = (r["exitReason"] or "").upper() != "EXPIRED"
                c.entry, c.exit = parse_time(r["entryTime"]), parse_time(r["exitTime"])
                c.R = to_float(r["rMultiple"], 0.0) if c.filled else 0.0
    out = []
    for c in cands:
        if c.filled is None:
            continue                                         # still open at the end of the run: not journaled
        c.bar = bars.get(c.T)
        c.placed = c.T + timedelta(seconds=cfg["period"])
        out.append(c)
    out.sort(key=lambda c: (c.T, c.sid))
    return out, bars


def _rev_metrics(c: RCand, k: int):
    key = ("rev", k)
    if key not in c.m:
        b, res = c.bar, None
        if b is not None and b.sell:
            n, d, rng = len(b.sell), c.dir, b.h - b.l
            cf = ((b.c - b.l) / rng if d > 0 else (b.h - b.c) / rng) if rng > 0 else 0.0
            idx = [j if d > 0 else n - 1 - j for j in range(min(k, n))]
            tot = sum(b.sell[i] + b.buy[i] for i in idx)
            side = sum((b.sell[i] if d > 0 else b.buy[i]) for i in idx)
            avg = b.vol / n if n else 0.0
            e = [0, 1, 2] if d > 0 else [n - 1, n - 2, n - 3]
            v = b.sell if d > 0 else b.buy
            sma, got, steps, p = 0.0, 0, 0, b.prev
            while p is not None and got < 20 and steps < 40:
                steps += 1
                if p.state == 0 and p.sell:
                    sma += p.vol
                    got += 1
                p = p.prev
            sma = sma / 20 if got == 20 else 0.0
            res = {"shape": n >= 2 * k + 1, "cf": cf, "share": side / tot if tot > 0 else 0.0,
                   "conc": tot / (k * avg) if avg > 0 else 0.0,
                   "exh_pct": (b.sell[e[0]] + b.buy[e[0]]) / b.vol if (b.vol > 0 and n >= 3) else 1.0,
                   "incr": n >= 3 and v[e[0]] < v[e[1]] < v[e[2]],
                   "imb2": any(((b.isell[i] if d > 0 else b.ibuy[i]) >= 2) for i in idx),
                   "volx": b.vol / sma if sma > 0 else 0.0}
        c.m[key] = res
    return c.m[key]


def _location(c: RCand, L: int) -> bool:
    key = ("loc", L)
    if key not in c.m:
        ok, b = False, c.bar
        if b is not None:
            pr, p = [], b.prev
            while p is not None and len(pr) < L:
                pr.append(p)
                p = p.prev
            if len(pr) == L and all(x.state in (0, 9) for x in pr):
                ok = all(b.l <= x.l + 1e-8 for x in pr) if c.dir > 0 else all(b.h >= x.h - 1e-8 for x in pr)
        c.m[key] = ok
    return c.m[key]


def _rev_type(c: RCand, cfg: dict):
    if not _location(c, cfg["L"]):
        return None
    m = _rev_metrics(c, cfg["k"])
    if m is None or not m["shape"]:
        return None
    is_abs = (m["share"] >= cfg["abs_share"] and m["conc"] >= cfg["abs_conc"] and m["cf"] >= cfg["abs_cf"] and
              (cfg["abs_volx"] <= 0 or m["volx"] >= cfg["abs_volx"]))
    is_exh = m["exh_pct"] <= cfg["exh_pct"] and m["incr"] and m["cf"] >= cfg["exh_cf"]
    if is_abs and "ABS" in cfg["setups"]:
        return "ABS"
    if is_exh and "EXH" in cfg["setups"]:
        return "EXH"
    return None


def _rev_points(c: RCand, cfg: dict) -> int:
    base = 0.85 <= c.ratio <= 1.15
    return (int(c.htf == c.dir) + int("loc" in c.items) + int(bool(_rev_metrics(c, cfg["k"])["imb2"])) +
            int("div" in c.items) + int(base))


def _filters(c: RCand, cfg: dict, kind: str) -> str:
    t = c.placed
    mins = t.hour * 60 + t.minute
    s, e = cfg["session"]
    if not (s == e or (s <= mins < e if s < e else (mins >= s or mins < e))):
        return "SESSION"
    if cfg["friday"] is not None and cfg["friday"] >= 0 and t.weekday() == 4 and mins >= cfg["friday"]:
        return "FRIDAY"
    if cfg["max_spread_atr"] > 0 and not (c.atr > 0 and c.spread <= cfg["max_spread_atr"] * c.atr + 1e-12):
        return "SPREAD"
    if cfg["min_ticks"] > 0 and (c.bar is None or c.bar.ticks < cfg["min_ticks"]):
        return "DATA_TICKS"
    if kind == "REV" and not c.ratio <= cfg["rev_max_ratio"]:
        return "REGIME"
    if kind == "SZR" and (c.ratio < cfg["szr_min_ratio"] or c.htf != c.dir):
        return "REGIME|HTF"
    return ""


def research_replay(cands: list, cfg: dict, funnel: Counter) -> list:
    sel = []
    for c in cands:
        if c.setup in ("ABS", "EXH"):
            ty = _rev_type(c, cfg)
            if ty is None:
                continue
            pts, why = _rev_points(c, cfg), _filters(c, cfg, "REV")
        elif c.setup == "SZR" and "SZR" in cfg["setups"]:
            # re-checkable SZR qualification from the logged info (rows, origin delta%, age); the stack tier and
            # the zone height are not logged, so run research with the SZR inputs you want to study
            i = c.info
            if (int(to_float(i.get("rows"), 0)) < cfg["szr_rows"] or to_float(i.get("odp"), 0.0) * c.dir < cfg["szr_odp"]
                    or int(to_float(i.get("age"), 0)) > cfg["szr_age"]):
                continue
            ty, pts, why = "SZR", c.points, _filters(c, cfg, "SZR")
        else:
            continue
        funnel["detected_" + ty] += 1
        grade = 2 if pts >= 4 else (1 if pts == 3 else 0)
        if why:
            funnel["f_" + why] += 1
        elif grade < cfg["min_grade"] or pts < cfg["min_points"]:
            funnel["f_GRADE"] += 1
        else:
            sel.append((c, ty, pts, grade))
    rank = {"SZR": 1, "ABS": 2, "EXH": 3, "DIV": 4}
    sel.sort(key=lambda x: (x[0].T, -x[3], -x[2], rank[x[1]], -x[0].dir))
    st = {"day": None, "filled": 0, "consec": 0, "pause": None, "block": False, "dayr": 0.0}
    eq = peak = 1.0
    killed, busy, closes, taken = False, [], [], []

    def roll(dt):
        if st["day"] != dt.date():
            st.update(day=dt.date(), filled=0, consec=0, block=False, dayr=0.0)

    for c, ty, pts, grade in sel:
        t = c.placed
        closes.sort(key=lambda x: x[0])
        while closes and closes[0][0] <= t:
            xt, r = closes.pop(0)
            roll(xt)
            st["dayr"] += r
            eq *= 1.0 + cfg["risk_pct"] / 100.0 * r
            peak = max(peak, eq)
            if cfg["kill_pct"] > 0 and (peak - eq) / peak * 100.0 >= cfg["kill_pct"] and not killed:
                killed = True
                funnel["kill_switch_fired"] += 1
            st["consec"] = st["consec"] + 1 if r < 0 else 0
            if cfg["consec"] > 0 and st["consec"] >= cfg["consec"]:
                st["pause"] = (xt + timedelta(minutes=cfg["consec_pause_min"]) if cfg["consec_pause_min"] > 0
                               else datetime(xt.year, xt.month, xt.day) + timedelta(days=1))
                st["consec"] = 0 if cfg["consec_pause_min"] > 0 else st["consec"]
                funnel["consec_pauses"] += 1
            if cfg["day_loss_pct"] > 0 and st["dayr"] * cfg["risk_pct"] <= -cfg["day_loss_pct"] and not st["block"]:
                st["block"] = True
                funnel["daily_loss_stops"] += 1
        roll(t)
        busy = [e for e in busy if e > t]
        reason = ("RISK_KILL" if killed else "POSITION" if len(busy) >= cfg["max_pos"] else
                  "RISK_DAILY_TRADES" if cfg["max_day"] > 0 and st["filled"] >= cfg["max_day"] else
                  "RISK_DAILY_LOSS" if st["block"] else
                  "RISK_CONSEC_LOSSES" if st["pause"] is not None and t < st["pause"] else "")
        if reason:
            funnel["r_" + reason] += 1
            continue
        busy.append(c.exit if c.exit is not None else t)
        taken.append((c, ty))
        if c.filled:
            if c.entry.date() == st["day"]:
                st["filled"] += 1
            closes.append((c.exit, c.R))
            funnel["filled"] += 1
        else:
            funnel["expired"] += 1
    return taken


def run_research(args) -> int:
    cfg = dict(RESEARCH_DEFAULT)
    if args.config:
        import json
        with open(args.config, encoding="utf-8") as fh:
            cfg.update(json.load(fh))
    cands, bars = load_research(args.research, cfg)
    d0 = args.date_from or min(bars)
    d1 = args.date_to or (max(bars) + timedelta(days=1))
    funnel = Counter()
    taken = research_replay(cands, cfg, funnel)
    fills = [c for c, _ in taken if c.filled and d0 <= c.entry < d1]
    print(f"research replay of {args.research}: {len(cands)} candidates, config {cfg}")
    print("funnel: " + ", ".join(f"{k}={v}" for k, v in sorted(funnel.items())))
    days = weekdays(datetime(d0.year, d0.month, d0.day), datetime(d1.year, d1.month, d1.day))
    s = per_day_stats([c.entry for c in fills], days)
    rs = [c.R for c in sorted(fills, key=lambda c: c.exit)]
    print(f"filled {len(rs)}; per trading day mean {fmt(s['mean'])}, median {fmt(s['median'], 1)}, "
          f">= 5: {fmt(s['ge5'], 1)} %; win {fmt(sum(r > 0 for r in rs) / len(rs) * 100 if rs else float('nan'), 1)} %, "
          f"avg R {fmt(sum(rs) / len(rs) if rs else float('nan'), 3)}, PF {fmt(profit_factor(rs))}, "
          f"net {fmt(sum(rs), 1)} R, max DD {fmt(historical_dd(rs), 1)} R")
    return 0


# ----------------------------------------------------------------------------- main
def parse_date_arg(s: str | None) -> datetime | None:
    if not s:
        return None
    d = parse_time(s)
    if d is None:
        sys.exit(f"error: bad date '{s}' (use YYYY-MM-DD or YYYY.MM.DD [hh:mm])")
    return d


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="fp_analyze.py",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        description="FootprintTrader study of the signals_*.csv / trades_*.csv journals "
                    "(docs/EA_ARCHITECTURE.md section 7; 03 section 11).",
        epilog="""\
reports
  1. per setup and grade: count, win rate, avg R (gross), expectancy after the
     per-trade cost (expNet), PF in R, sum R, MFE/MAE percentiles (R)
  2. in-sample vs out-of-sample tables when --split is given (split on entryTime)
  3. Monte-Carlo bootstrap WITH replacement of the evaluation set (OOS if --split,
     else all): max drawdown distribution in R and in %% at --risk-pct per 1R
  4. monthly profit concentration (net R by exit month; a month's share = its net R
     / total net R; fails if any month > --month-cap or total <= 0)
  5. the 03 section 11.8 acceptance checklist on the evaluation set
  6. placebo comparison (--placebo): real minus placebo OOS expectancy >= 0.05R
     (03 section 11.10); warns when the trade counts are not comparable
  7. filled trades per trading day (Mon-Fri; mean, median, share of days with >= 5),
     per setup; with --signals --funnel: the signal funnel (first blocking stage)
  8. --research DIR [--config JSON]: replay of a research run under a configuration
     (docs/decisions/frequency.md)

cost model (applied to every trade before expNet / PF / Monte Carlo / months)
  net R = rMultiple - cost_r
          - (stress_spread_mult - 1) * spreadAtEntry * point / |entryPrice - sl|
          - 2 * stress_slip_pts * point / |entryPrice - sl|
  The stress terms need --point (the symbol's point, e.g. 0.01 for XAUUSD 2 digits).
  rMultiple already contains the spread the EA actually paid; the stress terms are
  EXTRA cost on top (03 section 11.7).

examples
  py -3 tools/fp_analyze.py --trades trades_XAUUSD_M5.csv --signals signals_XAUUSD_M5.csv
  py -3 tools/fp_analyze.py --trades real.csv --placebo placebo.csv --split 2025-07-01 \\
        --cost-r 0.03 --risk-pct 0.5 --dd-limit-pct 10 --paths 10000 --seed 7
  py -3 tools/fp_analyze.py --trades t.csv --point 0.01 --stress-spread-mult 1.5 --stress-slip-pts 20

exit code: 0, or 1 with --strict when an automated acceptance item fails; 2 on bad input.
""")
    p.add_argument("--trades", nargs="+", metavar="CSV", help="trades_*.csv file(s) of the real run (required unless --research)")
    p.add_argument("--research", metavar="DIR",
                   help="research replay of a research run folder (mt5_run_tester.ps1 -Runs research): signals, trades "
                        "and bar dump; applies --config (JSON, keys of RESEARCH_DEFAULT) and reports trades/day and R")
    p.add_argument("--config", metavar="JSON", help="research replay configuration overrides (JSON file)")
    p.add_argument("--funnel", action="store_true", help="with --signals: where candidates are lost (first blocking stage)")
    p.add_argument("--signals", nargs="+", metavar="CSV", help="signals_*.csv file(s) of the real run (counts, reasons)")
    p.add_argument("--placebo", nargs="+", metavar="CSV",
                   help="trades_*.csv file(s) of the InpPlaceboPriceOnly=true run (same period, same inputs)")
    p.add_argument("--placebo-signals", nargs="+", metavar="CSV", help="signals_*.csv file(s) of the placebo run")
    p.add_argument("--split", metavar="DATE", help="out-of-sample starts at this entry date (YYYY-MM-DD)")
    p.add_argument("--from", dest="date_from", metavar="DATE", help="ignore trades entered before DATE")
    p.add_argument("--to", dest="date_to", metavar="DATE", help="ignore trades entered at/after DATE")
    p.add_argument("--mode", choices=["VIRTUAL", "LIVE", "virtual", "live"], help="only this journal mode")
    p.add_argument("--setup", nargs="+", type=str.upper, choices=SETUP_ORDER, help="only these setups")
    p.add_argument("--min-grade", type=str.upper, choices=["A", "B", "C"], help="only trades with grade >= this")
    p.add_argument("--cost-r", type=float, default=0.0, help="fixed cost per trade in R (default 0)")
    p.add_argument("--point", type=float, default=0.0, help="symbol point, enables the stress cost terms")
    p.add_argument("--stress-spread-mult", type=float, default=1.0, help="spread multiple for stress (default 1.0)")
    p.add_argument("--stress-slip-pts", type=float, default=0.0, help="extra slippage per side in points (default 0)")
    p.add_argument("--paths", type=int, default=5000, help="Monte-Carlo paths (>= 5000; default 5000)")
    p.add_argument("--seed", type=int, default=12345, help="Monte-Carlo RNG seed (default 12345)")
    p.add_argument("--risk-pct", type=float, default=0.5, help="risk %% of equity per 1R for the %% drawdown (0.5)")
    p.add_argument("--dd-limit-pct", type=float, default=10.0,
                   help="your max-drawdown limit in %%; the MC p95 must stay within it (default 10 = InpMaxDDPct)")
    p.add_argument("--month-cap", type=float, default=0.40, help="max share of total profit in one month (0.40)")
    p.add_argument("--min-oos-trades", type=int, default=100, help="acceptance: minimum OOS trades (100)")
    p.add_argument("--min-pf", type=float, default=1.25, help="acceptance: minimum OOS profit factor in R (1.25)")
    p.add_argument("--min-exp", type=float, default=0.10, help="acceptance: minimum OOS expectancy after costs (0.10R)")
    p.add_argument("--placebo-gap", type=float, default=0.05, help="acceptance: real - placebo OOS expectancy (0.05R)")
    p.add_argument("--strict", action="store_true", help="exit 1 if an automated acceptance item fails")
    return p


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    args.date_from = parse_date_arg(args.date_from)
    args.date_to = parse_date_arg(args.date_to)
    split = parse_date_arg(args.split)
    if args.paths < 1:
        sys.exit("error: --paths must be >= 1")
    if args.paths < 5000:
        print(f"warning: --paths {args.paths} < 5000 (03 section 11.7 asks for >= 5000)")
    if (args.stress_spread_mult > 1.0 or args.stress_slip_pts > 0) and not args.point:
        print("warning: stress cost terms ignored - give --point")

    if args.research:
        return run_research(args)
    if not args.trades:
        sys.exit("error: --trades is required (or use --research DIR)")
    real = load_trades(args.trades, args, "real trades")
    print(f"FootprintTrader study: {len(real)} real trades from {len(args.trades)} file(s); "
          f"cost_r={args.cost_r}, stress spread x{args.stress_spread_mult}, slip {args.stress_slip_pts} pts, "
          f"seed={args.seed}, paths={args.paths}")
    if not real:
        print("no trades to analyse")
        return 2

    if args.signals:
        report_signals(args.signals, "real signals")
        if args.funnel:
            report_funnel(args.signals, args.trades)

    print_table("all trades by setup / grade (R; expNet after costs)", group_by_setup_grade(real))
    if split:
        ins = [t for t in real if t.entry < split]
        oos = [t for t in real if t.entry >= split]
        print_table(f"IN-SAMPLE (entry < {split:%Y-%m-%d})", group_by_setup_grade(ins))
        print_table(f"OUT-OF-SAMPLE (entry >= {split:%Y-%m-%d})", group_by_setup_grade(oos))
        evalset, evalname = oos, "OOS"
    else:
        evalset, evalname = real, "ALL (no --split: NOT out-of-sample)"

    report_per_day(real, args.date_from, args.date_to)
    if split:
        report_per_day([t for t in real if t.entry < split], args.date_from, split)
        report_per_day([t for t in real if t.entry >= split], split, args.date_to)

    exits = Counter(t.exit_reason for t in real)
    print("\nexit reasons: " + ", ".join(f"{k or '?'}={v}" for k, v in exits.most_common()))

    checks: list[tuple[str, str, str]] = []  # (item, status, detail)
    s = summarize(evalset) if evalset else None

    # --- Monte Carlo
    if evalset:
        rs = [t.net for t in evalset]
        mc = monte_carlo(rs, args.paths, args.seed, args.risk_pct)
        print(f"\n== Monte-Carlo bootstrap ({evalname}: {len(rs)} trades/path, {args.paths} paths, "
              f"seed {args.seed}, risk {args.risk_pct}% per R)")
        print(f"historical max DD: {fmt(historical_dd(rs))} R")
        for q in (50, 90, 95, 99):
            print(f"  p{q:<3} max DD {fmt(percentile(mc['dd_r'], q)):>7} R   {fmt(percentile(mc['dd_p'], q)):>7} %   "
                  f"final {fmt(percentile(mc['final_r'], 100 - q)):>8} R (p{100 - q})")
        worst_r = max(mc["dd_r"])
        print(f"  worst  max DD {fmt(worst_r):>7} R   {fmt(max(mc['dd_p'])):>7} %")
        p_exceed = sum(1 for d in mc["dd_p"] if d >= args.dd_limit_pct) / len(mc["dd_p"]) * 100.0
        print(f"  P(max DD >= {args.dd_limit_pct}%) = {fmt(p_exceed, 1)} %")
        p95 = percentile(mc["dd_p"], 95)
        checks.append(("MC p95 drawdown within limit", "PASS" if p95 <= args.dd_limit_pct else "FAIL",
                       f"p95 {fmt(p95)} % vs limit {args.dd_limit_pct} %"))

        # --- months
        m, total, max_share = monthly(evalset)
        print(f"\n== monthly net R ({evalname}); cap {args.month_cap * 100:.0f}% of total profit")
        for k, v in m.items():
            share = (v / total * 100.0) if total > 0 else float("nan")
            flag = "  <-- over cap" if total > 0 and v / total > args.month_cap else ""
            print(f"  {k}  {fmt(v, 2):>8} R  {fmt(share, 1):>6} %{flag}")
        if total <= 0:
            checks.append(("no month > cap of profit", "FAIL", f"total net R {fmt(total)} <= 0 (no profit)"))
        else:
            checks.append(("no month > cap of profit", "PASS" if max_share <= args.month_cap else "FAIL",
                           f"max month share {fmt(max_share * 100, 1)} % (cap {args.month_cap * 100:.0f} %), "
                           f"{len(m)} months"))

        checks.insert(0, (f"{evalname} expectancy >= {args.min_exp}R after costs",
                          "PASS" if s["exp"] >= args.min_exp else "FAIL", f"{fmt(s['exp'], 3)} R"))
        checks.insert(0, (f"{evalname} trades >= {args.min_oos_trades}",
                          "PASS" if s["n"] >= args.min_oos_trades else "FAIL", f"n = {s['n']}"))
        checks.insert(0, (f"{evalname} PF(R) >= {args.min_pf}",
                          "PASS" if s["pf"] >= args.min_pf else "FAIL", f"PF {fmt(s['pf'])}"))
    else:
        checks.append(("evaluation set", "FAIL", "no trades in the evaluation set"))

    # --- placebo
    if args.placebo:
        plc = load_trades(args.placebo, args, "placebo trades")
        if args.placebo_signals:
            report_signals(args.placebo_signals, "placebo signals")
        p_eval = [t for t in plc if t.entry >= split] if split else plc
        print_table("PLACEBO trades by setup / grade", group_by_setup_grade(plc))
        print(f"\n== placebo comparison ({'OOS' if split else 'ALL'}; 03 section 11.10)")
        print(f"{'setup':<8}{'real n':>8}{'real exp':>10}{'plc n':>8}{'plc exp':>10}{'gap':>8}{'n ratio':>9}")
        for st in SETUP_ORDER + ["ALL"]:
            a = evalset if st == "ALL" else [t for t in evalset if t.setup == st]
            b = p_eval if st == "ALL" else [t for t in p_eval if t.setup == st]
            if not a and not b:
                continue
            ea = sum(t.net for t in a) / len(a) if a else float("nan")
            eb = sum(t.net for t in b) / len(b) if b else float("nan")
            ratio = len(b) / len(a) if a else float("nan")
            print(f"{st:<8}{len(a):>8}{fmt(ea, 3):>10}{len(b):>8}{fmt(eb, 3):>10}{fmt(ea - eb, 3):>8}{fmt(ratio):>9}")
        if evalset and p_eval:
            ea = sum(t.net for t in evalset) / len(evalset)
            eb = sum(t.net for t in p_eval) / len(p_eval)
            gap = ea - eb
            ratio = len(p_eval) / len(evalset)
            checks.append((f"real beats placebo by >= {args.placebo_gap}R",
                           "PASS" if gap >= args.placebo_gap else "FAIL",
                           f"gap {fmt(gap, 3)} R (real {fmt(ea, 3)}, placebo {fmt(eb, 3)})"))
            if not (0.67 <= ratio <= 1.5):
                print(f"warning: placebo/real trade count ratio {fmt(ratio)} is outside 0.67..1.5 - the comparison is "
                      "weak; recalibrate placeboWickFrac / placeboSzrBodyATR (docs/decisions/signals.md)")
            checks.append(("placebo trade count comparable (0.67..1.5)", "PASS" if 0.67 <= ratio <= 1.5 else "WARN",
                           f"ratio {fmt(ratio)}"))
        else:
            checks.append((f"real beats placebo by >= {args.placebo_gap}R", "FAIL", "no placebo or real trades"))
    else:
        checks.append(("real beats placebo (03 section 11.10)", "TODO", "run with --placebo <trades of the placebo run>"))

    checks.append(("forward demo >= 6 weeks matching the tester", "MANUAL", "compare the demo journal with a tester run"))
    if not split:
        checks.append(("out-of-sample split", "WARN", "no --split given: every item above used ALL trades"))

    print("\n== acceptance checklist (03 section 11.8)")
    for item, status, detail in checks:
        print(f"  [{status:<6}] {item:<48} {detail}")
    failed = any(st == "FAIL" for _, st, _ in checks)
    return 1 if (args.strict and failed) else 0


if __name__ == "__main__":
    sys.exit(main())
