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

### `10-svxlink-block-underflow-probe.patch` (deferred 2026-05-20)

ORP-DIAG block-underflow probe in `AsyncAudioDeviceAlsa.cpp` — logs
`*** ORP-DIAG block-underflow: START/END ...` on every in-clip
`getBlocks()==0 → zerofill_on_underflow` event. Built to test the
silent-splice hypothesis (was the audible glitch caused by in-clip
zerofill?). A/B-ruled-out 2026-05-19: the audible glitch is post-digital
(see `project_bench_clean_prod_glitch.md`), and a separate A/B
on the same day exonerated patch 10 as the cause of the EchoLink
never-un-keys regression. So patch 10 is **behaviorally safe** — but
deferred because:

1. **Canonical alignment.** The 2026-05-19 prod rebuild that fixed the
   never-un-keys regression was built with `03,04,05,06,09` only
   (without patch 10). With patch 10 in canonical, a fresh build from
   HEAD would re-introduce it and diverge from the running prod binary
   for no operational reason. Keeping it in `deferred/` makes
   canonical-build == currently-running-prod exact.
2. **Log noise in the hot path.** Patch 10 writes `cerr` from inside
   `AudioDeviceAlsa::writeSpaceAvailable` (the single-threaded audio
   callback) on every block-underflow event. During EchoLink inbound
   it fires steadily — useful when actively diagnosing zerofill-related
   questions, expensive otherwise (especially on prod's slow FAT32
   `/var/log`).

Re-enable temporarily when actively diagnosing in-clip zerofill behavior
(e.g., when re-engineering patch 01); leave deferred for normal operation.
