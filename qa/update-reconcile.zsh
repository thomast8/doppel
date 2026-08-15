#!/bin/zsh
# The reconcile path: what Doppel has to do once ChatGPT's own updater has
# replaced the primary on its own and left managed instances behind.
#
# The home, the install root and the appcast are all throwaway, but the
# instances are real clones built from the primary. Rebuilding one is the whole
# point of a reconcile, and a stub bundle cannot prove that happened: only a
# real clone can be quit, rebuilt, verified and signed again. Two of them,
# because the other half of the promise is that an instance already built from
# this primary is left alone.
#
# The drift is produced by rewriting the build the installed clone records,
# which is exactly what `verify_managed_instance` reads, rather than by keeping
# two vendor bundles around for a machine that may only have one.
#
#   qa/update-reconcile.zsh [--cli /path/to/doppel]
#
# Set DOPPEL_PRIMARY_APP to run against a vendor bundle other than the installed
# one.

set -u
setopt PIPE_FAIL

readonly REPO_ROOT="${0:A:h:h}"
CLI="$REPO_ROOT/bin/doppel"
[[ "${1:-}" == "--cli" ]] && CLI="$2"

readonly PRIMARY="${DOPPEL_PRIMARY_APP:-/Applications/ChatGPT.app}"
readonly SCRATCH="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/doppel-reconcile.XXXXXXXX")"
readonly BEHIND="Doppel Behind $$"
readonly CURRENT="Doppel Current $$"
readonly APPS="$SCRATCH/Applications"
readonly BEHIND_APP="$APPS/$BEHIND.app"
readonly CURRENT_APP="$APPS/$CURRENT.app"
readonly BEHIND_INFO="$BEHIND_APP/Contents/Info.plist"

export DOPPEL_HOME="$SCRATCH/home"
export DOPPEL_RELAUNCH=0
# Spaces are percent-encoded because curl rejects them in a file:// URL, and
# TMPDIR can well contain one. Everything else about this path is mktemp's.
export DOPPEL_APPCAST_URL="file://${SCRATCH// /%20}/appcast.xml"

typeset -i PASSED=0 FAILED=0
pass() { print -r -- "  ✓ $1"; (( PASSED += 1 )); return 0 }
fail() { print -r -- "  ✗ $1"; print -r -- "      $2"; (( FAILED += 1 )); return 0 }
check() {
    if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "expected '$3', got '$2'"; fi
}

slug_of() { print -r -- "$1" | /usr/bin/tr '[:upper:]' '[:lower:]' | /usr/bin/sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g' }

# The engine keeps per-instance staging and rollbacks outside DOPPEL_HOME, so
# the throwaway home is not enough on its own to leave nothing behind.
cleanup() {
    local name
    for name in "$BEHIND" "$CURRENT"; do
        "$CLI" remove "$name" --purge-data >/dev/null 2>&1 || true
        /bin/rm -rf "$HOME/Library/Application Support/Doppel/state/com.openai.codex.doppel-$(slug_of "$name")" 2>/dev/null || true
    done
    /bin/rm -rf "$SCRATCH" 2>/dev/null || true
    return 0
}
trap cleanup EXIT INT TERM

# A feed at the given build, served from disk: every decision here is about the
# primary and the instances, and a network round trip would only add a way for
# this to fail for an unrelated reason.
write_appcast() {
    cat > "$SCRATCH/appcast.xml" <<XML
<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
  <channel>
    <item>
      <sparkle:version>$1</sparkle:version>
      <sparkle:shortVersionString>$2</sparkle:shortVersionString>
      <enclosure url="https://persistent.oaistatic.com/codex-app-prod/ChatGPT-darwin-arm64-$2.zip" />
    </item>
  </channel>
</rss>
XML
}

source_build() { /usr/bin/plutil -extract DoppelSourceBundleVersion raw "$1/Contents/Info.plist" 2>/dev/null || true }
app_stamp() { /usr/bin/stat -f '%m' "$1" 2>/dev/null || print -r -- "missing" }
field() { print -r -- "$1" | /usr/bin/awk -F'\t' -v c="$2" '{print $c}' }
# What the vendor updater leaves behind: an instance built from a build the
# primary no longer carries.
leave_behind() {
    /usr/bin/plutil -replace DoppelSourceBundleVersion -string "$(( BUILD - 1 ))" "$BEHIND_INFO"
}

[[ -d "$PRIMARY" ]] || { print -u2 -r -- "the primary app is required at $PRIMARY"; exit 1 }
BUILD="$(/usr/bin/plutil -extract CFBundleVersion raw "$PRIMARY/Contents/Info.plist")"
SHORT="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$PRIMARY/Contents/Info.plist")"
PRIMARY_STAMP="$(/usr/bin/stat -f '%m' "$PRIMARY")"
/bin/mkdir -p "$APPS"
write_appcast "$BUILD" "$SHORT"

print -r -- "Doppel reconcile"
print -r -- "  cli:     $CLI"
print -r -- "  primary: $PRIMARY ($BUILD)"
print -r -- ""

print -r -- "instances built from the installed primary need nothing"
for name in "$BEHIND" "$CURRENT"; do
    if ! "$CLI" create --name "$name" --tint 3B82F6 --install-to "$APPS" >/dev/null 2>&1; then
        print -u2 -r -- "  ✗ create failed; the rest of this file needs real clones"
        print -u2 -r -- "      $("$CLI" create --name "$name" --tint 3B82F6 --install-to "$APPS" 2>&1 | /usr/bin/tail -2)"
        exit 1
    fi
done
check "both clones record the primary's build" \
    "$(source_build "$BEHIND_APP")/$(source_build "$CURRENT_APP")" "$BUILD/$BUILD"
check "and the check reports nothing to do" \
    "$(field "$("$CLI" update check --porcelain)" 1)" "current"
check "with no instance counted as behind" \
    "$(field "$("$CLI" update check --porcelain)" 7)" "0"
BEHIND_STAMP="$(app_stamp "$BEHIND_APP")"
CURRENT_STAMP="$(app_stamp "$CURRENT_APP")"
OUT="$("$CLI" update apply "$BUILD" 2>&1)"
STATUS=$?
check "applying the installed build is a no-op" "$OUT" "current	$BUILD	$BUILD	2	0"
check "and succeeds" "$STATUS" "0"
check "without rebuilding anything" \
    "$(app_stamp "$BEHIND_APP")/$(app_stamp "$CURRENT_APP")" "$BEHIND_STAMP/$CURRENT_STAMP"

print -r -- ""
print -r -- "only the instance left behind is rebuilt"
leave_behind
check "the check now reports drift" \
    "$(field "$("$CLI" update check --porcelain)" 1)" "stale-instances"
check "and counts only the instance that is behind" \
    "$(field "$("$CLI" update check --porcelain)" 7)" "1"
HUMAN="$("$CLI" update check)"
[[ "$HUMAN" == *"managed instance(s) were built from an older version"* ]] \
    && pass "and says so in the readable form" \
    || fail "and says so in the readable form" "got: $HUMAN"
"$CLI" update verify >/dev/null 2>&1 \
    && fail "verification fails while an instance is behind" "verify passed" \
    || pass "verification fails while an instance is behind"

BEHIND_STAMP="$(app_stamp "$BEHIND_APP")"
CURRENT_STAMP="$(app_stamp "$CURRENT_APP")"
OUT="$("$CLI" update apply "$BUILD" 2>&1)"
STATUS=$?
check "the reconcile reports the one instance it rebuilt" "$OUT" "reconciled	$BUILD	$BUILD	1	0"
check "and succeeds" "$STATUS" "0"
[[ "$(app_stamp "$BEHIND_APP")" != "$BEHIND_STAMP" ]] \
    && pass "the instance that was behind was actually replaced" \
    || fail "the instance that was behind was actually replaced" "the app was not touched"
check "and the one already built from this primary was left alone" \
    "$(app_stamp "$CURRENT_APP")" "$CURRENT_STAMP"
check "the rebuilt instance carries the primary's build" "$(source_build "$BEHIND_APP")" "$BUILD"
"$CLI" update verify >/dev/null 2>&1 \
    && pass "and passes the same verification an update ends with" \
    || fail "and passes the same verification an update ends with" "verify failed"
/usr/bin/codesign --verify --deep --strict "$BEHIND_APP" >/dev/null 2>&1 \
    && pass "and is still sealed" \
    || fail "and is still sealed" "codesign rejected the rebuilt bundle"

print -r -- ""
print -r -- "an instance ahead of the primary is never rebuilt backwards"
# The mirror image of the case above, and the one where a rebuild would be a
# downgrade: an Electron profile a later version already migrated, handed back
# to an earlier one. It is reported, not offered.
/usr/bin/plutil -replace DoppelSourceBundleVersion -string "$(( BUILD + 1 ))" "$BEHIND_INFO"
check "the check does not call it drift" \
    "$(field "$("$CLI" update check --porcelain)" 1)" "current"
check "nor count it among the instances that are behind" \
    "$(field "$("$CLI" update check --porcelain)" 7)" "0"
check "but does count it in its own column" \
    "$(field "$("$CLI" update check --porcelain)" 8)" "1"
BEHIND_STAMP="$(app_stamp "$BEHIND_APP")"
OUT="$("$CLI" update apply "$BUILD" 2>&1)"
check "and applying the installed build leaves it alone" "$OUT" "current	$BUILD	$BUILD	2	0"
check "without touching the bundle" "$(app_stamp "$BEHIND_APP")" "$BEHIND_STAMP"
check "or the build it records" "$(source_build "$BEHIND_APP")" "$(( BUILD + 1 ))"

print -r -- ""
print -r -- "a feed that has fallen behind the primary is not a reason to refuse"
# `doppel update apply` with no build is the documented form. If the appcast is
# older than what is installed, that request still means "make everything
# match" — the instances are what is behind, not the primary.
leave_behind
write_appcast "$(( BUILD - 2 ))" "older-than-installed"
OUT="$("$CLI" update apply 2>&1)"
check "a bare apply reconciles against the installed build" "$OUT" "reconciled	$BUILD	$BUILD	1	0"
write_appcast "$BUILD" "$SHORT"

print -r -- ""
print -r -- "nothing outside the instances was touched"
check "the primary was left exactly as it was" "$(/usr/bin/stat -f '%m' "$PRIMARY")" "$PRIMARY_STAMP"
check "and still reports its own build" \
    "$(/usr/bin/plutil -extract CFBundleVersion raw "$PRIMARY/Contents/Info.plist")" "$BUILD"

print -r -- ""
print -r -- "$PASSED passed, $FAILED failed"
(( FAILED == 0 ))
