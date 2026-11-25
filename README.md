# VIctory on Linux — NVIDIA 8 GB, ready to run

A VIctory build tuned for **8 GB NVIDIA cards on Linux under Proton**, plus the
three shader fixes that took it from "audio and subtitles only" to the prison
cell actually rendering on an RTX 3070.

Based on [`soldsawn/victory-nvidia-8gb`](https://github.com/soldsawn/victory-nvidia-8gb)
(fxceless/victory-fork `ca8829f`) with its 8 GB preset — a 1080p resolution cap,
mip dropping, and the async/copy switches — and the DXC clamp, quad-read and
mesh-index fixes below.

**This repository contains no game files.** You need your own copy of the title.

## State (2026-11-26)

| | |
|---|---|
| Prologue / prison cell | renders: cell, window light, textures, HUD, subtitles, body |
| Frame rate | ~2 fps (≈530 ms) at 1920×1080 on an RTX 3070, 3700X |
| VRAM | 4.9 of 8 GB |
| Open defect | the character's **head/face** is a hair/skin blob — body renders, face does not |
| Driver | no NVRM / device loss in a normal run |

Measured frame (5,728 draws): preparing 229 ms (copies 64 ms/104 MB, textures
5 ms), GPU 75 ms, copy-back 149 ms/35 MB. The layer's copies, not the GPU, are
the limit.

## Requirements

- x86-64 Linux with an NVIDIA GPU (8 GB tested; more is better)
- Rust + [`cargo-xwin`](https://github.com/rust-cross/cargo-xwin):
  `rustup target add x86_64-pc-windows-msvc && cargo install cargo-xwin`
- Proton (tested with **Proton Experimental**; any Proton with
  `files/bin/wine`, `files/lib/wine/vkd3d-proton` and `files/lib/wine/dxvk`)
- Microsoft's `dxcompiler.dll` and `dxil.dll` (Windows SDK / any game that
  ships them). **Required:** Wine's compiler cannot build the indirect-argument
  clamp, and without it every indirect draw is dropped (no 3D).

## Quick start

```sh
git clone https://github.com/meeyao/victory-8gb-linux.git
cd victory-8gb-linux

# once: build, create the Wine prefix, install Proton's vkd3d/DXVK DLLs
./scripts/setup-linux.sh \
  --proton "$HOME/.local/share/Steam/steamapps/common/Proton - Experimental" \
  --dxc /path/to/folder/with/dxcompiler.dll

# every time
./scripts/run-linux.sh --game "/path/to/game_scarlett_master.exe"
```

The first launch translates shaders as it loads and takes several minutes.
Later launches reuse the cache.

`setup-linux.sh` options: `--proton DIR`, `--dxc DIR`, `--prefix DIR`
(default `~/.local/share/victory-8gb/prefix`). The same three can be set with
`PROTON_DIR`, `VICTORY_DXC_DIR`, `VICTORY_PREFIX`.

## What the run script sets

The 8 GB preset from the upstream launcher, unchanged:

```
VICTORY_RESOLUTION=1920x1080      # cap the 4K ladder
VICTORY_TEXTURE_DROP_MIPS=2      # keeps textures in 8 GB
VICTORY_ASYNC_SUBMIT=1  VICTORY_QUEUE2=1  VICTORY_INDIRECT_WINDOW=1
VICTORY_INDIRECT_WINDOW_DRAWS=1  VICTORY_INDIRECT_GATHER=1
VICTORY_CLAMP_WAITS=0  VICTORY_JOIN_PARTS=1  VICTORY_BACK_OWN_VIEW=1
VICTORY_GUARD_HOLES_FRAME=1  VICTORY_HEAP_WORKER=1  VICTORY_ALIAS_ONCE=1
VICTORY_TEXTURE_NO_WAIT=1  VICTORY_COPY_PLAIN=1  VICTORY_SKIP_WC_COMPARE=1
VICTORY_WIDE_TEXTURES=1  VICTORY_DISK_CORES=slow  VICTORY_XMEM_PERSISTENT_VIEW=1
```

plus the Linux runtime settings `VKD3D_CONFIG=descriptor_heap` and
`VKD3D_DISABLE_EXTENSIONS=VK_NV_raw_access_chains`.

Override anything by exporting it before `run-linux.sh`; the script does not
clobber variables you set.

## The three fixes in this tree

See [`docs/PATCHES.md`](docs/PATCHES.md). In short:

1. **DXC clamp fallback** — Wine's `d3dcompiler_47` rejects the indirect-argument
   clamp (`InterlockedAdd`/`InterlockedOr` on `RWByteAddressBuffer`, `E5005`).
   The clamp now compiles with DXC from `dxcompiler.dll`. Without it:
   `dropped 3790/frame: indirect kind 10: not bounded (no clamp)`.
2. **Quad reads include helper lanes** — a derivative taken by hand at a
   triangle's edge was the whole value; edges showed as lines on skin, glass
   and car paint (belobug `094ea1a`).
3. **Mesh expanded-primitive indices masked to 9 bits** — GFX10 packs three
   9-bit vertex indices; bit 9/19/29 are edge flags, not index bits
   (zm0kiemedia/Neptune_VI `afbfcb5`).

## Findings

[`docs/FINDINGS.md`](docs/FINDINGS.md) records the measurements, why the
earlier builds showed only UI/audio, which forks do what, and the crash rules
(no SIGKILL; a driver NVRM assert ends the boot).

## Credits and license

GPL-3.0-or-later, as upstream. Built on
[VIctory](https://github.com/Marvisak/VIctory),
[fxceless/victory-fork](https://github.com/fxceless/victory-fork),
[soldsawn/victory-nvidia-8gb](https://github.com/soldsawn/victory-nvidia-8gb),
[Neptune_VI](https://github.com/zm0kiemedia/Neptune_VI) and
[victory-giga-fork](https://gitlab.com/byartesao/victory-giga-fork). No game
data, no binaries from the game.
