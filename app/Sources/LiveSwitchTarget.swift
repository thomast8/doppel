import Foundation

struct LiveSwitchTarget: Equatable {
    enum State: String {
        case missing
        case stopped
        case running
    }

    static let protocolVersion = "live-switch-target-v1"

    let instanceID: String
    let engine: InstanceEngine
    let bundleID: String
    let appPath: String
    let codexHome: String
    let state: State
    let processIdentifier: pid_t?
    let processFingerprint: String?
    let build: Int?

    static func parse(_ output: String) -> LiveSwitchTarget? {
        guard let line = output.split(separator: "\n", omittingEmptySubsequences: true).last else {
            return nil
        }
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count == 10,
              fields[0] == protocolVersion,
              !fields[1].isEmpty,
              let engine = InstanceEngine(rawValue: String(fields[2])),
              !fields[3].isEmpty,
              fields[4].hasPrefix("/"),
              fields[5].hasPrefix("/"),
              let state = State(rawValue: String(fields[6]))
        else { return nil }

        let pid = pid_t(fields[7])
        let fingerprint = fields[8].isEmpty ? nil : String(fields[8])
        let build = Int(fields[9])
        switch state {
        case .running:
            guard let pid, pid > 0,
                  let fingerprint,
                  fingerprint.count == 64,
                  fingerprint.allSatisfy({ $0.isHexDigit }),
                  let build, build > 0
            else { return nil }
            return LiveSwitchTarget(
                instanceID: String(fields[1]), engine: engine,
                bundleID: String(fields[3]), appPath: String(fields[4]),
                codexHome: String(fields[5]), state: state,
                processIdentifier: pid, processFingerprint: fingerprint, build: build)
        case .stopped:
            guard fields[7].isEmpty, fields[8].isEmpty, let build, build > 0 else { return nil }
            return LiveSwitchTarget(
                instanceID: String(fields[1]), engine: engine,
                bundleID: String(fields[3]), appPath: String(fields[4]),
                codexHome: String(fields[5]), state: state,
                processIdentifier: nil, processFingerprint: nil, build: build)
        case .missing:
            guard fields[7].isEmpty, fields[8].isEmpty, fields[9].isEmpty else { return nil }
            return LiveSwitchTarget(
                instanceID: String(fields[1]), engine: engine,
                bundleID: String(fields[3]), appPath: String(fields[4]),
                codexHome: String(fields[5]), state: state,
                processIdentifier: nil, processFingerprint: nil, build: nil)
        }
    }
}
