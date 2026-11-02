#!/bin/zsh
# Dry-run the deep-link patcher against the ChatGPT builds that exist on this
# machine: the installed primary and every update Doppel has staged. Each run
# patches an APFS clone of app.asar in a temp directory and never touches an
# app, so it is safe to run at any time, and a vendor build the patcher cannot
# read is found here instead of when an update is applied.
#
# usage: qa/vendor-compat.zsh [ChatGPT.app ...]   (default: installed + staged)

set -u
ROOT="${0:A:h:h}"
PATCHER="$ROOT/engine/patch-deep-link.py"
UPDATE_ROOT="${DOPPEL_UPDATE_ROOT:-$HOME/Library/Application Support/Doppel/updates}"

apps=("$@")
if (( ${#apps} == 0 )); then
    [[ -d /Applications/ChatGPT.app ]] && apps+=(/Applications/ChatGPT.app)
    for staged in "$UPDATE_ROOT"/Prepared/*/ChatGPT.app(N); do
        apps+=("$staged")
    done
fi
if (( ${#apps} == 0 )); then
    print -r -- "no ChatGPT builds found to check"
    exit 1
fi

failed=0
scratch="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/doppel-vendor-compat.XXXXXXXX")" || exit 1
trap '/bin/rm -rf "$scratch"' EXIT

for app in "${apps[@]}"; do
    asar="$app/Contents/Resources/app.asar"
    version="$(/usr/bin/defaults read "$app/Contents/Info" CFBundleShortVersionString 2>/dev/null || print unknown)"
    if [[ ! -f "$asar" ]]; then
        print -r -- "  ✗ $app ($version): no app.asar"
        failed=1
        continue
    fi
    /bin/cp -c "$asar" "$scratch/app.asar" 2>/dev/null || /bin/cp "$asar" "$scratch/app.asar" || { failed=1; continue; }
    if output="$(/usr/bin/python3 -B "$PATCHER" patch "$scratch/app.asar" 2>&1 >/dev/null)"; then
        print -r -- "  ✓ $app ($version)"
    else
        print -r -- "  ✗ $app ($version): ${output#patch-deep-link: }"
        failed=1
    fi
    /bin/rm -f "$scratch/app.asar"
done

(( failed == 0 ))
