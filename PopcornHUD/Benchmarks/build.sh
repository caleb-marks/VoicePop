#!/bin/bash
# Builds the optimized (-O) benchmark and analysis tools without touching Package.swift.
#
#   PopcornHUD/Benchmarks/build.sh [out-dir]      (default: PopcornHUD/.build/bench)
#
# Produces:
#   state-watcher-bench   polling baseline vs event-driven StateWatcher on an isolated fixture
#   hud-publish-bench     NSHostingView<PopcornView> publication cost, offscreen
#   timing-report         p50/p95 per pipeline interval from a VoicePop timing log
#
# Nothing here launches VoicePop, talks to the running Voxtype daemon, or reads ~/.config.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
pkg="$(cd "$here/.." && pwd)"
out="${1:-$pkg/.build/bench}"
mkdir -p "$out"
flags=(-O -wmo -target arm64-apple-macosx13.0)

echo "building PopcornCore (-O)…"
swiftc "${flags[@]}" -parse-as-library -emit-library -static -module-name PopcornCore \
  -emit-module -emit-module-path "$out/PopcornCore.swiftmodule" \
  "$pkg"/Sources/PopcornCore/*.swift -o "$out/libPopcornCore.a"

echo "building PopcornArt (-O)…"
swiftc "${flags[@]}" -parse-as-library -emit-library -static -module-name PopcornArt \
  -emit-module -emit-module-path "$out/PopcornArt.swiftmodule" -I "$out" \
  "$pkg"/Sources/PopcornArt/*.swift -o "$out/libPopcornArt.a"

echo "building state-watcher-bench…"
swiftc "${flags[@]}" -parse-as-library -I "$out" -L "$out" -lPopcornCore \
  "$here/StateWatcherBench.swift" -o "$out/state-watcher-bench"

echo "building hud-publish-bench…"
swiftc "${flags[@]}" -parse-as-library -I "$out" -L "$out" -lPopcornCore -lPopcornArt \
  "$here/HUDPublishBench.swift" "$pkg/Sources/PopcornHUD/PopcornView.swift" -o "$out/hud-publish-bench"

echo "building timing-report…"
swiftc "${flags[@]}" -parse-as-library -I "$out" -L "$out" -lPopcornCore \
  "$here/TimingReportMain.swift" -o "$out/timing-report"

echo "done: $out"
