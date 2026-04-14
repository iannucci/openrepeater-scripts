#!/usr/bin/env python3
"""
svxlink-audio-monitor — passive ALSA observability daemon.

Watches /proc/asound/card0/pcm0p (TX) and /proc/asound/card0/pcm0c (RX) at
200 Hz and writes a JSONL event log when something interesting happens:

  tx_open        — TX playback substream entered RUNNING (= TX keyup)
  tx_close       — TX playback substream left RUNNING (= TX dekey)
  tx_xrun_real   — TX playback transitioned RUNNING -> XRUN with avail_max>0
                   (= real audible underrun: D/A starved of samples)
  tx_xrun_idle   — TX playback transitioned to XRUN with avail_max==0
                   (= substream parked because no audio to send; not audible)
  rx_xrun        — RX capture transitioned RUNNING -> XRUN
                   (= real A/D overrun: capture buffer overflowed)
  tx_near_under  — TX playback avail crossed BUFSIZE - PERIOD threshold
                   while still RUNNING (warning: getting close to underrun)
  rx_near_over   — RX capture avail crossed BUFSIZE - PERIOD threshold
                   (warning: getting close to overrun)

Each emitted record is one JSON object on its own line, including up to
1 second (200 samples) of context leading up to the event.

Designed to run forever as a low-priority systemd service. Memory and CPU
footprint are minimal; no disk I/O between events.

To inspect the log:
    tail -F /var/log/svxlink-audio-monitor.jsonl
    /usr/local/bin/svxlink-audio-report   # summary tool
"""

import collections
import json
import os
import signal
import sys
import time

PROD_P = "/proc/asound/card0/pcm0p/sub0/status"
PROD_C = "/proc/asound/card0/pcm0c/sub0/status"
LOG    = "/var/log/svxlink-audio-monitor.jsonl"

SAMPLE_HZ = 200                # 5 ms between samples
CTX_LEN   = 200                # 1 s of context kept in a ring buffer
BUFSIZE   = 4096               # ALSA hw_params buffer_size (frames)
PERIOD    = 1024               # ALSA hw_params period_size  (frames)
NEAR_THR  = BUFSIZE - PERIOD   # 3072: threshold for "near underrun/overrun"


def parse(text):
    """Parse /proc/asound/.../status — return (state, avail, avail_max)."""
    state, avail, avmax = "", 0, 0
    for line in text.split("\n"):
        if line.startswith("state:"):
            state = line.split(":", 1)[1].strip()
        elif line.startswith("avail "):
            try: avail = int(line.split(":", 1)[1].strip())
            except: pass
        elif line.startswith("avail_max"):
            try: avmax = int(line.split(":", 1)[1].strip())
            except: pass
    return state, avail, avmax


def sample():
    """Take one snapshot of both substreams. Returns 7-tuple or None."""
    try:
        with open(PROD_P) as f: pt = f.read()
        with open(PROD_C) as f: ct = f.read()
    except Exception:
        return None
    ts = time.time()
    ps, pa, pm = parse(pt)
    cs, ca, cm = parse(ct)
    return (ts, ps, pa, pm, cs, ca, cm)


def ctx_to_compact(ctx):
    """Compact context for the log (drop verbose fields)."""
    out = []
    for s in ctx:
        out.append({
            "ts": round(s[0], 4),
            "tx": s[1][:4], "tx_av": s[2], "tx_avm": s[3],
            "rx": s[4][:4], "rx_av": s[5], "rx_avm": s[6],
        })
    return out


def emit(fp, event, current, ctx, **extra):
    rec = {
        "type": event,
        "ts": current[0],
        "tx_state": current[1], "tx_avail": current[2], "tx_avail_max": current[3],
        "rx_state": current[4], "rx_avail": current[5], "rx_avail_max": current[6],
    }
    rec.update(extra)
    rec["context"] = ctx_to_compact(ctx)
    fp.write(json.dumps(rec, separators=(",", ":")) + "\n")
    fp.flush()


def open_log_for_append():
    """Open log; create with mode 644 if needed."""
    fp = open(LOG, "a", buffering=1)
    return fp


def main():
    # Open log; on rotation we'll get SIGHUP to reopen.
    fp = open_log_for_append()
    def reopen(_signum, _frame):
        nonlocal fp
        try: fp.close()
        except Exception: pass
        fp = open_log_for_append()
    signal.signal(signal.SIGHUP, reopen)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))

    ctx = collections.deque(maxlen=CTX_LEN)
    period_s = 1.0 / SAMPLE_HZ
    prev = None
    next_t = time.time()

    # Per-session stats accumulator
    session = None  # dict opened on tx_open, emitted on tx_close

    while True:
        s = sample()
        if s is None:
            time.sleep(period_s)
            next_t = time.time() + period_s
            continue
        ctx.append(s)
        ts, ps, pa, pm, cs, ca, cm = s

        if prev is not None:
            ps_prev = prev[1]
            cs_prev = prev[4]

            # --- TX (playback) state transitions ---
            if ps_prev != ps:
                if ps == "RUNNING" and ps_prev != "RUNNING":
                    # Keyup
                    session = {"start_ts": ts, "samples": 0, "near_under": 0,
                               "max_avail": 0}
                    emit(fp, "tx_open", s, list(ctx), prev_state=ps_prev)
                elif ps_prev == "RUNNING" and ps == "XRUN":
                    if pm > 0 and prev[2] < BUFSIZE:
                        # Real audible underrun: was actively buffered, now empty
                        emit(fp, "tx_xrun_real", s, list(ctx),
                             prev_avail=prev[2], prev_avail_max=prev[3])
                        if session is not None:
                            session.setdefault("xruns", 0)
                            session["xruns"] += 1
                    else:
                        # Substream parked / no buffered data: not audible
                        emit(fp, "tx_xrun_idle", s, list(ctx),
                             prev_avail=prev[2])
                elif ps_prev == "RUNNING" and ps != "RUNNING" and ps != "XRUN":
                    emit(fp, "tx_close", s, list(ctx), prev_state=ps_prev)
                    if session is not None:
                        session["end_ts"] = ts
                        session["duration_s"] = round(ts - session["start_ts"], 3)
                        emit(fp, "tx_session_summary", s, [], **session)
                        session = None

            # --- RX (capture) overrun detection ---
            if cs_prev == "RUNNING" and cs == "XRUN":
                emit(fp, "rx_xrun", s, list(ctx), prev_avail=prev[5],
                     prev_avail_max=prev[6])

            # --- Near-miss thresholds (warn before XRUN) ---
            if ps == "RUNNING" and pa > NEAR_THR and prev[2] <= NEAR_THR:
                emit(fp, "tx_near_under", s, list(ctx))
                if session is not None:
                    session["near_under"] += 1
            if cs == "RUNNING" and ca > NEAR_THR and prev[5] <= NEAR_THR:
                emit(fp, "rx_near_over", s, list(ctx))

        # Update session running stats while TX is active
        if session is not None and ps == "RUNNING":
            session["samples"] += 1
            if pa > session["max_avail"]:
                session["max_avail"] = pa

        prev = s
        # Pace the loop
        next_t += period_s
        delay = next_t - time.time()
        if delay > 0:
            time.sleep(delay)
        elif delay < -0.5:  # got way behind; resync
            next_t = time.time() + period_s


if __name__ == "__main__":
    main()
