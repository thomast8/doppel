#!/bin/zsh
# End-to-end check of the instance lifecycle against real bundles on disk.
#
# Every assertion here exists because the thing it checks broke at least once.
# It creates a throwaway instance, puts it through create, edit, rename,
# recolour, original-icon and remove, and inspects what actually landed on disk
# rather than trusting the commands' own output.
#
#   qa/e2e.zsh [--cli /path/to/doppel]
#
# The throwaway instance is removed at the end, including its data. It never
# touches an existing instance.

set -u
setopt PIPE_FAIL

readonly REPO_ROOT="${0:A:h:h}"
CLI="$REPO_ROOT/bin/doppel"
[[ "${1:-}" == "--cli" ]] && CLI="$2"

readonly NAME="Doppel QA $$"
readonly RENAMED="Doppel QA Renamed $$"
readonly SLUG="$(print -r -- "$NAME" | /usr/bin/tr '[:upper:]' '[:lower:]' | /usr/bin/sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g')"
readonly APPS="$HOME/Applications"
readonly INSTANCES="$HOME/Library/Application Support/Doppel/instances"
readonly PRIMARY="${DOPPEL_PRIMARY_APP:-/Applications/ChatGPT.app}"
# Edits reopen the instance by design; a test run should not litter the screen
# with app windows.
export DOPPEL_RELAUNCH=0

typeset -i PASSED=0 FAILED=0

pass() { print -r -- "  ✓ $1"; (( PASSED += 1 )); return 0 }
fail() { print -r -- "  ✗ $1"; print -r -- "      $2"; (( FAILED += 1 )); return 0 }

check() {
    local label="$1" actual="$2" expected="$3"
    if [[ "$actual" == "$expected" ]]; then
        pass "$label"
    else
        fail "$label" "expected '$expected', got '$actual'"
    fi
}

plist() { /usr/bin/plutil -extract "$2" raw "$1/Contents/Info.plist" 2>/dev/null }

# Average colour of an icon's light pixels, so a tint can be asserted rather
# than assumed. Built once into the QA directory.
readonly SAMPLER="$REPO_ROOT/qa/.build/icon-sample"
build_sampler() {
    [[ -x "$SAMPLER" ]] && return 0
    /bin/mkdir -p "${SAMPLER:h}"
    /usr/bin/swiftc -O "$REPO_ROOT/qa/icon-sample.swift" -o "$SAMPLER" || {
        print -u2 -r -- "could not build the icon sampler"; exit 1
    }
}

icon_hex() { "$SAMPLER" "$1" }

# Two colours agree when each channel is within tolerance: tinting blends with
# the artwork underneath, so the result is never the exact input.
colour_near() {
    local got="${1#\#}" want="${2#\#}" tolerance="${3:-45}" i
    for i in 1 3 5; do
        local a=$(( 16#${got[$i,$i+1]} )) b=$(( 16#${want[$i,$i+1]} ))
        (( ${a} - ${b} > tolerance || ${b} - ${a} > tolerance )) && return 1
    done
    return 0
}

cleanup() {
    "$CLI" remove "$RENAMED" --purge-data >/dev/null 2>&1 || \
        "$CLI" remove "$NAME" --purge-data >/dev/null 2>&1 || true
    /bin/rm -rf "$HOME/Library/Application Support/Doppel/state/Removed/$SLUG."* 2>/dev/null || true
}
trap cleanup EXIT

[[ -d "$PRIMARY" ]] || { print -u2 -r -- "the primary app is required at $PRIMARY"; exit 1 }
build_sampler

print -r -- "Doppel end-to-end QA"
print -r -- "  cli: $CLI"
print -r -- ""

print -r -- "create"
if ! "$CLI" create --name "$NAME" --tint EC4899 >/dev/null 2>&1; then
    print -u2 -r -- "  ✗ create failed; aborting"
    exit 1
fi
APP="$APPS/$NAME.app"
DIR="$INSTANCES/$SLUG"
[[ -d "$APP" ]] && pass "bundle installed" || fail "bundle installed" "missing $APP"
check "display name" "$(plist "$APP" CFBundleDisplayName)" "$NAME"
check "bundle name" "$(plist "$APP" CFBundleName)" "$NAME"
check "own bundle identifier" "$(plist "$APP" CFBundleIdentifier)" "com.openai.codex.doppel-$SLUG"
check "own profile" "$(plist "$APP" LSEnvironment.CODEX_ELECTRON_USER_DATA_PATH)" "$HOME/Library/Application Support/$NAME"
check "sparkle neutralised" "$(plist "$APP" SUFeedURL)" "https://doppel.invalid/no-updates.xml"
if /usr/bin/codesign --verify --deep --strict "$APP" >/dev/null 2>&1; then
    pass "signature valid"
else
    fail "signature valid" "codesign rejected the bundle"
fi
got="$(icon_hex "$APP/Contents/Resources/icon-chatgpt.png")"
if colour_near "$got" "EC4899"; then pass "icon tinted pink ($got)"; else fail "icon tinted pink" "got $got"; fi

print -r -- ""
print -r -- "embedded copies stay in step (a stale copy makes an instance undo its own edit)"
check "embedded config name" \
    "$(/bin/zsh -c "source '$APP/Contents/Resources/Doppel/instance-config.zsh'; print -r -- \$DOPPEL_DISPLAY_NAME" 2>/dev/null)" \
    "$NAME"
if /usr/bin/cmp -s "$APP/Contents/Resources/Doppel/assets/icon.icns" "$APP/Contents/Resources/electron.icns"; then
    pass "embedded icon matches the bundle icon"
else
    fail "embedded icon matches the bundle icon" "the next launch would rebuild and revert"
fi

print -r -- ""
print -r -- "rename and recolour"
DR_BEFORE="$(/usr/bin/codesign -d -r- "$APP" 2>&1 | grep 'designated =>')"
"$CLI" edit "$NAME" --rename "$RENAMED" --tint 3B82F6 >/dev/null 2>&1
RENAMED_APP="$APPS/$RENAMED.app"
[[ -d "$RENAMED_APP" ]] && pass "bundle renamed on disk" || fail "bundle renamed on disk" "missing $RENAMED_APP"
[[ ! -d "$APP" ]] && pass "old path gone" || fail "old path gone" "$APP still exists"
check "display name updated" "$(plist "$RENAMED_APP" CFBundleDisplayName)" "$RENAMED"
check "identity unchanged" "$(plist "$RENAMED_APP" CFBundleIdentifier)" "com.openai.codex.doppel-$SLUG"
check "data path unchanged" "$(plist "$RENAMED_APP" LSEnvironment.CODEX_HOME)" "$HOME/.codex-$SLUG"
check "embedded config renamed" \
    "$(/bin/zsh -c "source '$RENAMED_APP/Contents/Resources/Doppel/instance-config.zsh'; print -r -- \$DOPPEL_DISPLAY_NAME" 2>/dev/null)" \
    "$RENAMED"
got="$(icon_hex "$RENAMED_APP/Contents/Resources/icon-chatgpt.png")"
if colour_near "$got" "3B82F6"; then pass "icon recoloured blue ($got)"; else fail "icon recoloured blue" "got $got"; fi
DR_AFTER="$(/usr/bin/codesign -d -r- "$RENAMED_APP" 2>&1 | grep 'designated =>')"
check "code identity survives the edit (keychain and privacy grants)" "$DR_AFTER" "$DR_BEFORE"

print -r -- ""
print -r -- "the health check the launcher runs must find it healthy"
ENGINE_LOG="$HOME/Library/Application Support/Doppel/state/com.openai.codex.doppel-$SLUG/engine.log"
DOPPEL_NO_ALERT=1 /bin/zsh "$DIR/doppel-engine.zsh" install "$RENAMED_APP" >/dev/null 2>&1
if [[ "$(/usr/bin/tail -1 "$ENGINE_LOG" 2>/dev/null)" == *"already healthy"* ]]; then
    pass "no rebuild triggered after an edit"
else
    fail "no rebuild triggered after an edit" "the instance would rebuild and revert: $(/usr/bin/tail -1 "$ENGINE_LOG" 2>/dev/null)"
fi

print -r -- ""
print -r -- "original icon"
"$CLI" edit "$RENAMED" --original-icon >/dev/null 2>&1
if /usr/bin/cmp -s "$RENAMED_APP/Contents/Resources/electron.icns" "$PRIMARY/Contents/Resources/electron.icns"; then
    pass "icon restored to the vendor's own artwork"
else
    fail "icon restored to the vendor's own artwork" "the icon still differs from the primary app's"
fi
check "recorded as original" "$(/bin/zsh -c "source '$DIR/instance-config.zsh'; print -r -- \$DOPPEL_TINT" 2>/dev/null)" "original"

print -r -- ""
print -r -- "remove"
"$CLI" remove "$RENAMED" --purge-data >/dev/null 2>&1
[[ ! -d "$RENAMED_APP" ]] && pass "bundle removed" || fail "bundle removed" "$RENAMED_APP still exists"
[[ ! -d "$DIR" ]] && pass "definition removed" || fail "definition removed" "$DIR still exists"
if /bin/ls "$HOME/Library/Application Support/Doppel/state/Removed/" 2>/dev/null | grep -q "$SLUG"; then
    pass "definition preserved for undo"
else
    fail "definition preserved for undo" "nothing kept under state/Removed"
fi

print -r -- ""
print -r -- "$PASSED passed, $FAILED failed"
(( FAILED == 0 ))
