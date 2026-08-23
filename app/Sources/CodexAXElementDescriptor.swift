import Foundation

struct CodexAXElementDescriptor: Equatable {
    let id: Int
    let role: String
    let subrole: String
    let title: String
    let description: String
    let help: String
    let identifier: String
    let placeholder: String
    let value: String
    let childLabels: [String]
    let enabled: Bool

    var labels: [String] {
        [title, description, help, identifier, placeholder, value] + childLabels
    }

    var semanticText: String {
        labels.filter { !$0.isEmpty }.joined(separator: " ").lowercased()
    }
}
