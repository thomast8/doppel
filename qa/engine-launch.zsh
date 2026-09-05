#!/bin/zsh
# Contract test for what the embedded engine does when an instance's Electron
# profile is already open somewhere else.
#
# Chromium allows one process per user-data-dir. Booting a second copy of a
# 1.3 GB Electron app against a profile another ChatGPT already holds ends with
# that copy exiting on the singleton a moment after macOS handed it the
# keyboard focus, so the click reads as "bounced in the Dock and did nothing".
# The engine has to notice the owner up front and activate it instead.
#
# The other half of this file is about not believing the process table. `ps`
# prints a process's own argv, so a same-uid process can claim to be any app it
# likes; an activation target taken from it unchecked is an arbitrary string
# handed to /usr/bin/open, which will follow a URL or read a leading dash as an
# option. The stand-in processes below include one that lies about itself.
#
# Everything runs against fixtures under one temporary directory. The stand-ins
# are copies of a compiled stand-in parked at the bundle paths `ps` reports,
# so ownership is detected exactly the way it is in the field, and
# DOPPEL_IAB_DRY_RUN keeps the engine from opening anything for real.

set -eu
setopt PIPE_FAIL

readonly REPO_ROOT="${0:A:h:h}"
readonly ENGINE="$REPO_ROOT/engine/doppel-engine.zsh"
readonly FIXTURE="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/doppel-engine-qa.XXXXXXXX")"
readonly FIXTURE_HOME="$FIXTURE/home"
readonly ASSETS="$FIXTURE/assets"
readonly DOPPEL_STATE="$FIXTURE_HOME/Library/Application Support/Doppel/state"

typeset -ga STUB_PIDS=()

stop_stubs() {
    local pid waited
    for pid in $STUB_PIDS; do
        /bin/kill "$pid" 2>/dev/null || true
    done
    # The engine reads `ps`, so a case must not start until the previous case's
    # stand-ins have actually left the process table.
    for pid in $STUB_PIDS; do
        waited=0
        while (( waited < 50 )) && /bin/kill -0 "$pid" 2>/dev/null; do
            /bin/sleep 0.1
            (( waited += 1 ))
        done
    done
    STUB_PIDS=()
}

cleanup() {
    stop_stubs
    [[ -n "$FIXTURE" && -d "$FIXTURE" && "$FIXTURE" == */doppel-engine-qa.* ]] || return 0
    /bin/rm -rf "$FIXTURE"
}
trap cleanup EXIT

typeset -i PASSED=0 FAILED=0
pass() { print -r -- "  ✓ $1"; (( PASSED += 1 )); return 0 }
fail() { print -r -- "  ✗ $1"; print -r -- "      $2"; (( FAILED += 1 )); return 0 }

# The stand-in has to be a compiled binary of our own, for two separate
# reasons. A `#!` script will not do because macOS reports the interpreter as
# comm, and the engine's scan is anchored on comm ending in
# /Contents/MacOS/ChatGPT[.real]. A copy of a system shell will not do either:
# /bin/sh re-execs itself as /bin/bash, so the kernel's idea of the running
# executable becomes /bin/bash and stops matching the path the copy sits at,
# which is precisely what the engine now checks. This one ignores its arguments
# and waits for a signal, so it stays exactly where it was put. It also sets
# its own alarm, because zsh does not run an EXIT trap when set -u aborts on an
# unset parameter: without the alarm an aborted run leaks processes whose comm
# ends in /Contents/MacOS/ChatGPT.real, which is exactly the shape the engine
# scans for.
readonly STUB_SOURCE="$FIXTURE/stub.c"
readonly STUB_BINARY="$FIXTURE/stub"
build_stub_binary() {
    print -r -- '#include <unistd.h>' > "$STUB_SOURCE"
    print -r -- 'int main(void) { alarm(300); for (;;) pause(); }' >> "$STUB_SOURCE"
    /usr/bin/cc -o "$STUB_BINARY" "$STUB_SOURCE" || {
        print -u2 -r -- "engine-launch QA: could not build the stand-in binary"
        exit 1
    }
}

install_stub_binary() {
    local binary="$1"
    /bin/mkdir -p "${binary:h}"
    /bin/cp "$STUB_BINARY" "$binary"
    # Copying moves the binary out from under its signature's page hashes on
    # arm64 unless it is re-sealed, and an unsealed binary will not execute.
    /usr/bin/codesign --force --sign - "$binary" >/dev/null 2>&1
}

await_stub() {
    local pid="$1" expected="$2" waited=0
    while (( waited < 50 )); do
        [[ "$(/bin/ps -p "$pid" -o comm= 2>/dev/null)" == "$expected" ]] && return 0
        /bin/sleep 0.1
        (( waited += 1 ))
    done
    print -u2 -r -- "engine-launch QA: a stand-in ChatGPT process did not start as $expected"
    exit 1
}

start_stub_process() {
    local app="$1" executable="$2"
    shift 2
    local binary="$app/Contents/MacOS/$executable" pid
    install_stub_binary "$binary"
    "$binary" "$@" &
    pid=$!
    STUB_PIDS+=($pid)
    await_stub "$pid" "$binary"
}

# The same thing, except the process presents somebody else's path as its own.
# This is the whole forgery in one call: argv[0] is a lie, and only the kernel
# still knows which file is running.
start_lying_stub_process() {
    local real_binary="$1" claimed="$2"
    shift 2
    local pid
    install_stub_binary "$real_binary"
    /usr/bin/python3 "$FIXTURE/spoof-argv0.py" "$real_binary" "$claimed" "$@" &
    pid=$!
    STUB_PIDS+=($pid)
    await_stub "$pid" "$claimed"
}

write_instance_assets() {
    local profile_root="$1"
    /bin/mkdir -p "$ASSETS"
    {
        print -r -- "# QA fixture"
        printf 'DOPPEL_DISPLAY_NAME=%q\n' "ChatGPT Engine QA"
        printf 'DOPPEL_BUNDLE_ID=%q\n' "com.openai.codex.engine-qa"
        printf 'DOPPEL_URL_SCHEME=%q\n' "codex-engine-qa"
        printf 'DOPPEL_PROFILE_ROOT=%q\n' "$profile_root"
        printf 'DOPPEL_CODEX_HOME=%q\n' "$FIXTURE_HOME/.codex-engine-qa"
        printf 'DOPPEL_TINT=%q\n' "1FA97E"
    } > "$ASSETS/instance-config.zsh"
}

run_engine() {
    HOME="$FIXTURE_HOME" \
    DOPPEL_DEV=1 \
    DOPPEL_IAB_DRY_RUN=1 \
    DOPPEL_ASSET_ROOT="$ASSETS" \
    DOPPEL_STATE_ROOT="$FIXTURE/state" \
    DOPPEL_PIN_ROOT="$FIXTURE/pins" \
    DOPPEL_PRIMARY_APP="$FIXTURE/Primary/ChatGPT.app" \
    DOPPEL_NO_ALERT=1 \
        /bin/zsh "$ENGINE" "$@" 2>&1
}

{
    print -r -- 'import os, sys'
    print -r -- 'os.execv(sys.argv[1], [sys.argv[2]] + sys.argv[3:])'
} > "$FIXTURE/spoof-argv0.py"

build_stub_binary
/bin/mkdir -p "$FIXTURE_HOME" "$FIXTURE/Primary/ChatGPT.app/Contents"
/usr/bin/plutil -create xml1 "$FIXTURE/Primary/ChatGPT.app/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleName -string "Codex" \
    "$FIXTURE/Primary/ChatGPT.app/Contents/Info.plist"

readonly PRIMARY_APP_FIXTURE="$FIXTURE/Primary/ChatGPT.app"
# The instance's own app bundle. The fast path must never need anything inside
# it: on this route the engine activates a process and stops.
readonly INSTANCE_APP="$FIXTURE_HOME/Applications/ChatGPT Engine QA.app"
readonly IMPOSTOR_APP="$FIXTURE_HOME/Applications/ChatGPT Impostor.app"
readonly EXPLICIT_ROOT="$FIXTURE_HOME/Library/Application Support/Engine QA"
/bin/mkdir -p "$INSTANCE_APP/Contents/MacOS"

# An assigned Built-in Browser profile runs as the official app pointed at the
# instance's own root, so the explicit argument is the shape to detect there.
print -r -- "the official app holding the profile explicitly is activated"
write_instance_assets "$EXPLICIT_ROOT"
start_stub_process "$PRIMARY_APP_FIXTURE" "ChatGPT" "--user-data-dir=$EXPLICIT_ROOT"
OUT="$(run_engine launch "$INSTANCE_APP" || true)"
[[ "$OUT" == *"activated-existing	$PRIMARY_APP_FIXTURE"* ]] \
    && pass "the engine activates the official app that owns the profile" \
    || fail "the engine activates the official app that owns the profile" "got: $OUT"

print -r -- "a launch argument still goes the long way round"
# A deep link has to reach the app, and activation alone would drop it. The
# fast path declines, so the engine falls through to its normal route, which
# stops on this fixture's missing assets. That refusal is the evidence.
OUT="$(run_engine launch "$INSTANCE_APP" "codex-engine-qa://thread/1" || true)"
[[ "$OUT" != *"activated-existing"* && "$OUT" == *"required engine asset is missing"* ]] \
    && pass "an argument-carrying launch is not collapsed into an activation" \
    || fail "an argument-carrying launch is not collapsed into an activation" "got: $OUT"

print -r -- "a process serial number argument is not a real argument"
OUT="$(run_engine launch "$INSTANCE_APP" "-psn_0_123456" || true)"
[[ "$OUT" == *"activated-existing	$PRIMARY_APP_FIXTURE"* ]] \
    && pass "a Finder -psn argument still activates the owner" \
    || fail "a Finder -psn argument still activates the owner" "got: $OUT"

print -r -- "an install must not be satisfied by somebody else's window"
OUT="$(DOPPEL_INSTALL_ONLY=1 run_engine launch "$INSTANCE_APP" || true)"
[[ "$OUT" != *"activated-existing"* && "$OUT" == *"required engine asset is missing"* ]] \
    && pass "install-only work is never short-circuited" \
    || fail "install-only work is never short-circuited" "got: $OUT"

# The CLI relaunches a clone with a one-shot marker and then waits for that
# process to adopt the profile. Collapsing that into an activation would strand
# the CLI waiting for an adoption that is never going to happen.
print -r -- "a launch the CLI authorised is never collapsed into an activation"
readonly CLONE_TOKEN="$(printf 'a%.0s' {1..64})"
/bin/mkdir -p "$DOPPEL_STATE/clone-launch" "$DOPPEL_STATE/IABCoordinator.lock"
printf '%s\t%s\n' "$CLONE_TOKEN" "com.openai.codex.engine-qa" \
    > "$DOPPEL_STATE/clone-launch/engine-qa"
print -r -- "$$" > "$DOPPEL_STATE/IABCoordinator.lock/pid"
OUT="$(run_engine launch "$INSTANCE_APP" \
    "--doppel-authorized-clone=engine-qa:$CLONE_TOKEN" || true)"
[[ "$OUT" != *"activated-existing"* && "$OUT" == *"required engine asset is missing"* ]] \
    && pass "an authorised clone launch keeps the CLI's contract" \
    || fail "an authorised clone launch keeps the CLI's contract" "got: $OUT"

print -r -- "nobody holding the profile means no activation"
stop_stubs
write_instance_assets "$FIXTURE_HOME/Library/Application Support/Nobody Here"
OUT="$(run_engine launch "$INSTANCE_APP" || true)"
[[ "$OUT" != *"activated-existing"* ]] \
    && pass "an unowned profile falls through to the normal launch" \
    || fail "an unowned profile falls through to the normal launch" "got: $OUT"

# The case this whole route exists for. A profile that deliberately adopts the
# vendor's default Electron root is owned by any official ChatGPT started from
# Finder or the Dock, and that process carries no --user-data-dir at all.
print -r -- "the official app owns the vendor default root with no argument"
write_instance_assets "$FIXTURE_HOME/Library/Application Support/Codex"
start_stub_process "$PRIMARY_APP_FIXTURE" "ChatGPT"
OUT="$(run_engine launch "$INSTANCE_APP" || true)"
[[ "$OUT" == *"activated-existing	$PRIMARY_APP_FIXTURE"* ]] \
    && pass "an argument-free official process is recognised as the owner" \
    || fail "an argument-free official process is recognised as the owner" "got: $OUT"

# Only the primary is ever activated. A clone holding the profile, this
# instance's own included, belongs to the CLI, which handles it under the
# engine-operation lock; opening the bundle this code runs from could relaunch
# itself in a loop if Launch Services and `ps` ever disagreed.
print -r -- "a bundle other than the primary is left to the CLI"
stop_stubs
write_instance_assets "$EXPLICIT_ROOT"
start_stub_process "$IMPOSTOR_APP" "ChatGPT.real" "--user-data-dir=$EXPLICIT_ROOT"
OUT="$(run_engine launch "$INSTANCE_APP" || true)"
[[ "$OUT" != *"activated-existing"* ]] \
    && pass "a clone holding the profile is not activated by the engine" \
    || fail "a clone holding the profile is not activated by the engine" "got: $OUT"

stop_stubs
start_stub_process "$INSTANCE_APP" "ChatGPT.real" "--user-data-dir=$EXPLICIT_ROOT"
OUT="$(run_engine launch "$INSTANCE_APP" || true)"
[[ "$OUT" != *"activated-existing"* ]] \
    && pass "this instance's own bundle is not opened by its own engine" \
    || fail "this instance's own bundle is not opened by its own engine" "got: $OUT"

print -r -- "a forged command line naming an allowed bundle is refused too"
stop_stubs
start_lying_stub_process "$IMPOSTOR_APP/Contents/MacOS/ChatGPT.real" \
    "$PRIMARY_APP_FIXTURE/Contents/MacOS/ChatGPT" "--user-data-dir=$EXPLICIT_ROOT"
OUT="$(run_engine launch "$INSTANCE_APP" || true)"
[[ "$OUT" != *"activated-existing"* ]] \
    && pass "a spoofed command line does not become an activation target" \
    || fail "a spoofed command line does not become an activation target" "got: $OUT"

# A forgery must not be able to hide the real owner either, which it could if
# the scan stopped at the first command line that matched the profile.
print -r -- "a forgery cannot shadow the genuine owner"
start_stub_process "$PRIMARY_APP_FIXTURE" "ChatGPT" "--user-data-dir=$EXPLICIT_ROOT"
OUT="$(run_engine launch "$INSTANCE_APP" || true)"
[[ "$OUT" == *"activated-existing	$PRIMARY_APP_FIXTURE"* ]] \
    && pass "the real owner is still found past a rejected candidate" \
    || fail "the real owner is still found past a rejected candidate" "got: $OUT"

print -r -- ""
print -r -- "engine-launch QA: $PASSED passed, $FAILED failed"
(( FAILED == 0 ))
