#!/bin/bash
# Builds PopChat.app into dist/. SwiftPM produces the binary; this script wraps it
# in an app bundle (LSUIElement menu bar app) and signs it.
#
# Signing identity comes from POPCHAT_SIGN_IDENTITY; the default "-" is ad-hoc, which
# is right for local iteration. release.sh sets it to the Developer ID and that branch
# additionally enables the hardened runtime + a secure timestamp, both of which
# notarization refuses to proceed without.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
SIGN_ID="${POPCHAT_SIGN_IDENTITY:--}"

# --build-system swiftbuild is not a performance choice, it is the fix for issue #1
# and must not be dropped back to the default "native" engine.
#
# SwiftPM generates the `Bundle.module` accessor differently per build engine. The
# native engine emits the flavour meant for a command-line tool: it looks for the
# bundle next to the executable, then at the ABSOLUTE build directory of whoever
# compiled it. Inside an app bundle "next to the executable" means PopChat.app/, and
# nothing may live at the root of a signed .app — codesign refuses to seal it ("unsealed
# contents present in the bundle root"), so that path can never be satisfied. Every
# build therefore fell through to the second candidate, which resolved on the build
# machine and nowhere else: shipped copies trapped as soon as the user opened the
# hotkey recorder. The swiftbuild engine emits the flavour Xcode uses, which looks in
# Bundle.main.resourceURL — Contents/Resources, where this script already puts them.
BUILD_SYSTEM_ARGS=(--build-system swiftbuild)
if ! swift build --help 2>/dev/null | grep -q -- "swiftbuild"; then
    echo "error: this Swift toolchain has no '--build-system swiftbuild' (needs 6.2 or newer)." >&2
    echo "       Building without it produces an app that crashes on the hotkey recorder" >&2
    echo "       and on LaTeX — see the comment above. Update with xcode-select --install." >&2
    swift --version >&2
    exit 1
fi
swift build "${BUILD_SYSTEM_ARGS[@]}" -c "$CONFIG"

# Asked rather than assumed: the two engines use different layouts (.build/<triple>/<config>
# vs .build/out/Products/<Config>), and this is the supported way to find either.
BIN_DIR="$(swift build "${BUILD_SYSTEM_ARGS[@]}" -c "$CONFIG" --show-bin-path)"
BIN="$BIN_DIR/PopChat"
APP="dist/PopChat.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PopChat"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"   # CFBundleIconFile

# SPM dependency resource bundles (KeyboardShortcuts localizations, SwiftMath's math
# fonts) must ship inside the app for Bundle.module lookup to succeed — without them
# the app traps on the hotkey recorder and on the first message containing LaTeX.
# -L is load-bearing: the bin path may be a symlink to .build/<triple>/<config>, and
# plain find will not descend into it, so this silently copied nothing.
find -L "$BIN_DIR" -maxdepth 1 -name "*.bundle" -exec cp -R {} "$APP/Contents/Resources/" \;

# Counted, not "is Resources empty" — the icon lives there too and would mask a miss.
if [ "$(find "$APP/Contents/Resources" -maxdepth 1 -name "*.bundle" | wc -l)" -eq 0 ]; then
    echo "error: no resource bundles were copied — LaTeX rendering would crash at runtime" >&2
    exit 1
fi

# Present-on-disk is necessary but not sufficient: it says nothing about whether the
# compiled-in accessor looks where they landed. This resolves them for real, from
# inside the bundle being shipped, and is the only check that would have caught #1.
# It builds an NSView, so it needs a window server — skipped rather than crashing
# the build over SSH, where AppKit cannot reach one.
if [ "$(launchctl managername 2>/dev/null)" = "Aqua" ]; then
    echo "==> Checking dependency resource bundles resolve inside the app"
    "$APP/Contents/MacOS/PopChat" --smoke-bundles
else
    echo "warning: no window server — skipping the resource-bundle check (run" >&2
    echo "         '$APP/Contents/MacOS/PopChat --smoke-bundles' from a desktop session)" >&2
fi

if [ "$SIGN_ID" = "-" ]; then
    codesign --force --sign - "$APP"
    echo "Built $APP (ad-hoc signed)"
else
    # The nested *.bundle payloads are resource-only (localizations, math fonts, a
    # privacy manifest) — no Mach-O inside, so the app's own signature seals them and
    # signing them individually just fails on the ones lacking an Info.plist.
    codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP"
    codesign --verify --strict --deep --verbose=2 "$APP"
    echo "Built $APP (signed: $SIGN_ID)"
fi
echo "Run with: open $APP"
