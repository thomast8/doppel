# Beta channel switch release evidence

Stable 1.1.12 (build 25) adds Receive Beta Updates to the menu. The persisted Boolean selects only the fixed HTTPS stable or beta feed through Sparkle's documented delegate API. Without a saved preference the bundled feed remains authoritative, including localhost QA builds. Switching off waits for a higher stable build and never requests a downgrade. Existing Sparkle signature verification remains unchanged.

Focused updater tests and the full stable `just test` passed. The signed universal stable archive was notarized (submission c9778969-c22c-480d-8bfe-7f128dda1eb8), stapled and accepted by Gatekeeper.

An isolated signed QA copy used a deliberately older build number and its own preference domain. Its real Sparkle prompt found stable 1.1.11. After persisted beta selection, the QA target was replaced with published beta-1, verified from its installed Info.plist and executable. No production app was replaced. The menu-control bridge timed out, so the toggle click itself remains unverified through automation; the actual preference-to-Sparkle installation path was exercised.

Beta-2 will include the same switch and use build 26, higher than stable build 25. Beta-1 remains immutable. Original Remote Access phone QA is recorded separately.

Stable QA: deep-link 10, e2e 38, edge 144 and engine-launch 16 passed. Initial reconciliation create failed but its diagnostic retry succeeded; a cleanup-free focused rerun passed all 26 checks. No full-suite repeat was needed. Just-in-time self-review confirmed fixed HTTPS feed selection, unchanged EdDSA verification, persisted opt-in and no downgrade requests. No blocking updater finding remains; menu click automation is still unavailable.

Stable 1.1.12 was published from reviewed commit 1020071bd53929d7944ef56c85d8c2527441c2f6; existing-client discovery awaits approval to merge PR #50. Beta-2 universal compilation and strict Developer ID signing passed, but notarization is blocked: the previously successful doppel-notary profile is no longer found, including an explicit login-Keychain lookup. No unsigned or unnotarized beta-2 was published and its feed still points to beta-1. Focused updater tests passed on the beta branch; the same fixed-feed access review applies unchanged.

PR #50 merged as de2491286ee1f560f0592be1bbaeadd9b76d3091 after explicit approval. The existing doppel-notary profile is available again and its submission history reads successfully; no credentials or Keychain settings were changed. Beta-2 packaging is resuming.

Beta-2 build 26 distribution verification passed: Apple notarization 8491a5dc-0b3f-4515-b0ad-064fa268b1c4 Accepted, stapled ticket validated, extracted archive Gatekeeper-accepted as Notarized Developer ID, strict nested signing and Sparkle EdDSA verification passed. Both app/helper architectures declare macOS 14 minimum; actual compatibility limitations remain unchanged. No credentials were found in the package. SHA-256: 7a476c2b8f9d05d996c7cde8fe8a9721bcbed43cd23e49523183d7ab27be2fd3. The stable public feed was read back as 1.1.12 build 25.

Published v2.0.0-beta-2 as a prerelease from source 2f615ce87853539f4df6fe4a4471f61accc3ebee. The beta appcast now advertises build 26, above stable build 25, using the verified archive URL and EdDSA signature. Beta-1 and the stable feed remain unchanged.
