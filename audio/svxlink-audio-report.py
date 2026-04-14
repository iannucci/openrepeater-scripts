#!/usr/bin/env python3
"""
svxlink-audio-report — summarize the svxlink-audio-monitor.jsonl log.

Usage:
    svxlink-audio-report                 # last 24h
    svxlink-audio-report --hours 6       # last 6h
    svxlink-audio-report --since "2026-04-13 20:00"
    svxlink-audio-report --detail        # also print every individual event

Reports per-hour event counts and per-TX-session glitch rates.
"""

import argparse
import json
import os
import sys
import time
from collections import Counter, defaultdict
from datetime import datetime, timedelta

LOG = "/var/log/svxlink-audio-monitor.jsonl"
ROTATED = [LOG + f".{i}" for i in range(1, 8)] + [LOG + f".{i}.gz" for i in range(1, 8)]


def open_log_paths():
    """Return the set of log files to read (current + uncompressed rotated)."""
    paths = []
    for p in [LOG] + ROTATED:
        if os.path.exists(p):
            paths.append(p)
    return paths


def iter_records(since_ts):
    """Yield decoded JSON records from all log files, filtered by timestamp."""
    import gzip
    for path in open_log_paths():
        opener = gzip.open if path.endswith(".gz") else open
        try:
            with opener(path, "rt") as f:
                for line in f:
                    line = line.strip()
                    if not line: continue
                    try:
                        rec = json.loads(line)
                    except Exception:
                        continue
                    if rec.get("ts", 0) < since_ts:
                        continue
                    yield rec
        except Exception as e:
            print(f"# warning: cannot read {path}: {e}", file=sys.stderr)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--hours", type=float, default=24)
    ap.add_argument("--since", type=str, default=None)
    ap.add_argument("--detail", action="store_true")
    args = ap.parse_args()

    if args.since:
        since_ts = time.mktime(time.strptime(args.since, "%Y-%m-%d %H:%M"))
    else:
        since_ts = time.time() - args.hours * 3600

    records = list(iter_records(since_ts))
    if not records:
        print(f"No events since {datetime.fromtimestamp(since_ts).strftime('%Y-%m-%d %H:%M:%S')}")
        return

    print(f"# Window: {datetime.fromtimestamp(since_ts).strftime('%Y-%m-%d %H:%M:%S')} - "
          f"{datetime.fromtimestamp(time.time()).strftime('%Y-%m-%d %H:%M:%S')}")
    print(f"# Total records: {len(records)}")
    print()

    # Overall counts by event type
    types = Counter(r["type"] for r in records)
    print("=== Event totals ===")
    for k in ["tx_open", "tx_close", "tx_session_summary",
              "tx_xrun_real_mid", "tx_xrun_tail", "tx_xrun_idle",
              "rx_xrun", "tx_near_under", "rx_near_over"]:
        if types[k]:
            tag = " ← AUDIBLE GLITCH" if k == "tx_xrun_real_mid" else \
                  " (benign end-of-TX drainout)" if k == "tx_xrun_tail" else ""
            print(f"  {k:22s} {types[k]}{tag}")
    print()

    # Per-hour bins
    print("=== Per-hour event counts ===")
    by_hour = defaultdict(Counter)
    for r in records:
        h = datetime.fromtimestamp(r["ts"]).strftime("%Y-%m-%d %H")
        by_hour[h][r["type"]] += 1
    print(f"  {'hour':17s}  {'tx_open':>7s}  {'GLITCH':>6s}  {'tail':>5s}  {'near':>5s}  {'rx_xrun':>7s}")
    for h in sorted(by_hour):
        c = by_hour[h]
        print(f"  {h:17s}  {c['tx_open']:>7d}  {c['tx_xrun_real_mid']:>6d}  {c['tx_xrun_tail']:>5d}  {c['tx_near_under']:>5d}  {c['rx_xrun']:>7d}")
    print()

    # Per-session glitch rates
    print("=== TX session summaries ===")
    sessions = [r for r in records if r["type"] == "tx_session_summary"]
    if not sessions:
        print("  (no completed sessions in window)")
    else:
        print(f"  {'time':19s}  {'duration_s':>10s}  {'xruns':>6s}  {'near':>4s}  {'max_avail':>9s}")
        for s in sessions:
            t = datetime.fromtimestamp(s["start_ts"]).strftime("%Y-%m-%d %H:%M:%S")
            print(f"  {t}  {s.get('duration_s', 0):>10.2f}  "
                  f"{s.get('xruns', 0):>6d}  {s.get('near_under', 0):>4d}  "
                  f"{s.get('max_avail', 0):>9d}")
        total_dur = sum(s.get("duration_s", 0) for s in sessions)
        total_xrun = sum(s.get("xruns", 0) for s in sessions)
        print()
        print(f"  Total TX active time: {total_dur:.1f}s ({total_dur/60:.1f}min)")
        if total_dur > 0:
            print(f"  Audible XRUN rate during TX-active: {60*total_xrun/total_dur:.2f}/min")
    print()

    if args.detail:
        print("=== Individual events ===")
        for r in records:
            t = datetime.fromtimestamp(r["ts"]).strftime("%H:%M:%S.%f")[:-3]
            extra = ""
            if r["type"] == "tx_xrun_real_mid":
                extra = f" recovery_ms={r.get('recovery_ms')} recovery_avail={r.get('recovery_avail')}"
            elif r["type"] == "tx_xrun_tail":
                extra = f" elapsed_ms={r.get('elapsed_ms')}"
            print(f"  {t}  {r['type']:18s}  tx={r['tx_state']}/{r['tx_avail']}/{r['tx_avail_max']}  rx={r['rx_state']}/{r['rx_avail']}/{r['rx_avail_max']}{extra}")


if __name__ == "__main__":
    main()
