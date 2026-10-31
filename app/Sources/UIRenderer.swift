import SwiftUI
import AppKit

/// Renders the create/edit window to an image.
///
/// Reviewing the interface otherwise needs a screen capture, which macOS gates
/// behind a permission that a headless or scripted run will not have. Drawing
/// the real view hierarchy offscreen sidesteps that entirely. AppKit-backed
/// glass and controls use matching SwiftUI stand-ins because they cannot
/// render into ImageRenderer without a window.
@MainActor
enum UIRenderer {
    private static var remoteQAWindow: NSWindow?
    private static var remoteQALaunchObserver: NSObjectProtocol?

    static func scheduleRemoteAccessQA(profileID: String) {
        scheduleQA { showRemoteAccessQA(profileID: profileID) }
    }

    static func scheduleCreateInstanceQA() {
        scheduleQA {
            NSApp.setActivationPolicy(.regular)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 520),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "New Doppel Instance QA"
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: CreateInstanceView(store: InstanceStore()))
            remoteQAWindow = window
            window.center(); window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private static func scheduleQA(_ show: @escaping @MainActor () -> Void) {
        remoteQALaunchObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                if let observer = remoteQALaunchObserver { NotificationCenter.default.removeObserver(observer) }
                remoteQALaunchObserver = nil
                show()
            }
        }
    }

    /// Opens the real setup view for native QA when a menu-only app cannot
    /// be selected by the accessibility bridge. Does not configure or enable it.
    static func showRemoteAccessQA(profileID: String) {
        let store = InstanceStore()
        guard profileID.range(of: "^[a-z0-9]+(?:-[a-z0-9]+)*$", options: .regularExpression) != nil else { return }
        NSApp.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 568, height: 650),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Remote Access QA"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: RemoteAccessView(store: store, profileID: profileID))
        remoteQAWindow = window
        window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static let screens = ["panel", "panel-attention", "panel-progress", "panel-setup", "instance", "settings",
                          "settings-updates", "settings-integrations", "settings-micro", "onboarding", "onboarding-create"]

    /// The newer screens are drawn from a fixed sample store rather than the
    /// Mac's real instances, so a render shows every state on any machine and
    /// never someone's account names. They use real AppKit controls, which
    /// ImageRenderer cannot draw, so they render through an offscreen window's
    /// view cache instead; that still needs no screen-capture permission.
    static func render(screen: String, to url: URL) {
        let store = sampleStore(attention: screen == "panel-attention", setup: screen == "panel-setup")
        if screen == "panel-progress" {
            store.busy = ["update"]
            store.progressNote = "Installing ChatGPT 26.821.10230 and rebuilding every instance…"
            store.progress = CLIProgress(fraction: 0.59, label: "Rebuilt 2 of 3 instances")
            store.lastError = "ChatGPT Work could not reopen. Launch it again from Doppel."
        } else if screen == "settings-updates" {
            addSampleUpdates(to: store)
        } else if screen == "panel" {
            store.upToDateApps = [.chatgpt, .claude]
        }
        let updater = DoppelUpdater(startingUpdater: false)
        let view: AnyView
        switch screen {
        case "panel", "panel-attention", "panel-progress", "panel-setup":
            view = AnyView(MenuContent(store: store, updaterController: updater, doppelUpdatesEnabled: true)
                .background(Color(nsColor: .windowBackgroundColor)))
        case "instance":
            view = AnyView(InstanceDetailView(store: store, slug: "personal"))
        case "settings", "settings-updates", "settings-integrations", "settings-micro":
            view = AnyView(SettingsView(store: store, updaterController: updater, doppelUpdatesEnabled: true,
                                        initialTab: ["settings", "settings-updates", "settings-integrations", "settings-micro"]
                                            .firstIndex(of: screen) ?? 0))
        case "onboarding":
            view = AnyView(OnboardingView(store: store, initialStep: .welcome, renderingDocumentation: true))
        case "onboarding-create":
            view = AnyView(OnboardingView(store: store, initialStep: .create, renderingDocumentation: true))
        default:
            fail("unknown screen \(screen); expected one of \(screens.joined(separator: ", "))")
        }

        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        // Lets SwiftUI finish its first update pass before the view is cached.
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            fail("render produced no image")
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        write(bitmap, to: url)
    }

    private static func sampleStore(attention: Bool, setup: Bool) -> InstanceStore {
        let store = InstanceStore(testingWithoutStartup: true)
        store.listLoaded = true
        store.primaryInstalled = true
        store.signingReady = !setup
        store.installedVersions = [
            .chatgpt: InstalledVendor(build: "6662", version: "26.810.52044"),
            .claude: InstalledVendor(app: .claude, build: "1.4212.0", version: "1.4212.0"),
        ]
        if setup { return store }
        store.instances = [
            Instance(id: "personal", name: "ChatGPT Personal", appPath: "/Applications/ChatGPT Personal.app",
                     installed: true, tint: "F28C28", engine: .clone),
            Instance(id: "claude/research", name: "Claude Research", appPath: "/Applications/Claude Research.app",
                     installed: true, tint: "14B8A6", engine: .clone, appKind: .claude),
            Instance(id: "veridue", name: "ChatGPT Veridue", appPath: "/Applications/ChatGPT Veridue.app",
                     installed: true, tint: "A855F7", engine: .vendor),
            Instance(id: "work", name: "ChatGPT Work", appPath: "/Applications/ChatGPT Work.app",
                     installed: true, tint: "3B82F6", engine: .clone),
        ]
        store.runningAppPaths = ["/Applications/ChatGPT Personal.app", "/Applications/Claude Research.app"]
        store.claudeInstalled = true
        var tools = NativeToolsStatus()
        tools.computerUse = .ready
        tools.chronicle = .running
        tools.chronicleHost = "ChatGPT Work"
        tools.chronicleFrameAge = 4
        tools.inAppBrowserInstanceID = "veridue"
        tools.inAppBrowserInstanceName = "ChatGPT Veridue"
        tools.inAppBrowserRunning = true
        tools.inAppBrowserVendorValid = true
        tools.browserHosts = [NativeToolsStatus.BrowserHost(browser: "Chrome", owner: "ChatGPT Work")]
        tools.instancesWithBrowserHost = ["ChatGPT Work", "ChatGPT Personal"]
        store.nativeToolsStatus = tools
        store.creatorMicroStatusAvailable = true
        store.creatorMicroOwnerID = "work"
        store.microChannels = MicroChannels(instances: ["work": 1, "personal": 3], claude: .channel(2))
        let statuses: [(String, String)] = [
            ("microphone", attention ? "denied" : "granted"), ("screen-recording", "granted"),
            ("notifications", "granted"), ("camera", "not-requested"), ("accessibility", "unconfirmed"),
        ]
        store.permissionStatuses = ["personal", "veridue", "work"].flatMap { id in
            statuses.map { permission, status in
                PermissionIssue(instanceID: id, instanceName: id, permission: permission,
                                status: id == "personal" ? status : (permission == "camera" ? status : "granted"))
            }
        }
        if attention {
            store.busy = ["work"]
            store.instanceProgress["work"] = CLIProgress(fraction: 0.6, label: "Signing")
            addSampleUpdates(to: store)
        }
        return store
    }

    /// A ChatGPT download waiting and a Claude instance left behind, so both
    /// kinds of offer are drawn.
    private static func addSampleUpdates(to store: InstanceStore) {
        store.updates[.chatgpt] = VendorUpdate(state: .ready, currentBuild: "6662", currentVersion: "26.810.52044",
                                               targetBuild: "6700", targetVersion: "26.821.10230",
                                               staleInstanceCount: 0)
        store.updates[.claude] = VendorUpdate(app: .claude, state: .staleInstances, currentBuild: "1.4212.0",
                                              currentVersion: "1.4212.0", targetBuild: "1.4212.0",
                                              targetVersion: "1.4212.0", staleInstanceCount: 1)
    }

    private static func write(_ bitmap: NSBitmapImageRep, to url: URL) {
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            fail("could not encode the image")
        }
        do {
            try data.write(to: url)
            print(url.path)
        } catch {
            fail(error.localizedDescription)
        }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
        exit(1)
    }

    static func render(to url: URL, editing: Bool) {
        let store = InstanceStore()
        // Give the store a moment to populate from the CLI so the rendered
        // window shows real instances rather than an empty state.
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))

        let sample = store.instances.first
            ?? Instance(id: "sample", name: "ChatGPT Personal",
                        appPath: "", installed: true, tint: "A855F7", engine: .clone)

        let view = CreateInstanceView(store: store, editing: editing ? sample : nil,
                                      renderingDocumentation: true)
            .frame(width: 440)
            .background(Color(nsColor: .windowBackgroundColor))

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage else {
            FileHandle.standardError.write(Data("render produced no image\n".utf8))
            exit(1)
        }
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("could not encode the image\n".utf8))
            exit(1)
        }
        do {
            try data.write(to: url)
            print(url.path)
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
