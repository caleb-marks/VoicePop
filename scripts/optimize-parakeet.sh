#!/bin/bash
# Build a low-memory copy of the Parakeet int8 model for Voxtype.
#
# ONNX Runtime normally copies the model weights into RAM and then makes a
# second "prepacked" copy laid out for fast CPU math (~1.8 GB peak per
# dictation). This script runs the same graph optimizations once, offline, and
# saves the weights AND the prepacked copy to a sidecar .data file. Voxtype then
# memory-maps that file, so the weights live in the reclaimable file cache
# instead of the daemon's own memory (~120 MB peak).
#
# Prepacked blobs are tied to the ONNX Runtime version and CPU. Re-run this
# after rebuilding Voxtype against a different ORT (check ORT_VERSION below).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ORT_VERSION="${ORT_VERSION:-1.24.2}" # ort-sys 2.0.0-rc.12 bundles ORT 1.24.2
MODELS="$HOME/.local/share/voxtype/models"
SRC="$MODELS/parakeet-tdt-0.6b-v3-int8"
DST="$MODELS/parakeet-tdt-0.6b-v3-int8-prepacked"
VENV="$ROOT/.cache/ort-venv"

[[ -f "$SRC/encoder-model.int8.onnx" ]] || { echo "missing $SRC" >&2; exit 1; }

if [[ ! -x "$VENV/bin/python" ]]; then
  python3 -m venv "$VENV"
fi
"$VENV/bin/pip" -q install "onnxruntime==$ORT_VERSION"

TMP="$(mktemp -d "$MODELS/.prepacked.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

"$VENV/bin/python" - "$SRC" "$TMP" <<'EOF'
import sys, onnxruntime as ort
src, dst = sys.argv[1], sys.argv[2]
for name in ("encoder-model.int8.onnx", "decoder_joint-model.int8.onnx"):
    so = ort.SessionOptions()
    # Voxtype's parakeet-rs uses GraphOptimizationLevel::Level3 == ORT_ENABLE_LAYOUT.
    so.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_LAYOUT
    so.optimized_model_filepath = f"{dst}/{name}"
    so.add_session_config_entry("session.optimized_model_external_initializers_file_name", f"{name}.data")
    so.add_session_config_entry("session.optimized_model_external_initializers_min_size_in_bytes", "1024")
    so.add_session_config_entry("session.save_external_prepacked_constant_initializers", "1")
    ort.InferenceSession(f"{src}/{name}", so, providers=["CPUExecutionProvider"])
    print("optimized", name)
EOF

cp "$SRC/vocab.txt" "$SRC/config.json" "$TMP/"
rm -rf "$DST"
mv "$TMP" "$DST"
trap - EXIT
du -sh "$DST"

cat <<EOF

Use it:
  /Applications/Voxtype.app/Contents/MacOS/voxtype-bin config set parakeet.model $(basename "$DST")
  $ROOT/scripts/restart-voxtype.sh
Roll back:
  /Applications/Voxtype.app/Contents/MacOS/voxtype-bin config set parakeet.model $(basename "$SRC")
EOF
