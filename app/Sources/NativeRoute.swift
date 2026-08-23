import Foundation

struct NativeRoute: Equatable, Hashable, CustomStringConvertible {
    let label: String

    init?(label: String) {
        let normalized = label
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.count <= 160 else { return nil }
        self.label = normalized
    }

    var description: String { label }
}
