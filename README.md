# Doppel

Run one macOS app as several truly separate apps: separate accounts, separate data,
separate name and icon in the Dock, Finder, Spotlight and the Cmd-Tab switcher.

Doppel was built for the ChatGPT desktop app, which supports only one account per
install. It clones the app you already have into additional instances ("ChatGPT
Personal", "ChatGPT Work", each with its own tinted icon), points each instance at
its own data directories, and re-signs the clone locally. No vendor code ships
with this project; every clone is generated on your machine from your own
installed copy. When an update is available, Doppel downloads it only from the
official OpenAI appcast and verifies the vendor signature before installation.

## Why not just a launcher script?

A wrapper that starts the same app with a different profile works, but macOS treats
the running process as the original app: same icon, same Dock identity, and only one
of them can pin to the Dock meaningfully. A Doppel instance is a real bundle with
its own bundle identifier, so macOS treats it as a genuinely different app.

## Coordinated ChatGPT updates

Managed instances cannot safely run ChatGPT's own Sparkle installer: their local
identity cannot match OpenAI's signing Team ID, and an in-place vendor update
would erase Doppel's launcher and account routing. Doppel disables that updater
inside every instance and checks OpenAI's production appcast itself.

The menu app checks shortly after launch and every six hours. Its native prompt
uses the primary ChatGPT icon and the same two-stage flow as the standard updater:
download or remind later, then restart and install or wait. The download is
resumable and nothing closes until the staged app has the expected bundle ID,
build number, OpenAI Team ID and a valid strict code signature.

On restart Doppel records which instances were open, closes all managed apps,
atomically replaces the untouched primary while keeping a rollback, rebuilds
every installed instance concurrently, verifies the source build plus each
instance's pinned signature, and reopens only the apps that were previously
running. APFS copy-on-write clones avoid copying the unchanged parts of the
1+ GB vendor bundle once per instance. A failed
download changes nothing; a failed install restores the previous primary; and a
partial rebuild keeps the restart manifest and reports the exact instance.

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
bin/doppel update check
bin/doppel update prepare
bin/doppel update apply
bin/doppel update verify
bin/doppel edit "ChatGPT Personal" --rename "ChatGPT Home" --tint 3B82F6
bin/doppel remove "ChatGPT Personal"                # keeps the account data
bin/doppel remove "ChatGPT Personal" --purge-data    # data to the Trash too
bin/doppel prune                                     # drop old rollback copies
bin/doppel prune "ChatGPT Personal"                  # just this instance's
```

`edit` renames an instance, changes its icon colour, or both, and reopens the
instance afterwards if it was running, so the change is visible immediately.
Identity and data stay put — the bundle identifier, URL scheme and data
directories are fixed when an instance is created — so a rename never separates
an account from its chats. Instances can be referred to by their current name at
any time; a name that would end up sharing another instance's identifier is
refused, because one of the two would then be unreachable.

`remove` never erases anything: the app bundle goes to the Trash, the instance
definition is preserved under `state/Removed/` so the removal can be undone, and
account data (profile and `CODEX_HOME`) is left in place unless `--purge-data` is
given — and even then it is moved to the Trash, not deleted.

`--purge-data` also refuses to touch anything that is not clearly the
instance's own: a home directory or one of its standard folders, a path outside
the home directory, data another instance is using, and the directories the
primary app and the Codex CLI use by default. An instance can legitimately be
pointed at those to adopt an existing account, which is exactly why removing it
must not take them with it. The refusal happens before anything is moved, so a
refused purge leaves the instance intact; remove it without the flag and delete
what you actually want gone yourself.

Every rebuild keeps the previous bundle as a rollback, and a vendor update
rebuilds on its own, so `prune` exists to drop the ones you no longer need. It
keeps the most recent rollback per instance (`DOPPEL_KEEP_BACKUPS` to change
that) and clears any staging left by a build that died. Rebuilds prune as they
go, so this is only needed to reclaim what earlier versions left behind.

`create` clones the primary app, tints its real icon with the colour you chose,
installs the instance into `~/Applications`, and stores the instance definition in
`~/Library/Application Support/Doppel/instances/`.

### Permissions for managed apps

macOS grants privacy permissions to each app identity separately. A new Doppel
instance therefore does not inherit access from ChatGPT or from another managed
instance. Each instance's **Privacy Permissions** submenu shows the status of
**Microphone**, **Camera**, **Accessibility**, **Screen & System Audio
Recording**, and **Notifications**. Clicking a row opens that exact System
Settings category when access was denied or is already granted. If the app has
not asked yet, clicking the row first runs Apple's native request as that one
managed instance. That request is what registers an otherwise absent app in
the Microphone, Camera, Screen Recording, or Accessibility list. Doppel then
refreshes the status; it never requests unrelated permissions at the same time.

Camera and microphone are optional until that account uses the relevant feature,
so `Not requested` is informational and never raises a warning. The public
Accessibility and Screen Recording checks expose only a boolean and can lag or
disagree with the visible System Settings row; Doppel labels an inconclusive
result `Check in Settings` instead of claiming the permission is missing. Only an explicit
denial, restriction, or outdated checker changes the menu-bar icon to a warning.

Permissions that macOS grants only in the context of a specific action or
target—such as Files and Folders, Calendar, Reminders, Location, and Apple
Events—continue to be requested by ChatGPT when that feature is used. Doppel
does not manufacture broad requests for capabilities an account may never use.
Doppel never resets or writes the macOS privacy database itself; permissions
remain under your control in System Settings. The menu app checks through Launch
Services so macOS attributes the probe to the managed bundle rather than to
Doppel itself, and checks again every five minutes and after a rebuild. Managed
apps no longer raise a broad permission assistant at launch. Optional access is
requested either by ChatGPT when a feature needs it or by selecting that one row
in Doppel.

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

A menu-bar-only front end (`LSUIElement`, so no Dock icon): list instances,
launch, rebuild, rename, recolour or remove them, coordinate ChatGPT updates,
create a new one from a name plus a colour picker, and toggle **Start at Login**.

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

The requirement the launcher checks is kept outside the bundle, under
`Doppel/pins/`, keyed by the bundle's install path. That matters more than it
sounds: the launcher used to read the requirement out of the same `Info.plist`
it was about to validate, so deleting one key and re-sealing ad hoc dropped it
to a much weaker identifier-only check that the re-seal then satisfied. The
install path is chosen by whoever launches the app, and a tampered bundle
cannot restate it. Read the limits of this below — it is not a boundary against
something already running as you, only one more thing that has to be got right.

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
  from — the repo, the instance directory, the build cache, the recorded pins —
  is writable by your own user, so a process already running as you can
  influence a rebuild. Without a local signing identity (above) nothing detects
  that. With one, tampering fails the pinned requirement, and the pin cannot be
  removed from inside the bundle; but the same user can still delete the pin
  record itself, and nothing stops that. Treat Doppel as protecting against
  accidents and drift, not against local malware.
- **Notification and service containers are still shared.** Isolation covers the
  Electron profile and `CODEX_HOME`. Helper processes inside the clone keep the
  vendor's signature and its app-group entitlements, so app-group containers
  (notifications, background services) are shared with the primary app and with
  every other instance. Isolating those means re-signing the helpers, which
  reintroduces the AMFI kill this design exists to avoid.
- Sparkle is disabled inside a clone with Codex's own
  `CODEX_SPARKLE_ENABLED=false` switch (plus the legacy scheduled-check and feed
  safeguards) because an in-place vendor update would drop the launcher and the
  profile settings, silently merging two accounts. Doppel checks the official
  appcast, updates the vendor-signed primary, then rebuilds every instance.
