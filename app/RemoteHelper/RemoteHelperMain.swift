import Foundation
import Darwin
import DoppelRemoteCore

@main
struct RemoteHelperMain {
    static func output<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        FileHandle.standardOutput.write(data + Data([10]))
    }

    static func main() async {
        umask(0o077)
        let operation = Task { await run() }
        let signals = [SIGTERM, SIGINT].map { number -> DispatchSourceSignal in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { operation.cancel() }
            source.resume()
            return source
        }
        await operation.value
        for source in signals { source.cancel() }
    }

    static func run() async {
        let args = Array(CommandLine.arguments.dropFirst())
        let internalCommand = args.first?.hasPrefix("__") == true
        do {
            guard let command = args.first else { throw RemoteAccessError("A remote command is required.") }
            var options: [String: String] = [:]
            let allowedOptions: Set<String> = ["--profile-slug", "--profile-dir", "--desktop-home", "--primary-app",
                                               "--cli", "--bind-address", "--host", "--purge", "--expected-account-id", "--expected-email"]
            var index = 1
            while index < args.count {
                guard allowedOptions.contains(args[index]), index + 1 < args.count,
                      options[args[index]] == nil else { throw RemoteAccessError("Invalid remote command arguments.") }
                options[args[index]] = args[index + 1]; index += 2
            }
            func required(_ name: String) throws -> String {
                guard let value = options[name], !value.isEmpty else { throw RemoteAccessError("Missing resolved profile configuration.") }
                return value
            }
            let context = try RemoteProfileContext(slug: required("--profile-slug"),
                profileDirectory: required("--profile-dir"), desktopHome: required("--desktop-home"),
                primaryApp: required("--primary-app"), cliPath: required("--cli"))
            let controller = RemoteAccessController(store: RemoteConfigurationStore(), profile: context)
            switch command {
            case "status": break
            case "configure": try controller.configure(address: required("--bind-address"), host: options["--host"])
            case "login":
                try await controller.login { login in
                    // Only the explicit login command emits temporary credentials.
                    struct LoginEvent: Encodable {
                        let schemaVersion = 1
                        let event = "deviceCode"
                        let verificationUrl: String
                        let userCode: String
                    }
                    try? output(LoginEvent(verificationUrl: login.verificationUrl, userCode: login.userCode))
                }
            case "enable": try await controller.enable(expectedAccountId: options["--expected-account-id"], expectedEmail: options["--expected-email"])
            case "disable": try controller.disable()
            case "replace-key": try controller.replaceKey()
            case "update-runtime": try controller.updateRuntime()
            case "export-key":
                FileHandle.standardOutput.write(try controller.exportKey()); return
            case "__serve": try await controller.serve()
            case "__session": try await controller.session(originalCommand: ProcessInfo.processInfo.environment["SSH_ORIGINAL_COMMAND"] ?? "")
            case "__remove": try controller.remove(purge: options["--purge"] == "true")
            default: throw RemoteAccessError("Unknown remote command.")
            }
            let status = await controller.status()
            if command == "login" {
                struct CompletionEvent: Encodable {
                    let schemaVersion = 1
                    let event = "complete"
                    let status: RemoteAccessStatus
                }
                try output(CompletionEvent(status: status))
            } else {
                try output(status)
            }
        } catch {
            let message = (error as? RemoteAccessError)?.message ?? "Remote Access could not complete this operation. Check this profile's setup."
            if internalCommand {
                FileHandle.standardError.write(Data((message + "\n").utf8))
            } else {
                struct Failure: Encodable { let schemaVersion = 1; let error: String }
                try? output(Failure(error: message))
            }
            exit(1)
        }
    }
}
