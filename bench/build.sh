#!/bin/sh
# Builds a benchmark copy of the app: optimized, with the test hooks compiled in, under its own bundle id
# (com.ahmedkhaleel.machbench.*) so it shares no settings, caches or keychain items with the installed Mach.
#
#   bench/build.sh mac            -> prints the path of Mach.app
#   bench/build.sh ios            -> prints the path of the simulator Mach.app
#   DD=build/dd-mine bench/build.sh mac     to use another build folder
#
# A benchmark build refuses to start unless MACH_DATA_DIR is set, so it cannot open real mail.
set -eu
cd "$(dirname "$0")/.."
platform="${1:-mac}"
for file in OAuthClient.json; do
  [ -f "App/Resources/$file" ] || printf '{"installed":{"client_id":"bench.invalid","client_secret":"x"}}' > "App/Resources/$file"
done
mkdir -p build
(cd App && xcodegen generate >/dev/null)
common="-project App/Mach.xcodeproj -configuration Release MACH_BUNDLE_BASE=com.ahmedkhaleel.machbench CODE_SIGNING_ALLOWED=NO"
flags='SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) BENCH'
if [ "$platform" = mac ]; then
  dd="${DD:-build/dd-mac}"
  xcodebuild $common -scheme Mach -derivedDataPath "$dd" "$flags" build > "$dd.log" 2>&1 || { tail -40 "$dd.log"; exit 1; }
  echo "$PWD/$dd/Build/Products/Release/Mach.app"
else
  dd="${DD:-build/dd-ios}"
  xcodebuild $common -scheme MachPhone -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
    -derivedDataPath "$dd" "$flags" build > "$dd.log" 2>&1 || { tail -40 "$dd.log"; exit 1; }
  echo "$PWD/$dd/Build/Products/Release-iphonesimulator/Mach.app"
fi
grep -E "warning:" "$dd.log" | grep -v "/checkouts/\|SourcePackages" | sort -u | sed 's/^/WARNING /' >&2 || true
