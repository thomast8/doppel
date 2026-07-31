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
bin/doppel edit "ChatGPT Personal" --rename "ChatGPT Home" --tint 3B82F6
bin/doppel remove "ChatGPT Personal"                # keeps the account data
bin/doppel remove "ChatGPT Personal" --purge-data    # data to the Trash too
```

`edit` renames an instance, changes its icon colour, or both, and reopens the
instance afterwards if it was running, so the change is visible immediately. Identity and data
stay put — the bundle identifier, URL scheme and data directories are fixed when
an instance is created — so a rename never separates an account from its chats.
Instances can be referred to by their current name at any time.

`remove` never erases anything: the app bundle goes to the Trash, the instance
definition is preserved under `state/Removed/` so the removal can be undone, and
account data (profile and `CODEX_HOME`) is left in place unless `--purge-data` is
given — and even then it is moved to the Trash, not deleted.

`create` clones the primary app, tints its real icon with the colour you chose,
installs the instance into `~/Applications`, and stores the instance definition in
`~/Library/Application Support/Doppel/instances/`.

### Dependencies

There are none beyond macOS. Icon tinting, the instance launcher and the error
helper are all compiled binaries that ship inside `Doppel.app`; everything else
Doppel calls — `codesign`, `security`, `sips`, `iconutil`, `lsregister` — is part
of the system. Running the CLI from a checkout instead compiles those three
helpers on demand, which is the only case that wants the Xcode Command Line
Tools.

### Menu-bar app

```sh
app/build-app.zsh          # builds and installs ~/Applications/Doppel.app
open -a ~/Applications/Doppel.app
```

A menu-bar-only front end (`LSUIElement`, so no Dock icon): list instances, launch,
rebuild, rename, recolour or remove them, create a new one from a name plus a
colour picker, and toggle **Start at Login**.

The app is self-contained. The CLI, the engine and the compiled helpers all ship
inside `Contents/Resources/doppel`, sealed by the app's own signature, so a
downloaded copy works on its own — no checkout, no package manager, no developer
tools. Every action still goes through that bundled CLI, so the two can never
disagree. `$DOPPEL_CLI` overrides the choice; a checkout at a standard location
is used when the app is run from source, skipping any path that is group- or
world-writable. An advisory lock stops launchd and Finder producing two menu-bar
icons.

Start at Login installs a user LaunchAgent (`ai.doppel.menubar`) rather than using
SMAppService, which needs a Developer ID-signed bundle that local ad-hoc builds
don't have. Turning the toggle off boots the job out and removes the plist.

## Secure signing

Doppel can create its own local code-signing identity — in the menu bar, **Set
Up Secure Signing**, or from the CLI:

```sh
bin/doppel-signing status
bin/doppel-signing setup     # creates the identity, no Keychain Access needed
bin/doppel-signing remove
```

The menu-bar route also rebuilds every instance afterwards, which is the step
that actually makes them adopt the identity.

### Why it matters

Clones are signed ad hoc by default, which has two consequences.

The visible one: macOS keychain grants ("Always Allow") are bound to the
signature, and an ad-hoc signature changes on every rebuild, so the keychain
consent dialog comes back after every vendor update.

The security one: an ad-hoc signature pins nothing. Any process running as your
user can modify a clone and re-sign it (`codesign -f -s -`), and the result still
passes verification — the instance launcher's signature check cannot tell the
difference. With a stable identity the launcher pins the certificate leaf, and an
attacker's ad-hoc re-seal no longer satisfies it (verified: an ad-hoc bundle fails
any `certificate leaf` requirement).

`doppel-signing setup` generates a code-signing certificate with OpenSSL and
imports it into your login keychain, granting `codesign` access to the key so
signing stays silent. No administrator rights and no trust prompt: the
certificate is deliberately left untrusted, because `codesign` signs with it
regardless and trusting it would need an admin authorisation. That also means
`security find-identity -v` will not list it — look for the certificate itself,
which is what Doppel does.

Keep the private key in a keychain you lock; any process running as you can
otherwise ask `codesign` to sign with it.

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
- **Library validation is disabled** in a clone. Re-signing the main executable
  while the vendor's frameworks keep their original signature requires it, so a
  clone will load any validly-signed library where the vendor app accepts only
  the vendor's own. Hardened runtime stays on and the dyld-environment
  entitlement is not granted, so `DYLD_INSERT_LIBRARIES` injection is still
  blocked (verified empirically against the built clones).
- **Doppel's boundary is your user account, not the OS.** Every input it builds
  from — the repo, the instance directory, the build cache — is writable by your
  own user, so a process already running as you can influence a rebuild. Without
  a local signing identity (above) nothing detects that; with one, tampering
  fails the pinned requirement. Treat Doppel as protecting against accidents and
  drift, not against local malware.
- **Notification and service containers are still shared.** Isolation covers the
  Electron profile and `CODEX_HOME`. Helper processes inside the clone keep the
  vendor's signature and its app-group entitlements, so app-group containers
  (notifications, background services) are shared with the primary app and with
  every other instance. Isolating those means re-signing the helpers, which
  reintroduces the AMFI kill this design exists to avoid.
- Sparkle is neutralized inside a clone (scheduled checks off, feed URL pointed
  at an unresolvable host) because an in-place vendor update would drop the
  launcher and the profile settings, silently merging two accounts. Updates
  reach instances only via the primary app plus a rebuild.
