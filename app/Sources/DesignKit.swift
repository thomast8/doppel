import SwiftUI

/// The look the Codex Micro page set for the rest of the app: a dark slab that
/// pictures the thing being configured, with a legend of its state, above a
/// grouped form whose rows lead with small filled badges in the colour of what
/// they stand for.
enum Design {
    static let claude = Color(hex: "D97757")
    static let idle = Color.white.opacity(0.25)

    static let heroGradient = LinearGradient(colors: [Color(white: 0.11), Color(white: 0.05)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing)
}

struct HeroLegend: Hashable {
    let color: Color
    let label: String
    let value: String
}

/// The dark slab at the top of a page. The art on the left is a small drawing
/// of the thing itself; the legend beside it says what state it is in, in the
/// same colours the drawing uses.
struct HeroCard<Art: View, Accessory: View>: View {
    let title: String
    let subtitle: String
    let legend: [HeroLegend]
    let art: Art
    let accessory: Accessory

    init(title: String, subtitle: String, legend: [HeroLegend],
         @ViewBuilder art: () -> Art,
         @ViewBuilder accessory: () -> Accessory = { EmptyView() }) {
        self.title = title
        self.subtitle = subtitle
        self.legend = legend
        self.art = art()
        self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 22) {
            art
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer().frame(height: 6)
                ForEach(legend, id: \.self) { HeroLegendRow(item: $0) }
            }
            .layoutPriority(1)
            Spacer(minLength: 0)
            accessory
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Design.heroGradient)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .environment(\.colorScheme, .dark)
    }
}

struct HeroLegendRow: View {
    let item: HeroLegend

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(item.color).frame(width: 7, height: 7)
            Text(item.label).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
            Text(item.value).font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                .lineLimit(1)
        }
    }
}

/// A key on the pad, as the Codex Micro page draws it: a dark rounded square
/// whose rim glows in the colour of whatever it stands for.
struct HeroKey<Content: View>: View {
    let glow: Color
    var size: CGFloat = 30
    let content: Content

    init(glow: Color, size: CGFloat = 30, @ViewBuilder content: () -> Content = { EmptyView() }) {
        self.glow = glow
        self.size = size
        self.content = content()
    }

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
            .fill(Color(white: 0.17))
            .frame(width: size, height: size)
            .overlay(content.foregroundStyle(glow == Design.idle ? Color.white.opacity(0.35) : glow))
            .overlay(RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
                .strokeBorder(glow, lineWidth: 1.5))
            .shadow(color: glow.opacity(0.5), radius: 4)
    }
}

extension View {
    /// The plate the hero keys sit on.
    func heroPlate() -> some View {
        padding(14)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(white: 0.09)))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1))
    }
}

/// A filled square with a symbol or a number, like the channel numbers on the
/// Codex Micro page. Muted when the thing it stands for is off or unset.
struct StatusBadge: View {
    var symbol: String? = nil
    var text: String? = nil
    let color: Color
    var muted = false

    var body: some View {
        Group {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
            } else {
                Text(text ?? "").font(.system(size: 14, weight: .semibold, design: .monospaced))
            }
        }
        .frame(width: 26, height: 26)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(muted ? Color.secondary.opacity(0.12) : color))
        .foregroundStyle(muted ? Color.secondary : Color.white)
    }
}

/// A form row led by a badge: title, a caption under it, and its control on
/// the right.
struct BadgeRow<Trailing: View>: View {
    let badge: StatusBadge
    let title: String
    var detail: String? = nil
    var detailColor: Color = .secondary
    let trailing: Trailing

    init(badge: StatusBadge, title: String, detail: String? = nil, detailColor: Color = .secondary,
         @ViewBuilder trailing: () -> Trailing) {
        self.badge = badge
        self.title = title
        self.detail = detail
        self.detailColor = detailColor
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 10) {
            badge
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(detailColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
    }
}

extension View {
    /// A hero card goes in the header of a grouped form's first section, so it
    /// scrolls with the form and sits on its background rather than in a box.
    /// Headers are inset from the rows; this cancels that so the card lines up
    /// with the sections under it.
    func heroHeader() -> some View {
        padding(.horizontal, -10).padding(.top, 6)
    }
}

/// One of a few exclusive options drawn as a tile, the way the Codex Micro
/// page draws its channels: tinted and outlined in its colour when chosen.
struct ChoiceTile: View {
    let badge: StatusBadge
    let title: String
    let detail: String
    let color: Color
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                badge
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? color : Color.secondary.opacity(0.5))
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? color.opacity(0.10) : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(selected ? color.opacity(0.5) : Color.secondary.opacity(0.22), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
