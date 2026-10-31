#!/bin/zsh
# Builds a throwaway tinted Claude instance and checks that its Dock and Finder
# icon follows dark mode through create, rebuild and edit. Nothing is launched,
# no account is touched, and the instance goes to the Trash at the end.
set -eu
setopt PIPE_FAIL
readonly REPO_ROOT="${0:A:h:h}"
readonly VENDOR=/Applications/Claude.app
mkdir -p "$REPO_ROOT/qa/.build"
readonly WORK="$(mktemp -d "$REPO_ROOT/qa/.build/claude-icon.XXXXXXXX")"
readonly NAME="Claude Doppel Icon $$"
readonly APP="$WORK/apps/$NAME.app"
readonly INFO="$APP/Contents/Info.plist"
readonly CATALOG="$APP/Contents/Resources/Assets.car"
export DOPPEL_DEV=1 DOPPEL_HOME="$WORK/doppel" DOPPEL_STATE_ROOT="$WORK/engine-state"
export DOPPEL_PIN_ROOT="$WORK/pins" DOPPEL_NO_ALERT=1 DOPPEL_RELAUNCH=0
export DOPPEL_SIGN_IDENTITY_NAME="Doppel Claude QA No Identity" DOPPEL_SIGN_IDENTITY=-
print -r -- "QA artifacts retained at $WORK"

/usr/bin/clang -fobjc-arc -framework AppKit "$REPO_ROOT/qa/icon-appearance.m" -o "$WORK/icon-appearance"
readonly VENDOR_ICON_NAME="$(/usr/bin/plutil -extract CFBundleIconName raw "$VENDOR/Contents/Info.plist")"

fail() { print -u2 -r -- "FAIL: $1"; exit 1; }

# Prints "<light luminance> <dark luminance>" and keeps the renders under $WORK/<step>.
render() {
    local step="$1" light dark
    mkdir -p "$WORK/$step"
    "$WORK/icon-appearance" "$APP" "$WORK/$step" > "$WORK/$step/report.txt"
    light="$(/usr/bin/awk '$1 == "light" {print $3}' "$WORK/$step/report.txt")"
    dark="$(/usr/bin/awk '$1 == "dark" {print $3}' "$WORK/$step/report.txt")"
    print -r -- "$step: $(tr '\n' ' ' < "$WORK/$step/report.txt")" >&2
    print -r -- "$light $dark"
}

expect_catalog() {
    local step="$1" light dark
    [[ "$(/usr/bin/plutil -extract CFBundleIconName raw "$INFO")" == "$VENDOR_ICON_NAME" ]] || \
        fail "$step: CFBundleIconName is not the vendor's"
    /usr/bin/codesign --verify --deep --strict "$APP" || fail "$step: signature"
    read light dark <<< "$(render "$step")"
    (( light - dark > 40 )) || fail "$step: the icon does not darken in dark mode ($light vs $dark)"
}

"$REPO_ROOT/bin/doppel" --app claude create --name "$NAME" --tint 3B82F6 \
    --profile-root "$WORK/profile" --claude-config-dir "$WORK/code" --install-to "$WORK/apps"
expect_catalog tinted-blue
/usr/bin/cmp -s "$CATALOG" "$VENDOR/Contents/Resources/Assets.car" && fail "the catalog was not recoloured"
/usr/bin/cmp -s "$APP/Contents/Resources/Doppel/assets/vendor-Assets.car" "$VENDOR/Contents/Resources/Assets.car" || \
    fail "the pristine vendor catalog was not preserved"
readonly BLUE_CATALOG="$WORK/blue.car"
/bin/cp "$CATALOG" "$BLUE_CATALOG"

"$REPO_ROOT/bin/doppel" --app claude rebuild "$NAME"
expect_catalog rebuilt-blue
/usr/bin/cmp -s "$CATALOG" "$BLUE_CATALOG" || fail "a rebuild changed the recoloured catalog"

"$REPO_ROOT/bin/doppel" --app claude edit "$NAME" --tint A855F7
expect_catalog tinted-purple
/usr/bin/cmp -s "$CATALOG" "$BLUE_CATALOG" && fail "recolouring kept the old catalog"

"$REPO_ROOT/bin/doppel" --app claude edit "$NAME" --original-icon
expect_catalog original
/usr/bin/cmp -s "$CATALOG" "$VENDOR/Contents/Resources/Assets.car" || fail "the original icon is not the vendor catalog"

"$REPO_ROOT/bin/doppel" --app claude edit "$NAME" --icon "$VENDOR/Contents/Resources/electron.icns"
/usr/bin/plutil -extract CFBundleIconName raw "$INFO" >/dev/null 2>&1 && fail "a custom icon still points at the catalog"
/usr/bin/cmp -s "$CATALOG" "$VENDOR/Contents/Resources/Assets.car" || fail "a custom icon left a recoloured catalog behind"
/usr/bin/codesign --verify --deep --strict "$APP" || fail "custom icon: signature"
render custom >/dev/null

"$REPO_ROOT/bin/doppel" --app claude remove "$NAME"
print -r -- "Tinted Claude icons follow dark mode through create, rebuild, recolour, original and custom icons."
