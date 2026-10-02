import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket

public struct RuntimeIdentity: Equatable, Sendable {
    public let codexHome: String
    public let appServerVersion: String?
    public let email: String?
    public let accountId: String?
    public let isChatGPT: Bool

    public init(codexHome: String, appServerVersion: String?, email: String?, accountId: String?, isChatGPT: Bool) {
        self.codexHome = codexHome
        self.appServerVersion = appServerVersion
        self.email = email
        self.accountId = accountId
        self.isChatGPT = isChatGPT
    }
}

public struct DeviceLogin: Equatable, Sendable {
    public let loginId: String
    public let verificationUrl: String
    public let userCode: String

    public init(loginId: String, verificationUrl: String, userCode: String) {
        self.loginId = loginId
        self.verificationUrl = verificationUrl
        self.userCode = userCode
    }
}

public final class CodexRuntimeClient: @unchecked Sendable {
    static func safeErrorMessage(_ error: Error) -> String? {
        if error is RuntimeTimeout { return "The Codex request timed out. Check Again or restart sign-in." }
        if error is CancellationError { return "Sign-in cancelled." }
        guard let error = error as? RuntimeClientError else { return nil }
        switch error {
        case .loginCancelled: return "Sign-in cancelled."
        case .loginFailed: return "ChatGPT sign-in failed or expired. Start sign-in again."
        case .workspaceMismatch: return "The daemon reports a different home. Remote Access is blocked."
        case .remote: return "Codex rejected the request. Check managed sign-in requirements and runtime compatibility."
        case .disconnected: return "The Codex runtime disconnected. Check Again before retrying."
        default: return "The Codex runtime protocol is unsupported or invalid. Check runtime compatibility before retrying."
        }
    }
    private let socketPath: String
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private let lock = NSLock()
    private var channel: Channel?
    private var nextID = 1
    private var pending: [Int: EventLoopPromise<[String: Any]>] = [:]
    private var loginWaiters: [String: [LoginWaiter]] = [:]
    private var loginOutcomes: [String: Bool] = [:]
    private var cancelledLoginIDs: Set<String> = []
    private var fragment = Data()
    private var fragmentInProgress = false
    private var initialized = false
    private var runtimeHome: String?
    private var serverVersion: String?

    public init(socketPath: String) { self.socketPath = socketPath }

    public func initialize(expectedHome: String) async throws -> RuntimeIdentity {
        try await connectIfNeeded()
        let result = try await rpc("initialize", params: [
            "clientInfo": ["name": "doppel", "title": "Doppel", "version": "2.0"],
            "capabilities": ["experimentalApi": true, "requestAttestation": false],
        ])
        guard let reportedHome = result["codexHome"] as? String,
              let actualHome = canonicalHome(reportedHome),
              let wantedHome = canonicalHome(expectedHome),
              actualHome == wantedHome else { throw RuntimeClientError.workspaceMismatch }
        lock.withLock {
            runtimeHome = actualHome
            if let userAgent = result["userAgent"] as? String {
                let version = userAgent.split(separator: "/").last ?? Substring(userAgent)
                serverVersion = version.split(whereSeparator: { $0.isWhitespace }).first.map(String.init)
            }
        }
        try await sendNotification("initialized", params: [:])
        lock.withLock { initialized = true }
        return try await readIdentity(expectedHome: expectedHome)
    }

    public func readIdentity(expectedHome: String) async throws -> RuntimeIdentity {
        guard lock.withLock({ initialized }) else { throw RuntimeClientError.notInitialized }
        guard let actualHome = lock.withLock({ runtimeHome }),
              canonicalHome(expectedHome) == actualHome else { throw RuntimeClientError.workspaceMismatch }
        let response = try await rpc("account/read", params: ["refreshToken": false])
        let account = response["account"] as? [String: Any] ?? response
        let workspaceRouting = response["workspaceRouting"] as? [String: Any] ?? [:]
        return RuntimeIdentity(
            codexHome: actualHome,
            appServerVersion: lock.withLock { serverVersion },
            email: account["email"] as? String,
            accountId: workspaceRouting["chatgptAccountId"] as? String,
            isChatGPT: (account["type"] as? String)?.lowercased() == "chatgpt"
        )
    }

    public func beginDeviceLogin() async throws -> DeviceLogin {
        guard lock.withLock({ initialized }) else { throw RuntimeClientError.notInitialized }
        let response = try await rpc("account/login/start", params: ["type": "chatgptDeviceCode"])
        guard let loginId = response["loginId"] as? String,
              let url = response["verificationUrl"] as? String ?? response["authUrl"] as? String,
              let code = response["userCode"] as? String else { throw RuntimeClientError.invalidResponse }
        return DeviceLogin(loginId: loginId, verificationUrl: url, userCode: code)
    }

    public func waitForLogin(loginId: String) async throws {
        guard lock.withLock({ initialized }) else { throw RuntimeClientError.notInitialized }
        let promise = group.next().makePromise(of: Void.self)
        let waiter = LoginWaiter(promise: promise)
        let registration = lock.withLock { () -> (wasCancelled: Bool, outcome: Bool?) in
            if cancelledLoginIDs.contains(loginId) { return (true, nil) }
            if let outcome = loginOutcomes.removeValue(forKey: loginId) { return (false, outcome) }
            loginWaiters[loginId, default: []].append(waiter)
            return (false, nil)
        }
        if registration.wasCancelled {
            waiter.resolve(RuntimeClientError.loginCancelled)
        } else if let priorOutcome = registration.outcome {
            waiter.resolve(priorOutcome ? nil : RuntimeClientError.loginFailed)
        }
        do {
            try await withTaskCancellationHandler {
                try await withTimeout(promise.futureResult, seconds: 600)
            } onCancel: {
                waiter.resolve(CancellationError())
            }
            let response = try await rpc("account/read", params: ["refreshToken": false])
            let account = response["account"] as? [String: Any] ?? response
            guard (account["type"] as? String)?.lowercased() == "chatgpt" else {
                throw RuntimeClientError.loginFailed
            }
        } catch {
            waiter.resolve(error)
            let shouldCancel = error is CancellationError || error is RuntimeTimeout
            lock.withLock {
                loginWaiters[loginId]?.removeAll { $0.id == waiter.id }
                if loginWaiters[loginId]?.isEmpty == true { loginWaiters.removeValue(forKey: loginId) }
            }
            if shouldCancel { try? await cancelLogin(loginId: loginId) }
            throw error
        }
    }

    public func cancelLogin(loginId: String) async throws {
        guard lock.withLock({ initialized }) else { throw RuntimeClientError.notInitialized }
        lock.withLock {
            cancelledLoginIDs.insert(loginId)
            loginOutcomes.removeValue(forKey: loginId)
        }
        do {
            _ = try await rpc("account/login/cancel", params: ["loginId": loginId])
            let waiters = lock.withLock { () -> [LoginWaiter] in
                loginOutcomes.removeValue(forKey: loginId)
                return loginWaiters.removeValue(forKey: loginId) ?? []
            }
            waiters.forEach { $0.resolve(RuntimeClientError.loginCancelled) }
        } catch {
            let (waiters, outcome) = lock.withLock { () -> ([LoginWaiter], Bool?) in
                cancelledLoginIDs.remove(loginId)
                let outcome = loginOutcomes.removeValue(forKey: loginId)
                let waiters = outcome == nil ? [] : loginWaiters.removeValue(forKey: loginId) ?? []
                return (waiters, outcome)
            }
            if let outcome { waiters.forEach { $0.resolve(outcome ? nil : RuntimeClientError.loginFailed) } }
            throw error
        }
    }

    public func close() async {
        let current = lock.withLock { () -> Channel? in
            let c = channel
            channel = nil
            return c
        }
        if let current { try? await current.close().get() }
        try? await group.shutdownGracefully()
    }

    private func connectIfNeeded() async throws {
        if lock.withLock({ channel != nil }) { return }
        let handler = RPCWebSocketHandler(client: self)
        let upgradePromise = group.next().makePromise(of: Void.self)
        let upgrader = NIOWebSocketClientUpgrader(maxFrameSize: 1 << 20) { channel, _ in
            channel.pipeline.addHandler(handler).map { upgradePromise.succeed(()) }
        }
        let config: NIOHTTPClientUpgradeSendableConfiguration = (
            upgraders: [upgrader], completionHandler: { _ in })
        let bootstrap = ClientBootstrap(group: group).channelInitializer { channel in
            channel.pipeline.addHTTPClientHandlers(withClientUpgrade: config).flatMap {
                channel.pipeline.addHandler(UpgradeRequestHandler())
            }
        }
        let connected = try await withTimeout(bootstrap.connect(unixDomainSocketPath: socketPath), seconds: 8)
        lock.withLock { channel = connected }
        try await withTimeout(upgradePromise.futureResult, seconds: 8)
    }

    private func rpc(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        let id = lock.withLock { () -> Int in let value = nextID; nextID += 1; return value }
        let promise = group.next().makePromise(of: [String: Any].self)
        guard let channel = lock.withLock({ channel }) else { throw RuntimeClientError.disconnected }
        lock.withLock { pending[id] = promise }
        let object: [String: Any] = ["id": id, "method": method, "params": params]
        do {
            let data = try JSONSerialization.data(withJSONObject: object)
            guard data.count <= Self.maxMessageSize else { throw RuntimeClientError.messageTooLarge }
            var buffer = channel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            let frame = WebSocketFrame(fin: true, opcode: .text, maskKey: .random(), data: buffer)
            try await withTimeout(channel.writeAndFlush(frame), seconds: 8)
            return try await withTimeout(promise.futureResult, seconds: 8)
        } catch {
            _ = lock.withLock { pending.removeValue(forKey: id) }
            throw error
        }
    }

    private func sendNotification(_ method: String, params: [String: Any]) async throws {
        guard let channel = lock.withLock({ channel }) else { throw RuntimeClientError.disconnected }
        let data = try JSONSerialization.data(withJSONObject: ["method": method, "params": params])
        guard data.count <= Self.maxMessageSize else { throw RuntimeClientError.messageTooLarge }
        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        try await withTimeout(channel.writeAndFlush(WebSocketFrame(fin: true, opcode: .text, maskKey: .random(), data: buffer)), seconds: 8)
    }

    fileprivate func receive(_ frame: WebSocketFrame) {
        switch frame.opcode {
        case .ping:
            let pong = WebSocketFrame(fin: true, opcode: .pong, maskKey: .random(), data: frame.unmaskedData)
            _ = channel?.writeAndFlush(pong)
        case .pong: break
        case .connectionClose:
            failAll(RuntimeClientError.disconnected)
            _ = channel?.close()
        case .text, .continuation:
            let copy = frame
            let bytes = copy.unmaskedData
            let state = lock.withLock { () -> (Bool, Data?) in
                if frame.opcode == .text {
                    guard !fragmentInProgress else { return (false, nil) }
                    fragment.removeAll(keepingCapacity: true)
                } else if !fragmentInProgress { return (false, nil) }
                guard fragment.count + bytes.readableBytes <= Self.maxMessageSize else { return (false, nil) }
                fragment.append(contentsOf: bytes.readableBytesView)
                fragmentInProgress = !frame.fin
                return (true, frame.fin ? fragment : nil)
            }
            guard state.0 else { protocolFailure(); return }
            guard let complete = state.1 else { return }
            guard let object = try? JSONSerialization.jsonObject(with: complete) as? [String: Any] else {
                protocolFailure(); return
            }
            dispatch(object)
        default: protocolFailure()
        }
    }

    fileprivate func channelClosed() { failAll(RuntimeClientError.disconnected) }

    private func dispatch(_ object: [String: Any]) {
        if let id = object["id"] as? Int {
            let promise = lock.withLock { pending.removeValue(forKey: id) }
            if let error = object["error"] as? [String: Any] {
                promise?.fail(RuntimeClientError.remote(error["message"] as? String ?? "RPC failed"))
            } else if let result = object["result"] as? [String: Any] {
                promise?.succeed(result)
            } else { promise?.fail(RuntimeClientError.invalidResponse) }
        } else if object["method"] as? String == "account/login/completed",
                  let params = object["params"] as? [String: Any],
                  let loginId = params["loginId"] as? String {
            let success = params["success"] as? Bool == true
            let waiters = lock.withLock { () -> [LoginWaiter] in
                if cancelledLoginIDs.contains(loginId) {
                    loginOutcomes[loginId] = success
                    return []
                }
                let current = loginWaiters.removeValue(forKey: loginId) ?? []
                if current.isEmpty { loginOutcomes[loginId] = success }
                return current
            }
            waiters.forEach { $0.resolve(success ? nil : RuntimeClientError.loginFailed) }
        }
    }

    private func protocolFailure() {
        _ = channel?.close()
        failAll(RuntimeClientError.protocolViolation)
    }

    private func failAll(_ error: Error) {
        let values = lock.withLock { () -> ([EventLoopPromise<[String: Any]>], [LoginWaiter]) in
            let p = Array(pending.values); pending.removeAll()
            let l = loginWaiters.values.flatMap { $0 }; loginWaiters.removeAll()
            return (p, l)
        }
        values.0.forEach { $0.fail(error) }
        values.1.forEach { $0.resolve(error) }
    }

    private static let maxMessageSize = 1 << 20
}

private final class UpgradeRequestHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = Never
    typealias OutboundOut = HTTPClientRequestPart
    func channelActive(context: ChannelHandlerContext) {
        var head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/")
        head.headers.add(name: "Host", value: "localhost")
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        context.fireChannelActive()
    }
}

private final class RPCWebSocketHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame
    private weak var client: CodexRuntimeClient?
    init(client: CodexRuntimeClient) { self.client = client }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) { client?.receive(unwrapInboundIn(data)) }
    func channelInactive(context: ChannelHandlerContext) { client?.channelClosed(); context.fireChannelInactive() }
    func errorCaught(context: ChannelHandlerContext, error: Error) { client?.channelClosed(); context.close(promise: nil) }
}

private enum RuntimeClientError: Error {
    case notInitialized, disconnected, invalidResponse, messageTooLarge, protocolViolation
    case loginFailed, loginCancelled, workspaceMismatch
    case remote(String)
}

private final class LoginWaiter: @unchecked Sendable {
    let id = UUID()
    private let promise: EventLoopPromise<Void>
    private let lock = NSLock()
    private var completed = false

    init(promise: EventLoopPromise<Void>) { self.promise = promise }

    func resolve(_ error: Error?) {
        let shouldResolve = lock.withLock { () -> Bool in
            guard !completed else { return false }
            completed = true
            return true
        }
        guard shouldResolve else { return }
        if let error { promise.fail(error) } else { promise.succeed(()) }
    }
}

private func withTimeout<T>(_ future: EventLoopFuture<T>, seconds: TimeInterval) async throws -> T {
    let result = future.eventLoop.makePromise(of: T.self)
    var completed = false
    let timeout = future.eventLoop.scheduleTask(in: .seconds(Int64(seconds))) {
        guard !completed else { return }
        completed = true
        result.fail(RuntimeTimeout())
    }
    future.whenComplete { completion in
        timeout.cancel()
        guard !completed else { return }
        completed = true
        result.completeWith(completion)
    }
    return try await result.futureResult.get()
}

private struct RuntimeTimeout: Error {}

private func canonicalHome(_ path: String) -> String? {
    guard path.hasPrefix("/") else { return nil }
    return URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
}
