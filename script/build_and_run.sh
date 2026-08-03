#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Doppel"
BUNDLE_ID="ai.doppel.menubar"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/Doppel"

# The installed and development copies share one single-instance lock. Stop
# whichever copy is running before staging and opening the fresh development
# bundle, otherwise `open` succeeds while the new process exits immediately.
pkill -x Doppel >/dev/null 2>&1 || true
"$ROOT_DIR/app/build-app.zsh" "$DIST_DIR"

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    /usr/bin/lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"Doppel\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 2
    pgrep -f "^$APP_BINARY$" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
