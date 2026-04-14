#!/usr/bin/env python3
"""
svxlink-gpio-monitor — edge-accurate observability for the RX squelch GPIO.

svxlink itself polls /sys/class/gpio/gpioN/value on a 100 ms timer. If
svxlink's single thread stalls (or blocks inside a syscall, logging, etc.),
edges can be missed entirely — and because svxlink only acts on state
transitions (not levels), a missed rising-edge means the keyup is lost
forever: by the time the next poll runs, the line may already be back
low, or svxlink's "last known state" may already match the current
state, so no squelchOpen event fires.

This daemon is an independent edge-triggered observer. It uses the
kernel's sysfs GPIO edge notification (POLLPRI on
/sys/class/gpio/gpioN/value with edge=both) to get woken up by the
kernel within microseconds of every transition. Each transition is
written to a JSONL event log.

To detect missed events in svxlink, cross-correlate this log with the
main svxlink log: for every rising edge here, there should be a
"squelch is OPEN" line in /var/log/svxlink within a few hundred ms. If
there isn't, svxlink missed the edge.

Designed to run as a persistent low-priority systemd service alongside
svxlink-audio-monitor.

Log: /var/log/svxlink-gpio-monitor.jsonl
     one JSON object per line, sorted by timestamp.
     Event types: 'init' (startup), 'edge' (a state transition).
"""

import errno
import json
import os
import select
import signal
import sys
import time

PIN = os.environ.get("SVXLINK_SQL_GPIO", "26")
SYSFS = f"/sys/class/gpio/gpio{PIN}"
LOG = "/var/log/svxlink-gpio-monitor.jsonl"


def ensure_exported():
    """Make sure gpioN is exported in sysfs. Normally svxlink exports it
    on startup. On a host without the ICS board hardware (bench Pi with
    no radio interface), the pin may never exist — in that case we poll
    here waiting for it to appear rather than crashing the service. Once
    it appears (e.g., after hardware is attached or card is moved into
    production), we proceed."""
    waited = 0
    while not os.path.exists(SYSFS):
        try:
            with open("/sys/class/gpio/export", "w") as f:
                f.write(PIN)
            break
        except OSError as e:
            if e.errno == errno.EBUSY:
                break  # already exported
            # Directory may not exist at all (no GPIO controller, no svxlink
            # running yet, or pin not valid). Wait and try again.
            if waited == 0:
                sys.stderr.write(
                    f"svxlink-gpio-monitor: waiting for /sys/class/gpio/gpio{PIN} "
                    f"to appear (last err: {e.strerror}). Will keep retrying.\n")
                sys.stderr.flush()
            time.sleep(10)
            waited += 10
    # Final sanity: if still not present, wait here forever (Restart=always
    # would otherwise just loop us endlessly).
    while not os.path.exists(SYSFS):
        time.sleep(30)


def ensure_edge_both():
    """Enable kernel-level edge notification. This is a system-wide
    setting but svxlink doesn't poll() on this fd so it's unaffected.
    If a previous run already set this we'll silently succeed."""
    with open(f"{SYSFS}/edge", "w") as f:
        f.write("both")


def read_value(fd):
    """Read the current GPIO value (0 or 1 after kernel active_low inversion)."""
    os.lseek(fd, 0, os.SEEK_SET)
    raw = os.read(fd, 8)
    # strip newline / nulls
    for b in raw:
        if b in (ord('0'), ord('1')):
            return int(chr(b))
    return None


def read_active_low():
    """Is the pin using kernel-level active-low inversion?"""
    try:
        with open(f"{SYSFS}/active_low") as f:
            return int(f.read().strip())
    except Exception:
        return 0


def main():
    ensure_exported()
    ensure_edge_both()
    active_low = read_active_low()

    # Open value fd; edge-triggered readings use POLLPRI.
    fd = os.open(f"{SYSFS}/value", os.O_RDONLY)
    # Do an initial read to clear the "unread" state and latch the current value
    initial = read_value(fd)

    poller = select.poll()
    poller.register(fd, select.POLLPRI | select.POLLERR)

    logf = open(LOG, "a", buffering=1)
    def reopen(_sig, _frm):
        nonlocal logf
        try: logf.close()
        except Exception: pass
        logf = open(LOG, "a", buffering=1)
    signal.signal(signal.SIGHUP, reopen)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))

    logf.write(json.dumps({
        "ts": time.time(),
        "type": "init",
        "pin": PIN,
        "initial_value": initial,
        "active_low_inversion": active_low,
        "note": "edge=both enabled; subsequent events are state transitions",
    }) + "\n")

    last = initial
    while True:
        # Kernel wakes us on edge. Without timeout we wait forever.
        events = poller.poll(5000)  # 5 s timeout for health-check heartbeat
        ts = time.time()
        if not events:
            # No transitions in 5 s — just record a heartbeat
            logf.write(json.dumps({"ts": ts, "type": "heartbeat",
                                   "value": read_value(fd)}) + "\n")
            continue
        # On a POLLPRI wakeup we must read to clear the condition.
        val = read_value(fd)
        if val != last:
            logf.write(json.dumps({
                "ts": ts,
                "type": "edge",
                "value": val,
                "direction": "rising" if (last == 0 and val == 1) else "falling",
            }) + "\n")
            last = val
        # If val == last, it was a spurious wakeup — ignore


if __name__ == "__main__":
    main()
