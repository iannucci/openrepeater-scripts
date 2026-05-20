# patches/deferred/

Patches in this directory are intentionally **not applied** by the build.

Both build paths glob `patches/*.patch` non-recursively
(`bench-clean-rebuild.sh:27`, `functions/functions.sh:190`), so files in this
subdirectory are skipped while their work remains preserved and easily
re-enabled by moving them back up one level.

## Why each is deferred

### `01-svxlink-jitter-buffer.patch` (deferred 2026-05-19)

Tunes the EchoLink jitter buffer for AREDN / Bay Area Backbone network
jitter (`JITTER_TARGET_DEPTH 3→5`, `JITTER_MAX_DEPTH 10→20`,
`JITTER_UNDERRUN_RESET_TICKS 5→10`, plus a ~246-line silence-fill
extension in `EchoLinkQso.cpp`). On the W6EI prod repeater this caused a
hard regression: inbound EchoLink TX never un-keyed on its own. The
custom silence-fill kept `AudioStreamStateDetector` active continuously,
which kept `Logic::logicIdleStateChanged` false, which gated *both*
`RepeaterLogic::idleTimeout` (`IDLE_TIMEOUT`=1s) and
`QsoImpl::idleTimeoutCheck` (`LINK_IDLE_TIMEOUT`=300s) — neither timer
could ever count down. Operator could only clear stuck transmissions by
keying RF locally and un-keying (an RF squelch transition forces a state
re-eval).

Resolved 2026-05-19 by reverting to upstream 24.02 JB.
See `~/.claude/projects/.../memory/project_echolink_stuck_tx_resolved.md`
for the full A/B history.

**Re-enable only after** the JB is re-engineered to either (a) stop
emitting after `underrun_reset_ticks` so the stream goes truly idle, or
(b) add an independent "no real RX audio for N seconds → `disconnect()`"
timer at `QsoImpl` that bypasses the `!logic_is_idle` guard.

### `02-svxlink-jitter-buffer-logging.patch` (deferred 2026-05-19)

Adds the `EchoLink JB: ...` diagnostic log lines used to characterize the
patch-01 behavior. Depends on variables introduced by patch 01, so it
travels with it. Re-enable together with a re-engineered 01.
