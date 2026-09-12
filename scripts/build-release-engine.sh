#!/bin/bash
# Rebuild the pinned Voxtype engine for release without embedding local checkout paths.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:-${VOXTYPE_SOURCE:-$ROOT/.cache/voxtype-src}}"
OUT="${2:-$ROOT/dist/release-engine}"
PIN="dda37ca72b71294d08b0c5bb49c5b24ca590d847"
FEATURES="gpu-metal,parakeet,parakeet-coreml"

[[ -f "$SRC/Cargo.toml" && -f "$SRC/Cargo.lock" ]] \
  || { echo "ERROR: Voxtype source and lockfile not found at $SRC" >&2; exit 1; }
SRC="$(cd "$SRC" && pwd -P)"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd -P)"
case "$OUT" in
  /|"$HOME"|"$SRC"|"$SRC"/*) echo "ERROR: unsafe output directory: $OUT" >&2; exit 1 ;;
esac
case "$SRC"/ in
  "$OUT"/*) echo "ERROR: output directory cannot contain the source checkout" >&2; exit 1 ;;
esac
[[ "$(git -C "$SRC" rev-parse HEAD)" == "$PIN" ]] \
  || { echo "ERROR: Voxtype source must be at pinned revision $PIN" >&2; exit 1; }
git -C "$SRC" diff --quiet && git -C "$SRC" diff --cached --quiet \
  || { echo "ERROR: Voxtype source has tracked changes" >&2; exit 1; }

TARGET="${VOXTYPE_TARGET_DIR:-$OUT.target}"
mkdir -p "$(dirname "$TARGET")"
TARGET_PARENT="$(cd "$(dirname "$TARGET")" && pwd -P)"
TARGET="$TARGET_PARENT/$(basename "$TARGET")"
case "$TARGET" in
  /|"$HOME"|"$SRC"|"$SRC"/*) echo "ERROR: unsafe target directory: $TARGET" >&2; exit 1 ;;
esac
case "$SRC"/ in
  "$TARGET"/*) echo "ERROR: target directory cannot contain the source checkout" >&2; exit 1 ;;
esac
SOURCE_DATE_EPOCH="$(git -C "$SRC" show -s --format=%ct HEAD)"
REMAP_RUST="--remap-path-prefix=$SRC=/usr/src/voxtype --remap-path-prefix=$TARGET=/usr/src/target --remap-path-prefix=$HOME=/usr/src/builder"
REMAP_CC="-ffile-prefix-map=$SRC=/usr/src/voxtype -fdebug-prefix-map=$SRC=/usr/src/voxtype -fmacro-prefix-map=$SRC=/usr/src/voxtype -ffile-prefix-map=$TARGET=/usr/src/target -fdebug-prefix-map=$TARGET=/usr/src/target -fmacro-prefix-map=$TARGET=/usr/src/target -ffile-prefix-map=$HOME=/usr/src/builder -fdebug-prefix-map=$HOME=/usr/src/builder -fmacro-prefix-map=$HOME=/usr/src/builder"

echo "==> Building pinned Voxtype release engine"
(
  cd "$SRC"
  env \
    SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" \
    ZERO_AR_DATE=1 \
    RUSTFLAGS="$REMAP_RUST" \
    CFLAGS="$REMAP_CC" \
    CXXFLAGS="$REMAP_CC" \
    cargo build --release --locked --target-dir "$TARGET" --features "$FEATURES"
)

cp "$TARGET/release/voxtype" "$OUT/voxtype-bin"
chmod 0755 "$OUT/voxtype-bin"
cat > "$OUT/VOXTYPE-BUILD.txt" <<EOF
Bundled engine: Voxtype 1.0.1
Upstream source: https://github.com/peteonrails/voxtype
Source revision: $PIN
Cargo lockfile: upstream Cargo.lock at the source revision above
Target: $(rustc -vV | sed -n 's/^host: //p')
Rust compiler: $(rustc --version)
Cargo: $(cargo --version)
Features: $FEATURES
Build command: cargo build --release --locked --features "$FEATURES"
Reproducibility: SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH, ZERO_AR_DATE=1
Path sanitization: Rust and native C/C++ sources remapped to /usr/src/voxtype,
  build output remapped to /usr/src/target, and the builder home remapped to /usr/src/builder.
EOF

if strings "$OUT/voxtype-bin" | grep -F "$HOME/" >/dev/null; then
  echo "ERROR: release engine contains the builder home path" >&2
  exit 1
fi
if strings "$OUT/voxtype-bin" \
    | grep -E '/Users/|/home/' \
    | grep -vF '/Users/runner/work/ort-artifacts/' >/dev/null; then
  echo "ERROR: release engine contains an absolute user home path" >&2
  exit 1
fi

echo "$OUT/voxtype-bin"
echo "$OUT/VOXTYPE-BUILD.txt"
shasum -a 256 "$OUT/voxtype-bin"
