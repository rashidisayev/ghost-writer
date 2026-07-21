#!/bin/bash
# Assembles Quill.app from the SPM build product.
#
# MenuBarExtra and LSUIElement need real bundle identity — a bare executable
# gets a Dock icon and no menu bar item. This does what an Xcode app target
# would do, without requiring the Xcode project.
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/Quill.app"

cd "$ROOT"

echo "==> Building ($CONFIG)"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Quill"
[ -x "$BIN" ] || { echo "error: no executable at $BIN" >&2; exit 1; }

echo "==> Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Quill"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# LSUIElement means no Dock icon, but Finder, the Settings window and any
# permission alert still show this one. Regenerate with Scripts/make-icon.swift.
if [ -f "$ROOT/Resources/Quill.icns" ]; then
	cp "$ROOT/Resources/Quill.icns" "$APP/Contents/Resources/Quill.icns"
else
	echo "warning: no Resources/Quill.icns — bundle will use the generic icon" >&2
fi

# Ad-hoc signing is enough for local use. TCC keys the Accessibility grant to
# the code signature, so re-signing with a different identity means re-granting.
# Shipping needs "Developer ID Application" + notarization — see BUILD.md Step 6.
echo "==> Signing (ad-hoc)"
codesign --force --sign - \
	--entitlements "$ROOT/Resources/Quill.entitlements" \
	--options runtime \
	"$APP" 2>&1 | sed 's/^/    /'

echo "==> Built $APP"
codesign -dv "$APP" 2>&1 | sed 's/^/    /'

# TCC keys an ad-hoc grant to the code directory hash, which changes on every
# build. The old entry stays visible and switched on in System Settings while
# applying to a binary that no longer exists — so it reads as "granted" and
# behaves as "denied". Clearing it is the only way to get a truthful state.
cat <<'NOTE'

    Accessibility: this build has a new code signature, so any existing grant
    no longer applies to it. Reset and re-grant:

        tccutil reset Accessibility com.quill.app

    then open Quill and use "Grant Accessibility permission…" from the menu.
NOTE
