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

# Pick a signing identity, in order of what each one is good for.
#
# The Accessibility grant is the reason identity matters here. TCC keys the
# grant to the code signature. An ad-hoc signature has a fresh hash on every
# build, so the grant dies on every build — the checkbox in System Settings
# stays on while pointing at a binary that no longer exists, which reads as
# "granted" and behaves as "denied". A real signing identity is keyed to the
# certificate instead, so the grant survives rebuilds, exactly like Xcode.
#
#   Developer ID Application : distribution — opens on any Mac once notarized
#   Apple Development        : LOCAL dev — stable grant across rebuilds, but
#                              Gatekeeper still blocks it on other machines
#   ad-hoc                   : last resort — grant dies every build
#
# Set CODESIGN_IDENTITY to override the choice.
# The trailing `|| true` is load-bearing: with `set -e`, grep finding no match
# (e.g. no Developer ID cert) would otherwise abort the whole script here,
# before the Apple Development fallback is even tried.
pick() { security find-identity -v -p codesigning 2>/dev/null \
	| grep "$1" | head -1 | sed 's/.*"\(.*\)".*/\1/' || true; }

IDENTITY="${CODESIGN_IDENTITY:-}"
KIND="override"
if [ -z "$IDENTITY" ]; then
	IDENTITY="$(pick 'Developer ID Application')"; KIND="developer-id"
fi
if [ -z "$IDENTITY" ]; then
	IDENTITY="$(pick 'Apple Development')"; KIND="apple-development"
fi

if [ -n "$IDENTITY" ]; then
	echo "==> Signing as: $IDENTITY"
	# --timestamp needs the network and only matters for distribution, so it is
	# added only for Developer ID. Written as two branches rather than an array:
	# macOS ships bash 3.2, where expanding an empty array under `set -u` aborts
	# with "unbound variable".
	if [ "$KIND" = "developer-id" ]; then
		codesign --force --sign "$IDENTITY" \
			--entitlements "$ROOT/Resources/GhostWriter.entitlements" \
			--options runtime --timestamp \
			"$APP" 2>&1 | sed 's/^/    /'
		echo "    Distributable once notarized — run Scripts/notarize.sh"
	else
		codesign --force --sign "$IDENTITY" \
			--entitlements "$ROOT/Resources/GhostWriter.entitlements" \
			--options runtime \
			"$APP" 2>&1 | sed 's/^/    /'
		echo "    Local identity: the Accessibility grant now survives rebuilds."
	fi
else
	echo "==> Signing (ad-hoc — LOCAL USE ONLY)"
	codesign --force --sign - \
		--entitlements "$ROOT/Resources/GhostWriter.entitlements" \
		--options runtime \
		"$APP" 2>&1 | sed 's/^/    /'
	echo "    No signing certificate found; the Accessibility grant will not" >&2
	echo "    survive the next rebuild." >&2
fi

echo "==> Built $APP"
codesign -dv "$APP" 2>&1 | sed 's/^/    /'

# A stable signature (Developer ID or Apple Development) keeps the Accessibility
# grant across rebuilds. Only ad-hoc builds need the reset, and only once you
# have switched TO ad-hoc from something else. When the grant does get into a
# stale state — usually after changing identity — this is the reset:
cat <<'NOTE'

    If Accessibility reads as granted but the app behaves as if it is not, the
    grant is stale (left over from a different signature). Reset once:

        tccutil reset Accessibility com.ghostwriter.app

    then open GhostWriter and grant it again. With a stable signing identity it
    then persists across rebuilds.
NOTE
