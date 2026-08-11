import AppKit
import Sparkle
import SwiftUI

/// Sparkle keeps ownership of discovery, signature verification, downloading,
/// extraction and installation. Doppel owns only the presentation layer so an
/// update feels like part of the app instead of a second, unrelated utility.
@MainActor
final class DoppelUpdater {
    let updater: SPUUpdater
    private let userDriver: DoppelUpdateDriver
    private var started = false

    init(startingUpdater: Bool) {
        let userDriver = DoppelUpdateDriver(hostBundle: .main)
        self.userDriver = userDriver
        updater = SPUUpdater(
            hostBundle: .main,
            applicationBundle: .main,
            userDriver: userDriver,
            delegate: nil)
        userDriver.updater = updater
        if startingUpdater { start() }
    }

    func start() {
        guard !started else { return }
        do {
            try updater.start()
            started = true
        } catch {
            FileHandle.standardError.write(Data(
                "Doppel updater could not start: \(error.localizedDescription)\n".utf8))
        }
    }

    func checkForUpdates() {
        updater.checkForUpdates()
    }

    func checkForUpdatesInBackground() {
        updater.checkForUpdatesInBackground()
    }
}

struct DoppelUpdatePromptModel: Equatable {
    let currentVersion: String
    let availableVersion: String
    let informationOnly: Bool
    let critical: Bool

    var title: String {
        informationOnly
            ? "Doppel \(availableVersion) is available"
            : "Doppel \(availableVersion) is ready"
    }

    var detail: String {
        informationOnly
            ? "You’re using \(currentVersion). Open the release page to learn more."
            : "You’re using \(currentVersion). The download will be verified before installation."
    }

    var primaryActionTitle: String {
        informationOnly ? "View Update" : "Install Update"
    }
}

/// A narrow user-driver adapter: the discovery choice is rendered by Doppel,
/// while Sparkle's standard driver continues to handle permissions, progress,
/// errors and the final relaunch hand-off.
@MainActor
final class DoppelUpdateDriver: NSObject, SPUUserDriver, NSWindowDelegate {
    weak var updater: SPUUpdater?

    private let hostBundle: Bundle
    private let standardDriver: SPUStandardUserDriver
    private var promptWindow: NSPanel?
    private var promptReply: ((SPUUserUpdateChoice) -> Void)?
    private var closingForChoice = false

    init(hostBundle: Bundle) {
        self.hostBundle = hostBundle
        standardDriver = SPUStandardUserDriver(hostBundle: hostBundle, delegate: nil)
        super.init()
    }

    func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        dismissPrompt(replying: .dismiss)

        let currentVersion = hostBundle.object(
            forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "this version"
        let model = DoppelUpdatePromptModel(
            currentVersion: currentVersion,
            availableVersion: appcastItem.displayVersionString,
            informationOnly: appcastItem.isInformationOnlyUpdate,
            critical: appcastItem.isCriticalUpdate)
        let automaticallyInstalls = updater?.automaticallyDownloadsUpdates ?? false
        let allowsAutomaticUpdates = updater?.allowsAutomaticUpdates ?? false

        promptReply = reply
        let content = DoppelUpdatePrompt(
            model: model,
            automaticallyInstalls: automaticallyInstalls,
            allowsAutomaticUpdates: allowsAutomaticUpdates,
            choose: { [weak self] choice in
                guard let self else { return }
                if choice == .install, appcastItem.isInformationOnlyUpdate {
                    if let infoURL = appcastItem.infoURL {
                        NSWorkspace.shared.open(infoURL)
                    }
                    self.dismissPrompt(replying: .dismiss)
                } else {
                    self.dismissPrompt(replying: choice)
                }
            },
            setAutomaticallyInstalls: { [weak self] enabled in
                self?.updater?.automaticallyDownloadsUpdates = enabled
            })

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 310),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        panel.delegate = self
        panel.title = "Doppel Update"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace]
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.contentView = NSHostingView(rootView: content)
        panel.center()
        promptWindow = panel

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard !closingForChoice, notification.object as? NSWindow === promptWindow else { return }
        let reply = promptReply
        promptReply = nil
        promptWindow = nil
        reply?(.dismiss)
    }

    private func dismissPrompt(replying choice: SPUUserUpdateChoice?) {
        let reply = promptReply
        promptReply = nil
        let window = promptWindow
        promptWindow = nil
        closingForChoice = true
        window?.close()
        closingForChoice = false
        if let choice { reply?(choice) }
    }

    // MARK: - Standard Sparkle fallbacks

    func show(_ request: SPUUpdatePermissionRequest,
              reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        standardDriver.show(request, reply: reply)
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        standardDriver.showUserInitiatedUpdateCheck(cancellation: cancellation)
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        // The custom prompt deliberately keeps the release decision compact.
        // A future appcast can surface notes in Doppel without handing an
        // unattached notes view to Sparkle's stock update-alert controller.
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        standardDriver.showUpdateNotFoundWithError(error, acknowledgement: acknowledgement)
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        standardDriver.showUpdaterError(error, acknowledgement: acknowledgement)
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        standardDriver.showDownloadInitiated(cancellation: cancellation)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        standardDriver.showDownloadDidReceiveExpectedContentLength(expectedContentLength)
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        standardDriver.showDownloadDidReceiveData(ofLength: length)
    }

    func showDownloadDidStartExtractingUpdate() {
        standardDriver.showDownloadDidStartExtractingUpdate()
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        standardDriver.showExtractionReceivedProgress(progress)
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        standardDriver.showReady(toInstallAndRelaunch: reply)
    }

    func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void
    ) {
        standardDriver.showInstallingUpdate(
            withApplicationTerminated: applicationTerminated,
            retryTerminatingApplication: retryTerminatingApplication)
    }

    func showUpdateInstalledAndRelaunched(
        _ relaunched: Bool,
        acknowledgement: @escaping () -> Void
    ) {
        standardDriver.showUpdateInstalledAndRelaunched(
            relaunched,
            acknowledgement: acknowledgement)
    }

    func dismissUpdateInstallation() {
        dismissPrompt(replying: nil)
        standardDriver.dismissUpdateInstallation()
    }

    func showUpdateInFocus() {
        if let promptWindow {
            NSApp.activate(ignoringOtherApps: true)
            promptWindow.makeKeyAndOrderFront(nil)
        } else if standardDriver.responds(to: NSSelectorFromString("showUpdateInFocus")) {
            standardDriver.perform(NSSelectorFromString("showUpdateInFocus"))
        }
    }
}

private final class DoppelUpdatePromptState: ObservableObject {
    @Published var automaticInstall: Bool

    init(automaticInstall: Bool) {
        self.automaticInstall = automaticInstall
    }
}

private struct DoppelUpdatePrompt: View {
    let model: DoppelUpdatePromptModel
    let automaticallyInstalls: Bool
    let allowsAutomaticUpdates: Bool
    let choose: (SPUUserUpdateChoice) -> Void
    let setAutomaticallyInstalls: (Bool) -> Void
    @StateObject private var state: DoppelUpdatePromptState

    init(
        model: DoppelUpdatePromptModel,
        automaticallyInstalls: Bool,
        allowsAutomaticUpdates: Bool,
        choose: @escaping (SPUUserUpdateChoice) -> Void,
        setAutomaticallyInstalls: @escaping (Bool) -> Void
    ) {
        self.model = model
        self.automaticallyInstalls = automaticallyInstalls
        self.allowsAutomaticUpdates = allowsAutomaticUpdates
        self.choose = choose
        self.setAutomaticallyInstalls = setAutomaticallyInstalls
        _state = StateObject(wrappedValue: DoppelUpdatePromptState(
            automaticInstall: automaticallyInstalls))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .center, spacing: 18) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 72, height: 72)
                    .shadow(color: .black.opacity(0.22), radius: 8, y: 4)

                VStack(alignment: .leading, spacing: 6) {
                    Text(model.title)
                        .font(.system(size: 22, weight: .semibold))
                    Text(model.detail)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                Label(model.critical ? "Critical signed update" : "Signed update",
                      systemImage: "checkmark.shield.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(model.critical ? .orange : .secondary)
                Spacer()
                if allowsAutomaticUpdates && !model.informationOnly {
                    Toggle("Install future updates automatically", isOn: $state.automaticInstall)
                        .toggleStyle(.checkbox)
                        .onChange(of: state.automaticInstall) { _, enabled in
                            setAutomaticallyInstalls(enabled)
                        }
                }
            }

            HStack(spacing: 12) {
                if !model.informationOnly {
                    glassButton("Skip", prominent: false) { choose(.skip) }
                }
                Spacer(minLength: 12)
                glassButton("Later", prominent: false) { choose(.dismiss) }
                    .keyboardShortcut(.cancelAction)
                glassButton(model.primaryActionTitle, prominent: true) { choose(.install) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 38)
        .padding(.bottom, 26)
        .frame(width: 560)
        .background {
            WindowStyler()
            GlassBackground(cornerRadius: 0, clearStyle: false,
                            fallbackMaterial: .underWindowBackground)
                .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private func glassButton(
        _ title: String,
        prominent: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let button = Button(title, action: action)
            .controlSize(.large)
            .buttonBorderShape(.capsule)
        Group {
            if #available(macOS 26.0, *) {
                if prominent {
                    button.buttonStyle(.glassProminent)
                } else {
                    button.buttonStyle(.glass)
                }
            } else if prominent {
                button.buttonStyle(.borderedProminent)
            } else {
                button.buttonStyle(.bordered)
            }
        }
        .clipShape(Capsule(style: .continuous))
        .accessibilityLabel(title)
    }
}
