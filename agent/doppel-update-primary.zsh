#!/bin/zsh
# Doppel primary updater. Nobody launches the vendor's primary app day to day
# once every account lives in a Doppel instance, so its Sparkle auto-updater
# never gets a chance to run. This job opens the primary hidden when no
# instance is using it, gives Sparkle time to check and download, then quits it
# (Sparkle installs on quit). Instances self-heal from the updated primary on
# their next launch.

set -u

readonly PRIMARY_APP="${DOPPEL_PRIMARY_APP:-/Applications/ChatGPT.app}"
readonly PRIMARY_BUNDLE_ID="${DOPPEL_PRIMARY_BUNDLE_ID:-com.openai.codex}"
readonly LOG_FILE="$HOME/Library/Application Support/Doppel/state/primary-updater.log"
readonly SOAK_SECONDS="${DOPPEL_UPDATER_SOAK:-900}"

mkdir -p "${LOG_FILE:h}"

log_message() {
    print -r -- "$(/bin/date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"
}

# Any main process from the primary or an instance means the machine is in
# active use; skip and let the next scheduled run try again.
if /usr/bin/pgrep -f "Contents/MacOS/ChatGPT" >/dev/null 2>&1; then
    log_message "Skipped: a ChatGPT instance is running."
    exit 0
fi

version_before="$(/usr/bin/plutil -extract CFBundleVersion raw "$PRIMARY_APP/Contents/Info.plist" 2>/dev/null)"
log_message "Opening primary $version_before hidden for its update check."
/usr/bin/open -j -a "$PRIMARY_APP" || { log_message "ERROR: the primary app could not be opened."; exit 1 }

/bin/sleep "$SOAK_SECONDS"

/usr/bin/osascript -e "tell application id \"$PRIMARY_BUNDLE_ID\" to quit" >/dev/null 2>&1
/bin/sleep 60

version_after="$(/usr/bin/plutil -extract CFBundleVersion raw "$PRIMARY_APP/Contents/Info.plist" 2>/dev/null)"
if [[ "$version_after" != "$version_before" ]]; then
    log_message "Primary updated: $version_before -> $version_after. Instances rebuild on next launch."
else
    log_message "Primary still $version_before (no update, or it installs on a later quit)."
fi
