#!/usr/bin/env bash
# App Store screenshots, captured from a clean simulator.
#
#   ./scripts/screenshots.sh [device-name]
#
# Default device is the 6.9" iPhone, which is the size App Store Connect
# requires (1320 x 2868). The app's data is wiped first so the shots don't pick
# up whatever earlier test runs left in the store, and the status bar is pinned
# to 9:41 with full bars, the way Apple's own screenshots look.
set -euo pipefail

DEVICE_NAME="${1:-iPhone 16 Pro Max}"
BUNDLE_ID="com.doony.cellar"
OUT_DIR="$(cd "$(dirname "$0")/.." && pwd)/screenshots"
RESULT_BUNDLE="$(mktemp -d)/screenshots.xcresult"

cd "$(dirname "$0")/.."

DEVICE_ID=$(xcrun simctl list devices available \
  | grep -F "$DEVICE_NAME (" | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
if [ -z "$DEVICE_ID" ]; then
  echo "No available simulator called '$DEVICE_NAME'." >&2
  exit 1
fi
echo "Device: $DEVICE_NAME ($DEVICE_ID)"

xcrun simctl boot "$DEVICE_ID" 2>/dev/null || true
xcrun simctl bootstatus "$DEVICE_ID" -b >/dev/null 2>&1 || true
# A clean store: yesterday's test wines must not appear on the App Store page.
xcrun simctl uninstall "$DEVICE_ID" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl status_bar "$DEVICE_ID" override \
  --time "9:41" --batteryState charged --batteryLevel 100 \
  --cellularMode active --cellularBars 4 --wifiMode active --wifiBars 3 2>/dev/null || true

xcodebuild -project Cellar.xcodeproj -scheme Cellar \
  -destination "id=$DEVICE_ID" \
  -only-testing:CellarUITests/CellarScreenshotTests \
  -resultBundlePath "$RESULT_BUNDLE" \
  test

rm -rf "$OUT_DIR"; mkdir -p "$OUT_DIR"
xcrun xcresulttool export attachments --path "$RESULT_BUNDLE" --output-path "$OUT_DIR" >/dev/null

# The export names files by attachment id; rename them back to 01-cellar.png etc.
python3 - "$OUT_DIR" <<'PY'
import json, os, re, shutil, sys
out = sys.argv[1]
manifest = os.path.join(out, "manifest.json")
if not os.path.exists(manifest):
    print("no manifest.json — attachments not exported"); sys.exit(1)
for test in json.load(open(manifest)):
    for att in test.get("attachments", []):
        name = att.get("suggestedHumanReadableName") or att.get("exportedFileName")
        src = os.path.join(out, att["exportedFileName"])
        if not name or not os.path.exists(src):
            continue
        if not name.lower().endswith(".png"):
            name += ".png"
        # Exported names carry "_0_<uuid>"; the App Store wants readable files.
        name = re.sub(r"_\d+_[0-9A-Fa-f-]{36}(\.png)$", r"\1", name)
        shutil.move(src, os.path.join(out, name))
os.remove(manifest)
PY

echo
echo "Screenshots in $OUT_DIR:"
for f in "$OUT_DIR"/*.png; do
  printf '  %-28s %s\n' "$(basename "$f")" "$(sips -g pixelWidth -g pixelHeight "$f" | awk '/pixel/ {printf "%s ", $2}')"
done
echo
echo "Reset the simulator's status bar with:"
echo "  xcrun simctl status_bar $DEVICE_ID clear"
