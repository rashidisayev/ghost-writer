#!/bin/bash
# Assembles GhostWriter.app from the SPM build product.
#
# MenuBarExtra and LSUIElement need real bundle identity — a bare executable
# gets a Dock icon and no menu bar item. This does what an Xcode app target
# would do, without requiring the Xcode project.
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/GhostWriter.app"

cd "$ROOT"

echo "==> Building ($CONFIG)"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/GhostWriter"
[ -x "$BIN" ] || { echo "error: no executable at $BIN" >&2; exit 1; }

echo "==> Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/GhostWriter"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# LSUIElement means no Dock icon, but Finder, the Settings window and any
# permission alert still show this one. Regenerate with Scripts/make-icon.swift.
if [ -f "$ROOT/Resources/GhostWriter.icns" ]; then
	cp "$ROOT/Resources/GhostWriter.icns" "$APP/Contents/Resources/GhostWriter.icns"
else
	echo "warning: no Resources/GhostWriter.icns — bundle will use the generic icon" >&2
fi

# Copied files carry extended attributes (quarantine flags, Finder info), and
# codesign --verify --strict rejects a bundle containing them: "resource fork,
# Finder information, or similar detritus not allowed". Strip before signing —
# afterwards would invalidate the signature.
xattr -cr "$APP"

# Pick the strongest identity available.
#
# Only "Developer ID Application" produces a build that opens on someone else's
# Mac. An "Apple Development" certificate is NOT a substitute — it is for
# running on your own registered devices, cannot be notarized, and Gatekeeper
# blocks it exactly like an ad-hoc signature. Set CODESIGN_IDENTITY to override.
#
# TCC keys the Accessibility grant to the code signature, so switching identity
# means granting permission again.
IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
	IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
		| grep 'Developer ID Application' | head -1 \
		| sed 's/.*"\(.*\)".*/\1/' || true)"
fi

if [ -n "$IDENTITY" ]; then
	echo "==> Signing as: $IDENTITY"
	codesign --force --sign "$IDENTITY" \
		--entitlements "$ROOT/Resources/GhostWriter.entitlements" \
		--options runtime \
		--timestamp \
		"$APP" 2>&1 | sed 's/^/    /'
	echo "    Distributable once notarized — run Scripts/notarize.sh"
else
	echo "==> Signing (ad-hoc — LOCAL USE ONLY)"
	codesign --force --sign - \
		--entitlements "$ROOT/Resources/GhostWriter.entitlements" \
		--options runtime \
		"$APP" 2>&1 | sed 's/^/    /'
	echo "    No 'Developer ID Application' certificate found." >&2
	echo "    This build will be blocked by Gatekeeper on every other Mac." >&2
fi

echo "==> Built $APP"
codesign -dv "$APP" 2>&1 | sed 's/^/    /'

# TCC keys an ad-hoc grant to the code directory hash, which changes on every
# build. The old entry stays visible and switched on in System Settings while
# applying to a binary that no longer exists — so it reads as "granted" and
# behaves as "denied". Clearing it is the only way to get a truthful state.
cat <<'NOTE'

    Accessibility: this build has a new code signature, so any existing grant
    no longer applies to it. Reset and re-grant:

        tccutil reset Accessibility com.ghostwriter.app

    then open GhostWriter and use "Grant Accessibility permission…" from the menu.
NOTE
