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

/// The app icon's mark at menu-bar scale: three instance tiles fanned out,
/// the front one carrying a speech bubble. It is one colour so macOS can tint
/// it for the menu bar, and the side tiles are half strength so the fan still
/// reads at 18 pt. When something needs attention the same mark gains a dot
/// rather than turning into a different symbol.
private enum DoppelMenuBarMark {
    static let image = mark(warning: false)
    static let warningImage = mark(warning: true)

    /// NSImage's drawing handler is resolution-independent, so this stays sharp
    /// on Retina displays while presenting MenuBarExtra with the direct image it
    /// expects. `isTemplate` lets macOS supply the correct light/dark tint.
    private static func mark(warning: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 22, height: 18), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let front = tile(center: CGPoint(x: 11, y: 9), size: 9.8, degrees: 0)
            context.setFillColor(NSColor.black.cgColor)

            context.saveGState()
            context.setAlpha(0.5)
            context.addPath(tile(center: CGPoint(x: 5.6, y: 8.2), size: 7.8, degrees: 14))
            context.addPath(tile(center: CGPoint(x: 16.4, y: 8.2), size: 7.8, degrees: -14))
            context.fillPath()
            context.restoreGState()

            // A gap around the front tile so it reads as lying on top.
            context.setBlendMode(.clear)
            context.addPath(front)
            context.setLineWidth(2.2)
            context.strokePath()
            context.setBlendMode(.normal)
            context.addPath(front)
            context.fillPath()

            // The bubble is cut out of the front tile.
            context.setBlendMode(.clear)
            context.addPath(bubblePath(in: CGRect(x: 8.4, y: 6.6, width: 5.2, height: 4.8)))
            context.fillPath()

            if warning {
                let dot = CGRect(x: 15.2, y: 13.2, width: 4.2, height: 4.2)
                context.addEllipse(in: dot.insetBy(dx: -1.2, dy: -1.2))
                context.fillPath()
                context.setBlendMode(.normal)
                context.addEllipse(in: dot)
                context.fillPath()
            }
            context.setBlendMode(.normal)
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func tile(center: CGPoint, size: CGFloat, degrees: CGFloat) -> CGPath {
        var transform = CGAffineTransform(translationX: center.x, y: center.y)
            .rotated(by: degrees * .pi / 180)
        let rect = CGRect(x: -size / 2, y: -size / 2, width: size, height: size)
        return CGPath(roundedRect: rect, cornerWidth: size * 0.26, cornerHeight: size * 0.26,
                      transform: &transform)
    }

    /// A rounded bubble with a short tail at the lower left, simple enough to
    /// survive at a few points across.
    private static func bubblePath(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let tail = rect.height * 0.24
        let bottom = rect.minY + tail
        let radius = rect.height * 0.28
        path.addRoundedRect(in: CGRect(x: rect.minX, y: bottom, width: rect.width, height: rect.height - tail),
                            cornerWidth: radius, cornerHeight: radius)
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.22, y: bottom + 0.2))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.12, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.48, y: bottom + 0.2))
        path.closeSubpath()
        return path
    }
}
