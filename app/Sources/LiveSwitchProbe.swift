import Foundation

@MainActor
enum LiveSwitchProbe {
    static func run(instanceID: String) -> (output: String, status: Int32) {
        guard let cli = discoverCLI() else {
            return ("target-invalid\tDoppel CLI not found", 2)
        }
        switch InstanceStore.runProcess(
            cli: cli, arguments: ["live-switch", "target", instanceID]
        ) {
        case .failure:
            return ("target-invalid\tresolution-failed", 2)
        case .success(let output):
            guard let target = LiveSwitchTarget.parse(output), target.instanceID == instanceID else {
                return ("target-invalid\tunreadable target contract", 2)
            }
            guard target.state == .running else {
                return ("\(target.state.rawValue)\tbuild=\(target.build ?? 0)", 3)
            }
            switch CodexAXAdapter().inspect(target) {
            case .unavailable(let failure):
                return ("unsupported\t\(failure.rawValue)\tbuild=\(target.build ?? 0)", 4)
            case .snapshot(let snapshot):
                let safety = snapshot.safetyFailure?.rawValue ?? "safe"
                return (
                    "supported\troute=\(singleLine(snapshot.route.label))\tturn=\(snapshot.turnIsActive ? "active" : "idle")\tsafety=\(safety)\tbuild=\(target.build ?? 0)",
                    0)
            }
        }
    }

    private static func discoverCLI() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        if environment["DOPPEL_DEV"] == "1", let override = environment["DOPPEL_CLI"] {
            let url = URL(fileURLWithPath: override)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        if let bundled = Bundle.main.resourceURL?.appending(path: "doppel/bin/doppel"),
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        return nil
    }

    private static func singleLine(_ value: String) -> String {
        value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
