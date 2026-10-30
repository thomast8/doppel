set shell := ["zsh", "-cu"]

test:
    ./app/test.zsh
    python3 ./qa/launcher.py
    python3 ./qa/contents.py
    python3 ./qa/creator-micro.py
    ./qa/release-notes.zsh

qa:
    ./qa/deep-link.zsh
    ./qa/e2e.zsh
    ./qa/edge.zsh
    ./qa/engine-launch.zsh
    ./qa/update-reconcile.zsh
    ./qa/retention.zsh

qa-edge:
    ./qa/edge.zsh

qa-engine:
    ./qa/engine-launch.zsh
    ./qa/update-reconcile.zsh
    ./qa/retention.zsh

qa-claude-engine:
    zsh ./qa/claude-engine.zsh

build-claude-qa:
    DOPPEL_BUNDLE_ID=ai.doppel.menubar.claudeqa DOPPEL_SINGLE_INSTANCE_LOCK_NAME=DoppelClaudeQA DOPPEL_VERSION=2.0.5-claude-dev ./app/build-app.zsh "{{justfile_directory()}}/qa/.build/claude-menu"

qa-create-window:
    python3 ./qa/create-window.py

qa-icons:
    mkdir -p qa/.build/icon-tint
    git show v2.0.5:engine/icon/main.swift > qa/.build/icon-tint/legacy.swift
    swiftc -O qa/.build/icon-tint/legacy.swift -o qa/.build/icon-tint/legacy
    swiftc -O engine/icon/main.swift -o qa/.build/icon-tint/doppel-icon
    swiftc qa/icon-tint.swift -o qa/.build/icon-tint/check
    sips -s format png /Applications/Claude.app/Contents/Resources/electron.icns --out qa/.build/icon-tint/claude.png
    sips -s format png /Applications/ChatGPT.app/Contents/Resources/electron.icns --out qa/.build/icon-tint/chatgpt.png
    qa/.build/icon-tint/check qa/.build/icon-tint/doppel-icon qa/.build/icon-tint/legacy qa/.build/icon-tint qa/.build/icon-tint/claude.png qa/.build/icon-tint/chatgpt.png

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

# Requires release-notes/<version>.md, plus DOPPEL_SIGN_ID (Developer ID) and
# NOTARY_KEYCHAIN_PROFILE. DOPPEL_ALLOW_ADHOC=1 builds an ad-hoc release instead.
package-release version build:
    DOPPEL_VERSION="{{version}}" DOPPEL_BUILD="{{build}}" ./script/package-release.zsh
