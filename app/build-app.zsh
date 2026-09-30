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
# Developer ID build; from there notarisation is only notarytool plus stapling.
# Ad-hoc builds can still use EdDSA-verified Sparkle updates for personal use.
readonly SIGN_ID="${DOPPEL_SIGN_ID:--}"
readonly DOPPEL_VERSION="${DOPPEL_VERSION:-1.0.0}"
readonly DOPPEL_BUILD="${DOPPEL_BUILD:-10}"
readonly DOPPEL_BUNDLE_ID="${DOPPEL_BUNDLE_ID:-ai.doppel.menubar}"
readonly SPARKLE_FEED_URL="${DOPPEL_SPARKLE_FEED_URL:-https://raw.githubusercontent.com/thomast8/doppel/main/appcast.xml}"
readonly SPARKLE_PUBLIC_KEY="${DOPPEL_SPARKLE_PUBLIC_KEY:-}"
readonly SINGLE_INSTANCE_LOCK_NAME="${DOPPEL_SINGLE_INSTANCE_LOCK_NAME:-}"
readonly SWIFT_SCRATCH="${DOPPEL_SWIFT_SCRATCH_PATH:-$APP_SRC/.build}"
readonly SPARKLE_ROOT="${DOPPEL_SPARKLE_ROOT:-$SWIFT_SCRATCH/artifacts/sparkle/Sparkle}"

if [[ "$SIGN_ID" != "-" && -z "$SPARKLE_PUBLIC_KEY" ]]; then
    print -u2 -r -- "DOPPEL_SPARKLE_PUBLIC_KEY is required for a distributable build"
    exit 1
fi
if [[ "$SPARKLE_FEED_URL" != https://* ]]; then
    [[ "${DOPPEL_ALLOW_INSECURE_LOCAL_FEED:-0}" == "1" && "$SPARKLE_FEED_URL" == http://localhost:* ]] || {
        print -u2 -r -- "the Sparkle feed must use HTTPS (localhost QA requires DOPPEL_ALLOW_INSECURE_LOCAL_FEED=1)"
        exit 1
    }
fi

cd "$APP_SRC"
typeset -a swift_build_args
swift_build_args=(--scratch-path "$SWIFT_SCRATCH")
[[ "${DOPPEL_SWIFT_DISABLE_SANDBOX:-0}" == "1" ]] && swift_build_args+=(--disable-sandbox)
typeset binary
if [[ "$UNIVERSAL" == "1" ]]; then
    print -r -- "Building universal release binary (arm64 + x86_64)…"
    swift build $swift_build_args -c release --arch arm64 --arch x86_64
    binary="$SWIFT_SCRATCH/out/Products/Release/DoppelMenuBar"
    [[ -x "$binary" ]] || binary="$SWIFT_SCRATCH/apple/Products/Release/DoppelMenuBar"
else
    print -r -- "Building release binary…"
    swift build $swift_build_args -c release
    binary="$SWIFT_SCRATCH/out/Products/Release/DoppelMenuBar"
    [[ -x "$binary" ]] || binary="$SWIFT_SCRATCH/release/DoppelMenuBar"
fi
readonly BINARY="$binary"
[[ -x "$BINARY" ]] || { print -u2 -r -- "build produced no binary at $BINARY"; exit 1 }
print -r -- "Architectures: $(/usr/bin/lipo -archs "$BINARY" 2>/dev/null || print -r -- unknown)"

typeset sparkle_source="$SPARKLE_ROOT/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
[[ -d "$sparkle_source" ]] || {
    print -u2 -r -- "Sparkle.framework was not found under $SPARKLE_ROOT"
    print -u2 -r -- "run swift package resolve, or set DOPPEL_SPARKLE_ROOT to an extracted Sparkle SwiftPM artifact"
    exit 1
}
readonly SPARKLE_SOURCE="$sparkle_source"

print -r -- "Assembling $APP…"
/bin/rm -rf "$APP"
/bin/mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
/bin/cp "$BINARY" "$APP/Contents/MacOS/Doppel"
/bin/chmod 755 "$APP/Contents/MacOS/Doppel"
/usr/bin/ditto "$SPARKLE_SOURCE" "$APP/Contents/Frameworks/Sparkle.framework"
if ! /usr/bin/otool -l "$APP/Contents/MacOS/Doppel" | /usr/bin/grep -q "path @executable_path/../Frameworks"; then
    /usr/bin/install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Doppel"
fi

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
/usr/bin/clang -fobjc-arc -O2 -mmacosx-version-min=14.0 $arch_flags -framework Cocoa -framework ApplicationServices \
    -framework AVFoundation -framework UserNotifications -framework Security \
    -o "$PAYLOAD/prebuilt/doppel-launcher" "$REPO_ROOT/engine/launcher/main.m"
/usr/bin/clang -fobjc-arc -O2 -mmacosx-version-min=14.0 $arch_flags -framework Cocoa \
    -o "$PAYLOAD/prebuilt/doppel-alert" "$REPO_ROOT/engine/alert/main.m"
/usr/bin/clang -fobjc-arc -O2 -mmacosx-version-min=14.0 $arch_flags -framework Cocoa \
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
	<string>1.0.0</string>
	<key>CFBundleVersion</key>
	<string>10</string>
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
/usr/bin/plutil -replace CFBundleIdentifier -string "$DOPPEL_BUNDLE_ID" "$APP/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleShortVersionString -string "$DOPPEL_VERSION" "$APP/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleVersion -string "$DOPPEL_BUILD" "$APP/Contents/Info.plist"
if [[ -n "$SPARKLE_PUBLIC_KEY" ]]; then
    /usr/bin/plutil -insert SUFeedURL -string "$SPARKLE_FEED_URL" "$APP/Contents/Info.plist"
    /usr/bin/plutil -insert SUEnableAutomaticChecks -bool true "$APP/Contents/Info.plist"
    /usr/bin/plutil -insert SUPublicEDKey -string "$SPARKLE_PUBLIC_KEY" "$APP/Contents/Info.plist"
    if [[ "${DOPPEL_SPARKLE_AUTOMATIC_UPDATE:-0}" == "1" ]]; then
        /usr/bin/plutil -insert SUAutomaticallyUpdate -bool true "$APP/Contents/Info.plist"
    fi
else
    /usr/bin/plutil -insert SUEnableAutomaticChecks -bool false "$APP/Contents/Info.plist"
fi
if [[ -n "$SINGLE_INSTANCE_LOCK_NAME" ]]; then
    /usr/bin/plutil -insert DoppelSingleInstanceLockName -string "$SINGLE_INSTANCE_LOCK_NAME" "$APP/Contents/Info.plist"
fi
if [[ -n "$SPARKLE_PUBLIC_KEY" && "$SPARKLE_FEED_URL" == http://localhost:* ]]; then
    /usr/bin/plutil -insert NSAppTransportSecurity -xml '<dict><key>NSExceptionDomains</key><dict><key>localhost</key><dict><key>NSExceptionAllowsInsecureHTTPLoads</key><true/></dict></dict></dict>' "$APP/Contents/Info.plist"
fi

# Sparkle.framework uses versioned symlinks. Recursive xattr clearing follows
# those links and fails with EINVAL on some macOS versions, so clear only the
# regular files that can actually carry copied quarantine metadata.
/usr/bin/find "$APP" -type f -exec /usr/bin/xattr -c {} +

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
readonly SPARKLE_FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
readonly SPARKLE_VERSION_ROOT="$SPARKLE_FRAMEWORK/Versions/B"
typeset -a sparkle_nested
sparkle_nested=(
    "$SPARKLE_VERSION_ROOT/XPCServices/Installer.xpc"
    "$SPARKLE_VERSION_ROOT/XPCServices/Downloader.xpc"
    "$SPARKLE_VERSION_ROOT/Autoupdate"
    "$SPARKLE_VERSION_ROOT/Updater.app"
)
typeset helper
for helper in $sparkle_nested; do
    [[ -e "$helper" ]] || { print -u2 -r -- "expected Sparkle code at $helper"; exit 1 }
done
/usr/bin/codesign $sign_flags "$SPARKLE_VERSION_ROOT/XPCServices/Installer.xpc" >/dev/null
/usr/bin/codesign $sign_flags --preserve-metadata=entitlements \
    "$SPARKLE_VERSION_ROOT/XPCServices/Downloader.xpc" >/dev/null
/usr/bin/codesign $sign_flags "$SPARKLE_VERSION_ROOT/Autoupdate" >/dev/null
/usr/bin/codesign $sign_flags "$SPARKLE_VERSION_ROOT/Updater.app" >/dev/null
/usr/bin/codesign $sign_flags "$SPARKLE_FRAMEWORK" >/dev/null
for helper in $nested; do
    [[ -f "$helper" ]] || { print -u2 -r -- "expected a nested helper at $helper"; exit 1 }
    /usr/bin/codesign $sign_flags "$helper" >/dev/null
done
typeset -a outer_sign_flags
outer_sign_flags=($sign_flags)
typeset adhoc_entitlements=""
if [[ "$SIGN_ID" == "-" ]]; then
    # A hardened ad-hoc app and ad-hoc dynamic framework have no matching Team
    # ID, so macOS library validation rejects Sparkle before launch. Keep this
    # exception off every Developer ID distribution build.
    adhoc_entitlements="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/doppel-entitlements.XXXXXXXX")"
    /usr/bin/plutil -create xml1 "$adhoc_entitlements"
    /usr/bin/plutil -insert 'com\.apple\.security\.cs\.disable-library-validation' -bool true "$adhoc_entitlements"
    outer_sign_flags+=(--entitlements "$adhoc_entitlements")
fi
/usr/bin/codesign $outer_sign_flags "$APP" >/dev/null
[[ -z "$adhoc_entitlements" ]] || /bin/rm -f "$adhoc_entitlements"

# Verify what was actually produced rather than assuming. --deep here is a
# verification request, which is what it is for, unlike --deep signing above.
for helper in $nested; do
    /usr/bin/codesign --verify --strict "$helper" >/dev/null
done
/usr/bin/codesign --verify --deep --strict "$SPARKLE_FRAMEWORK" >/dev/null
/usr/bin/codesign --verify --deep --strict "$APP" >/dev/null
if [[ "$SIGN_ID" != "-" ]]; then
    # Fail the build rather than ship an archive that cannot be notarised.
    /usr/bin/codesign -dv --verbose=4 "$APP" 2>&1 | /usr/bin/grep -q "^Authority=Developer ID Application" || {
        print -u2 -r -- "the outer bundle is not signed by a Developer ID Application certificate"; exit 1
    }
    print -r -- "Signed for Developer ID distribution. Next: notarytool submit, then stapler staple."
fi

print -r -- "Installed: $APP"
