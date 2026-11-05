import AppKit
import SwiftUI

struct InstanceBrowserSection: View {
    let instance: Instance
    @ObservedObject var browsers: ChromeProfiles

    private var bridge: ChromeBridge { instance.appKind == .chatgpt ? .chatgpt : .claude }

    var body: some View {
        Section("Browser for \(instance.name)") {
            Text("This browser belongs to this managed instance. Sign in with the same account in both. Doppel does not copy or verify login credentials.")
                .font(.caption).foregroundStyle(.secondary)
            if let profile = browsers.profile(for: instance) {
                HStack {
                    Button("Open Browser") { open(signInOnly: profile.accountConfirmed != true) }
                    Button("Set Up Bridge…") { open(signInOnly: false) }
                }
                Toggle("I confirmed both use the same account", isOn: Binding(
                    get: { profile.accountConfirmed == true },
                    set: { value in perform { try browsers.confirmAccount(profile, confirmed: value) } }))
                Text("Confirm again if either account changes. This records your confirmation; it is not an automatic account check.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Copy Connection Instructions") {
                        perform {
                            let current = try browsers.ensureProfile(for: instance)
                            browsers.copyInstructions(current, bridge: bridge)
                        }
                    }
                    .disabled(profile.accountConfirmed != true)
                    if bridge == .chatgpt {
                        Button("Pair ChatGPT Bridge…") { browsers.promptPair(profile) }
                            .disabled(profile.accountConfirmed != true)
                    }
                }
            } else {
                Button("Set Up This Instance’s Browser…") { open(signInOnly: true, setup: true) }
                let unlinked = browsers.profiles.filter { $0.ownerID == nil }
                if !unlinked.isEmpty {
                    Menu("Use an Existing Unlinked Profile…") {
                        ForEach(unlinked) { profile in
                            Button(profile.name) { confirmLink(profile) }
                        }
                    }
                }
            }
            if bridge == .claude {
                Button("Copy Claude Code Launch Command") {
                    guard let home = instance.agentHome,
                          let command = ChromeProfiles.codeCommand(agentHome: home) else {
                        showError("This instance's Code configuration directory is unavailable. Reopen Doppel after updating.")
                        return
                    }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                }
                Text("Use this command in Terminal so Claude Code uses \(instance.name)’s configuration, then sign in to that account if asked. Enable Chrome with /chrome. A generic Browser 1 label does not confirm which profile is selected.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Enable the Browser plugin inside \(instance.name), then set up and pair this browser. Its host is taken from this instance’s own runtime.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func open(signInOnly: Bool, setup: Bool = false) {
        perform {
            let profile = try browsers.ensureProfile(for: instance)
            browsers.launch(profile, setup: setup || !signInOnly, signInOnly: signInOnly)
        }
    }

    private func confirmLink(_ profile: ChromeProfile) {
        let alert = NSAlert()
        alert.messageText = "Link \(profile.name) to \(instance.name)?"
        alert.informativeText = "This keeps the existing browser data and assigns it only to this instance. You must confirm that its signed-in account matches \(instance.name) before connecting an agent."
        alert.addButton(withTitle: "Link Profile")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        perform { try browsers.link(profile, to: instance) }
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { showError(error.localizedDescription) }
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Browser Setup"
        alert.informativeText = message
        alert.runModal()
    }
}
