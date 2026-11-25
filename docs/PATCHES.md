# Patches in this tree

Base: `soldsawn/victory-nvidia-8gb` @ `7b7b952` (fxceless/victory-fork
`ca8829f`). Three changes on top, each small and independent.

## 1. The indirect-argument clamp compiles with DXC (required for any 3D)

**Files:** `crates/victory-gpu/Cargo.toml`, `crates/victory-gpu/src/indirect.rs`

Wine's `d3dcompiler_47` rejects the clamp's `InterlockedAdd` / `InterlockedOr`
on `RWByteAddressBuffer`:

```
argument clamp: clamp:139:10: E5005: Method 'InterlockedOr' is not defined on type 'RWByteAddressBuffer'.
```

With no clamp, `victory-gpu` refuses indirect execution:

```
dropped 3790.5/frame: indirect kind 10: not bounded (no clamp, ...)
dropped  964.5/frame: indirect kind 2
dropped  262.0/frame: indirect kind 0
dropped   97.0/frame: indirect kind 1
```

That leaves menus, subtitles and audio — and no 3D. The fix adds a
`dxc_compile(source)` helper (DXC loaded from `dxcompiler.dll` beside the exe,
`cs_6_0`) and falls back to it when `D3DCompile` fails. `setup-linux.sh` copies
`dxcompiler.dll`/`dxil.dll` next to `victory.exe`; without them the fallback
reports `Module not found (0x8007007E)` and the clamp is still lost.

Ported from the same fix used in `rorodev6/victory`; the DXC compile helper is
from VIctory's own tree.

## 2. A pixel's quad is read through quad reads, helper lanes included

**File:** `crates/victory-shader/src/emit/lower.rs` (16 lines)

At a triangle's edge the quad's other pixels are helper lanes; a read lane
gives 0 from them, so a derivative taken by hand was the whole value and the
edges showed as lines on skin, glass and car paint. Adds `helpers_read(quad)`
(pixel shaders always include helpers) and uses it wherever the old code only
used quad reads for mesh pipelines.

Source: belobug `094ea1a`, also in `byartesao/victory-giga-fork`.

## 3. Mesh expanded-primitive vertex indices masked to 9 bits

**File:** `crates/victory-shader/src/emit/lower.rs` (4 lines)

GFX10 `exp prim` packs three 9-bit vertex indices at bits 0..9, 10..19, 20..29.
Bits 9, 19 and 29 are edge flags; masking with `0x3FF` treated them as index
bits and fed wrong vertices to mesh pipelines (head/face are mesh draws).

Source: `zm0kiemedia/Neptune_VI` `afbfcb5`.

## Not yet applied (known candidates for the open head/face defect)

- `aee44cd` (Neptune_VI): a helper lane's `v_readfirstlane` reads its own
  value. soldsawn lowers `v_readfirstlane` through the paired-wave path, so the
  patch needs a port rather than a cherry-pick.
- `da1f7e9` (fxceless): textures picked by index looked at again after upload —
  soldsawn already carries this feature (`233a65f`).
- `6ad18d6` (Neptune_VI): `v_div_fixup_f32` producing ±Infinity.
- victory-giga: blend-shape skinning and hair programs (named in its README,
  no single commit identified).
