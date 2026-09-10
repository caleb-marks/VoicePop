#!/bin/bash
# Restart Voxtype daemon via app bundle (preserves TCC identity).
# Then suppress Voxtype's emoji menu bar parent so PopcornHUD owns the tray icon.
set -euo pipefail
pkill -x voxtype-bin 2>/dev/null || true
sleep 1
open -a Voxtype

# AppLaunch = daemon child + menubar parent. Drop the parent only.
suppress_voxtype_menubar() {
  local pid args
  while read -r pid args; do
    [[ -z "${pid:-}" ]] && continue
    case "$args" in
      */voxtype-bin|voxtype-bin)
        kill "$pid" 2>/dev/null || true
        ;;
      */voxtype-bin\ menubar|voxtype-bin\ menubar)
        kill "$pid" 2>/dev/null || true
        ;;
    esac
  done < <(ps -axo pid=,args= | grep -F 'voxtype-bin' | grep -v grep || true)
}

# Voxtype may take a moment to spawn; retry briefly.
for _ in 1 2 3 4 5 6; do
  sleep 0.5
  suppress_voxtype_menubar
done

echo "Voxtype restarted (emoji tray suppressed; PopcornHUD owns menu bar)"
