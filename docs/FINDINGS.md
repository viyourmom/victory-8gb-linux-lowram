# Findings — VIctory on Linux, NVIDIA 8 GB (2026-11-26)

Everything here was measured on one machine: CachyOS, Ryzen 7 3700X, 32 GB,
**RTX 3070 8 GB**, driver 620.70.06 (open module), Wine from Proton
Experimental, vkd3d-proton, game build `b99f876b74d4a77f`.

## What renders, and with what

| Tree | Result |
|---|---|
| soldsawn/victory-nvidia-8gb + the three patches here | **prison cell renders**: textures, window light, HUD, subtitles, body; ~2 fps at 1920×1080; 4.9/8 GB VRAM; 0 NVRM |
| rorodev6/victory (series-s) | menus/UI render, 3D black; ~2.4 GB VRAM; cache hits work |
| vlinux (series-x/series-s) | never left the loader before the VA asserts; series-x menus render |
| Neptune_VI | series-s is the default and the fastest documented path (16–17 fps on a 5070 Ti), but it needs a PC `amd_fidelityfx_upscaler_dx12.dll` for series-s; without it, 4K |

## Why earlier builds showed only audio and subtitles

The indirect-argument clamp is compiled at run time. Wine's `d3dcompiler_47`
cannot compile it (`E5005` on `InterlockedAdd`/`InterlockedOr`), so the clamp is
missing and the layer refuses every indirect draw:

```
dropped 3790.5/frame: indirect kind 10: not bounded (no clamp, ...)
```

UI and audio do not use indirect draws, which is exactly the "menus and sound,
no 3D" symptom. The fix (patch 1) compiles the clamp with DXC; draws went from
~800 to **5,728/frame**.

## Frame budget at 1080p (5,728 draws)

```
frame       531 ms   (~2 fps)
preparing   229 ms   copies 64 ms / 104 MB, textures 5 ms
GPU          75 ms
copy-back   149 ms / 35 MB
VRAM        4.9 / 8 GB     GPU 63%
```

The card is at ~13 fps worth of work; the layer's copies are the limit. That is
the CPU/GPU duplication tax of the console's unified memory (the title sizes its
pool for 13–14 GB; the PC mirrors it).

## VRAM and the 8 GB ceiling

- Without `VICTORY_RESOLUTION=1920x1080` and `VICTORY_TEXTURE_DROP_MIPS=2` the
  same scene reaches 7.6–7.8 GB and the driver starts failing DMA mappings
  (`gpu_vaspace.c`, `intermapRegisterDmaMapping`); after that, every run hangs
  until a reboot.
- With the cap and the mip drop, VRAM stays around 4.9 GB and no NVRM appears.
- The 4K ladder costs ~2.7 GB more VRAM and about 40% more frame time.

## Crash rules learned the hard way

- `SIGKILL` on the title with thousands of live mappings fires the NVRM storm
  minutes later. Close the window, then `SIGTERM`; never `kill -9`.
- One VA assert poisons the boot: new GPU devices fail (`vkCreateDevice` →
  `ERROR_INITIALIZATION_FAILED`, `GspRmAlloc failed`, `State in use`). Reboot
  only with the user's say-so.
- A preflight that creates a Vulkan device is the only reliable "is the card
  usable" check; `nvidia-smi` alone can answer while device creation fails.

## Open defect: head/face

The body renders; the head is a hair/skin blob with no face. It is not a
dropped draw (the ~347 drops/frame are the ray-tracing builder, which is off).
Applied so far: quad reads with helper lanes (patch 2), mesh index mask
(patch 3). Candidates listed in `docs/PATCHES.md`.

## Forks and what each contributes

- **soldsawn/victory-nvidia-8gb** — the 8 GB preset (1080p cap, mip drop,
  async/copy switches) and the 32-lane wave fixes. Base of this tree.
- **zm0kiemedia/Neptune_VI** — the face/mesh shader fixes; series-s needs a PC
  FidelityFX upscaler DLL.
- **byartesao/victory-giga-fork** — quad-read helper lanes, texture index
  refresh, blend-shape/hair fixes (named in its README).
- **rorodev6/victory** — series-s profile and the same DXC clamp fix.
- **fxceless/victory-fork** — frame-rate switches (`ASYNC_SUBMIT`, `QUEUE2`,
  `INDIRECT_GATHER`) and `VICTORY_TEXTURE_DROP_MIPS`.

## Reproducing the measurement

This tree's scripts run the same profile. The frametime CSV used for the
numbers comes from forks that carry `VICTORY_FRAMETIME_DUMP`
(`AppData\Local\Temp\victory-frametime.csv` in the prefix); soldsawn's base does
not, so the numbers above are parsed from the run log's 5-second lines.
