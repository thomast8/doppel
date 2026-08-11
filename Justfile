set shell := ["zsh", "-cu"]

test:
    ./app/test.zsh
    ./qa/release-notes.zsh

qa:
    ./qa/e2e.zsh
    ./qa/edge.zsh

build:
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
