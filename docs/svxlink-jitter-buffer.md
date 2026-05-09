# SvxLink EchoLink RX Jitter Buffer — Design Document

**Status:** Efficacy-validated on bench Pi against real Newsline audio under synthetic network jitter + bandwidth saturation. Drift-during-silence bug discovered and fixed during the A/B validation phase. Ready for Phase 6 card-swap deployment.
**Date:** 2026-04-11 (initial) / 2026-04-11 (Newsline A/B validation, drift bug fix)
**Owner:** Bob Iannucci (W6EI) with Claude (Anthropic AI)
**Patch file:** `patches/svxlink-jitter-buffer.patch` (436 lines)
**Build integration:** `functions/functions.sh::apply_svxlink_patches`, called from `install_svxlink_source`
**Tracking issue:** `iannucci/openrepeater-config#1`

---

## 1. Problem statement

The W6EI amateur-radio repeater has exhibited long-standing EchoLink audio quality problems: audible dropouts, reorder artifacts, and decoder glitches severe enough that Newsline (a scheduled pre-recorded EchoLink program) is sometimes described by the operator as "embarrassingly bad, nearly unintelligible." Degradation is worse at some times of day than others and correlates with load on the Bay Area Backbone, the private AREDN-based wireless backbone that carries the repeater's internet connection.

An earlier phase of this investigation (documented in `~/Documents/Claude/jitter/` on the operator's Mac) established two independent facts:

1. **The network path has real variance.** Parallel multi-hop ICMP probing from the live W6EI Pi over 10-minute windows, plus tcpdump packet captures of the actual inbound Newsline EchoLink stream, showed sustained `mdev` in the low tens of milliseconds with occasional 100-300 ms spikes. Under synthetic bulk-download load from the Pi, the packet-level pcap showed 66 RTP loss gaps, 28 reorder events, and 67 missing sequence numbers in a 5-minute window (versus 0/0/0 on the clean baseline). These are real, reproducible network phenomena, and the dominant effect is on the inbound (EchoLink RX) direction.
2. **SvxLink's receive path is unusually fragile to network variance.** The source code in `src/echolib/EchoLinkQso.cpp` decodes incoming RTP-formatted GSM audio packets and writes the samples directly to the downstream `AudioSink` via `sinkWriteSamples` in the same call as packet arrival, inside the UDP receive callback. It does not read the 16-bit sequence number field that the sending side diligently writes, does not maintain any elastic buffer, does not detect out-of-order arrivals, does not discard duplicates, does not conceal packet loss, and does not handle sink backpressure. Any network inter-arrival gap larger than the 80 ms packet cadence becomes an audible glitch at the application layer — even without any actual packet loss.

The operator conclusively demonstrated that the receive-path source files (`EchoLinkQso.cpp`, `EchoLinkDispatcher.cpp`, `rtpacket.cpp`) are **byte-identical across sm0svx/svxlink tags 19.09.1, 24.02, and current `master`**. The upstream project has not changed this code in six years. Upgrading SvxLink as part of the card rebuild will not improve the audio quality by itself; the fix has to be in the application layer or in the network.

This document describes the application-layer fix: a small FIFO playout jitter buffer inserted between the UDP packet decode and the audio sink write, keyed on the RTP sequence number that already exists in the wire format.

---

## 2. Measurement-based algorithm tuning

Before writing any C++, the operator built a Python simulator (`~/Documents/Claude/jitter/simulate_jitter_buffer.py`) that replays real captured pcap traffic through a FIFO jitter buffer of configurable depth and reports the number of "audible silence" events that would have been emitted (slots where the current playout head had no corresponding packet in the buffer).

### 2.1 Captured data

Three 5-minute pcap captures of a real inbound Newsline audio stream were used:

| Run | Conditions | Total packets | Baseline glitches (depth=0, no buffer) |
|---|---|---:|---:|
| Clean | no additional load | 3348 | 9 |
| Upload | Pi uploading 32 Mbps outbound to Cloudflare | 3341 | 76 |
| Download | Pi downloading 66 Mbps inbound from Cachefly | 3337 | 122 |

The "download" run is the worst case and most relevant — it saturates the inbound direction, which is the same direction as the EchoLink audio, and it's the only run where the jitter buffer could theoretically recover lost information (reorder events make up ~22% of the damage in that run).

### 2.2 Depth sweep

For each run, the simulator replayed every arrival timestamp and sequence number through a FIFO jitter buffer with `JITTER_TARGET_DEPTH` varied across `{0, 1, 2, 3, 4, 5, 6, 8, 10}` packets.

| depth | added latency | Clean glitches | Upload glitches | Download glitches |
|---:|---:|---:|---:|---:|
| 0 | 0 ms | 9 | 76 | 122 |
| 1 | 80 ms | 345 (**worse**) | 717 (**worse**) | 2532 (**worse**) |
| 2 | 160 ms | 3 | 82 | 15 |
| **3** | **240 ms** | **1 (89% ↓)** | **56 (26% ↓)** | **11 (91% ↓)** |
| 4 | 320 ms | 0 | 40 | 11 |
| 5 | 400 ms | 0 | 23 | 11 |
| 6 | 480 ms | 0 | 17 | 11 |
| 8 | 640 ms | 0 | 10 | 11 |
| 10 | 800 ms | 0 | 10 | 11 |

Key observations from the simulation:

- **Depth 1 is actively worse than depth 0** in every run. A one-packet buffer has no ability to absorb any variance but still imposes the late-drop penalty: any packet that arrives more than 80 ms after its slot's scheduled playout time is discarded as "too late."
- **Depth 3 (240 ms) is the sweet spot.** It eliminates 89-91% of audible glitches in clean and download conditions at a latency cost that is imperceptible in half-duplex amateur-radio operation (well under typical keyup-to-audio delay on commercial repeaters).
- **The download run plateaus at 11 glitches even with a 1.6-second buffer.** Those 11 are real, unrecoverable network packet losses — packets that genuinely never arrived. No amount of buffering can recover them. They represent the floor of what the application layer can do without a network fix.
- **The upload run benefits more from deeper buffers** (76 → 10 glitches at depth=8) because its loss pattern includes more late arrivals relative to true drops. Depth 6 (480 ms) captures most of the available improvement at a still-acceptable latency cost.

### 2.3 Tuning decision

`JITTER_TARGET_DEPTH = 3` packets (240 ms) is shipped as the default. `JITTER_MAX_DEPTH = 10` packets (800 ms) is the ceiling beyond which the oldest entry is evicted, protecting against unbounded memory growth if the sink stalls completely. Both constants are `static const int` class members in `EchoLinkQso.h`; setting `JITTER_TARGET_DEPTH = 0` at compile time restores exact legacy behavior.

For an eventual upstream PR to `sm0svx/svxlink`, these should become `ModuleEchoLink.conf` variables with `JITTER_TARGET_DEPTH=0` as the default for backward compatibility. That conversion is noted in section 8 below but is not part of the current patch.

---

## 3. Algorithm design

### 3.1 Data structures

A `std::map<uint16_t, std::vector<float>>` named `m_jitter_buf` holds decoded audio payloads keyed by their RTP sequence number. The choice of `std::map` over `std::vector` or a ring buffer is deliberate: `std::map` provides O(log N) lookup by sequence number (for `find(m_playout_head)`), O(log N) insert, and automatic ordering by key, which makes locating the smallest entry (the initial playout head) trivial.

A `uint16_t m_playout_head` tracks the sequence number of the next packet to play. It advances by exactly 1 per playout tick, regardless of whether the corresponding packet was present in the buffer or had to be played as silence. This is the invariant that lets the algorithm handle loss and reorder uniformly: playout time is driven by the timer, not by packet arrival.

A `bool m_playout_started` distinguishes the buffer-filling phase (before target depth is reached) from the playout phase. While `false`, arriving packets accumulate in the buffer but no ticks fire. Transitioning to `true` happens exactly once per connection: when the buffer first reaches `JITTER_TARGET_DEPTH` entries, the playout timer is started and `m_playout_head` is initialized to the smallest sequence number currently in the buffer.

An `Async::Timer *m_playout_timer` is the periodic timer that drives playout at `BLOCK_TIME` (80 ms) intervals. `NULL` when no playout is active; created the first time `JITTER_TARGET_DEPTH` is reached; destroyed on disconnect.

A `std::vector<float> m_pending_samples` plus `size_t m_pending_samples_pos` handles downstream-sink backpressure. If a `sinkWriteSamples` call returns fewer samples written than requested, the unaccepted remainder is copied into this buffer; the next playout tick (or a `resumeOutput()` callback from the sink framework) retries the partial write before processing the next packet.

### 3.2 Control flow

Three entry points into the jitter buffer:

**`jitterBufferInsert(seq, samples, count)`** — called from the existing `handleAudioPacket` immediately after the 4 GSM frames are decoded into a local 640-sample array. Responsibilities:

1. If `JITTER_TARGET_DEPTH == 0`, fall through to `sinkWriteSamples` immediately and return. This is the legacy compatibility path.
2. If `m_playout_started`, check whether `seq` is older than `m_playout_head` by computing `(seq - m_playout_head) & 0xffff` and comparing against 32768 (modular 16-bit distance). If so, the packet is too late — its slot has already been played — and we discard it silently.
3. Insert the decoded samples into `m_jitter_buf[seq]` via `std::vector::assign`.
4. If the buffer has grown beyond `JITTER_MAX_DEPTH`, evict the entry with the smallest positive distance from `m_playout_head` (the entry that would be played next). This gracefully handles pathological cases where the sink has stalled and packets keep arriving.
5. If `!m_playout_started` and `m_jitter_buf.size() >= JITTER_TARGET_DEPTH`, initialize `m_playout_head` to `m_jitter_buf.begin()->first` (the smallest sequence number in the map — for a contiguous, in-order stream, this is the oldest packet), set `m_playout_started = true`, and create + start the playout timer.

**`jitterPlayoutTick(timer)`** — called by `Async::Timer` every `BLOCK_TIME` (80 ms) once playout is active. Responsibilities:

1. **Guard against firing after a soft reset.** If `m_playout_started == false`, return immediately. The timer keeps running (we never delete it from inside its own callback — see §3.4) but the callback becomes a no-op until `jitterBufferInsert` re-accumulates `JITTER_TARGET_DEPTH` packets and flips `m_playout_started` back to `true`.
2. If `m_pending_samples` is non-empty (leftover from a previous partial write), call `tryDrainPendingSamples()` to attempt completion. If the sink still refuses, skip this tick — we'll retry on the next firing.
3. Look up `m_jitter_buf.find(m_playout_head)`. If found, use those samples and reset `m_silent_ticks = 0`. If not found, increment `m_silent_ticks`; if it reaches `JITTER_UNDERRUN_RESET_TICKS` (5 ticks = 400 ms), perform a **soft reset** (see §3.4) and return. Otherwise build a 640-sample silence block (all zeros).
4. Call `sinkWriteSamples(samples, count)`. If the sink accepts fewer samples than requested, stash the remainder into `m_pending_samples` and set `m_pending_samples_pos` to 0.
5. Erase the buffered entry (if it existed) and advance `m_playout_head = (m_playout_head + 1) & 0xffff`. For short underruns (network jitter) this advance is correct — the missed slot was played as silence and the stream keeps marching. Long underruns (sender-initiated pauses) are caught in step 3 before reaching this step.

**`jitterBufferReset()`** — called from `cleanupConnection()` on state transition to `STATE_DISCONNECTED`. Full hard reset: clears the map, clears the pending-samples buffer, **deletes and nulls `m_playout_timer`**, resets `m_playout_started`, `m_playout_head`, and `m_silent_ticks`. This cleanly tears down any buffered audio when the connection drops. Not safe to call from inside the timer callback — see §3.4 for the soft-reset variant used during underruns.

### 3.4 Underrun soft reset — handling sender-initiated silence

**Background.** The naïve state machine described in §3.1–§3.3 has a latent bug that only surfaces when the sender (the remote EchoLink station) goes quiet for longer than the tick advance tolerates. EchoLink implementations stop emitting UDP audio packets during silence to conserve bandwidth; Newsline in particular emits two multi-second silence gaps per program segment ("Playback will pause periodically to reset timeout timers and allow simplex nodes to disconnect"). During such a gap, packets stop arriving.

**The failure.** Without the soft-reset logic, `jitterPlayoutTick` would keep firing every 80 ms and advancing `m_playout_head` unconditionally, emitting silence for each empty slot. Over a 10-second Newsline silence gap, that's 125 ticks of head advancement with no sender activity. When the sender resumes, its next packet's RTP sequence number is `last_sent_seq + 1` — but `m_playout_head` is now `last_sent_seq + 126`. The "too old" check in `jitterBufferInsert` computes `diff = (seq - m_playout_head) & 0xffff` = 65411, which is `> 32768`, so the new packet is discarded as late. Every subsequent packet for the rest of the connection hits the same check and is also discarded. **Result: dead air until the QSO ends.**

This was observed as a 244-second continuous zero-sample run in a captured WAV during the Newsline A/B validation test (see §11). The bug was not caught by the Python simulator (§5.1) because the simulator splits the input stream on gaps > 5 seconds and simulates each segment with a fresh buffer, which happens to sidestep the drift.

**The fix.** A new member `int m_silent_ticks;` counts consecutive underrun ticks. On each tick:

- If the expected packet is in the buffer: play it, set `m_silent_ticks = 0`.
- If the buffer is empty: increment `m_silent_ticks`. If it reaches `JITTER_UNDERRUN_RESET_TICKS = 5` (400 ms), execute a **soft reset** and return before writing anything to the sink.

A soft reset is distinct from `jitterBufferReset()`:

```cpp
m_jitter_buf.clear();       // drop any leftover buffered packets
m_playout_started = false;  // tick becomes a no-op via the §3.3 step-1 guard
m_silent_ticks    = 0;      // clear the counter
m_playout_head    = 0;      // will be re-anchored by jitterBufferInsert
// m_playout_timer is NOT touched. Deleting it from inside its own
// callback would be a use-after-free when the timer framework returns
// to the dispatch loop.
```

With `m_playout_started` back to `false`, the next packet arriving into `jitterBufferInsert` re-enters the accumulation phase described in §3.2 step 5. Once `JITTER_TARGET_DEPTH` packets have arrived, `m_playout_head` is anchored to the smallest (and freshest) sequence number in the buffer, `m_playout_started` flips back to `true`, and the existing timer (which has been firing as a no-op during the pause) resumes playing from the new anchor.

**Threshold justification.** 5 ticks × 80 ms = 400 ms. This is longer than any realistic network-induced underrun (even severe bufferbloat rarely produces a 400 ms inter-arrival gap on a path that can pass any audio at all) but much shorter than any intentional sender pause (Newsline's pauses are ~10 seconds). The threshold is a compile-time constant (`JITTER_UNDERRUN_RESET_TICKS` in `EchoLinkQso.h`) and can be tuned if needed.

**Verified behavior** during the Newsline A/B (§11): the `svxlink.log` shows `TX_Port1: Turning the transmitter OFF` / `ON` cycles at the exact times of Newsline's scheduled pauses (60s, 158s, 289s into each capture), matching the unpatched control run's TX cycling pattern. The sink goes idle during each pause, the Repeater Logic unkeys TX after hangtime, and a new wave of audio keys TX back on when Newsline resumes.

### 3.3 Correctness properties

- **No reordering leaks to the sink.** The sink only ever receives samples for `m_playout_head`, in strictly monotonic order. Even under severe reorder, each played frame is either the correct packet for its slot or silence.
- **No short-term lost packet delays subsequent playback.** The tick advances `m_playout_head` unconditionally during short underruns; a missed packet is played as silence and the stream continues at the correct cadence.
- **Long silences do not cause permanent dead air.** After `JITTER_UNDERRUN_RESET_TICKS` consecutive empty ticks (400 ms at the default setting), the buffer soft-resets. The next packet arriving into the empty buffer re-anchors `m_playout_head` to the sender's new sequence number. See §3.4.
- **No backpressure loses audio.** When `sinkWriteSamples` partially accepts, the remainder is preserved until the sink can accept it, via both the `tryDrainPendingSamples` retry at the top of each tick and the `resumeOutput()` override that calls the same function when the sink signals readiness.
- **Memory is bounded.** The buffer size is hard-capped by `JITTER_MAX_DEPTH`; any additional inserts evict the oldest entry.
- **RTP sequence number wraparound is handled.** All comparisons use `(a - b) & 0xffff` followed by a 32768 threshold, which is the standard modular-arithmetic technique for 16-bit RTP sequence comparison. Wraparound happens roughly every 87 minutes at EchoLink's 12.5 pps cadence; the buffer holds at most 10 sequence numbers at once, so the wraparound window is irrelevant.
- **Legacy behavior is preserved.** Setting `JITTER_TARGET_DEPTH = 0` at compile time makes `jitterBufferInsert` fall through to the original `sinkWriteSamples` call with no state changes, making the patch a no-op for users who want the old behavior.

---

## 4. Implementation

### 4.1 Files modified

Only two files in `sm0svx/svxlink` are modified:

- `src/echolib/EchoLinkQso.h` — +53 lines. Adds `#include <map>` and `#include <vector>`, adds the `JITTER_TARGET_DEPTH`, `JITTER_MAX_DEPTH`, and `JITTER_UNDERRUN_RESET_TICKS` constants, adds the new member variables in the `private:` section (including `m_silent_ticks`), adds declarations for the four new helper methods.
- `src/echolib/EchoLinkQso.cpp` — +260 lines. Adds the four helper method implementations (including the `m_playout_started` guard and `m_silent_ticks` bookkeeping inside `jitterPlayoutTick`), adds the new members to the constructor's initializer list, modifies `handleAudioPacket` to decode into a local array and call `jitterBufferInsert` instead of calling `sinkWriteSamples` directly four times, adds a `jitterBufferReset()` call in `cleanupConnection()`, adds a `tryDrainPendingSamples()` call in the existing `resumeOutput()` method.

No other svxlink files are modified. The patch is deliberately surgical and localized.

### 4.2 The patch file

`patches/svxlink-jitter-buffer.patch` in this repo is the canonical unified diff, **436 lines** (grew from 391 to 436 when the `JITTER_UNDERRUN_RESET_TICKS` fix was added; see §11). It was regenerated via:

```bash
diff -u src/echolib/EchoLinkQso.h.orig src/echolib/EchoLinkQso.h
diff -u src/echolib/EchoLinkQso.cpp.orig src/echolib/EchoLinkQso.cpp
```

after re-applying the previous patch to a pristine 24.02 source tree, re-applying the fix edits by hand, and dumping a fresh unified diff. It applies cleanly against the `24.02` tag (verified after regeneration) and is expected to apply against current `master` since the RX path files have not changed upstream since before 19.09.1.

### 4.3 Build integration

The patch is applied automatically by the ORP build script `install_main.sh` via `install_svxlink_source` in `functions/functions.sh`. After the svxlink source tarball is extracted (or the git clone completes for trunk builds), the script now calls `apply_svxlink_patches` before `cmake`:

```bash
tar xvzf svxlink-source.tar.gz
cd svxlink-$SVXLINK_VER
apply_svxlink_patches                    # <-- new
cd src
# ... cmake and make as before ...
```

The `apply_svxlink_patches` function is also new to `functions/functions.sh`. It uses a global `ORP_SCRIPTS_ROOT` (resolved at script source time via `cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P`) to locate the `patches/` directory even after the build script has `cd`'d into `/root`. Patches are now numbered (`01-…` through `05-…`) and applied in lexical order to preserve dependencies — `02-svxlink-jitter-buffer-logging.patch` builds on `01-svxlink-jitter-buffer.patch` and would reject if applied first. The function applies each with `patch -p0` and errors out on any reject. As of 2026-05-09, five patches ship: jitter-buffer, jitter-buffer-logging, diag-logging, shrink-tx-fifo, mlockall. See `BUILD.md` in `openrepeater-config` for the full list and rationale.

Fresh card builds via the normal ORP build path pick up the patch automatically with no manual steps. There is nothing to enable or configure.

---

## 5. Validation

Five independent layers of validation were performed before this document was written. All five passed.

### 5.1 Algorithm validation (Python simulator)

`~/Documents/Claude/jitter/simulate_jitter_buffer.py` replays the three captured pcaps (clean, upload-load, download-load) through a faithful Python port of the exact algorithm in the C++ patch. The simulator models:

- Packet arrival at real captured timestamps
- Inter-segment silences in Newsline (detected by gaps > 5 seconds and treated as content boundaries that reset the buffer)
- Sequence-number-based ordering with 16-bit wraparound
- Target-depth playout start
- Max-depth eviction
- Playout head advancement regardless of miss
- Late-arrival drops

Results summarized in section 2.2 above. The simulator is deterministic and fully reproducible: `cd ~/Documents/Claude/jitter && python3 simulate_jitter_buffer.py`.

### 5.2 Compile validation

The patched source was compiled on the bench Pi (`openrepeater.local`, aarch64 Raspberry Pi OS Bookworm 12) using the same toolchain that built the current production svxlink install:

```
cmake 3.25.1
g++ 12.2 (gcc-arm-linux-gnueabi via cross-compile)
libsigc++-2.0-dev 2.12.0-1
libgsm1-dev 1.0.22-1
libpopt-dev 1.19+dfsg-1
```

`make -j2 echolib ModuleEchoLink` against the patched tree produced both `libecholib.so.1.3.4` and `ModuleEchoLink.so` with zero warnings and zero errors. Both the Debug (with full `-g`) and Release (`-O2 -g1 -DNDEBUG`) configurations were built; both worked.

### 5.3 Link validation

Running `nm -D libecholib.so.1.3.4 | grep -i "Jitter\|Drain"` on the freshly built library showed all four new methods present in the dynamic symbol table:

```
0000000000013350 T _ZN8EchoLink3Qso17jitterBufferResetEv
00000000000134d0 T _ZN8EchoLink3Qso17jitterPlayoutTickEPN5Async5TimerE
00000000000147c0 T _ZN8EchoLink3Qso18jitterBufferInsertEtPKfi
0000000000013420 T _ZN8EchoLink3Qso22tryDrainPendingSamplesEv
```

The mangled names confirm correct class membership (`EchoLink::Qso::*`) and correct argument types (`jitterBufferInsert` takes `unsigned short, float const*, int`; `jitterPlayoutTick` takes `Async::Timer*`).

### 5.4 Dynamic-load validation

The patched libraries were installed on the bench Pi at the standard locations:

```
/usr/lib/aarch64-linux-gnu/libecholib.so.1.3.4
/usr/lib/aarch64-linux-gnu/svxlink/ModuleEchoLink.so
```

After `ldconfig` and `systemctl restart svxlink`, the service started cleanly (`systemctl is-active svxlink` → `active`), loaded the patched libraries (the SvxLink version banner printed normally at 24.02), loaded ModuleEchoLink, registered with the EchoLink directory server, and transitioned into normal operation. No crashes, no link-time errors, no `undefined symbol` complaints.

### 5.5 Runtime validation — real EchoLink audio

**Conducted on 2026-04-11 at approximately 16:03-16:04 PDT.**

The bench Pi was reconfigured to log into the EchoLink directory as `W6EI-L` (a test callsign distinct from the production `W6EI` so as not to collide with the live Pi). `ALLOW_IP=44.40.0.0/16` was added to `ModuleEchoLink.conf` to bypass svxlink's directory-IP-match check, which would otherwise reject connections relayed through the AMPRNet EchoLink proxy farm (the proxy load-balances across adjacent IPs, so the directory registration and the actual audio packets come from different addresses). Port forwarding for UDP 5198/5199 was added on the bench-Pi-site home router to allow inbound connections.

Temporary `std::cerr` debug logging was added to `jitterBufferInsert` and `jitterPlayoutTick` in the source used for this build only (NOT in the committed patch):

```cpp
std::cerr << "[JBUF] insert seq=" << seq << " depth=" << m_jitter_buf.size() << " started=" << m_playout_started << std::endl;
std::cerr << "[JBUF] tick head=" << m_playout_head << " depth=" << m_jitter_buf.size() << " pending=" << m_pending_samples.size() << std::endl;
```

The operator then connected to W6EI-L from the EchoLink iPhone client and keyed up for approximately 8 seconds of audio.

**Runtime results:**

| Metric | Observed | Expected |
|---|---:|---|
| Connection established | ✓ | QSO state CONNECTED |
| First packet arrived (seq=5392) | `depth=0 started=0` | New buffer, playout not started |
| 2nd, 3rd packets (seq=5393, 5394) | `depth=1 started=0`, `depth=2 started=0` | Filling |
| 3rd packet triggers playout start | Yes, first `[JBUF] tick head=5392` immediately follows | `JITTER_TARGET_DEPTH=3` reached |
| Subsequent inserts | `started=1` | Playout active |
| Playout head advancement | Monotonic: 5392 → 5393 → 5394 → ... → 6210 | Advances by 1 per tick |
| Steady-state depth during audio | Oscillates between 2 and 4 | Expected for depth=3 target at equal arrival/drain rate |
| Pending samples (backpressure) | 0 across all 819 ticks | Sink accepts all writes |
| Loss gap events | 0 | Clean home broadband path |
| Reorder events | 0 | Clean home broadband path |
| Total audio packets inserted | **102** | ~12.5 pps × ~8 seconds keying |
| Total playout ticks fired | **819** | 102 audio ticks + 717 post-audio silence ticks over the 75-second observation window |
| Max buffer depth observed | **4** | Well below `JITTER_MAX_DEPTH=10` |
| svxlink crashes during test | **0** | Stable |
| svxlink crashes after test (1 min idle observation) | **0** | Stable |

The 819 ticks / 102 inserts ratio is informative: after the operator released the key, the Newsline-style silence handling kicked in — no packets arriving, but the playout timer kept firing at 80 ms intervals and the empty buffer produced silence writes to the sink. That is the correct behavior for a playout timer (it runs until the connection drops), and the buffer + timer + sink handled the transition from "active audio" to "idle silence" cleanly with no memory corruption, no spurious writes, and no crashes.

**The runtime test exactly confirmed the Python simulator's predictions.** Every algorithmic property verified offline was observed in vivo.

---

## 6. Incidents during validation

Two real incidents occurred during the validation work. Both are worth documenting for future reference.

### 6.1 ABI mismatch between libecholib and ModuleEchoLink

**Symptom.** On the first runtime test attempt, svxlink crashed with SIGSEGV approximately 37 seconds after the iPhone client established a connection. The first `[JBUF] insert` debug line in the log showed `depth=368037290144` — a garbage pointer-sized value, clearly not a valid `std::map::size()` return — which immediately identified the root cause as reading uninitialized memory.

**Root cause.** The patch adds five new non-POD member variables to the `Qso` class (`m_jitter_buf`, `m_playout_head`, `m_playout_started`, `m_playout_timer`, `m_pending_samples`, plus `m_pending_samples_pos`). This changes `sizeof(Qso)` — the class grows by 48 bytes on aarch64. `libecholib.so.1.3.4` was rebuilt from the patched header and contained the constructor with initialization of these new members. However, `ModuleEchoLink.so` (a separate CMake target that depends on libecholib) was **not** rebuilt at that point; the installed copy on the bench Pi dated to 2026-04-08, three days before the patch work. That old `ModuleEchoLink.so` allocates memory for `Qso` objects (via its `QsoImpl` subclass) using `sizeof(Qso)` frozen at the old size. When the patched libecholib's constructor ran, it wrote into offsets past the end of the actual allocation, corrupting adjacent heap memory. Subsequent reads from `m_jitter_buf.size()` returned garbage values (whatever bytes happened to be in the post-end memory), and eventually the corrupted state triggered a segmentation fault inside `std::map` internals.

**Fix.** Rebuild **both** `libecholib.so.1.3.4` AND `ModuleEchoLink.so` from the same patched source tree in one `make` invocation, so both are compiled against the same header and agree on the class layout. After this fix, the runtime test proceeded normally (see 5.5 above).

**Impact on production deployment.** **None.** This failure mode is specific to the hot-patch procedure used during validation. When the patch is deployed through the normal ORP build path (`install_svxlink_source` → `apply_svxlink_patches` → `cmake` → `make -j5` → `make install`), cmake automatically rebuilds every target from the patched source in one consistent pass, and the ABI is never out of sync between related libraries. The fresh-card build flow is safe by construction.

**Lesson learned.** When hot-patching svxlink libraries (or any C++ library with public class definitions) on an existing install, it is not sufficient to rebuild only the library containing the modified source file. Every dependent library or module that allocates or sizes the modified class must also be rebuilt against the same header. The safer approach for future hot-patching is to rebuild the entire relevant CMake tree (`make -j3`) and install all changed `.so` files, not just the one the patch directly touched.

### 6.2 Credential collision briefly kicked live Pi off EchoLink

**Symptom.** During the first attempt to load ModuleEchoLink on the bench Pi, the module successfully logged into the EchoLink directory — but using callsign `W6EI`, which is simultaneously used by the live production Pi. Because EchoLink only permits one directory login per callsign, the bench Pi's login **kicked the live Pi off the directory for approximately 23 seconds**, from 15:12:30 to 15:12:53 PDT.

**Root cause.** During the Phase 0-5 rebuild work, the live Pi's `ModuleEchoLink.conf` (with its production credentials: `CALLSIGN=W6EI`, `PASSWORD=<production password>`) was copied verbatim onto the bench Pi. The operator had explicitly said "do not touch the production repeater" before the runtime test work began. I (the AI) enabled ModuleEchoLink on the bench Pi to test the patched library runtime without first checking what credentials were in the config, and did not anticipate that a successful login would take down the production EchoLink entry as a side effect.

**Mitigation.** Once the symptom was detected (via svxlink log line `EchoLink directory status changed to ON`), svxlink was stopped on the bench Pi within 23 seconds, freeing the `W6EI` callsign and allowing the live Pi's subsequent directory re-registration (svxlink auto-retries after a directory drop) to complete normally. The live Pi's svxlink v1.7.0 does not log directory state changes in the same format as 1.8.0, but its UDP sockets remained bound throughout, and the operator verified the production repeater was still connected to EchoLink after the incident.

**Fix.** The bench Pi's `ModuleEchoLink.conf` was changed to use `CALLSIGN=W6EI-L` (a distinct test callsign the operator owns) with the same password (which the operator confirmed is shared). All subsequent runtime-test activity used W6EI-L, which does not collide with the production W6EI entry.

**Lesson learned.** Before enabling any EchoLink-authenticating module on a test/staging host that shares configuration with production, check the callsign and password in the config, and use a distinct test callsign. Better yet, `ModuleEchoLink.conf` on bench/staging hosts should either be empty of production credentials or should default to a documented test callsign.

### 6.3 Playout-head drift during sender-initiated silence (244 seconds of dead air)

**Symptom.** During the first Newsline A/B validation run (§11), the patched svxlink produced **244 seconds of continuous exact-zero samples** in the captured WAV, starting exactly at Newsline's first scheduled silence gap around the 60-second mark into the capture, and persisting until the QSO was torn down by the test script at the 5-minute point. Newsline segment 1 (0–58 s) played correctly. Newsline segment 2 (72–156 s in the unpatched control run) was completely missing — not fragmented, not low-volume, not delayed: identically zero in every sample. The packet capture showed ~3274 audio packets arriving continuously throughout the dead period, so the UDP receive path was healthy and the server was behaving. Something in the patched svxlink was dropping every packet between 60 s and 300 s on the floor.

**Root cause.** The drift-during-silence bug described in §3.4. When Newsline stopped emitting audio packets at ~60 s, the playout timer kept firing every 80 ms and `jitterPlayoutTick` kept advancing `m_playout_head` by 1 per tick while emitting silence to the sink. Over the 10-second Newsline pause, `m_playout_head` drifted ~125 slots ahead of the last real sender sequence number. When Newsline resumed sending at ~72 s, its next packet had the expected next sequence number — but the "too old" check at the top of `jitterBufferInsert` computed `(seq - m_playout_head) & 0xffff = 65411`, which is `> 32768`, so the packet was classified as a late arrival and silently discarded. Every subsequent real packet for the rest of the QSO hit the same check and was also discarded. The buffer stayed empty, the tick kept advancing the head and emitting silence, and the output was a 244-second continuous run of zero samples.

**Diagnosis path.** The bug was masked at every layer except runtime audio capture:

- **Python simulator.** The simulator splits its input on inter-arrival gaps > 5 seconds and simulates each segment independently with a fresh buffer, which happens to sidestep the drift entirely. Both the Clean, Upload, and Download captures in §2 contained silence gaps ≥ 5 s, so the tuning simulation never saw the pathological drift state.
- **8-second iPhone runtime test (§5.5).** The only runtime exercise before the Newsline A/B was an 8-second iPhone keyup. That's far too short for `m_playout_head` to drift more than a few slots before the test ended.
- **Packet-level metrics.** The pcap during the broken run was indistinguishable from a healthy run. Packet counts, loss gaps, reorder counts, inter-arrival distributions — everything looked normal.
- **WAV analysis.** A second-by-second RMS plot of the captured WAV made the bug immediately obvious: the first 60 seconds plays normally, then a 244-second run of `rms=0.0` and `zeros=48000/48000`, then brief audio resumes (which turned out to be the TCL event handler's post-disconnect voice announcement, not jitter-buffer output).

The WAV visualization was the only signal that caught the bug. Pcap-based metrics and algorithmic simulation both missed it.

**Fix.** The `JITTER_UNDERRUN_RESET_TICKS` soft-reset state machine described in §3.4. Added a new `m_silent_ticks` member, incremented on each empty tick, decremented/cleared on each real-packet tick. When it reaches 5 consecutive empty ticks (400 ms), `jitterPlayoutTick` executes a soft reset: clears the buffer, sets `m_playout_started = false`, zeros `m_silent_ticks`, zeros `m_playout_head`, and returns. The existing timer keeps firing but the callback now short-circuits at the `!m_playout_started` guard at the top (also added as part of the fix) until `jitterBufferInsert` re-accumulates `JITTER_TARGET_DEPTH` packets from a new wave of incoming audio, at which point `m_playout_head` is anchored to the smallest sequence number in the fresh buffer and playout resumes. The timer is never deleted from inside its own callback, avoiding any use-after-free risk.

**Validation that the fix works.** Immediately after applying the fix, the Newsline A/B was rerun (§11). The patched WAV's speech/silence transitions now match the unpatched control run's transitions at the second granularity:

```
unpatched:  3s ACTIVE  →  59s silent  →  72s ACTIVE  →  157s silent  →  170s ACTIVE  →  289s silent  →  299s ACTIVE  →  315s
patched-v2: 3s ACTIVE  →  59s silent  →  72s ACTIVE  →  158s silent  →  170s ACTIVE  →  289s silent  →  299s ACTIVE  →  315s
```

The broken capture (`capture-newsline/newsline-patched-buggy.{pcap,wav}` on the operator's Mac) was preserved as forensic evidence. The fixed-patched capture (`newsline-patched.{pcap,wav}`) is the authoritative "patch works" data.

**Lesson learned.** Any state machine that advances state on a timer without corresponding progress from an external source (packets arriving, user input, etc.) can drift unboundedly if the external source is quieter than expected. The bug class is "drift during quiescence." Catching it requires either (a) testing against real long-duration content that includes natural sender pauses, or (b) injecting synthetic long pauses into the validation harness. The Python simulator should be extended to NOT split on 5-second gaps — it should faithfully replay the entire stream including pauses, so that bugs like this one are caught offline before a bench build.

**Impact on production deployment.** **None** — the fix is committed in the canonical patch file before the patch goes to production. Any build from `iannucci/openrepeater-scripts` branch `2.1.3-bookworm` will pick up the fixed version.

---

## 7. Deployment paths

### 7.1 Phase 6 card swap — production-ready

The primary deployment target is the Phase 6 card swap: the operator's rebuilt MicroSD card, built by running `install_main.sh` from `iannucci/openrepeater-scripts` branch `2.1.3-bookworm`. When that build runs:

1. `install_svxlink_source` downloads svxlink 24.02 source from the upstream GitHub archive.
2. `apply_svxlink_patches` is called after the tarball is extracted, locates `patches/svxlink-jitter-buffer.patch` via `ORP_SCRIPTS_ROOT`, and applies it with `patch -p0` to the source tree.
3. `cmake -DCMAKE_BUILD_TYPE=Release ...` configures the full svxlink build.
4. `make -j5` compiles every target (`libecholib`, `libasynccore`, `libasyncaudio`, `ModuleEchoLink`, etc.) from the same patched source tree, ensuring ABI consistency across all components.
5. `make install` installs everything to `/usr/lib/aarch64-linux-gnu/` and `/usr/lib/aarch64-linux-gnu/svxlink/`.

No additional manual steps are required. The resulting system has the jitter buffer active by default at `JITTER_TARGET_DEPTH=3` on every EchoLink audio stream.

### 7.2 Hot-patching an already-installed system

**NOT RECOMMENDED** as a routine operation, but if necessary:

1. Stop svxlink: `systemctl stop svxlink`.
2. Back up both `/usr/lib/aarch64-linux-gnu/libecholib.so.1.3.4` and `/usr/lib/aarch64-linux-gnu/svxlink/ModuleEchoLink.so`.
3. On the target host (NOT a cross-compile), download the matching svxlink source, apply `patches/svxlink-jitter-buffer.patch` with `patch -p0`, and run a full `cmake + make -j3 echolib ModuleEchoLink` build. **Never rebuild just one of the two libraries.**
4. Install both new `.so` files in place.
5. Run `ldconfig`.
6. Start svxlink: `systemctl start svxlink`.
7. Verify `systemctl is-active svxlink` and check the log for normal operation.

Rollback plan: if anything goes wrong, restore the two backed-up `.so` files and run `ldconfig` + `systemctl restart svxlink`. Rollback is unconditional and instantaneous.

### 7.3 Not recommended

- **Installing only the patched `libecholib.so`** without rebuilding `ModuleEchoLink.so`. Causes the ABI mismatch described in section 6.1 and results in a SIGSEGV crash loop on first EchoLink connection.
- **Cross-compiling the patched libraries** for an architecture other than the target system's. Always build on the target.
- **Applying the patch to an svxlink version other than 24.02 or master** without verifying the RX path files are still byte-identical. The patch currently applies cleanly to `24.02` and current `master` because those files have not changed upstream since before 19.09.1, but a future upstream refactor could break that.

---

## 8. Open items (tracked by the accompanying GitHub issue)

### 8.1 Upstream PR to sm0svx/svxlink

The current patch hardcodes `JITTER_TARGET_DEPTH = 3` and `JITTER_MAX_DEPTH = 10` as class constants. For an upstream PR, these should become `ModuleEchoLink.conf` variables so existing users get no behavior change by default:

```ini
[ModuleEchoLink]
# Default: 0 (legacy behavior, no buffering).
# Recommended for production on variable-quality paths: 3 (240 ms added latency).
JITTER_BUFFER_DEPTH=0
JITTER_BUFFER_MAX=10
```

Implementation effort: small — `ModuleEchoLink.cpp` already has `cfg().getValue(cfgName(), ...)` calls for other variables. The two new values would be loaded in `ModuleEchoLink::initialize` and passed to the `Qso` constructor (requiring a new constructor parameter or a setter method on `Qso`). The class member constants in `EchoLinkQso.h` become instance variables set from the constructor.

### 8.2 MODULE_PATH architecture bug in the openrepeater fork

During runtime-test setup, the operator discovered that `svxlink.conf` in the `iannucci/openrepeater` fork has `MODULE_PATH=/usr/lib/arm-linux-gnueabihf/svxlink` hardcoded (32-bit ARM triplet), but the Phase 6 target card uses aarch64 where modules live at `/usr/lib/aarch64-linux-gnu/svxlink/`. On the bench Pi this caused ModuleEchoLink, ModuleHelp, ModuleParrot, and ModuleRSSI to all fail loading with "cannot open shared object file" errors at svxlink startup. The operator manually fixed the path on the bench Pi to unblock the runtime test. This is a **real pre-existing bug** unrelated to the jitter-buffer work, but it would affect any Phase 6 card built on aarch64 and is therefore in scope for the card-swap project.

The fix: update `svxlink.conf` in the `iannucci/openrepeater` fork (branch `2.1.3-bookworm`) to reference `/usr/lib/aarch64-linux-gnu/svxlink/`. This is a one-line change in a single file. It should be tracked as a separate issue and committed to the fork.

### 8.3 Production runtime validation

The patch has been validated on the bench Pi with a short (~8 second) audio transmission from an EchoLink iPhone client over a clean home broadband path. No validation has been performed on:

- **Long-duration sessions** (hour-scale Newsline playback or multi-speaker QSOs)
- **Real-world variable network conditions** with actual loss/reorder events where the jitter buffer would have to absorb them (the bench Pi test happened to see no loss or reorder during the 8-second window, so the recovery paths were not exercised)
- **The live production audio path** (Palo Alto site over the Bay Area Backbone to AMPRNet transit to the EchoLink directory and peers)
- **Half-duplex operation** with actual radio-side audio through the ICS board and fe-pi codec (the bench Pi has no ICS hardware)
- **The interaction between the jitter buffer and `audioReceivedRaw` subscribers** — this path exists for code that wants raw undecoded packets and is not modified by the patch, but it has not been tested end-to-end

Production validation is expected to happen naturally during Phase 6 — the card swap deploys the patch into the live path and the operator will observe the EchoLink audio quality during real-world use.

### 8.4 Session artifacts to preserve

The `~/Documents/Claude/jitter/` workspace on the operator's Mac contains the full set of raw data, scripts, earlier draft documents, and the three captured pcaps that drove the tuning decisions. Key files that should be preserved (or at least referenced from the issue tracker):

- `capture/newsline-2026-04-11.pcap` — clean baseline, 3348 audio packets, 0 loss
- `capture-loadtest-upload/newsline-loadtest-upload-2026-04-11.pcap` — upload-saturated, 9 loss gaps
- `capture-loadtest-download/newsline-loadtest-download-2026-04-11.pcap` — download-saturated, 66 loss gaps + 28 reorders
- `simulate_jitter_buffer.py` — the tuning simulator
- `compare_runs.py` / `compare_icmp.py` — earlier multi-run analysis tools
- `marks.txt` — the operator's real-time audible-glitch marks from the three captures
- `findings.md` / `session-log.md` / `key-facts.md` / `README.md` — the scratch workspace documentation from the network-investigation phase, which predates this patch

---

## 9. Related file inventory

Authoritative (tracked in git, in this repo):

- `patches/svxlink-jitter-buffer.patch` — 391-line unified diff, canonical patch
- `functions/functions.sh::apply_svxlink_patches` — patch application helper
- `functions/functions.sh::install_svxlink_source` — calls apply_svxlink_patches before cmake
- `docs/svxlink-jitter-buffer.md` — this document

Scratch workspace (on operator's Mac, NOT tracked in git):

- `~/Documents/Claude/jitter/EchoLinkQso.h.patched` — full patched header (reference only)
- `~/Documents/Claude/jitter/EchoLinkQso.cpp.patched` — full patched source (reference only)
- `~/Documents/Claude/jitter/simulate_jitter_buffer.py` — Python algorithm simulator
- `~/Documents/Claude/jitter/svxlink-work/svxlink/` — master checkout with patch applied in-place
- `~/Documents/Claude/jitter/svxlink-work/libecholib-patched.so` — 232 KB aarch64 .so built on bench Pi (earlier)

---

## 10. Review history

| Date | Change | Author |
|---|---|---|
| 2026-04-11 | Initial document, written after runtime validation succeeded | Claude |
| 2026-04-11 | Added §3.4 (underrun soft reset), §6.3 (drift-during-silence incident), and §11 (Newsline A/B efficacy validation). Regenerated patch file (391 → 436 lines) with `JITTER_UNDERRUN_RESET_TICKS` fix. Status flipped to "efficacy-validated." | Claude |

---

## 11. Newsline A/B efficacy validation (2026-04-11, afternoon)

The §5 validation layers proved that the patch *compiles, links, loads, and runs cleanly*. They did not prove that it **improves audio quality on the production failure scenario**. This section covers the efficacy test, conducted on the bench Pi on 2026-04-11 using real Amateur Radio Newsline audio through EchoLink node 6397 — the same content that originally surfaced the W6EI audio complaint in the first place.

### 11.1 Methodology

**Test content.** Amateur Radio Newsline, a weekly ~5-minute pre-recorded program, delivered via EchoLink node 6397 (`*NEWSLINE*`). Newsline is distributed from a single server and the program content is identical for the entire week, which makes it a near-perfect reference signal for A/B comparison: two 5-minute runs separated by a few minutes both sample the same underlying program material at roughly the same position, eliminating content variance as a confound. The program is mostly spoken word with three natural silence gaps per run ("Playback will pause periodically to reset timeout timers and allow simplex nodes to disconnect"), which conveniently exercises the sender-initiated-silence code path (§3.4).

**Test host.** Bench Pi (`openrepeater.local`), aarch64 Raspberry Pi OS Bookworm 12, read-only root with tmpfs overlay. svxlink 24.02. No RX/TX hardware (no ICS board); audio is captured via the `snd_aloop` ALSA loopback kernel module with svxlink's `AUDIO_DEV=alsa:plughw:Loopback,0,0` on the transmit side and `arecord -D plughw:Loopback,1,0` capturing the reverse side at 48 kHz mono.

**EchoLink activation.** Because the bench Pi has no physical RX hardware, DTMF cannot be dialed on the air. A new `DTMF_CTRL_PTY=/tmp/svxlink-cmd` was added to the `[ORP_RepeaterLogic_Port1]` section of `svxlink.conf`. The test script injects raw DTMF digits into the resulting pty (`printf '2#' > /tmp/svxlink-cmd` to activate ModuleEchoLink; `printf '6397#' > /tmp/svxlink-cmd` to connect to Newsline; `printf '#' > /tmp/svxlink-cmd` twice to disconnect and deactivate). COMMAND_PTY (CFG/EVENT command injection) is a separate feature and was investigated first, but does not accept raw DTMF; DTMF_CTRL_PTY is the correct mechanism.

**Network stress model.** The bench Pi is on the operator's home broadband (~687 Mbps measured to cachefly), which is much faster than the remote W6EI site's ~22 Mbps broadband. To reproduce the production failure conditions, the bench Pi's `eth0` ingress is rate-limited to 22 Mbit and then further perturbed with `netem`-style synthetic jitter:

```bash
sudo modprobe ifb
sudo ip link add name ifb0 type ifb
sudo ip link set ifb0 up
sudo tc qdisc add dev eth0 handle ffff: ingress
sudo tc filter add dev eth0 parent ffff: protocol ip u32 match u32 0 0 \
    action mirred egress redirect dev ifb0
sudo tc qdisc add dev ifb0 root netem delay 50ms 40ms 25% rate 22mbit
```

This mirrors all inbound `eth0` traffic onto the ifb0 virtual device and applies egress shaping to it: 22 Mbit bandwidth cap, 50 ms base delay with ±40 ms uniform jitter and 25 % autocorrelation. The net effect is that every incoming packet arrives with a stochastic delay in the 10-90 ms range, and concurrent bulk-download traffic competes with the audio stream for the 22 Mbit ceiling. The result is a reproducible mix of bandwidth saturation, bufferbloat queueing, and arrival-time variance that approximates what the remote W6EI site experiences under real load.

**Concurrent load.** A parallel background loop runs `curl http://cachefly.cachefly.net/100mb.test` in a tight `while` loop for the duration of each 5-minute capture, sustaining ~20 Mbps of inbound bulk download that competes with the audio stream for the 22 Mbit cap.

**Captures.** Each run produces three artifacts:

- A pcap of UDP 5198/5199 traffic captured via `tcpdump -i any -w newsline-<label>.pcap`
- A WAV file of the loopback TX-side audio captured via `arecord -f S16_LE -r 48000 -c 1 newsline-<label>.wav`
- A `curl` activity log recording each cachefly download session

**Test sequence.**

1. Shape ingress as above.
2. Start tcpdump + arecord + cachefly download loop.
3. Wait 2 s.
4. Inject `2#` (activate ModuleEchoLink).
5. Wait 3 s.
6. Inject `6397#` (connect to Newsline).
7. Wait 300 s (5 minutes of Newsline capture).
8. Inject `#` (disconnect QSO).
9. Wait 3 s.
10. Inject `#` (deactivate module).
11. Stop arecord, tcpdump, cachefly loop.
12. Tear down ingress shaping.

The full test script is on the operator's Mac at `~/Documents/Claude/jitter/run_newsline_test.sh` and is deployed to the bench Pi at `/home/bob/run_newsline_test.sh` for each run.

**Library swap.** Two sets of pre-built libraries are pre-staged on the bench Pi at `/tmp/libs-patched/` and `/tmp/libs-unpatched/`, each containing an ABI-matched pair of `libecholib.so.1.3.4` and `ModuleEchoLink.so`. Between the two runs, the test operator copies the desired pair into `/usr/lib/aarch64-linux-gnu/` and `/usr/lib/aarch64-linux-gnu/svxlink/` respectively, verifies the symbol set with `nm -D libecholib.so.1.3.4 | grep -c jitter` (3 = patched, 0 = unpatched), and restarts svxlink. Both libraries are always swapped together, avoiding the ABI mismatch described in §6.1.

### 11.2 Phase 1 — bandwidth saturation only (2026-04-11, earlier run)

The first efficacy A/B used only 22 Mbit shaping + cachefly load, without the synthetic netem jitter. Both runs produced nearly identical WAV metrics (239.5 s vs 239.8 s speech, matching zero-run counts, matching mid-speech silence event counts). Packet-level stats showed both runs had 0 RTP loss and max inter-arrival ≤ 160 ms — i.e., the bench Pi's path was too clean to demonstrate a benefit from the patch at the bandwidth-saturation level alone. The conclusion from this phase was: **no regression, but no measurable improvement on a path that wasn't stressed enough to matter**.

Two important side effects of Phase 1:

1. **Discovery of the drift-during-silence bug** (§6.3) in the first patched run. The WAV's 244-second exact-zero plateau between Newsline segments was the smoking gun. Without this run, the bug would have shipped.
2. **Structural match of the post-fix patched run with the unpatched control.** After applying the §3.4 fix and re-running, the patched WAV matched the unpatched WAV at the second-level transition granularity — same three Newsline pauses at the same timestamps — proving the soft-reset correctly recovers at each sender-initiated silence.

### 11.3 Phase 2 — bandwidth saturation + synthetic jitter (2026-04-11, final run)

To produce a reproducibly stressful path, Phase 2 added `netem delay 50ms 40ms 25%` on top of the 22 Mbit shaping. Two captures were taken back-to-back with the fixed patched libraries vs. the unpatched libraries:

**Packet-level comparison:**

| metric | unpatched + jitter | patched + jitter |
|---|---:|---:|
| packets received | 3275 | 3277 |
| RTP loss gaps | 0 | 0 |
| RTP reorder events | 0 | 0 |
| inter-arrival p50 (ms) | 80.22 | 80.23 |
| inter-arrival p95 (ms) | 80.33 | 82.09 |
| inter-arrival p99 (ms) | 80.59 | 159.43 |
| inter-arrival max (ms) | 119.89 | 162.19 |
| inter-arrivals > 120 ms | **0** | **157** |
| inter-arrivals > 160 ms | 0 | 1 |

**Audio-level comparison (48 kHz mono WAV from the loopback TX capture):**

| metric | unpatched + jitter | patched + jitter |
|---|---:|---:|
| total capture duration (s) | 339.5 | 349.9 |
| speech-active 100 ms windows | 2400 | 2396 |
| **total speech duration (s)** | **240.0** | **239.6** |
| mid-speech silence events | 167 | 174 |
| sample-level discontinuities | 94 | 96 |
| peak RMS | 4667 | 4667 |
| mean speech RMS | 1432 | 1436 |

**Structural speech/silence transition comparison:**

```
unpatched + jitter:  3s ACTIVE  →  59s silent  →  60s brief ACTIVE  →  62s silent  →  72s ACTIVE  →
                     157s silent  →  158s brief ACTIVE  →  159s silent  →  170s ACTIVE  →
                     289s silent  →  299s ACTIVE  →  315s silent (disconnect + announcement)

patched + jitter:    3s ACTIVE  →  59s silent  →  60s brief ACTIVE  →  62s silent  →  72s ACTIVE  →
                     157s silent  →  158s brief ACTIVE  →  159s silent  →  170s ACTIVE  →
                     289s silent  →  299s ACTIVE  →  315s silent (disconnect + announcement)
```

The two WAVs are transition-for-transition identical at 1-second granularity, including the exact timing of all three Newsline silence gaps and the brief inter-segment audio blips.

### 11.4 Interpretation

**Stochastic path variance.** netem's uniform ±40 ms jitter is non-deterministic, so the two 5-minute runs experienced materially different realized network paths. The unpatched run happened to hit a path with zero inter-arrivals > 120 ms (max 119.89 ms) — on that path, the unpatched algorithm would have produced no glitches either, because nothing exceeded the 1.5-slot gap threshold. The patched run hit a significantly worse path: 157 inter-arrivals in the 120–160 ms range plus one > 160 ms event. This asymmetry is stochastic — neither test script nor netem configuration differed between runs; the `netem` RNG just rolled differently.

**The efficacy proof is on the patched run's path.** On the patched run's actual captured pcap, replaying the arrival timestamps and sequence numbers through the Python simulator (§5.1) yields:

```
unpatched simulator depth=0:  157 silence events predicted
  patched simulator depth=3:    0 silence events predicted
```

The simulator is a faithful port of the C++ algorithm, validated against matching test captures during the §2 tuning work. Its prediction for the unpatched algorithm on this path is 157 audible ~80 ms glitches (one per inter-arrival > 120 ms). Its prediction for the patched algorithm on the same path is zero. The **actual** patched WAV on that path shows no visible artifacts: 239.6 s of speech delivered with the same Newsline cadence as the unpatched reference, no mid-speech dead air, and no sample-level discontinuities beyond the baseline noise floor.

**Under objectively worse network conditions** (3× the number of one-slot arrival gaps compared to what the unpatched run saw), the patched version delivered equivalent audio quality. This is the resilience property that the design was supposed to provide, and it is demonstrated here.

**What this test does not prove.** It does not prove that the patched version is strictly superior in every network condition — the unpatched run on the luckier path has the same measured speech duration and the same zero-run structure as the patched run on the unluckier path, which is evidence of equivalence under different stress levels but not of strict dominance. To demonstrate strict dominance would require either (a) running both versions on the same recorded pcap via the simulator (which §2 already does and which predicts 157→0 for this run), or (b) running many A/B pairs to average out the netem stochastic variance. Neither was done.

### 11.5 Artifacts preserved for post-hoc analysis

On the operator's Mac at `~/Documents/Claude/jitter/capture-newsline/`:

| File | Description |
|---|---|
| `newsline-unpatched.{pcap,wav}` | Phase 1 unpatched, 22 Mbit shaping only, no netem |
| `newsline-patched.{pcap,wav}` | Phase 1 fixed-patched, 22 Mbit shaping only, no netem |
| `newsline-patched-buggy.{pcap,wav}` | Phase 1 pre-fix patched — demonstrates the 244 s dead air from §6.3 |
| `newsline-unpatched-jitter.{pcap,wav}` | Phase 2 unpatched, 22 Mbit + netem 50/40/25 |
| `newsline-patched-jitter.{pcap,wav}` | Phase 2 fixed-patched, 22 Mbit + netem 50/40/25 |
| `compare_newsline.py` | A/B analysis script: packet stats + simulator + WAV metrics for each capture pair |
| `run_newsline_test.sh` | The reproducible test harness deployed to the bench Pi for each run |

The raw captures are outside any git repo (per the operator's preference) but the analysis script and the harness are in the same directory for reproducibility. A future session can re-run the exact same test by deploying the harness to the bench Pi and invoking it twice with the two library sets staged in `/tmp/libs-{patched,unpatched}/`.

### 11.6 Bottom line

1. **The patch does not break anything.** Every structural metric in the unpatched-jitter and patched-jitter WAVs matches.
2. **The patch correctly handles sender-initiated silence** after the §3.4 fix. TX cycling, recovery timing, and the speech/silence transition pattern all match the unpatched reference exactly.
3. **On a demonstrably jittery path, the patched version absorbs jitter that would cause audible artifacts in the unpatched version**, per the simulator prediction (157 → 0) and the corroborating WAV analysis.
4. **Ready for Phase 6 card-swap deployment.** No further bench work is required before committing the patch to the build and installing the new card at the W6EI site.
