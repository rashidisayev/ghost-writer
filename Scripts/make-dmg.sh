#!/bin/bash
# Packages build/GhostWriter.app into a styled, drag-to-install .dmg:
# a custom background with an arrow to Applications, positioned icons, a
# branded volume icon, and hidden window chrome.
#
# IMPORTANT: the app inside is only as trusted as its signature. An ad-hoc or
# "Apple Development" build is blocked by Gatekeeper on every Mac but the one
# that built it — run Scripts/notarize.sh with a Developer ID for a build that
# opens cleanly elsewhere.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/GhostWriter.app"
VOLNAME="Ghost Writer"
# The app is copied into the image under its display name. Only the .app folder
# is renamed; CFBundleExecutable still points at the "GhostWriter" binary, so
# the label the user drags reads "Ghost Writer" while the bundle stays valid.
APPNAME="Ghost Writer.app"
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
	"$APP/Contents/Info.plist" 2>/dev/null || echo "0.1")"
DMG="$ROOT/build/GhostWriter-${VERSION}.dmg"
RW="$(mktemp -u).dmg"
STAGE="$(mktemp -d)"
BACKGROUND="$ROOT/Resources/dmg-background.tiff"

cleanup() {
	[ -n "${DEVICE:-}" ] && hdiutil detach "$DEVICE" -quiet 2>/dev/null || true
	rm -rf "$STAGE" "$RW"
}
trap cleanup EXIT

cd "$ROOT"

[ -d "$APP" ] || { echo "error: no app at $APP — run Scripts/build-app.sh first" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Assemble the staging tree
# ---------------------------------------------------------------------------

echo "==> Staging"
cp -R "$APP" "$STAGE/$APPNAME"

# Running the app accrues extended attributes that were not there at signing
# time — TCC writes com.apple.macl onto a bundle holding a permission, and
# Finder adds its own. codesign --strict rejects a bundle carrying them. Strip
# them from the COPY: they are not covered by the signature, so removing them
# leaves it valid, and the original stays untouched for local runs. Renaming the
# .app folder does not touch the signature — the folder name is not sealed.
xattr -cr "$STAGE/$APPNAME"

echo "==> Verifying signature before packaging"
codesign --verify --deep --strict "$STAGE/$APPNAME" || {
	echo "error: app fails signature verification; packaging it would ship a broken build" >&2
	exit 1
}

ln -s /Applications "$STAGE/Applications"

# No README file on the volume by design — it clutters the window, and the one
# thing a first-time user must know (the Gatekeeper "Open Anyway" step) is baked
# into the background image, on screen exactly when they hit the block. The full
# instructions live in the GitHub release notes.

mkdir "$STAGE/.background"
if [ -f "$BACKGROUND" ]; then
	cp "$BACKGROUND" "$STAGE/.background/background.tiff"
else
	echo "warning: no $BACKGROUND — DMG will have a plain background" >&2
	echo "         regenerate with: Scripts/make-dmg-background.swift + tiffutil" >&2
fi

# Volume icon: reuse the app icon so the mounted disk and the .dmg itself carry
# the brand rather than the generic image.
[ -f "$ROOT/Resources/GhostWriter.icns" ] && \
	cp "$ROOT/Resources/GhostWriter.icns" "$STAGE/.VolumeIcon.icns"

# ---------------------------------------------------------------------------
# Create a writable image, style it, then compress
# ---------------------------------------------------------------------------

# Size the image from its contents plus slack; a too-small image fails to
# create, a too-large one wastes download bytes (UDZO reclaims most of it).
SIZE_MB=$(( $(du -sm "$STAGE" | cut -f1) + 24 ))

# A volume of the same name already mounted — a stale run, or the user's own
# downloaded copy — would force this one to mount as "Ghost Writer 1", and the
# styling below addresses the disk by name. Detach it first.
if [ -d "/Volumes/$VOLNAME" ]; then
	echo "==> Detaching an existing '$VOLNAME' volume"
	hdiutil detach "/Volumes/$VOLNAME" -force >/dev/null 2>&1 || true
	sleep 1
fi

# A blank writable image, populated by copy. Creating with -srcfolder produces
# an image that mounts read-only on recent macOS, which fails the styling. A
# blank image is read-write by default; passing -format there is rejected.
echo "==> Creating writable image (${SIZE_MB} MB)"
rm -f "$RW"
hdiutil create -size "${SIZE_MB}m" -fs HFS+ -volname "$VOLNAME" "$RW" >/dev/null

echo "==> Mounting"
DEVICE="$(hdiutil attach "$RW" -nobrowse -noautoopen \
	| grep -Eo '^/dev/disk[0-9]+' | head -1)"
MOUNT="/Volumes/$VOLNAME"
sleep 1

# ditto preserves the Applications symlink, the dot-directories and resource
# forks; a plain cp -R would not carry all of them.
ditto "$STAGE" "$MOUNT"

# Custom volume icon needs the folder's "has custom icon" bit set.
if [ -f "$STAGE/.VolumeIcon.icns" ]; then
	SetFile -a C "$MOUNT" 2>/dev/null \
		|| /Applications/Xcode.app/Contents/Developer/usr/bin/SetFile -a C "$MOUNT" 2>/dev/null \
		|| echo "note: could not set volume icon bit (SetFile unavailable)" >&2
fi

# Finder styling. Best-effort: it drives Finder over Apple events, which needs a
# GUI session and can be unavailable (headless CI, no Automation permission). A
# failure here must not fail the build — the image is fully functional without
# the styling, just plain.
style_window() {
	osascript <<-EOF
		tell application "Finder"
			tell disk "$VOLNAME"
				open
				set current view of container window to icon view
				set toolbar visible of container window to false
				set statusbar visible of container window to false
				-- Frame is 660 wide; height is content (410) plus the title bar.
				set the bounds of container window to {200, 120, 860, 558}
				set opts to the icon view options of container window
				set arrangement of opts to not arranged
				set icon size of opts to 112
				set text size of opts to 12
				set background picture of opts to file ".background:background.tiff"
				set position of item "$APPNAME" of container window to {180, 210}
				set position of item "Applications" of container window to {480, 210}
				close
				open
				update without registering applications
				delay 1
			end tell
		end tell
	EOF
}

echo "==> Styling window"
if [ -n "${CI:-}" ]; then
	# Skip on CI deliberately: driving Finder over Apple events needs an
	# interactive session, and on a headless runner it can hang rather than
	# fail. The image is fully functional unstyled, which is all CI verifies.
	echo "    skipped (CI has no interactive Finder session)"
elif style_window >/dev/null 2>&1; then
	echo "    styled"
else
	echo "    warning: Finder styling unavailable; shipping a functional plain image" >&2
fi

sync
echo "==> Detaching"
hdiutil detach "$DEVICE" -quiet
DEVICE=""

echo "==> Compressing"
rm -f "$DMG"
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null

echo "==> Signing disk image (ad-hoc)"
codesign --force --sign - "$DMG"

SIZE="$(du -h "$DMG" | cut -f1 | tr -d ' ')"
echo "==> Built $DMG ($SIZE)"
echo
cat <<'WARN'
    ---------------------------------------------------------------
    The app inside is signed for LOCAL USE unless it was built with
    a Developer ID. Anyone else will hit Gatekeeper on first launch;
    the background tells them how to proceed (Open Anyway).

    For a build that opens cleanly on any Mac:
      Scripts/notarize.sh   (needs a paid Developer ID + notary creds)
    ---------------------------------------------------------------
WARN
