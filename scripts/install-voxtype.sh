#!/bin/bash
# Idempotent Voxtype install for VoicePop Mac port.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MIN_VER="1.0.1"
APP_BIN="/Applications/Voxtype.app/Contents/MacOS/voxtype-bin"
FORCE="${VOXTYPE_FORCE:-0}"

version_ge() {
  # Returns 0 if $1 >= $2 (semver X.Y.Z)
  printf '%s\n%s\n' "$2" "$1" | sort -V | head -1 | grep -qx "$2"
}

has_compiled_parakeet() {
  local bin="$1" out
  [[ -x "$bin" ]] || return 1
  out="$("$bin" info engines 2>/dev/null || true)"
  grep -q 'compiled  parakeet' <<<"$out"
}

if has_compiled_parakeet "$APP_BIN" && [[ "$FORCE" != "1" ]]; then
  echo "==> Custom Parakeet build already at $APP_BIN; skipping brew/app-bundle overwrite"
  echo "    (VOXTYPE_FORCE=1 to replace it)"
  echo "==> Models (Parakeet default; whisper small.en kept as fallback)"
  "$APP_BIN" setup --download --model parakeet-tdt-0.6b-v3-int8 || true
  "$APP_BIN" setup --download --model small.en || true
  if [[ ! -f "$HOME/.config/voxtype/config.toml" ]]; then
    mkdir -p "$HOME/.config/voxtype"
    sed "s|__VOICEPOP_ROOT__|$ROOT|g" "$ROOT/config/config.toml" > "$HOME/.config/voxtype/config.toml"
  else
    echo "==> Keeping existing ~/.config/voxtype/config.toml"
  fi
  if [[ -x "$ROOT/bin/voxtype-clean" ]]; then
    chmod +x "$ROOT/bin/voxtype-clean"
  fi
  exit 0
fi

echo "==> Ensuring Homebrew tap + cask"
brew tap peteonrails/voxtype >/dev/null
brew install --cask peteonrails/voxtype/voxtype || true

INSTALLED="$(voxtype --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
echo "    installed: ${INSTALLED:-none}"

if [[ -z "${INSTALLED}" ]] || ! version_ge "$INSTALLED" "$MIN_VER"; then
  echo "==> Cask too old; installing ${MIN_VER} from GitHub release"
  CACHE="$ROOT/.cache"
  mkdir -p "$CACHE"
  BIN="$CACHE/voxtype-${MIN_VER}-macos-universal"
  if [[ ! -f "$BIN" ]]; then
    curl -fsSL -o "$BIN" \
      "https://github.com/peteonrails/voxtype/releases/download/v${MIN_VER}/voxtype-${MIN_VER}-macos-universal"
  fi
  chmod +x "$BIN"
  xattr -dr com.apple.quarantine "$BIN" || true
  PREFIX="$(brew --prefix 2>/dev/null || true)"
  if [[ -n "$PREFIX" && -w "$PREFIX/bin" ]]; then
    rm -f "$PREFIX/bin/voxtype"
    cp "$BIN" "$PREFIX/bin/voxtype"
    chmod +x "$PREFIX/bin/voxtype"
    xattr -dr com.apple.quarantine "$PREFIX/bin/voxtype" || true
  fi
fi

voxtype --version
INSTALLED="$(voxtype --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
if ! version_ge "$INSTALLED" "$MIN_VER"; then
  echo "ERROR: voxtype still < ${MIN_VER}" >&2
  exit 1
fi

if ! has_compiled_parakeet "$(command -v voxtype)"; then
  echo "WARNING: PATH voxtype is Whisper-only. Refusing to run app-bundle so the" >&2
  echo "         custom Parakeet binary is not replaced. Use the rebuilt binary at" >&2
  echo "         $APP_BIN or set VOXTYPE_FORCE=1." >&2
  exit 1
fi

echo "==> Models (Parakeet default; whisper small.en kept as fallback)"
voxtype setup --download --model parakeet-tdt-0.6b-v3-int8 || true
voxtype setup --download --model small.en || true

echo "==> Install config"
mkdir -p "$HOME/.config/voxtype"
if [[ -f "$HOME/.config/voxtype/config.toml" && "$FORCE" != "1" ]]; then
  echo "    keeping existing ~/.config/voxtype/config.toml (VOXTYPE_FORCE=1 to replace)"
else
  sed "s|__VOICEPOP_ROOT__|$ROOT|g" "$ROOT/config/config.toml" > "$HOME/.config/voxtype/config.toml"
fi
if [[ -x "$ROOT/bin/voxtype-clean" ]]; then
  chmod +x "$ROOT/bin/voxtype-clean"
else
  echo "WARNING: $ROOT/bin/voxtype-clean missing or not executable."
  echo "         Build it before dictation post-process will work:"
  echo "         (cd PopcornHUD && swift build -c release && cp .build/release/voxtype-clean ../bin/voxtype-clean)"
fi

echo "==> App bundle (Login Item)"
voxtype setup app-bundle

cat <<'EOF'

TCC checklist (you must click):
1. System Settings → Privacy & Security → Accessibility → enable Voxtype
2. Input Monitoring → enable Voxtype
3. Microphone → enable Voxtype after first recording
PopcornHUD needs no permissions.
Never run the daemon from Terminal for daily use.
EOF
