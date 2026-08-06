#!/bin/zsh
# Builds Doppel.app and installs it into ~/Applications. LSUIElement keeps it
# out of the Dock and the Cmd-Tab switcher: it lives in the menu bar only.
#
# The bundle is self-contained. The CLI, the engine and the three compiled
# helpers ship inside Contents/Resources/doppel, so a copy of the app needs
# neither this repository nor any developer tooling. Everything it calls at
# runtime — codesign, security, sips, iconutil, lsregister — is part of macOS.
#
#   app/build-app.zsh [install-root]

set -eu
setopt PIPE_FAIL

readonly APP_SRC="${0:A:h}"
readonly REPO_ROOT="${APP_SRC:h}"
readonly INSTALL_ROOT="${1:-$HOME/Applications}"
readonly APP="$INSTALL_ROOT/Doppel.app"
# DOPPEL_UNIVERSAL=1 builds arm64 + x86_64 (used for release artifacts).
readonly UNIVERSAL="${DOPPEL_UNIVERSAL:-0}"
# Ad hoc by default, which is what a local build wants. Set DOPPEL_SIGN_ID to a
# "Developer ID Application" identity (its name or its SHA-1) to produce a
# distributable build; from there notarisation is only notarytool plus stapling.
# Everything else about the signing below is already what notarisation expects.
readonly SIGN_ID="${DOPPEL_SIGN_ID:--}"

cd "$APP_SRC"
typeset binary
if [[ "$UNIVERSAL" == "1" ]]; then
    print -r -- "Building universal release binary (arm64 + x86_64)…"
    swift build -c release --arch arm64 --arch x86_64
    binary="$APP_SRC/.build/out/Products/Release/DoppelMenuBar"
    [[ -x "$binary" ]] || binary="$APP_SRC/.build/apple/Products/Release/DoppelMenuBar"
else
    print -r -- "Building release binary…"
    swift build -c release
    binary="$APP_SRC/.build/release/DoppelMenuBar"
fi
readonly BINARY="$binary"
[[ -x "$BINARY" ]] || { print -u2 -r -- "build produced no binary at $BINARY"; exit 1 }
print -r -- "Architectures: $(/usr/bin/lipo -archs "$BINARY" 2>/dev/null || print -r -- unknown)"

print -r -- "Assembling $APP…"
/bin/rm -rf "$APP"
/bin/mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
/bin/cp "$BINARY" "$APP/Contents/MacOS/Doppel"
/bin/chmod 755 "$APP/Contents/MacOS/Doppel"

# The CLI, engine and helpers travel with the app.
readonly PAYLOAD="$APP/Contents/Resources/doppel"
/bin/mkdir -p "$PAYLOAD/bin" "$PAYLOAD/engine" "$PAYLOAD/prebuilt"
/bin/cp "$REPO_ROOT/bin/doppel" "$REPO_ROOT/bin/doppel-signing" "$PAYLOAD/bin/"
/bin/cp "$REPO_ROOT/engine/doppel-engine.zsh" "$PAYLOAD/engine/"
/bin/cp "$REPO_ROOT/engine/patch-deep-link.py" "$PAYLOAD/engine/"
/bin/chmod 755 "$PAYLOAD/bin/doppel" "$PAYLOAD/bin/doppel-signing" "$PAYLOAD/engine/doppel-engine.zsh"

print -r -- "Compiling instance helpers…"
typeset -a arch_flags
if [[ "$UNIVERSAL" == "1" ]]; then
    arch_flags=(-arch arm64 -arch x86_64)
else
    arch_flags=()
fi
/usr/bin/clang -fobjc-arc -O2 $arch_flags -framework Cocoa -framework ApplicationServices \
    -framework AVFoundation -framework UserNotifications -framework Security \
    -o "$PAYLOAD/prebuilt/doppel-launcher" "$REPO_ROOT/engine/launcher/main.m"
/usr/bin/clang -fobjc-arc -O2 $arch_flags -framework Cocoa \
    -o "$PAYLOAD/prebuilt/doppel-alert" "$REPO_ROOT/engine/alert/main.m"
/usr/bin/clang -fobjc-arc -O2 $arch_flags -framework Cocoa \
    -o "$PAYLOAD/prebuilt/doppel-url-handler" "$REPO_ROOT/engine/url-handler/main.m"
if [[ "$UNIVERSAL" == "1" ]]; then
    /usr/bin/swiftc -O -target arm64-apple-macos14.0 "$REPO_ROOT/engine/icon/main.swift" \
        -o "$PAYLOAD/prebuilt/doppel-icon.arm64"
    /usr/bin/swiftc -O -target x86_64-apple-macos14.0 "$REPO_ROOT/engine/icon/main.swift" \
        -o "$PAYLOAD/prebuilt/doppel-icon.x86_64"
    /usr/bin/lipo -create "$PAYLOAD/prebuilt/doppel-icon.arm64" "$PAYLOAD/prebuilt/doppel-icon.x86_64" \
        -output "$PAYLOAD/prebuilt/doppel-icon"
    /bin/rm -f "$PAYLOAD/prebuilt/doppel-icon."{arm64,x86_64}
else
    /usr/bin/swiftc -O "$REPO_ROOT/engine/icon/main.swift" -o "$PAYLOAD/prebuilt/doppel-icon"
fi
/bin/chmod 755 "$PAYLOAD/prebuilt/"*

# Doppel's original paired-bubble mark is drawn rather than checked in. The
# generator is host architecture only — it runs here and does not ship.
print -r -- "Drawing the app icon…"
typeset ICON_WORK
ICON_WORK="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/doppel-appicon.XXXXXXXX")"
/usr/bin/swiftc -O "$APP_SRC/icon/main.swift" -o "$ICON_WORK/doppel-appicon" || {
    print -u2 -r -- "compiling the icon generator failed"; exit 1
}
"$ICON_WORK/doppel-appicon" "$ICON_WORK/Doppel.iconset" >/dev/null || {
    print -u2 -r -- "drawing the app icon failed"; exit 1
}
/usr/bin/iconutil -c icns "$ICON_WORK/Doppel.iconset" -o "$APP/Contents/Resources/Doppel.icns" || {
    print -u2 -r -- "building Doppel.icns failed"; exit 1
}
/bin/rm -rf "$ICON_WORK"

/bin/cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>Doppel</string>
	<key>CFBundleIdentifier</key>
	<string>ai.doppel.menubar</string>
	<key>CFBundleName</key>
	<string>Doppel</string>
	<key>CFBundleDisplayName</key>
	<string>Doppel</string>
	<key>CFBundleIconFile</key>
	<string>Doppel</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>0.4.5</string>
	<key>CFBundleVersion</key>
	<string>9</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
PLIST
print -r -- '</plist>' >> "$APP/Contents/Info.plist"
/usr/bin/printf 'APPL????' > "$APP/Contents/PkgInfo"

/usr/bin/xattr -cr "$APP"

# Signed inside out, not with --deep. Apple documents --deep as a fix-up tool
# rather than a signing strategy: it applies one set of options to everything it
# finds, which is exactly wrong once nested code needs its own treatment, and it
# is the shape notarisation rejects. The nested helpers are standalone Mach-O
# executables shipped in Resources, so each is signed first and the outer bundle
# last, where its signature seals them along with Contents/MacOS/Doppel.
print -r -- "Signing (identity: $SIGN_ID)…"
typeset -a sign_flags
sign_flags=(--force --options runtime --sign "$SIGN_ID")
# A secure timestamp needs a real identity; an ad-hoc signature cannot carry one.
[[ "$SIGN_ID" != "-" ]] && sign_flags+=(--timestamp)

typeset -a nested
nested=(
    "$PAYLOAD/prebuilt/doppel-launcher"
    "$PAYLOAD/prebuilt/doppel-alert"
    "$PAYLOAD/prebuilt/doppel-url-handler"
    "$PAYLOAD/prebuilt/doppel-icon"
)
typeset helper
for helper in $nested; do
    [[ -f "$helper" ]] || { print -u2 -r -- "expected a nested helper at $helper"; exit 1 }
    /usr/bin/codesign $sign_flags "$helper" >/dev/null
done
/usr/bin/codesign $sign_flags "$APP" >/dev/null

# Verify what was actually produced rather than assuming. --deep here is a
# verification request, which is what it is for, unlike --deep signing above.
for helper in $nested; do
    /usr/bin/codesign --verify --strict "$helper" >/dev/null
done
/usr/bin/codesign --verify --deep --strict "$APP" >/dev/null
if [[ "$SIGN_ID" != "-" ]]; then
    # Fail the build rather than ship an archive that cannot be notarised.
    /usr/bin/codesign -dv --verbose=4 "$APP" 2>&1 | /usr/bin/grep -q "^Authority=Developer ID Application" || {
        print -u2 -r -- "the outer bundle is not signed by a Developer ID Application certificate"; exit 1
    }
    print -r -- "Signed for distribution. Next: notarytool submit, then stapler staple."
fi

print -r -- "Installed: $APP"
