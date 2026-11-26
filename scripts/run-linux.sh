#!/usr/bin/env bash
# Run the title through this build.
#
#   ./scripts/run-linux.sh --game "/path/to/game_scarlett_master.exe"
#
# Options (or the matching environment variables):
#   --game PATH    the title's game_scarlett_master.exe (required)
#   --proton DIR   Proton install (default $PROTON_DIR or Proton Experimental)
#   --prefix DIR   Wine prefix (default $VICTORY_PREFIX or ~/.local/share/victory-8gb/prefix)
#
# Any VICTORY_* variable already in the environment is kept; the defaults below
# only fill what is unset.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PROTON=${PROTON_DIR:-"$HOME/.local/share/Steam/steamapps/common/Proton - Experimental"}
PREFIX=${VICTORY_PREFIX:-"$HOME/.local/share/victory-8gb/prefix"}
GAME=

while [ $# -gt 0 ]; do
  case "$1" in
    --game) GAME=$2; shift 2 ;;
    --proton) PROTON=$2; shift 2 ;;
    --prefix) PREFIX=$2; shift 2 ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

[ -n "$GAME" ] || { echo "--game <game_scarlett_master.exe> is required" >&2; exit 2; }
GAME=$(cd "$(dirname "$GAME")" && pwd)/$(basename "$GAME")
[ -f "$GAME" ] || { echo "not found: $GAME" >&2; exit 1; }

WINE="$PROTON/files/bin/wine"
# VICTORY_BUILD_DIR picks another profile's output (e.g. .../diag after
# `cargo build --profile diag --features diagnostics`).
REL=${VICTORY_BUILD_DIR:-"$ROOT/target/x86_64-pc-windows-msvc/release"}
[ -x "$WINE" ] || { echo "Proton wine not found: $WINE (pass --proton)" >&2; exit 1; }
[ -f "$REL/victory.exe" ] || { echo "not built: run ./scripts/setup-linux.sh first" >&2; exit 1; }
[ -f "$REL/dxcompiler.dll" ] || { echo "dxcompiler.dll missing beside victory.exe; rerun setup with --dxc" >&2; exit 1; }

export WINEPREFIX="$PREFIX"
export WINEDEBUG=${WINEDEBUG:--all}
export WINEDLLOVERRIDES='d3d12=n;d3d12core=n;dxgi=n;d3d11=n'
export VKD3D_CONFIG=${VKD3D_CONFIG:-descriptor_heap}
export VKD3D_DISABLE_EXTENSIONS=${VKD3D_DISABLE_EXTENSIONS:-VK_NV_raw_access_chains}

# soldsawn/victory-nvidia-8gb's preset, as in tools/play-nvidia-8gb.ps1.
export VICTORY_RESOLUTION=${VICTORY_RESOLUTION:-1920x1080}
export VICTORY_TEXTURE_DROP_MIPS=${VICTORY_TEXTURE_DROP_MIPS:-2}
export VICTORY_ASYNC_SUBMIT=${VICTORY_ASYNC_SUBMIT:-1}
export VICTORY_QUEUE2=${VICTORY_QUEUE2:-1}
export VICTORY_INDIRECT_WINDOW=${VICTORY_INDIRECT_WINDOW:-1}
export VICTORY_INDIRECT_WINDOW_DRAWS=${VICTORY_INDIRECT_WINDOW_DRAWS:-1}
export VICTORY_INDIRECT_GATHER=${VICTORY_INDIRECT_GATHER:-1}
export VICTORY_CLAMP_WAITS=${VICTORY_CLAMP_WAITS:-0}
export VICTORY_JOIN_PARTS=${VICTORY_JOIN_PARTS:-1}
export VICTORY_BACK_OWN_VIEW=${VICTORY_BACK_OWN_VIEW:-1}
export VICTORY_GUARD_HOLES_FRAME=${VICTORY_GUARD_HOLES_FRAME:-1}
export VICTORY_HEAP_WORKER=${VICTORY_HEAP_WORKER:-1}
export VICTORY_ALIAS_ONCE=${VICTORY_ALIAS_ONCE:-1}
export VICTORY_TEXTURE_NO_WAIT=${VICTORY_TEXTURE_NO_WAIT:-1}
export VICTORY_COPY_PLAIN=${VICTORY_COPY_PLAIN:-1}
export VICTORY_SKIP_WC_COMPARE=${VICTORY_SKIP_WC_COMPARE:-1}
export VICTORY_WIDE_TEXTURES=${VICTORY_WIDE_TEXTURES:-1}
export VICTORY_DISK_CORES=${VICTORY_DISK_CORES:-slow}
export VICTORY_XMEM_PERSISTENT_VIEW=${VICTORY_XMEM_PERSISTENT_VIEW:-1}

# Quality of life: advance the boot screens. Set VICTORY_KEYS= to disable.
export VICTORY_KEYS=${VICTORY_KEYS-12:Enter,16:Enter,20:A,25:Enter,30:A,35:Enter,40:A,50:Enter}

GAME_WIN="Z:${GAME//\//\\}"

echo "game:   $GAME"
echo "build:  $REL/victory.exe"
echo "prefix: $PREFIX"
exec "$WINE" "$REL/victory.exe" run "$GAME_WIN" --execute
