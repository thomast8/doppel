import SwiftUI

/// Who holds each Bluetooth channel of the pad, from
/// `doppel micro channel --porcelain`. Instances are keyed by their ChatGPT
/// slug, which is also their id in the store.
struct MicroChannels: Equatable {
    enum ClaudeCode: Equatable {
        case off, everyChannel, channel(Int)
    }

    enum Holder: Equatable {
        case free, claude, instance(String)
    }

    var instances: [String: Int] = [:]
    var claude: ClaudeCode = .off

    func holder(of channel: Int) -> Holder {
        if claude == .channel(channel) { return .claude }
        if let slug = instances.first(where: { $0.value == channel })?.key { return .instance(slug) }
        return .free
    }

    static func parse(_ output: String) -> MicroChannels {
        var state = MicroChannels()
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            switch (fields.first, fields.count) {
            case ("instance", 3):
                if let channel = Int(fields[2]), (1...9).contains(channel), !fields[1].isEmpty {
                    state.instances[fields[1]] = channel
                }
            case ("claude", 2):
                if fields[1] == "any" {
                    state.claude = .everyChannel
                } else if let channel = Int(fields[1]), (1...9).contains(channel) {
                    state.claude = .channel(channel)
                }
            default:
                continue
            }
        }
        return state
    }
}

/// The CLI's answer to `micro claude <channel> --plan`, held until the user
/// confirms it on the page.
struct ClaudeMicroPlan: Equatable {
    let channel: String
    let output: String

    var nothingToChange: Bool { output.contains("nothing to change") }

    /// The "- step" lines, without the heading the terminal prints.
    var steps: [String] {
        output.split(separator: "\n").compactMap { line in
            line.hasPrefix("- ") ? String(line.dropFirst(2)) : nil
        }
    }

    var notes: [String] {
        output.split(separator: "\n").map(String.init).filter { $0.hasPrefix("Note:") }
    }
}

/// The Codex Micro page in Settings: the pad drawn the way Codex shows it,
/// which instance answers by default, the nine Bluetooth channels and Claude
/// Code's place among them.
/// Which channel's chooser is open. An ObservableObject rather than @State,
/// which the Command Line Tools toolchain lacks.
final class CodexMicroModel: ObservableObject {
    @Published var openChannel: Int?
}

struct CodexMicroView: View {
    @ObservedObject var store: InstanceStore
    @StateObject private var model = CodexMicroModel()

    private static let claudeColor = Color(hex: "D97757")
    private var chatGPTInstances: [Instance] { store.instances.filter { $0.appKind == .chatgpt } }
    private var busy: Bool { store.engineOperationBusy || store.checkingCreatorMicro }

    var body: some View {
        VStack(spacing: 0) {
            hero.padding(.horizontal, 20).padding(.top, 16)
            form
        }
    }

    private var form: some View {
        Form {
            Section {
                defaultOwner
            } header: {
                Text("Default")
            } footer: {
                Text("The default instance listens on every channel nobody else holds. Running instances restart when this changes, and official ChatGPT also uses the pad while it runs.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                channelGrid
            } header: {
                Text("Bluetooth channels")
            } footer: {
                Text("Each channel is its own device, so apps on different channels can all stay open. Press the pad's channel button to switch. An instance reads its channel when it starts.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section("Claude Code") { claudeCode }
        }
        .formStyle(.grouped)
        .disabled(!store.creatorMicroStatusAvailable && !store.checkingCreatorMicro)
    }

    // MARK: - Hero

    /// A dark slab like the Codex app's own picture of the pad: six agent keys,
    /// the dial and joystick, and along the top a light for each channel in the
    /// colour of whoever holds it.
    private var hero: some View {
        HStack(spacing: 22) {
            pad
            VStack(alignment: .leading, spacing: 6) {
                Text("Codex Micro")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Also the Work Louder Creator Micro 2")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer().frame(height: 6)
                legendRow(color: ownerColor, label: "Default", value: ownerName)
                legendRow(color: Self.claudeColor, label: "Claude Code", value: claudeSummary)
                legendRow(color: .white.opacity(0.25), label: "Free channels",
                          value: "\((1...9).filter { channels.holder(of: $0) == .free }.count) of 9")
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .background(
            LinearGradient(colors: [Color(white: 0.11), Color(white: 0.05)],
                           startPoint: .topLeading, endPoint: .bottomTrailing))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .environment(\.colorScheme, .dark)
    }

    private var pad: some View {
        VStack(spacing: 10) {
            HStack(spacing: 5) {
                ForEach(1...9, id: \.self) { channel in
                    Circle()
                        .fill(color(for: channels.holder(of: channel)))
                        .frame(width: 5, height: 5)
                        .shadow(color: color(for: channels.holder(of: channel)).opacity(0.8), radius: 2)
                }
            }
            HStack(alignment: .top, spacing: 12) {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 6), count: 3), spacing: 6) {
                    ForEach(0..<6, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color(white: 0.17))
                            .frame(width: 30, height: 30)
                            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(keyGlow(index), lineWidth: 1.5))
                            .shadow(color: keyGlow(index).opacity(0.5), radius: 4)
                    }
                }
                VStack(spacing: 8) {
                    Circle()
                        .fill(AngularGradient(colors: [Color(white: 0.30), Color(white: 0.14), Color(white: 0.30)],
                                              center: .center))
                        .frame(width: 34, height: 34)
                        .overlay(Capsule().fill(.white.opacity(0.7)).frame(width: 2, height: 9).offset(y: -10))
                    Circle()
                        .fill(Color(white: 0.2))
                        .frame(width: 22, height: 22)
                        .overlay(Circle().fill(Color(white: 0.32)).frame(width: 10, height: 10))
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(white: 0.09)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(.white.opacity(0.08), lineWidth: 1))
        .accessibilityElement()
        .accessibilityLabel("Codex Micro pad")
    }

    /// The agent keys show what holds the pad's channels, in channel order,
    /// so the picture changes as the assignments do.
    private func keyGlow(_ index: Int) -> Color {
        let held = (1...9).map { channels.holder(of: $0) }.filter { $0 != .free }
        guard index < held.count else { return .white.opacity(index == 0 && ownerName != "Nobody" ? 0.55 : 0.12) }
        return color(for: held[index])
    }

    private func legendRow(color: Color, label: String, value: String) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
            Text(value).font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
        }
    }

    // MARK: - Sections

    private var defaultOwner: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Answers the pad")
                Text("doppel micro assign").font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if store.checkingCreatorMicro {
                ProgressView().controlSize(.small)
            } else if !store.creatorMicroStatusAvailable {
                Text("Unavailable").foregroundStyle(.secondary)
            } else {
                Menu(ownerName) {
                    ForEach(chatGPTInstances) { instance in
                        Button(instance.name) { store.assignCreatorMicro(to: instance) }
                            .disabled(store.creatorMicroOwnerID == instance.id)
                    }
                    Divider()
                    Button("Nobody") { store.releaseCreatorMicro() }
                        .disabled(store.creatorMicroOwnerID == nil)
                }
                .fixedSize()
                .disabled(busy)
            }
        }
    }

    private var channelGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach(1...9, id: \.self) { channel in channelTile(channel) }
        }
        .padding(.vertical, 4)
    }

    private func channelTile(_ channel: Int) -> some View {
        let holder = channels.holder(of: channel)
        return Button {
            model.openChannel = channel
        } label: {
            HStack(spacing: 10) {
                Text("\(channel)")
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(holder == .free ? Color.secondary.opacity(0.12) : color(for: holder)))
                    .foregroundStyle(holder == .free ? Color.secondary : Color.white)
                Text(name(for: holder))
                    .font(.system(size: 12))
                    .foregroundStyle(holder == .free ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(8)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(holder == .free ? Color.clear : color(for: holder).opacity(0.10)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(holder == .free ? Color.secondary.opacity(0.22) : color(for: holder).opacity(0.5),
                              lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .accessibilityLabel("Channel \(channel), \(name(for: holder))")
        .popover(isPresented: Binding(get: { model.openChannel == channel },
                                      set: { if !$0 { model.openChannel = nil } }),
                 arrowEdge: .bottom) {
            channelChooser(channel, holder: holder)
        }
    }

    private func channelChooser(_ channel: Int, holder: MicroChannels.Holder) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Channel \(channel)").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 8).padding(.bottom, 4)
            ForEach(chatGPTInstances) { instance in
                chooserRow(instance.name, color: instance.tileColor,
                           selected: holder == .instance(instance.id)) {
                    store.setMicroChannel(channel, for: instance)
                }
            }
            chooserRow("Claude Code", color: Self.claudeColor, selected: holder == .claude) {
                store.planClaudeMicro(channel: String(channel))
            }
            Divider().padding(.vertical, 4)
            switch holder {
            case .instance(let slug):
                if let instance = store.instances.first(where: { $0.id == slug }) {
                    chooserRow("Free this channel", color: nil, selected: false) {
                        store.setMicroChannel(nil, for: instance)
                    }
                }
            case .claude:
                chooserRow("Let Claude Code use every channel", color: nil, selected: false) {
                    store.planClaudeMicro(channel: "any")
                }
            case .free:
                Text("Free. The default instance answers here.")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8)
            }
        }
        .padding(10)
        .frame(width: 250)
    }

    private func chooserRow(_ title: String, color: Color?, selected: Bool,
                            action: @escaping () -> Void) -> some View {
        Button {
            model.openChannel = nil
            action()
        } label: {
            HStack(spacing: 8) {
                Circle().fill(color ?? .clear).frame(width: 8, height: 8)
                Text(title)
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(selected)
    }

    @ViewBuilder
    private var claudeCode: some View {
        if let plan = store.claudeMicroPlan {
            VStack(alignment: .leading, spacing: 8) {
                if plan.nothingToChange {
                    Text("Claude Code is already set up that way.")
                } else {
                    Text(plan.channel == "any"
                         ? "Set up Claude Code on every channel"
                         : "Set up Claude Code on channel \(plan.channel)")
                        .font(.system(size: 13, weight: .semibold))
                    ForEach(plan.steps, id: \.self) { step in
                        Label(step, systemImage: "arrow.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                ForEach(plan.notes, id: \.self) { note in
                    Text(note).font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Spacer()
                    Button(plan.nothingToChange ? "OK" : "Cancel") { store.claudeMicroPlan = nil }
                    if !plan.nothingToChange {
                        Button("Set Up") { store.applyClaudeMicroPlan() }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
        } else {
            HStack {
                Circle().fill(channels.claude == .off ? Color.secondary.opacity(0.4) : Self.claudeColor)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(claudeSummary)
                    Text("Each Claude Code session gets one of the pad's agent keys.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Menu(channels.claude == .off ? "Set Up…" : "Change…") {
                    ForEach((1...9).filter { channels.holder(of: $0) != .claude }, id: \.self) { channel in
                        Button("Channel \(channel)") { store.planClaudeMicro(channel: String(channel)) }
                            .disabled(channels.holder(of: channel) != .free)
                    }
                    Divider()
                    Button("Every Channel") { store.planClaudeMicro(channel: "any") }
                }
                .fixedSize()
                .disabled(busy)
            }
        }
    }

    // MARK: - Names and colours

    private var channels: MicroChannels { store.microChannels }

    private var owner: Instance? { store.instances.first { $0.id == store.creatorMicroOwnerID } }
    private var ownerName: String { owner?.name ?? "Nobody" }
    private var ownerColor: Color { owner?.tileColor ?? .white.opacity(0.25) }

    private var claudeSummary: String {
        switch channels.claude {
        case .off: return "Not set up"
        case .everyChannel: return "Every channel"
        case .channel(let channel): return "Channel \(channel)"
        }
    }

    private func name(for holder: MicroChannels.Holder) -> String {
        switch holder {
        case .free: return "Free"
        case .claude: return "Claude Code"
        case .instance(let slug): return store.instances.first { $0.id == slug }?.name ?? slug
        }
    }

    private func color(for holder: MicroChannels.Holder) -> Color {
        switch holder {
        case .free: return .white.opacity(0.18)
        case .claude: return Self.claudeColor
        case .instance(let slug): return store.instances.first { $0.id == slug }?.tileColor ?? .gray
        }
    }
}
