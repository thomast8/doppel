# Remote Access 2.0 implementation evidence

Feature branch: `codex/remote-access-2-0`. This ledger separates observed beta checks from outstanding compatibility and recovery checks.

## Acceptance ledger

- [x] Managed startup checkpoint on the two existing independently authenticated pilot homes: direct proxy attachment and cold recovery.
- [x] Repeat that checkpoint on fresh production GUI homes.
- [ ] Per-profile private-address SSH listeners, stable ports, key isolation and revocation.
- [x] Profile-scoped GUI setup, identity confirmation, explicit access grant and private clipboard transfer.
- [ ] Background persistence, network recovery, rename/removal and runtime update behavior.
- [x] Two phone entries, correct live identities and marker tasks, reconnect without cancelling the other target.
- [x] Existing desktop authentication and work preserved during the two-account phone experiment.
- [ ] Focused tests, local SSH QA, full repository gates and packaged GUI QA.
- [ ] Security self-review, ready-for-review PR and published diff readback.
- [ ] Developer ID signing, notarization, stapling, Gatekeeper and Sparkle archive verification.

## Observed on 2026-10-01

- Installed bundled CLI: 0.159.2. Swift compiler: 6.4; deployment target remains macOS 14.
- Mac runs macOS 27.2. Installed ChatGPT is 26.928.31416, build 12553. Exact iOS and iOS ChatGPT versions remain to be recorded.
- SwiftNIO exactly 2.103.0 resolved; test dependencies warmed sequentially.
- Initial six focused runtime-client tests passed: correlation, disconnect, malformed protocol, message limit, timeout and login cancellation.
- Fresh isolated temporary-home bootstrap installed a complete official managed package and started daemon 0.159.2. No SSH listener was enabled.
- After disabling automatic updates, stopping and starting only that fresh daemon recovered the selected managed package successfully.
- Both saved iOS SSH entries showed Connected after stopping and recovering each pilot's selected managed daemon separately. Live RPC checks confirmed each actual home, email and workspace against its intended desktop identity. No desktop daemon was stopped. These checks reuse previously authenticated isolated pilot homes, not fresh production GUI homes.
- Focused Remote tests: 28 executed, 26 passed and two opt-in live checks skipped. Separate real controller bootstrap check then passed all four tests, including complete-package installation, disabled automatic updates, unauthenticated admission rejection and bounded inherited-pipe handling.
- `just build` produced a self-contained arm64 ad-hoc development application with the compiled remote helper. Subsequent rebuilt GUI setup reached a completed Personal sign-in on its fresh production home. Personal access was subsequently explicitly granted and enabled; phone acceptance remains pending.
- Installed generated schema reports the actual home in `initialize.codexHome`; `account/read`'s documented ChatGPT account contains email and plan, not a workspace ID. Existing pilot source obtains live workspace evidence from experimental `workspaceRouting.chatgptAccountId`. The implementation must check that actual field, fail closed when absent, and never substitute saved authentication or caller expectations.

## Initial unverified items (historical checkpoint)

New generated ECDSA PEM on current iOS; fresh production GUI home cold proxy attachment; Veridue GUI account login; listener lifecycle; complete GUI workflow; background recovery; final universal package; macOS 14; release distribution. Existing pilot success does not qualify these new implementation paths.

At this checkpoint the Developer ID signing identity was unavailable. Later signing checks are recorded below; notarization and distribution remain separate gates. The existing public appcast has not been changed.

- Real device-code start/cancel check passed against the fresh Personal home without logging codes. The GUI window initially clipped sign-in controls; a fixed scroll viewport and account-step scrolling now expose them. A real GUI sign-in completed and live status reports the isolated Personal workspace, runtime 0.159.2, disabled listener and stable port 54223.
- An earlier universal build contained both arm64 and x86_64 application/helper slices with macOS 14 deployment targets. This establishes packaging structure, not execution on macOS 14 or final release qualification.

- Personal access was explicitly approved and enabled on its private Meshnet address, port 54223. Initial launchd `Background` scheduling stalled the official managed launcher before daemon start; the same command completed immediately in the ordinary user context. Retaining the original plist and changing only `ProcessType` to `Standard` brought up the exact listener, and the running GUI now reports Ready on this Mac. The source uses Standard scheduling. Focused controller checks passed (three passed, one opt-in check skipped).
- The generated Personal PEM key was copied only through the explicit GUI action for user-performed iOS entry. Acceptance on the phone remains pending. No key material is recorded here.

- The phone rejected the initial SEC1 PEM before starting SSH. macOS ssh-keygen generated explicit curve parameters; it loaded in the SSH tool but failed Apple’s P-256 PEM parser. Re-encoding a private copy with macOS ssh-keygen PKCS8 preserved its SSH identity and loaded in the Apple parser. New keys now use PKCS8 PEM; legacy export preserves the original material and validates an equivalent private PKCS8 copy against its authorized public key. No account or endpoint changed. Actual iOS acceptance of the corrected export remains pending.
- Focused Remote checks after the encoding change: 31 executed, 28 passed, three opt-in checks skipped. The native key test generated and re-encoded actual keys, verified Apple parser acceptance and unchanged SSH public identity. The subsequent fingerprint clipboard slice passed all 11 focused GUI checks.
- Public remote CLI preflight failures now emit versioned sanitized JSON without adding Python to product paths. All-profile failures remain valid JSON and identify the safe profile slug. Bounded failure probes passed; internal SSH diagnostics stay on stderr.
- Veridue’s isolated production configuration is prepared on Meshnet at port 54224; it is unauthenticated and disabled. The disposable Remote QA Local profile is prepared on the private LAN, with no login or listener enabled.

- The full `just test` gate passed: 33 tests executed, 30 passed and three optional live checks skipped; release-notes QA passed.
- Required lifecycle QA exposed a definition-order bug: the locked removal worker dispatched before `cmd_remote` was defined. The worker entry point now follows all command definitions, preserving the existing lock and revocation-before-removal order. The rerun passed all 38 lifecycle checks. The first sandboxed attempt could not create the home-directory engine lock; real fixture QA uses the required filesystem access.
- A live Veridue account check currently reports the Personal workspace. Its listener remains disabled and the GUI displays the concrete workspace mismatch. A new explicit Work sign-in is in progress; this is not a successful two-account production check.

- Published release state refreshed: v1.1.11 was published on 2026-10-01 and the public appcast maximum is build 23. The 2.0 development/package default is therefore build 24. No public appcast was modified. Current Keychain identities include Apple Development and Apple Distribution, but no Developer ID Application identity; public macOS distribution remains blocked.

- Remaining required repository QA has passed 132 edge-case checks and 11 engine-launch checks; all 26 update-reconciliation checks also passed. All five required `just qa` component gates have passed, with only the failed lifecycle component repeated after its focused fix. Harmless private marker projects were prepared under each production remote directory, with no overwrite or desktop project changes.

- User reaffirmed that 2.0 is still rough and must not be published as a release. Continue development and QA; do not publish release assets or replace the public appcast.

- `DOPPEL_UNIVERSAL=1 just build` passed after granting SwiftPM its normal manifest/cache access. The new development artifact is 2.0.0 build 24, ad-hoc signed. Both the app and native remote helper contain arm64/x86_64 slices with minos 14.0; deep strict code-signature verification passed. This is not execution on macOS 14 or Developer ID/notarized distribution qualification.

## Resumed phone QA on 2026-10-02

- User requested phone QA followed by a beta release, replacing the earlier hold on all release publication. Beta publication remains conditional on the requested verification and distribution gates; do not update the stable appcast as a beta workaround.
- Live packaged status: Personal is Ready, enabled on Meshnet port 54223, runtime 0.159.2. Veridue remains disabled and blocked because its active workspace is Personal. Fresh Work sign-in is prepared in the private GUI; its temporary code is not recorded.
- Current installed ChatGPT remains 26.928.31416/build 12553, bundled CLI 0.159.2; Mac remains macOS 27.2. No Developer ID Application identity is installed.
- Both private QA applications were refreshed from the verified universal build 24, with prior artifacts retained. Sandboxed LaunchServices reported a misleading missing-executable error; the executable and signatures verified, and normal-access launch succeeded. No product workaround was added.
- iPhone Mirroring resumed and screenshots/keyboard input work. Coordinate taps repeatedly fail with bridge error `noWindowsAvailable`; raising/rebinding the window did not resolve it. Keyboard Spotlight opened ChatGPT. Existing running phone work was left untouched. A manual Connections-list handoff is pending because tapping is unavailable.
- Corrected Personal PKCS8 export was copied via the explicit GUI control, without logging the key. Current-phone import and two saved production endpoints are still unverified.

### Developer ID setup prepared

- User explicitly requested Mac certificate setup using the existing Apple developer membership. Xcode signed into the existing Apple account and shows the existing development/distribution certificates. No iOS certificate was revoked, replaced or exported.
- Xcode's certificate creation entries are disabled, but the authenticated Apple developer portal permits a Developer ID Application request for team 9W2YL9NTD6. The request uses the current G2 intermediary.
- Apple's native Certificate Assistant generated a fresh RSA-2048 key pair in the login Keychain with label `Doppel Developer ID Application 2026-10-02`. Only its public CSR was saved/staged privately, and the CSR signature verifies. The original CSR is retained; no private key was exported.
- The completed request is staged in the developer portal, awaiting action-time confirmation before certificate issuance. No certificate has yet been issued or installed, and no application has been published.
- The documented `doppel-notary` Keychain profile is absent. Certificate installation will resolve signing availability; notarization authentication remains a separate prerequisite.

### Developer ID signing verified

- User approved certificate issuance. Apple issued Developer ID Application for Thomas Tiotto, team 9W2YL9NTD6, with expiration 2031-09-17. The public certificate was installed in the login Keychain alongside the existing private key; three valid code-signing identities are now present. Existing iOS identities remain intact.
- A harmless local probe signed successfully with this identity, hardened runtime and an Apple timestamp. Strict verification passed and the certificate chain ends at Apple Root CA. This proves local Developer ID signing; no Doppel release was signed, notarized or published by this check.
- Notarization authentication remains unconfigured. Apple's native notarytool supports secure interactive app-specific-password entry and validated storage under the repository's `doppel-notary` Keychain profile. No password or private key was read or recorded.

### Notarization authentication and corrected-key phone import

- User completed secure notarization credential setup. A native `notarytool history` request using `doppel-notary` authenticated successfully; history and credentials were not displayed. No application was submitted by this authentication check.
- Mirroring briefly regained coordinate input. The production Personal endpoint was entered into current iOS Codex, and the GUI's validated PKCS8 key was transferred via the clipboard without reading its text. iOS accepted the key and saved a separate `Doppel Personal` entry at port 54223. Its initial state is Unknown/off; connection and task execution remain unverified.
- The bridge then timed out during phone observation and the clipboard-restoration action. App reattachment and surface inventory also timed out. A manual connection-toggle and clipboard-restoration handoff is pending; do not claim the restoration completed.
- The Personal listener is bound only to Meshnet address 100.126.74.37:54223 and its LaunchAgent is running. A Mac-to-own-Meshnet-address SSH probe timed out before authentication. This does not identify whether another Meshnet peer can reach it; phone reachability remains the next required check.

### Real Developer ID build checkpoint

- A separate universal Developer ID build exposed an existing packaging-check defect: `codesign -dv --verbose=4 | grep -q` returned component statuses `141 0` under `PIPE_FAIL`, falsely rejecting a valid Apple-signed bundle. The verifier now drains the complete output with plain `grep` redirected to `/dev/null`; the same real artifact produces statuses `0 0`. Shell syntax and diff checks passed.
- Repeating the failed signed build after this focused fix passed. The app and all nested helpers/framework code were signed inside-out with Developer ID, hardened runtime and timestamps; strict nested/deep verification and the corrected authority check passed. Both architectures are present. The artifact is retained at `/private/tmp/doppel-developer-id-qa.c2hu7ITT/Doppel.app`; the first artifact is also retained.
- This is a local signed build, not a notarized or published beta. Required phone connection/task/coexistence/cold-start QA, disposable live SSH lifecycle QA, final authentication/access self-review and release submission remain outstanding.

### Personal Offline diagnosis

- User reports the saved Personal entry is Offline and Meshnet looks healthy. Mac-side listener and assigned Meshnet address remain present; the generated public key matches `authorized_keys`, and effective sshd configuration permits public-key authentication for the intended user only. macOS application firewall is disabled; no firewall settings were changed.
- The exact bundled CLI `remote __session chatgpt-personal` admission path passed locally against the live isolated runtime: it verified identity, exported the intended home, printed the Personal marker and preserved intentional exit status 37. This isolates the unresolved failure to phone/SSH transport or client startup; it does not prove an actual SSH session or model task.
- Mirroring still times out. Metadata-only packet inspection is unavailable because BPF access requires administrator privileges; no permissions were expanded. The SSH log is ERROR-only, so absence of entries cannot prove that no phone request arrived. Detailed phone connection-error evidence is pending.
- Re-entering the key did not resolve Offline. The Mac's NordVPN GUI confirms the current iPhone is online and incoming/outgoing remote access is allowed; traffic routing and LAN access remain off and were not changed. Native control works for NordVPN, narrowing the automation failure to Mirroring attachment rather than proving the whole bridge unavailable.
- Recent unified logs contain repeated `kex_exchange_identification: read: Connection reset by peer [preauth]` from SSH session processes. These show pre-authentication resets, but the log lacks peer/port attribution, so they cannot yet be assigned conclusively to the phone's Personal attempt. A local client-only `IPQoS=none` probe still timed out; no server configuration change was made from this hypothesis.
- A complete quit/reopen of Mirroring is requested to recover phone inspection. No further key rotation, account replacement or network permission expansion was performed.
- Restarting Mirroring restored control. The saved Personal entry has host 100.126.74.37, port 54223, username thomastiotto and Private key authentication selected; its edit form enables Save. No credential was displayed or changed during inspection.
- A controlled off/on of only Personal produced two TCP sockets from the phone's confirmed Meshnet IP 100.126.107.254 in `SYN_RCVD`, persisting across observations. The phone's SYN reaches the Mac, but TCP does not complete; this attempt fails before SSH key authentication or runtime startup. The return route uses the assigned Meshnet interface utun6.
- NordVPN on the phone confirms Meshnet On and the expected peer addresses/remote-access permissions. Opening NordVPN while mirrored did not restore ping reachability. The Mac app is NordVPN 10.12.0. No VPN or protection settings were changed.
- Nord's current first-party iOS troubleshooting page documents that locked phones may appear active while Meshnet cannot send/receive data: https://meshnet.nordvpn.com/troubleshooting/ios. This is a possible test confound, not a proven cause. A physical, unlocked-phone reconnect test is pending to distinguish it from another Meshnet return-path problem.
- User reports the awake physical-phone attempt also fails; the sleep-mode hypothesis is therefore not established. The original retained PoC report confirms successful phone Meshnet connections on the same Mac/phone addresses and also records a timed-out Mac-to-self Meshnet SSH probe during that successful run. Self-address timeout is not a useful regression signal here.
- Full effective sshd configuration comparison shows the same transport defaults, including IPQoS. Differences are ports/owned paths/forced-command routing and production's forwarding, PTY and user-rc restrictions. Those session restrictions do not explain a TCP SYN_RCVD stall.
- A controlled direct-launch comparison is active on the unchanged, already-approved Personal endpoint/key/home/account. Only the profile's LaunchAgent was unloaded; the same bundled `remote __serve` command is running directly as the same Mac user, matching the PoC launch context. A shell EXIT trap restores the retained LaunchAgent when the diagnostic listener exits. No extra port, address or pilot credential was enabled. Phone reconnect result is pending; the initial 50-second socket observation showed only LISTEN and no new attempt.

- User confirms the direct-launch comparison also remains Offline. The temporary direct listener was stopped and the original Personal LaunchAgent explicitly restored; PID 68458 is listening on the unchanged private endpoint. Packaged status again verifies the intended Personal account/home and reports local readiness. Launch context is not established as the failure cause.
- Current NordVPN helper logs contain repeated transport timeouts and tunnel warnings, but similar warnings occur in logs from the successful PoC period; these are not sufficient to assign root cause. A narrowly filtered SYN/SYN-ACK header capture is requested because macOS denies BPF access without administrator authentication. No network settings or permissions were weakened.

- User supplied two header-only captures: phone SYN packets reach the approved listener, the Mac emits SYN-ACK replies, and both sides retransmit. The capture intentionally excludes ordinary ACK/data packets, so absence of ACK alone is not evidence; repeated SYN/SYN-ACK plus the earlier SYN_RCVD observations establishes a handshake stall for those attempts.
- Restarted only the Mac Meshnet link through NordVPN, retaining the same private address and peer permissions; VPN remains connected and real-time protection remains on. Afterward a phone connection reached TIME_WAIT with bidirectional nonzero byte counts. This proves TCP/data exchange occurred, not successful Codex authentication or a completed task. Personal listener remains PID 68458.
- User installed Little Snitch and requested its use. Native attachment to its installed configuration/monitor apps times out; its bundled read-only export command requires root, and no noninteractive sudo session is available. Requested a visible Network Monitor window; no Little Snitch rules were modified.

### Personal phone connection recovered

- User reports Personal connected after the Meshnet restart and Little Snitch installation. Mac-side verification confirms two ESTABLISHED SSH sockets from the phone to the production port, with data exchanged, while live RPC status still matches the intended Personal account/workspace on runtime 0.159.2. Neither SSH keys, forced-command routing nor account credentials were changed for this recovery.
- This supports network-path recovery, but the restart and newly installed network filter are confounding changes; a specific Meshnet defect is not proven. No Little Snitch rule was changed by the agent. Production marker tasks, cold recovery and two-account coexistence remain unverified.
- Personal TCP remains established during mirrored use. Mirroring was restarted to recover a frozen display; the phone app then stalled at new-task connection selection and was relaunched without submitting a task. The user subsequently took over the phone, ending Mirroring. No marker model turn has been submitted. Veridue remains disabled with the prior mismatched identity; its dedicated GUI sign-in has been restarted for user authentication.

### Veridue sign-in and setup readiness race

- User completed explicit Veridue sign-in and enabled its production route. Both Personal and Veridue now report Ready with live, matching account/workspace evidence and distinct stable ports 54223/54224. A phone connection to Veridue is not yet confirmed.
- The screenshot showed an enabled Veridue configuration reported as Blocked immediately after bootstrap, hiding Copy Private Key. Live inspection found the LaunchAgent and listener healthy. Root cause: enable returned after launchctl bootstrap while holding the per-profile lock; the LaunchAgent needed that lock to start, so the immediate status request raced startup.
- enable now releases the lock and waits up to eight seconds for the owned listener before returning. The local SSH QA script now asserts that the enable response itself is Ready, rather than masking this race with later polling. A timeout keeps the retained enabled setup and asks the user to Check Again.
- The GUI now keeps Copy Private Key visible, disabling it until generated key material is available. Starting sign-in resets account confirmation; the existing identity is labelled Previous sign-in during authentication, and confirmation is disabled while busy.
- Refreshed the existing running GUI through Check Again, revealing the key control, then copied Veridue's validated key explicitly without displaying it. The prior clipboard remains owned by that window until Connection Saved or dismissal.
- Focused Remote tests passed: 32 executed, 29 passed, three opt-in live checks skipped. The first sandboxed attempt failed before compilation and was rerun with normal Xcode/SwiftPM access. The final key-button visibility edit is being compiled in a fresh signed universal QA build; startup and phone regression QA remain pending.
- Fresh universal Developer ID QA build passed with the final GUI edit, strict signing checks and both architectures. Retained at /private/tmp/doppel-remote-refresh.tyupuLEK/Doppel.app; app/helper slices report minos 14.0 (not macOS 14 execution QA). Its bundled CLI verifies Veridue Ready against the live runtime. Existing running apps/listeners were preserved; the fresh build is not yet the active phone setup app. No notarization or publication occurred.

### Named-curve key regression and sign-in code copying

- User reported Veridue key rejection. Both old and refreshed exports had a valid PKCS8 header, but metadata inspection found explicit prime-field curve parameters (570 bytes). The working Personal export uses the named prime256v1 curve (241 bytes). The earlier SEC1-only export conversion wrongly skipped explicit-curve PKCS8 input.
- Re-encoding a private copy verified named P-256 output and an unchanged public key. To unblock the current GUI, the original Veridue encoding was retained in a private mode-600 file, then only its encoding was normalized; the derived public key still matches its existing authorization. Copied the corrected key through the current GUI without displaying it. Phone import is pending.
- Production generation now normalizes generated keys, and export normalizes both SEC1 and PKCS8 representations while preserving the original. Regression tests cover explicit-curve PKCS8 input, named output and unchanged authorization.
- User requested automatic one-time-code copying and a click-to-copy indication. Login events now copy the code through the existing clipboard-ownership mechanism before opening the official URL; the GUI shows a Copy code button with a copy icon and tooltip. Login completion/cancellation restores prior clipboard contents only if Doppel still owns them. Focused clipboard regression covers restoration and preserving a subsequent user copy.
- Updated focused Remote suite passed: 34 executed, 31 passed, three optional live checks skipped. A separate signed universal QA build is in progress; real-phone key acceptance and real GUI code-copy QA remain pending.
- Fresh signed universal build with the key/code fixes passed and is retained at /private/tmp/doppel-key-code-qa.h480eGEG/Doppel.app. Its packaged export verifies named P-256 (241 bytes) and the same Veridue authorization. A distinctly named signed QA copy is retained beside it; native UI attachment still times out, so automatic code-copy and cancellation remain incompletely verified on the running GUI despite passing clipboard tests. No existing setup app or live listener was replaced or stopped.

### Two production phone connections established

- Current iOS Codex visibly shows both Doppel Personal and Doppel Veridue as Connected in the same session. The corrected named-curve Veridue key was accepted. Mac-side inspection confirms separate authenticated SSH sessions from the phone to ports 54223 and 54224; live RPC status verifies both expected account/workspace identities. Sandboxed status cannot reach these Unix sockets and reports Blocked, so identity readback was repeated with normal local-runtime access.
- The new-task view on the Personal route stalled: neither project selection nor Back responded, while iPhone app-switcher input remained functional. Reopened only the phone ChatGPT app; Mac listeners, desktop tasks and accounts were preserved. No marker model turn was submitted. Task, reconnect and cold-start acceptance remain pending.

### Production phone task, cold recovery and coexistence acceptance

- Both first marker tasks completed on the real iPhone. Personal returned `personal` from `/Users/thomastiotto/Doppel SSH Pilot/personal-project`; Veridue returned `veridue` from the corresponding `veridue-project`. Each directory contains only its harmless marker. The production runtimes persisted the tasks in their separate remote homes; these reused marker folders, not pilot authentication or runtimes.
- Stopped only the idle Personal remote daemon through the official lifecycle command. iOS recovered it with a new daemon PID (82419 → 70187). Reconnected Personal and ran its second marker turn with a bounded 180-second sleep.
- While that Personal turn was running, stopped only the idle Veridue remote daemon. iOS recovered it with a new daemon PID (69907 → 74103), and Veridue off/on reconnect left Personal's daemon and its sleep process alive. Both live account/workspace checks still matched.
- Ran Veridue's second marker turn with a bounded 90-second sleep. During that turn, disconnected/reconnected only Personal; Veridue remained Connected and its sleep process remained alive. Both entries subsequently showed Connected together.
- All four turns completed, with correct markers/directories and no file changes. Completion and final responses were read back from each intended remote home. Exactly two model turns per target were used. The phone was then taken into physical use, ending Mirroring; no further task was submitted.
- Retained task IDs: Personal `01a0fcfd-16c2-7b52-939c-1cdcb4c051f8`, `01a0fd02-6bf3-7613-9b60-b614123a2719`; Veridue `01a0fcff-3a09-7d10-973a-2ec894a34504`, `01a0fd05-3461-7613-aacb-3b1cbc21f2a6`.
- Refreshed GUI attachment succeeded after launching the QA copy with its missing `--remote-access-qa` argument and dismissing unrelated update prompts. The actual setup window emits automatic code-copy feedback and exposes a clickable code button with Copy help text; clicking it again works. Disposable isolated authentication remains user-completed and is pending for the final local SSH lifecycle gate.
- The disposable GUI sign-in reached its ten-minute timeout without authentication. The actual window cleared the temporary code, restored enabled controls, preserved the saved network and displayed “The Codex request timed out. Check Again or restart sign-in.” Local SSH lifecycle QA remains blocked by this fixture's missing explicit login.
- Final `just test` passed: 35 executed, 32 passed and three opt-in live checks skipped; release-notes QA passed. The final full `just qa` gate is running sequentially. Current public release readback is 1.1.11, maximum appcast build 23; build 24 remains available for the planned beta. Mac is 27.2 and installed ChatGPT is 26.928.31416, build 12553. Exact iOS/app versions remain unrecorded.

### Final beta integration and gates

- User selected publication as `2.0.0-beta-1`, rather than a stable 2.0.0 release. The beta uses a separate Sparkle feed; the stable 1.x feed remains unchanged.
- Integrated current main through `cdd4d17`, preserving its clone-engine, permission-probe, browser status and Creator Micro fixes. The only merge conflict was command usage text; both command sets were retained.
- The earlier global QA failures coincided with another worktree running the same engine-lock suites. A clean edge replay passed all 132 checks, including the previously failing entitlements and live-permission checks. Integration subsequently required a final full run.
- Final integrated `just test` passed: 35 executed, 32 passed, three opt-in skips. Deep-link QA passed 10 checks, end-to-end QA 38, edge QA 144 and engine-launch QA 16; update reconciliation passed all 26 checks. The final full suite exited successfully.
- Disposable GUI authentication completed through its own device-code flow. Packaged first enable returned actual Ready status. Source-checkout startup subsequently hit the eight-second readiness deadline while compiling its helper; the lifecycle harness now accepts a selected packaged CLI for distribution QA, while source CLI discovery continues to compile checked-out code. No production timeout or trust check was weakened.
- iPhone Mirroring is currently unavailable because the phone is in use. Exact iOS/ChatGPT iOS versions remain unrecorded. macOS 14 execution, actual Mac logout/login and deliberate private-network disappearance/recovery remain outside this beta qualification.
- Final signed universal beta build passed with version `2.0.0-beta-1`, build 24, normal bundle identity and a separate beta feed. The existing removal confirmation now explicitly warns that revocation interrupts remote tasks.

- Final packaged local SSH QA passed quoted arguments and exit status, empty-command and wrong-key rejection, explicit private binding, disable/re-enable, port conflicts, rename and removal revocation. The harness also fixed its zsh `path` loop variable, which replaced PATH and prevented runtime startup.
- Removal now returns success after preserving data when no cache directory exists; the actual packaged removal replay passed.
- Final access self-review found dangling symlinks could appear absent through FileManager. Private writes and key generation now inspect entries with lstat and reject those links. Focused Remote tests (34 executed, 31 passed, three opt-in skips) and a real packaged SSH dangling-key regression passed; no authorization or validation checks were weakened.
- Both universal slices declare macOS 14 minimum, strict Developer ID verification passed, and the payload scan found no remote credentials. Final packaged GUI readback remains unavailable while the Mac is locked; prior running GUI and phone workflow checks are recorded above.
