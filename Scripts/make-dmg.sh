#!/bin/bash
# Packages build/GhostWriter.app into a distributable .dmg.
#
# IMPORTANT: this produces an AD-HOC SIGNED disk image. Gatekeeper will block it
# on any Mac but the one that built it — see the warning printed at the end and
# BUILD.md step 6. Proper distribution needs a Developer ID certificate and
# notarization; this script is for sharing with people you can also send
# instructions to.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/GhostWriter.app"
NAME="GhostWriter"
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
	"$APP/Contents/Info.plist" 2>/dev/null || echo "0.1")"
DMG="$ROOT/build/${NAME}-${VERSION}.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cd "$ROOT"

[ -d "$APP" ] || { echo "error: no app at $APP — run Scripts/build-app.sh first" >&2; exit 1; }

echo "==> Staging"
cp -R "$APP" "$STAGE/"

# Running the app accrues extended attributes that were not there at signing
# time — TCC writes com.apple.macl onto a bundle holding a permission, and
# Finder adds its own. codesign --strict rejects a bundle carrying them. Strip
# them from the COPY: they are not covered by the signature, so removing them
# leaves it valid, and the original stays untouched for local runs.
xattr -cr "$STAGE/GhostWriter.app"

echo "==> Verifying signature before packaging"
codesign --verify --deep --strict "$STAGE/GhostWriter.app" || {
	echo "error: app fails signature verification; packaging it would ship a broken build" >&2
	exit 1
}
# The drag-to-install convention. Without this the user has to know to move it
# to /Applications themselves, and an app run from the mounted image will lose
# its Accessibility grant every time the image is remounted.
ln -s /Applications "$STAGE/Applications"

# A README the recipient will actually see when the image mounts.
cat > "$STAGE/READ ME FIRST.txt" <<'NOTE'
Ghost Writer — installation

1. Drag GhostWriter.app onto the Applications folder shown here.
2. Open Applications and launch Ghost Writer.

macOS will very likely refuse to open it the first time, saying the app is
damaged or from an unidentified developer. That is Gatekeeper reacting to the
fact that this build is not signed with a paid Apple Developer certificate. The
app is not damaged.

To open it anyway:

    Right-click GhostWriter.app  ->  Open  ->  Open

If macOS still refuses, run this in Terminal:

    xattr -dr com.apple.quarantine /Applications/GhostWriter.app

Ghost Writer needs Accessibility permission to read and rewrite the text field you are
typing in. It asks for this on first launch and explains why. It never reads
password fields, terminals, or password managers.

You also need your own OpenAI API key, with credit on the account. Ghost Writer sends
text directly to OpenAI — there is no Ghost Writer server.
NOTE

echo "==> Building disk image"
rm -f "$DMG"
hdiutil create \
	-volname "Ghost Writer" \
	-srcfolder "$STAGE" \
	-ov -format UDZO \
	"$DMG" >/dev/null

echo "==> Signing disk image (ad-hoc)"
codesign --force --sign - "$DMG"

SIZE="$(du -h "$DMG" | cut -f1 | tr -d ' ')"
echo "==> Built $DMG ($SIZE)"
echo
cat <<'WARN'
    ---------------------------------------------------------------
    THIS BUILD IS AD-HOC SIGNED AND NOT NOTARIZED.

    Anyone you send it to WILL hit Gatekeeper. They must right-click
    -> Open, or strip the quarantine attribute by hand. The mounted
    image includes instructions, but expect questions.

    For real distribution you need:
      - Apple Developer Program membership ($99/yr)
      - codesign with "Developer ID Application: NAME (TEAMID)"
      - xcrun notarytool submit + xcrun stapler staple

    See BUILD.md step 6.
    ---------------------------------------------------------------
WARN
