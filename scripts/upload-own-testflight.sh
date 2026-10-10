#!/bin/zsh
# Your own iPhone build (the one scripts/install-on-iphone.sh makes: your Google key, your push relay), sent to
# yourself through TestFlight, for when the phone is nowhere near the Mac.
#
#   scripts/upload-own-testflight.sh [version]
#
# This build has your private keys inside it. It is for an internal TestFlight group (people on your own App Store
# Connect team) and nobody else: never add it to an outside group and never send it to review. What the public gets
# is scripts/upload-testflight.sh.
#
# Needs the same App Store Connect key as that script: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH.
set -euo pipefail
cd "$(dirname "$0")/../App"
: "${ASC_KEY_ID:?}" "${ASC_ISSUER_ID:?}" "${ASC_KEY_PATH:?}"
version=${1:-}
build=${BUILD_NUMBER:-$(date -u +%y%m%d%H%M)}
out="$PWD/../build/own"
team=$(awk '/DEVELOPMENT_TEAM:/ { print $2; exit }' project.yml)
mkdir -p "$out"

MAIN="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")/App/Resources"
for key in OAuthClient.json PushRelay.json; do
  if [[ -e "$MAIN/$key" ]] && { [[ ! -e "Resources/$key" ]] || grep -q 'bench.invalid' "Resources/$key"; }; then cp "$MAIN/$key" Resources/; fi
  [[ -e "Resources/$key" ]] || { echo "No App/Resources/$key." >&2; exit 1; }
done
! grep -q 'bench.invalid' Resources/OAuthClient.json || { echo "App/Resources/OAuthClient.json is the benchmark's dummy key." >&2; exit 1; }

# A TestFlight build gets its pushes from Apple's real service, not the one for builds installed from Xcode.
cp Resources/PushRelay.json "$out/PushRelay.kept.json"
restore() { [[ ! -e "$out/PushRelay.kept.json" ]] || mv -f "$out/PushRelay.kept.json" Resources/PushRelay.json }
trap restore EXIT
plutil -replace sandbox -bool false Resources/PushRelay.json

command -v xcodegen >/dev/null || brew install xcodegen
xcodegen generate --quiet
SIGN=(-allowProvisioningUpdates -authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
VERSION=(CURRENT_PROJECT_VERSION="$build")
[[ -z "$version" ]] || VERSION+=(MARKETING_VERSION="$version")

echo "==> Archiving your own Mach (build $build)"
archive="$out/Mach.xcarchive"
rm -rf "$archive" "$out/export"
xcodebuild archive -project Mach.xcodeproj -scheme MachPhone -configuration Release -destination 'generic/platform=iOS' \
  -archivePath "$archive" -derivedDataPath "$out/dd" "${VERSION[@]}" "${SIGN[@]}" > "$out/archive.log" 2>&1 \
  || { grep -E "error:" "$out/archive.log" >&2 || tail -30 "$out/archive.log" >&2; exit 1; }
restore
app="$archive/Products/Applications/Mach.app"
[[ "$(plutil -extract sandbox raw -o - "$app/PushRelay.json")" == false ]] || { echo "NOT uploading: the relay file still asks for test pushes" >&2; exit 1; }
[[ -d "$app/PlugIns" ]] || { echo "NOT uploading: the notification extension is missing" >&2; exit 1; }

echo "==> Signing and uploading to App Store Connect"
cat > "$out/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>app-store-connect</string>
	<key>destination</key>
	<string>upload</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>teamID</key>
	<string>$team</string>
	<key>manageAppVersionAndBuildNumber</key>
	<false/>
	<key>uploadSymbols</key>
	<true/>
</dict>
</plist>
PLIST
xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist "$out/ExportOptions.plist" -exportPath "$out/export" \
  "${SIGN[@]}" > "$out/export.log" 2>&1 || { grep -E "error:|Error" "$out/export.log" >&2 || tail -30 "$out/export.log" >&2; exit 1; }
echo "==> Uploaded build $build. It appears in TestFlight once Apple has processed it (a few minutes)."
