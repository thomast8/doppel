# Doppel

Run one macOS app as several truly separate apps: separate accounts, separate data,
separate name and icon in the Dock, Finder, Spotlight and the Cmd-Tab switcher.

Doppel was built for the ChatGPT desktop app, which supports only one account per
install. It clones the app you already have into additional instances ("ChatGPT
Personal", "ChatGPT Work", each with its own tinted icon), points each instance at
its own data directories, and re-signs the clone locally. Nothing is downloaded and
no vendor code ships with this project; every clone is generated on your machine
from your own installed copy.

## Why not just a launcher script?

A wrapper that starts the same app with a different profile works, but macOS treats
the running process as the original app: same icon, same Dock identity, and only one
of them can pin to the Dock meaningfully. A Doppel instance is a real bundle with
its own bundle identifier, so macOS treats it as a genuinely different app.

## Surviving vendor auto-updates

The cloned app would normally break or go stale whenever the vendor's auto-updater
replaces the primary app. Every Doppel instance embeds the engine plus its own
config, and its launcher health-checks the bundle on every start: if the primary
app has moved on (new version, new binary hash), the instance rebuilds itself from
the current primary before launching. Updates flow in; the clone never drifts.

Because nobody launches the primary app anymore once every account lives in a
Doppel instance, its updater never gets a chance to run. `agent/` contains a
LaunchAgent that periodically opens the primary hidden while idle, lets its
updater work, and quits it again.

## Usage

```sh
bin/doppel create --name "ChatGPT Personal" \
    --bundle-id com.openai.codex.personal \
    --scheme codex-personal \
    --profile-root "$HOME/Library/Application Support/ChatGPT Personal" \
    --codex-home "$HOME/.codex-personal" \
    --tint F28C28

bin/doppel list
bin/doppel launch "ChatGPT Personal"
bin/doppel rebuild "ChatGPT Personal"
```

`create` clones the primary app, tints its real icon with the color you chose,
installs the instance into `~/Applications`, and stores the instance definition in
`~/Library/Application Support/Doppel/instances/`. Requirements: Xcode Command
Line Tools and [uv](https://docs.astral.sh/uv/) (used once per icon, for Pillow).

## Keychain prompts and the local signing identity

Clones are signed ad hoc by default. macOS keychain grants ("Always Allow") are
tied to the signature, and an ad-hoc signature changes on every rebuild, so the
keychain consent dialog returns after every vendor update. To make grants stick,
create a self-signed code-signing certificate named exactly `Doppel Local Signing`
(Keychain Access > Certificate Assistant > Create a Certificate, type "Code
Signing"). The engine detects it automatically and uses it for every build from
then on; run `bin/doppel rebuild <name>` once after creating it.

## Honest limitations

- The vendor's terms may not contemplate running modified copies. Doppel keeps
  everything local and personal-use; do not redistribute a built instance.
- "ChatGPT" and its icon belong to OpenAI. Instance names and icons you create are
  your local Finder labels, nothing more. This project is not affiliated with or
  endorsed by OpenAI.
- Deep links (`codex://`) open in whichever install claims the URL scheme; each
  instance claims only its own scheme (`codex-personal`, ...) to avoid stealing
  links from the primary.
- Instances are unsigned by Apple standards (ad hoc or self-signed), so Gatekeeper
  assessment (`spctl`) rejects them. They launch fine because they are built
  locally and never quarantined.
