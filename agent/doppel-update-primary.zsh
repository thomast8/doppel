#!/bin/zsh
# Doppel primary updater. Nobody launches the vendor's primary app day to day
# once every account lives in a Doppel instance, so its Sparkle auto-updater
# never gets a chance to run. This job opens the primary hidden when nothing is
# using it, gives Sparkle time to check and download, then quits it (Sparkle
# installs on quit). Instances self-heal from the updated primary on their next
# launch.

set -u

readonly PRIMARY_APP="${DOPPEL_PRIMARY_APP:-/Applications/ChatGPT.app}"
readonly PRIMARY_BUNDLE_ID="${DOPPEL_PRIMARY_BUNDLE_ID:-com.openai.codex}"
readonly PRIMARY_TEAM_ID="${DOPPEL_PRIMARY_TEAM_ID:-2DC432GLL2}"
readonly LOG_FILE="$HOME/Library/Logs/Doppel/primary-updater.log"
readonly SOAK_SECONDS="${DOPPEL_UPDATER_SOAK:-900}"

mkdir -p "${LOG_FILE:h}"

log_message() {
    print -r -- "$(/bin/date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"
}

# Only open an app that is still the vendor's own signed bundle.
validate_primary() {
    [[ -d "$PRIMARY_APP" ]] || { log_message "ERROR: no app at $PRIMARY_APP."; return 1 }
    [[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw "$PRIMARY_APP/Contents/Info.plist" 2>/dev/null)" == "$PRIMARY_BUNDLE_ID" ]] || \
        { log_message "ERROR: $PRIMARY_APP is not $PRIMARY_BUNDLE_ID."; return 1 }
    local details
    details="$(/usr/bin/codesign -dv --verbose=4 "$PRIMARY_APP" 2>&1)" || \
        { log_message "ERROR: the primary signature could not be read."; return 1 }
    [[ "$details" == *"TeamIdentifier=$PRIMARY_TEAM_ID"* ]] || \
        { log_message "ERROR: $PRIMARY_APP is not signed by team $PRIMARY_TEAM_ID."; return 1 }
    return 0
}

# Match resolved executables rather than any process whose argv mentions
# ChatGPT: a substring match on argv both false-positives on unrelated
# processes (an editor with the engine file open) and is trivially spoofable.
instance_or_primary_running() {
    /usr/bin/pgrep -x "ChatGPT" >/dev/null 2>&1 && return 0
    /usr/bin/pgrep -x "ChatGPT.real" >/dev/null 2>&1 && return 0
    # A rebuild in flight: the engine runs as zsh with the engine path as argv[1].
    /usr/bin/pgrep -f '^/bin/zsh [^ ]*doppel-engine\.zsh ' >/dev/null 2>&1 && return 0
    return 1
}

if instance_or_primary_running; then
    log_message "Skipped: a ChatGPT instance or an instance rebuild is running."
    exit 0
fi

validate_primary || exit 1

version_before="$(/usr/bin/plutil -extract CFBundleVersion raw "$PRIMARY_APP/Contents/Info.plist" 2>/dev/null)"
log_message "Opening primary $version_before hidden for its update check."
/usr/bin/open -j -a "$PRIMARY_APP" || { log_message "ERROR: the primary app could not be opened."; exit 1 }

/bin/sleep "$SOAK_SECONDS"

# The bundle id is passed as an argument rather than interpolated into the
# script text, so it cannot alter the AppleScript.
/usr/bin/osascript - "$PRIMARY_BUNDLE_ID" >/dev/null 2>&1 <<'APPLESCRIPT'
on run argv
    tell application id (item 1 of argv) to quit
end run
APPLESCRIPT
if (( $? != 0 )); then
    log_message "WARNING: the quit request failed; the primary may still be running."
fi
/bin/sleep 60

if instance_or_primary_running; then
    log_message "WARNING: the primary is still running after the quit request; no update installs until it exits."
fi

version_after="$(/usr/bin/plutil -extract CFBundleVersion raw "$PRIMARY_APP/Contents/Info.plist" 2>/dev/null)"
if [[ "$version_after" != "$version_before" ]]; then
    log_message "Primary updated: $version_before -> $version_after. Instances rebuild on next launch."
else
    log_message "Primary still $version_before (no update, or it installs on a later quit)."
fi
