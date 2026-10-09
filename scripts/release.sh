#!/bin/sh
# Builds, signs, notarizes and publishes a Mac release, and the update feed the app reads.
#
#   scripts/release.sh 1.0.1
#
# Needs: a "Developer ID Application" certificate in the keychain, an App Store Connect API key for notarizing
# (ASC_KEY_PATH, ASC_KEY_ID, ASC_ISSUER_ID), Sparkle's tools (SPARKLE_BIN, from a Sparkle release) with the update
# signing key in a file (SPARKLE_KEY_FILE) or in the keychain under the account "mach", and the GitHub CLI signed in.
set -eu
version="${1:?usage: scripts/release.sh <version>}"
cd "$(dirname "$0")/.."
: "${ASC_KEY_PATH:?}" "${ASC_KEY_ID:?}" "${ASC_ISSUER_ID:?}" "${SPARKLE_BIN:?}"
identity="${SIGN_IDENTITY:-Developer ID Application}"
repo="${RELEASE_REPO:-ahmedkhaleel2004/mach}"
# A number that only ever grows, which is how the app tells a newer build from its own.
build="$(date -u +%y%m%d%H%M)"
out="$PWD/build/release"
rm -rf "$out"; mkdir -p "$out/dmg" "$out/feed"

# A public build carries nobody's Google key or relay: each person supplies their own in the app's data folder.
hidden="$out/hidden"; mkdir -p "$hidden"
restore() { for f in OAuthClient.json PushRelay.json; do [ -f "$hidden/$f" ] && mv "$hidden/$f" "App/Resources/$f"; done; true; }
trap restore EXIT
for f in OAuthClient.json PushRelay.json; do [ -f "App/Resources/$f" ] && mv "App/Resources/$f" "$hidden/$f"; done

echo "==> Building $version ($build)"
(cd App && xcodegen generate >/dev/null)
xcodebuild -project App/Mach.xcodeproj -scheme Mach -configuration Release -derivedDataPath "$out/dd" \
  MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build" CODE_SIGNING_ALLOWED=NO build > "$out/build.log" 2>&1 || { tail -30 "$out/build.log"; exit 1; }
restore
app="$out/dmg/Mach.app"
cp -R "$out/dd/Build/Products/Release/Mach.app" "$app"
if ls "$app/Contents/Resources" | grep -qE "^(OAuthClient|PushRelay)\.json$"; then echo "a private key file is inside the app"; exit 1; fi

echo "==> Signing"
# SIGN_KEYCHAIN picks the keychain to take the certificate from, when it is in more than one.
keychain="${SIGN_KEYCHAIN:+--keychain $SIGN_KEYCHAIN}"
sign() { codesign --force --timestamp --options runtime $keychain --sign "$identity" "$@"; }
sparkle="$app/Contents/Frameworks/Sparkle.framework/Versions/B"
sign "$sparkle/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$sparkle/XPCServices/Downloader.xpc"
sign "$sparkle/Autoupdate"
sign "$sparkle/Updater.app"
sign "$app/Contents/Frameworks/Sparkle.framework"
find "$app/Contents/Frameworks" -maxdepth 1 -name "*.dylib" -exec codesign --force --timestamp --options runtime $keychain --sign "$identity" {} \;
sign "$app"
codesign --verify --deep --strict "$app"

echo "==> Disk image"
ln -s /Applications "$out/dmg/Applications"
dmg="$out/feed/Mach-$version.dmg"
hdiutil create -volname "Mach" -srcfolder "$out/dmg" -ov -format UDZO "$dmg" >/dev/null
codesign --force --timestamp $keychain --sign "$identity" "$dmg"

echo "==> Notarizing (a few minutes)"
xcrun notarytool submit "$dmg" --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" --wait > "$out/notary.log" 2>&1 || { cat "$out/notary.log"; exit 1; }
grep -q "status: Accepted" "$out/notary.log" || { cat "$out/notary.log"; exit 1; }
xcrun stapler staple "$dmg" >/dev/null
spctl --assess --type open --context context:primary-signature "$dmg"

echo "==> Update feed"
# The update signing key: from a file (SPARKLE_KEY_FILE), else from the keychain under the account "mach".
if [ -n "${SPARKLE_KEY_FILE:-}" ]; then key="--ed-key-file $SPARKLE_KEY_FILE"; else key="--account mach"; fi
"$SPARKLE_BIN/generate_appcast" $key --download-url-prefix "https://github.com/$repo/releases/download/v$version/" \
  --link "https://github.com/$repo" -o "$out/feed/appcast.xml" "$out/feed" >/dev/null
grep -q "sparkle:edSignature" "$out/feed/appcast.xml"

if [ "${PUBLISH:-1}" = 1 ]; then
  echo "==> Publishing v$version"
  gh release create "v$version" "$dmg" "$out/feed/appcast.xml" --repo "$repo" --title "Mach $version" --notes "${NOTES:-Mach $version}"
fi
echo "$dmg"
