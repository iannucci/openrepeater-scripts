#!/usr/bin/env python3
"""
Correlate svxlink-gpio-monitor edge events against svxlink's own
squelch-state log messages. Reports:

  - Every GPIO rising edge that has no matching 'squelch is OPEN'
    line in /var/log/svxlink within TOLERANCE seconds (svxlink missed
    the keyup — this is the failure mode we are hunting)
  - Every GPIO falling edge that has no matching 'squelch is CLOSED'
  - Every svxlink squelch-state log line that has no matching GPIO
    edge (would indicate a spurious svxlink event — unexpected)

Usage:
    svxlink-gpio-vs-log                 # last 24h
    svxlink-gpio-vs-log --hours 2       # last 2h
    svxlink-gpio-vs-log --tolerance 0.5 # tighter match window (default 1.0 s)
"""
import argparse, gzip, json, os, re, sys, time
from datetime import datetime

GPIO_LOG     = "/var/log/svxlink-gpio-monitor.jsonl"
SVXLINK_LOG  = "/var/log/svxlink"
GPIO_ROTATED = [GPIO_LOG + f".{i}" for i in range(1, 8)] + \
               [GPIO_LOG + f".{i}.gz" for i in range(1, 8)]

SVXLINK_LINE = re.compile(
    r'^(\w{3} \w{3} \s?\d+ \d{2}:\d{2}:\d{2} \d{4}): RX_Port1: The squelch is (OPEN|CLOSED)'
)


def load_gpio_edges(since_ts):
    out = []
    for p in [GPIO_LOG] + GPIO_ROTATED:
        if not os.path.exists(p):
            continue
        opener = gzip.open if p.endswith(".gz") else open
        try:
            with opener(p, "rt") as f:
                for line in f:
                    try:
                        rec = json.loads(line)
                    except Exception:
                        continue
                    if rec.get("type") != "edge":
                        continue
                    if rec["ts"] < since_ts:
                        continue
                    out.append(rec)
        except Exception as e:
            print(f"# cannot read {p}: {e}", file=sys.stderr)
    return sorted(out, key=lambda r: r["ts"])


def load_svxlink_squelch(since_ts):
    out = []
    if not os.path.exists(SVXLINK_LOG):
        return out
    with open(SVXLINK_LOG) as f:
        for line in f:
            m = SVXLINK_LINE.match(line)
            if not m:
                continue
            try:
                ts = time.mktime(time.strptime(m.group(1), "%a %b %d %H:%M:%S %Y"))
            except Exception:
                continue
            if ts < since_ts:
                continue
            out.append({"ts": ts, "state": m.group(2)})
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--hours", type=float, default=24)
    ap.add_argument("--tolerance", type=float, default=1.0,
                    help="max seconds between GPIO edge and svxlink log line "
                         "to consider them matched (default 1.0)")
    args = ap.parse_args()
    since = time.time() - args.hours * 3600

    gpio = load_gpio_edges(since)
    svx  = load_svxlink_squelch(since)
    print(f"# Window last {args.hours} hours, tolerance {args.tolerance} s")
    print(f"# GPIO edges:      {len(gpio)}")
    print(f"# svxlink squelch: {len(svx)}")
    print()

    def match_gpio_to_svx(edge):
        """For a GPIO rising edge, find closest svxlink OPEN within tolerance
        (or falling to CLOSED)."""
        want = "OPEN" if edge["value"] == 1 else "CLOSED"
        best = None
        for s in svx:
            if s["state"] != want:
                continue
            dt = s["ts"] - edge["ts"]
            if -args.tolerance <= dt <= args.tolerance:
                if best is None or abs(dt) < abs(best["ts"] - edge["ts"]):
                    best = s
        return best

    missed_opens = []
    missed_closes = []
    for e in gpio:
        m = match_gpio_to_svx(e)
        if m is None:
            if e["value"] == 1:
                missed_opens.append(e)
            else:
                missed_closes.append(e)

    print(f"=== GPIO rising edges (keyup) with NO matching svxlink OPEN ({len(missed_opens)}) ===")
    for e in missed_opens:
        print(f"  {datetime.fromtimestamp(e['ts']).strftime('%Y-%m-%d %H:%M:%S.%f')[:-3]}  GPIO->1")

    print()
    print(f"=== GPIO falling edges (dekey) with NO matching svxlink CLOSED ({len(missed_closes)}) ===")
    for e in missed_closes:
        print(f"  {datetime.fromtimestamp(e['ts']).strftime('%Y-%m-%d %H:%M:%S.%f')[:-3]}  GPIO->0")

    print()
    def match_svx_to_gpio(s):
        want = 1 if s["state"] == "OPEN" else 0
        for e in gpio:
            if e["value"] != want:
                continue
            if abs(e["ts"] - s["ts"]) <= args.tolerance:
                return e
        return None

    orphan_svx = [s for s in svx if match_svx_to_gpio(s) is None]
    print(f"=== svxlink squelch events with NO matching GPIO edge ({len(orphan_svx)}) ===")
    for s in orphan_svx[:40]:
        print(f"  {datetime.fromtimestamp(s['ts']).strftime('%Y-%m-%d %H:%M:%S')}  svxlink {s['state']}")


if __name__ == "__main__":
    main()
