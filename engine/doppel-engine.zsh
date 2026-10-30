#!/bin/zsh
# Doppel engine: builds and launches an independent, rebranded instance of a
# locally installed ChatGPT or Claude desktop app.
#
# The engine never ships or downloads vendor code. It clones the app the user
# already has, gives the clone its own bundle identity, icon, and data
# directories, and re-signs it locally (ad hoc). A copy of this engine plus the
# instance config is embedded in every clone, so a clone that no longer matches
# the primary app (after the vendor auto-updates) rebuilds itself on launch.

set -u
setopt PIPE_FAIL

readonly ENGINE_VERSION="33"

# When this engine copy runs from inside an installed bundle, environment
# overrides are ignored: otherwise a same-uid process could point a
# signature-validated bundle at a config, state dir, or signing identity of its
# choosing. Overrides remain available for development (DOPPEL_DEV=1).
if [[ "${0:A}" == */*.app/Contents/Resources/Doppel/* && "${DOPPEL_DEV:-0}" != "1" ]]; then
    # DOPPEL_SIGN_IDENTITY_NAME belongs here with the other two signing
    # overrides: it does not name an identity directly, but it chooses which
    # keychain certificate detect_sign_identity finds, which reaches the same
    # end. Left settable, a rebuild could be made to sign an instance with a
    # certificate of the caller's choosing and then pin that certificate,
    # turning detectable tampering into permanently trusted tampering.
    unset DOPPEL_ASSET_ROOT DOPPEL_STATE_ROOT DOPPEL_PIN_ROOT DOPPEL_SIGN_IDENTITY \
          DOPPEL_SIGN_LEAF_SHA1 DOPPEL_SIGN_IDENTITY_NAME \
          DOPPEL_PRIMARY_APP DOPPEL_PRIMARY_BUNDLE_ID \
          DOPPEL_PRIMARY_SCHEME DOPPEL_PRIMARY_TEAM_ID DOPPEL_INSTALL_ONLY
fi

readonly ASSET_ROOT="${DOPPEL_ASSET_ROOT:-${0:A:h}}"
readonly CONFIG_FILE="$ASSET_ROOT/instance-config.zsh"

if [[ ! -f "$CONFIG_FILE" ]]; then
    print -u2 -r -- "Doppel: missing instance config at $CONFIG_FILE"
    exit 1
fi
unset DOPPEL_APP_KIND
source "$CONFIG_FILE"
DOPPEL_APP_KIND="${DOPPEL_APP_KIND:-chatgpt}"
source "$ASSET_ROOT/vendor.zsh"

for _required in DOPPEL_DISPLAY_NAME DOPPEL_BUNDLE_ID DOPPEL_URL_SCHEME DOPPEL_PROFILE_ROOT "$AGENT_HOME_KEY"; do
    [[ -n "${(P)_required:-}" ]] || { print -u2 -r -- "Doppel: config is missing $_required"; exit 1 }
done

# Both are interpolated into a code-signing requirement, so they are checked
# once here rather than at every use. A value carrying a quote can close the
# string and append its own clause: a team id of `Z" or ! identifier "zzzzzzzz`
# makes the whole requirement true for anything.
[[ "$PRIMARY_BUNDLE_ID" == [A-Za-z0-9]* && "$PRIMARY_BUNDLE_ID" != *[^A-Za-z0-9.-]* ]] || \
    { print -u2 -r -- "Doppel: the primary bundle identifier may contain only letters, digits, dots and hyphens"; exit 1 }
[[ ${#PRIMARY_TEAM_ID} -eq 10 && "$PRIMARY_TEAM_ID" != *[^A-Z0-9]* ]] || \
    { print -u2 -r -- "Doppel: the primary team identifier must be 10 upper-case letters or digits"; exit 1 }
# Re-check persisted configs, not only new CLI input. URI schemes are
# case-insensitive, so an older or hand-edited `Codex` instance would otherwise
# rebuild into a normal-launch claim on the shared OAuth callback.
[[ "${DOPPEL_URL_SCHEME:l}" != "${PRIMARY_SCHEME:l}" ]] || \
    { print -u2 -r -- "Doppel: the instance URL scheme belongs to the primary app"; exit 1; }
readonly AGENT_HOME="${(P)AGENT_HOME_KEY}"
readonly STATE_ROOT="${DOPPEL_STATE_ROOT:-$DEFAULT_DOPPEL_HOME/state/$DOPPEL_BUNDLE_ID}"
# Where the launcher looks up the requirement a bundle at a given path has to
# satisfy. Keyed by install path rather than by anything inside the bundle:
# the launcher used to read the requirement out of the very Info.plist it was
# checking, so deleting that one key and re-sealing ad hoc satisfied the
# weaker fallback. The path is the one thing the person launching the app
# chooses and a tampered bundle cannot restate.
readonly PIN_ROOT="${DOPPEL_PIN_ROOT:-$HOME/Library/Application Support/Doppel/pins}"
readonly LAUNCHER="$ASSET_ROOT/bin/doppel-launcher"
readonly ALERT_HELPER="$ASSET_ROOT/bin/doppel-alert"
readonly URL_HANDLER_HELPER="$ASSET_ROOT/bin/doppel-url-handler"
readonly ROUTER_CLI="$ASSET_ROOT/bin/doppel"
readonly ROUTER_ENGINE="$ASSET_ROOT/engine/doppel-engine.zsh"
readonly ROUTER_PATCHER="$ASSET_ROOT/engine/patch-deep-link.py"
readonly DEEP_LINK_PATCHER="$ASSET_ROOT/patch-deep-link.py"
readonly ICON_ICNS="$ASSET_ROOT/assets/icon.icns"
readonly ICON_PNG="$ASSET_ROOT/assets/icon.png"
readonly LOG_FILE="$STATE_ROOT/engine.log"
readonly LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
readonly ROLLBACK_INFO_NAME="Info.plist.doppel-rollback"

# Ad-hoc signatures change on every rebuild, so keychain "Always Allow" grants
# die with each vendor update. If the user has created a stable local signing
# identity (Keychain Access > Certificate Assistant, Code Signing template,
# named "Doppel Local Signing"), sign with it so grants persist. The identity's
# SHA-1 is captured so the launcher can pin the certificate leaf, which is what
# makes an attacker's ad-hoc re-seal of a tampered bundle fail.
# find-identity -v is not usable here: it lists only identities with a trusted
# chain, and a locally created self-signed certificate is untrusted by design.
# codesign signs with it anyway, so the certificate itself is what is looked up.
detect_sign_identity() {
    /usr/bin/security find-certificate -c "${DOPPEL_SIGN_IDENTITY_NAME:-Doppel Local Signing}" -Z \
        "$HOME/Library/Keychains/login.keychain-db" 2>/dev/null | \
        /usr/bin/awk '/^SHA-1 hash:/ {print $3; exit}'
}
SIGN_LEAF_SHA1="${DOPPEL_SIGN_LEAF_SHA1:-$(detect_sign_identity)}"
if [[ -n "$SIGN_LEAF_SHA1" ]]; then
    readonly SIGN_IDENTITY="${DOPPEL_SIGN_IDENTITY:-$SIGN_LEAF_SHA1}"
else
    readonly SIGN_IDENTITY="${DOPPEL_SIGN_IDENTITY:--}"
fi
readonly SIGN_LEAF_SHA1

mkdir -p "$STATE_ROOT"

log_message() {
    local message="$1"
    print -r -- "$(/bin/date '+%Y-%m-%d %H:%M:%S') [$DOPPEL_DISPLAY_NAME] $message" >> "$LOG_FILE"
}

fail_closed() {
    local message="$1"
    log_message "ERROR: $message"
    if [[ "${DOPPEL_NO_ALERT:-0}" != "1" && -x "$ALERT_HELPER" ]]; then
        "$ALERT_HELPER" "$DOPPEL_DISPLAY_NAME" "$message" >/dev/null 2>&1 &
    fi
    print -u2 -r -- "$DOPPEL_DISPLAY_NAME: $message"
    exit 1
}

plist_value() {
    /usr/bin/plutil -extract "$2" raw "$1" 2>/dev/null
}

sha256_file() {
    /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

pin_file_for() {
    local app="${1:A}" digest
    digest="$(print -rn -- "$app" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
    print -r -- "$PIN_ROOT/$digest"
}

# Records, outside the bundle, what a bundle installed at this path must
# satisfy. Removed again when there is no signing identity, so that dropping
# the identity does not leave every instance refusing to start.
record_pinned_requirement() {
    local app="$1" pin
    pin="$(pin_file_for "$app")"
    if [[ -z "$SIGN_LEAF_SHA1" ]]; then
        /bin/rm -f "$pin" 2>/dev/null || true
        return 0
    fi
    mkdir -p "$PIN_ROOT"
    print -r -- "identifier \"$DOPPEL_BUNDLE_ID\" and certificate leaf H\"$SIGN_LEAF_SHA1\"" > "$pin" || \
        fail_closed "Recording the pinned requirement failed."
    /bin/chmod 600 "$pin"
}

# A stored rollback that still has a Contents directory is an app bundle to
# Launch Services. Moving only Info.plist aside (the old layout) left it
# registered as a damaged app, so anything that opened it got "may be damaged
# or incomplete". Moving the whole Contents directory aside leaves a plain
# folder; moving it back restores the exact bundle and its code seal.
readonly ROLLBACK_CONTENTS_NAME="Contents.doppel-rollback"

mask_rollback_app() {
    local app="$1" contents hidden stamp
    contents="$app/Contents"
    hidden="$app/$ROLLBACK_CONTENTS_NAME"
    [[ -d "$app" ]] || return 1
    [[ -d "$hidden" && ! -e "$contents" ]] && return 0
    [[ -d "$contents" && ! -e "$hidden" ]] || return 1
    if [[ -f "$contents/$ROLLBACK_INFO_NAME" ]]; then
        [[ ! -e "$contents/Info.plist" ]] || return 1
        /bin/mv "$contents/$ROLLBACK_INFO_NAME" "$contents/Info.plist" || return 1
    fi
    "$LSREGISTER" -u "$app" >/dev/null 2>&1 || true
    # Prune keeps the newest rollbacks by mtime, and the rename below bumps the
    # outer directory's, so put the original back.
    stamp="$(/bin/date -r "$(/usr/bin/stat -f '%m' "$app")" '+%Y%m%d%H%M.%S')" || return 1
    /bin/mv "$contents" "$hidden" || return 1
    /usr/bin/touch -t "$stamp" "$app"
}

unmask_rollback_app() {
    local app="$1" contents hidden
    contents="$app/Contents"
    hidden="$app/$ROLLBACK_CONTENTS_NAME"
    [[ -d "$app" ]] || return 1
    if [[ -d "$hidden" && ! -e "$contents" ]]; then
        /bin/mv "$hidden" "$contents" || return 1
    fi
    [[ -d "$contents" && ! -e "$hidden" ]] || return 1
    # Rollbacks stored by older versions only had their plist moved aside.
    if [[ -f "$contents/$ROLLBACK_INFO_NAME" && ! -e "$contents/Info.plist" ]]; then
        /bin/mv "$contents/$ROLLBACK_INFO_NAME" "$contents/Info.plist" || return 1
    fi
    [[ -f "$contents/Info.plist" ]]
}

# A rollback is a whole copy of the app. One is kept every time an instance is
# rebuilt, and a vendor update rebuilds on its own, so without this they piled
# up unbounded — tens of gigabytes on a machine with a couple of instances.
prune_state() {
    local keep="${DOPPEL_KEEP_BACKUPS:-1}" index
    local -a rollbacks
    rollbacks=("$STATE_ROOT/Backups"/*.rollback(N/om))
    for (( index = keep + 1; index <= ${#rollbacks}; index++ )); do
        "$LSREGISTER" -u "${rollbacks[$index]}" >/dev/null 2>&1 || true
        /bin/rm -rf "${rollbacks[$index]}" 2>/dev/null || true
    done
    # Nothing else can be building: this runs while the rebuild lock is held,
    # so anything still in Staging is debris from a build that died.
    local staged
    for staged in "$STATE_ROOT/Staging"/*(N/); do
        /bin/rm -rf "$staged" 2>/dev/null || true
    done
    return 0
}

# Doppel installs by replacing whatever is at the target path, keeping the old
# copy as a rollback. That is right for its own bundle and wrong for anybody
# else's, which would vanish into a state directory nobody thinks to look in.
is_doppel_instance() {
    local app="$1"
    [[ -e "$app" ]] || return 0
    [[ -x "$app/Contents/MacOS/$PRIMARY_EXECUTABLE.real" ]] && return 0
    [[ -n "$(plist_value "$app/Contents/Info.plist" DoppelSigningIdentifier)" ]] && return 0
    return 1
}

require_engine_assets() {
    local asset
    for asset in "$LAUNCHER" "$ALERT_HELPER" "$URL_HANDLER_HELPER" "$DEEP_LINK_PATCHER" \
                 "$ROUTER_CLI" "$ROUTER_ENGINE" "$ROUTER_PATCHER" "$ASSET_ROOT/vendor.zsh" "$ASSET_ROOT/claude-profile.cjs" "$ICON_ICNS" "$ICON_PNG"; do
        [[ -f "$asset" ]] || fail_closed "A required engine asset is missing: $asset"
    done
    [[ -x "$LAUNCHER" ]] || fail_closed "The launcher is not executable: $LAUNCHER"
    [[ -x "$ROUTER_CLI" && -x "$ROUTER_ENGINE" ]] || \
        fail_closed "The embedded engine router is not executable."
}

# The requirement genuine vendor code has to satisfy, which is the vendor app's
# own designated requirement. `--verify` on its own only proves a signature
# seals the bundle it is attached to, which any locally made certificate can
# also do; the Apple anchor is what makes this mean "OpenAI signed it".
#
# The two marker OIDs are not decoration. Without them the requirement accepts
# any certificate Apple ever issued to that team, including an individual
# engineer's Apple Development certificate, which is far more widely held than
# the release key. 6.2.6 is the Developer ID intermediate CA; 6.1.13 is the
# Developer ID Application leaf. Kept identical to the CLI's copy.
#
# Interpolated values are validated once at startup rather than here, because
# this runs inside a command substitution where fail_closed would only kill the
# subshell and leave the caller running with an empty requirement.
vendor_requirement() {
    print -r -- "=anchor apple generic and identifier \"$PRIMARY_BUNDLE_ID\"\
 and certificate 1[field.1.2.840.113635.100.6.2.6]\
 and certificate leaf[field.1.2.840.113635.100.6.1.13]\
 and certificate leaf[subject.OU] = \"$PRIMARY_TEAM_ID\""
}

validate_primary() {
    [[ -d "$PRIMARY_APP" ]] || fail_closed "The primary app was not found at $PRIMARY_APP"
    [[ "$(plist_value "$PRIMARY_APP/Contents/Info.plist" CFBundleIdentifier)" == "$PRIMARY_BUNDLE_ID" ]] || \
        fail_closed "The primary app has an unexpected bundle identifier. No rebuild was performed."
    # The requirement covers the signing identifier and the team in one check.
    # The old `codesign -dv` text search for TeamIdentifier=<team> is gone: that
    # output also echoes the signing identifier, so one crafted identifier
    # satisfied it.
    /usr/bin/codesign --verify --deep --strict \
        -R "$(vendor_requirement)" "$PRIMARY_APP" >/dev/null 2>&1 || \
        fail_closed "The primary app does not have the expected Apple-anchored vendor signature. No rebuild was performed."

    [[ "$DOPPEL_APP_KIND" == claude ]] && return 0
    LC_ALL=C /usr/bin/grep -a -q 'CODEX_ELECTRON_USER_DATA_PATH' "$PRIMARY_APP/Contents/Resources/app.asar" || \
        fail_closed "This release no longer exposes the expected separate-profile control. No rebuild was performed."
}

source_version() {
    plist_value "$PRIMARY_APP/Contents/Info.plist" CFBundleVersion
}

source_executable_hash() {
    sha256_file "$PRIMARY_APP/Contents/MacOS/$PRIMARY_EXECUTABLE"
}

instance_is_healthy() {
    local app="$1"
    local expected_version="$2"
    local expected_hash="$3"
    local info="$app/Contents/Info.plist" expected_router_hash
    expected_router_hash="$(sha256_file "$ROUTER_CLI" 2>/dev/null)" || return 1

    [[ -d "$app" ]] || return 1
    [[ -x "$app/Contents/MacOS/$PRIMARY_EXECUTABLE" ]] || return 1
    [[ -x "$app/Contents/MacOS/$PRIMARY_EXECUTABLE.real" ]] || return 1
    /usr/bin/xattr -d com.apple.FinderInfo "$app" 2>/dev/null || true
    /usr/bin/xattr -d com.apple.ResourceFork "$app" 2>/dev/null || true
    [[ "$(plist_value "$info" CFBundleIdentifier)" == "$DOPPEL_BUNDLE_ID" ]] || return 1
    [[ "$(plist_value "$info" CFBundleDisplayName)" == "$DOPPEL_DISPLAY_NAME" ]] || return 1
    [[ "$(plist_value "$info" DoppelEngineVersion)" == "$ENGINE_VERSION" ]] || return 1
    [[ "$(plist_value "$info" DoppelSourceBundleVersion)" == "$expected_version" ]] || return 1
    [[ "$(plist_value "$info" DoppelSourceExecutableSHA256)" == "$expected_hash" ]] || return 1
    if [[ "$DOPPEL_APP_KIND" == chatgpt ]]; then
    [[ "$(plist_value "$info" LSEnvironment.CODEX_ELECTRON_USER_DATA_PATH)" == "$DOPPEL_PROFILE_ROOT" ]] || return 1
    [[ "$(plist_value "$info" LSEnvironment.CODEX_HOME)" == "$AGENT_HOME" ]] || return 1
    [[ "$(plist_value "$info" LSEnvironment.CODEX_SPARKLE_ENABLED)" == "false" ]] || return 1
    else
        [[ "$(plist_value "$info" LSEnvironment.CLAUDE_CONFIG_DIR)" == "$AGENT_HOME" ]] || return 1
        [[ -f "$app/Contents/Resources/Doppel/claude.json" ]] || return 1
        /usr/bin/cmp -s "$ASSET_ROOT/claude-profile.cjs" "$app/Contents/Resources/Doppel/claude-profile.cjs" || return 1
    fi
    [[ "$(plist_value "$info" LSEnvironment.DOPPEL_URL_SCHEME)" == "$DOPPEL_URL_SCHEME" ]] || return 1
    [[ "$(plist_value "$info" CFBundleURLTypes.0.CFBundleURLSchemes.0)" == "$DOPPEL_URL_SCHEME" ]] || return 1
    [[ "$(plist_value "$info" CFBundleURLTypes.0.CFBundleURLSchemes.1)" == "$PRIMARY_SCHEME" ]] || return 1
    [[ -z "$(plist_value "$info" CFBundleURLTypes.0.CFBundleURLSchemes.2)" ]] || return 1
    [[ "$(plist_value "$info" SUFeedURL)" == "https://doppel.invalid/no-updates.xml" ]] || return 1
    /usr/bin/cmp -s "$app/Contents/Resources/electron.icns" "$ICON_ICNS" || return 1
    [[ "$(plist_value "$info" DoppelSigningIdentifier)" == "$DOPPEL_BUNDLE_ID" ]] || return 1
    [[ "$(plist_value "$info" DoppelDeepLinkScheme)" == "$DOPPEL_URL_SCHEME" ]] || return 1
    [[ -x "$app/Contents/Resources/Doppel/bin/doppel" ]] || return 1
    [[ -x "$app/Contents/Resources/Doppel/engine/doppel-engine.zsh" ]] || return 1
    [[ -f "$app/Contents/Resources/Doppel/engine/patch-deep-link.py" ]] || return 1
    /usr/bin/cmp -s "$ASSET_ROOT/vendor.zsh" "$app/Contents/Resources/Doppel/vendor.zsh" || return 1
    [[ "$(plist_value "$info" DoppelRouterSHA256)" == "$expected_router_hash" ]] || return 1
    [[ "$(sha256_file "$app/Contents/Resources/Doppel/bin/doppel" 2>/dev/null)" == \
       "$expected_router_hash" ]] || return 1

    # This runs on every launch, so it is one verification rather than two, and
    # not --deep: the bundle seal already covers every nested file, so tampering
    # with a framework breaks this check too. The deep walk is kept for the
    # build and restyle paths, where code has actually just been written.
    if [[ -n "$SIGN_LEAF_SHA1" ]]; then
        [[ -n "$(plist_value "$info" DoppelPinnedRequirement)" ]] || return 1
        /usr/bin/codesign --verify --strict \
            -R "=identifier \"$DOPPEL_BUNDLE_ID\" and certificate leaf H\"$SIGN_LEAF_SHA1\"" \
            "$app" >/dev/null 2>&1 || return 1
    else
        /usr/bin/codesign --verify --strict "$app" >/dev/null 2>&1 || return 1
    fi
    return 0
}

patch_plist() {
    local info="$1"
    local version="$2"
    local executable_hash="$3"

    /usr/bin/plutil -replace CFBundleIdentifier -string "$DOPPEL_BUNDLE_ID" "$info"
    /usr/bin/plutil -replace CFBundleDisplayName -string "$DOPPEL_DISPLAY_NAME" "$info"
    if [[ "$DOPPEL_APP_KIND" == claude ]]; then
        # Electron resolves its vendor helper app names before JavaScript runs.
        /usr/bin/plutil -replace CFBundleName -string Claude "$info"
    else
        /usr/bin/plutil -replace CFBundleName -string "$DOPPEL_DISPLAY_NAME" "$info"
    fi
    /usr/bin/plutil -replace CFBundleExecutable -string "$PRIMARY_EXECUTABLE" "$info"
    /usr/bin/plutil -remove CFBundleIconName "$info" 2>/dev/null || true
    /usr/bin/plutil -remove NSDockTilePlugIn "$info" 2>/dev/null || true
    /usr/bin/plutil -remove LSHasLocalizedDisplayName "$info" 2>/dev/null || true
    /usr/bin/plutil -replace BundleSigningBaseName -string "${DOPPEL_SIGNING_BASE_NAME:-Doppel}" "$info"
    /usr/bin/plutil -replace CrProductDirName -string "$DOPPEL_BUNDLE_ID" "$info"
    if [[ "$DOPPEL_APP_KIND" == claude ]]; then
        /usr/bin/plutil -replace CFBundleAlternateNames -json "[\"$DOPPEL_DISPLAY_NAME\"]" "$info"
    else
        /usr/bin/plutil -replace CFBundleAlternateNames.0 -string "$DOPPEL_DISPLAY_NAME" "$info"
    fi
    /usr/bin/plutil -replace CFBundleURLTypes.0.CFBundleURLName -string "$DOPPEL_DISPLAY_NAME" "$info"
    # Electron can only claim a macOS protocol that the bundle declares. Keep
    # the instance scheme first for ordinary launch-time registration, and
    # declare the vendor callback scheme second so connector OAuth can claim it
    # just in time. The ASAR patch still prevents a normal clone launch from
    # taking codex:// ownership.
    /usr/bin/plutil -replace CFBundleURLTypes.0.CFBundleURLSchemes -json \
        "[\"$DOPPEL_URL_SCHEME\",\"$PRIMARY_SCHEME\"]" "$info"
    if [[ "$DOPPEL_APP_KIND" == chatgpt ]]; then
    /usr/bin/plutil -replace LSEnvironment.CODEX_ELECTRON_USER_DATA_PATH -string "$DOPPEL_PROFILE_ROOT" "$info"
    /usr/bin/plutil -replace LSEnvironment.CODEX_HOME -string "$AGENT_HOME" "$info"
    # Codex now supplies its appcast at runtime, so the traditional Sparkle
    # Info.plist switches below no longer stop a user- or backend-initiated
    # update. This environment switch is read by Codex before it creates the
    # updater and is the supported interception point. Only the untouched,
    # vendor-signed primary app is ever allowed to run Sparkle.
    /usr/bin/plutil -replace LSEnvironment.CODEX_SPARKLE_ENABLED -string "false" "$info"
    else
        /usr/bin/plutil -replace LSEnvironment.CLAUDE_CONFIG_DIR -string "$AGENT_HOME" "$info"
        /usr/bin/plutil -remove CFBundleURLTypes.1 "$info" 2>/dev/null || true
    fi
    # The packaged app otherwise hardcodes codex:// both when it creates an
    # OAuth callback and when it registers with Launch Services. The cloned
    # app.asar reads this per-instance value instead.
    /usr/bin/plutil -replace LSEnvironment.DOPPEL_URL_SCHEME -string "$DOPPEL_URL_SCHEME" "$info"
    # Sparkle must not update an instance: it would replace the bundle with the
    # vendor's, dropping the launcher and this instance's LSEnvironment profile
    # keys, which would silently point the icon at the default profile and merge
    # two accounts. Scheduled checks are disabled and the feed is pointed at an
    # unresolvable URL so a user-initiated "Check for Updates" also fails.
    /usr/bin/plutil -replace SUEnableAutomaticChecks -bool false "$info"
    /usr/bin/plutil -replace SUAllowsAutomaticUpdates -bool false "$info"
    /usr/bin/plutil -replace SUScheduledCheckInterval -integer 0 "$info"
    /usr/bin/plutil -replace SUFeedURL -string "https://doppel.invalid/no-updates.xml" "$info"
    /usr/bin/plutil -replace DoppelSigningIdentifier -string "$DOPPEL_BUNDLE_ID" "$info"
    /usr/bin/plutil -replace DoppelDeepLinkScheme -string "$DOPPEL_URL_SCHEME" "$info"
    /usr/bin/plutil -replace DoppelRouterSHA256 -string "$(sha256_file "$ROUTER_CLI")" "$info"
    if [[ -n "$SIGN_LEAF_SHA1" ]]; then
        /usr/bin/plutil -replace DoppelPinnedRequirement -string \
            "identifier \"$DOPPEL_BUNDLE_ID\" and certificate leaf H\"$SIGN_LEAF_SHA1\"" "$info"
    else
        /usr/bin/plutil -remove DoppelPinnedRequirement "$info" 2>/dev/null || true
    fi
    /usr/bin/plutil -replace DoppelEngineVersion -string "$ENGINE_VERSION" "$info"
    /usr/bin/plutil -replace DoppelSourceBundleVersion -string "$version" "$info"
    /usr/bin/plutil -replace DoppelSourceExecutableSHA256 -string "$executable_hash" "$info"
}

# Extracts the entitlements of the executable at $1 into $2 and strips what a
# local signature cannot carry. Restricted entitlements (team identity, push,
# keychain/app groups) need a provisioning profile; under an ad-hoc signature
# AMFI kills the process at spawn, so they are stripped. Library validation
# must be disabled because the ad-hoc main binary loads the vendor-signed
# frameworks.
write_filtered_entitlements() {
    local source_binary="$1" out="$2"
    /usr/bin/codesign -d --entitlements - --xml "$source_binary" > "$out" 2>/dev/null || return 1
    [[ -s "$out" ]] || return 1
    /usr/bin/python3 - "$out" <<'PYFILTER'
import plistlib, sys
path = sys.argv[1]
with open(path, "rb") as f:
    ent = plistlib.load(f)
restricted = ("com.apple.application-identifier", "com.apple.developer.",
              "com.apple.security.application-groups", "keychain-access-groups")
ent = {k: v for k, v in ent.items() if not any(k == p or k.startswith(p) for p in restricted)}
ent["com.apple.security.cs.disable-library-validation"] = True
with open(path, "wb") as f:
    plistlib.dump(ent, f)
PYFILTER
}

# Re-asserts the filtered key set immediately before signing: anything that
# reintroduced a restricted or dyld-relaxing entitlement between filtering and
# use must not reach codesign.
verify_filtered_entitlements() {
    /usr/bin/python3 - "$1" <<'PYVERIFY'
import plistlib, sys
with open(sys.argv[1], "rb") as f:
    ent = plistlib.load(f)
banned = ("com.apple.application-identifier", "com.apple.developer.",
          "com.apple.security.application-groups", "keychain-access-groups",
          "com.apple.security.get-task-allow",
          "com.apple.security.cs.allow-dyld-environment-variables",
          "com.apple.security.cs.disable-executable-page-protection")
bad = [k for k in ent if any(k == b or k.startswith(b) for b in banned)]
if bad or ent.get("com.apple.security.cs.disable-library-validation") is not True:
    sys.exit(1)
PYVERIFY
}

write_claude_config() {
    [[ "$DOPPEL_APP_KIND" == claude ]] || return 0
    /usr/bin/python3 - "$1/Contents/Resources/Doppel/claude.json" "$DOPPEL_DISPLAY_NAME" \
        "$DOPPEL_PROFILE_ROOT" "$AGENT_HOME" "$DOPPEL_URL_SCHEME" "$DOPPEL_BUNDLE_ID" \
        "$PRIMARY_APP" "$PRIMARY_BUNDLE_ID" "$DOPPEL_INSTANCE_SLUG" <<'PYCLAUDE'
import json, sys
from pathlib import Path
output, name, profile, code, scheme, bundle, primary, primary_bundle, slug = sys.argv[1:]
Path(output).write_text(json.dumps(dict(name=name, profile=profile, code=code, scheme=scheme,
    bundleID=bundle, primaryApp=primary, primaryBundleID=primary_bundle, slug=slug)))
PYCLAUDE
}

build_instance() {
    local target="$1"
    local version="$2"
    local executable_hash="$3"

    [[ ! -e "$target" ]] || fail_closed "Refusing to overwrite an existing staging path: $target"
    mkdir -p "${target:h}"
    log_message "Building instance $version at $target"
    # APFS can clone the 1+ GB source bundle copy-on-write in seconds. Each
    # instance then gets private copies only for the files Doppel changes.
    # Keep ditto as the fallback for non-APFS volumes or older macOS.
    if ! /bin/cp -cR "$PRIMARY_APP" "$target" 2>/dev/null; then
        [[ ! -e "$target" ]] || /bin/rm -rf "$target"
        /usr/bin/ditto "$PRIMARY_APP" "$target" || \
            fail_closed "Copying the primary app into staging failed."
    fi
    # The vendor can ship read-only files (ChatGPT 26.924 did), and xattr cannot
    # touch those. Modes are not part of the code signature, and this is only the
    # staged copy, so make it writable before stripping metadata.
    /bin/chmod -R u+w "$target" || fail_closed "Making the staged copy writable failed."
    /usr/bin/xattr -cr "$target" || fail_closed "Removing copied filesystem metadata failed."
    /usr/bin/codesign --verify --deep --strict "$target" >/dev/null 2>&1 || \
        fail_closed "The staged source copy did not retain the vendor signature."
    [[ "$(plist_value "$target/Contents/Info.plist" CFBundleVersion)" == "$version" ]] || \
        fail_closed "The primary app changed while the staged copy was being created."
    [[ "$(sha256_file "$target/Contents/MacOS/$PRIMARY_EXECUTABLE")" == "$executable_hash" ]] || \
        fail_closed "The primary executable changed while the staged copy was being created."

    local embedded="$target/Contents/Resources/Doppel"
    mkdir -p "$embedded/bin" "$embedded/assets" "$embedded/engine"
    /bin/cp "$ASSET_ROOT/doppel-engine.zsh" "$ASSET_ROOT/vendor.zsh" "$ASSET_ROOT/claude-profile.cjs" "$CONFIG_FILE" "$DEEP_LINK_PATCHER" "$embedded/" || \
        fail_closed "Embedding the self-healing engine failed."
    /bin/cp "$LAUNCHER" "$ALERT_HELPER" "$URL_HANDLER_HELPER" "$embedded/bin/" || \
        fail_closed "Embedding the engine executables failed."
    /bin/cp "$ROUTER_CLI" "$embedded/bin/doppel" || \
        fail_closed "Embedding the engine router failed."
    /bin/cp "$ROUTER_ENGINE" "$ROUTER_PATCHER" "$ASSET_ROOT/engine/claude-sessions.py" "$ASSET_ROOT/vendor.zsh" "$ASSET_ROOT/claude-profile.cjs" "$embedded/engine/" || \
        fail_closed "Embedding the router support files failed."
    /bin/chmod 755 "$embedded/bin/doppel-launcher" "$embedded/bin/doppel-alert" \
        "$embedded/bin/doppel-url-handler" "$embedded/bin/doppel" \
        "$embedded/engine/doppel-engine.zsh"
    /bin/cp "$ICON_ICNS" "$ICON_PNG" "$embedded/assets/" || \
        fail_closed "Embedding the icon assets failed."

    write_claude_config "$target" || fail_closed "Writing the Claude profile settings failed."

    /bin/mv "$target/Contents/MacOS/$PRIMARY_EXECUTABLE" "$target/Contents/MacOS/$PRIMARY_EXECUTABLE.real" || \
        fail_closed "Preserving the vendor executable failed."

    # The vendor's entitlements are extracted from the copy itself, so a
    # release that changes its entitlements still re-signs correctly.
    # The plist lives in a private per-run directory (0700, unpredictable name)
    # and is re-validated immediately before signing, so it cannot be swapped
    # between filtering and use.
    local entitlements_dir entitlements
    entitlements_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/doppel-ent.XXXXXXXX")" || \
        fail_closed "Creating the private entitlements directory failed."
    /bin/chmod 700 "$entitlements_dir"
    entitlements="$entitlements_dir/entitlements.plist"
    write_filtered_entitlements "$target/Contents/MacOS/$PRIMARY_EXECUTABLE.real" "$entitlements" || \
        fail_closed "Extracting and filtering the vendor entitlements failed."

    /bin/cp "$LAUNCHER" "$target/Contents/MacOS/$PRIMARY_EXECUTABLE" || fail_closed "Installing the durable launcher failed."
    /bin/chmod 755 "$target/Contents/MacOS/$PRIMARY_EXECUTABLE"
    /bin/cp "$ICON_ICNS" "$target/Contents/Resources/electron.icns"
    /bin/cp "$ICON_ICNS" "$target/Contents/Resources/icon-chatgpt.icns"
    /bin/cp "$ICON_PNG" "$target/Contents/Resources/icon-chatgpt.png"
    patch_plist "$target/Contents/Info.plist" "$version" "$executable_hash" || \
        fail_closed "Patching the instance metadata failed."

    # Keep launch-time registration instance-specific, but retain Google's
    # registered codex:// OAuth callback. The ASAR patch claims codex:// only
    # when this instance actually starts connector authorization.
    local asar_hash
    asar_hash="$(/usr/bin/python3 "$DEEP_LINK_PATCHER" --app "$DOPPEL_APP_KIND" patch \
        "$target/Contents/Resources/app.asar")" || \
        fail_closed "Patching the instance OAuth callback routing failed."
    (( ${#asar_hash} == 64 )) && [[ "$asar_hash" != *[^0-9a-f]* ]] || \
        fail_closed "The patched ASAR returned an invalid integrity hash."
    /usr/libexec/PlistBuddy -c \
        "Set :ElectronAsarIntegrity:Resources/app.asar:hash $asar_hash" \
        "$target/Contents/Info.plist" >/dev/null || \
        fail_closed "Updating Electron's ASAR integrity metadata failed."

    # New Electron releases seal the integrity dictionary inside the framework
    # as well as in Info.plist. Refresh that digest without disabling validation.
    local framework="$target/Contents/Frameworks/$PRIMARY_FRAMEWORK.framework" digest_status
    digest_status="$(/usr/bin/python3 "$DEEP_LINK_PATCHER" integrity \
        "$framework/$PRIMARY_FRAMEWORK" "$PRIMARY_APP/Contents/Info.plist" \
        "$target/Contents/Info.plist")" || \
        fail_closed "Updating Electron's framework integrity digest failed."
    if [[ "$digest_status" == "updated" ]]; then
        # Vendor helpers cannot load the now locally signed framework. Apply
        # the same filtered runtime entitlements as the clone's main process.
        local helper helper_entitlements="$entitlements_dir/helper.plist"
        local -a electron_helpers
        electron_helpers=("$framework"/Helpers/*.app(N/))
        if [[ "$DOPPEL_APP_KIND" == claude ]]; then
            electron_helpers+=("$target/Contents/Frameworks"/Claude\ Helper*.app(N/))
        fi
        for helper in "$electron_helpers[@]"; do
            write_filtered_entitlements "$helper" "$helper_entitlements" && \
                verify_filtered_entitlements "$helper_entitlements" || \
                fail_closed "Filtering Electron helper entitlements failed."
            /usr/bin/codesign --force --sign "$SIGN_IDENTITY" --options runtime \
                --preserve-metadata=identifier --entitlements "$helper_entitlements" \
                "$helper" >/dev/null || fail_closed "Signing the Electron helper failed."
        done
        /usr/bin/codesign --force --sign "$SIGN_IDENTITY" --options runtime \
            "$framework" >/dev/null || fail_closed "Signing the patched Electron framework failed."
    fi

    # Finder provenance and resource-fork metadata are not executable content
    # and make an otherwise valid staged bundle fail code-signature sealing.
    /usr/bin/xattr -cr "$target" || fail_closed "Removing staging-only filesystem metadata failed."

    verify_filtered_entitlements "$entitlements" || \
        fail_closed "The entitlements plist changed after filtering; refusing to sign."

    # -i pins the code-signing identifier to this instance, so each instance has
    # its own code identity: keychain ACLs and TCC grants no longer transfer
    # from one instance to another.
    /usr/bin/codesign --force --sign "$SIGN_IDENTITY" -i "$DOPPEL_BUNDLE_ID" --options runtime \
        --entitlements "$entitlements" \
        "$target/Contents/MacOS/$PRIMARY_EXECUTABLE.real" >/dev/null || fail_closed "Signing the preserved vendor executable failed."
    /usr/bin/xattr -cr "$target" || fail_closed "Removing intermediate signing metadata failed."
    # The bundle signature covers the launcher, the process that runs Apple's
    # native permission requests for the menu. tccd's hardened-runtime
    # prompting policy silently denies microphone and camera to a process
    # without the matching device entitlements — no prompt, no Settings row —
    # so the launcher must carry the same filtered vendor set.
    /usr/bin/codesign --force --sign "$SIGN_IDENTITY" -i "$DOPPEL_BUNDLE_ID" --options runtime \
        --entitlements "$entitlements" \
        "$target" >/dev/null || fail_closed "Signing the instance bundle failed."
    /bin/rm -rf "$entitlements_dir"
    /usr/bin/xattr -cr "$target" || fail_closed "Removing post-signing Finder metadata failed."
    /usr/bin/codesign --verify --deep --strict "$target" >/dev/null 2>&1 || \
        fail_closed "The staged instance bundle failed signature verification."
    instance_is_healthy "$target" "$version" "$executable_hash" || \
        fail_closed "The staged instance bundle failed its health check."
    log_message "Built and verified instance $version"
}

# Applies a new name or icon to an existing bundle without rebuilding it.
#
# A full rebuild copies the whole vendor app, re-signs every nested binary and
# takes half a minute; for a rename or a recolour none of that is needed. The
# preserved vendor executable is not touched at all here, only the bundle's own
# metadata and artwork, which keeps the change quick and leaves the inner binary
# byte-identical.
restyle_instance() {
    local app="$1"
    [[ -d "$app" ]] || fail_closed "There is no bundle to restyle at $app"
    [[ -x "$app/Contents/MacOS/$PRIMARY_EXECUTABLE.real" ]] || \
        fail_closed "The bundle at $app is not a Doppel instance."
    require_engine_assets

    local info="$app/Contents/Info.plist"

    # The bundle carries its own copy of the config, engine and icons, and the
    # launcher self-heals against them on every start. Leaving them stale makes
    # the instance decide it is wrong on the next launch and rebuild itself back
    # to the previous name and colour — undoing the edit that just happened.
    local embedded="$app/Contents/Resources/Doppel"
    if [[ -d "$embedded" ]]; then
        /bin/mkdir -p "$embedded/bin" "$embedded/assets" "$embedded/engine"
        /bin/cp "$CONFIG_FILE" "$embedded/instance-config.zsh" || \
            fail_closed "Updating the embedded config failed."
        /bin/cp "$ASSET_ROOT/vendor.zsh" "$ASSET_ROOT/claude-profile.cjs" "$embedded/" || fail_closed "Updating vendor support failed."
        /bin/cp "$ASSET_ROOT/doppel-engine.zsh" "$embedded/doppel-engine.zsh" 2>/dev/null || true
        /bin/cp "$DEEP_LINK_PATCHER" "$embedded/patch-deep-link.py" 2>/dev/null || true
        /bin/cp "$URL_HANDLER_HELPER" "$embedded/bin/doppel-url-handler" || \
            fail_closed "Updating the URL-handler repair helper failed."
        /bin/cp "$ROUTER_CLI" "$embedded/bin/doppel" || \
            fail_closed "Updating the embedded engine router failed."
        /bin/cp "$ROUTER_ENGINE" "$ROUTER_PATCHER" "$ASSET_ROOT/engine/claude-sessions.py" "$ASSET_ROOT/vendor.zsh" "$ASSET_ROOT/claude-profile.cjs" "$embedded/engine/" || \
            fail_closed "Updating the router support files failed."
        /bin/chmod 755 "$embedded/bin/doppel-url-handler" "$embedded/bin/doppel" \
            "$embedded/engine/doppel-engine.zsh"
        /bin/cp "$ICON_ICNS" "$embedded/assets/icon.icns" || fail_closed "Updating the embedded icon failed."
        /bin/cp "$ICON_PNG" "$embedded/assets/icon.png" || fail_closed "Updating the embedded icon failed."
        /bin/chmod 755 "$embedded/doppel-engine.zsh" 2>/dev/null || true
    fi

    write_claude_config "$app" || fail_closed "Updating the Claude profile settings failed."
    /bin/cp "$ICON_ICNS" "$app/Contents/Resources/electron.icns" || fail_closed "Replacing the icon failed."
    /bin/cp "$ICON_ICNS" "$app/Contents/Resources/icon-chatgpt.icns" || fail_closed "Replacing the icon failed."
    /bin/cp "$ICON_PNG" "$app/Contents/Resources/icon-chatgpt.png" || fail_closed "Replacing the icon failed."
    /usr/bin/plutil -replace CFBundleDisplayName -string "$DOPPEL_DISPLAY_NAME" "$info"
    if [[ "$DOPPEL_APP_KIND" == claude ]]; then
        # Electron resolves its vendor helper app names before JavaScript runs.
        /usr/bin/plutil -replace CFBundleName -string Claude "$info"
    else
        /usr/bin/plutil -replace CFBundleName -string "$DOPPEL_DISPLAY_NAME" "$info"
    fi
    /usr/bin/plutil -replace CFBundleAlternateNames.0 -string "$DOPPEL_DISPLAY_NAME" "$info"
    /usr/bin/plutil -replace CFBundleURLTypes.0.CFBundleURLName -string "$DOPPEL_DISPLAY_NAME" "$info"
    /usr/bin/plutil -replace DoppelRouterSHA256 -string "$(sha256_file "$ROUTER_CLI")" "$info"

    /usr/bin/xattr -cr "$app" || fail_closed "Removing filesystem metadata failed."
    # The re-sign covers the launcher, so it must keep the device entitlements
    # the build gave it; signing without them would silently break the next
    # microphone or camera prompt. The preserved executable already carries
    # the filtered set, so it is the source of truth here.
    local entitlements_dir entitlements
    entitlements_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/doppel-ent.XXXXXXXX")" || \
        fail_closed "Creating the private entitlements directory failed."
    /bin/chmod 700 "$entitlements_dir"
    entitlements="$entitlements_dir/entitlements.plist"
    write_filtered_entitlements "$app/Contents/MacOS/$PRIMARY_EXECUTABLE.real" "$entitlements" || \
        fail_closed "Extracting the preserved entitlements failed."
    verify_filtered_entitlements "$entitlements" || \
        fail_closed "The entitlements plist changed after filtering; refusing to sign."
    /usr/bin/codesign --force --sign "$SIGN_IDENTITY" -i "$DOPPEL_BUNDLE_ID" --options runtime \
        --entitlements "$entitlements" \
        "$app" >/dev/null || fail_closed "Re-signing the restyled bundle failed."
    /bin/rm -rf "$entitlements_dir"
    /usr/bin/xattr -cr "$app" || true
    /usr/bin/codesign --verify --deep --strict "$app" >/dev/null 2>&1 || \
        fail_closed "The restyled bundle failed signature verification."


    local version executable_hash
    version="$(source_version)"
    executable_hash="$(source_executable_hash)"
    instance_is_healthy "$app" "$version" "$executable_hash" || \
        fail_closed "The restyled bundle failed its health check."
    record_pinned_requirement "$app"
    log_message "Restyled instance in place (no rebuild)"
}

acquire_rebuild_lock() {
    local lock="$STATE_ROOT/Rebuild.lock"
    if /bin/mkdir "$lock" 2>/dev/null; then
        print -r -- "$$" > "$lock/owner-pid"
        print -r -- "$lock"
        return 0
    fi

    local owner=""
    [[ -f "$lock/owner-pid" ]] && owner="$(<"$lock/owner-pid")"
    if [[ "$owner" == <-> ]] && /bin/kill -0 "$owner" 2>/dev/null; then
        fail_closed "Another rebuild of this instance is already running. Try again in a moment."
    fi

    local stale_root="$STATE_ROOT/Stale Locks"
    mkdir -p "$stale_root"
    /bin/mv "$lock" "$stale_root/Rebuild.lock.$(/bin/date '+%Y%m%d-%H%M%S').$$" || \
        fail_closed "A stale rebuild lock could not be preserved."
    /bin/mkdir "$lock" || fail_closed "The rebuild lock could not be acquired."
    print -r -- "$$" > "$lock/owner-pid"
    print -r -- "$lock"
}

release_rebuild_lock() {
    local lock="$1"
    /bin/rm -f "$lock/owner-pid"
    /bin/rmdir "$lock"
}

exchange_app_contents() {
    /usr/bin/python3 - "$1/Contents" "$2/Contents" <<'PYEXCHANGE'
import ctypes, errno, os, sys
left, right = sys.argv[1:]
libc = ctypes.CDLL(None, use_errno=True)
if libc.renamex_np(os.fsencode(left), os.fsencode(right), 2) == 0:  # RENAME_SWAP
    sys.exit(0)
error = ctypes.get_errno()
if error not in (errno.ENOTSUP, errno.EINVAL):
    raise OSError(error, os.strerror(error))
# Some writable installation filesystems lack atomic exchange. Keep the old
# Contents beside the new one until both same-volume renames have succeeded.
holding = right + '.doppel-swap'
if os.path.lexists(holding):
    raise FileExistsError(holding)
os.rename(left, holding)
try:
    os.rename(right, left)
    try:
        os.rename(holding, right)
    except OSError:
        os.rename(left, right)
        raise
except OSError:
    os.rename(holding, left)
    raise
PYEXCHANGE
}

managed_slug_for_this_profile() {
    local doppel_home="$DEFAULT_DOPPEL_HOME"
    if [[ "${DOPPEL_DEV:-0}" == "1" ]]; then
        doppel_home="${DOPPEL_HOME:-$doppel_home}"
    fi
    local config candidate_bundle_id
    for config in "$doppel_home/instances"/*/instance-config.zsh(N); do
        candidate_bundle_id="$(/bin/zsh -c \
            'source "$1" 2>/dev/null || exit 0; print -r -- "${DOPPEL_BUNDLE_ID:-}"' \
            doppel-instance "$config" 2>/dev/null || true)"
        if [[ "$candidate_bundle_id" == "$DOPPEL_BUNDLE_ID" ]]; then
            print -r -- "${config:h:t}"
            return 0
        fi
    done
    return 0
}

consume_clone_launch_authorization() {
    local marker="$1" slug token doppel_home="$DEFAULT_DOPPEL_HOME"
    if [[ "${DOPPEL_DEV:-0}" == "1" ]]; then
        doppel_home="${DOPPEL_HOME:-$doppel_home}"
    fi
    slug="${marker%%:*}"
    token="${marker#*:}"
    [[ -n "$slug" && "$slug" != *[^a-z0-9-]* && ${#token} -eq 64 && \
       "$token" != *[^a-f0-9]* ]] || return 1
    local receipt="$doppel_home/state/clone-launch/$slug" saved_token saved_bundle extra owner
    [[ -r "$receipt" ]] || return 1
    IFS=$'\t' read -r saved_token saved_bundle extra < "$receipt" || return 1
    [[ -z "$extra" && "$saved_token" == "$token" && \
       "$saved_bundle" == "$DOPPEL_BUNDLE_ID" ]] || return 1
    owner="$(/bin/cat "$doppel_home/state/IABCoordinator.lock/pid" 2>/dev/null || true)"
    [[ "$owner" == <1-> ]] && /bin/kill -0 "$owner" 2>/dev/null || return 1
    /bin/rm -f "$receipt" || return 1
    return 0
}

route_managed_engine() {
    local slug mode token extra
    slug="$(managed_slug_for_this_profile)"
    [[ -n "$slug" ]] || return 1
    [[ -x "$ROUTER_CLI" ]] || \
        fail_closed "This profile owns Built-in Browser, but its signed engine router is missing. Rebuild it from Doppel."
    log_message "Direct app launch entered locked engine routing"
    # Read permission to continue while the coordinator retains its lock until
    # this exact process execs the runtime. Reopening the app splits its Dock tile.
    coproc "$ROUTER_CLI" --app "$DOPPEL_APP_KIND" __route-launch-in-place "$slug" "$$" "$@" 2>&1
    if ! IFS=$'\t' read -r -p mode token extra; then
        fail_closed "The engine coordinator did not authorize this launcher."
    fi
    if [[ "$mode" == clone && -z "$extra" ]]; then
        consume_clone_launch_authorization "$slug:$token" || \
            fail_closed "The engine coordinator's launch authorization was not valid."
        return 0
    fi
    [[ "$mode" == routed && -z "$token" && -z "$extra" ]] && exit 0
    mode="${mode#doppel: }"
    fail_closed "${mode:-The assigned engine could not be started.}"
}

# True when this launch carries something the app itself has to receive, which
# activating an already-running window would silently drop. Finder and the Dock
# pass a process serial number and nothing else; that is not a request.
launch_carries_arguments() {
    local arg
    for arg in "$@"; do
        [[ "$arg" == -psn_* ]] && continue
        return 0
    done
    return 1
}

# Main ChatGPT processes, official or cloned. `comm` is the executable path
# without arguments, so the anchored suffix keeps this to the app processes and
# leaves out Electron's helpers under Frameworks and Resources. pgrep is not
# usable: on macOS it hides its own ancestors, and a Doppel launch can well be
# a descendant of the very ChatGPT process it has to find.
#
# Kept in step with the CLI's copy at the same name, with one deliberate
# difference: the CLI's returns nothing at all under DOPPEL_IAB_DRY_RUN, which
# it can afford because its dry run asserts a decision made from stored state.
# The engine's fast path is a decision made from the process table, so its own
# QA has to be able to put stand-in processes in front of this scan.
chatgpt_process_candidates() {
    /bin/ps -ww -axo pid=,comm= 2>/dev/null | \
        /usr/bin/awk -v executable="$PRIMARY_EXECUTABLE" '$0 ~ ("/Contents/MacOS/" executable "(\\.real)?$") { print $1 }' || true
}

# The executable a pid is actually running, asked of the kernel. Everything
# `ps` prints, `comm` included, is that process's own argv, which any same-uid
# process can forge: exec /bin/sleep with argv[0] of "/Evil.app/Contents/
# MacOS/ChatGPT" and it is indistinguishable from a real instance in the scan
# above. The open file of type `txt` is the mapped executable itself, so it
# cannot be dressed up.
process_executable_path() {
    /usr/sbin/lsof -p "$1" -a -d txt -Fn 2>/dev/null | \
        /usr/bin/awk '/^n\// { print substr($0, 2); exit }'
}

# Kept in step with the CLI's copy. An instance may deliberately adopt the
# vendor's own Electron root so one profile keeps the account the untouched app
# has always used.
profile_root_is_primary_default() {
    local root="${1:A}" product candidate
    for candidate in "$HOME/Library/Application Support/Codex"; do
        [[ "$root" == "${candidate:A}" ]] && return 0
    done
    product="$(/usr/bin/plutil -extract CFBundleName raw \
        "$PRIMARY_APP/Contents/Info.plist" 2>/dev/null || true)"
    if [[ -n "$product" ]]; then
        candidate="$HOME/Library/Application Support/$product"
        [[ "$root" == "${candidate:A}" ]] && return 0
    fi
    return 1
}

# True when the untouched primary app already has this instance's Electron
# profile open. Two rules decide that, kept in step with the CLI's
# vendor_command_uses_profile: an explicit --user-data-dir naming this profile,
# which is how an assigned Built-in Browser profile runs, or no such argument at
# all, which is how a Finder or Dock launch of the official app owns the vendor
# default root. The second is the one that bites, because an instance that
# adopts that root is exactly the instance the untouched app takes over from.
#
# The explicit form is matched at the end of the command line, so a holder that
# was itself started with a deep link after its --user-data-dir is not spotted.
# The CLI's copy has the same blind spot, and the two are worth more kept
# identical than separately clever; the cost of missing one is a launch that
# behaves the way it did before this path existed.
#
# Only the primary is asked about, and only ever by its own fixed path. A clone
# holding its own profile is left to the CLI, which owns that case under the
# engine-operation lock and can activate a window without this path guessing;
# answering it here as well would mean opening a bundle this code is itself
# running from, and if Launch Services ever disagreed with `ps` about whether
# that bundle is running, each activation would start another launcher that
# reached the same conclusion.
#
# The scan itself is not believed. A command line is a process's own argv, and
# a same-uid process can put anything in it, so an unguarded scan would hand
# /usr/bin/open an attacker-chosen string, which open follows as happily when it
# spells a URL or an option as when it names a bundle. Nothing from argv is
# carried forward: this answers yes or no, the caller opens a constant. The
# kernel is then asked whether the process really is running out of the primary,
# so a forged entry cannot fake a holder that is not there, and cannot hide a
# real one either, because a rejected candidate only ends its own iteration.
primary_holds_profile() {
    local pid command executable
    local primary_real="${PRIMARY_APP:A}"
    # Asking the kernel costs a process each time, and a fleet of forgeries
    # would otherwise turn this into the slow launch the whole path exists to
    # avoid. Real life presents one candidate; a run of them that all fail is
    # somebody playing games, and giving up leaves the launch exactly where it
    # was before this path existed.
    local -i lookups=0
    for pid in ${(f)"$(chatgpt_process_candidates)"}; do
        [[ "$pid" == <1-> ]] || continue
        command="$(/bin/ps -p "$pid" -o command= 2>/dev/null || true)"
        [[ "$command" == "$PRIMARY_APP/Contents/MacOS/"* ]] || continue
        if [[ "$command" != *"--user-data-dir=$DOPPEL_PROFILE_ROOT" ]]; then
            [[ "$command" != *"--user-data-dir="* ]] || continue
            profile_root_is_primary_default "$DOPPEL_PROFILE_ROOT" || continue
        fi
        (( ++lookups > 8 )) && return 1
        executable="$(process_executable_path "$pid")"
        # lsof answers with the fully resolved path, and an app can sit behind a
        # symlinked volume, so both sides are compared resolved.
        [[ -n "$executable" && "${executable:A}" == "$primary_real/Contents/MacOS/"* ]] || continue
        return 0
    done
    return 1
}

# Clones leave the Codex Micro / Creator Micro pad alone (see the ASAR patch)
# unless `doppel micro assign` named this one. Read at launch, so assigning
# needs no rebuild and takes effect when the instance next starts.
codex_micro_owner_is_this_profile() {
    local doppel_home="$DEFAULT_DOPPEL_HOME" owner=""
    if [[ "${DOPPEL_DEV:-0}" == "1" ]]; then
        doppel_home="${DOPPEL_HOME:-$doppel_home}"
    fi
    [[ -r "$doppel_home/state/codex-micro-owner" ]] || return 1
    IFS= read -r owner < "$doppel_home/state/codex-micro-owner"
    [[ -n "$owner" && "$owner" != *[^a-z0-9-]* ]] || return 1
    [[ "$owner" == "$(managed_slug_for_this_profile)" ]]
}

# The Bluetooth channel `doppel micro channel` gave this clone, or nothing.
codex_micro_channel() {
    local doppel_home="$DEFAULT_DOPPEL_HOME" channel="" file
    if [[ "${DOPPEL_DEV:-0}" == "1" ]]; then
        doppel_home="${DOPPEL_HOME:-$doppel_home}"
    fi
    file="$doppel_home/state/codex-micro-channels/$(managed_slug_for_this_profile)"
    [[ -r "$file" ]] || return 0
    IFS= read -r channel < "$file" || true
    [[ "$channel" == [1-9] ]] && print -r -- "$channel"
    return 0
}

exec_clone_binary() {
    local app="$1" channel
    shift
    if [[ "$DOPPEL_APP_KIND" == claude ]]; then
        ( umask 077; mkdir -p "$DOPPEL_PROFILE_ROOT" "$AGENT_HOME" ) || fail_closed "Creating the Claude profile directories failed."
        export CLAUDE_CONFIG_DIR="$AGENT_HOME"
        exec "$app/Contents/MacOS/$PRIMARY_EXECUTABLE.real" --user-data-dir="$DOPPEL_PROFILE_ROOT" "$@"
        fail_closed "The preserved Claude executable could not be started."
    fi
    mkdir -p "$DOPPEL_PROFILE_ROOT" "$AGENT_HOME"
    unset DOPPEL_CODEX_MICRO DOPPEL_MICRO_CHANNEL
    channel="$(codex_micro_channel)"
    if [[ -n "$channel" ]]; then
        export DOPPEL_CODEX_MICRO=1 DOPPEL_MICRO_CHANNEL="$channel"
    elif codex_micro_owner_is_this_profile; then
        export DOPPEL_CODEX_MICRO=1
    fi
    export CODEX_ELECTRON_USER_DATA_PATH="$DOPPEL_PROFILE_ROOT"
    export CODEX_HOME="$AGENT_HOME"
    # Read by the ASAR patch: each clone keeps its own Codex runtime, because
    # accounts are pinned to different versions and would reinstall over each
    # other in ~/.cache. The Chromium profile is the one root a clone never shares.
    export DOPPEL_CODEX_RUNTIMES_ROOT="$DOPPEL_PROFILE_ROOT/codex-runtimes"
    export DOPPEL_URL_SCHEME
    export DOPPEL_PRIMARY_APP="$PRIMARY_APP"
    export DOPPEL_PRIMARY_BUNDLE_ID="$PRIMARY_BUNDLE_ID"
    export DOPPEL_URL_HANDLER_HELPER="$URL_HANDLER_HELPER"
    log_message "Launching healthy instance $(source_version)"
    exec "$app/Contents/MacOS/$PRIMARY_EXECUTABLE.real" --user-data-dir="$DOPPEL_PROFILE_ROOT" "$@"
    fail_closed "The preserved vendor executable could not be started."
}

launch_instance() {
    local app="$1"
    shift
    local authorized_clone=0 marker=""
    if [[ "${1:-}" == --doppel-authorized-clone=* ]]; then
        marker="${1#--doppel-authorized-clone=}"
        shift
        consume_clone_launch_authorization "$marker" || \
            fail_closed "This clone launch was not authorized by Doppel's active engine coordinator."
        authorized_clone=1
    fi

    # Clicking a branded icon whose profile another ChatGPT already has open
    # must not boot a second Electron against it. Chromium allows one process
    # per user-data-dir, so that copy exits on the singleton about a second
    # after macOS hands it the keyboard focus, and the click reads as a Dock
    # bounce that opened nothing. Activate the process that owns the profile.
    #
    # Nothing is read or executed out of this bundle to get there: the profile
    # comes from the config the bundle executable already validated, the scan
    # only answers yes or no, and what is opened is the primary's own fixed
    # path. Health and version checks are deliberately skipped, since a rebuild
    # could not launch this profile anyway while the primary holds it; Doppel's
    # update coordinator is what rebuilds a stale instance.
    #
    # The CLI's routed launches keep their own contract: that path has already
    # ruled out a foreign owner and waits for this process to adopt the profile.
    #
    # Deciding this outside the CLI's engine-operation lock is deliberate. That
    # lock serialises changes to who owns a profile; this changes nothing and
    # writes nothing, and taking it would mean paying for a whole coordinator
    # just to raise a window. The worst a lost race costs is starting the app
    # that was holding this profile a moment earlier.
    if (( ! authorized_clone )) && [[ "${DOPPEL_INSTALL_ONLY:-0}" != "1" ]] && \
       ! launch_carries_arguments "$@" && primary_holds_profile; then
        log_message "Profile already open in the official app; activating it"
        if [[ "${DOPPEL_DEV:-0}" == "1" && "${DOPPEL_IAB_DRY_RUN:-0}" == "1" ]]; then
            printf 'activated-existing\t%s\n' "$PRIMARY_APP"
            return 0
        fi
        # `open` starts a bundle that is not running rather than failing, and
        # the primary can quit between the scan and here. Starting the app that
        # was holding this profile a moment ago is a sane outcome rather than a
        # wrong one. The terminator is belt and braces: this path is a constant.
        /usr/bin/open -- "$PRIMARY_APP" >/dev/null 2>&1 || \
            fail_closed "This profile is already open in the official ChatGPT app, but macOS could not bring it forward."
        exit 0
    fi

    require_engine_assets

    # Claude must retain the coordinator through self-healing too: installing
    # a fresh bundle restores the shared callback handler.
    if [[ "$DOPPEL_APP_KIND" == claude && "${DOPPEL_INSTALL_ONLY:-0}" != 1 ]] && (( ! authorized_clone )); then
        if route_managed_engine "$@"; then authorized_clone=1; fi
    fi

    local version executable_hash
    version="$(source_version)" || fail_closed "The primary app version could not be read."
    executable_hash="$(source_executable_hash)" || fail_closed "The primary executable could not be fingerprinted."

    if instance_is_healthy "$app" "$version" "$executable_hash"; then
        # An instance built before pins existed has none recorded, and would
        # otherwise keep falling back to what its own Info.plist claims. The
        # health check above already proved it satisfies the leaf, so this is
        # the safe moment to write one down.
        record_pinned_requirement "$app"
        if [[ "${DOPPEL_INSTALL_ONLY:-0}" == "1" ]]; then
            log_message "Instance $version is already healthy; nothing to do."
            # The caller reports this to the user, so a no-op is not described
            # as a rebuild.
            print -r -- "doppel-engine: already-healthy"
            return 0
        fi
        # Every known managed profile enters the CLI's one authoritative lock,
        # even when it currently uses the fallback clone. The CLI authorizes
        # this original process with a private one-shot token. This
        # closes Finder-launch versus Browser-assignment races without holding
        # the global lock for the lifetime of the GUI app.
        (( authorized_clone )) || route_managed_engine "$@" || true
        exec_clone_binary "$app" "$@"
    fi

    is_doppel_instance "$app" || \
        fail_closed "There is already an app at $app and it is not a Doppel instance. Move it aside first; Doppel will not replace it."

    if [[ "$DOPPEL_APP_KIND" == claude ]]; then
        "$ROUTER_CLI" --app claude __auth-idle || \
            fail_closed "Finish the active Claude sign-in or quit its window before rebuilding instances."
    fi
    validate_primary
    local lock staging timestamp backup_root backup staging_root=""
    # The exit inside acquire_rebuild_lock only kills the $(...) subshell;
    # without this status check a concurrent rebuild would proceed unlocked.
    lock="$(acquire_rebuild_lock)" || exit 1
    timestamp="$(/bin/date '+%Y%m%d-%H%M%S')"
    staging="$STATE_ROOT/Staging/$DOPPEL_DISPLAY_NAME.$version.$timestamp.$$.app"
    # A failed or interrupted build must not leave a 1.7GB copy behind. After a
    # successful install the path has been moved into place, so this is a no-op.
    trap '/bin/rm -rf "$staging"' EXIT
    if [[ "${DOPPEL_INSTALL_ONLY:-0}" != "1" ]]; then
        # Keep the app directory macOS launched; stage on its filesystem so
        # replacing Contents cannot turn into a cross-volume copy and removal.
        staging_root="$(/usr/bin/mktemp -d "${app:h}/.doppel-rebuild.XXXXXXXX")" || \
            fail_closed "A staging directory beside the instance could not be created."
        trap '/bin/rm -rf "$staging_root"' EXIT
        staging="$staging_root/${app:t}"
    fi
    build_instance "$staging" "$version" "$executable_hash"

    backup_root="$STATE_ROOT/Backups"
    mkdir -p "$backup_root"
    backup="$backup_root/$DOPPEL_DISPLAY_NAME.$timestamp.$$.app.rollback"
    if [[ -n "$staging_root" ]]; then
        if ! /bin/cp -cR "$app" "$backup" 2>/dev/null; then
            /bin/rm -rf "$backup"
            /usr/bin/ditto "$app" "$backup" || fail_closed "The existing instance could not be copied to rollback storage."
        fi
        mask_rollback_app "$backup" || fail_closed "The previous app could not be hidden safely in rollback storage."
        exchange_app_contents "$app" "$staging" || fail_closed "Installing the rebuilt contents failed; the previous app and rollback were preserved."
        if ! instance_is_healthy "$app" "$version" "$executable_hash"; then
            exchange_app_contents "$app" "$staging" || \
                fail_closed "The rebuilt app failed verification AND restoration failed; recover the previous app from $backup"
            fail_closed "The rebuilt app failed verification; the previous app was restored."
        fi
        /bin/rm -rf "$staging_root"
        trap - EXIT
    elif [[ -e "$app" ]]; then
        /bin/mv "$app" "$backup" || fail_closed "The existing instance could not be preserved as a rollback backup."
        if ! mask_rollback_app "$backup"; then
            /bin/mv "$backup" "$app" 2>/dev/null || true
            fail_closed "The previous app could not be hidden safely in rollback storage; it was restored."
        fi
    fi
    if [[ -z "$staging_root" ]] && ! /bin/mv "$staging" "$app"; then
        if [[ -e "$backup" ]]; then
            if unmask_rollback_app "$backup" && /bin/mv "$backup" "$app" 2>/dev/null; then
                fail_closed "Installing the rebuilt instance failed; the previous app was restored."
            else
                fail_closed "Installing the rebuilt instance failed AND the previous app could not be restored; recover it manually from $backup"
            fi
        fi
        fail_closed "Installing the rebuilt instance failed."
    fi

    trap - EXIT
    "$LSREGISTER" -f "$app" >/dev/null 2>&1 || true
    # A pre-fix clone may have left an explicit preference claiming the
    # vendor's codex:// scheme. New clones declare that scheme for OAuth but do
    # not claim it during normal launch; stale ownership is repaired here
    # without launching the primary app.
    if ! "$URL_HANDLER_HELPER" set "$PRIMARY_SCHEME" "$PRIMARY_APP" "$PRIMARY_BUNDLE_ID"; then
        log_message "WARNING: Could not restore $PRIMARY_SCHEME:// to $PRIMARY_BUNDLE_ID"
        print -u2 -r -- "$DOPPEL_DISPLAY_NAME: warning: the primary $PRIMARY_SCHEME:// handler could not be restored."
    fi
    /usr/bin/touch "$app"
    record_pinned_requirement "$app"
    prune_state
    release_rebuild_lock "$lock"
    log_message "Installed instance $version; rollback preserved at $backup"
    if [[ "${DOPPEL_INSTALL_ONLY:-0}" == "1" ]]; then
        return 0
    fi
    (( authorized_clone )) || route_managed_engine "$@" || true
    exec_clone_binary "$app" "$@"
}

case "${1:-}" in
    build)
        [[ $# -eq 2 ]] || fail_closed "Usage: doppel-engine.zsh build /path/to/output.app"
        require_engine_assets
        validate_primary
        build_instance "$2" "$(source_version)" "$(source_executable_hash)"
        ;;
    restyle)
        [[ $# -eq 2 ]] || fail_closed "Usage: doppel-engine.zsh restyle /path/to/App.app"
        restyle_instance "$2"
        ;;
    install)
        [[ $# -eq 2 ]] || fail_closed "Usage: doppel-engine.zsh install /path/to/App.app"
        require_engine_assets
        validate_primary
        DOPPEL_INSTALL_ONLY=1 launch_instance "$2"
        ;;
    launch)
        [[ $# -ge 2 ]] || fail_closed "The launcher did not provide its app path."
        app_path="$2"
        shift 2
        launch_instance "$app_path" "$@"
        ;;
    *)
        fail_closed "Unknown engine command: ${1:-<missing>}"
        ;;
esac
