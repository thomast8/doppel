#!/bin/zsh
# Builds Doppel.app (the menu-bar front end) and installs it into
# ~/Applications. LSUIElement keeps it out of the Dock and the Cmd-Tab
# switcher: it lives in the menu bar only.
#
#   app/build-app.zsh [install-root]

set -eu
setopt PIPE_FAIL

readonly APP_SRC="${0:A:h}"
readonly INSTALL_ROOT="${1:-$HOME/Applications}"
readonly APP="$INSTALL_ROOT/Doppel.app"
# DOPPEL_UNIVERSAL=1 builds arm64 + x86_64 (used for release artifacts).
readonly UNIVERSAL="${DOPPEL_UNIVERSAL:-0}"

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
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>0.1</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
PLIST
print -r -- '</plist>' >> "$APP/Contents/Info.plist"
/usr/bin/printf 'APPL????' > "$APP/Contents/PkgInfo"

/usr/bin/xattr -cr "$APP"
/usr/bin/codesign --force --sign - --options runtime "$APP" >/dev/null
/usr/bin/codesign --verify --strict "$APP" >/dev/null

print -r -- "Installed: $APP"
