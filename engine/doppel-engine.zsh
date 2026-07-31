#!/bin/zsh
# Doppel engine: builds and launches an independent, rebranded instance of a
# locally installed Electron app (currently: the ChatGPT desktop app).
#
# The engine never ships or downloads vendor code. It clones the app the user
# already has, gives the clone its own bundle identity, icon, and data
# directories, and re-signs it locally (ad hoc). A copy of this engine plus the
# instance config is embedded in every clone, so a clone that no longer matches
# the primary app (after the vendor auto-updates) rebuilds itself on launch.

set -u
setopt PIPE_FAIL

readonly ENGINE_VERSION="12"

# When this engine copy runs from inside an installed bundle, environment
# overrides are ignored: otherwise a same-uid process could point a
# signature-validated bundle at a config, state dir, or signing identity of its
# choosing. Overrides remain available for development (DOPPEL_DEV=1).
if [[ "${0:A}" == */*.app/Contents/Resources/Doppel/* && "${DOPPEL_DEV:-0}" != "1" ]]; then
    unset DOPPEL_ASSET_ROOT DOPPEL_STATE_ROOT DOPPEL_PIN_ROOT DOPPEL_SIGN_IDENTITY \
          DOPPEL_SIGN_LEAF_SHA1 DOPPEL_PRIMARY_APP DOPPEL_PRIMARY_BUNDLE_ID \
          DOPPEL_PRIMARY_TEAM_ID DOPPEL_INSTALL_ONLY
fi

readonly ASSET_ROOT="${DOPPEL_ASSET_ROOT:-${0:A:h}}"
readonly CONFIG_FILE="$ASSET_ROOT/instance-config.zsh"

if [[ ! -f "$CONFIG_FILE" ]]; then
    print -u2 -r -- "Doppel: missing instance config at $CONFIG_FILE"
    exit 1
fi
source "$CONFIG_FILE"

for _required in DOPPEL_DISPLAY_NAME DOPPEL_BUNDLE_ID DOPPEL_URL_SCHEME DOPPEL_PROFILE_ROOT DOPPEL_CODEX_HOME; do
    [[ -n "${(P)_required:-}" ]] || { print -u2 -r -- "Doppel: config is missing $_required"; exit 1 }
done

readonly PRIMARY_APP="${DOPPEL_PRIMARY_APP:-/Applications/ChatGPT.app}"
readonly PRIMARY_BUNDLE_ID="${DOPPEL_PRIMARY_BUNDLE_ID:-com.openai.codex}"
readonly PRIMARY_TEAM_ID="${DOPPEL_PRIMARY_TEAM_ID:-2DC432GLL2}"
readonly STATE_ROOT="${DOPPEL_STATE_ROOT:-$HOME/Library/Application Support/Doppel/state/$DOPPEL_BUNDLE_ID}"
# Where the launcher looks up the requirement a bundle at a given path has to
# satisfy. Keyed by install path rather than by anything inside the bundle:
# the launcher used to read the requirement out of the very Info.plist it was
# checking, so deleting that one key and re-sealing ad hoc satisfied the
# weaker fallback. The path is the one thing the person launching the app
# chooses and a tampered bundle cannot restate.
readonly PIN_ROOT="${DOPPEL_PIN_ROOT:-$HOME/Library/Application Support/Doppel/pins}"
readonly LAUNCHER="$ASSET_ROOT/bin/doppel-launcher"
readonly ALERT_HELPER="$ASSET_ROOT/bin/doppel-alert"
readonly ICON_ICNS="$ASSET_ROOT/assets/icon.icns"
readonly ICON_PNG="$ASSET_ROOT/assets/icon.png"
readonly LOG_FILE="$STATE_ROOT/engine.log"
readonly LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

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

# A rollback is a whole copy of the app. One is kept every time an instance is
# rebuilt, and a vendor update rebuilds on its own, so without this they piled
# up unbounded — tens of gigabytes on a machine with a couple of instances.
prune_state() {
    local keep="${DOPPEL_KEEP_BACKUPS:-1}" index
    local -a rollbacks
    rollbacks=("$STATE_ROOT/Backups"/*.rollback(N/om))
    for (( index = keep + 1; index <= ${#rollbacks}; index++ )); do
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
    [[ -x "$app/Contents/MacOS/ChatGPT.real" ]] && return 0
    [[ -n "$(plist_value "$app/Contents/Info.plist" DoppelSigningIdentifier)" ]] && return 0
    return 1
}

require_engine_assets() {
    local asset
    for asset in "$LAUNCHER" "$ALERT_HELPER" "$ICON_ICNS" "$ICON_PNG"; do
        [[ -f "$asset" ]] || fail_closed "A required engine asset is missing: $asset"
    done
    [[ -x "$LAUNCHER" ]] || fail_closed "The launcher is not executable: $LAUNCHER"
}

validate_primary() {
    [[ -d "$PRIMARY_APP" ]] || fail_closed "The primary app was not found at $PRIMARY_APP"
    [[ "$(plist_value "$PRIMARY_APP/Contents/Info.plist" CFBundleIdentifier)" == "$PRIMARY_BUNDLE_ID" ]] || \
        fail_closed "The primary app has an unexpected bundle identifier. No rebuild was performed."
    /usr/bin/codesign --verify --deep --strict "$PRIMARY_APP" >/dev/null 2>&1 || \
        fail_closed "The primary app signature is invalid. No rebuild was performed."

    local signing_details
    signing_details="$(/usr/bin/codesign -dv --verbose=4 "$PRIMARY_APP" 2>&1)" || \
        fail_closed "The primary app signing identity could not be read."
    [[ "$signing_details" == *"Identifier=$PRIMARY_BUNDLE_ID"* ]] || \
        fail_closed "The primary app signing identifier is unexpected."
    [[ "$signing_details" == *"TeamIdentifier=$PRIMARY_TEAM_ID"* ]] || \
        fail_closed "The primary app is not signed by the expected vendor team."

    LC_ALL=C /usr/bin/grep -a -q 'CODEX_ELECTRON_USER_DATA_PATH' "$PRIMARY_APP/Contents/Resources/app.asar" || \
        fail_closed "This release no longer exposes the expected separate-profile control. No rebuild was performed."
}

source_version() {
    plist_value "$PRIMARY_APP/Contents/Info.plist" CFBundleVersion
}

source_executable_hash() {
    sha256_file "$PRIMARY_APP/Contents/MacOS/ChatGPT"
}

instance_is_healthy() {
    local app="$1"
    local expected_version="$2"
    local expected_hash="$3"
    local info="$app/Contents/Info.plist"

    [[ -d "$app" ]] || return 1
    [[ -x "$app/Contents/MacOS/ChatGPT" ]] || return 1
    [[ -x "$app/Contents/MacOS/ChatGPT.real" ]] || return 1
    /usr/bin/xattr -d com.apple.FinderInfo "$app" 2>/dev/null || true
    /usr/bin/xattr -d com.apple.ResourceFork "$app" 2>/dev/null || true
    [[ "$(plist_value "$info" CFBundleIdentifier)" == "$DOPPEL_BUNDLE_ID" ]] || return 1
    [[ "$(plist_value "$info" CFBundleDisplayName)" == "$DOPPEL_DISPLAY_NAME" ]] || return 1
    [[ "$(plist_value "$info" DoppelEngineVersion)" == "$ENGINE_VERSION" ]] || return 1
    [[ "$(plist_value "$info" DoppelSourceBundleVersion)" == "$expected_version" ]] || return 1
    [[ "$(plist_value "$info" DoppelSourceExecutableSHA256)" == "$expected_hash" ]] || return 1
    [[ "$(plist_value "$info" LSEnvironment.CODEX_ELECTRON_USER_DATA_PATH)" == "$DOPPEL_PROFILE_ROOT" ]] || return 1
    [[ "$(plist_value "$info" LSEnvironment.CODEX_HOME)" == "$DOPPEL_CODEX_HOME" ]] || return 1
    [[ "$(plist_value "$info" CFBundleURLTypes.0.CFBundleURLSchemes.0)" == "$DOPPEL_URL_SCHEME" ]] || return 1
    [[ -z "$(plist_value "$info" CFBundleURLTypes.0.CFBundleURLSchemes.1)" ]] || return 1
    [[ "$(plist_value "$info" SUFeedURL)" == "https://doppel.invalid/no-updates.xml" ]] || return 1
    /usr/bin/cmp -s "$app/Contents/Resources/electron.icns" "$ICON_ICNS" || return 1
    [[ "$(plist_value "$info" DoppelSigningIdentifier)" == "$DOPPEL_BUNDLE_ID" ]] || return 1

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
    /usr/bin/plutil -replace CFBundleName -string "$DOPPEL_DISPLAY_NAME" "$info"
    /usr/bin/plutil -replace CFBundleExecutable -string 'ChatGPT' "$info"
    /usr/bin/plutil -remove CFBundleIconName "$info" 2>/dev/null || true
    /usr/bin/plutil -remove NSDockTilePlugIn "$info" 2>/dev/null || true
    /usr/bin/plutil -remove LSHasLocalizedDisplayName "$info" 2>/dev/null || true
    /usr/bin/plutil -replace BundleSigningBaseName -string "${DOPPEL_SIGNING_BASE_NAME:-Doppel}" "$info"
    /usr/bin/plutil -replace CrProductDirName -string "$DOPPEL_BUNDLE_ID" "$info"
    /usr/bin/plutil -replace CFBundleAlternateNames.0 -string "$DOPPEL_DISPLAY_NAME" "$info"
    /usr/bin/plutil -replace CFBundleURLTypes.0.CFBundleURLName -string "$DOPPEL_DISPLAY_NAME" "$info"
    /usr/bin/plutil -replace CFBundleURLTypes.0.CFBundleURLSchemes -json "[\"$DOPPEL_URL_SCHEME\"]" "$info"
    /usr/bin/plutil -replace LSEnvironment.CODEX_ELECTRON_USER_DATA_PATH -string "$DOPPEL_PROFILE_ROOT" "$info"
    /usr/bin/plutil -replace LSEnvironment.CODEX_HOME -string "$DOPPEL_CODEX_HOME" "$info"
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

build_instance() {
    local target="$1"
    local version="$2"
    local executable_hash="$3"

    [[ ! -e "$target" ]] || fail_closed "Refusing to overwrite an existing staging path: $target"
    mkdir -p "${target:h}"
    log_message "Building instance $version at $target"
    /usr/bin/ditto "$PRIMARY_APP" "$target" || fail_closed "Copying the primary app into staging failed."
    /usr/bin/xattr -cr "$target" || fail_closed "Removing copied filesystem metadata failed."
    /usr/bin/codesign --verify --deep --strict "$target" >/dev/null 2>&1 || \
        fail_closed "The staged source copy did not retain the vendor signature."
    [[ "$(plist_value "$target/Contents/Info.plist" CFBundleVersion)" == "$version" ]] || \
        fail_closed "The primary app changed while the staged copy was being created."
    [[ "$(sha256_file "$target/Contents/MacOS/ChatGPT")" == "$executable_hash" ]] || \
        fail_closed "The primary executable changed while the staged copy was being created."

    local embedded="$target/Contents/Resources/Doppel"
    mkdir -p "$embedded/bin" "$embedded/assets"
    /bin/cp "$ASSET_ROOT/doppel-engine.zsh" "$CONFIG_FILE" "$embedded/" || \
        fail_closed "Embedding the self-healing engine failed."
    /bin/cp "$LAUNCHER" "$ALERT_HELPER" "$embedded/bin/" || \
        fail_closed "Embedding the engine executables failed."
    /bin/chmod 755 "$embedded/bin/doppel-launcher" "$embedded/bin/doppel-alert"
    /bin/cp "$ICON_ICNS" "$ICON_PNG" "$embedded/assets/" || \
        fail_closed "Embedding the icon assets failed."

    /bin/mv "$target/Contents/MacOS/ChatGPT" "$target/Contents/MacOS/ChatGPT.real" || \
        fail_closed "Preserving the vendor executable failed."

    # The vendor's entitlements are extracted from the copy itself, so a
    # release that changes its entitlements still re-signs correctly.
    # Restricted entitlements (team identity, push, keychain/app groups) need a
    # provisioning profile; under an ad-hoc signature AMFI kills the process at
    # spawn, so they are stripped. Library validation must be disabled because
    # the ad-hoc main binary loads the vendor-signed frameworks.
    # The plist lives in a private per-run directory (0700, unpredictable name)
    # and is re-validated immediately before signing, so it cannot be swapped
    # between filtering and use.
    local entitlements_dir entitlements
    entitlements_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/doppel-ent.XXXXXXXX")" || \
        fail_closed "Creating the private entitlements directory failed."
    /bin/chmod 700 "$entitlements_dir"
    entitlements="$entitlements_dir/entitlements.plist"
    /usr/bin/codesign -d --entitlements - --xml \
        "$target/Contents/MacOS/ChatGPT.real" > "$entitlements" 2>/dev/null || \
        fail_closed "Extracting the vendor entitlements failed."
    [[ -s "$entitlements" ]] || fail_closed "The extracted vendor entitlements were empty."
    /usr/bin/python3 - "$entitlements" <<'PYFILTER' || fail_closed "Filtering the vendor entitlements failed."
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

    /bin/cp "$LAUNCHER" "$target/Contents/MacOS/ChatGPT" || fail_closed "Installing the durable launcher failed."
    /bin/chmod 755 "$target/Contents/MacOS/ChatGPT"
    /bin/cp "$ICON_ICNS" "$target/Contents/Resources/electron.icns"
    /bin/cp "$ICON_ICNS" "$target/Contents/Resources/icon-chatgpt.icns"
    /bin/cp "$ICON_PNG" "$target/Contents/Resources/icon-chatgpt.png"
    patch_plist "$target/Contents/Info.plist" "$version" "$executable_hash" || \
        fail_closed "Patching the instance metadata failed."

    # Finder provenance and resource-fork metadata are not executable content
    # and make an otherwise valid staged bundle fail code-signature sealing.
    /usr/bin/xattr -cr "$target" || fail_closed "Removing staging-only filesystem metadata failed."

    # Re-assert the filtered key set right before signing: anything that
    # reintroduced a restricted or dyld-relaxing entitlement in the meantime
    # must not reach codesign.
    /usr/bin/python3 - "$entitlements" <<'PYVERIFY' || fail_closed "The entitlements plist changed after filtering; refusing to sign."
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

    # -i pins the code-signing identifier to this instance, so each instance has
    # its own code identity: keychain ACLs and TCC grants no longer transfer
    # from one instance to another.
    /usr/bin/codesign --force --sign "$SIGN_IDENTITY" -i "$DOPPEL_BUNDLE_ID" --options runtime \
        --entitlements "$entitlements" \
        "$target/Contents/MacOS/ChatGPT.real" >/dev/null || fail_closed "Signing the preserved vendor executable failed."
    /bin/rm -rf "$entitlements_dir"
    /usr/bin/xattr -cr "$target" || fail_closed "Removing intermediate signing metadata failed."
    /usr/bin/codesign --force --sign "$SIGN_IDENTITY" -i "$DOPPEL_BUNDLE_ID" --options runtime \
        "$target" >/dev/null || fail_closed "Signing the instance bundle failed."
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
    [[ -x "$app/Contents/MacOS/ChatGPT.real" ]] || \
        fail_closed "The bundle at $app is not a Doppel instance."
    require_engine_assets

    local info="$app/Contents/Info.plist"

    # The bundle carries its own copy of the config, engine and icons, and the
    # launcher self-heals against them on every start. Leaving them stale makes
    # the instance decide it is wrong on the next launch and rebuild itself back
    # to the previous name and colour — undoing the edit that just happened.
    local embedded="$app/Contents/Resources/Doppel"
    if [[ -d "$embedded" ]]; then
        /bin/mkdir -p "$embedded/assets"
        /bin/cp "$CONFIG_FILE" "$embedded/instance-config.zsh" || \
            fail_closed "Updating the embedded config failed."
        /bin/cp "$ASSET_ROOT/doppel-engine.zsh" "$embedded/doppel-engine.zsh" 2>/dev/null || true
        /bin/cp "$ICON_ICNS" "$embedded/assets/icon.icns" || fail_closed "Updating the embedded icon failed."
        /bin/cp "$ICON_PNG" "$embedded/assets/icon.png" || fail_closed "Updating the embedded icon failed."
        /bin/chmod 755 "$embedded/doppel-engine.zsh" 2>/dev/null || true
    fi

    /bin/cp "$ICON_ICNS" "$app/Contents/Resources/electron.icns" || fail_closed "Replacing the icon failed."
    /bin/cp "$ICON_ICNS" "$app/Contents/Resources/icon-chatgpt.icns" || fail_closed "Replacing the icon failed."
    /bin/cp "$ICON_PNG" "$app/Contents/Resources/icon-chatgpt.png" || fail_closed "Replacing the icon failed."
    /usr/bin/plutil -replace CFBundleDisplayName -string "$DOPPEL_DISPLAY_NAME" "$info"
    /usr/bin/plutil -replace CFBundleName -string "$DOPPEL_DISPLAY_NAME" "$info"
    /usr/bin/plutil -replace CFBundleAlternateNames.0 -string "$DOPPEL_DISPLAY_NAME" "$info"
    /usr/bin/plutil -replace CFBundleURLTypes.0.CFBundleURLName -string "$DOPPEL_DISPLAY_NAME" "$info"

    /usr/bin/xattr -cr "$app" || fail_closed "Removing filesystem metadata failed."
    /usr/bin/codesign --force --sign "$SIGN_IDENTITY" -i "$DOPPEL_BUNDLE_ID" --options runtime \
        "$app" >/dev/null || fail_closed "Re-signing the restyled bundle failed."
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

launch_instance() {
    local app="$1"
    shift
    require_engine_assets

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
        mkdir -p "$DOPPEL_PROFILE_ROOT" "$DOPPEL_CODEX_HOME"
        export CODEX_ELECTRON_USER_DATA_PATH="$DOPPEL_PROFILE_ROOT"
        export CODEX_HOME="$DOPPEL_CODEX_HOME"
        # Ask only after the bundle is known healthy. With ad-hoc signing, a
        # rebuild changes the TCC identity, so prompting from the launcher that
        # was about to be replaced would grant access to stale code and then
        # immediately ask the user again.
        "$app/Contents/MacOS/ChatGPT" --doppel-request-permissions || \
            log_message "The permission check could not be shown; continuing launch"
        log_message "Launching healthy instance $version"
        exec "$app/Contents/MacOS/ChatGPT.real" --user-data-dir="$DOPPEL_PROFILE_ROOT" "$@"
        fail_closed "The preserved vendor executable could not be started."
    fi

    is_doppel_instance "$app" || \
        fail_closed "There is already an app at $app and it is not a Doppel instance. Move it aside first; Doppel will not replace it."

    validate_primary
    local lock staging timestamp backup_root backup
    # The exit inside acquire_rebuild_lock only kills the $(...) subshell;
    # without this status check a concurrent rebuild would proceed unlocked.
    lock="$(acquire_rebuild_lock)" || exit 1
    timestamp="$(/bin/date '+%Y%m%d-%H%M%S')"
    staging="$STATE_ROOT/Staging/$DOPPEL_DISPLAY_NAME.$version.$timestamp.$$.app"
    build_instance "$staging" "$version" "$executable_hash"

    backup_root="$STATE_ROOT/Backups"
    mkdir -p "$backup_root"
    backup="$backup_root/$DOPPEL_DISPLAY_NAME.$timestamp.$$.app.rollback"
    if [[ -e "$app" ]]; then
        /bin/mv "$app" "$backup" || fail_closed "The existing instance could not be preserved as a rollback backup."
    fi
    if ! /bin/mv "$staging" "$app"; then
        if [[ -e "$backup" ]]; then
            if /bin/mv "$backup" "$app" 2>/dev/null; then
                fail_closed "Installing the rebuilt instance failed; the previous app was restored."
            else
                fail_closed "Installing the rebuilt instance failed AND the previous app could not be restored; recover it manually from $backup"
            fi
        fi
        fail_closed "Installing the rebuilt instance failed."
    fi

    [[ -e "$backup" ]] && "$LSREGISTER" -u "$backup" >/dev/null 2>&1 || true
    "$LSREGISTER" -f "$app" >/dev/null 2>&1 || true
    /usr/bin/touch "$app"
    record_pinned_requirement "$app"
    prune_state
    release_rebuild_lock "$lock"
    log_message "Installed instance $version; rollback preserved at $backup"
    if [[ "${DOPPEL_INSTALL_ONLY:-0}" == "1" ]]; then
        return 0
    fi
    /usr/bin/open -na "$app" || fail_closed "The rebuilt instance was installed but could not be opened."
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
