import Foundation
import Darwin

struct RemoteProcessResult {
    let status: Int32
    let output: Data
    let error: Data
}

enum RemoteSystem {
    static var username: String { String(cString: getpwuid(getuid()).pointee.pw_name) }
    static var shell: String { String(cString: getpwuid(getuid()).pointee.pw_shell) }

    static func environment(home: URL? = nil, installDirectory: URL? = nil) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for key in ["OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN", "CODEX_EXEC_SERVER_URL",
                    "CODEX_CLI_PATH", "CODEX_HOME", "CODEX_INSTALL_DIR", "SSH_ORIGINAL_COMMAND"] {
            env[key] = nil
        }
        if let home { env["CODEX_HOME"] = home.path }
        if let installDirectory {
            env["CODEX_INSTALL_DIR"] = installDirectory.path
            env["PATH"] = installDirectory.path + ":" + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        }
        return env
    }

    // Drain both pipes while the process runs: package bootstrap and SSH errors
    // must not fill a pipe and deadlock the GUI's child process.
    static func run(_ path: String, _ arguments: [String], environment: [String: String]? = nil,
                    timeout: TimeInterval = 120) throws -> RemoteProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
        process.environment = environment ?? self.environment()
        let out = Pipe(), err = Pipe()
        process.standardOutput = out; process.standardError = err; process.standardInput = FileHandle.nullDevice
        final class Capture: @unchecked Sendable {
            let lock = NSLock()
            var data = Data()
            var stopped = false
            func stop() { lock.lock(); stopped = true; lock.unlock() }
            func consume(_ handle: FileHandle) {
                let fd = handle.fileDescriptor
                _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
                var buffer = [UInt8](repeating: 0, count: 16_384)
                while true {
                    let count = read(fd, &buffer, buffer.count)
                    if count == 0 { break }
                    lock.lock()
                    let stop = stopped
                    if count > 0, data.count < 1_048_576 {
                        data.append(contentsOf: buffer.prefix(min(count, 1_048_576 - data.count)))
                    }
                    lock.unlock()
                    if stop { break }
                    if count < 0 {
                        if errno != EAGAIN && errno != EINTR { break }
                        Thread.sleep(forTimeInterval: 0.01)
                    }
                }
            }
        }
        let stdout = Capture(), stderr = Capture()
        try process.run()
        let group = DispatchGroup()
        group.enter(); DispatchQueue.global().async { stdout.consume(out.fileHandleForReading); group.leave() }
        group.enter(); DispatchQueue.global().async { stderr.consume(err.fileHandleForReading); group.leave() }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.1)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit(); stdout.stop(); stderr.stop(); group.wait()
            throw RemoteAccessError("The remote setup command timed out. Check Again before retrying.")
        }
        process.waitUntilExit()
        if group.wait(timeout: .now() + 1) == .timedOut {
            stdout.stop(); stderr.stop(); group.wait()
        }
        return .init(status: process.terminationStatus, output: stdout.data, error: stderr.data)
    }

    static func requireSuccess(_ path: String, _ args: [String], environment: [String: String]? = nil,
                               message: String, timeout: TimeInterval = 120) throws -> Data {
        let result = try run(path, args, environment: environment, timeout: timeout)
        guard result.status == 0 else { throw RemoteAccessError(message) }
        return result.output
    }

    static func shellQuote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func execute(_ path: String, _ args: [String], environment: [String: String]) throws -> Never {
        signal(SIGTERM, SIG_DFL); signal(SIGINT, SIG_DFL)
        for (key, _) in ProcessInfo.processInfo.environment { unsetenv(key) }
        for (key, value) in environment { setenv(key, value, 1) }
        let strings = ([path] + args).map { strdup($0) }
        defer { for string in strings { free(string) } }
        var argv = strings + [nil]
        execv(path, &argv)
        throw RemoteAccessError("Could not start the selected remote process.")
    }
}

public struct RemoteProfileContext {
    public let slug: String
    public let profileDirectory: String
    public let desktopHome: String
    public let primaryApp: String
    public let cliPath: String
    public init(slug: String, profileDirectory: String, desktopHome: String,
                primaryApp: String, cliPath: String) {
        self.slug = slug; self.profileDirectory = profileDirectory; self.desktopHome = desktopHome
        self.primaryApp = primaryApp; self.cliPath = cliPath
    }
}

public struct RemoteAccessStatus: Codable {
    public var schemaVersion = 1
    public let profileSlug: String
    public let remoteId: String?
    public let state: String
    public let enabled: Bool
    public let host: String?
    public let bindAddress: String?
    public let port: Int?
    public let username: String
    public let email: String?
    public let accountId: String?
    public let runtimeVersion: String?
    public let hostKeyFingerprint: String?
    public let checkedAt: Date?
    public let detail: String?
    public let networks: [RemoteNetworkAddress]
}
