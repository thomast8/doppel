#!/bin/zsh
# Focused Doppel-to-Remodex contract tests using an argv-capturing fake bridge.

set -u
setopt PIPE_FAIL

readonly REPO_ROOT="${0:A:h:h}"
readonly CLI="$REPO_ROOT/bin/doppel"
readonly SCRATCH="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/doppel-remodex.XXXXXXXX")"
readonly DOPPEL_HOME_FIXTURE="$SCRATCH/Doppel Home"
readonly INSTANCE_DIR="$DOPPEL_HOME_FIXTURE/instances/personal"
readonly APP="$SCRATCH/Applications/ChatGPT Personal.app"
readonly CODEX_HOME_FIXTURE="$SCRATCH/Codex Home"
readonly BRIDGE="$SCRATCH/bin with spaces/remodex"
readonly CAPTURE="$SCRATCH/argv"
readonly STATUS_JSON="$SCRATCH/status.json"

typeset -i PASSED=0 FAILED=0
pass() { print -r -- "  ✓ $1"; (( PASSED += 1 )); }
fail() { print -r -- "  ✗ $1"; print -r -- "      $2"; (( FAILED += 1 )); }
check() { [[ "$2" == "$3" ]] && pass "$1" || fail "$1" "expected '$3', got '$2'"; }
cleanup() { /bin/rm -rf "$SCRATCH"; }
trap cleanup EXIT

/bin/mkdir -p "$INSTANCE_DIR" "$APP/Contents" "$CODEX_HOME_FIXTURE" "${BRIDGE:h}"
{
    printf 'DOPPEL_DISPLAY_NAME=%q\n' "ChatGPT Personal"
    printf 'DOPPEL_BUNDLE_ID=%q\n' "com.openai.codex.secondary"
    printf 'DOPPEL_URL_SCHEME=%q\n' "codex-secondary"
    printf 'DOPPEL_PROFILE_ROOT=%q\n' "$SCRATCH/Profile Root"
    printf 'DOPPEL_CODEX_HOME=%q\n' "$CODEX_HOME_FIXTURE"
    printf 'DOPPEL_TINT=%q\n' "F28C28"
} > "$INSTANCE_DIR/instance-config.zsh"
print -r -- "$SCRATCH/Applications" > "$INSTANCE_DIR/install-root"
/usr/bin/plutil -create xml1 "$APP/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleIdentifier -string com.openai.codex.secondary "$APP/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleURLTypes -json '[{"CFBundleURLSchemes":["codex-secondary"]}]' "$APP/Contents/Info.plist"

{
    print -r -- '#!/bin/zsh'
    print -r -- 'set -u'
    print -r -- ': > "$DOPPEL_TEST_CAPTURE"'
    print -r -- 'for argument in "$@"; do print -r -- "$argument" >> "$DOPPEL_TEST_CAPTURE"; done'
    print -r -- 'if [[ "${1:-}" == "status" ]]; then /bin/cat "$DOPPEL_TEST_STATUS"; exit 0; fi'
    print -r -- '[[ "${DOPPEL_TEST_FAIL:-0}" != "1" ]] || exit 9'
    print -r -- 'print -r -- "bridge ok"'
} > "$BRIDGE"
/bin/chmod 755 "$BRIDGE"

export DOPPEL_HOME="$DOPPEL_HOME_FIXTURE"
export DOPPEL_DEV=1
export DOPPEL_REMODEX_BIN="$BRIDGE"
export DOPPEL_TEST_CAPTURE="$CAPTURE"
export DOPPEL_TEST_STATUS="$STATUS_JSON"

print -r -- "Doppel Remodex contract"
OUT="$($CLI remodex use "ChatGPT Personal" 2>&1)"; STATUS=$?
check "use succeeds" "$STATUS" "0"
EXPECTED=$'target\nset\n--codex-home\n'"$CODEX_HOME_FIXTURE"$'\n--bundle-id\ncom.openai.codex.secondary\n--app-path\n'"$APP"$'\n--url-scheme\ncodex-secondary\n--restart'
check "paths with spaces remain exact argv" "$(<"$CAPTURE")" "$EXPECTED"

printf '%s\n' '{"daemonConfig":{"codexHome":"'"$CODEX_HOME_FIXTURE"'","codexBundleId":"com.openai.codex.secondary","codexAppPath":"'"$APP"'","codexUrlScheme":"codex-secondary","codexTargetFingerprint":"fingerprint"},"bridgeStatus":{"codexTargetFingerprint":"fingerprint","codexLaunchState":"connected"}}' > "$STATUS_JSON"
OUT="$($CLI remodex status --porcelain 2>&1)"; STATUS=$?
check "status readback succeeds" "$STATUS" "0"
check "status identifies the active instance" "$OUT" $'active\tpersonal\tChatGPT Personal\t'"$CODEX_HOME_FIXTURE"$'\tcom.openai.codex.secondary\t'"$APP"$'\tcodex-secondary'

print -r -- '{"daemonConfig":{"codexBundleId":"com.openai.codex"},"bridgeStatus":{}}' > "$STATUS_JSON"
OUT="$($CLI remodex status --porcelain 2>&1)"; STATUS=$?
check "old Remodex stays non-fatal for the menu" "$OUT" $'unsupported\t\t\t\t\t\t'

GUI_HOME="$SCRATCH/GUI Home"
INSTALLED_CLI="$SCRATCH/Doppel.app/Contents/Resources/doppel/bin/doppel"
STANDARD_BRIDGE="$GUI_HOME/.local/bin/remodex"
/bin/mkdir -p "${INSTALLED_CLI:h}" "${STANDARD_BRIDGE:h}"
/bin/cp "$CLI" "$INSTALLED_CLI"
{
    print -r -- '#!/usr/bin/env fake-node'
    /usr/bin/tail -n +2 "$BRIDGE"
} > "$STANDARD_BRIDGE"
/bin/ln -s /bin/zsh "${STANDARD_BRIDGE:h}/fake-node"
/bin/chmod 755 "$INSTALLED_CLI" "$STANDARD_BRIDGE"
OUT="$(HOME="$GUI_HOME" PATH=/usr/bin:/bin DOPPEL_DEV=0 \
    "$INSTALLED_CLI" remodex status --porcelain 2>&1)"; STATUS=$?
check "bundled CLI finds a standard global install outside GUI PATH" "$STATUS" "0"
check "standard-path Remodex is queried" "$OUT" $'unsupported\t\t\t\t\t\t'

export DOPPEL_REMODEX_BIN="$SCRATCH/missing-remodex"
OUT="$($CLI remodex status --porcelain 2>&1)"; STATUS=$?
check "absent Remodex stays non-fatal for the menu" "$OUT" $'unavailable\t\t\t\t\t\t'
export DOPPEL_REMODEX_BIN="$BRIDGE"

export DOPPEL_TEST_FAIL=1
OUT="$($CLI remodex use "ChatGPT Personal" 2>&1)"; STATUS=$?
(( STATUS != 0 )) && pass "restart failure is surfaced" || fail "restart failure is surfaced" "exited 0"
[[ "$OUT" == *"previous target was restored"* ]] && pass "restart failure explains rollback" || fail "restart failure explains rollback" "$OUT"
unset DOPPEL_TEST_FAIL

OUT="$($CLI remodex release 2>&1)"; STATUS=$?
check "release succeeds" "$STATUS" "0"
check "release restores primary with a restart" "$(<"$CAPTURE")" $'target\nreset\n--restart'

/usr/bin/plutil -replace CFBundleIdentifier -string com.openai.codex.wrong "$APP/Contents/Info.plist"
: > "$CAPTURE"
OUT="$($CLI remodex use "ChatGPT Personal" 2>&1)"; STATUS=$?
(( STATUS != 0 )) && pass "mismatched bundle metadata is refused" || fail "mismatched bundle metadata is refused" "exited 0"
[[ ! -s "$CAPTURE" ]] && pass "metadata failure never invokes Remodex" || fail "metadata failure never invokes Remodex" "bridge was called"

/usr/bin/plutil -replace CFBundleIdentifier -string com.openai.codex.secondary "$APP/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleURLTypes -json '[{"CFBundleURLSchemes":["codex-wrong"]}]' "$APP/Contents/Info.plist"
: > "$CAPTURE"
OUT="$($CLI remodex use "ChatGPT Personal" 2>&1)"; STATUS=$?
(( STATUS != 0 )) && pass "mismatched URL scheme metadata is refused" || fail "mismatched URL scheme metadata is refused" "exited 0"
[[ ! -s "$CAPTURE" ]] && pass "scheme failure never invokes Remodex" || fail "scheme failure never invokes Remodex" "bridge was called"

print -r -- ""
print -r -- "$PASSED passed, $FAILED failed"
(( FAILED == 0 ))
