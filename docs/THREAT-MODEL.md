# Doppel threat model

Doppel takes an app you already have, copies it, changes the copy's identity, and
re-signs it on your machine. That is an unusual enough thing to do that "is this
safe?" deserves a real answer rather than a reassuring one. This document is that
answer: what Doppel protects, what it deliberately does not, and where a clone is
genuinely weaker than the app it was made from.

The short version: Doppel's job is to keep two accounts apart and to make sure the
code it clones is really OpenAI's. It is not a sandbox, and it is not a defence
against something already running as you.

## What is being protected

Four things, roughly in order of how much damage losing them would do.

**Your account sessions.** Each instance holds a logged-in ChatGPT session. Those
credentials live in the instance's Electron profile and its `CODEX_HOME`. The whole
point of the product is that the work session and the personal session never see
each other's data.

**The integrity of the vendor code being cloned.** Every instance is a copy of
`/Applications/ChatGPT.app`. If Doppel could be talked into cloning something that
was not really OpenAI's app, it would faithfully reproduce the attacker's code into
every instance, sign it, and put it in your Dock with a friendly name. This is the
highest-leverage thing to get right, and it is where the strongest checks are.

**The integrity of the instances after they are built.** A built instance is a real
app bundle sitting in `~/Applications`. Nothing about being a clone makes it harder
to modify than any other app you own.

**Your privacy grants.** macOS binds microphone, camera, Accessibility and Screen
Recording permissions to a code identity. Each instance has its own, which is what
stops one instance inheriting another's access, and what makes those grants worth
keeping stable across rebuilds.

## Who is in scope

| Actor | Treatment |
|---|---|
| OpenAI | Trusted for code it signs. Doppel verifies the signature; it does not audit the app. |
| The network | Untrusted. Update metadata and downloads are treated as attacker-controlled until verified. |
| Another admin user, or root | Out of scope. They can already replace `/Applications/ChatGPT.app` and defeat everything below. A second *non-admin* account is a different matter: `/Applications` is `root:admin 0775`, and Doppel's instance directory, build cache and pins all live in the acting user's home, so a non-admin account has no path to any of this. |
| Code running as you | **Out of scope as a security boundary**, but see below. This is the honest answer and the important one. |
| macOS itself | Trusted. Doppel relies on code signing, TCC and Launch Services behaving as documented. |

The same-user case needs a plainer statement than "out of scope", because it is the
case people actually ask about. Every input Doppel builds from is writable by your
own user: the instance directory, the build cache, the pin records, the keychain
entry holding the local signing key. A process running as you can therefore
influence a rebuild. Doppel's design makes that *detectable* rather than
impossible, and detection only exists if you have set up a local signing identity.
Treat Doppel as protecting against accidents, drift and mistakes, not against local
malware.

## What Doppel actually enforces

Three properties, each with a mechanism you can go and read.

### 1. Only Apple-anchored OpenAI code gets cloned or installed

`validate_vendor_app` in `bin/doppel` and `validate_primary` in
`engine/doppel-engine.zsh` both require the candidate app to satisfy this
designated requirement:

```
anchor apple generic and identifier "com.openai.codex"
    and certificate 1[field.1.2.840.113635.100.6.2.6]
    and certificate leaf[field.1.2.840.113635.100.6.1.13]
    and certificate leaf[subject.OU] = "2DC432GLL2"
```

That is the load-bearing check, and every clause is doing work. `codesign
--verify --strict` on its own proves only that a signature correctly seals the
bundle it is attached to, which any locally made certificate can also do; a
self-signed bundle passes it happily. The Apple anchor is what turns "this is
signed" into "Apple issued the signer a certificate".

The two marker OIDs turn that into "OpenAI's *release* key signed it". A Team ID
appears in the `subject.OU` field of every certificate type Apple issues to a
team, not only Developer ID Application: Apple Development, Apple Distribution
and Developer ID Installer certificates all carry it and all chain to the Apple
root. Without the markers the requirement would accept any of them, including an
individual engineer's Apple Development certificate, which lives on laptops and
in CI and is far more widely held than a release key. `6.2.6` is the Developer ID
intermediate CA and `6.1.13` is the Developer ID Application leaf, which makes
the requirement above exactly the vendor app's own designated requirement. Check
that yourself with `codesign -d -r- /Applications/ChatGPT.app`.

The two values interpolated into that string are validated at startup, because a
value carrying a quote could close it and append its own clause: a team id of
`Z" or ! identifier "zzzzzzzz` would otherwise make the whole requirement true
for anything. That is only reachable from a checkout or under `DOPPEL_DEV=1`, but
refusing it costs one comparison.

No `codesign -dv` output is parsed as part of this decision. An earlier version
searched that text for `TeamIdentifier=<team>`, which is what made it spoofable
(see the changelog below); the requirement checks the same field without reading
a stream an attacker can write into.

This requirement gates every path where vendor code enters the system: the
installed primary before a clone is built, the app downloaded from the appcast, the
app inside a cached official DMG, and the primary again after an update is
installed.

Around that check sit four more constraints. Update metadata is fetched over HTTPS
from OpenAI's own appcast host. The download URL is not merely trusted from the
feed; it has to match the expected `persistent.oaistatic.com` release path or the
update is refused. A build older than what is installed is never installed, so a
genuine-but-old build cannot be replayed at you: naming one is refused outright,
and a feed that has fallen behind the primary is reconciled against the
installed build instead. That reconcile is the only case where a build that is
not newer is accepted at all; it downloads nothing, leaves the primary
untouched, and moves instances in one direction only, so an instance built from
a newer build than the primary is reported rather than rebuilt onto the older
one. And the whole flow fails closed: a
failed download changes nothing, a failed install puts the previous primary back,
and a rebuild refuses to proceed at all rather than cloning something it could not
verify.

### 2. A built instance cannot be silently modified

Clones are signed ad hoc unless you run `doppel-signing setup`. An ad-hoc signature
pins nothing: anyone who can write to the bundle can also re-sign it with
`codesign -f -s -`, and the result verifies. So the ad-hoc default detects
corruption, not tampering.

With a local signing identity, the instance launcher requires the bundle to satisfy
a requirement naming that certificate's leaf, and an ad-hoc re-seal cannot satisfy
it. The requirement is stored outside the bundle, under `Doppel/pins/`, keyed by
the bundle's install path. That detail is the whole trick: the launcher used to read
the requirement out of the same `Info.plist` it was about to check, so deleting one
key and re-sealing dropped it to a much weaker identifier-only test that the re-seal
then passed. The install path is chosen by whoever launches the app, and a tampered
bundle cannot restate it.

The limit is stated in the design rather than hidden: the same user can delete the
pin record, and nothing prevents that.

### 3. Instances are separated from each other and from the primary

Each instance gets its own bundle identifier, Electron profile, `CODEX_HOME`, URL
scheme, and code-signing identifier. The last one is what gives it a distinct TCC
identity, so privacy grants do not transfer between instances.

This separation is real but not total, and the gap is specific: helper processes
inside a clone keep the vendor's own signature and therefore its app-group
entitlements, so app-group containers (notifications, background services) remain
shared with the primary app and with every other instance. Isolating those would
mean re-signing the helpers, which reintroduces the AMFI kill this whole design
exists to avoid.

## Where a clone is weaker than the app it came from

This is the part a security-minded reader should look at hardest, because it is a
real regression and not a theoretical one.

**Library validation is disabled.** Re-signing the main executable while the
vendor's frameworks keep their original signature requires
`com.apple.security.cs.disable-library-validation`. The genuine ChatGPT app will
load only libraries signed by Apple or OpenAI; a clone will load any validly signed
library. Hardened runtime stays on and the entitlement verifier explicitly refuses
to sign if `com.apple.security.cs.allow-dyld-environment-variables`,
`get-task-allow` or `disable-executable-page-protection` have appeared, so
`DYLD_INSERT_LIBRARIES` injection is still blocked; but the dylib-loading policy is
genuinely relaxed relative to the vendor app.

**The signature carries no Apple identity.** A clone is ad-hoc or locally
self-signed, so Gatekeeper assessment (`spctl`) rejects it. It runs because it is
built locally and never quarantined, not because macOS approves of it.

**It is an easier target that holds live credentials.** Combine the two points
above with an ad-hoc default, and a clone is a softer thing to inject into or tamper
with than the app it was copied from, while holding a live OpenAI session. On macOS
the same-user boundary is weak everywhere, so this is not unique to Doppel, but it
is the honest summary: running instances trades some code-integrity strength for
account separation. Setting up a local signing identity buys back the tamper
detection; it cannot buy back library validation.

**The in-app browser cannot work inside a clone, permanently.** The vendor gates
its browser socket on the connecting process, its parent *and* its grandparent
each carrying OpenAI's Team ID. The grandparent is the instance's own locally
signed executable, so nothing short of OpenAI's signing key satisfies it. A clone
uses the browser extension, whose check stops at the parent process.

Doppel can assign one profile to a different engine without claiming the clone
has become trusted: it launches the untouched `/Applications/ChatGPT.app` with
that profile's external `CODEX_HOME` and Electron data path. Before launch it
re-runs the same Apple-anchored vendor requirement used for updates and refuses
if either the clone or a vendor engine for another profile is already open. The
assignment itself never terminates a process. This preserves vendor code identity
but gives up the clone's distinct Dock, URL-handler and TCC identity while the
official engine is active. It also does not isolate the vendor's shared Keychain,
app-group or Computer Use services.

The official engine is launched with its in-app Sparkle updater disabled so its
profile cannot advance independently of the fallback clone. It starts from an
allowlisted environment rather than inheriting the invoking Codex process:
profile roots and the updater switch are explicit, normal macOS account values
and an existing SSH-agent socket are retained, and unrelated `CODEX_*` and
`DOPPEL_*` state is absent. A PID-owned global
operation lock serialises engine assignment, release, launch, rebuild, removal
and update installation through process adoption. The critical worker runs in
an isolated process session, and the lease remains live while any process in
that group survives, including after a coordinator or supervisor failure.
Every Finder/Dock launch of a known clone enters that same lock. A fallback clone
is reopened with a private one-shot authorization, which its signature-validated
engine consumes while the coordinator holds the lock through positive process
adoption. Releasing or moving the slot also requires the outgoing clone to match
the official build. Assignment and official launch additionally require the
current router version, router hash and pinned bundle verification. A private runtime
receipt binds the assigned slug to the PID, process start and vendor build that
Doppel itself launched, so a manually opened process with an unverifiable
`CODEX_HOME` is treated as a conflict rather than adopted.

These roots separate account routing inside one macOS login; they are not a
multi-user security boundary. Existing profile directories retain their current
POSIX modes, and the Keychain, app group, Computer Use service and other
same-user facilities remain shared.

## The Doppel app you download

Separate question from everything above, and currently the weakest link in the
chain for a new user.

Releases are ad-hoc signed and not notarised. The app has no Team ID, Gatekeeper
does not accept it as coming from an identified developer, and installing it
requires a deliberate override. Its on-disk signature integrity check passes, so it
can detect a damaged bundle, but it establishes no publisher identity and gives you
nothing to verify against if someone puts up a lookalike release page. The published
SHA-256 helps against corruption and a truncated download; it does not help if the
page you got the hash from is the attacker's.

The fix is ordinary and known: enrol in the Apple Developer Program, sign with a
Developer ID Application certificate, notarise, and staple the ticket. That gives
the download a verifiable publisher and removes the override step. It does nothing
for the generated clones, which remain a separate problem with no vendor-key
solution.

Until that is done, the recommended install path is right-click then Open, and
*not* `xattr -dr com.apple.quarantine`. Both get the app running. The second one
teaches a gesture that macOS malware depends on, which is a bad thing to put in
front of someone who is still deciding whether to trust you.

## Threats considered

| Threat | Disposition |
|---|---|
| MITM on the update feed or download | Addressed. HTTPS, allowlisted release URL, Apple-anchored signature check on the downloaded app. |
| Malicious app planted at `/Applications/ChatGPT.app` and then cloned | Addressed. The Apple-anchored requirement rejects any bundle not signed by OpenAI. Previously bypassable; see the changelog note below. |
| Replaying an older genuine vendor build | Addressed. A build older than the installed one is never installed, whether it was named explicitly or came from a feed that fell behind; the installed build itself is accepted only to rebuild instances from the primary already in place. |
| Environment variables redirecting an installed copy's vendor checks, signing identity, or the CLI it runs | Addressed. The bundled CLI and the in-bundle engine drop the vendor-identity, appcast and signing variables unless `DOPPEL_DEV=1`, and the menu app applies the same gate to `DOPPEL_CLI`, which it used to follow unconditionally. |
| Vendor updater running inside a clone and destroying account routing | Addressed. Sparkle is disabled in clones via the vendor's own switch, plus feed and scheduled-check safeguards. |
| A forged or modified app being selected as the built-in-browser engine | Addressed. Assignment and every launch require the Apple-anchored OpenAI designated requirement and a strict deep signature. |
| Clone and vendor engines opening the same Electron profile | Addressed for managed entrypoints. CLI, menu, Finder and Dock launches share a global operation lock through positive process adoption; launch also refuses any detected ChatGPT process already using the profile. A same-user process invoking preserved binaries or editing state directly remains out of scope. |
| Official engine self-updating ahead of its fallback clone | Addressed for Doppel launches. Sparkle is disabled in the vendor-slot session, and release/reassignment verifies the outgoing fallback build. |
| A vendor release changing the assumptions Doppel patches | Addressed by failing closed. A rebuild refuses rather than producing a half-working clone. |
| `--purge-data` deleting data an instance does not own | Addressed. Shared, system and primary-owned paths are refused before anything moves. |
| A planted app bundle in a scan root running its own config | Addressed. `list`, `update check` and `adopt` look for managed apps in `~/Applications` and `/Applications`, so the config they read comes from a bundle anything running as you can write, including one downloaded and never opened. Those configs are parsed, never sourced, so a value spelling a command substitution comes back as those characters and is refused by the same field checks `create` applies. |
| An adopted bundle naming account paths its owner never chose | Partly mitigated. Adoption prints the profile root and Codex home it took on, and `--purge-data` still refuses shared, system and primary-owned paths at the point of deletion. It does not refuse an ordinary in-home path, because that is also what a legitimate instance records. |
| Tampering with a built instance | Detected only with a local signing identity. Not prevented. |
| Same-user process deleting a pin record | Accepted. Documented, not prevented. |
| Same-user process asking `codesign` to sign with the local key | Accepted. Keep the keychain locked; documented in the README. |
| Another local user or root replacing the primary app | Out of scope. |
| Malicious dylib loaded into a clone | Partly mitigated. Library validation is off; hardened runtime and the dyld entitlement ban remain. |
| Lookalike release page for the Doppel download | **Not addressed.** Needs Developer ID signing. |

## Known gaps and accepted risks

Things a reviewer should know are still open, rather than discovering them.

- The distributed app is not signed or notarised. This is the top item, and the
  only one here that needs something Doppel cannot do for itself: an Apple
  Developer Program membership. `app/build-app.zsh` is otherwise ready for it, so
  the remaining work is a `notarytool` submission and stapling the ticket.
- `DOPPEL_HOME` remains overridable for the bundled CLI. It relocates state rather
  than changing what counts as trusted vendor code, and the QA harness depends on
  it, so it was left alone deliberately.
- The vendor check fails closed with no escape hatch. If a legitimate future
  release stopped satisfying the requirement (a changed signing identifier, say, or
  a move off Developer ID), every path refuses: `update check`, `prepare`, `apply`
  and `rebuild`. The cached-DMG fallback cannot rescue it, because the cached image
  holds the same signature and is validated by the same function, and an installed
  copy has no override left. Failing closed is the right posture for a trust check,
  but the recovery story is "ship a new Doppel". The fallback's refusals are now
  covered in `qa/edge.zsh`; its successful mount-and-rebuild arm still is not,
  because that needs a real verified official image on disk.
- Clones inherit the vendor's `allow-jit` and `allow-unsigned-executable-memory`
  entitlements, which are neither stripped nor banned. These are not clone-specific
  regressions, so they sit outside the comparison above, but read the
  `DYLD_INSERT_LIBRARIES` claim as being about dyld injection specifically, not as
  a general in-process code-integrity guarantee.
- Unit tests need Xcode. `app/test.zsh` finds a toolchain that has XCTest, but the
  Command Line Tools alone do not ship one, and swift-testing is no help: they
  carry its module but not a loadable framework, so it compiles and then fails at
  launch. The `qa/` suites need nothing beyond macOS; only the Swift tests do.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting on the repository, under the Security
tab. It is enabled, so a report reaches the maintainer without the details being
public first. Please do not open a public issue containing a working reproduction.

## Changelog of security-relevant fixes

**Vendor verification was spoofable before this document existed.** The old check
combined `codesign --verify --deep --strict` with a substring search for
`TeamIdentifier=2DC432GLL2` in `codesign -dv --verbose=4` output. Both halves can be
satisfied without any OpenAI key: an ad-hoc signature verifies fine, and the
signing identifier is echoed into the same output stream that was being searched, so
signing with an identifier containing a newline followed by
`TeamIdentifier=2DC432GLL2` made the substring match succeed. A completely fake,
ad-hoc-signed bundle was accepted as "valid vendor-signed code". Replaced by the
Apple-anchored designated requirement above, which rejects it.

**The requirement trusted the whole team, not the release key.** The first version
of the check pinned only `anchor apple generic` plus the Team ID in `subject.OU`.
Because Apple puts the Team ID in that field on every certificate type it issues to
a team, that would have accepted an Apple Development or Apple Distribution
certificate belonging to anyone in the team. The two Developer ID marker OIDs were
added so the requirement matches the vendor app's own designated requirement.

**Environment hardening was incomplete in three places.** The engine dropped
`DOPPEL_SIGN_IDENTITY` and `DOPPEL_SIGN_LEAF_SHA1` inside an installed bundle but
not `DOPPEL_SIGN_IDENTITY_NAME`, which reaches the same end by choosing which
keychain certificate is found. The CLI dropped only the appcast and update-root
overrides, leaving the vendor-identity values settable for the process that
downloads and installs vendor updates. Worst of the three, the engine's guard only
fires for the copy embedded inside an instance bundle, so none of the signing
overrides were dropped on the path `rebuild` and `update apply` actually use, where
the engine runs from `instances/<slug>/`: a caller could choose the certificate that
signed a rebuild and have it recorded as that instance's pin, converting detectable
tampering into permanently trusted tampering. The bundled CLI now scrubs the signing
and state variables as well, since it is that engine's parent.

**Requirement-language injection.** The bundle identifier and team id are
interpolated into the requirement string, and a value containing a quote could close
it and append a clause that made the requirement true for anything. Both are now
validated at startup.

## Reproducing the verification

The claims above about signature behaviour were checked rather than reasoned about.
Both of these run as written, and neither needs a keychain or touches your installed
ChatGPT:

```sh
# 1. The real installed app satisfies the requirement Doppel enforces, and that
#    requirement is the app's own. Compare the two:
codesign -d -r- /Applications/ChatGPT.app
codesign --verify --deep --strict \
  -R '=anchor apple generic and identifier "com.openai.codex"
      and certificate 1[field.1.2.840.113635.100.6.2.6]
      and certificate leaf[field.1.2.840.113635.100.6.1.13]
      and certificate leaf[subject.OU] = "2DC432GLL2"' \
  /Applications/ChatGPT.app

# 2. The fake bundle that defeated the old check, end to end.
mkdir -p Spoof.app/Contents
plutil -create xml1 Spoof.app/Contents/Info.plist
plutil -insert CFBundleIdentifier -string com.openai.codex Spoof.app/Contents/Info.plist
plutil -insert CFBundleVersion -string 1 Spoof.app/Contents/Info.plist
codesign --force --sign - -i 'com.openai.codex
TeamIdentifier=2DC432GLL2' Spoof.app

codesign -dv --verbose=4 Spoof.app           # prints TeamIdentifier=2DC432GLL2
codesign --verify --deep --strict Spoof.app  # passes: an ad-hoc seal verifies
# Both halves of the old check satisfied, with no key. The requirement rejects it.
```

Both are also wired up as assertions, so a future edit that drops the requirement
fails the suite rather than passing quietly. `qa/edge.zsh` builds that same spoof
bundle and asserts that both the CLI's and the engine's copy of the check refuse it
(they are separate copies, so covering one proves nothing about the other), and that
a CLI running from an installed-bundle path drops both an injected
`DOPPEL_PRIMARY_SCHEME` and an injected `DOPPEL_SIGN_LEAF_SHA1` before the engine
runs. Every one of those assertions was confirmed to fail against a deliberately
regressed copy, which is the only way to know a test is load-bearing rather than
decorative. `qa/e2e.zsh` covers the surrounding clone, sign, rebuild and rename
behaviour against the real vendor app, and `qa/update-reconcile.zsh` covers the
one build that is not newer and is still applied: it builds a real clone, makes
it record an older build the way the vendor updater leaves one behind, and
asserts that the reconcile rebuilds and reseals it while the primary is left
byte-for-byte alone.

---

*Drafted with AI assistance. The signature and environment-hardening claims marked
above were verified empirically against the real installed ChatGPT app and a real
built Doppel bundle, and the QA suites pass; the prose and the risk judgements have
not yet had an independent human security review.*
