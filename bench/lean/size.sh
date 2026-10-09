#!/bin/sh
# How big the app is and how much it has to load before our code runs. Looks at a built app; never starts it.
#
#   bench/lean/size.sh <path to Mach.app>            prints one "name value" line per measure
#   bench/lean/size.sh build mac|ios [KEY=VALUE ...]       builds the app people use (Release, no BENCH flag, unsigned)
#                                                          into build/dd-size-<platform> first, then measures it.
#                                                          Extra KEY=VALUE go to xcodebuild, to try a build setting.
#
# The app built by `build` opens the real mailbox if started. This script never starts it; neither should you.
set -eu
cd "$(dirname "$0")/../.."
if [ "${1:-}" = build ]; then
  platform="$2"; shift 2
  [ -f App/Resources/OAuthClient.json ] || printf '{"installed":{"client_id":"bench.invalid","client_secret":"x"}}' > App/Resources/OAuthClient.json
  (cd App && xcodegen generate >/dev/null)
  dd="${DD:-build/dd-size-$platform}"
  mkdir -p build
  if [ "$platform" = mac ]; then
    xcodebuild -project App/Mach.xcodeproj -configuration Release CODE_SIGNING_ALLOWED=NO -scheme Mach -derivedDataPath "$dd" "$@" build > "$dd.log" 2>&1 || { tail -40 "$dd.log"; exit 1; }
    app="$dd/Build/Products/Release/Mach.app"
  else
    xcodebuild -project App/Mach.xcodeproj -configuration Release CODE_SIGNING_ALLOWED=NO -scheme MachPhone -sdk iphoneos -destination 'generic/platform=iOS' \
      -derivedDataPath "$dd" "$@" build > "$dd.log" 2>&1 || { tail -40 "$dd.log"; exit 1; }
    app="$dd/Build/Products/Release-iphoneos/Mach.app"
  fi
  echo "warnings_own_code $(grep -E 'warning:' "$dd.log" | grep -v '/checkouts/\|SourcePackages\|appintentsmetadataprocessor' | grep -E '^/' | sort -u | wc -l | tr -d ' ')"
  echo "warnings_outside_ThreadWeb $(grep -E 'warning:' "$dd.log" | grep -v '/checkouts/\|SourcePackages\|appintentsmetadataprocessor\|ThreadWeb.swift' | grep -E '^/' | sort -u | wc -l | tr -d ' ')"
else
  app="$1"
fi
if [ -d "$app/Contents/MacOS" ]; then exe="$app/Contents/MacOS/Mach"; else exe="$app/Mach"; fi
echo "app $app"
echo "bundle_kb $(du -sk "$app" | cut -f1)"
echo "bundle_bytes $(find "$app" -type f -exec stat -f %z {} + | awk '{s+=$1} END {print s}')"
echo "executable_bytes $(stat -f %z "$exe")"
echo "text_segment_bytes $(size -m "$exe" | awk '/Segment __TEXT:/ {print $3}')"
echo "data_segments_bytes $(size -m "$exe" | awk '/Segment __DATA/ {s+=$3} END {print s}')"
echo "linkedit_bytes $(size -m "$exe" | awk '/Segment __LINKEDIT:/ {print $3}')"
echo "dylibs_linked $(otool -L "$exe" | tail -n +2 | wc -l | tr -d ' ')"
echo "dylibs_embedded $(find "$app" -name '*.dylib' -o -name '*.framework' | wc -l | tr -d ' ')"
echo "static_initializers $(otool -s __DATA_CONST __mod_init_func "$exe" 2>/dev/null | grep -c '^0' || true) (rows of 2 pointers; __init_offs: $(size -m "$exe" | awk '/__init_offs/ {print $3/4}'))"
echo "symbols $(nm "$exe" 2>/dev/null | wc -l | tr -d ' ')"
echo "bench_code_symbols $(nm "$exe" 2>/dev/null | xcrun swift-demangle | grep -c 'SyntheticMailbox\|Mach.Bench\b\|enum Bench' || true)"
echo "bench_code_strings $(strings -a "$exe" | grep -c 'bench.jsonl\|SyntheticMailbox\|MACH_DEBUG_CHANNEL\|BENCH build' || true)"
echo "assets_car_bytes $(find "$app" -name Assets.car -exec stat -f %z {} + | head -1)"
echo "icns_bytes $(find "$app" -name '*.icns' -exec stat -f %z {} + | head -1)"
echo "thread_html_bytes $(find "$app" -name thread.html -exec stat -f %z {} + | head -1)"
if [ -d "$app/PlugIns" ]; then echo "notify_extension_bytes $(find "$app/PlugIns" -type f -exec stat -f %z {} + | awk '{s+=$1} END {print s}')"; fi
