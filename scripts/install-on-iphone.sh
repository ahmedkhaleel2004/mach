#!/bin/zsh
# Builds a signed Release and installs it on the paired iPhone (USB or same Wi-Fi).
# Usage: scripts/install-on-iphone.sh [device-udid]
# Signing: set your team in App/project.yml. If ASC_KEY_PATH, ASC_KEY_ID and ASC_ISSUER_ID are set, Xcode uses that
# App Store Connect key to create the app id and profile without anyone signing in to Xcode.
set -euo pipefail
cd "$(dirname "$0")/../App"

# A git worktree has none of the ignored key files, and an app built without them cannot sign in to Google.
# Borrow the main checkout's.
MAIN="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")/App/Resources"
for key in OAuthClient.json PushRelay.json; do
  [[ -e "Resources/$key" || ! -e "$MAIN/$key" ]] || cp "$MAIN/$key" Resources/
done

command -v xcodegen >/dev/null || brew install xcodegen
xcodegen generate --quiet

DEVICE=${1:-$(xcrun devicectl list devices 2>/dev/null | awk '/physical/ && /iPhone/ && /available/ { for (i=1;i<=NF;i++) if ($i ~ /^[0-9A-F]{8}-[0-9A-F]{16}$/) { print $i; exit } }')}
if [[ -z "$DEVICE" ]]; then
  echo "No reachable iPhone. Unlock it and plug it in (or join the same Wi-Fi), then run again." >&2
  exit 1
fi

AUTH=()
if [[ -n "${ASC_KEY_PATH:-}" ]]; then
  AUTH=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi

echo "==> Building Mach for iPhone (Release)"
xcodebuild -project Mach.xcodeproj -scheme MachPhone -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath ../build/device \
  -allowProvisioningUpdates "${AUTH[@]}" build -quiet

echo "==> Installing on $DEVICE"
xcrun devicectl device install app --device "$DEVICE" ../build/device/Build/Products/Release-iphoneos/Mach.app
xcrun devicectl device process launch --device "$DEVICE" app.blitzmail.ios >/dev/null 2>&1 \
  && echo "==> Launched" || echo "==> Installed. Unlock your iPhone and open Mach."
