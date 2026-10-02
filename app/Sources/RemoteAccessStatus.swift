import Foundation
import Darwin

struct RemoteAccessNetwork: Decodable, Equatable {
    let interface: String
    let address: String
}

struct RemoteAccessStatus: Decodable, Equatable {
    let schemaVersion: Int
    let profileSlug: String
    let remoteId: String?
    let state: State
    let enabled: Bool
    let host: String?
    let bindAddress: String?
    let port: Int?
    let username: String?
    let email: String?
    let accountId: String?
    let runtimeVersion: String?
    let hostKeyFingerprint: String?
    let checkedAt: String?
    let detail: String?
    let networks: [RemoteAccessNetwork]

    enum State: String, Decodable, Equatable {
        case notConfigured, signInRequired, disabled, ready, networkUnavailable, blocked
    }

    static func parse(_ data: Data) throws -> RemoteAccessStatus {
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.schemaVersion == 1 else { throw RemoteCLIError("This version of Doppel cannot read the Remote Access status.") }
        return value
    }

}

struct RemoteCLIError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }

    static func helperMessage(from data: Data) -> String? {
        struct Failure: Decodable { let schemaVersion: Int; let error: String }
        guard let line = String(data: data, encoding: .utf8)?.split(separator: "\n").last,
              let value = try? JSONDecoder().decode(Failure.self, from: Data(line.utf8)),
              value.schemaVersion == 1 else { return nil }
        let message = value.error.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, message.count <= 500,
              !message.contains("\n"), !message.contains("/Users/"),
              !message.contains("-----BEGIN") else { return nil }
        return message
    }
}

enum RemoteAccessKey {
    static func isECDSAPrivateKey(_ value: String) -> Bool {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = key.split(whereSeparator: \.isNewline)
        guard lines.count >= 3 else { return false }
        let type = lines[0] == "-----BEGIN PRIVATE KEY-----" ? "PRIVATE KEY" : "EC PRIVATE KEY"
        guard lines[0] == "-----BEGIN \(type)-----", lines[lines.count - 1] == "-----END \(type)-----" else { return false }
        return Data(base64Encoded: lines.dropFirst().dropLast().joined()) != nil
    }
}

/// Small cancellable process owner used for the long device-code login.
/// Both pipes are drained concurrently so neither can block the child.
final class RemoteCLIProcess {
    private static let maximumOutputBytes = 1_048_576
    private let lock = NSLock()
    private let process = Process()
    private var output = Data()
    private var lineBuffer = NDJSONLineBuffer()
    private var totalBytes = 0
    private var openStreams = 2
    private var exitStatus: Int32?
    private var failure: String?
    private var terminating = false
    private var finished = false
    private var readHandles: [FileHandle] = []
    private var completionHandler: (@MainActor (Result<String, Error>) -> Void)?

    func start(cli: URL, arguments: [String], timeout: TimeInterval,
               onLine: @escaping @MainActor (String) -> Void,
               completion: @escaping @MainActor (Result<String, Error>) -> Void) {
        let stdout = Pipe(), stderr = Pipe()
        process.executableURL = cli
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        readHandles = [stdout.fileHandleForReading, stderr.fileHandleForReading]
        completionHandler = completion
        drain(stdout.fileHandleForReading, isError: false, onLine: onLine)
        drain(stderr.fileHandleForReading, isError: true, onLine: { _ in })
        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            self.lock.lock(); self.exitStatus = process.terminationStatus; self.lock.unlock()
            self.finishIfReady()
        }
        do {
            try process.run()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self else { return }
                self.lock.lock(); let alreadyFinished = self.finished; self.lock.unlock()
                guard !alreadyFinished else { return }
                self.terminate("Remote Access operation timed out. Try again.")
            }
        } catch {
            complete(.failure(RemoteCLIError("Could not start the Remote Access command.")))
        }
    }

    func cancel() { terminate("Sign-in cancelled.") }

    private func drain(_ handle: FileHandle, isError: Bool,
                       onLine: @escaping @MainActor (String) -> Void) {
        handle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { handle.readabilityHandler = nil; return }
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                self.streamClosed()
                return
            }
            let lines = self.consume(data, isError: isError)
            for line in lines { Task { @MainActor in onLine(line) } }
        }
    }

    private func consume(_ data: Data, isError: Bool) -> [String] {
        lock.lock()
        totalBytes += data.count
        guard totalBytes <= Self.maximumOutputBytes else {
            failure = "Remote Access returned too much output. Try again."
            let shouldTerminate = !terminating
            lock.unlock()
            if shouldTerminate { terminate("Remote Access returned too much output. Try again.") }
            return []
        }
        if isError { lock.unlock(); return [] }
        output.append(data)
        let lines = lineBuffer.append(data, maximumBytes: Self.maximumOutputBytes)
        lock.unlock()
        guard let lines else {
            terminate("Remote Access returned an invalid response. Try again.")
            return []
        }
        return lines
    }

    private func streamClosed() {
        lock.lock(); openStreams -= 1; lock.unlock()
        finishIfReady()
    }

    private func finishIfReady() {
        lock.lock()
        guard !finished, openStreams == 0, let status = exitStatus else { lock.unlock(); return }
        finished = true
        let data = output
        let failure = self.failure
        let callback = completionHandler
        completionHandler = nil
        lock.unlock()
        if let failure { complete(.failure(RemoteCLIError(failure)), using: callback) }
        else if status == 0 { complete(.success(String(decoding: data, as: UTF8.self)), using: callback) }
        else {
            let message = RemoteCLIError.helperMessage(from: data)
                ?? "Remote Access command failed. Check Again or try again."
            complete(.failure(RemoteCLIError(message)), using: callback)
        }
    }

    private func terminate(_ reason: String) {
        lock.lock()
        guard !terminating, !finished else { lock.unlock(); return }
        terminating = true; failure = reason
        lock.unlock()
        if process.isRunning { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self else { return }
            if self.process.isRunning { kill(self.process.processIdentifier, SIGKILL) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [weak self] in self?.forceCloseStreams() }
        }
    }

    private func forceCloseStreams() {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        let handles = readHandles
        openStreams = 0
        if exitStatus == nil { exitStatus = process.isRunning ? -1 : process.terminationStatus }
        lock.unlock()
        for handle in handles { handle.readabilityHandler = nil; try? handle.close() }
        finishIfReady()
    }

    private func complete(_ result: Result<String, Error>, using callback: (@MainActor (Result<String, Error>) -> Void)? = nil) {
        lock.lock()
        let handler = callback ?? completionHandler
        completionHandler = nil
        lock.unlock()
        guard let handler else { return }
        Task { @MainActor in handler(result) }
    }
}

struct NDJSONLineBuffer {
    private var pending = Data()

    mutating func append(_ data: Data, maximumBytes: Int) -> [String]? {
        pending.append(data)
        guard pending.count <= maximumBytes else { return nil }
        let newlineIndices = pending.indices.filter { pending[$0] == 0x0A }
        guard let last = newlineIndices.last else { return [] }
        let complete = Data(pending[..<pending.index(after: last)])
        pending = Data(pending[pending.index(after: last)...])
        return complete.split(separator: 0x0A, omittingEmptySubsequences: true)
            .map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}
