import SwiftUI
import Sparkle

@main
struct DoppelApp: App {
    @StateObject private var store = InstanceStore()
    private let updaterController: DoppelUpdater
    private let doppelUpdatesEnabled: Bool

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let foregroundUpdateQALaunch = arguments.contains("--check-for-doppel-updates")
        let backgroundUpdateQALaunch = arguments.contains("--download-doppel-update")
        let updateQALaunch = foregroundUpdateQALaunch || backgroundUpdateQALaunch
        let headlessCommand = arguments.contains("--login-item")
            || arguments.contains("--render-ui")
            || arguments.contains("--remote-access-qa")
            || arguments.contains("--create-instance-qa")
        doppelUpdatesEnabled = !(Bundle.main.object(
            forInfoDictionaryKey: "SUPublicEDKey") as? String ?? "").isEmpty
        updaterController = DoppelUpdater(
            startingUpdater: doppelUpdatesEnabled && !headlessCommand && !updateQALaunch)

        // Scriptable hook, also how the login-item path is tested without
        // driving the menu: Doppel --login-item {on|off|status}
        if let index = arguments.firstIndex(of: "--login-item") {
            let action = index + 1 < arguments.count ? arguments[index + 1] : "status"
            switch action {
            case "on", "off":
                if let failure = LoginItem.setEnabled(action == "on") {
                    FileHandle.standardError.write(Data("\(failure)\n".utf8))
                    exit(1)
                }
                print(LoginItem.isEnabled ? "on" : "off")
            default:
                print(LoginItem.isEnabled ? "on" : "off")
            }
            exit(0)
        }

        // Renders the window to a PNG without a screen or any capture
        // permission, so the UI can be reviewed as part of QA:
        //   Doppel --render-ui <path.png> [edit | panel | instance | settings | onboarding …]
        if let index = arguments.firstIndex(of: "--render-ui") {
            let path = index + 1 < arguments.count ? arguments[index + 1] : "/tmp/doppel-ui.png"
            if let screen = arguments.first(where: UIRenderer.screens.contains) {
                UIRenderer.render(screen: screen, to: URL(fileURLWithPath: path))
                exit(0)
            }
            let editing = arguments.contains("edit")
            UIRenderer.render(to: URL(fileURLWithPath: path), editing: editing)
            exit(0)
        }

        let configuredLockName = Bundle.main.object(
            forInfoDictionaryKey: "DoppelSingleInstanceLockName") as? String
        let lockName = configuredLockName
            ?? (updateQALaunch ? "menubar-update-qa.lock" : "menubar.lock")
        if !SingleInstance.acquire(lockName: lockName) {
            // Another menu-bar instance is already running; a second icon would
            // just confuse. Leave quietly.
            exit(0)
        }

        if let index = arguments.firstIndex(of: "--remote-access-qa"), index + 1 < arguments.count {
            let profileID = arguments[index + 1]
            UIRenderer.scheduleRemoteAccessQA(profileID: profileID)
        } else if arguments.contains("--create-instance-qa") {
            UIRenderer.scheduleCreateInstanceQA()
        }

        // Deterministic production-like QA hook. It drives the same Sparkle
        // controller as the menu item, after AppKit has entered its event loop.
        if updateQALaunch {
            guard doppelUpdatesEnabled else {
                FileHandle.standardError.write(Data(
                    "Doppel updates require SUPublicEDKey in the app bundle\n".utf8))
                exit(2)
            }
            DispatchQueue.main.async { [updaterController] in
                NSApp.activate(ignoringOtherApps: true)
                updaterController.start()
                if backgroundUpdateQALaunch {
                    updaterController.checkForUpdatesInBackground()
                } else {
                    updaterController.checkForUpdates()
                }
            }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(
                store: store,
                updaterController: updaterController,
                doppelUpdatesEnabled: doppelUpdatesEnabled)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)
        Window("New Doppel Instance", id: "create-instance") {
            CreateInstanceView(store: store)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)

        WindowGroup("Remote Access", id: "remote-access", for: String.self) { $profileID in
            if let profileID {
                RemoteAccessView(store: store, profileID: profileID)
            }
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)

        WindowGroup("Doppel Instance", id: "instance", for: String.self) { $slug in
            if let slug {
                InstanceDetailView(store: store, slug: slug)
            }
        }
        .windowResizability(.contentSize)

        Window("Doppel Settings", id: "settings") {
            SettingsView(store: store, updaterController: updaterController,
                         doppelUpdatesEnabled: doppelUpdatesEnabled)
        }
        .windowResizability(.contentSize)

        Window("Set Up Doppel", id: "onboarding") {
            OnboardingView(store: store)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)

        WindowGroup("Edit Doppel Instance", id: "edit-instance", for: String.self) { $slug in
            if let slug, let instance = store.instances.first(where: { $0.id == slug }) {
                CreateInstanceView(store: store, editing: instance)
            }
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
    }
}

/// The menu bar icon. It is also the earliest reliably-rendered view, which is
/// what --show-create hangs off: the window can be opened at launch without
/// driving the menu by hand.
struct MenuBarLabel: View {
    @ObservedObject var store: InstanceStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // MenuBarExtra reliably promotes a direct Image into the status item.
        // Wrapping a custom Shape in a Group produced an empty slot on macOS.
        Image(nsImage: store.permissionIssues.isEmpty
              ? DoppelMenuBarMark.image
              : DoppelMenuBarMark.warningImage)
            .renderingMode(.template)
            .accessibilityLabel(store.permissionIssues.isEmpty
                                ? "Doppel"
                                : "Doppel: managed app permissions need attention")
            .onAppear {
                guard ProcessInfo.processInfo.arguments.contains("--show-create") else { return }
                openWindow(id: "create-instance")
                NSApp.activate(ignoringOtherApps: true)
            }
            .onChange(of: store.listLoaded) { _, loaded in
                let defaults = UserDefaults.standard
                guard SetupProgress.shouldAutoOpen(
                    listLoaded: loaded, instanceCount: store.instances.count,
                    alreadyShown: defaults.bool(forKey: SetupProgress.shownDefaultsKey)) else { return }
                defaults.set(true, forKey: SetupProgress.shownDefaultsKey)
                openWindow(id: "onboarding")
                NSApp.activate(ignoringOtherApps: true)
            }
    }
}

/// Doppel's original mark at menu-bar scale: two asymmetric conversation
/// bubbles, offset on the same diagonal as the app artwork. Keeping the geometry
/// local means this identity has no dependency on another app's trademark.
private enum DoppelMenuBarMark {
    /// NSImage's drawing handler is resolution-independent, so this stays sharp
    /// on Retina displays while presenting MenuBarExtra with the direct image it
    /// expects. `isTemplate` lets macOS supply the correct light/dark tint.
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.setLineWidth(1.45)
            context.setStrokeColor(NSColor.black.cgColor)

            context.saveGState()
            context.setAlpha(0.46)
            context.addPath(bubblePath(in: CGRect(x: 0.5, y: 6.8,
                                                  width: 12.2, height: 9.4)))
            context.strokePath()
            context.restoreGState()

            context.addPath(bubblePath(in: CGRect(x: 5.3, y: 1.4,
                                                  width: 12.2, height: 9.4)))
            context.strokePath()
            return true
        }
        image.isTemplate = true
        return image
    }()

    static let warningImage: NSImage = {
        let image = NSImage(systemSymbolName: "exclamationmark.bubble.fill",
                            accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                       accessibilityDescription: nil)!
        image.isTemplate = true
        return image
    }()

    private static func bubblePath(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let tailHeight = rect.height * 0.20
        let bodyBottom = rect.minY + tailHeight
        let radius = min(rect.width * 0.16, (rect.height - tailHeight) * 0.30)
        let tailStart = rect.minX + rect.width * 0.22
        let tailTip = CGPoint(x: rect.minX + rect.width * 0.09, y: rect.minY)
        let tailEnd = rect.minX + rect.width * 0.41

        path.move(to: CGPoint(x: rect.minX + radius, y: bodyBottom))
        path.addLine(to: CGPoint(x: tailStart, y: bodyBottom))
        path.addQuadCurve(to: tailTip,
                          control: CGPoint(x: tailStart - rect.width * 0.035,
                                           y: bodyBottom - tailHeight * 0.48))
        path.addQuadCurve(to: CGPoint(x: tailEnd, y: bodyBottom),
                          control: CGPoint(x: tailTip.x + rect.width * 0.16,
                                           y: tailTip.y + tailHeight * 0.36))
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: bodyBottom))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: bodyBottom + radius),
                          control: CGPoint(x: rect.maxX, y: bodyBottom))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - radius, y: rect.maxY),
                          control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - radius),
                          control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: bodyBottom + radius))
        path.addQuadCurve(to: CGPoint(x: rect.minX + radius, y: bodyBottom),
                          control: CGPoint(x: rect.minX, y: bodyBottom))
        path.closeSubpath()
        return path
    }
}
