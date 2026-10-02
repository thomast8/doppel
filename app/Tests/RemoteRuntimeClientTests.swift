import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket
import XCTest
@testable import DoppelRemoteCore

final class RemoteRuntimeClientTests: XCTestCase {
    func testOptInLiveDeviceCodeStartAndCancel() async throws {
        guard let home = ProcessInfo.processInfo.environment["DOPPEL_REMOTE_DEVICE_CHECK_HOME"] else {
            throw XCTSkip("Opt-in isolated live device-code start/cancel check.")
        }
        let client = CodexRuntimeClient(socketPath: home + "/app-server-control/app-server-control.sock")
        defer { Task { await client.close() } }
        let initial = try await client.initialize(expectedHome: home)
        guard !initial.isChatGPT else { throw XCTSkip("Already signed in; no new login grant was started.") }
        do {
            let login = try await client.beginDeviceLogin()
            XCTAssertFalse(login.userCode.isEmpty, "A temporary device code is required.")
            XCTAssertEqual(URL(string: login.verificationUrl)?.host, "auth.openai.com")
            try await client.cancelLogin(loginId: login.loginId)
        } catch {
            XCTFail(CodexRuntimeClient.safeErrorMessage(error) ?? "The live device-code request failed.")
        }
    }

    func testFailedDeviceLoginHasAnActionableSanitizedError() async throws {
        let fixture = try RPCFixture()
        defer { fixture.stop() }
        let client = CodexRuntimeClient(socketPath: fixture.socketPath)
        defer { Task { await client.close() } }
        _ = try await client.initialize(expectedHome: "/home")
        let login = try await client.beginDeviceLogin()
        fixture.completeLogin(loginId: login.loginId, success: false)
        do {
            try await client.waitForLogin(loginId: login.loginId)
            XCTFail("Failed authentication must not complete successfully.")
        } catch {
            XCTAssertEqual(CodexRuntimeClient.safeErrorMessage(error), "ChatGPT sign-in failed or expired. Start sign-in again.")
        }
    }

    func testInitializationAndConcurrentIdentityCallsAreCorrelated() async throws {
        let fixture = try RPCFixture(reportedHome: "/isolated/home")
        defer { fixture.stop() }
        let client = CodexRuntimeClient(socketPath: fixture.socketPath)
        defer { Task { await client.close() } }

        let initial = try await client.initialize(expectedHome: "/isolated/home")
        XCTAssertEqual(initial.appServerVersion, "fixture-version")
        XCTAssertEqual(initial.codexHome, "/isolated/home")
        XCTAssertEqual(initial.appServerVersion, "fixture-version")
        XCTAssertTrue(initial.isChatGPT)

        async let first = client.readIdentity(expectedHome: "/isolated/home")
        async let second = client.readIdentity(expectedHome: "/isolated/home")
        let one: RuntimeIdentity
        let two: RuntimeIdentity
        do {
            (one, two) = try await (first, second)
        } catch {
            XCTFail("concurrent identity calls timed out; methods seen: \(fixture.observedMethods)")
            throw error
        }
        XCTAssertEqual(one.codexHome, "/isolated/home")
        XCTAssertEqual(two.codexHome, "/isolated/home")
        XCTAssertEqual(Set([one.email, two.email].compactMap { $0 }), ["one@example.test", "two@example.test"])
        XCTAssertEqual(Set([one.accountId, two.accountId].compactMap { $0 }), ["account-one", "account-two"])
        XCTAssertEqual(fixture.observedMethods, ["initialize", "initialized", "account/read", "account/read", "account/read"])
    }

    func testDisconnectFailsPendingRPC() async throws {
        let fixture = try RPCFixture(disconnectOnIdentityRead: true)
        defer { fixture.stop() }
        let client = CodexRuntimeClient(socketPath: fixture.socketPath)
        defer { Task { await client.close() } }
        _ = try await client.initialize(expectedHome: "/home")
        do {
            _ = try await client.readIdentity(expectedHome: "/home")
            XCTFail("disconnect should fail the pending RPC")
        } catch {
            // The transport error is intentionally opaque to callers.
        }
    }

    func testMalformedServerMessageFailsPendingRPC() async throws {
        let fixture = try RPCFixture(malformedOnIdentityRead: true)
        defer { fixture.stop() }
        let client = CodexRuntimeClient(socketPath: fixture.socketPath)
        defer { Task { await client.close() } }
        _ = try await client.initialize(expectedHome: "/home")
        do {
            _ = try await client.readIdentity(expectedHome: "/home")
            XCTFail("malformed JSON must fail and close the connection")
        } catch {
            // The caller receives a protocol failure without raw payload details.
        }
    }

    func testCancellingLoginWaitSendsCancellationRPC() async throws {
        let fixture = try RPCFixture(completionOnCancel: true)
        defer { fixture.stop() }
        let client = CodexRuntimeClient(socketPath: fixture.socketPath)
        defer { Task { await client.close() } }
        _ = try await client.initialize(expectedHome: "/home")
        let waiting = Task { try await client.waitForLogin(loginId: "login-1") }
        await Task.yield()
        waiting.cancel()
        do {
            try await waiting.value
            XCTFail("cancelled login wait should throw")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("expected cancellation, received \(type(of: error))")
        }
        XCTAssertTrue(fixture.observedMethods.contains("account/login/cancel"))
        XCTAssertTrue(fixture.cancelReplyAcknowledged)
        await client.close()
    }

    func testCompletionBeforeWaitRegistrationIsRemembered() async throws {
        let fixture = try RPCFixture()
        defer { fixture.stop() }
        let client = CodexRuntimeClient(socketPath: fixture.socketPath)
        defer { Task { await client.close() } }
        _ = try await client.initialize(expectedHome: "/home")

        fixture.completeLogin(loginId: "login-1", success: true)
        _ = try await client.readIdentity(expectedHome: "/home")
        try await client.waitForLogin(loginId: "login-1")
    }

    func testRPCTimeoutReturnsWhenServerDoesNotReply() async throws {
        let fixture = try RPCFixture(silenceIdentityRead: true)
        defer { fixture.stop() }
        let client = CodexRuntimeClient(socketPath: fixture.socketPath)
        defer { Task { await client.close() } }
        _ = try await client.initialize(expectedHome: "/home")
        do {
            _ = try await client.readIdentity(expectedHome: "/home")
            XCTFail("an unanswered RPC should time out")
        } catch {
            // The timeout is intentionally surfaced without transport details.
        }
    }

    func testOversizedWebSocketMessageFailsPendingRPC() async throws {
        let fixture = try RPCFixture(oversizedOnIdentityRead: true)
        defer { fixture.stop() }
        let client = CodexRuntimeClient(socketPath: fixture.socketPath)
        defer { Task { await client.close() } }
        _ = try await client.initialize(expectedHome: "/home")
        do {
            _ = try await client.readIdentity(expectedHome: "/home")
            XCTFail("messages above the aggregate cap must fail")
        } catch {
            // The peer is closed without exposing the oversized payload.
        }
    }

    func testInitializeRejectsMismatchedServerHome() async throws {
        let fixture = try RPCFixture(reportedHome: "/home/other")
        defer { fixture.stop() }
        let client = CodexRuntimeClient(socketPath: fixture.socketPath)
        defer { Task { await client.close() } }
        do {
            _ = try await client.initialize(expectedHome: "/home/expected")
            XCTFail("identity must use the server-reported home")
        } catch {
            XCTAssertFalse(fixture.observedMethods.contains("initialized"))
        }
    }

    func testInitializeRejectsMissingServerHome() async throws {
        let fixture = try RPCFixture(omitReportedHome: true)
        defer { fixture.stop() }
        let client = CodexRuntimeClient(socketPath: fixture.socketPath)
        defer { Task { await client.close() } }
        do {
            _ = try await client.initialize(expectedHome: "/home")
            XCTFail("identity must be inconclusive when the server omits its home")
        } catch {
            XCTAssertFalse(fixture.observedMethods.contains("initialized"))
        }
    }

    func testOptInLiveReadOnlyIdentityProbe() async throws {
        guard let home = ProcessInfo.processInfo.environment["DOPPEL_REMOTE_PROBE_HOME"] else {
            throw XCTSkip("Set DOPPEL_REMOTE_PROBE_HOME to an isolated trial CODEX_HOME to probe it.")
        }
        let socket = URL(fileURLWithPath: home)
            .appendingPathComponent("app-server-control/app-server-control.sock").path
        let client = CodexRuntimeClient(socketPath: socket)
        let identity: RuntimeIdentity
        do {
            identity = try await client.initialize(expectedHome: home)
            await client.close()
        } catch {
            await client.close()
            throw error
        }
        let expectedHome = URL(fileURLWithPath: home).standardizedFileURL.resolvingSymlinksInPath().path
        let hasChatGPT = identity.isChatGPT
        let hasWorkspace = identity.codexHome == expectedHome && identity.accountId != nil
        print("DOPPEL_REMOTE_PROBE {\"hasChatGPT\":\(hasChatGPT),\"hasWorkspace\":\(hasWorkspace)}")
        XCTAssertTrue(identity.codexHome == expectedHome)
    }
}

private final class RPCFixture: @unchecked Sendable {
    let socketPath = "/tmp/dprpc-\(UUID().uuidString.prefix(8))"
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private var server: Channel!
    private let lock = NSLock()
    private var methods: [String] = []
    private let disconnectOnIdentityRead: Bool
    private let malformedOnIdentityRead: Bool
    private let silenceIdentityRead: Bool
    private let oversizedOnIdentityRead: Bool
    private let reportedHome: String
    private let omitReportedHome: Bool
    private let completionOnCancel: Bool
    private var websocketChannel: Channel?
    private var loginCompleted = false
    private var didAcknowledgeCancel = false
    private var pendingReads: [(ChannelHandlerContext, Int)] = []

    var observedMethods: [String] { lock.withLock { methods } }
    var cancelReplyAcknowledged: Bool { lock.withLock { didAcknowledgeCancel } }

    init(disconnectOnIdentityRead: Bool = false, malformedOnIdentityRead: Bool = false,
         silenceIdentityRead: Bool = false, oversizedOnIdentityRead: Bool = false,
         reportedHome: String = "/home", omitReportedHome: Bool = false,
         completionOnCancel: Bool = false) throws {
        self.disconnectOnIdentityRead = disconnectOnIdentityRead
        self.malformedOnIdentityRead = malformedOnIdentityRead
        self.silenceIdentityRead = silenceIdentityRead
        self.oversizedOnIdentityRead = oversizedOnIdentityRead
        self.reportedHome = reportedHome
        self.omitReportedHome = omitReportedHome
        self.completionOnCancel = completionOnCancel
        let upgrader = NIOWebSocketServerUpgrader(
            maxFrameSize: 1 << 20,
            shouldUpgrade: { channel, _ in channel.eventLoop.makeSucceededFuture(HTTPHeaders()) },
            upgradePipelineHandler: { [weak self] channel, _ in
                guard let self else { return channel.eventLoop.makeFailedFuture(FixtureError.stopped) }
                return channel.pipeline.addHandler(FixtureWebSocketHandler(fixture: self))
            })
        let config: NIOHTTPServerUpgradeSendableConfiguration = (
            upgraders: [upgrader], completionHandler: { _ in })
        server = try ServerBootstrap(group: group)
            .childChannelInitializer { channel in channel.pipeline.configureHTTPServerPipeline(withServerUpgrade: config) }
            .bind(unixDomainSocketPath: socketPath).wait()
    }

    func stop() {
        if let server { try? server.close().wait() }
        try? group.syncShutdownGracefully()
    }

    fileprivate func receive(_ object: [String: Any], context: ChannelHandlerContext) {
        lock.withLock { websocketChannel = context.channel }
        guard let method = object["method"] as? String, let id = object["id"] as? Int else {
            if let method = object["method"] as? String { lock.withLock { methods.append(method) } }
            return
        }
        lock.withLock { methods.append(method) }
        switch method {
        case "initialize":
            var result: [String: Any] = ["userAgent": "codex/fixture-version (Mac OS; arm64) terminal", "platformFamily": "unix", "platformOs": "macos"]
            if !omitReportedHome { result["codexHome"] = reportedHome }
            respond(context, id: id, result: result)
        case "account/read":
            let readCount = lock.withLock { methods.filter { $0 == "account/read" }.count }
            if readCount > 1 && disconnectOnIdentityRead { context.close(promise: nil); return }
            if readCount > 1 && malformedOnIdentityRead {
                let buffer = context.channel.allocator.buffer(string: "not-json")
                context.writeAndFlush(NIOAny(WebSocketFrame(fin: true, opcode: .text, data: buffer)), promise: nil)
                return
            }
            if readCount > 1 && silenceIdentityRead { return }
            if readCount > 1 && oversizedOnIdentityRead {
                let large = String(repeating: "x", count: (1 << 20) + 1)
                respond(context, id: id, result: ["account": ["type": "chatgpt", "email": large]])
                return
            }
            if readCount > 1 && lock.withLock({ loginCompleted }) {
                respond(context, id: id, result: [
                    "account": ["type": "chatgpt", "email": "completed@example.test"],
                    "workspaceRouting": ["chatgptAccountId": "account-completed"],
                ])
                return
            }
            if readCount == 1 {
                respond(context, id: id, result: [
                    "account": ["type": "chatgpt", "email": "initial@example.test"],
                    "workspaceRouting": ["chatgptAccountId": "account-initial"],
                ])
                return
            }
            pendingReads.append((context, id))
            if pendingReads.count == 2 {
                let requests = pendingReads.reversed()
                for (index, request) in requests.enumerated() {
                    let email = index == 0 ? "two@example.test" : "one@example.test"
                    let accountID = index == 0 ? "account-two" : "account-one"
                    respond(request.0, id: request.1, result: [
                        "account": ["type": "chatgpt", "email": email],
                        "workspaceRouting": ["chatgptAccountId": accountID],
                    ])
                }
                pendingReads.removeAll()
            }
        case "account/login/start":
            respond(context, id: id, result: ["loginId": "login-1", "verificationUrl": "https://example.test/device", "userCode": "SAFE-CODE"])
        case "account/login/cancel":
            if completionOnCancel { writeLoginCompletion(context, loginId: "login-1", success: true) }
            lock.withLock { didAcknowledgeCancel = true }
            respond(context, id: id, result: [:])
        default: respond(context, id: id, result: [:])
        }
    }

    func completeLogin(loginId: String, success: Bool) {
        guard let channel = lock.withLock({ websocketChannel }) else { return }
        channel.eventLoop.execute {
            self.writeLoginCompletion(channel: channel, loginId: loginId, success: success)
        }
    }

    private func writeLoginCompletion(_ context: ChannelHandlerContext, loginId: String, success: Bool) {
        lock.withLock { loginCompleted = true }
        guard let bytes = try? JSONSerialization.data(withJSONObject: [
            "method": "account/login/completed",
            "params": ["loginId": loginId, "success": success],
        ]) else { return }
        var buffer = context.channel.allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        context.writeAndFlush(NIOAny(WebSocketFrame(fin: true, opcode: .text, data: buffer)), promise: nil)
    }

    private func writeLoginCompletion(channel: Channel, loginId: String, success: Bool) {
        lock.withLock { loginCompleted = true }
        guard let bytes = try? JSONSerialization.data(withJSONObject: [
            "method": "account/login/completed",
            "params": ["loginId": loginId, "success": success],
        ]) else { return }
        var buffer = channel.allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        channel.writeAndFlush(WebSocketFrame(fin: true, opcode: .text, data: buffer), promise: nil)
    }

    private func respond(_ context: ChannelHandlerContext, id: Int, result: [String: Any]) {
        guard let bytes = try? JSONSerialization.data(withJSONObject: ["id": id, "result": result]) else { return }
        var buffer = context.channel.allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        context.writeAndFlush(NIOAny(WebSocketFrame(fin: true, opcode: .text, data: buffer)), promise: nil)
    }

    private enum FixtureError: Error { case stopped }
}

private final class FixtureWebSocketHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame
    private let fixture: RPCFixture
    init(fixture: RPCFixture) { self.fixture = fixture }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        guard frame.opcode == .text,
              let object = try? JSONSerialization.jsonObject(with: Data(frame.unmaskedData.readableBytesView)) as? [String: Any] else { return }
        fixture.receive(object, context: context)
    }
}
