#!/bin/bash
# Ad-hoc sign a Minutia build so every embedded Mach-O carries the SAME identity
# as the outer app. Hardened runtime enforces library validation, so an ad-hoc app
# that embeds a Developer ID signed Sparkle.framework dies at launch with
# "mapping process and mapped file have different Team IDs".
set -euo pipefail

APP="${1:?usage: adhoc-sign.sh /path/to/Minutia.app}"
IDENTITY="-"
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
FW="$FRAMEWORK/Versions/B"

[ -d "$FRAMEWORK" ] || { echo "no Sparkle.framework in $APP"; exit 1; }

echo "Signing nested Sparkle code innermost-first"
if [ -d "$FW/XPCServices" ]; then
  find "$FW/XPCServices" -maxdepth 1 -name '*.xpc' -print0 | while IFS= read -r -d '' xpc; do
    case "$(basename "$xpc")" in
      Downloader.xpc)
        codesign -f -o runtime --preserve-metadata=entitlements -s "$IDENTITY" "$xpc"
        ;;
      *)
        codesign -f -o runtime -s "$IDENTITY" "$xpc"
        ;;
    esac
  done
fi

for helper in "$FW/Autoupdate" "$FW/Updater.app"; do
  [ -e "$helper" ] && codesign -f -o runtime -s "$IDENTITY" "$helper"
done

codesign -f -o runtime -s "$IDENTITY" "$FRAMEWORK"

echo "Signing the app last"
ENTITLEMENTS="$(dirname "$0")/../Minutia/Minutia-adhoc.entitlements"
codesign -f -o runtime --entitlements "$ENTITLEMENTS" -s "$IDENTITY" "$APP"

echo "Verifying"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -2
echo "Team IDs present in the bundle:"
codesign -dv "$APP" 2>&1 | grep -E "TeamIdentifier" || true
