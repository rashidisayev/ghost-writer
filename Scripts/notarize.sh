#!/bin/bash
# Notarizes build/GhostWriter-<version>.dmg with Apple and staples the ticket.
#
# This is the ONLY thing that makes the app open on someone else's Mac without
# them disabling a security check. Ad-hoc signing and "Apple Development"
# certificates are both blocked by Gatekeeper; neither can be notarized.
#
# Requires, in order:
#   1. Apple Developer Program membership ($99/yr)
#   2. A "Developer ID Application" certificate in your login keychain
#      (Xcode > Settings > Accounts > Manage Certificates > + > Developer ID)
#   3. Stored notary credentials:
#        xcrun notarytool store-credentials "AC_PASSWORD" \
#          --apple-id "you@example.com" \
#          --team-id "TEAMID" \
#          --password "app-specific-password"
#      The app-specific password comes from appleid.apple.com, not your Apple
#      ID password.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE="${NOTARY_PROFILE:-AC_PASSWORD}"
APP="$ROOT/build/GhostWriter.app"

cd "$ROOT"

# --- Preflight: fail early with an actionable message ------------------------

IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
	| grep 'Developer ID Application' | head -1 | sed 's/.*"\(.*\)".*/\1/' || true)}"

if [ -z "$IDENTITY" ]; then
	cat >&2 <<'ERR'
error: no "Developer ID Application" certificate found.

An "Apple Development" certificate is not sufficient — it is for running on
your own devices and cannot be notarized. You need a paid Apple Developer
Program membership, then:

    Xcode > Settings > Accounts > Manage Certificates > + > Developer ID Application

Until then the DMG can only be opened by bypassing Gatekeeper by hand.
ERR
	exit 1
fi

if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
	cat >&2 <<ERR
error: no stored notary credentials under profile "$PROFILE".

    xcrun notarytool store-credentials "$PROFILE" \\
      --apple-id "you@example.com" --team-id "TEAMID" \\
      --password "app-specific-password"
ERR
	exit 1
fi

# --- Sign, package, submit ---------------------------------------------------

echo "==> Building and signing with: $IDENTITY"
CODESIGN_IDENTITY="$IDENTITY" "$ROOT/Scripts/build-app.sh" release

echo "==> Packaging"
"$ROOT/Scripts/make-dmg.sh"

DMG="$(ls -t "$ROOT"/build/GhostWriter-*.dmg | head -1)"
echo "==> Submitting $(basename "$DMG") to Apple"
# --wait blocks until Apple returns a verdict; typically a few minutes.
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait

# Stapling attaches the ticket to the file, so it opens even offline. Without
# this the user needs a working network connection on first launch.
echo "==> Stapling"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo "==> Verifying as Gatekeeper sees it"
spctl --assess --type open --context context:primary-signature -vv "$DMG" || {
	echo "error: Gatekeeper still rejects the image" >&2
	exit 1
}

echo
echo "    $DMG is notarized and stapled."
echo "    It will now open on any Mac without warnings."
