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

readonly ENGINE_VERSION="8"
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
readonly LAUNCHER="$ASSET_ROOT/bin/doppel-launcher"
readonly ALERT_HELPER="$ASSET_ROOT/bin/doppel-alert"
readonly ICON_ICNS="$ASSET_ROOT/assets/icon.icns"
readonly ICON_PNG="$ASSET_ROOT/assets/icon.png"
readonly LOG_FILE="$STATE_ROOT/engine.log"
readonly LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

# Ad-hoc signatures change on every rebuild, so keychain "Always Allow" grants
# die with each vendor update. If the user has created a stable local signing
# identity (Keychain Access > Certificate Assistant, Code Signing template,
# named "Doppel Local Signing"), sign with it so grants persist.
detect_sign_identity() {
    if /usr/bin/security find-identity -v -p codesigning 2>/dev/null | \
            /usr/bin/grep -q '"Doppel Local Signing"'; then
        print -r -- "Doppel Local Signing"
    else
        print -r -- "-"
    fi
}
readonly SIGN_IDENTITY="${DOPPEL_SIGN_IDENTITY:-$(detect_sign_identity)}"

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
    [[ "$(plist_value "$info" DoppelEngineVersion)" == "$ENGINE_VERSION" ]] || return 1
    [[ "$(plist_value "$info" DoppelSourceBundleVersion)" == "$expected_version" ]] || return 1
    [[ "$(plist_value "$info" DoppelSourceExecutableSHA256)" == "$expected_hash" ]] || return 1
    [[ "$(plist_value "$info" LSEnvironment.CODEX_ELECTRON_USER_DATA_PATH)" == "$DOPPEL_PROFILE_ROOT" ]] || return 1
    [[ "$(plist_value "$info" LSEnvironment.CODEX_HOME)" == "$DOPPEL_CODEX_HOME" ]] || return 1
    [[ "$(plist_value "$info" CFBundleURLTypes.0.CFBundleURLSchemes.0)" == "$DOPPEL_URL_SCHEME" ]] || return 1
    [[ -z "$(plist_value "$info" CFBundleURLTypes.0.CFBundleURLSchemes.1)" ]] || return 1
    /usr/bin/cmp -s "$app/Contents/Resources/electron.icns" "$ICON_ICNS" || return 1
    /usr/bin/codesign --verify --deep --strict "$app" >/dev/null 2>&1 || return 1
    if [[ "$SIGN_IDENTITY" != "-" ]]; then
        # A stable identity is available; an ad-hoc-signed instance should be
        # rebuilt so keychain grants survive future rebuilds.
        /usr/bin/codesign -dv "$app" 2>&1 | /usr/bin/grep -q "Authority=$SIGN_IDENTITY" || return 1
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
    /usr/bin/plutil -replace SUEnableAutomaticChecks -bool false "$info"
    /usr/bin/plutil -replace SUAllowsAutomaticUpdates -bool false "$info"
    /usr/bin/plutil -replace SUScheduledCheckInterval -integer 0 "$info"
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
    local entitlements="$STATE_ROOT/extracted-entitlements.plist"
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

    /usr/bin/codesign --force --sign "$SIGN_IDENTITY" --options runtime --entitlements "$entitlements" \
        "$target/Contents/MacOS/ChatGPT.real" >/dev/null || fail_closed "Signing the preserved vendor executable failed."
    /usr/bin/xattr -cr "$target" || fail_closed "Removing intermediate signing metadata failed."
    /usr/bin/codesign --force --sign "$SIGN_IDENTITY" --options runtime "$target" >/dev/null || \
        fail_closed "Signing the instance bundle failed."
    /usr/bin/xattr -cr "$target" || fail_closed "Removing post-signing Finder metadata failed."
    /usr/bin/codesign --verify --deep --strict "$target" >/dev/null 2>&1 || \
        fail_closed "The staged instance bundle failed signature verification."
    instance_is_healthy "$target" "$version" "$executable_hash" || \
        fail_closed "The staged instance bundle failed its health check."
    log_message "Built and verified instance $version"
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
        if [[ "${DOPPEL_NO_EXEC:-0}" == "1" ]]; then
            log_message "Instance $version is already healthy; nothing to do."
            return 0
        fi
        mkdir -p "$DOPPEL_PROFILE_ROOT" "$DOPPEL_CODEX_HOME"
        export CODEX_ELECTRON_USER_DATA_PATH="$DOPPEL_PROFILE_ROOT"
        export CODEX_HOME="$DOPPEL_CODEX_HOME"
        log_message "Launching healthy instance $version"
        exec "$app/Contents/MacOS/ChatGPT.real" --user-data-dir="$DOPPEL_PROFILE_ROOT" "$@"
        fail_closed "The preserved vendor executable could not be started."
    fi

    validate_primary
    local lock staging timestamp backup_root backup
    lock="$(acquire_rebuild_lock)"
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
        [[ -e "$backup" ]] && /bin/mv "$backup" "$app" 2>/dev/null
        fail_closed "Installing the rebuilt instance failed; the previous app was restored."
    fi

    [[ -e "$backup" ]] && "$LSREGISTER" -u "$backup" >/dev/null 2>&1 || true
    "$LSREGISTER" -f "$app" >/dev/null 2>&1 || true
    /usr/bin/touch "$app"
    release_rebuild_lock "$lock"
    log_message "Installed instance $version; rollback preserved at $backup"
    if [[ "${DOPPEL_TEST_NO_RELAUNCH:-0}" == "1" ]]; then
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
    install)
        [[ $# -eq 2 ]] || fail_closed "Usage: doppel-engine.zsh install /path/to/App.app"
        require_engine_assets
        validate_primary
        DOPPEL_TEST_NO_RELAUNCH=1 DOPPEL_NO_EXEC=1 launch_instance "$2"
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
