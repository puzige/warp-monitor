#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="${APP_NAME:-WARP Monitor}"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
DMG_PATH="$DIST_DIR/WARP-Monitor.dmg"
VOLUME_NAME="${VOLUME_NAME:-WARP Monitor}"

if [[ ! -d "$APP_DIR" ]]; then
    "$ROOT_DIR/Scripts/build_app.sh"
fi

if ! command -v hdiutil >/dev/null 2>&1; then
    echo "hdiutil is required to create a DMG on macOS" >&2
    exit 1
fi

mkdir -p "$DIST_DIR"
STAGE_DIR="$(mktemp -d "$DIST_DIR/dmg-stage.XXXXXX")"
trap 'rm -rf "$STAGE_DIR"' EXIT

ditto "$APP_DIR" "$STAGE_DIR/$APP_NAME.app"
ln -s /Applications "$STAGE_DIR/Applications"

rm -f "$DMG_PATH"
hdiutil create \
    -volname "$VOLUME_NAME" \
    -srcfolder "$STAGE_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

echo "Built $DMG_PATH"
