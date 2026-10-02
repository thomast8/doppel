import SwiftUI
import AppKit

@MainActor
final class RemoteAccessModel: ObservableObject {
    @Published var status: RemoteAccessStatus?
    @Published var busy = false
    @Published var message: String?
    @Published var userCode: String?
    @Published var selectedAddress = ""
    @Published var confirmedIdentity = false
    var expectedProfileSlug = ""
    var loginProcess: RemoteCLIProcess?
    private var loginCancelled = false
    private var clipboard: RemoteClipboardSnapshot?

    var networkIsConfigured: Bool {
        Self.hasConfiguredNetwork(status, selectedAddress: selectedAddress)
    }

    nonisolated static func hasConfiguredNetwork(_ status: RemoteAccessStatus?, selectedAddress: String) -> Bool {
        guard let status else { return false }
        return status.remoteId != nil && status.bindAddress == selectedAddress && !selectedAddress.isEmpty
    }

    nonisolated static func shouldRestoreAfterDisruption(wasEnabled: Bool) -> Bool { wasEnabled }

    nonisolated static func canEnable(_ status: RemoteAccessStatus?, selectedAddress: String,
                                      identityConfirmed: Bool) -> Bool {
        guard let status, status.state != .blocked, status.checkedAt != nil,
              let email = status.email, !email.isEmpty,
              let account = status.accountId, !account.isEmpty,
              identityConfirmed else { return false }
        return status.networks.contains { $0.address == selectedAddress }
    }

    nonisolated static func displayDate(_ iso8601: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: iso8601) else { return iso8601 }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    func check(store: InstanceStore, profile: String) {
        confirmedIdentity = false
        run(store, ["status", profile, "--json"], parseStatus: true)
    }

    func login(store: InstanceStore, profile: String) {
        guard !busy else { return }
        guard networkIsConfigured else { message = "Save the selected network before signing in."; return }
        busy = true; loginCancelled = false; confirmedIdentity = false; message = nil; userCode = nil
        loginProcess = store.runRemoteCLI(["login", profile], timeout: 600, onLine: { [weak self] line in
            guard let self, !self.loginCancelled, let data = line.data(using: .utf8),
                  let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            if value["event"] as? String == "deviceCode" {
                self.userCode = value["userCode"] as? String
                self.copyLoginCode()
                if let string = value["verificationUrl"] as? String,
                   let url = URL(string: string), url.scheme == "https", url.host == "auth.openai.com" {
                    NSWorkspace.shared.open(url)
                }
            }
        }, completion: { [weak self] result in
            guard let self else { return }
            self.loginProcess = nil; self.busy = false
            self.restoreClipboard()
            switch result {
            case .success(let output):
                if let line = output.split(separator: "\n").last,
                   let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                   event["event"] as? String == "complete",
                   let statusData = try? JSONSerialization.data(withJSONObject: event["status"] ?? [:]),
                   let value = try? RemoteAccessStatus.parse(statusData), value.profileSlug == self.expectedProfileSlug {
                    self.status = value
                    self.userCode = nil; self.message = "Sign-in finished. Confirm the account and workspace shown below."
                } else {
                    self.userCode = nil
                    self.message = "Doppel returned an unreadable sign-in result. Check Again."
                }
            case .failure(let error): self.userCode = nil; self.message = Self.safe(error)
            }
        })
    }

    func cancelLogin() {
        loginCancelled = true
        userCode = nil
        message = "Cancelling sign-in…"
        loginProcess?.cancel()
    }

    func copyLoginCode(_ pasteboard: NSPasteboard = .general) {
        guard let userCode, !userCode.isEmpty else { return }
        copyOwnedClipboardValue(userCode, to: pasteboard)
        message = "Sign-in code copied. Click the code to copy it again."
    }

    func saveNetwork(store: InstanceStore, profile: String) {
        guard let address = status?.networks.first(where: { $0.address == selectedAddress })?.address else {
            message = "Choose a private Mac address first."; return
        }
        run(store, ["configure", profile, "--bind-address", address], parseStatus: true, then: { [weak self] in
            self?.message = "Network saved. No listener is enabled. Continue to sign in."
        })
    }

    func perform(store: InstanceStore, profile: String, command: String, extra: [String] = [], timeout: TimeInterval = 300,
                 then: (() -> Void)? = nil, failure: (() -> Void)? = nil) {
        run(store, [command, profile] + extra, parseStatus: true, timeout: timeout, then: then, failure: failure)
    }

    func setupAndEnable(store: InstanceStore, profile: String) {
        guard Self.canEnable(status, selectedAddress: selectedAddress, identityConfirmed: confirmedIdentity) else {
            message = "Sign in, verify the intended account and workspace, and choose an available private address before enabling."
            return
        }
        guard let address = status?.networks.first(where: { $0.address == selectedAddress })?.address else {
            message = "Choose a private Mac address before enabling access."; return
        }
        guard let account = status?.accountId, let email = status?.email else { return }
        run(store, ["configure", profile, "--bind-address", address], parseStatus: true, then: { [weak self] in
            guard let self else { return }
            self.perform(store: store, profile: profile, command: "enable",
                         extra: ["--expected-account-id", account, "--expected-email", email])
        })
    }

    func copyKey(store: InstanceStore, profile: String) {
        guard !busy else { return }
        busy = true
        _ = store.runRemoteCLI(["export-key", profile], onLine: { _ in }, completion: { [weak self] result in
            guard let self else { return }; self.busy = false
            if case .success(let key) = result {
                guard RemoteAccessKey.isECDSAPrivateKey(key) else {
                    self.message = "Doppel returned an invalid private key. Check Again or reinstall Doppel."
                    return
                }
                if !RemoteClipboardSnapshot.owns(changeCount: NSPasteboard.general.changeCount,
                                                 expected: self.clipboard?.ownedChangeCount,
                                                 currentValue: NSPasteboard.general.string(forType: .string),
                                                 expectedValue: self.clipboard?.ownedString) {
                    self.clipboard = nil
                }
                let pem = key.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
                self.copyOwnedClipboardValue(pem, to: .general)
                self.message = "Private key copied. Use Connection Saved to restore the previous clipboard."
            } else if case .failure(let error) = result { self.message = Self.safe(error) }
        })
    }

    func copyFingerprint(_ fingerprint: String, pasteboard: NSPasteboard = .general) {
        guard !fingerprint.isEmpty else { return }
        copyOwnedClipboardValue(fingerprint, to: pasteboard)
        message = "Fingerprint copied. Use Connection Saved to restore the previous clipboard."
    }

    func restoreClipboard(_ pasteboard: NSPasteboard = .general) {
        clipboard?.restoreIfOwned(pasteboard)
        clipboard = nil
    }

    private func copyOwnedClipboardValue(_ value: String, to pasteboard: NSPasteboard) {
        if !RemoteClipboardSnapshot.owns(changeCount: pasteboard.changeCount,
                                         expected: clipboard?.ownedChangeCount,
                                         currentValue: pasteboard.string(forType: .string),
                                         expectedValue: clipboard?.ownedString) {
            clipboard = nil
        }
        if clipboard == nil { clipboard = RemoteClipboardSnapshot.capture(pasteboard) }
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
        clipboard?.claimCurrentContents(pasteboard, expectedString: value)
    }

    func copyDetails(_ status: RemoteAccessStatus, displayName: String) {
        restoreClipboard()
        let value = "Display name: \(displayName)\nHost: \(status.host ?? status.bindAddress ?? "")\nPort: \(status.port ?? 0)\nUsername: \(status.username ?? "")\nFingerprint: \(status.hostKeyFingerprint ?? "")"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    func disruptiveAction(store: InstanceStore, profile: String, command: String, timeout: TimeInterval = 300) {
        let wasEnabled = Self.shouldRestoreAfterDisruption(wasEnabled: status?.enabled == true)
        guard wasEnabled else { perform(store: store, profile: profile, command: command, timeout: timeout); return }
        perform(store: store, profile: profile, command: "disable", then: { [weak self] in
            guard let self else { return }
            self.run(store, [command, profile], parseStatus: true, timeout: timeout, then: { [weak self] in
                self?.perform(store: store, profile: profile, command: "enable", failure: { [weak self] in
                    self?.message = "\(command) completed, but access could not be re-enabled. Check Again."
                })
            }, failure: { [weak self] in
                guard let self else { return }
                self.recoverEnabledState(store: store, profile: profile,
                                         failure: "\(command) failed; Doppel is restoring Remote Access.")
            })
        }, failure: { [weak self] in
            guard let self else { return }
            self.recoverEnabledState(store: store, profile: profile,
                                     failure: "Disable failed; Doppel is checking the original state.")
        })
    }

    private func recoverEnabledState(store: InstanceStore, profile: String, failure: String) {
        run(store, ["status", profile, "--json"], parseStatus: true, then: { [weak self] in
            guard let self else { return }
            guard self.status?.enabled == false else { self.message = failure; return }
            self.perform(store: store, profile: profile, command: "enable", then: { [weak self] in
                self?.message = "The operation failed. The original Remote Access state was restored."
            }, failure: { [weak self] in
                self?.message = "The operation failed and Remote Access could not be restored. Check Again."
            })
        }, failure: { [weak self] in
            self?.message = "The operation failed and the Remote Access state could not be verified. Check Again."
        })
    }

    private func run(_ store: InstanceStore, _ arguments: [String], parseStatus: Bool,
                     timeout: TimeInterval = 300, then: (() -> Void)? = nil,
                     failure: (() -> Void)? = nil) {
        guard !busy else { return }
        busy = true; message = nil
        _ = store.runRemoteCLI(arguments, timeout: timeout, completion: { [weak self] result in
            guard let self else { return }; self.busy = false
            switch result {
            case .success(let output):
                if parseStatus, let data = output.data(using: .utf8), let value = try? RemoteAccessStatus.parse(data),
                   value.profileSlug == self.expectedProfileSlug {
                    self.status = value
                    self.selectedAddress = self.selectedAddress.isEmpty ? (value.bindAddress ?? "") : self.selectedAddress
                    self.message = value.detail
                    then?()
                } else { self.message = "Doppel returned an unreadable or mismatched Remote Access response." }
            case .failure(let error): self.message = Self.safe(error); failure?()
            }
        })
    }

    private static func safe(_ error: Error) -> String {
        let text = error.localizedDescription
        return text.contains("\n") || text.contains("/Users/") ? "Remote Access could not complete. Check Again or try again." : text
    }
}

/// Preserves arbitrary previous pasteboard flavors and restores only while the
/// key copied by this view still owns the pasteboard.
struct RemoteClipboardSnapshot {
    let items: [[(NSPasteboard.PasteboardType, Data)]]
    private(set) var ownedChangeCount: Int?
    private(set) var ownedString: String?

    static func capture(_ pasteboard: NSPasteboard = .general) -> Self {
        let items = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        return Self(items: items, ownedChangeCount: nil, ownedString: nil)
    }

    mutating func claimCurrentContents(_ pasteboard: NSPasteboard = .general, expectedString: String) {
        ownedChangeCount = pasteboard.changeCount
        ownedString = expectedString
    }

    func restoreIfOwned(_ pasteboard: NSPasteboard = .general) {
        guard Self.owns(changeCount: pasteboard.changeCount, expected: ownedChangeCount,
                        currentValue: pasteboard.string(forType: .string), expectedValue: ownedString) else { return }
        pasteboard.clearContents()
        let restored = items.map { values in
            let item = NSPasteboardItem()
            for (type, data) in values { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(restored)
    }

    static func owns(changeCount: Int, expected: Int?, currentValue: String? = nil,
                     expectedValue: String? = nil) -> Bool {
        expected == changeCount && expectedValue != nil && currentValue == expectedValue
    }
}

struct RemoteAccessView: View {
    @ObservedObject var store: InstanceStore
    let profileID: String
    @StateObject private var model = RemoteAccessModel()
    @Environment(\.dismiss) private var dismiss

    private var profile: String { store.instances.first(where: { $0.id == profileID })?.name ?? "" }
    private var ready: Bool { model.status?.state == .ready && model.status?.enabled == true }

    private var statusLabel: String {
        switch model.status?.state {
        case .some(.notConfigured): return "Not configured"
        case .some(.signInRequired): return "Sign-in required"
        case .some(.disabled): return "Disabled"
        case .some(.ready): return "Ready on this Mac"
        case .some(.networkUnavailable): return "Network unavailable"
        case .some(.blocked): return "Blocked"
        case .none: return "Checking Remote Access…"
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
            Text("Remote Access").font(.title2.weight(.semibold))
            Text(profile).foregroundStyle(.secondary)
            Label(statusLabel, systemImage: ready ? "checkmark.circle.fill" : "network")
                .font(.headline)
            if let status = model.status {
                if let version = status.runtimeVersion { Text("Runtime \(version)").font(.caption).foregroundStyle(.secondary) }
                if let checkedAt = status.checkedAt {
                    Text("Last live check: \(RemoteAccessModel.displayDate(checkedAt))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let detail = status.detail { Text(detail).font(.callout).textSelection(.enabled) }
            }
            step(1, "Choose a network", "Use a private Wi-Fi address. Meshnet works across networks; LAN access works only on the same network.")
            Link("Set up Meshnet on macOS and iPhone/iPad",
                 destination: URL(string: "https://meshnet.nordvpn.com/getting-started/how-to-start-using-meshnet")!)
            Text("Allow the phone's incoming access in Meshnet. The Mac must stay awake and logged in; access continues when Doppel quits.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("Private Mac address", selection: $model.selectedAddress) {
                Text("Choose a private address").tag("")
                ForEach(model.status?.networks ?? [], id: \.address) { Text("\($0.interface) · \($0.address)").tag($0.address) }
            }
            .disabled(model.busy)
            Text("Save this choice to create the isolated profile setup. This does not start a listener.")
                .font(.caption).foregroundStyle(.secondary)
            Button(model.networkIsConfigured ? "Network saved" : "Save network & continue") {
                model.saveNetwork(store: store, profile: profile)
            }
            .disabled(model.busy || model.selectedAddress.isEmpty || model.networkIsConfigured)
            step(2, "Sign in to ChatGPT", "Open the secure sign-in page, enter its temporary code, then verify the email and workspace.")
                .id("remote-account")
            HStack {
                Button("Start sign-in") { model.login(store: store, profile: profile) }
                    .disabled(model.busy || profile.isEmpty || !model.networkIsConfigured)
                if let userCode = model.userCode {
                    Button { model.copyLoginCode() } label: {
                        Label("Copy \(userCode)", systemImage: "doc.on.doc").font(.system(.body, design: .monospaced))
                    }
                    .help("Copy sign-in code")
                    .accessibilityLabel("Copy sign-in code \(userCode)")
                }
                if model.loginProcess != nil { Button("Cancel sign-in") { model.cancelLogin() } }
            }
            if let status = model.status, let email = status.email, let account = status.accountId {
                Text("\(model.loginProcess == nil ? "Signed in as" : "Previous sign-in:") \(email) · workspace \(account)").font(.callout)
                Toggle("I verified this is the intended account and workspace", isOn: $model.confirmedIdentity)
                    .disabled(model.busy)
            }
            step(3, "Enable access", "Anyone with this phone key can run commands with your Mac user's file access. Profile separation covers accounts and runtimes; macOS does not sandbox these commands. It opens port \(model.status?.port ?? 54221) on the selected private address.")
            Button("Enable Remote Access") { model.setupAndEnable(store: store, profile: profile) }
                .buttonStyle(.borderedProminent)
                .disabled(model.busy || !RemoteAccessModel.canEnable(model.status,
                                                                      selectedAddress: model.selectedAddress,
                                                                      identityConfirmed: model.confirmedIdentity) || ready)
            if let status = model.status, status.remoteId != nil {
                Text(verbatim: "\(status.host ?? status.bindAddress ?? ""):\(status.port ?? 0) · \(status.username ?? "")")
                    .textSelection(.enabled)
                Text("Fingerprint: \(status.hostKeyFingerprint ?? "Unavailable")").textSelection(.enabled)
                HStack {
                    Button("Copy Details") { model.copyDetails(status, displayName: profile) }.disabled(model.busy)
                    Button("Copy Fingerprint") {
                        if let fingerprint = status.hostKeyFingerprint { model.copyFingerprint(fingerprint) }
                    }
                    .disabled(model.busy || status.hostKeyFingerprint == nil)
                    Button("Copy Private Key") { model.copyKey(store: store, profile: profile) }
                        .disabled(model.busy || status.hostKeyFingerprint == nil)
                    Button("Connection Saved") { model.restoreClipboard() }
                }
                HStack {
                    if ready {
                        Button("Replace Key") { confirm("Replace the key? Existing phone connections will stop working, and running tasks will be interrupted.") { model.disruptiveAction(store: store, profile: profile, command: "replace-key") } }
                        Button("Update Runtime") { confirm("Update runtime? Running tasks may be interrupted.") { model.disruptiveAction(store: store, profile: profile, command: "update-runtime", timeout: 600) } }
                    }
                    Button("Disable") { confirm("Disable Remote Access? Running tasks will be interrupted and the phone will lose access.") { model.perform(store: store, profile: profile, command: "disable") } }
                }.disabled(model.busy)
            }
            step(4, "Connect your phone", "In Codex for iOS, open the Codex dropdown → Settings → Add connection → SSH. Enter these details, add the private key, and verify the fingerprint.")
            step(5, "Check this Mac", "Ready here confirms the local account and listener. It does not confirm that the phone can connect.")
            if let message = model.message { Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                }
            }
            .frame(height: 560)
            .scrollIndicators(.visible)
            .onChange(of: model.networkIsConfigured) { _, configured in
                if configured { proxy.scrollTo("remote-account", anchor: .top) }
            }
            .onChange(of: model.userCode) { _, code in
                if code != nil { proxy.scrollTo("remote-account", anchor: .top) }
            }
            }
            HStack {
                Button("Check Again") { model.check(store: store, profile: profile) }.disabled(model.busy)
                Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24).frame(width: 520)
        .onAppear {
            model.expectedProfileSlug = profileID
            if !profile.isEmpty { model.check(store: store, profile: profile) }
        }
        .onChange(of: profile) { _, name in
            if !name.isEmpty && !model.busy { model.check(store: store, profile: name) }
        }
        .onDisappear {
            model.restoreClipboard()
            if model.loginProcess != nil { model.cancelLogin() }
        }
    }

    private func step(_ number: Int, _ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(number). \(title)").font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func confirm(_ text: String, action: @escaping () -> Void) {
        let alert = NSAlert(); alert.alertStyle = .warning; alert.messageText = text
        alert.addButton(withTitle: "Continue"); alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { action() }
    }
}
