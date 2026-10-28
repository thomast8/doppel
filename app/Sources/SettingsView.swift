import SwiftUI
import AppKit

/// Doppel-wide settings, split the way people look for them: the app itself,
/// updates, and the ChatGPT features that exist once per Mac and so have to be
/// handed to one instance.
struct SettingsView: View {
    @ObservedObject var store: InstanceStore
    @ObservedObject var updaterController: DoppelUpdater
    let doppelUpdatesEnabled: Bool
    @StateObject private var selection: SettingsSelection

    init(store: InstanceStore, updaterController: DoppelUpdater, doppelUpdatesEnabled: Bool,
         initialTab: Int = 0) {
        self.store = store
        self.updaterController = updaterController
        self.doppelUpdatesEnabled = doppelUpdatesEnabled
        _selection = StateObject(wrappedValue: SettingsSelection(tab: initialTab))
    }

    var body: some View {
        TabView(selection: $selection.tab) {
            general.tabItem { Label("General", systemImage: "gearshape") }.tag(0)
            updates.tabItem { Label("Updates", systemImage: "arrow.down.circle") }.tag(1)
            integrations.tabItem { Label("Integrations", systemImage: "puzzlepiece.extension") }.tag(2)
        }
        .frame(width: 560, height: 500)
    }

    // MARK: - General

    private var general: some View {
        SettingsGeneral(store: store)
    }

    // MARK: - Updates

    private var updates: some View {
        Form {
            Section("ChatGPT") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(store.installedChatGPT.map { "ChatGPT \($0.display)" } ?? "ChatGPT")
                        Text("Doppel checks every six hours and updates every instance together.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if store.busy.contains("update") {
                        ProgressView().controlSize(.small)
                    } else if let update = store.chatGPTUpdate {
                        Button(MenuContent.updateButtonTitle(update)) { store.beginKnownUpdate() }
                            .disabled(store.engineOperationBusy)
                    } else {
                        Button(store.checkingForUpdates ? "Checking…" : "Check Now") {
                            store.checkForUpdates(userInitiated: true)
                        }
                        .disabled(store.checkingForUpdates)
                    }
                }
            }
            Section("Doppel") {
                HStack {
                    Text(MenuContent.doppelVersionLabel)
                    Spacer()
                    Button("Check Now") { updaterController.checkForUpdates() }
                        .disabled(!doppelUpdatesEnabled)
                }
                Toggle(isOn: Binding(
                    get: { updaterController.receivesBetaUpdates },
                    set: { updaterController.setReceivesBetaUpdates($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Receive beta updates")
                        Text("Less tested. Turning this off waits for a newer stable release; it does not downgrade.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .disabled(!doppelUpdatesEnabled)
                if !doppelUpdatesEnabled {
                    Text("This build was made locally, so it does not update itself.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Integrations

    private var integrations: some View {
        Form {
            Section {
                browserExtension
                builtInBrowser
                creatorMicro
            } header: {
                Text("Some ChatGPT features exist once per Mac. Pick which instance gets each.")
                    .textCase(nil)
            }
            if let status = store.nativeToolsStatus {
                Section("Status") {
                    statusRow("Computer Use",
                              value: status.computerUse == .ready ? "Ready" : "Available on demand",
                              good: true)
                    chronicleRow(status)
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("App discovery")
                            Text("Managed instances are resolved by exact installed path.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if status.discoverableRollbacks > 0 {
                            let noun = status.discoverableRollbacks == 1 ? "Entry" : "Entries"
                            Button("Repair \(status.discoverableRollbacks) Duplicate \(noun)") {
                                store.repairNativeTools()
                            }
                            .disabled(store.busy.contains("native-tools"))
                        } else {
                            Text("Clean").foregroundStyle(.green)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var browserExtension: some View {
        if let status = store.nativeToolsStatus {
            if status.browserHosts.isEmpty {
                statusRow("Browser extension", value: "Not installed", good: false)
            } else {
                // Only instances that already have an extension host of their
                // own are offered: the CLI refuses the rest rather than
                // pointing the registration at a path that is not there.
                let eligible = store.instances.filter {
                    $0.installed && status.instancesWithBrowserHost.contains($0.name)
                }
                let waiting = store.instances.filter {
                    $0.installed && !status.instancesWithBrowserHost.contains($0.name)
                }
                // Each browser has its own registration, so two instances can
                // browse at the same time in two different browsers.
                ForEach(status.browserHosts, id: \.browser) { host in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(host.browser) extension")
                            Text("Any instance can use a running one; this picks whose starts it.")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("doppel native-tools claim-browser")
                                .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if eligible.isEmpty {
                            Text(host.owner).foregroundStyle(.secondary)
                        } else {
                            Menu(host.owner.isEmpty ? "Choose" : host.owner) {
                                ForEach(eligible) { instance in
                                    Button(instance.name) {
                                        store.claimBrowserHost(for: instance, browser: host.browser)
                                    }
                                    .disabled(host.ownerNames.contains(instance.name))
                                }
                            }
                            .fixedSize()
                            .disabled(store.busy.contains("native-tools"))
                        }
                    }
                }
                if status.browserHosts.count > 1, !eligible.isEmpty {
                    HStack {
                        Text("Every browser")
                        Spacer()
                        Menu("Give To") {
                            ForEach(eligible) { instance in
                                Button(instance.name) { store.claimBrowserHost(for: instance) }
                                    .disabled(status.browserOwnerNames.contains(instance.name))
                            }
                        }
                        .fixedSize()
                        .disabled(store.busy.contains("native-tools"))
                    }
                }
                if !waiting.isEmpty {
                    Text(waiting.count == 1
                         ? "\(waiting[0].name) must run once before it can hold one."
                         : "\(waiting.count) instances must run once before they can hold one.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        } else {
            Text(store.checkingNativeTools ? "Checking…" : "Status unavailable")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var builtInBrowser: some View {
        if let status = store.nativeToolsStatus {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Built-in browser")
                    Text(builtInBrowserDetail(status))
                        .font(.caption)
                        .foregroundStyle(status.inAppBrowserAssignmentConflicted
                                         || (!status.inAppBrowserInstanceName.isEmpty
                                             && !status.inAppBrowserVendorValid)
                                         ? Color.red : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Change it from an instance's Engine setting.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(status.inAppBrowserInstanceName.isEmpty ? "None" : status.inAppBrowserInstanceName)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Kept from the old Native Tools menu: each of these states once needed
    /// its own explanation, and the fix differs between them.
    private func builtInBrowserDetail(_ status: NativeToolsStatus) -> String {
        if status.inAppBrowserAssignmentConflicted {
            return "Assigned to \(status.inAppBrowserInstanceName), but \(status.inAppBrowserRuntimeInstanceName) is running. Quit official ChatGPT, then open the instance from Doppel."
        }
        if !status.inAppBrowserInstanceName.isEmpty {
            if !status.inAppBrowserVendorValid { return "Official ChatGPT failed signature verification." }
            if status.inAppBrowserRunningOutsideDoppel { return "Running outside Doppel." }
            return status.inAppBrowserRunning ? "Running on the official app." : "Runs on the official app, sharing its profile."
        }
        if status.inAppBrowserRunningOutsideDoppel {
            return "\(status.inAppBrowserRuntimeInstanceName) is running outside Doppel. Quit official ChatGPT so it opens through Doppel."
        }
        if status.inAppBrowserUnavailable {
            return "ChatGPT only opens it for an app signed by OpenAI."
        }
        return "Runs on the official app, sharing its profile."
    }

    private var creatorMicro: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Creator Micro keypad")
                Text("Running instances restart when this changes. Official ChatGPT also uses the keypad when running.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("doppel micro assign")
                    .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
            }
            Spacer()
            if store.checkingCreatorMicro {
                ProgressView().controlSize(.small)
            } else if !store.creatorMicroStatusAvailable {
                Text("Unavailable").foregroundStyle(.secondary)
            } else {
                Menu(store.instances.first { $0.id == store.creatorMicroOwnerID }?.name ?? "Nobody") {
                    ForEach(store.instances) { instance in
                        Button(instance.name) { store.assignCreatorMicro(to: instance) }
                            .disabled(store.creatorMicroOwnerID == instance.id)
                    }
                    Divider()
                    Button("Nobody") { store.releaseCreatorMicro() }
                        .disabled(store.creatorMicroOwnerID == nil)
                }
                .fixedSize()
                .disabled(store.engineOperationBusy)
            }
        }
    }

    private func chronicleRow(_ status: NativeToolsStatus) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Chronicle screen history")
                Text(status.chronicleHost.isEmpty
                     ? "One recorder per Mac."
                     : "One recorder per Mac, held by \(status.chronicleHost).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if status.chronicle == .running {
                Text(status.chronicleIsFresh ? "Recording" : "Recording is stale")
                    .foregroundStyle(status.chronicleIsFresh ? Color.green : Color.orange)
            } else {
                Text("Not running").foregroundStyle(.secondary)
            }
        }
    }

    private func statusRow(_ title: String, value: String, good: Bool) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(good ? Color.green : Color.secondary)
        }
    }
}

/// An ObservableObject rather than @State, which the Command Line Tools
/// toolchain lacks.
final class SettingsSelection: ObservableObject {
    @Published var tab: Int
    init(tab: Int) { self.tab = tab }
}

/// Split out so the login toggle re-reads the system state after each change;
/// the store publishes a change but holds no copy of it.
private struct SettingsGeneral: View {
    @ObservedObject var store: InstanceStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { store.loginItemEnabled },
                                     set: { store.setLoginItem($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Start Doppel at login")
                        Text("Keeps update and permission checks running.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Setup guide")
                        Text("Walks through ChatGPT, signing, a first instance and permissions.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Open") { openWindow(id: "onboarding") }
                }
            }
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Secure signing")
                        Text("A local key in your login keychain signs every instance, so macOS keeps their permissions across rebuilds.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if store.signingReady {
                        Text("Ready").foregroundStyle(.green)
                    } else if store.busy.contains("signing") {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Set Up…") { store.setUpSigning() }
                            .disabled(store.engineOperationBusy)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
