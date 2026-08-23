#!/bin/zsh
# Isolated contract test for the movable built-in-browser engine slot.
#
# It uses the real installed vendor signature, but all Doppel state, instance
# definitions, app placeholders and profile paths live under one temporary
# directory. DOPPEL_IAB_DRY_RUN proves the exact launch selection without
# opening or terminating any ChatGPT process.

set -eu
setopt PIPE_FAIL

readonly REPO_ROOT="${0:A:h:h}"
readonly CLI="$REPO_ROOT/bin/doppel"
readonly PRIMARY="${DOPPEL_PRIMARY_APP:-/Applications/ChatGPT.app}"
readonly FIXTURE="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/doppel-iab-qa.XXXXXXXX")"
readonly FIXTURE_HOME="$FIXTURE/home"
readonly FIXTURE_STATE="$FIXTURE/doppel"

cleanup() {
    [[ -n "$FIXTURE" && -d "$FIXTURE" && "$FIXTURE" == */doppel-iab-qa.* ]] || return 0
    /bin/rm -rf "$FIXTURE"
}
trap cleanup EXIT

fail() { print -u2 -r -- "iab-engine QA: $1"; exit 1 }
expect() { [[ "$1" == "$2" ]] || fail "$3 (expected '$2', got '$1')"; }

[[ -d "$PRIMARY" ]] || fail "the official ChatGPT app is required at $PRIMARY"
/usr/bin/codesign --verify --deep --strict "$PRIMARY" >/dev/null 2>&1 || \
    fail "the official ChatGPT app failed strict signature verification"
PRIMARY_BUILD="$(/usr/bin/plutil -extract CFBundleVersion raw "$PRIMARY/Contents/Info.plist" 2>/dev/null)"
[[ "$PRIMARY_BUILD" == <1-> ]] || fail "the official ChatGPT build number is invalid"

write_instance() {
    local slug="$1" name="$2" tint="$3"
    local dir="$FIXTURE_STATE/instances/$slug"
    local app_root="$FIXTURE_HOME/Applications"
    local app="$app_root/$name.app"
    /bin/mkdir -p "$dir" "$app/Contents/MacOS"
    /usr/bin/plutil -create xml1 "$app/Contents/Info.plist"
    /usr/bin/plutil -insert DoppelSourceBundleVersion -string "$PRIMARY_BUILD" \
        "$app/Contents/Info.plist"
    /usr/bin/plutil -insert DoppelEngineVersion -string "24" \
        "$app/Contents/Info.plist"
    /bin/mkdir -p "$app/Contents/Resources/Doppel/bin" \
        "$app/Contents/Resources/Doppel/engine"
    /bin/cp "$CLI" "$app/Contents/Resources/Doppel/bin/doppel"
    : > "$app/Contents/Resources/Doppel/engine/doppel-engine.zsh"
    : > "$app/Contents/Resources/Doppel/engine/patch-deep-link.py"
    /bin/chmod 755 "$app/Contents/Resources/Doppel/bin/doppel" \
        "$app/Contents/Resources/Doppel/engine/doppel-engine.zsh"
    {
        print -r -- '#!/bin/zsh'
        print -r -- '[[ "${1:-}" == "--doppel-verify" ]]'
    } > "$app/Contents/MacOS/ChatGPT"
    /bin/chmod 755 "$app/Contents/MacOS/ChatGPT"
    /usr/bin/plutil -insert DoppelRouterSHA256 -string \
        "$(/usr/bin/shasum -a 256 "$CLI" | /usr/bin/awk '{print $1}')" \
        "$app/Contents/Info.plist"
    {
        print -r -- "# QA fixture"
        printf 'DOPPEL_DISPLAY_NAME=%q\n' "$name"
        printf 'DOPPEL_BUNDLE_ID=%q\n' "com.openai.codex.$slug"
        printf 'DOPPEL_URL_SCHEME=%q\n' "codex-$slug"
        printf 'DOPPEL_PROFILE_ROOT=%q\n' "$FIXTURE_HOME/Library/Application Support/$name"
        printf 'DOPPEL_CODEX_HOME=%q\n' "$FIXTURE_HOME/.codex-$slug"
        printf 'DOPPEL_TINT=%q\n' "$tint"
    } > "$dir/instance-config.zsh"
    print -r -- "$app_root" > "$dir/install-root"
}

/bin/mkdir -p "$FIXTURE_STATE/instances"
write_instance personal "ChatGPT Personal QA" A855F7
write_instance work "ChatGPT Work QA" 1FA97E

run_cli() {
    HOME="$FIXTURE_HOME" \
    DOPPEL_HOME="$FIXTURE_STATE" \
    DOPPEL_PRIMARY_APP="$PRIMARY" \
    DOPPEL_DEV=1 \
    DOPPEL_IAB_DRY_RUN=1 \
        "$CLI" "$@"
}

expect "$(run_cli browser status --porcelain)" "unassigned" \
    "a fresh state root should have no engine assignment"

# Assignment promises that Finder/Dock launches are transparent too. A clone
# from before the embedded router existed must be rebuilt before it can own the
# slot, otherwise opening its branded icon would still bypass the official app.
PERSONAL_INFO="$FIXTURE_HOME/Applications/ChatGPT Personal QA.app/Contents/Info.plist"
/usr/bin/plutil -replace DoppelEngineVersion -string "23" "$PERSONAL_INFO"
if old_router_output="$(run_cli browser assign "ChatGPT Personal QA" 2>&1)"; then
    fail "a pre-router clone should not be assigned the built-in browser"
fi
[[ "$old_router_output" == *"not ready for transparent Built-in Browser routing"* ]] || \
    fail "the pre-router refusal should explain that a rebuild is required"
expect "$(run_cli browser status --porcelain)" "unassigned" \
    "a failed pre-router assignment must leave the slot empty"
/usr/bin/plutil -replace DoppelEngineVersion -string "24" "$PERSONAL_INFO"

# Slot transitions share one PID-owned operation lock. A live owner must block
# another command, while a dead owner's exact lock is reclaimed safely.
LOCK="$FIXTURE_STATE/state/IABCoordinator.lock"
/bin/mkdir -p "$LOCK"
print -r -- "$$" > "$LOCK/pid"
if locked_output="$(run_cli browser assign "ChatGPT Personal QA" 2>&1)"; then
    fail "a live engine-operation lock should block assignment"
fi
[[ "$locked_output" == *"another Doppel engine operation is already in progress"* ]] || \
    fail "the live-lock refusal should explain the conflict"
/bin/rm -f "$LOCK/pid"
/bin/rmdir "$LOCK"
/bin/mkdir "$LOCK"
print -r -- "99999999" > "$LOCK/pid"
run_cli browser assign "ChatGPT Personal QA" >/dev/null
[[ ! -e "$LOCK" ]] || fail "a completed operation should release a reclaimed stale lock"

# An ownerless directory can be the tiny mkdir-before-PID window. It is live
# while fresh, but recoverable after its age proves the creator died.
/bin/mkdir "$LOCK"
if ownerless_output="$(run_cli browser assign "ChatGPT Personal QA" 2>&1)"; then
    fail "a fresh ownerless engine lock should not be stolen"
fi
[[ "$ownerless_output" == *"another Doppel engine operation is already in progress"* ]] || \
    fail "the fresh ownerless-lock refusal should explain the conflict"
/usr/bin/touch -t 200001010000 "$LOCK"
run_cli browser assign "ChatGPT Personal QA" >/dev/null
[[ ! -e "$LOCK" ]] || fail "an old ownerless engine lock should be reclaimed"
expect "$(run_cli browser status --porcelain | /usr/bin/cut -f1-4)" \
    $'assigned\tpersonal\tChatGPT Personal QA\tstopped' \
    "assignment should retain the stable profile and stopped runtime state"
expect "$(/usr/bin/stat -f '%Lp' "$FIXTURE_STATE/state/iab-engine-slot")" "600" \
    "the engine-slot state should be private"
expect "$(run_cli list --porcelain | /usr/bin/awk -F '\t' '$1 == "personal" { print $6 }')" \
    "vendor" "the assigned profile should resolve to the vendor engine"
expect "$(run_cli list --porcelain | /usr/bin/awk -F '\t' '$1 == "work" { print $6 }')" \
    "clone" "an unassigned profile should keep the clone engine"
expect "$(run_cli launch "ChatGPT Personal QA")" \
    $'vendor-launch\t'"$PRIMARY"$'\t'"$FIXTURE_HOME/Library/Application Support/ChatGPT Personal QA"$'\t'"$FIXTURE_HOME/.codex-personal"$'\tsparkle-disabled' \
    "launch should select the untouched vendor bundle, both profile roots and disable self-update"

# Hold a dry-run launch inside its check-to-adoption window. Release must not
# cross that window; this is the concrete race the global lock exists to close.
DELAYED_LAUNCH_FILE="$FIXTURE/delayed-launch.out"
(
    # A background zsh subshell inherits the QA EXIT trap. Clear it before
    # exec so completing this one command cannot remove the parent's fixture.
    trap - EXIT
    exec /usr/bin/env \
        HOME="$FIXTURE_HOME" \
        DOPPEL_HOME="$FIXTURE_STATE" \
        DOPPEL_PRIMARY_APP="$PRIMARY" \
        DOPPEL_DEV=1 \
        DOPPEL_IAB_DRY_RUN=1 \
        DOPPEL_IAB_DRY_RUN_DELAY=2 \
        "$CLI" launch "ChatGPT Personal QA"
) > "$DELAYED_LAUNCH_FILE" &
DELAYED_PID=$!
for _ in {1..30}; do
    [[ -d "$LOCK" ]] && break
    /bin/sleep 0.1
done
[[ -d "$LOCK" ]] || fail "the delayed launch never acquired the engine-operation lock"
if concurrent_output="$(run_cli browser release 2>&1)"; then
    fail "release should not cross a launch's profile-adoption window"
fi
[[ "$concurrent_output" == *"another Doppel engine operation is already in progress"* ]] || \
    fail "the concurrent release should report the held engine lock"
wait "$DELAYED_PID"
[[ -f "$DELAYED_LAUNCH_FILE" ]] || fail "the delayed launch produced no result"
expect "$(/bin/cat "$DELAYED_LAUNCH_FILE")" \
    $'vendor-launch\t'"$PRIMARY"$'\t'"$FIXTURE_HOME/Library/Application Support/ChatGPT Personal QA"$'\t'"$FIXTURE_HOME/.codex-personal"$'\tsparkle-disabled' \
    "the serialized launch should complete normally"
expect "$(run_cli browser status --porcelain | /usr/bin/cut -f1-2)" \
    $'assigned\tpersonal' "a blocked concurrent release must preserve the slot"

# A signal aimed at the coordinator must not release the lock while its worker
# is still inside the launch/adoption critical section. The operation finishes
# safely, then the coordinator returns the conventional signal exit status.
SIGNALLED_LAUNCH_FILE="$FIXTURE/signalled-launch.out"
(
    trap - EXIT
    exec /usr/bin/env \
        HOME="$FIXTURE_HOME" \
        DOPPEL_HOME="$FIXTURE_STATE" \
        DOPPEL_PRIMARY_APP="$PRIMARY" \
        DOPPEL_DEV=1 \
        DOPPEL_IAB_DRY_RUN=1 \
        DOPPEL_IAB_DRY_RUN_DELAY=2 \
        "$CLI" launch "ChatGPT Personal QA"
) > "$SIGNALLED_LAUNCH_FILE" &
SIGNALLED_PID=$!
for _ in {1..30}; do
    [[ -d "$LOCK" ]] && break
    /bin/sleep 0.1
done
[[ -d "$LOCK" ]] || fail "the signalled launch never acquired the engine-operation lock"
/bin/kill -TERM "$SIGNALLED_PID"
/bin/sleep 0.2
[[ -d "$LOCK" ]] || fail "a signal released the engine lock before its worker finished"
if wait "$SIGNALLED_PID"; then
    fail "a term-signalled coordinator should return a signal status"
else
    SIGNALLED_STATUS=$?
fi
expect "$SIGNALLED_STATUS" "143" "the coordinator should report deferred SIGTERM"
expect "$(/bin/cat "$SIGNALLED_LAUNCH_FILE")" \
    $'vendor-launch\t'"$PRIMARY"$'\t'"$FIXTURE_HOME/Library/Application Support/ChatGPT Personal QA"$'\t'"$FIXTURE_HOME/.codex-personal"$'\tsparkle-disabled' \
    "a signalled launch should finish its protected adoption work"
[[ ! -e "$LOCK" ]] || fail "the signalled operation should release its lock after completion"

# Even if both the coordinator and its supervisor are killed, the recorded
# process-group lease must keep a surviving worker protected. Once the group is
# empty, the next command may reclaim the dead lease normally.
ORPHANED_LAUNCH_FILE="$FIXTURE/orphaned-launch.out"
(
    trap - EXIT
    exec /usr/bin/env \
        HOME="$FIXTURE_HOME" \
        DOPPEL_HOME="$FIXTURE_STATE" \
        DOPPEL_PRIMARY_APP="$PRIMARY" \
        DOPPEL_DEV=1 \
        DOPPEL_IAB_DRY_RUN=1 \
        DOPPEL_IAB_DRY_RUN_DELAY=2 \
        "$CLI" launch "ChatGPT Personal QA"
) > "$ORPHANED_LAUNCH_FILE" &
ORPHANED_COORDINATOR_PID=$!
for _ in {1..30}; do
    [[ -r "$LOCK/pid" ]] && break
    /bin/sleep 0.1
done
[[ -r "$LOCK/pid" ]] || fail "the orphaned launch never published its lock owner"
ORPHANED_GROUP_PID="$(/bin/cat "$LOCK/pid")"
[[ "$ORPHANED_GROUP_PID" == <1-> ]] || fail "the engine lock did not contain a process-group id"
for _ in {1..30}; do
    [[ -n "$(/usr/bin/pgrep -P "$ORPHANED_GROUP_PID" 2>/dev/null || true)" ]] && break
    /bin/sleep 0.1
done
[[ -n "$(/usr/bin/pgrep -P "$ORPHANED_GROUP_PID" 2>/dev/null || true)" ]] || \
    fail "the supervisor never started its isolated worker"
/bin/kill -KILL "$ORPHANED_COORDINATOR_PID"
/bin/kill -KILL "$ORPHANED_GROUP_PID"
wait "$ORPHANED_COORDINATOR_PID" 2>/dev/null || true
/bin/sleep 0.2
[[ -d "$LOCK" ]] || fail "supervisor death released a lock while its worker group survived"
if orphan_conflict="$(run_cli browser release 2>&1)"; then
    fail "a live orphaned worker group should block another engine operation"
fi
[[ "$orphan_conflict" == *"another Doppel engine operation is already in progress"* ]] || \
    fail "the orphaned-worker refusal should explain the live lock"
for _ in {1..50}; do
    /bin/kill -0 -- "-$ORPHANED_GROUP_PID" 2>/dev/null || break
    /bin/sleep 0.1
done
/bin/kill -0 -- "-$ORPHANED_GROUP_PID" 2>/dev/null && \
    fail "the orphaned engine worker group did not finish"
expect "$(/bin/cat "$ORPHANED_LAUNCH_FILE")" \
    $'vendor-launch\t'"$PRIMARY"$'\t'"$FIXTURE_HOME/Library/Application Support/ChatGPT Personal QA"$'\t'"$FIXTURE_HOME/.codex-personal"$'\tsparkle-disabled' \
    "the orphaned worker should finish before its lease becomes stale"
run_cli browser assign "ChatGPT Personal QA" >/dev/null
[[ ! -e "$LOCK" ]] || fail "the dead process-group lease should be reclaimed after completion"

run_cli browser assign "ChatGPT Work QA" >/dev/null
expect "$(run_cli list --porcelain | /usr/bin/awk -F '\t' '$1 == "personal" { print $6 }')" \
    "clone" "moving the slot should return the old profile to its clone engine"
expect "$(run_cli native-tools status --porcelain | /usr/bin/awk -F '\t' '$1 == "in-app-browser" { print $2 FS $3 FS $4 }')" \
    $'assigned\twork\tChatGPT Work QA' \
    "native-tools status should report the selected profile"

# Releasing returns the profile to its fallback clone, so a build mismatch must
# leave the assignment intact rather than opening newer profile data in an old
# Electron runtime.
WORK_INFO="$FIXTURE_HOME/Applications/ChatGPT Work QA.app/Contents/Info.plist"
/usr/bin/plutil -replace DoppelSourceBundleVersion -string "1" "$WORK_INFO"
if mismatch_output="$(run_cli browser release 2>&1)"; then
    fail "release should refuse a fallback clone built from another version"
fi
[[ "$mismatch_output" == *"Rebuild the profile first"* ]] || \
    fail "the fallback mismatch should provide a rebuild instruction"
expect "$(run_cli browser status --porcelain | /usr/bin/cut -f1-2)" \
    $'assigned\twork' "a failed release should preserve the assignment"
/usr/bin/plutil -replace DoppelSourceBundleVersion -string "$PRIMARY_BUILD" "$WORK_INFO"
run_cli browser release >/dev/null
expect "$(run_cli browser status --porcelain)" "unassigned" \
    "release should empty the engine slot"

# The menu uses this opt-in form only after the user confirms its Quit and
# Assign alert. With no live process in the isolated fixture, it should remain
# a normal assignment and preserve the same routing contract.
run_cli browser assign --quit-running "ChatGPT Work QA" >/dev/null
expect "$(run_cli browser status --porcelain | /usr/bin/cut -f1-2)" \
    $'assigned\twork' "the confirmed assignment form should select the target profile"

# Browser extension support is an explicit, profile-local override. Start from
# a realistic remote cache and prove that Doppel changes only OwlExtensions.
WORK_PROFILE="$FIXTURE_HOME/Library/Application Support/ChatGPT Work QA"
FEATURE_CACHE="$WORK_PROFILE/owl-feature-bootstrap-cache.json"
RECEIPT="$FIXTURE_STATE/instances/work/browser-extensions-override.plist"
/bin/mkdir -p "$WORK_PROFILE"
print -r -- '{"enabledOwlFeatureNames":["OwlHistory","UnknownEnabled"],"disabledOwlFeatureNames":["OwlExtensions","UnknownDisabled"]}' > "$FEATURE_CACHE"
/bin/chmod 640 "$FEATURE_CACHE"
expect "$(run_cli browser extensions status --porcelain "ChatGPT Work QA")" "off" \
    "the remote-disabled feature should begin off"
print -u2 -r -- "iab-engine QA: extension enablement"
run_cli browser extensions enable "ChatGPT Work QA" >/dev/null
expect "$(run_cli browser extensions status --porcelain "ChatGPT Work QA")" "override" \
    "enable should publish the per-profile override"
[[ -r "$RECEIPT" ]] || fail "enable should create a private reconciliation receipt"
expect "$(/usr/bin/stat -f '%Lp' "$RECEIPT")" "600" \
    "the reconciliation receipt should be private"
expect "$(/usr/bin/stat -f '%Lp' "$FEATURE_CACHE")" "640" \
    "feature-cache permissions should survive the atomic rewrite"
feature_json="$(/usr/bin/plutil -convert json -o - "$FEATURE_CACHE")"
[[ "$feature_json" == *'"OwlExtensions"'* && "$feature_json" == *'"UnknownEnabled"'* && \
   "$feature_json" == *'"UnknownDisabled"'* ]] || \
    fail "enable should preserve unknown feature names"
[[ "$(/usr/bin/plutil -extract disabledOwlFeatureNames json -o - "$FEATURE_CACHE")" != *'"OwlExtensions"'* ]] || \
    fail "enable should remove OwlExtensions from the disabled list"

first_digest="$(/usr/bin/shasum -a 256 "$FEATURE_CACHE" | /usr/bin/awk '{print $1}')"
run_cli browser extensions enable "ChatGPT Work QA" >/dev/null
expect "$(/usr/bin/shasum -a 256 "$FEATURE_CACHE" | /usr/bin/awk '{print $1}')" "$first_digest" \
    "repeat enable should be idempotent"

# Simulate an OpenAI cache refresh. Launch reconciliation must restore only the
# requested feature and update the receipt to the new exact digest.
print -u2 -r -- "iab-engine QA: extension cache reconciliation"
print -r -- '{"enabledOwlFeatureNames":["OwlPrinting","RemoteNew"],"disabledOwlFeatureNames":["OwlExtensions","RemoteDisabled"]}' > "$FEATURE_CACHE"
if ! refresh_launch_output="$(run_cli launch "ChatGPT Work QA" 2>&1)"; then
    fail "launch reconciliation failed: $refresh_launch_output"
fi
[[ "$refresh_launch_output" == vendor-launch$'\t'* ]] || \
    fail "launch reconciliation should continue to the official engine"
[[ "$(/usr/bin/plutil -extract enabledOwlFeatureNames json -o - "$FEATURE_CACHE")" == *'"RemoteNew"'* ]] || \
    fail "launch reconciliation should preserve refreshed remote features"
[[ "$(/usr/bin/plutil -extract enabledOwlFeatureNames json -o - "$FEATURE_CACHE")" == *'"OwlExtensions"'* ]] || \
    fail "launch reconciliation should re-enable OwlExtensions"

# If OpenAI's next refresh enables the feature itself, Doppel must retire its
# override instead of later restoring an obsolete disabled value.
print -r -- '{"enabledOwlFeatureNames":["OwlExtensions","OpenAIEnabled"],"disabledOwlFeatureNames":[]}' > "$FEATURE_CACHE"
run_cli launch "ChatGPT Work QA" >/dev/null
expect "$(run_cli browser extensions status --porcelain "ChatGPT Work QA")" "upstream" \
    "an upstream enablement should supersede Doppel's override"
[[ ! -e "$RECEIPT" ]] || fail "an upstream enablement should retire the override receipt"

# If ChatGPT changes the cache after Doppel writes it, disabling drops the
# receipt but must not overwrite the newer state.
print -r -- '{"enabledOwlFeatureNames":["OwlPrinting"],"disabledOwlFeatureNames":["OwlExtensions"]}' > "$FEATURE_CACHE"
run_cli browser extensions enable "ChatGPT Work QA" >/dev/null
print -r -- '{"enabledOwlFeatureNames":["OpenAINewer"],"disabledOwlFeatureNames":[]}' > "$FEATURE_CACHE"
newer_digest="$(/usr/bin/shasum -a 256 "$FEATURE_CACHE" | /usr/bin/awk '{print $1}')"
run_cli browser extensions disable "ChatGPT Work QA" >/dev/null
expect "$(/usr/bin/shasum -a 256 "$FEATURE_CACHE" | /usr/bin/awk '{print $1}')" "$newer_digest" \
    "digest-aware disable should leave newer OpenAI state untouched"
[[ ! -e "$RECEIPT" ]] || fail "digest-aware disable should remove the stale receipt"

# A clean disable restores the exact prior membership without deleting other
# Browser data or extension files.
print -u2 -r -- "iab-engine QA: extension rollback"
print -r -- '{"enabledOwlFeatureNames":["OwlHistory"],"disabledOwlFeatureNames":["OwlExtensions","KeepMe"]}' > "$FEATURE_CACHE"
/bin/mkdir -p "$WORK_PROFILE/Default/Extensions/example"
print -r -- keep > "$WORK_PROFILE/Default/Extensions/example/data"
run_cli browser extensions enable "ChatGPT Work QA" >/dev/null
run_cli browser extensions disable "ChatGPT Work QA" >/dev/null
[[ "$(/usr/bin/plutil -extract disabledOwlFeatureNames json -o - "$FEATURE_CACHE")" == *'"OwlExtensions"'* ]] || \
    fail "clean disable should restore the prior disabled membership"
[[ -f "$WORK_PROFILE/Default/Extensions/example/data" ]] || \
    fail "disable should keep installed extension data"

# Apple setup uses the exact official store URL. A routing failure after a new
# opt-in must restore the pre-command feature state and remove its receipt.
print -u2 -r -- "iab-engine QA: Apple Passwords routing"
apple_output="$(run_cli browser extensions apple-passwords "ChatGPT Work QA")"
[[ "$apple_output" == *$'\t'https://chromewebstore.google.com/detail/icloud-passwords/pejdijmoenmkgeppbflobdenhhabjlaj?hl=en ]] || \
    fail "Apple Passwords setup should route the exact official extension URL (got '$apple_output')"
run_cli browser extensions disable "ChatGPT Work QA" >/dev/null
if routing_output="$(DOPPEL_IAB_DRY_RUN_URL_ROUTING_FAILURE=1 run_cli browser extensions apple-passwords "ChatGPT Work QA" 2>&1)"; then
    fail "a Browser URL routing failure should fail Apple Passwords setup"
fi
[[ "$routing_output" == *"override was rolled back"* ]] || \
    fail "a routing failure should explain the automatic rollback"
expect "$(run_cli browser extensions status --porcelain "ChatGPT Work QA")" "off" \
    "a routing failure should leave the extension override off"
[[ ! -e "$RECEIPT" ]] || fail "a routing failure should not leave an override receipt"

# Malformed state, unsupported builds, and a running profile all fail before
# changing either the cache or receipt.
print -u2 -r -- "iab-engine QA: extension refusal cases"
print -r -- '{not-json' > "$FEATURE_CACHE"
malformed_digest="$(/usr/bin/shasum -a 256 "$FEATURE_CACHE" | /usr/bin/awk '{print $1}')"
if malformed_output="$(run_cli browser extensions enable "ChatGPT Work QA" 2>&1)"; then
    fail "malformed feature cache should be refused"
fi
[[ "$malformed_output" == *"feature cache is malformed"* ]] || \
    fail "malformed refusal should identify the feature cache"
expect "$(/usr/bin/shasum -a 256 "$FEATURE_CACHE" | /usr/bin/awk '{print $1}')" "$malformed_digest" \
    "malformed cache should remain byte-for-byte unchanged"
[[ ! -e "$RECEIPT" ]] || fail "malformed cache should not create a receipt"

# Builds that retain Browser routes but advertise no OwlExtensions feature in
# either the signed archive or the profile cache must still fail closed.
print -r -- '{"enabledOwlFeatureNames":["OwlHistory"],"disabledOwlFeatureNames":[]}' > "$FEATURE_CACHE"
if missing_feature_output="$(run_cli browser extensions enable "ChatGPT Work QA" 2>&1)"; then
    fail "a cache without OwlExtensions should be refused"
fi
[[ "$missing_feature_output" == *"does not support"* ]] || \
    fail "a missing OwlExtensions signal should identify the build capability"

print -r -- '{"enabledOwlFeatureNames":[],"disabledOwlFeatureNames":["OwlExtensions"]}' > "$FEATURE_CACHE"
if unsupported_output="$(DOPPEL_IAB_DRY_RUN_UNSUPPORTED_EXTENSIONS=1 run_cli browser extensions enable "ChatGPT Work QA" 2>&1)"; then
    fail "unsupported ChatGPT build should be refused"
fi
[[ "$unsupported_output" == *"does not support"* ]] || \
    fail "unsupported refusal should identify the build capability"
if running_output="$(DOPPEL_IAB_DRY_RUN_PROFILE_RUNNING=1 run_cli browser extensions enable "ChatGPT Work QA" 2>&1)"; then
    fail "running profile should require explicit quit consent"
fi
[[ "$running_output" == *"extensions change needs running ChatGPT apps to quit"* ]] || \
    fail "running refusal should match the menu's recoverable message"

run_cli browser release >/dev/null

# A malformed or stale slot is ignored for routing, but release should still
# remove it so the user's explicit reset is durable.
/bin/mkdir -p "$FIXTURE_STATE/state"
print -r -- '../not-an-instance' > "$FIXTURE_STATE/state/iab-engine-slot"
run_cli browser release >/dev/null
[[ ! -e "$FIXTURE_STATE/state/iab-engine-slot" ]] || \
    fail "release should remove an invalid engine-slot file"

print -r -- "iab-engine QA: passed"
