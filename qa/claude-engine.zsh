#!/bin/zsh
# Build a real Claude instance through the shared CLI, preserving QA artifacts.
set -eu
setopt PIPE_FAIL
readonly REPO_ROOT="${0:A:h:h}"
python3 "$REPO_ROOT/qa/claude-patch.py"
mkdir -p "$REPO_ROOT/qa/.build"
readonly WORK="$(mktemp -d "$REPO_ROOT/qa/.build/claude-engine.XXXXXXXX")"
readonly NAME="Claude Doppel Engine $$"
readonly APP="$WORK/apps/$NAME.app"
export DOPPEL_DEV=1 DOPPEL_HOME="$WORK/doppel" DOPPEL_STATE_ROOT="$WORK/engine-state"
export DOPPEL_PIN_ROOT="$WORK/pins" DOPPEL_NO_ALERT=1 DOPPEL_RELAUNCH=0
export DOPPEL_SIGN_IDENTITY_NAME="Doppel Claude QA No Identity" DOPPEL_SIGN_IDENTITY=-
print -r -- "QA artifacts retained at $WORK"
"$REPO_ROOT/bin/doppel" --app claude create --name "$NAME" --original-icon \
    --profile-root "$WORK/profile" --claude-config-dir "$WORK/code" --install-to "$WORK/apps"
[[ -x "$APP/Contents/MacOS/Claude.real" ]]
[[ "$(/usr/bin/plutil -extract CFBundleName raw "$APP/Contents/Info.plist")" == Claude ]]
[[ "$(/usr/bin/plutil -extract CFBundleDisplayName raw "$APP/Contents/Info.plist")" == "$NAME" ]]
/usr/bin/codesign --verify --deep --strict "$APP"
/usr/bin/python3 "$REPO_ROOT/engine/patch-deep-link.py" --app claude verify "$APP/Contents/Resources/app.asar"
"$APP/Contents/MacOS/Claude" --doppel-verify
"$REPO_ROOT/bin/doppel" --app claude list --porcelain
"$REPO_ROOT/bin/doppel" --app claude rebuild "$NAME"
"$REPO_ROOT/bin/doppel" --app claude edit "$NAME" --rename "$NAME Renamed"
[[ -d "$WORK/apps/$NAME Renamed.app" ]]
[[ "$(/usr/bin/plutil -extract CFBundleName raw "$WORK/apps/$NAME Renamed.app/Contents/Info.plist")" == Claude ]]
/usr/bin/codesign --verify --deep --strict "$WORK/apps/$NAME Renamed.app"
readonly SECOND="$NAME Second"
"$REPO_ROOT/bin/doppel" --app claude create --name "$SECOND" --tint 3B82F6 \
    --profile-root "$WORK/profile-b" --claude-config-dir "$WORK/code-b" --install-to "$WORK/apps"
readonly FIRST_APP="$WORK/apps/$NAME Renamed.app"
readonly SECOND_APP="$WORK/apps/$SECOND.app"
if /usr/bin/cmp -s "$FIRST_APP/Contents/Resources/electron.icns" "$SECOND_APP/Contents/Resources/electron.icns"; then
    print -u2 -- "The tinted Claude icon did not change"
    exit 1
fi
readonly HELPER="$DOPPEL_HOME/build/doppel-url-handler"
typeset -a TEST_PIDS=()
restore_callback() {
    "$HELPER" set claude /Applications/Claude.app com.anthropic.claudefordesktop >/dev/null 2>&1 || true
    for pid in $TEST_PIDS; do /bin/kill "$pid" 2>/dev/null || true; done
}
trap restore_callback EXIT
wait_for_runtime() {
    local pid="$1" app="$2" attempt
    for attempt in {1..80}; do
        [[ "$(/bin/ps -p "$pid" -o comm= 2>/dev/null)" == "$app/Contents/MacOS/Claude.real" && ! -d "$DOPPEL_HOME/state/IABCoordinator.lock" ]] && return 0
        /bin/kill -0 "$pid" 2>/dev/null || { print -u2 -- "Claude runtime exited before adoption"; return 1; }
        sleep .25
    done
    print -u2 -- "Claude runtime adoption timed out"
    return 1
}
"$FIRST_APP/Contents/MacOS/Claude" > "$WORK/first-launch.log" 2>&1 &
FIRST_PID=$!
TEST_PIDS+=($FIRST_PID)
wait_for_runtime "$FIRST_PID" "$FIRST_APP"
"$SECOND_APP/Contents/MacOS/Claude" > "$WORK/second-launch.log" 2>&1 &
SECOND_PID=$!
TEST_PIDS+=($SECOND_PID)
wait_for_runtime "$SECOND_PID" "$SECOND_APP"
FIRST_SLUG="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["slug"])' "$FIRST_APP/Contents/Resources/Doppel/claude.json")"
SECOND_SLUG="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["slug"])' "$SECOND_APP/Contents/Resources/Doppel/claude.json")"
"$REPO_ROOT/bin/doppel" --app claude __auth-claim "$FIRST_SLUG" "$FIRST_PID"
[[ "$("$HELPER" get claude)" == "$(/usr/bin/plutil -extract CFBundleIdentifier raw "$FIRST_APP/Contents/Info.plist")" ]]
if "$REPO_ROOT/bin/doppel" --app claude rebuild "$SECOND_SLUG" > "$WORK/rebuild-during-login.log" 2>&1; then
    print -u2 -- "A rebuild was allowed to reset an active sign-in callback"
    exit 1
fi
/usr/bin/grep -q 'Finish the active Claude sign-in' "$WORK/rebuild-during-login.log"
if "$REPO_ROOT/bin/doppel" --app claude __auth-idle >/dev/null 2>&1; then
    print -u2 -- "Self-healing was allowed during an active sign-in"
    exit 1
fi
[[ "$("$HELPER" get claude)" == "$(/usr/bin/plutil -extract CFBundleIdentifier raw "$FIRST_APP/Contents/Info.plist")" ]]
if "$REPO_ROOT/bin/doppel" --app claude __auth-claim "$SECOND_SLUG" "$SECOND_PID" > "$WORK/competing-login.log" 2>&1; then
    print -u2 -- "A competing sign-in stole the callback"
    exit 1
fi
/usr/bin/grep -q 'another Claude instance is signing in' "$WORK/competing-login.log"
[[ "$("$HELPER" get claude)" == "$(/usr/bin/plutil -extract CFBundleIdentifier raw "$FIRST_APP/Contents/Info.plist")" ]]
"$REPO_ROOT/bin/doppel" --app claude __auth-release "$FIRST_SLUG" "$FIRST_PID"
[[ "$("$HELPER" get claude)" == com.anthropic.claudefordesktop ]]
"$REPO_ROOT/bin/doppel" --app claude __auth-claim "$SECOND_SLUG" "$SECOND_PID"
"$REPO_ROOT/bin/doppel" --app claude __auth-release "$SECOND_SLUG" "$SECOND_PID"
[[ "$("$HELPER" get claude)" == com.anthropic.claudefordesktop ]]
mkdir -p "$WORK/profile"
print -r -- retained > "$WORK/profile/qa-data-sentinel"
"$REPO_ROOT/bin/doppel" --app claude remove "$NAME Renamed"
"$REPO_ROOT/bin/doppel" --app claude remove "$SECOND"
TEST_PIDS=()
[[ "$(cat "$WORK/profile/qa-data-sentinel")" == retained ]]
print -r -- "Shared Claude lifecycle, two live runtimes, exclusive callback ownership and data-preserving removal passed. No account sign-in performed."
