#!/bin/bash
# Compatibility entry point: installation is handled by the app.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
open "$HERE/VoicePop.app"
