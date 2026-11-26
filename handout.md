# Handout — cutting host RAM on 8 GB NVIDIA Linux (Victory)

Written 2026-11-25 at the end of the diagnostics/DXC session. Everything below is
what actually happened, measured, on this machine — not a plan restated.

---

## 1. Goal and hard rules

- **Goal:** peak host RAM from **16,809 MB → ≤12,288 MB** (diag build, same scene),
  without regressing the 8 GB / 32-lane / GE-Proton11-14 baseline, and with both
  `host.rs` shader warnings gone.
- **Never** `kill -9` / SIGKILL (repo `docs/FINDINGS.md`: NVRM storm). Always
  `timeout -s TERM 150` + confirm clean exit (no leftover `victory.exe`, GPU back to
  ~430 MiB, zero Xid). Never kill the unrelated Wires wineserver (PID 4189).
- **Max 2 game launches back to back**, then pause; press Enter to pass menus.
- **Never** cherry-pick Repo A's `prebuild.rs`, castable lists, RT stand-ins, nor
  Repo B's AMD/1024 MB snapshot/card-window changes.
- Do **not** touch `crates/victory-gpu/src/resource.rs` upload/eviction logic or
  port `pool.rs` until the numbers below say which allocator to change. (Still true.)
- Hardware baseline: RTX 3070 8 GB, vkd3d-proton 3.2.0 `VKD3D_CONFIG=descriptor_heap`,
  DXVK 3.1.1, Proton **GE-Proton11-14** (re-confirmed, do not switch).

## 2. Repo state right now (uncommitted — nothing merged, nothing pushed)

`git status` in `victory-8gb-linux`:

```
 M apps/victory/src/main.rs
 M crates/victory-gpu/src/host.rs
 M crates/victory-gpu/src/indirect.rs
 M crates/victory-gpu/src/watch.rs
 M scripts/run-linux.sh
 M scripts/setup-linux.sh
?? apps/victory/src/abort.rs
?? handout.md
```

### 2.1 `scripts/setup-linux.sh` — fresh prefixes get the vkd3d-proton DLLs

Proton's `files/lib/wine/vkd3d-proton/` has only `d3d12.dll`/`d3d12core.dll`; the
`libvkd3d-*.dll` trio lives in `files/lib/vkd3d/x86_64-windows/`. Added a copy loop
so a new prefix can create the device without the manual fix.

### 2.2 `crates/victory-gpu/src/watch.rs` — 3 bit-rotted diagnostics lines

- `:448` `if failed && !known_view && guarded` → `!view` (`known_view` is a
  function; `view` already holds `guarded && known_view(first * PAGE)`).
- `failed_asking()`: `g.clean.contains(&b)` / `g.absent.contains(&b)` →
  `contains(b)` (`clean`/`absent` are `Blocks`, which takes `usize`; `protected`,
  `viewed`, `aliased` are `BTreeSet` and keep `&b`).

`cargo build --profile diag --features diagnostics` now compiles (3 pre-existing
dead-code warnings only).

### 2.3 `apps/victory/src/abort.rs` (new) + `main.rs` — panic/abort to the log

Ported Repo A `4247385` verbatim (std-only: panic hook + CRT `SIGABRT` handler
writing to `VICTORY_LOG_FILE`, flushed and synced). **Skipped** A's
`victory-core/src/logging.rs` flush patch: our `logging.rs` is 35 lines and writes
to **stderr** only — there is no shared file writer to flush. `main.rs` gets
`mod abort;` and `abort::install();` right after `logging::init("info")`.

### 2.4 `crates/victory-gpu/src/host.rs` — the DXC fallback (the real win)

Root cause of **both** warnings, proven by the new `stage=` field:

| warning | where it actually failed |
|---|---|
| `format=45` "no pipeline to draw a depth plane from its twin" | **`CreateRootSignature(0, &ps[..])`** on Wine `d3dcompiler_47` DXBC (`stage="the root signature"`), not the PSO and not the shader |
| `0x80004005` "no host copies in the card's memory" | **`D3DCompile` itself** on `CARD_COMPARE` (`stage="the compare shader"`) |

Changes:
- new `pub(crate) fn dxc_compile(source, entry, target)` — the single DXC loader
  (`dxcompiler.dll` beside the exe), profiled by strings instead of the old
  hardcoded `cs_6_0` argument list;
- `indirect.rs`'s `dxc_compile(source)` is now a one-line call into it
  (`"main"`, `"cs_6_0"`) — no duplicate boilerplate, module-level `Dxc::*` import
  removed;
- `fn compile_either(...)` — system compiler (`*_5_1`) or DXC (`*_6_0`) for the
  same stage;
- `PlanePass::make` → tries `make_with(..., false)`, then `make_with(..., true)`
  (DXC) on refusal; per-stage `tracing::warn!(stage=…)` marks where it stopped;
- `Session::make_card_work` → `make_card_work_with(dxc)` with the same retry.

**Verified in runs 02–05:** `no pipeline to draw a depth plane` = 0,
`no host copies in the card's memory` = 0, and the card compare is live:
`host copies in the card's memory: 86 copies 823 MB … 8,371 pieces compared on the
card, 58 fetched (2.7 MB) per frame`. The two `0x80004005` lines that remain are the
*handled* refusals (one per site, followed by the DXC success).

`make_card_inflight()` (`CARD_FETCH`, `host.rs` ~4,330) still uses `D3DCompile`
cs_5_1 only. It fails silently and falls back to the old fetch path — fix it the
same way only if the in-flight fetch is wanted.

### 2.5 `scripts/run-linux.sh` — `VICTORY_BUILD_DIR`

`REL` was hardcoded to `.../release`. Now `REL=${VICTORY_BUILD_DIR:-…/release}` so
the diag profile can be run. Nothing else in the script changed.

## 3. Test harness (bring this back exactly)

Wrapper `/tmp/vgb/ramrun.sh <log> [VICTORY_X=…]…` does: exports
`PROTON_DIR=…/GE-Proton11-14-x86_64`, `VICTORY_KEYS` with the 10 Enters, runs
`timeout -s TERM 150 ./scripts/run-linux.sh --game "…/xbox-ver/game_scarlett_master.exe"`,
samples every 3 s the tree RSS (`ps` sum, excluding PID 4189 and `Wires/`), VRAM
(`nvidia-smi --query-compute-apps`), and prints `PEAK_TREE_RSS_MB`.

Build + run (fish):

```fish
cd "$HOME/Games/GTA 6/victory-8gb-linux"
set -x PROTON_DIR $HOME/.steam/root/compatibilitytools.d/GE-Proton11-14-x86_64
XWIN_ARCH=x86_64 cargo xwin build --profile diag -p victory --features diagnostics --target x86_64-pc-windows-msvc
cp -f /tmp/vgb/dxc/dxcompiler.dll /tmp/vgb/dxc/dxil.dll target/x86_64-pc-windows-msvc/diag/
set -x VICTORY_BUILD_DIR "$PWD/target/x86_64-pc-windows-msvc/diag"
/tmp/vgb/ramrun.sh /tmp/vgb/06-whatever.log VICTORY_WINDOW_KB=256
```

Logs are **ANSI-colored** — strip before grepping:
`sed -E 's/\x1b\[[0-9;]*m//g' run.log > run.plain`.

## 4. Measurements (diag build, GE-Proton11-14, 150 s)

Peak RSS is the tree sum; plateau is the mean of 3 s samples from 90–150 s (after
the world transition); draws/frame at the end says how far the run actually got.

| # | config | peak RSS | plateau | peak VRAM | host textures | windows out of buffers | host copies | card-shared host mem | draws/frame | warnings |
|---|---|---|---|---|---|---|---|---|---|---|
| 01 | diag baseline | 16,809 | 15,479 | 2,482 | 17,017 / 2,596 MB | 2,048 MB (477) | 3,911 / 2,913 MB | 3,572 MB | ~1,027 | **both** |
| 02 | + DXC fallback | **15,322** | **13,874** | 3,262 | 16,108 / 2,577 MB | 2,144 MB (498) | 3,920 / 3,008 MB | 3,712 MB | 237 | none |
| 03 | + `WINDOW_KB=256` `TAILS=1` | 15,064 | 13,878 | 3,537 | 13,151 / 2,580 MB | 1,162 MB (2666) | 6,136 / 2,031 MB | 3,047 MB | 108 | none |
| 04 | + `DROP_MIPS=3` `SNAPSHOTS=64` | 16,268 | 14,491 | 2,984 | 14,790 / 2,423 MB | 1,687 MB (3354) | 6,781 / 2,551 MB | 3,536 MB | 949 | none |
| 05 | 03 + `TEXTURE_BUDGET_MB=1024` | 16,800 | 15,082 | 2,988 | 9,351 / 2,033 MB | 1,877 MB | 7,210 / 2,746 MB | 3,892 MB | 788 | none |

Also from the logs:

- **CPU compare** (sum of the last dump's `compared …` lines): 01 **3,625 MB/frame**,
  max single range 94 MB → 02 **48 MB/frame**, max 2.2 MB. ~75× less; the card
  compare now does the work.
- **`--profile diag` breakdown exists** (this was the blocker): `memory: … private
  (… in memory)`, `host textures:`, `memory, more:` (twins, own blocks ≥32 MB),
  `host copies in the card's memory`, `memory map (… regions)` by kind.
- Own blocks ≥32 MB: 01 `401, 174, 90, 90, 64, 50, 36 MB` → 02+ `401, 64 MB`.
- Peak VRAM stayed ≤3.6 GB of an 8 GB card; no Xid, no `NV_ERR_NO_MEMORY` in any run.

### 4.1 Honest reading of the table

- **The DXC fix is real and large**: −1,605 MB on the plateau, −1,487 MB peak,
  CPU compare −75×, and it is what makes the card compare (and therefore the depth
  twin) work at all. Runs 01 and 02 are the two that started with an identical
  code path.
- **The env knobs are inside the noise.** `WINDOW_KB=256 + TAILS=1` cuts the window
  blocks (2,048 → 1,162 MB, 477 → 2,666 windows) but the plateau does not move
  (13,874 → 13,878).
- **`DROP_MIPS=3` + `SNAPSHOTS_MB=64` is a net loss** (+613 MB plateau): textures
  −157 MB, but host copies **+520 MB** and windows **+525 MB** — more, smaller
  textures mean more windows and more copies.
- **`TEXTURE_BUDGET_MB=1024` is a net loss too** (+1,204 MB): host textures
  −547 MB, windows +715 MB, host copies +715 MB, card-shared +845 MB. Refused
  uploads (`passes that made none for lack of room: 24`) just move the memory
  elsewhere.
- **The big caveat:** runs stop at wildly different points (108 → 949 draws/frame
  at 150 s), because menu advance, PSO cold-start and disk speed vary. A ±1.5 GB
  scene difference swamps a 300 MB knob effect. **Wall-clock 150 s is not a
  comparable metric.** Fix this before trusting any further knob result (see §6.1).

## 5. Where the RAM actually is (from run 04, in-game)

`memory map` by kind at 23:41:04 (committed / resident):

- title's heaps (private, console addrs) **6,369 MB** / 2,274 MB
- views of the title's pages (mapped) **6,333 MB** / 2,564 MB
- title's page pool (mapped, ≥1 GB regions) **12,472 MB** / 1,056 MB
- programs and libraries 242 MB / 153 MB

`memory:` line, same run: **private commit 5,567 MB**, **working set 15,483 MB**.
So ~10 GB of the working set is *mapped section memory, not private commit* — the
title's own page pool (12.5 GB committed, ~1 GB resident at any moment) plus views.
That is the title's memory as Wine maps it, not Victory's buffers.

Victory's own alive blocks in 04: host copies 2,551 MB (windows 1,687 MB),
host textures 2,423 MB, own allocator 1,037 MB, twins 108 MB, staging 18 MB;
plus **3,536–3,892 MB of "the PC's memory shared with [the card]"** (D3D12
shared/L0 heaps; `shared_buffer()` in `host.rs:8783` creates a fresh committed L0
buffer per call, nothing is pooled or reused).

Rough resident budget: ~6 GB title + ~7 GB Victory buffers + ~3.5 GB card-shared
≈ the 15 GB working set. **The two biggest Victory-side levers are the card-shared
3.5 GB and the 2.5 GB of host copies/windows — not the texture budget.**

### 5.1 The two requested red flags

- **RSS stickiness: not the problem.** When internal alive totals fell, /proc fell
  with them (windows 2,048 → 1,162 MB tracked 15,479 → 13,878 MB plateau); freed
  blocks are not held >32 MB in the allocator (`own blocks ≥32 MB` = 465 MB flat).
  The 15 GB vs 5.5 GB gap is *shared/mapped pages counted in RSS*, i.e. the title's
  page pool, not leaked Victory allocations. **Do not spend the next stage on
  page-return/`MEM_DECOMMIT` for Victory's allocator.**
- **Dirty tracking: real holes.** `write-watch askings per frame that failed in the
  kernel: 206–358`, and `draw.rs` logs **200** × *"a texture picked by index
  changed after its upload with nothing to tell of it: uploaded again slot=…,
  frames_after_upload=176"* (125–149 distinct 2.2 MB slots per run). The tracking is
  reactive (only 1,516 slots made due by map/unmap/write events in 04) and misses
  writes in un-guarded memory; the upload queue backs up (`9,269 waiting`, `oldest
  written 1,274 frames ago`, `2,188 uploaded in part`). That costs re-upload
  bandwidth and VRAM churn, and it is a *correctness/CPU* bug — it is **not** what
  makes RSS big.

## 6. Next steps, in the order that pays

### 6.1 First: make the measurement comparable (no game code changes)

The 12 GB target can't be judged at wall clock. Add a fixed-scene gate to the
harness instead of a fixed time: sample until the log's `N draws` first reaches a
threshold (e.g. 900 draws/frame), keep sampling 20 s more, then `timeout -s TERM`.
Two runs per config, report the lower plateau. Cheap: only `/tmp/vgb/ramrun.sh`.

### 6.2 Stage 2 — proposed surgical design (do not start before the user approves)

Ranked by measured MB, each with the exact site:

1. **Pool the card-shared L0 buffers (3.5–3.9 GB).** `Session::shared_buffer()`
   (`host.rs:8783`) does `CreateCommittedResource` + `Map` per call and never
   reuses; callers are `make_card_work`/`make_card_inflight` (1 MB + tickets),
   `fpsbox.rs:177`, `host.rs:4921,5349`, `indirect.rs:821,1204-1206,1309-1314,1440-1443`
   (some are per-invocation test paths). Fix = one size-class free list keyed by
   `size`, released on a fence-guarded tick, plus reuse of `differs`/`fetched`.
   Expected: the biggest win available; measure `card shared` before/after.
2. **Fence-guarded LRU on host copies of windows** (`resource.rs` around `room()`,
   `:1538`; `shadow.rs` window grid `:4285-4335`). The sweep already computes
   "not used for 30 s and held by no list and no slot" (`host copies the sweep never
   lets go: … 0 of them`) — that count is **0**, i.e. the criterion never fires.
   Make it: drop the window's *host* bytes (keep the block) once its last fence has
   passed, then let the next ask re-copy. Expected 1–2 GB of the 2.5 GB.
3. **`VICTORY_TEXTURE_BUDGET_MB` is the wrong knob** — proven a net loss at 1 GB.
   Leave the 2.4–2.6 GB texture set alone; the budget gate is doing its job.
4. **`pool.rs` (Repo B `9fea743`) is not justified yet.** Nothing measured shows
   allocator churn (fragmented ≥32 MB blocks = 465 MB, stable across runs), so
   skip it until 1 and 2 are measured.
5. Fix `make_card_inflight` (`CARD_FETCH`) with the DXC fallback only if the
   in-flight fetch is worth having.
6. Optionally add `vkd3d-proton.cache*` to `.gitignore` — each run drops it in the
   repo root (they were moved to `/tmp/vgb/stray/`).

### 6.3 Open questions for the user

- Is 12,288 MB a **hard cap** (i.e. also cap VRAM/card-shared and accept texture
  pop-in) or a target with visual quality secondary?
- Approve 6.2 item 1 (shared-buffer pooling) first, or item 2 (window LRU)?
- Is the dirty-tracking hole (§5.1) in scope now, or after RAM is under 12 GB?

## 7. Session log (what was run, all clean)

| run | file | result |
|---|---|---|
| 01 | `/tmp/vgb/01-diag-baseline.log` | 16,809 MB peak, both warnings, diag breakdown confirmed |
| 02 | `/tmp/vgb/02-diag-dxc.log` | 15,322 MB, both warnings gone, card compare live |
| 03 | `/tmp/vgb/03-diag-windows.log` | 15,064 MB peak / 13,878 plateau |
| 04 | `/tmp/vgb/04-diag-windows-mips-snaps.log` | 16,268 MB peak / 14,491 plateau |
| 05 | `/tmp/vgb/05-diag-texbudget1024.log` | 16,800 MB peak / 15,082 plateau |

Every run: `timeout -s TERM 150`, no leftover `victory.exe`, GPU back to ~430 MiB,
`dmesg` zero Xid, only the Wires wineserver (PID 4189) untouched. Raw samples:
`/tmp/vgb/<run>.tsv`, ANSI-stripped copies `/tmp/vgb/<run>.plain`.

Audit clones (read-only, still on disk): `/tmp/victory-audit/repoA` (branch
`phase-0-audit`), `/tmp/victory-audit/repoB` (`main`).

---

# Session 2 — cutscene → prison, long run, Part B audit (2026-11-26)

## A. It renders past the cutscene: **yes**

Release build (`--release`, DXC fix present, 00:02) + `VICTORY_WINDOW_KB=256`
`VICTORY_WINDOW_TAILS=1`, `timeout -s TERM 360` (run 06), gate ≥900 draws.

| phase | t | draws/frame | fps | RSS | VRAM | pipelines being made |
|---|---|---|---|---|---|---|
| first menu | 0–75 s | 3–12 | 28–30 | 4–6 GB | 1.0–1.6 GB | 0 |
| world load | 75–90 s | 44 → 2,421 | 0.2–0.5 | 14.2 GB | 2.9 GB | 700–760 |
| 3D cutscene | 90–260 s | 60–2,421 (mostly 125) | **0.2–1.4** | 14.5–15.6 GB | 3.3–3.7 GB | 700–870 |
| gameplay (city) | 270–348 s | 659–1,616 | 0.4–1.5 | 14.3–15.2 GB | 3.7–3.9 GB | 520–710 |

Run 07 (30 min, same build/env): gameplay 4,700–5,300 draws/frame at 1.6–2.6 fps,
peak **8,576 draws/frame**, VRAM grew 2.9 → 5.6 GB, never crashed; ended by my own
1,800 s TERM (`exit=124`), no leftover process, VRAM back to 80 MiB.

**Measurements (run 07):** peak tree RSS **18,157 MB** (one process 17.7 GB),
plateau last 30 s 14,269 MB, **gate (draws ≥900 sustained 5 samples, t≥75 s):
RSS 14,297 MB, VRAM 3,933 MB, 1,051 draws** — this is the honest Stage-2 baseline.

The fps story at 4,693 draws (415 ms/frame, 2.4 fps): **14.2 ms on the GPU**,
104 ms preparing (copies 85.8 ms for 282.9 MB), 28 ms copying back, heap worker
13.7 ms (4.1 detiling). During the cutscene the same frame took 0.2–1.4 s, with
700–870 pipelines being made and 1,557 draws/frame dropped for want of them.
**Pipelines, not the GPU, are the frame-rate wall while streaming.**

## B. Part B audit — the three answers

### B1 `shared_buffer()` (`host.rs:8783`) — live, not garbage

Callers (runtime): `shadow.rs:4228` (host copy of a title buffer, kept in
`Entry.shadow`), `shadow.rs:4478/4565` (windows outside buffers, kept in `LOOSE`),
`host.rs:4274` (compare results 1 MB, in `CardWork`), `host.rs:4331/4334`
(in-flight tickets/pieces, in `CardInflight`), `host.rs:4921/5349` (relay fetch,
grown in 16 MiB steps), `fpsbox.rs:177`, `memory.rs:98`. All `indirect.rs`
matches (821, 1204-1206, …) are inside `#[test]` functions on WARP.

Lifetime: the `ID3D12Resource` is COM-owned by the Rust struct that holds it;
`host::retire` drops at once when no submission is running, else after the
fence (`bury`). The sweep (`host::sweep`, every 1 s) calls `shadow::let_go_idle`
(windows), `texture::let_go_idle`, `resource::let_go_idle`.

**So a pool would cut allocation churn, not RSS:** the 3.5–3.9 GB of card-shared
L0 is *live* window buffers and card-staging, and it is exactly what the census
counts as `windows` + `host copies`.

**The upload queue is already coalesced.** `TextureQueue` is a
`BTreeMap<u32 slot, Waiting>`; a rewrite `insert`s over the old entry and bumps a
write id, and `same()` makes a stale worker's work a no-op. Nothing can stack.
The backlog (7k–13k slots) is 3 throttles: `due(frame, max)` per pass,
exponential `later()` backoff for slots whose memory is not mapped, and
`hold()` when the card has no room. It costs latency, not GB: 11k entries is
the slots themselves, and staging is kept by the texture, not the queue.

### B2 window sweep — the “0 freeable” is by construction

`resource::targets_census` (`resource.rs:1970`) walks textures and **skips every
copy the host copied into** (`copied_into` → counted at `c[8]` and `continue`),
so its “not used for 30 s and held by no list and no slot” bucket only ever looks
at render-target copies. `resource::let_go_idle` only takes copies of filled
textures the host *never* copied into. **No code path frees a render-target host
copy at all** — the count is 0 because they are used every frame, not because a
reference is stuck.

The window copies that *are* swept live in `shadow::LOOSE`, freed by
`shadow::let_go_idle` when `Arc::strong_count == 1`, `references(buffer) == 1`,
and idle for `ram_idle_ms` (10 s, 5 s under 4 GB free, 2 s under 2 GB) + 4 frames.
That path works (2,048 → 1,162 MB with `WINDOW_KB=256`).

### B3 write-watch failures — `MEM_MAPPED`, an OS limit

Every sampled failure (runs 04/05) reports `state 0x1000` (MEM_COMMIT),
`type 0x40000` (**MEM_MAPPED**), `protect 0x4` (PAGE_READWRITE), `is a view: true`.
`GetWriteWatch` only works on MEM_PRIVATE (VirtualAlloc’d) memory; on
section-backed views Wine returns INVALID_PARAMETER. `vm.max_map_count` is
1,048,576, so no limit there. Those ranges fall back to `guard()` (mprotect),
which only sees writes that happen while a 64 KiB block is read-only — hence
DirectStorage/DMA writes (346,532 of them, **23,894 MB** in run 07) and writes to
never-guarded blocks are invisible, and a 2.2 MB slot can “change with nothing to
tell of it” 176 frames later (the fingerprint `recheck` catches it late).

Also seen in run 07: 175 × “buffer views off their copy's elements (refused, read
zero)”, 29 × “a pipeline creation method that is not implemented” (slot 0x218),
and exactly one DXC retry per site (the three `0x80004005` infos) — the fallback
works and does not repeat.

## C. What the audit changes about Stage 2

- **2.1 as written cannot reach the target** — pooling live buffers saves churn,
  not GB. Do not build it first.
- **2.2 is the only real RSS lever left** (windows + render-target copies), but it
  needs the fence-guarded detach that Part C calls invasive. Awaiting a decision.
- **FPS lever, measured:** pipeline making (700–870 at once during streaming,
  fps 0.2 → 2.6 once caught up) and CPU copies (282.9 MB/frame in gameplay).
- `dmesg` is **not readable as this user** (`Operation not permitted`), so “zero
  Xid” was inferred from clean exits and released VRAM, not read from the kernel
  ring buffer.

## D. Harness (new)

`/tmp/vgb/ramrun2.sh <log> [dur] [gate] -- [VICTORY_*…]`: samples RSS/VRAM every
2 s with draws/pipelines/fps/copy-ms, and snapshots at the gate. `GATE_MIN_T=75`
stops the boot screen’s exact 900 draws/frame from tripping it (it did in run 06).
`GATE_STOP=0` runs the full duration. `GATE_HOLD`, `GATE_SUSTAIN` tune it.

## E. Repo check

`origin/main` = `8c1caa7` = HEAD; `git fetch --all` brought nothing; audit clones
also unchanged (`repoA e667c48`, `repoB 0a43566`). No owner push to pull yet.

## F. Phase 1 audit, second pass (zero-launch)

### F1 the 18.2 GB peak is a copy burst, not a leak
- Gate (t=280 s, 1,051 draws): **14,297 MB**.
- Peak (t=920 s): **18,157 MB**, on the frame that copied **401.1 MB in one
  frame (4,523 ms, 196.9 ms GPU, 2,909 draws, 0.2 fps)**. RSS recovers to
  14.3 GB by t=1,002 s and settles at 16.2 GB.
- Steady 1,002 → 1,602 s: **+1.8 GB with only ~300 new pipelines** → streamed
  content (host copies + L0 staging), not pipelines.
- Pipelines: 3,145 first binds, 2,168 distinct, **1,978 made in one 600–800 s
  burst**. VRAM grew 3,933 → 5,633 MB (device-local, not RSS). Queue peaked at
  11,234 slots; DirectStorage writes 23,894 MB cumulative.
- The release build has no census, so per-bucket attribution needs a diag run at
  the gate (run 08, below).

### F2 render-target host copies cannot be evicted safely
`resource::let_go_idle` (1895) skips `!fills(desc) || texture::host_wrote(at)`.
`fills()` = no target/depth/UAV flag; `host_wrote()` = "the host GPU wrote it by a
copy or resolve: **cannot be made again from title memory**". Tracking is
`Hosted { made, used: moment, gone, placed, refused }` — no per-copy fence; safety
is COM refcount (`references(texture)==1`, `Arc::strong_count==1`), lists keeping
what they name and slots keeping what they view, with `host::retire` deferring
drops past the running submission. **Fences are clean; provenance is not.**
Evicting the ~2–3 GB of RT copies would render into nothing. Not implemented.

### F3 idle thresholds (now knobs)
`ram_idle_ms` saw only `ullAvailPhys`: <2 GiB → 2 s, <4 GiB → 5 s, else 10 s,
plus `IDLE_FRAMES = 4` and refcount checks. A 16 GB host sits in the 2 s band most
of the run, but there was **no RSS ceiling**, so a run with standby-cached room
stayed at 10 s. Now: `VICTORY_RAM_MODERATE_MB` (8192), `VICTORY_RAM_FLOOR_MB`
(4096), `VICTORY_RAM_IDLE_RSS_MB` (10240 working set → 2 s).

### F4 pipelines / cache / the 269 ms
- 8 workers (half of 16 threads, clamp 2–8), no env knob.
- **No `host-pipelines.bin` exists**: `CreatePipelineLibrary(&[])` failed and the
error was swallowed by `.ok()?`, so every run remakes all 2,168 pipelines. Now
logged (`error`, `dir`). vkd3d's own cache is 230 KB (+209 KB `.write`).
- 415.5 ms frame − (104.3 prepare + 28.1 back + 14.2 GPU) = **269 ms in the
title's own (emulated) CPU**, not in our meters; `--profile diag` would name it.
- 282.9 MB/frame copies = title buffer copies (45/frame) + window refreshes.

### F5 DirectStorage path (for the MEM_MAPPED fix)
`victory-hle/src/modules/dstorage.rs` (factory, queue, files) and
`xmem.rs` (`write_physical`, "DirectStorage workers may write this concurrently")
write the pages; `watch.rs:1349` already receives them as `pages`, and
`WRITTEN` counts them. Completing I/O can mark destination guest ranges dirty
directly — the right fix instead of `GetWriteWatch` (which cannot see MEM_MAPPED).

### F6 what this phase changed
`host.rs`: `RamLimits`, `ram_limits()`, `working_set()`, `ram_idle_ms_with()`,
rewritten `ram_idle_ms_scales_with_pressure` test. `pipeline/library.rs`: the
empty-library refusal is logged with its error and dir. Diag, release and
`--tests` all build clean (3 pre-existing `resource.rs` dead-code warnings only;
tests compile but cannot run on Linux — Windows target).

### F6b the empty-library bug itself (fixed)
windows-rs 0.62.2 generates `CreatePipelineLibrary` as
`core::mem::transmute(plibraryblob.as_ptr())`, so `make(&[])` passed a dangling
`0x1` with length 0 — D3D12 wants **NULL** there and answers `E_INVALIDARG`, so
no empty library was ever made and nothing was ever kept. `library.rs` now calls
the device-1 vtable itself (`create_library`) and passes `core::ptr::null()` for
an empty slice. Diag rebuilt 00:59. Upstream (`8c1caa7..6b385bd`) does not contain
this fix; it carries `bit_exact_format` for typed buffer views, a `NO_WAIT`
default flip back to off (our launcher still exports 1), a div/fma priority fix
and the card-compare DXC fallback we already hand-ported.

### F6c run 08 (diag, gated) — the library lives
`exit=124` from our own 600 s TERM, no leftovers, no device removed.
- Opened empty with **no refusal** (the null blob), then
  `.../AppData/Local/victory/cache/pipelines/host-pipelines.bin` grew to
  **328,568 bytes**, saved every ~20 s; 1,714 pipelines made (run 07: 2,168).
- Gate at **124 s: 13,391 MB, VRAM 3,249 MB, 2,908 draws** (run 07: 280 s,
  14,297 MB, 3,933 MB, 1,051 draws). Peak **16,814 MB** at 296 s (run 07:
  18,157 MB at ~920 s), VRAM peak 4,889 MB, draws max **9,871** (run 07: 8,576).
- The 600 s cap ends in the cutscene, so the last-30 s mean (14,281 MB) is not
  comparable with run 07's 30-minute city plateau; only the equal-draw gate and
  the peak are.
- `the system compiler refused the compare pipeline; trying DXC` fires and the
  DXC path carries on; one `the depth plane pipeline stopped ... stage="the root
  signature"` warning.

## Session 3 — backup, run 08 census, 3-way audit, ports (2026-11-26, 01:30)

### G1 the tree is on GitHub, as the burner
`wip/rtx3070-16gb-linux` = baseline commit `3a02bf1` (identity `viyourmom
<burner@github>`, `core.hooksPath` unset so the policy hook does not run; the
staged set was verified all-text). Fork `viyourmom/victory-8gb-linux` does not
exist yet, so nothing is pushed: click Fork once, then `git push burner
wip/rtx3070-16gb-linux`.

### G2 where run 08's 1,103 MB above target lives (gate t=123 s)
| bucket | gate | peak t=294 | end t=573 |
|---|---|---|---|
| working set | 13,452 | 15,852 | 15,103 |
| private commit | 3,087 | 4,259 | 4,852 |
| host textures | 2,160 | 2,766 | 3,226 |
| host copies of title memory | 2,962 | 2,618 | 3,113 |
| … of them windows outside buffers | 2,098 | 1,751 | 2,238 |
| … of them the host renders to/writes | 779 | 1,039 | 1,379 |
| staging of textures | 19 | 23 | 34 |
| the card's own, in use | 2,949 | 3,689 | 4,248 |
| the PC's shared with the card | 3,646 | 3,450 | 3,979 |
| the PC's free RAM | 2,788 | 1,097 | 988 |

The title's own resident pages at the gate are ~5,750 MB (heaps 1,823 + views
2,926 + page pool 899 + programs 102). **The cheapest 900 MB is inside the
windows themselves**: "of the windows alive, 889 MB lie between the lowest and
highest address asked for in each" at the gate, 1,145 MB at the end. That is
window area nothing reads, and it grows with `VICTORY_WINDOW_KB`; splitting a
window at its holes is the next lever, not a new allocator.

Also: `copystat`'s `the pipeline library's file 0 MB` line is wrong (it stats a
path in the working directory, not the prefix's cache) — the file is 328 KB and
`library.rs` logs the real saves.

### G3 the depth-plane warning and the 264 ms copy
The `stage="the root signature"` warning is the **handled** first attempt
(`dxc=false`) of `PlanePass::make` for format 45: Wine's `d3dcompiler_47`
rejects the DXBC root signature, the DXC retry on the next line succeeds, and it
happens once per run (count: 1). Not a fault.

The 264.2 ms for 295.7 MB is `PREPARING[0]` — CPU `Shadow::update` memcpy of
title pages into the host copy, timed (host.rs `update` ~7680), not PCIe and not
the GPU. Release measured the same volume at 85.8 ms (3.3 GB/s) in run 07; the
diag build times `copystat::range` inside that region, and with 966 MB free the
sources are being refaulted. Fix the window set, not the copy loop.

### G4 what was ported (`exp/merges-nvidia-neptune`, 4 commits)
`d97c81d` typed buffer views take the float format of the same width
(`bit_exact_format`); `9047d43` signature rows share one interpolation mode;
`5cb2a64` `v_div_fixup` keeps a qNaN quotient below signed zero; `cb01b1e` a
helper lane's `v_readfirstlane` takes its own value. All from
meeyao/victory-8gb-linux `710b7e4` (upstream `origin/main` is now `b83b48b`,
which **reverted** `6b385bd` "Textures wait for title memory: the missing
head" — so `VICTORY_TEXTURE_NO_WAIT` stays 1 here). Diag, release and `--tests`
build with the same 3 pre-existing `resource.rs` dead-code warnings, no new
ones.

### F7 next two runs (not yet launched)
1. `/tmp/vgb/ramrun2.sh /tmp/vgb/08-diag-gated.log 600 900 -- VICTORY_WINDOW_KB=256
   VICTORY_WINDOW_TAILS=1 VICTORY_BUILD_DIR=<repo>/target/x86_64-pc-windows-msvc/diag`
   — census at the gate (compare 14,297 MB) **and** the new library error message.
   `GATE_STOP=0`; diag is ~2× slower, hence 600 s.
2. Release, 600 s, same env: peak/gate RSS and FPS delta with the tighter idle
   thresholds. Expect the window sweep to engage earlier; 12,288 MB will not be
   reached by these two changes alone — the pipeline cache is the next lever.

## Session 4 — run 09 (warm release), the folded-buffer patch, dark shading (2026-11-26, 02:20)

### H1 the harness presses Enter through the menus
The title sits on its "press a key" menus until someone does: the demo shows a
static frame, RSS flat at ~4 GB, and the gate never opens. `/tmp/vgb/ramrun2.sh`
therefore exports, before the launch:

```sh
export VICTORY_KEYS="12:Enter,16:Enter,20:Enter,25:Enter,30:Enter,35:Enter,40:Enter,45:Enter,50:Enter,60:Enter"
```

`VICTORY_KEYS` is `<second>:<key>` pairs, counted from the start of the title's
run: one Enter lands on the first menu, the later ones clear the settings/load
confirmation and the "continue" prompt. Add a pair for a new menu rather than
shortening the list; a run that never gets past a menu looks exactly like a
hang, with no draws and no VRAM. The script also keeps the run's own window
(no `-silent`) so an Enter that lands on a menu still shows on screen.

### H2 run 09 — warm cache, release, 1,800 s asked, 1,202 s run
`09-rel-warm.*`: `GATE_MIN_T=75 GATE_STOP=0 ramrun2.sh … 1800 900 -- VICTORY_WINDOW_KB=256
VICTORY_WINDOW_TAILS=1`, `host-pipelines.bin` left warm (26 pipelines loaded
before the first draw). The run was ended by closing the demo window at
t≈1,202 s; exit was clean (no `victory.exe`, no `wineserver` of ours, GPU back
to 86 MiB).

| | gate | end |
|---|---|---|
| when | t=222 s | t≈1,200 s |
| RSS | 14,753 MB | 14,559 MB |
| VRAM | 3,280 MB | 5,196 MB |
| draws/frame | 6,158 | 5,580 |
| fps | 0.2 | 2.0 |
| copies in the frame | 1,290.8 ms | 97.0 ms |

Peak 17,422 MB at t=478 s (the `.tsv`'s RSS column is KiB, not MB); 1,693 frame
lines, max 7,870 draws at that peak, no ERROR line. Against run 07 (cold, gate 280 s / 14,297 MB) the warm cache buys 58 s to
the gate and costs 456 MB there: the gate is a different shot, so **run 09 vs
run 10 is the only comparison that means anything**.

### H3 the frame time is CPU, not the card
From the run's own census, per frame: the card is **21% busy** (`nothing of ours
queued 298.2 ms`), so the 0.6–2.0 fps is host work. The biggest pieces:
- `textures picked by index`, own thread (`VICTORY_HEAP_WORKER`): **48.7 ms**
  (8.1 of it detiling), 84 slots shown;
- descriptor heap sync: **23.9 ms**, 189 changed heap pages, **190,464 slots
  looked at** per frame;
- texture refreshes on the submitting thread: **22.8 ms** (13.2 asking the write
  watch);
- copies of title memory in place (`VICTORY_COPY_PLAIN=1`): 23,440 copies,
  **301.2 MB** per frame;
- shader-write compares: 37.1 MB in 366 buffer-copy ranges, 28.4 MB snapshotted;
- the relay thread waits 64.8 ms for the card with nothing to land.
Single frames hit `copies 2,189.6 ms 320.0 MB` — 320 MB re-copied in one frame
at ~146 MB/s, i.e. the sources are being refaulted with ~1 GB free.

### H4 the patch under test: a buffer's copy is its window's (`exp/lean-windows-fps`)
`a540bb8`, pushed to the burner repo, `VICTORY_FOLD_BUFFERS` (on unless `0`).
A buffer small enough for one window now takes the window the title's memory
around it is already copied into instead of a second copy of the same bytes; the
buffer's entry holds the window, so `let_go_idle` (which needs
`Arc::strong_count == 1`) can never take it while a buffer points at it. From
neptune: 179.2 → 160.1 ms a frame, settles 4.5 → 1.0 a frame. Diag, release and
`--tests` build with the same 3 pre-existing `resource.rs` warnings, no new
ones. **Not yet A/B'd here** — run 10 is the measurement.

The 889 MB "asked for without a length" (run 08 census) is **not** reclaimable by
trimming: a root view carries no length, so the console reads past whatever
window we make; a shorter window would zero real mesh reads, not just the hole.

### H5 open bug: the image is dark and blurry
Reported from the run 09 session, with geometry now correct (faces render).
Ruled out from the same run's log: no `ERROR` line; the only shader of ours that
fails to compile is the **compare pipeline** (`Load4` on `RWByteAddressBuffer`,
then DXC retries it), not a title pass; the 29 `a pipeline creation method that
is not implemented` slots are the known gaps; `texture picked by index changed
after its upload` (220×) re-uploads and is handled. `0` mentions of sRGB.
Leading hypothesis: **tiled/UBWC decode or mip selection**, which is the one
fault that gives dark *and* blurry at once (a wrongly detiled mip reads as
smeared and dark). Next: compare one known texture against neptune's detile for
the same format/level, with `VICTORY_DETILE*`/`VICTORY_TEXTURE_*` knobs to
isolate decode from upload.

### H6 next
1. Run 10 with the same args as run 09 (`10-rel-lean.*`) once the demo is
   reopened: gate RSS/VRAM, peak, fps, `copies … ms` against run 09.
2. Then the CPU levers in H3 order: the 190k-slot heap pass, then the 301 MB of
   plain copies, then the texture worker's 48.7 ms.
3. In parallel, the dark/blurry hunt in H5.
