#!/usr/bin/env python3
"""
svxlink-audio-monitor — passive ALSA observability daemon.

Watches /proc/asound/card0/pcm0p (TX) and /proc/asound/card0/pcm0c (RX) at
200 Hz and writes a JSONL event log when something interesting happens:

  tx_open            — TX playback substream entered RUNNING (= TX keyup)
  tx_close           — TX playback substream left RUNNING/XRUN (= TX dekey)
  tx_xrun_real_mid   — TX buffer drained mid-transmission AND svxlink
                        resumed feeding within 500 ms. Audible underrun.
  tx_xrun_tail       — TX buffer drained and svxlink never resumed within
                        500 ms (= normal end-of-transmission drainout
                        during PTT hangtime; not audible).
  tx_xrun_idle       — TX transitioned to XRUN with buffer never having been
                        active (= substream bookkeeping; not audible).
  rx_xrun            — RX capture transitioned RUNNING -> XRUN
                        (= real A/D overrun: capture buffer overflowed).
  tx_near_under      — TX avail crossed BUFSIZE - PERIOD threshold while
                        still RUNNING (warning: getting close to underrun).
  rx_near_over       — RX avail crossed BUFSIZE - PERIOD threshold
                        (warning: getting close to overrun).

The mid vs tail distinction is critical: overnight on W6EI, *every*
scheduled CW/voice ID produces an XRUN at the natural end of the tone
when svxlink stops writing — these are inaudible and must not be
mistaken for glitches. An audible glitch is one where svxlink wanted
to keep feeding audio but fell behind; the buffer drained; and audio
resumed (buffer refilled) within a short window after.

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
XRUN_CLASSIFY_MS = 500         # window in which audio must resume to count
                               # as a real mid-transmission glitch. Longer
                               # than any svxlink hangtime we'd care about.


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

    # Deferred XRUN classification: when buffer drains during an active TX
    # session, we don't know yet whether it's a mid-transmission glitch
    # (audio will resume) or an end-of-transmission tail (audio stopped
    # for good). Buffer the event and wait XRUN_CLASSIFY_MS to decide.
    pending_xrun = None  # dict: ts, trigger_sample, ctx_at_emit, prev_avail, prev_avail_max

    def flush_pending_as_tail():
        """Called when the pending window expires without recovery."""
        nonlocal pending_xrun
        if pending_xrun is None:
            return
        emit(fp, "tx_xrun_tail",
             pending_xrun["trigger_sample"],
             pending_xrun["ctx_at_emit"],
             prev_avail=pending_xrun["prev_avail"],
             prev_avail_max=pending_xrun["prev_avail_max"],
             elapsed_ms=round((time.time() - pending_xrun["ts"]) * 1000, 1))
        pending_xrun = None

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

            # --- Deferred XRUN classification ---
            if pending_xrun is not None:
                elapsed = ts - pending_xrun["ts"]
                # Condition for "real mid-transmission glitch": buffer is
                # refilling. avail dropping below BUFSIZE while state is
                # RUNNING means new samples are being written. State can
                # also pop back to RUNNING with avail < BUFSIZE.
                if ps == "RUNNING" and pa < BUFSIZE:
                    emit(fp, "tx_xrun_real_mid",
                         pending_xrun["trigger_sample"],
                         pending_xrun["ctx_at_emit"],
                         prev_avail=pending_xrun["prev_avail"],
                         prev_avail_max=pending_xrun["prev_avail_max"],
                         recovery_ms=round(elapsed * 1000, 1),
                         recovery_avail=pa)
                    if session is not None:
                        session["xruns"] = session.get("xruns", 0) + 1
                    pending_xrun = None
                elif elapsed * 1000 >= XRUN_CLASSIFY_MS:
                    # Timed out without recovery — benign tail
                    emit(fp, "tx_xrun_tail",
                         pending_xrun["trigger_sample"],
                         pending_xrun["ctx_at_emit"],
                         prev_avail=pending_xrun["prev_avail"],
                         prev_avail_max=pending_xrun["prev_avail_max"],
                         elapsed_ms=round(elapsed * 1000, 1))
                    pending_xrun = None

            # --- TX (playback) state transitions ---
            # Consider both RUNNING and XRUN as "active" session states so
            # tx_close fires on the RUNNING/XRUN -> anything-else boundary.
            active_prev = ps_prev in ("RUNNING", "XRUN")
            active_now  = ps     in ("RUNNING", "XRUN")

            if ps_prev != ps:
                if ps == "RUNNING" and ps_prev != "RUNNING":
                    # Keyup (from XRUN-idle or from not-open)
                    if ps_prev != "XRUN" or session is None:
                        session = {"start_ts": ts, "samples": 0,
                                   "near_under": 0, "max_avail": 0}
                        emit(fp, "tx_open", s, list(ctx), prev_state=ps_prev)
                elif ps_prev == "RUNNING" and ps == "XRUN":
                    if pm > 0 and prev[2] < BUFSIZE:
                        # XRUN while buffer was previously active — defer
                        # classification until we see whether audio resumes
                        pending_xrun = {
                            "ts": ts,
                            "trigger_sample": s,
                            "ctx_at_emit": list(ctx),
                            "prev_avail": prev[2],
                            "prev_avail_max": prev[3],
                        }
                    else:
                        # Substream parked / buffer never active
                        emit(fp, "tx_xrun_idle", s, list(ctx),
                             prev_avail=prev[2])
                elif active_prev and not active_now:
                    # Leaving active states (RUNNING or XRUN) to something
                    # else (OPEN, SETUP, PREPARED, etc.) = end of TX session
                    if pending_xrun is not None:
                        # Outstanding XRUN never recovered — flush as tail
                        flush_pending_as_tail()
                    emit(fp, "tx_close", s, list(ctx),
                         prev_state=ps_prev)
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
