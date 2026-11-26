#!/usr/bin/env bash
# Build this tree and prepare a Wine prefix that can run it.
#
#   ./scripts/setup-linux.sh --proton "<Proton dir>" --dxc "<dir with dxcompiler.dll>"
#
# Options (or the matching environment variables):
#   --proton DIR   Proton install (default $PROTON_DIR or Proton Experimental)
#   --dxc DIR      folder with dxcompiler.dll and dxil.dll (default $VICTORY_DXC_DIR)
#   --prefix DIR   Wine prefix (default $VICTORY_PREFIX or ~/.local/share/victory-8gb/prefix)
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PROTON=${PROTON_DIR:-"$HOME/.local/share/Steam/steamapps/common/Proton - Experimental"}
PREFIX=${VICTORY_PREFIX:-"$HOME/.local/share/victory-8gb/prefix"}
DXC=${VICTORY_DXC_DIR:-}

while [ $# -gt 0 ]; do
  case "$1" in
    --proton) PROTON=$2; shift 2 ;;
    --dxc) DXC=$2; shift 2 ;;
    --prefix) PREFIX=$2; shift 2 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

WINE="$PROTON/files/bin/wine"
[ -x "$WINE" ] || { echo "Proton wine not found: $WINE (pass --proton)" >&2; exit 1; }

command -v cargo >/dev/null || { echo "cargo is required: https://rustup.rs" >&2; exit 1; }
cargo xwin --version >/dev/null 2>&1 || {
  echo "cargo-xwin is required: cargo install cargo-xwin" >&2; exit 1; }

echo "== build"
(cd "$ROOT" && XWIN_ARCH=x86_64 cargo xwin build --locked --release -p victory \
  --target x86_64-pc-windows-msvc)
REL="$ROOT/target/x86_64-pc-windows-msvc/release"
[ -f "$REL/victory.exe" ] || { echo "build did not produce $REL/victory.exe" >&2; exit 1; }

echo "== DXC"
if [ -n "$DXC" ]; then
  cp -f "$DXC/dxcompiler.dll" "$DXC/dxil.dll" "$REL/"
fi
[ -f "$REL/dxcompiler.dll" ] && [ -f "$REL/dxil.dll" ] || {
  echo "dxcompiler.dll and dxil.dll must sit beside victory.exe." >&2
  echo "Pass --dxc <folder> (Windows SDK, or any game that ships them)." >&2
  exit 1; }

echo "== Wine prefix: $PREFIX"
mkdir -p "$PREFIX"
if [ ! -d "$PREFIX/drive_c" ]; then
  WINEPREFIX="$PREFIX" "$WINE" wineboot -u >/dev/null 2>&1 || true
fi
SYS="$PREFIX/drive_c/windows/system32"
# Wine's own d3d12core is a 49 KB stub; Proton ships vkd3d-proton and DXVK.
for f in d3d12.dll d3d12core.dll; do
  cp -f "$PROTON/files/lib/wine/vkd3d-proton/x86_64-windows/$f" "$SYS/$f"
done
cp -f "$PROTON/files/lib/wine/dxvk/x86_64-windows/dxgi.dll" "$SYS/dxgi.dll"
# vkd3d-proton's own libvkd3d-* DLLs: d3d12.dll loads them from system32
# beside itself, and Wine's builtin copies are a different version. Without
# these a fresh prefix fails to create the device.
for f in libvkd3d-1.dll libvkd3d-shader-1.dll libvkd3d-utils-1.dll; do
  cp -f "$PROTON/files/lib/vkd3d/x86_64-windows/$f" "$SYS/$f"
done

# A prefix made by Proton keeps absolute symlinks into the Proton folder.
# Outside Proton's runtime those dangle; turn them into real files.
while IFS= read -r l; do
  t=$(readlink "$l" || true)
  [ -n "$t" ] && [ -f "$t" ] && { rm -f "$l"; cp -f "$t" "$l"; }
done < <(find "$PREFIX" -type l -lname '/*' 2>/dev/null)

echo
echo "ready: $REL/victory.exe"
echo "run:   ./scripts/run-linux.sh --game \"/path/to/game_scarlett_master.exe\""
