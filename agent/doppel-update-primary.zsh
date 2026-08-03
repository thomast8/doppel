#!/bin/zsh
# Compatibility launcher for older ai.doppel.update-primary LaunchAgents.
#
# Earlier versions opened the vendor primary hidden and let Sparkle update it
# independently. That could race managed instances and could never coordinate
# their restart. The Doppel menu app now checks OpenAI's official appcast,
# prompts with the ChatGPT update flow, stages and verifies the vendor app, and
# updates every managed instance as one transaction. This old scheduled entry
# simply ensures that coordinator is running.

set -eu

readonly DOPPEL_APP="${DOPPEL_APP:-$HOME/Applications/Doppel.app}"
readonly LOG_FILE="$HOME/Library/Logs/Doppel/primary-updater.log"

mkdir -p "${LOG_FILE:h}"

log_message() {
    print -r -- "$(/bin/date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"
}

[[ -d "$DOPPEL_APP" ]] || { log_message "ERROR: no Doppel app at $DOPPEL_APP."; exit 1 }
/usr/bin/open -gj "$DOPPEL_APP" || { log_message "ERROR: Doppel could not be opened."; exit 1 }
log_message "Ensured Doppel's coordinated update checker is running."
