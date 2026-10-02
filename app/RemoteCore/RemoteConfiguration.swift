import Foundation
import Darwin

public struct RemoteAccessError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct RemoteConfiguration: Codable {
    public var schemaVersion = 1
    public let remoteId: String
    public let profileSlug: String
    public let profileDirectory: String
    public let desktopHome: String
    public var enabled: Bool
    public var bindAddress: String
    public var connectionHost: String
    public let port: Int
    public var expectedAccountId: String?
    public var expectedEmail: String?
}

public struct RemoteNetworkAddress: Codable, Equatable {
    public let interface: String
    public let address: String

    public static func isPrivate(_ address: String) -> Bool {
        let fields = address.split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 4 else { return false }
        let numbers = fields.compactMap { UInt8($0) }
        guard numbers.count == 4,
              zip(fields, numbers).allSatisfy({ String($0.1) == $0.0 }) else { return false }
        return numbers[0] == 10 || (numbers[0] == 172 && (16...31).contains(numbers[1]))
            || (numbers[0] == 192 && numbers[1] == 168)
            || (numbers[0] == 100 && (64...127).contains(numbers[1]))
    }

    public static func available() -> [RemoteNetworkAddress] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return [] }
        defer { freeifaddrs(first) }
        var result: [RemoteNetworkAddress] = []
        var next = first
        while let current = next {
            defer { next = current.pointee.ifa_next }
            guard let addr = current.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET),
                  current.pointee.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            var value = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &value, &buffer, socklen_t(buffer.count)) != nil else { continue }
            let address = String(cString: buffer)
            if isPrivate(address) {
                result.append(.init(interface: String(cString: current.pointee.ifa_name), address: address))
            }
        }
        return result.sorted { ($0.interface, $0.address) < ($1.interface, $1.address) }
    }
}

public final class RemoteConfigurationStore {
    public let root: URL
    private let fm = FileManager.default

    public init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".dpr")) {
        self.root = root.standardizedFileURL
    }

    public func directory(_ id: String) throws -> URL {
        guard id.count == 12, id.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw RemoteAccessError("Invalid remote profile identifier.")
        }
        return root.appendingPathComponent(id)
    }

    public func home(_ id: String) throws -> URL { try directory(id).appendingPathComponent("home") }

    public func validate(_ url: URL, privateMode: Bool = false) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw RemoteAccessError("A remote setup file is missing.") }
        guard info.st_mode & S_IFMT != S_IFLNK, info.st_uid == getuid(),
              info.st_mode & 0o022 == 0,
              !privateMode || info.st_mode & 0o077 == 0 else {
            throw RemoteAccessError("Remote setup has unsafe ownership, permissions or a symbolic link.")
        }
    }

    public func validateIfPresent(_ url: URL, privateMode: Bool = false) throws -> Bool {
        var info = stat()
        if lstat(url.path, &info) == 0 {
            try validate(url, privateMode: privateMode)
            return true
        }
        guard errno == ENOENT else { throw RemoteAccessError("Could not inspect a remote setup path safely.") }
        return false
    }

    public func validateParents(_ url: URL) throws {
        var current = url.standardizedFileURL
        let userHome = fm.homeDirectoryForCurrentUser.standardizedFileURL
        guard current.path.hasPrefix(userHome.path + "/") || current == userHome else {
            // Test fixtures remain opt-in, and are never honoured by installed copies.
            guard ProcessInfo.processInfo.environment["DOPPEL_DEV"] == "1",
                  current.path == root.path || current.path.hasPrefix(root.path + "/") else {
                throw RemoteAccessError("Remote data must be inside your home directory.")
            }
            while current.path != root.path {
                try validate(current)
                current.deleteLastPathComponent()
            }
            try validate(root, privateMode: true)
            return
        }
        while current.path.hasPrefix(userHome.path) {
            try validate(current)
            if current == userHome { break }
            current.deleteLastPathComponent()
        }
    }

    public func prepareRoot() throws {
        if !fm.fileExists(atPath: root.path) {
            try validateParents(root.deletingLastPathComponent())
            try fm.createDirectory(at: root, withIntermediateDirectories: false,
                                   attributes: [.posixPermissions: 0o700])
        }
        try validateParents(root)
        try validate(root, privateMode: true)
    }

    public func withLock<T>(id: String? = nil, _ operation: () throws -> T) throws -> T {
        let lock = try acquireLock(id: id)
        defer { lock.release() }
        return try operation()
    }

    public func acquireLock(id: String? = nil) throws -> RemoteOperationLock {
        try prepareRoot()
        let url = try id.map { try directory($0).appendingPathComponent("operation.lock") }
            ?? root.appendingPathComponent("configuration.lock")
        let fd = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw RemoteAccessError("Could not lock remote setup.") }
        do { try validate(url, privateMode: true) }
        catch { close(fd); throw error }
        let deadline = Date().addingTimeInterval(8)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard Date() < deadline else {
                close(fd)
                throw RemoteAccessError("Another remote operation is running. Try again shortly.")
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return RemoteOperationLock(fd: fd)
    }

    public func configurations() throws -> [RemoteConfiguration] {
        guard fm.fileExists(atPath: root.path) else { return [] }
        try validateParents(root)
        return try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.count == 12 }.map { try load($0.lastPathComponent) }
    }

    public func load(_ id: String) throws -> RemoteConfiguration {
        let dir = try directory(id)
        try validateParents(dir)
        try validate(dir, privateMode: true)
        let file = dir.appendingPathComponent("config.json")
        try validate(file, privateMode: true)
        let value = try JSONDecoder().decode(RemoteConfiguration.self, from: Data(contentsOf: file))
        guard value.schemaVersion == 1, value.remoteId == id,
              value.profileSlug.range(of: "^[a-z0-9]+(?:-[a-z0-9]+)*$", options: .regularExpression) != nil,
              (54221...54320).contains(value.port), RemoteNetworkAddress.isPrivate(value.bindAddress) else {
            throw RemoteAccessError("Remote configuration is invalid or from an unsupported version.")
        }
        try validateHomeLength(id)
        return value
    }

    public func find(profileSlug: String) throws -> RemoteConfiguration? {
        let values = try configurations().filter { $0.profileSlug == profileSlug }
        guard values.count <= 1 else { throw RemoteAccessError("Duplicate remote profile configuration.") }
        return values.first
    }

    public func save(_ configuration: RemoteConfiguration) throws {
        let dir = try directory(configuration.remoteId)
        try validate(dir, privateMode: true)
        try write(JSONEncoder().encode(configuration), to: dir.appendingPathComponent("config.json"))
    }

    public func write(_ data: Data, to url: URL) throws {
        try validateParents(url.deletingLastPathComponent())
        _ = try validateIfPresent(url, privateMode: true)
        try data.write(to: url, options: .atomic)
        guard chmod(url.path, 0o600) == 0 else { throw RemoteAccessError("Could not secure remote setup file.") }
    }

    public func validateHomeLength(_ id: String) throws {
        let socket = try home(id).resolvingSymlinksInPath()
            .appendingPathComponent("app-server-control/app-server-control.sock")
        guard socket.path.utf8.count < 104 else {
            throw RemoteAccessError("Your home path is too long for the Codex control socket. Remote Access cannot safely start here.")
        }
    }

    public func create(profileSlug: String, profileDirectory: String, desktopHome: String,
                       bindAddress: String, connectionHost: String) throws -> RemoteConfiguration {
        try withLock {
            if var existing = try find(profileSlug: profileSlug) {
                guard !existing.enabled else { throw RemoteAccessError("Disable this profile before changing its network.") }
                existing.bindAddress = bindAddress; existing.connectionHost = connectionHost
                try save(existing); return existing
            }
            let used = Set(try configurations().map(\.port))
            guard let port = (54221...54320).first(where: { !used.contains($0) && Self.portAvailable($0, address: bindAddress) }) else {
                throw RemoteAccessError("No free remote port is available between 54221 and 54320.")
            }
            var id: String
            repeat { id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12).description }
            while fm.fileExists(atPath: try directory(id).path)
            try validateHomeLength(id)
            let dir = try directory(id)
            try fm.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try fm.createDirectory(at: home(id), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let value = RemoteConfiguration(remoteId: id, profileSlug: profileSlug,
                profileDirectory: profileDirectory, desktopHome: desktopHome, enabled: false,
                bindAddress: bindAddress, connectionHost: connectionHost, port: port)
            try save(value); return value
        }
    }

    public static func portAvailable(_ port: Int, address: String) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        guard inet_pton(AF_INET, address, &addr.sin_addr) == 1 else { return false }
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
    }
}

public final class RemoteOperationLock {
    private var fd: Int32
    fileprivate init(fd: Int32) { self.fd = fd }
    public func release() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN); close(fd); fd = -1
    }
    deinit { release() }
}
