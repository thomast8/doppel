set shell := ["zsh", "-cu"]

test:
    ./app/test.zsh
    ./qa/release-notes.zsh

qa:
    ./qa/e2e.zsh
    ./qa/edge.zsh
    ./qa/engine-launch.zsh
    ./qa/update-reconcile.zsh

# A local build is ad hoc and carries no Sparkle public key, so build-app.zsh
# leaves the feed URL out and disables update checks entirely. Installing one
# over a release copy therefore leaves it stuck on the script's default version,
# unable to update itself; `just install` is for when that overwrite is the point.
# Builds into app/.build/app, leaving ~/Applications/Doppel.app alone.
build:
    ./app/build-app.zsh "{{justfile_directory()}}/app/.build/app"

# Installs a local build over ~/Applications/Doppel.app, updates disabled.
install:
    ./app/build-app.zsh

# Generate the free Sparkle signing key once. The private key stays in Keychain.
sparkle-key:
    swift package --package-path app resolve
    ./app/.build/artifacts/sparkle/Sparkle/bin/generate_keys --account ai.doppel.menubar

# Requires release-notes/<version>.md. Defaults to an ad-hoc personal release.
# Set DOPPEL_SIGN_ID and NOTARY_KEYCHAIN_PROFILE later to add Developer ID
# signing and notarisation.
package-release version build:
    DOPPEL_VERSION="{{version}}" DOPPEL_BUILD="{{build}}" ./script/package-release.zsh
