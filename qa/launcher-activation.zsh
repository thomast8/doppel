#!/bin/zsh
# Isolated AppKit contract test for the private exact-process focus hand-off.
# All app bundles and processes are disposable fixtures under one temp root.

set -eu
setopt PIPE_FAIL

readonly REPO_ROOT="${0:A:h:h}"
readonly FIXTURE="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/doppel-activation-qa.XXXXXXXX")"
readonly ACTIVATOR_APP="$FIXTURE/Doppel Activator.app"
readonly FOCUS_APP="$FIXTURE/Focus Target.app"
readonly BACKGROUND_APP="$FIXTURE/Background Target.app"
typeset -a FIXTURE_PIDS=()
typeset -i PASSED=0 FAILED=0

cleanup() {
    local pid
    for pid in $FIXTURE_PIDS; do
        [[ "$pid" == <1-> ]] && /bin/kill "$pid" >/dev/null 2>&1 || true
    done
    [[ "$FIXTURE" == */doppel-activation-qa.* ]] && /bin/rm -rf "$FIXTURE"
}
trap cleanup EXIT

pass() { print -r -- "  ✓ $1"; (( PASSED += 1 )); return 0; }
fail() { print -r -- "  ✗ $1"; print -r -- "      $2"; (( FAILED += 1 )); return 0; }

typeset OUT="" STATUS=0
run_activator() {
    STATUS=0
    OUT="$("$ACTIVATOR_APP/Contents/MacOS/Activator" --doppel-activate "$@" 2>&1)" || STATUS=$?
    return 0
}

run_routed_activator() {
    {
        printf 'TARGET_PID=%q\n' "$1"
        printf 'TARGET_BUNDLE_ID=%q\n' "$2"
        printf 'TARGET_APP=%q\n' "$3"
    } > "$FIXTURE/activation-request.zsh"
    : > "$FIXTURE/activator.stdout"
    : > "$FIXTURE/activator.stderr"
    STATUS=0
    /usr/bin/open -n -W \
        --stdout "$FIXTURE/activator.stdout" \
        --stderr "$FIXTURE/activator.stderr" \
        "$ACTIVATOR_APP" || STATUS=$?
    OUT="$(<"$FIXTURE/activator.stderr")"
    return 0
}

wait_for_app_pid() {
    local executable="$1" canonical="${1:A}" waited=0 pid=""
    while (( waited < 50 )); do
        pid="$(/bin/ps -ww -axo pid=,comm= | while read -r candidate command; do
            [[ "${command:A}" == "$canonical" ]] && print -r -- "$candidate"
        done | /usr/bin/head -1)"
        if [[ "$pid" == <1-> ]]; then
            print -r -- "$pid"
            return 0
        fi
        /bin/sleep 0.1
        waited=$(( waited + 1 ))
    done
    return 1
}

wait_for_pid_exit() {
    local pid="$1" waited=0
    while (( waited < 50 )); do
        /bin/kill -0 "$pid" >/dev/null 2>&1 || return 0
        /bin/sleep 0.1
        waited=$(( waited + 1 ))
    done
    return 1
}

write_plist() {
    local app="$1" identifier="$2" executable="$3" background="${4:-false}"
    local info="$app/Contents/Info.plist"
    /bin/mkdir -p "$app/Contents/MacOS"
    /usr/bin/plutil -create xml1 "$info"
    /usr/bin/plutil -insert CFBundleIdentifier -string "$identifier" "$info"
    /usr/bin/plutil -insert CFBundleName -string "${app:t:r}" "$info"
    /usr/bin/plutil -insert CFBundleDisplayName -string "${app:t:r}" "$info"
    /usr/bin/plutil -insert CFBundleExecutable -string "$executable" "$info"
    /usr/bin/plutil -insert CFBundlePackageType -string APPL "$info"
    [[ "$background" == true ]] && /usr/bin/plutil -insert LSBackgroundOnly -bool true "$info"
    return 0
}

print -r -- "Launcher activation QA"

print -r -- ""
print -r -- "build the signed launcher fixture"
write_plist "$ACTIVATOR_APP" ai.doppel.activation-qa Activator
/bin/mkdir -p "$ACTIVATOR_APP/Contents/Resources/Doppel"
/usr/bin/clang -fobjc-arc -O2 \
    -framework Cocoa -framework ApplicationServices -framework AVFoundation \
    -framework UserNotifications -framework Security -framework CoreServices \
    -o "$ACTIVATOR_APP/Contents/MacOS/Activator" "$REPO_ROOT/engine/launcher/main.m"
{
    print -r -- '#!/bin/zsh'
    printf 'readonly REQUEST=%q\n' "$FIXTURE/activation-request.zsh"
    print -r -- '[[ -r "$REQUEST" ]] || exit 0'
    print -r -- 'source "$REQUEST"'
    print -r -- 'exec "${0:A:h:h:h}/MacOS/Activator" --doppel-activate "$TARGET_PID" "$TARGET_BUNDLE_ID" "$TARGET_APP"'
} > "$ACTIVATOR_APP/Contents/Resources/Doppel/doppel-engine.zsh"
/bin/chmod 755 "$ACTIVATOR_APP/Contents/Resources/Doppel/doppel-engine.zsh"
/usr/bin/plutil -insert DoppelSigningIdentifier -string ai.doppel.activation-qa \
    "$ACTIVATOR_APP/Contents/Info.plist"
/usr/bin/codesign --force --sign - --identifier ai.doppel.activation-qa \
    "$ACTIVATOR_APP" >/dev/null 2>&1
if /usr/bin/codesign --verify --strict "$ACTIVATOR_APP" >/dev/null 2>&1; then
    pass "launcher fixture is strictly valid"
else
    fail "launcher fixture is strictly valid" "codesign rejected the fixture"
fi

/usr/bin/clang -fobjc-arc -O2 -framework Cocoa \
    -x objective-c -o "$FIXTURE/target" - <<'TARGET'
#import <Cocoa/Cocoa.h>

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        BOOL background = [[NSBundle.mainBundle objectForInfoDictionaryKey:@"LSBackgroundOnly"] boolValue];
        if (background) {
            [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        } else {
            [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
            NSWindow *window = [[NSWindow alloc]
                initWithContentRect:NSMakeRect(100, 100, 320, 180)
                styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
                backing:NSBackingStoreBuffered
                defer:NO];
            window.title = @"Doppel Activation QA";
            [window orderFront:nil];
        }
        [NSApp run];
    }
    return 0;
}
TARGET

for fixture in "${FOCUS_APP}:ai.doppel.focus-target:FocusTarget:false" \
               "${BACKGROUND_APP}:ai.doppel.background-target:BackgroundTarget:true"; do
    IFS=: read -r app identifier executable background <<< "$fixture"
    write_plist "$app" "$identifier" "$executable" "$background"
    /bin/cp "$FIXTURE/target" "$app/Contents/MacOS/$executable"
    /usr/bin/codesign --force --sign - --identifier "$identifier" "$app" >/dev/null 2>&1
done

print -r -- ""
print -r -- "reject malformed and stale process identities"
run_activator not-a-pid ai.doppel.focus-target "$FOCUS_APP"
[[ "$STATUS" == 64 && "$OUT" == *"invalid process identifier"* ]] \
    && pass "invalid PID is refused" \
    || fail "invalid PID is refused" "status $STATUS, output: $OUT"

/usr/bin/open -n -g "$FOCUS_APP"
FOCUS_PID="$(wait_for_app_pid "$FOCUS_APP/Contents/MacOS/FocusTarget")" || {
    fail "focus target launches" "the fixture process never appeared"; exit 1
}
FIXTURE_PIDS+=("$FOCUS_PID")

run_activator "$FOCUS_PID" ai.doppel.wrong "$FOCUS_APP"
[[ "$STATUS" == 77 && "$OUT" == *"different bundle identifier"* ]] \
    && pass "wrong bundle identifier is refused" \
    || fail "wrong bundle identifier is refused" "status $STATUS, output: $OUT"

run_activator "$FOCUS_PID" ai.doppel.focus-target "$BACKGROUND_APP"
[[ "$STATUS" == 77 && "$OUT" == *"different bundle path"* ]] \
    && pass "wrong bundle path is refused" \
    || fail "wrong bundle path is refused" "status $STATUS, output: $OUT"

print -r -- ""
print -r -- "activate only the exact regular application"
run_routed_activator "$FOCUS_PID" ai.doppel.focus-target "$FOCUS_APP"
[[ "$STATUS" == 0 ]] \
    && [[ "$OUT" != *"did not become frontmost"* ]] \
    && pass "Dock-routed launcher makes the verified regular app frontmost" \
    || fail "Dock-routed launcher makes the verified regular app frontmost" "status $STATUS, output: $OUT"

/bin/kill -KILL "$FOCUS_PID" >/dev/null 2>&1 || true
wait_for_pid_exit "$FOCUS_PID" || {
    fail "focus target stops" "fixture PID $FOCUS_PID did not exit"; exit 1
}
run_activator "$FOCUS_PID" ai.doppel.focus-target "$FOCUS_APP"
[[ "$STATUS" == 69 && "$OUT" == *"no longer running"* ]] \
    && pass "stopped process is refused" \
    || fail "stopped process is refused" "status $STATUS, output: $OUT"

print -r -- ""
print -r -- "report an application that cannot become frontmost"
/usr/bin/open -n -g "$BACKGROUND_APP"
BACKGROUND_PID="$(wait_for_app_pid "$BACKGROUND_APP/Contents/MacOS/BackgroundTarget")" || {
    fail "background target launches" "the fixture process never appeared"; exit 1
}
FIXTURE_PIDS+=("$BACKGROUND_PID")
run_activator "$BACKGROUND_PID" ai.doppel.background-target "$BACKGROUND_APP"
[[ "$STATUS" == 75 && ( "$OUT" == *"activation request"* || "$OUT" == *"did not become frontmost"* ) ]] \
    && pass "activation refusal is reported" \
    || fail "activation refusal is reported" "status $STATUS, output: $OUT"

print -r -- ""
print -r -- "$PASSED passed, $FAILED failed"
(( FAILED == 0 ))
