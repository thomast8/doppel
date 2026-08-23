import Foundation

enum RemodexTargetState: String {
    case active
    case configured
    case unavailable
    case unsupported
}

struct RemodexStatus: Equatable {
    let state: RemodexTargetState
    let instanceID: String
    let instanceName: String
    let codexHome: String
    let bundleID: String
    let appPath: String
    let urlScheme: String

    func isActive(for instance: Instance) -> Bool {
        state == .active && instanceID == instance.id
    }

    static func parse(_ output: String) -> RemodexStatus? {
        guard let line = output.split(separator: "\n", omittingEmptySubsequences: true).first else {
            return nil
        }
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count == 7, let state = RemodexTargetState(rawValue: String(fields[0])) else {
            return nil
        }
        return RemodexStatus(
            state: state,
            instanceID: String(fields[1]),
            instanceName: String(fields[2]),
            codexHome: String(fields[3]),
            bundleID: String(fields[4]),
            appPath: String(fields[5]),
            urlScheme: String(fields[6]))
    }
}
