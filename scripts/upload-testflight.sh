#!/bin/zsh
# Archives the iPhone app the way it goes to the App Store (the Store configuration: no push relay, see
# App/project.yml) and uploads it to App Store Connect, where it shows up in TestFlight.
#
#   scripts/upload-testflight.sh [version]        version defaults to the one in App/project.yml
#
# Needs an App Store Connect API key with the Admin role: ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH (the .p8 file).
# With it Xcode signs by itself: it creates the distribution certificate and the profiles the first time.
# The app record must already exist on App Store Connect (bundle id com.ahmedkhaleel.mach.ios).
#
#   BUILD_NUMBER=7 ...      the build number; by default the time, so every upload has a new one
#   ARCHIVE_ONLY=1 ...      archive unsigned and check the result, then stop. Touches no Apple account, needs no key.
set -euo pipefail
cd "$(dirname "$0")/../App"
version=${1:-}
build=${BUILD_NUMBER:-$(date -u +%y%m%d%H%M)}
out="$PWD/../build/store"
key=Resources/OAuthClient.json
team=$(awk '/DEVELOPMENT_TEAM:/ { print $2; exit }' project.yml)

if [[ -z "${ARCHIVE_ONLY:-}" ]]; then
  : "${ASC_KEY_ID:?set ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH, or ARCHIVE_ONLY=1}" "${ASC_ISSUER_ID:?}" "${ASC_KEY_PATH:?}"
  [[ -f "$ASC_KEY_PATH" ]] || { echo "No App Store Connect key at $ASC_KEY_PATH" >&2; exit 1; }
fi

# A git worktree has none of the ignored key files. Borrow the main checkout's Google key (never its relay file).
MAIN="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")/App/Resources"
[[ -e "$key" || ! -e "$MAIN/OAuthClient.json" ]] || cp "$MAIN/OAuthClient.json" "$key"
[[ -e "$key" ]] || { echo "No Google key. Save the iOS client as App/$key: {\"client_id\": \"….apps.googleusercontent.com\"}" >&2; exit 1; }

# The App Store build carries the iOS client's id and nothing else. A file that also holds the Mac's Desktop key
# (with its secret) is put aside for the length of the build, and only the iOS id goes in.
id=$(plutil -extract ios.client_id raw -o - "$key" 2>/dev/null || plutil -extract client_id raw -o - "$key" 2>/dev/null || true)
if [[ "$id" != ?*.apps.googleusercontent.com ]]; then
  echo "App/$key has no iOS client in it. Add the iOS client's id: {\"client_id\": \"….apps.googleusercontent.com\"}," >&2
  echo "or, beside the Desktop key in the same file, \"ios\": {\"client_id\": \"….apps.googleusercontent.com\"}." >&2
  exit 1
fi
mkdir -p "$out"
restore() { [[ ! -e "$out/OAuthClient.kept.json" ]] || mv -f "$out/OAuthClient.kept.json" "$key" }
trap restore EXIT
if grep -qi secret "$key" || ! plutil -extract client_id raw -o - "$key" >/dev/null 2>&1; then
  cp "$key" "$out/OAuthClient.kept.json"
  printf '{"client_id":"%s"}\n' "$id" > "$key"
fi

command -v xcodegen >/dev/null || brew install xcodegen
xcodegen generate --quiet

SIGN=(-allowProvisioningUpdates)
if [[ -n "${ARCHIVE_ONLY:-}" ]]; then
  SIGN=(CODE_SIGNING_ALLOWED=NO)
else
  SIGN+=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi
VERSION=(CURRENT_PROJECT_VERSION="$build")
[[ -z "$version" ]] || VERSION+=(MARKETING_VERSION="$version")

echo "==> Archiving Mach for the App Store (build $build)"
archive="$out/Mach.xcarchive"
rm -rf "$archive" "$out/export"
xcodebuild archive -project Mach.xcodeproj -scheme MachPhone -configuration Store -destination 'generic/platform=iOS' \
  -archivePath "$archive" -derivedDataPath "$out/dd" "${VERSION[@]}" "${SIGN[@]}" > "$out/archive.log" 2>&1 \
  || { grep -E "error:" "$out/archive.log" >&2 || tail -30 "$out/archive.log" >&2; exit 1; }
restore

echo "==> Checking what was built"
app="$archive/Products/Applications/Mach.app"
fail() { echo "NOT uploading: $1" >&2; exit 1 }
[[ -f "$app/OAuthClient.json" ]] || fail "the app has no Google key in it"
! grep -qi secret "$app/OAuthClient.json" || fail "a client secret is inside the app"
[[ ! -e "$app/PushRelay.json" ]] || fail "the push relay's address is inside the app"
[[ ! -d "$app/PlugIns" ]] || fail "the notification extension is inside the app"
[[ -f "$app/PrivacyInfo.xcprivacy" ]] || fail "the privacy manifest is missing"
info=$(plutil -p "$app/Info.plist")
[[ "$info" != *remote-notification* ]] || fail "the remote-notification background mode is still declared"
[[ "$info" != *'"NSAllowsArbitraryLoads" =>'* ]] || fail "every connection is exempt from App Transport Security"
[[ "$info" != *NSLocalNetworkUsageDescription* ]] || fail "the local network is still asked for"
[[ "$(plutil -extract CFBundleVersion raw -o - "$app/Info.plist")" == "$build" ]] || fail "the build number is not $build"
if [[ -z "${ARCHIVE_ONLY:-}" ]]; then
  ! codesign -d --entitlements - --xml "$app" 2>/dev/null | grep -q aps-environment || fail "the app is signed for push"
fi
echo "    $(plutil -extract CFBundleShortVersionString raw -o - "$app/Info.plist") ($build), $(du -sh "$app" | cut -f1 | tr -d ' ')"

if [[ -n "${ARCHIVE_ONLY:-}" ]]; then
  echo "==> Archived, unsigned, not uploaded: $archive"
  exit 0
fi

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
