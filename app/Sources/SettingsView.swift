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

    private static let tabs: [(title: String, symbol: String)] = [
        ("General", "gearshape"), ("Updates", "arrow.down.circle"),
        ("Integrations", "puzzlepiece.extension"), ("Codex Micro", "keyboard"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            Group {
                switch selection.tab {
                case 1: updates
                case 2: integrations
                case 3: CodexMicroView(store: store)
                default: general
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 600, height: 620)
    }

    /// Icon tabs in the style of the system's own settings windows. A bordered
    /// TabView in a plain window draws its segmented control across the edge
    /// of an inset box, which looks broken next to the grouped forms.
    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(Self.tabs.indices, id: \.self) { index in
                let tab = Self.tabs[index]
                let selected = selection.tab == index
                Button { selection.tab = index } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.symbol).font(.system(size: 18))
                            .frame(height: 22)
                        Text(tab.title).font(.system(size: 11))
                    }
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .frame(width: 86, height: 50)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(selected ? Color.primary.opacity(0.08) : Color.clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - General

    private var general: some View {
        SettingsGeneral(store: store)
    }

    // MARK: - Updates

    private var updates: some View {
        Form {
            Section {
                vendorRow(.chatgpt)
            } header: {
                VStack(alignment: .leading, spacing: 18) {
                    updatesHero.heroHeader()
                    Text("ChatGPT")
                }
            }
            if store.isInstalled(.claude) {
                Section("Claude") { vendorRow(.claude) }
            }
            Section("Doppel") {
                BadgeRow(badge: StatusBadge(symbol: "square.on.square", color: .indigo,
                                            muted: !doppelUpdatesEnabled),
                         title: MenuContent.doppelVersionLabel,
                         detail: doppelUpdatesEnabled ? nil
                             : "This build was made locally, so it does not update itself.") {
                    Button("Check Now") { updaterController.checkForUpdates() }
                        .disabled(!doppelUpdatesEnabled)
                }
                BadgeRow(badge: StatusBadge(symbol: "flask.fill", color: .orange,
                                            muted: !updaterController.receivesBetaUpdates),
                         title: "Receive beta updates",
                         detail: "Less tested. Turning this off waits for a newer stable release; it does not downgrade.") {
                    Toggle("Receive beta updates", isOn: Binding(
                        get: { updaterController.receivesBetaUpdates },
                        set: { updaterController.setReceivesBetaUpdates($0) }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                .disabled(!doppelUpdatesEnabled)
            }
        }
        .formStyle(.grouped)
    }

    /// Doppel downloads ChatGPT itself; Claude updates itself and Doppel only
    /// brings the instances up to it, so the idle captions say different things.
    private func vendorRow(_ app: InstanceApp) -> some View {
        let update = store.updates[app]
        let idle = app == .chatgpt
            ? "Doppel checks every six hours and updates every instance together."
            : "Claude updates itself. Doppel checks every six hours and rebuilds the instances it left behind."
        return BadgeRow(badge: StatusBadge(symbol: app == .chatgpt ? "arrow.down" : "arrow.triangle.2.circlepath",
                                           color: app == .chatgpt ? .blue : Design.claude,
                                           muted: update == nil),
                        title: store.installedVersions[app].map { "\(app.label) \($0.display)" } ?? app.label,
                        detail: update.map(MenuContent.updateHeadline) ?? idle) {
            if store.busy.contains("update") && store.updatingApp == app {
                ProgressView().controlSize(.small)
            } else if let update {
                Button(MenuContent.bannerButtonTitle(update)) { store.beginKnownUpdate(app) }
                    .buttonStyle(.borderedProminent)
                    .tint(app.accent)
                    .disabled(store.engineOperationBusy)
            } else {
                Button(store.checkingForUpdates ? "Checking…" : "Check Now") {
                    store.checkForUpdates(userInitiated: true)
                }
                .disabled(store.checkingForUpdates || store.busy.contains("update"))
            }
        }
    }

    private var heroApps: [InstanceApp] {
        InstanceApp.allCases.filter { $0 == .chatgpt || store.isInstalled($0) }
    }

    /// Each installed vendor app and where it is going, as two keys with a lit
    /// path between them when there is somewhere to go.
    private var updatesHero: some View {
        let apps = heroApps
        var legend: [HeroLegend] = apps.map { app in
            let installed = store.installedVersions[app]
            let update = store.updates[app]
            let value: String
            if let update {
                value = update.state == .staleInstances ? "\(installed?.version ?? update.currentVersion), rebuild needed"
                    : "\(installed?.version ?? update.currentVersion) → \(update.targetVersion)"
            } else if let installed {
                value = store.upToDateApps.contains(app) ? "\(installed.version), up to date" : installed.version
            } else {
                value = "Not checked"
            }
            return HeroLegend(color: update != nil ? app.accent : (installed == nil ? Design.idle : .green),
                              label: app.label, value: value)
        }
        for app in apps {
            let current = store.instances.filter { $0.appKind == app }
            guard !current.isEmpty else { continue }
            let update = store.updates[app]
            let stale = update?.state == .staleInstances ? update?.staleInstanceCount ?? 0 : 0
            legend.append(HeroLegend(color: stale > 0 ? .orange : .green, label: "\(app.label) instances",
                                     value: "\(current.count - stale) of \(current.count) current"))
        }
        legend.append(HeroLegend(color: .indigo, label: "Doppel", value: MenuContent.doppelVersionLabel))
        let subtitle = apps.count > 1 ? "Both apps are checked every six hours" : "ChatGPT is checked every six hours"
        return HeroCard(title: "Updates", subtitle: subtitle, legend: legend) {
            VStack(spacing: 10) {
                ForEach(apps, id: \.self) { app in
                    versionKeys(app, size: apps.count > 1 ? 56 : 64)
                }
            }
            .heroPlate()
        }
    }

    private func versionKeys(_ app: InstanceApp, size: CGFloat) -> some View {
        let installed = store.installedVersions[app]
        let update = store.updates[app]
        return HStack(spacing: 10) {
            versionKey(installed.map { Self.shortVersion($0.version) } ?? "–",
                       glow: installed == nil ? Design.idle : .green, size: size)
            Image(systemName: "chevron.right.2")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(update == nil ? Design.idle : app.accent)
            versionKey(update.map { Self.shortVersion($0.targetVersion) } ?? "–",
                       glow: update == nil ? Design.idle : app.accent, size: size)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(app.label) \(installed?.version ?? "not checked")")
    }

    private func versionKey(_ label: String, glow: Color, size: CGFloat = 64) -> some View {
        HeroKey(glow: glow, size: size) {
            Text(label).font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(4)
        }
    }

    /// "26.1023.51421" reads as "26.1023" on a key; the full version is in
    /// the legend and the rows.
    static func shortVersion(_ version: String) -> String {
        version.split(separator: ".").prefix(2).joined(separator: ".")
    }

    // MARK: - Integrations

    private var integrations: some View {
        Form {
            Section {
                browserExtension
                builtInBrowser
            } header: {
                VStack(alignment: .leading, spacing: 18) {
                    integrationsHero.heroHeader()
                    Text("Some ChatGPT features exist once per Mac. Pick which instance gets each.")
                        .textCase(nil)
                }
            }
            if let status = store.nativeToolsStatus {
                Section("Status") {
                    BadgeRow(badge: StatusBadge(symbol: "cursorarrow.rays", color: .green,
                                                muted: status.computerUse != .ready),
                             title: "Computer Use", detail: nil) {
                        Text(status.computerUse == .ready ? "Ready" : "Available on demand")
                            .foregroundStyle(status.computerUse == .ready ? Color.green : Color.secondary)
                    }
                    chronicleRow(status)
                    BadgeRow(badge: StatusBadge(symbol: "magnifyingglass", color: .teal,
                                                muted: status.discoverableRollbacks == 0),
                             title: "App discovery",
                             detail: "Managed instances are resolved by exact installed path.") {
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

    /// The four once-per-Mac features as keys, each lit in the colour of the
    /// instance that holds it.
    private var integrationsHero: some View {
        let status = store.nativeToolsStatus
        let browserOwner = status?.browserHosts.first?.owner ?? ""
        let builtIn = status?.inAppBrowserInstanceName ?? ""
        let chronicleHost = status?.chronicleHost ?? ""
        let computerUseReady = status?.computerUse == .ready
        let chronicleOn = status?.chronicle == .running
        return HeroCard(title: "Integrations", subtitle: "Once per Mac, handed to one instance", legend: [
            HeroLegend(color: tint(of: browserOwner), label: "Extension",
                       value: browserOwner.isEmpty ? "Nobody" : browserOwner),
            HeroLegend(color: builtIn.isEmpty ? Design.idle : tint(of: builtIn), label: "Built-in browser",
                       value: builtIn.isEmpty ? "None" : builtIn),
            HeroLegend(color: computerUseReady ? .green : Design.idle, label: "Computer Use",
                       value: computerUseReady ? "Ready" : "On demand"),
            HeroLegend(color: chronicleOn ? tint(of: chronicleHost) : Design.idle, label: "Chronicle",
                       value: chronicleOn ? chronicleHost : "Off"),
        ]) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(44), spacing: 8), count: 2), spacing: 8) {
                featureKey("puzzlepiece.extension.fill", glow: tint(of: browserOwner))
                featureKey("safari.fill", glow: builtIn.isEmpty ? Design.idle : tint(of: builtIn))
                featureKey("cursorarrow.rays", glow: computerUseReady ? .green : Design.idle)
                featureKey("clock.fill", glow: chronicleOn ? tint(of: chronicleHost) : Design.idle)
            }
            .fixedSize()
            .heroPlate()
        }
    }

    private func featureKey(_ symbol: String, glow: Color) -> some View {
        HeroKey(glow: glow, size: 44) {
            Image(systemName: symbol).font(.system(size: 17, weight: .medium))
        }
    }

    /// An instance's tile colour by display name, which is how the native
    /// tools report their holders. Nobody, or a name Doppel does not manage,
    /// stays unlit.
    private func tint(of name: String, fallback: Color = Design.idle) -> Color {
        store.instances.first { $0.name == name }?.tileColor ?? fallback
    }

    @ViewBuilder
    private var browserExtension: some View {
        if let status = store.nativeToolsStatus {
            if status.browserHosts.isEmpty {
                BadgeRow(badge: StatusBadge(symbol: "puzzlepiece.extension.fill", color: .gray, muted: true),
                         title: "Browser extension", detail: nil) {
                    Text("Not installed").foregroundStyle(.secondary)
                }
            } else {
                // Only instances that already have an extension host of their
                // own are offered: the CLI refuses the rest rather than
                // pointing the registration at a path that is not there.
                let eligible = store.instances.filter {
                    $0.appKind == .chatgpt && $0.installed && status.instancesWithBrowserHost.contains($0.name)
                }
                let waiting = store.instances.filter {
                    $0.appKind == .chatgpt && $0.installed && !status.instancesWithBrowserHost.contains($0.name)
                }
                // Each browser has its own registration, so two instances can
                // browse at the same time in two different browsers.
                ForEach(status.browserHosts, id: \.browser) { host in
                    BadgeRow(badge: StatusBadge(symbol: "puzzlepiece.extension.fill", color: tint(of: host.owner, fallback: .gray),
                                                muted: host.owner.isEmpty),
                             title: "\(host.browser) extension",
                             detail: "Any instance can use a running one; this picks whose starts it.") {
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
            let failing = status.inAppBrowserAssignmentConflicted
                || (!status.inAppBrowserInstanceName.isEmpty && !status.inAppBrowserVendorValid)
            BadgeRow(badge: StatusBadge(symbol: "safari.fill", color: tint(of: status.inAppBrowserInstanceName, fallback: .gray),
                                        muted: status.inAppBrowserInstanceName.isEmpty),
                     title: "Built-in browser",
                     detail: builtInBrowserDetail(status) + " Change it from an instance's Engine setting.",
                     detailColor: failing ? .red : .secondary) {
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

    private func chronicleRow(_ status: NativeToolsStatus) -> some View {
        BadgeRow(badge: StatusBadge(symbol: "clock.fill", color: tint(of: status.chronicleHost, fallback: .gray),
                                    muted: status.chronicle != .running),
                 title: "Chronicle screen history",
                 detail: status.chronicleHost.isEmpty
                     ? "One recorder per Mac."
                     : "One recorder per Mac, held by \(status.chronicleHost).") {
            if status.chronicle == .running {
                Text(status.chronicleIsFresh ? "Recording" : "Recording is stale")
                    .foregroundStyle(status.chronicleIsFresh ? Color.green : Color.orange)
            } else {
                Text("Not running").foregroundStyle(.secondary)
            }
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
                BadgeRow(badge: StatusBadge(symbol: "power", color: .green, muted: !store.loginItemEnabled),
                         title: "Start Doppel at login",
                         detail: "Keeps update and permission checks running.") {
                    Toggle("Start Doppel at login", isOn: Binding(get: { store.loginItemEnabled },
                                                                  set: { store.setLoginItem($0) }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                BadgeRow(badge: StatusBadge(symbol: "sparkles", color: .blue),
                         title: "Setup guide",
                         detail: "Walks through finding ChatGPT or Claude, signing, a first instance and permissions.") {
                    Button("Open") { openWindow(id: "onboarding") }
                }
            } header: {
                hero.heroHeader()
            }
            Section("Signing") {
                BadgeRow(badge: StatusBadge(symbol: "key.fill", color: store.signingReady ? .green : .orange),
                         title: "Secure signing",
                         detail: "A local key in your login keychain signs every instance, so macOS keeps their permissions across rebuilds.") {
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

    /// Doppel's whole idea in one picture: the instances fanned out like
    /// cards, each in its own colour, lit while it runs.
    private var hero: some View {
        let instances = store.instances
        let running = instances.filter { store.isRunning($0) }.count
        let apps = [store.primaryInstalled ? "ChatGPT" : nil, store.claudeInstalled ? "Claude" : nil]
            .compactMap { $0 }
        return HeroCard(title: "Doppel", subtitle: MenuContent.doppelVersionLabel, legend: [
            HeroLegend(color: running > 0 ? .green : Design.idle, label: "Instances",
                       value: instances.isEmpty ? "None yet" : "\(instances.count), \(running) running"),
            HeroLegend(color: apps.isEmpty ? .orange : .white.opacity(0.7), label: "Apps",
                       value: apps.isEmpty ? "None found" : apps.joined(separator: " and ")),
            HeroLegend(color: store.signingReady ? .green : .orange, label: "Signing",
                       value: store.signingReady ? "Ready" : "Not set up"),
            HeroLegend(color: store.loginItemEnabled ? .green : Design.idle, label: "At login",
                       value: store.loginItemEnabled ? "Starts" : "Off"),
        ]) {
            fan(Array(instances.prefix(4)))
        }
    }

    private func fan(_ shown: [Instance]) -> some View {
        ZStack {
            if shown.isEmpty {
                HeroKey(glow: Design.idle, size: 64) {
                    Image(systemName: "plus").font(.system(size: 22, weight: .medium))
                }
            }
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, instance in
                let offset = Double(index) - Double(shown.count - 1) / 2
                IconTile(color: instance.tileColor, name: instance.name, radius: 13,
                         renderingDocumentation: true, size: 56)
                    .shadow(color: store.isRunning(instance) ? instance.tileColor.opacity(0.8) : .black.opacity(0.4),
                            radius: store.isRunning(instance) ? 10 : 4)
                    .rotationEffect(.degrees(offset * 9), anchor: .bottom)
                    .offset(x: offset * 26, y: abs(offset) * 5)
            }
        }
        .frame(width: 150, height: 104)
    }
}
