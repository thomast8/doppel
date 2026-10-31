import SwiftUI
import AppKit

/// Guide state lives in an ObservableObject for the same reason as CreateForm:
/// the @State macro is unavailable under a Command Line Tools-only toolchain.
final class OnboardingModel: ObservableObject {
    @Published var step: OnboardingStep = .welcome
    @Published var appKind = InstanceApp.chatgpt
    @Published var started = false
    @Published var name = ""
    @Published var color = Color(hex: "3B82F6")
    @Published var customHue: Double = 0.6
    @Published var useOriginal = false
    @Published var creating = false
    @Published var errorMessage: String?
    /// The instance this run of the guide made, which the permission and done
    /// steps are about.
    @Published var createdName: String?
}

/// First-run setup: what Doppel is, the ChatGPT it builds from, secure
/// signing, a first instance and its permissions. Every step drives the same
/// store actions as the rest of the app, so finishing it leaves nothing the
/// panel would still ask for.
struct OnboardingView: View {
    @ObservedObject var store: InstanceStore
    var initialStep: OnboardingStep?
    /// The offscreen renderer has no window for glass to refract.
    var renderingDocumentation = false
    @StateObject private var model = OnboardingModel()
    @Environment(\.dismiss) private var dismiss

    /// The field shows a suggestion as its placeholder and the button names
    /// it, so leaving the field empty creates the suggestion.
    static func instanceName(typed: String, kind: InstanceApp) -> String {
        let trimmed = typed.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "\(kind.label) Work" : trimmed
    }

    private var nameToCreate: String { Self.instanceName(typed: model.name, kind: model.appKind) }
    private var shownName: String { model.createdName ?? nameToCreate }
    private var createdInstance: Instance? {
        model.createdName.flatMap { name in
            store.instances.first { $0.name == name && $0.appKind == model.appKind }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            progressDots.padding(.top, 14)
            Group {
                switch model.step {
                case .welcome: welcome
                case .findApp: findApps
                case .signing: signing
                case .create: create
                case .permissions: permissions
                case .done: done
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 44)
            .padding(.top, 22)
            footer
        }
        .frame(width: 640, height: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            // Someone who already has an instance has read the welcome; when
            // their setup is unfinished the guide resumes at the missing step.
            guard !model.started else { return }
            model.started = true
            if !store.primaryInstalled && store.claudeInstalled { model.appKind = .claude }
            if let initialStep {
                model.step = initialStep
            } else if !store.instances.isEmpty, !store.setupProgress.isComplete {
                model.step = store.setupProgress.resumeStep
            }
        }
    }

    // MARK: - Steps

    private var welcome: some View {
        VStack(spacing: 0) {
            stage {
                ZStack {
                    tile(Color(hex: "A855F7"), "P", size: 66).rotationEffect(.degrees(-8)).offset(x: -64, y: 8)
                    tile(Color(hex: "F28C28"), "O", size: 66).rotationEffect(.degrees(8)).offset(x: 64, y: 8)
                    tile(Color(hex: "3B82F6"), "W", size: 76)
                }
                .frame(height: 100)
                .padding(.vertical, 22)
            }
            .accessibilityHidden(true)
            Text("One app per account").font(.system(size: 24, weight: .semibold)).padding(.top, 22)
            Text("Doppel turns your installed ChatGPT or Claude into separate apps, each with its own login, chats, name and Dock icon.")
                .lead()
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            HStack(alignment: .top, spacing: 26) {
                feature("person.2.fill", .blue, "Separate accounts and data")
                feature("dock.rectangle", .purple, "Its own icon in the Dock and Cmd-Tab")
                feature("checkmark.seal.fill", .green, "Updated together and verified")
            }
            .padding(.top, 22)
        }
        .frame(maxWidth: .infinity)
    }

    private var findApps: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("Find your apps")
            Text("Instances are built from the copies already on this Mac. Nothing is downloaded from anywhere else. One of the two is enough.")
                .lead()
            card {
                VStack(spacing: 12) {
                    appRow(.chatgpt, version: store.installedVersions[.chatgpt].map(\.version))
                    Divider()
                    appRow(.claude, version: store.installedVersions[.claude].map(\.version))
                }
            }
            .padding(.top, 22)
            if !store.anyAppInstalled {
                Text("Install one into Applications, then check again.")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 10)
            }
        }
    }

    private func appRow(_ kind: InstanceApp, version: String?) -> some View {
        HStack(spacing: 12) {
            HeroKey(glow: store.isInstalled(kind) ? .green : Design.idle, size: 48) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: kind.path))
                    .resizable()
                    .frame(width: 34, height: 34)
                    .opacity(store.isInstalled(kind) ? 1 : 0.4)
            }
            .padding(.trailing, 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(version.map { "\(kind.label) \($0)" } ?? kind.label)
                    .font(.system(size: 14, weight: .semibold))
                Text(kind.path).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
            }
            Spacer()
            if store.isInstalled(kind) {
                Text("Found").foregroundStyle(.green).font(.system(size: 13, weight: .medium))
            } else {
                Button("Get \(kind.label)") { NSWorkspace.shared.open(kind.downloadURL) }
                Button("Check Again") { store.reload() }
            }
        }
    }

    private var signing: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("Set up secure signing")
            Text("Each instance is a real app, so macOS needs it signed. Doppel makes a signing key that never leaves this Mac and keeps it in your login keychain. Without it, macOS can forget an instance's permissions after every update.")
                .lead()
            card {
                HStack(spacing: 12) {
                    HeroKey(glow: store.signingReady ? .green : .orange, size: 44) {
                        Image(systemName: "key.fill").font(.system(size: 17, weight: .medium))
                    }
                    .padding(.trailing, 4)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Local signing key").font(.system(size: 14))
                        Text(store.signingReady ? "Created and stored in your login keychain." : "Not set up yet.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if store.signingReady {
                        Text("Ready").foregroundStyle(.green).font(.system(size: 13, weight: .medium))
                    } else if store.busy.contains("signing") {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Set Up") { store.setUpSigning() }
                            .buttonStyle(.borderedProminent)
                            .disabled(store.engineOperationBusy)
                    }
                }
            }
            .padding(.top, 22)
            Text(store.instances.isEmpty
                 ? "macOS asks for your password once."
                 : "macOS asks for your password once. Existing instances are rebuilt to adopt the key.")
                .font(.caption).foregroundStyle(.secondary).padding(.top, 12)
        }
    }

    private var create: some View {
        HStack(alignment: .top, spacing: 26) {
            VStack(alignment: .leading, spacing: 0) {
                title(store.instances.isEmpty ? "Create your first instance" : "Create an instance")
                Text("Give it a name you will recognise in the Dock. You can change both later.").lead()
                if store.primaryInstalled && store.claudeInstalled {
                    Picker("App", selection: $model.appKind) {
                        ForEach(InstanceApp.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 220)
                    .padding(.top, 18)
                    .disabled(model.creating)
                }
                Text("Name").fieldLabel().padding(.top, 20)
                TextField("", text: $model.name, prompt: Text("\(model.appKind.label) Work"))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .onSubmit { if canCreate { createInstance() } }
                    .accessibilityLabel("Name")
                Text("Icon colour").fieldLabel().padding(.top, 16)
                TintPicker(color: $model.color, customHue: $model.customHue, useOriginal: $model.useOriginal)
                if let error = model.errorMessage {
                    Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 12)
                }
            }
            stage {
                VStack(spacing: 12) {
                    IconTile(color: model.useOriginal ? Color(white: 0.97) : model.color,
                             name: shownName, radius: 22,
                             renderingDocumentation: renderingDocumentation, size: 96)
                        .shadow(color: (model.useOriginal ? Color.white : model.color).opacity(0.6), radius: 16)
                    Text(shownName).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                    Text(model.appKind.label).font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .padding(.vertical, 24)
            }
            .frame(width: 170)
            .padding(.top, 50)
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("Permissions for \(shownName)")
            Text("Each instance asks macOS on its own. Allow what you use now; the rest can wait until a feature needs it.")
                .lead()
            if let instance = createdInstance {
                Form {
                    Section { PermissionRows(store: store, instanceID: instance.id) }
                }
                .formStyle(.grouped)
                .scrollDisabled(true)
                .padding(.horizontal, -20)
            } else {
                ProgressView("Waiting for \(shownName)…").padding(.top, 24)
            }
        }
    }

    private var done: some View {
        VStack(spacing: 0) {
            if let instance = createdInstance ?? store.instances.first {
                stage {
                    IconTile(color: instance.tileColor, name: instance.name, radius: 22,
                             renderingDocumentation: true, size: 96)
                        .shadow(color: instance.tileColor.opacity(0.7), radius: 18)
                        .padding(.vertical, 26)
                }
                .padding(.top, 8)
                Text("\(instance.name) is ready").font(.system(size: 24, weight: .semibold)).padding(.top, 20)
            } else {
                Text("Doppel is set up").font(.system(size: 24, weight: .semibold)).padding(.top, 60)
            }
            Text("Sign in with the account you want it to use. Doppel stays in the menu bar to add instances, fix permissions and handle updates.")
                .lead()
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Label("Look for the fanned tiles in the menu bar.", systemImage: "menubar.arrow.up.rectangle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 18)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Footer

    private var canCreate: Bool {
        !model.creating && !store.engineOperationBusy && store.isInstalled(model.appKind)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if model.step != .welcome && model.step != .done && model.step != .permissions {
                Button("Back") { move(-1) }
                    .buttonStyle(.link)
                    .disabled(model.creating)
            }
            Spacer()
            switch model.step {
            case .welcome:
                primary("Get Started") { move(1) }
            case .findApp:
                primary("Continue") { move(1) }.disabled(!store.anyAppInstalled)
            case .signing:
                if !store.signingReady {
                    Button("Skip for Now") { move(1) }.buttonStyle(.link)
                        .disabled(store.busy.contains("signing"))
                }
                primary("Continue") { move(1) }.disabled(!store.signingReady)
            case .create:
                if !store.instances.isEmpty {
                    Button("Skip") { model.step = .done }.buttonStyle(.link)
                }
                primary(model.creating ? "Creating…" : "Create \(shownName)") { createInstance() }
                    .disabled(!canCreate)
            case .permissions:
                Button("Skip for Now") { move(1) }.buttonStyle(.link)
                primary("Continue") { move(1) }
            case .done:
                Button("Create Another") {
                    model.name = ""
                    model.createdName = nil
                    model.step = .create
                }
                .buttonStyle(.bordered)
                if let instance = createdInstance ?? store.instances.first {
                    primary("Open \(instance.name)") {
                        store.launch(instance)
                        dismiss()
                    }
                } else {
                    primary("Done") { dismiss() }
                }
            }
        }
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .padding(.horizontal, 44)
        .padding(.bottom, 24)
        .padding(.top, 12)
    }

    private func move(_ delta: Int) {
        guard let next = OnboardingStep(rawValue: model.step.rawValue + delta) else { return }
        model.step = next
    }

    private func createInstance() {
        guard canCreate else { return }
        model.creating = true
        model.errorMessage = nil
        let name = nameToCreate
        store.create(name: name, tintHex: model.useOriginal ? "original" : model.color.rgbHex,
                     appKind: model.appKind) { [model] failure in
            model.creating = false
            if let failure {
                model.errorMessage = failure
            } else {
                model.createdName = name
                model.step = .permissions
            }
        }
    }

    // MARK: - Pieces

    private var progressDots: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingStep.allCases, id: \.rawValue) { step in
                Capsule()
                    .fill(step.rawValue <= model.step.rawValue ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: step == model.step ? 18 : 6, height: 6)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Step \(model.step.rawValue + 1) of \(OnboardingStep.allCases.count)")
    }

    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
    }

    private func title(_ text: String) -> some View {
        Text(text).font(.system(size: 24, weight: .semibold))
    }

    /// The dark slab of the Codex Micro page, holding what a step is about.
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(16)
            .background(Design.heroGradient)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .environment(\.colorScheme, .dark)
    }

    /// The same slab for a step's picture, centred and full width.
    private func stage<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity)
            .background(Design.heroGradient)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .environment(\.colorScheme, .dark)
    }

    private func tile(_ color: Color, _ letter: String, size: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(color.gradient)
            .frame(width: size, height: size)
            .overlay(Text(letter).font(.system(size: size * 0.36, weight: .semibold, design: .rounded))
                .foregroundStyle(.white))
            .shadow(color: color.opacity(0.55), radius: 12)
    }

    private func feature(_ symbol: String, _ color: Color, _ text: String) -> some View {
        VStack(spacing: 8) {
            StatusBadge(symbol: symbol, color: color)
            Text(text).font(.system(size: 12.5)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(width: 140)
    }
}

private extension Text {
    func lead() -> some View {
        self.font(.system(size: 14))
            .foregroundStyle(.secondary)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 6)
    }

    func fieldLabel() -> some View {
        self.font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.bottom, 6)
    }
}
