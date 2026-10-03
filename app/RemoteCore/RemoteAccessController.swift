import Foundation
import Darwin

public final class RemoteAccessController {
    public let store: RemoteConfigurationStore
    public let profile: RemoteProfileContext
    private let fm = FileManager.default

    public init(store: RemoteConfigurationStore, profile: RemoteProfileContext) {
        self.store = store; self.profile = profile
    }

    private func configuration() throws -> RemoteConfiguration {
        guard let config = try store.find(profileSlug: profile.slug) else {
            throw RemoteAccessError("Choose a private network address before setting up Remote Access.")
        }
        guard config.profileDirectory == profile.profileDirectory, config.desktopHome == profile.desktopHome else {
            throw RemoteAccessError("The profile's data paths changed. Its remote setup must be checked before enabling access.")
        }
        try store.validate(URL(fileURLWithPath: config.profileDirectory))
        try store.validate(URL(fileURLWithPath: config.profileDirectory).appendingPathComponent("instance-config.zsh"))
        return config
    }

    public func configure(address: String, host: String?) throws {
        let operation = try store.find(profileSlug: profile.slug).map { try store.acquireLock(id: $0.remoteId) }
        defer { operation?.release() }
        guard RemoteNetworkAddress.available().contains(where: { $0.address == address }) else {
            throw RemoteAccessError("Select a private IPv4 address currently assigned to this Mac.")
        }
        let connectionHost = host?.trimmingCharacters(in: .whitespacesAndNewlines) ?? address
        guard !connectionHost.isEmpty, connectionHost.utf8.count <= 253,
              connectionHost.range(of: "^[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$", options: .regularExpression) != nil else {
            throw RemoteAccessError("Enter a private IP address or a valid hostname.")
        }
        if connectionHost != address { try validateHostname(connectionHost, address: address) }
        _ = try store.create(profileSlug: profile.slug, profileDirectory: profile.profileDirectory,
                             desktopHome: profile.desktopHome, bindAddress: address, connectionHost: connectionHost)
    }

    private func validateHostname(_ host: String, address: String) throws {
        var hints = addrinfo(); hints.ai_family = AF_INET; hints.ai_socktype = SOCK_STREAM
        var first: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &first) == 0 else {
            throw RemoteAccessError("The hostname does not resolve. Use the selected private IP address instead.")
        }
        defer { freeaddrinfo(first) }
        var matched = false; var next = first
        while let entry = next {
            defer { next = entry.pointee.ai_next }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var value = entry.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            if inet_ntop(AF_INET, &value, &buffer, socklen_t(buffer.count)) != nil,
               String(cString: buffer) == address { matched = true }
        }
        guard matched else { throw RemoteAccessError("The hostname must resolve to the selected private Mac address.") }
    }

    private func codex(_ config: RemoteConfiguration) throws -> URL {
        let home = try store.home(config.remoteId)
        for suffix in ["packages/app-server-daemon/current/bin/codex", "packages/standalone/current/bin/codex",
                       "packages/standalone/current/codex"] {
            let candidate = home.appendingPathComponent(suffix)
            if fm.isExecutableFile(atPath: candidate.path) {
                let resolved = candidate.resolvingSymlinksInPath()
                guard resolved.path.hasPrefix(home.path + "/packages/") else {
                    throw RemoteAccessError("The managed runtime points outside this remote home.")
                }
                try store.validate(resolved); return resolved
            }
        }
        let candidate = URL(fileURLWithPath: profile.primaryApp)
            .appendingPathComponent("Contents/Resources/codex-cli/bin/codex")
        guard fm.isExecutableFile(atPath: candidate.path) else {
            throw RemoteAccessError("Install the current ChatGPT desktop app before setting up Remote Access.")
        }
        return candidate
    }

    private func runtimeEnvironment(_ config: RemoteConfiguration) throws -> [String: String] {
        let binary = try codex(config)
        return RemoteSystem.environment(home: try store.home(config.remoteId), installDirectory: binary.deletingLastPathComponent())
    }

    private func ensureRuntime(_ config: RemoteConfiguration) throws {
        let home = try store.home(config.remoteId)
        try store.validate(home, privateMode: true)
        let configFile = home.appendingPathComponent("config.toml")
        if !fm.fileExists(atPath: configFile.path) {
            try store.write(Data("cli_auth_credentials_store = \"file\"\nforced_login_method = \"chatgpt\"\n".utf8), to: configFile)
        }
        try store.validate(configFile, privateMode: true)
        let daemonDirectory = home.appendingPathComponent("app-server-daemon")
        if !fm.fileExists(atPath: daemonDirectory.path) {
            try fm.createDirectory(at: daemonDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        try store.validate(daemonDirectory, privateMode: true)
        let settings = daemonDirectory.appendingPathComponent("settings.json")
        var value: [String: Any] = ["remoteControlEnabled": false, "shutdownGraceSeconds": 60]
        if fm.fileExists(atPath: settings.path) {
            try store.validate(settings, privateMode: true)
            value = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any] ?? value
        }
        var updater = value["updater"] as? [String: Any] ?? [:]
        updater["autoUpdateEnabled"] = false; value["updater"] = updater
        try store.write(JSONSerialization.data(withJSONObject: value), to: settings)
        let binary = try codex(config)
        let seed = binary.path.hasPrefix(profile.primaryApp + "/")
        if seed {
            let requirement = "anchor apple generic and identifier \"com.openai.codex\" and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = \"2DC432GLL2\""
            _ = try RemoteSystem.requireSuccess("/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R", "=" + requirement, profile.primaryApp],
                message: "The installed ChatGPT app did not pass the OpenAI signature check.")
        }
        _ = try RemoteSystem.requireSuccess(binary.path, ["app-server", "daemon", seed ? "bootstrap" : "start"],
            environment: try runtimeEnvironment(config),
            message: "Codex could not start its isolated runtime. Check installation, managed requirements and credential-storage policy.")
    }

    private func client(_ config: RemoteConfiguration) throws -> CodexRuntimeClient {
        CodexRuntimeClient(socketPath: try store.home(config.remoteId)
            .appendingPathComponent("app-server-control/app-server-control.sock").path)
    }

    private func identity(_ config: RemoteConfiguration) async throws -> RuntimeIdentity {
        let rpc = try client(config)
        do {
            let value = try await rpc.initialize(expectedHome: store.home(config.remoteId).path)
            await rpc.close(); return value
        } catch {
            await rpc.close()
            throw RemoteAccessError("Could not verify this runtime's live account and workspace. Check Again or sign in.")
        }
    }

    private func requireIdentity(_ identity: RuntimeIdentity, configuration config: RemoteConfiguration,
                                 allowUnconfirmed: Bool = false) throws {
        guard identity.isChatGPT, let account = identity.accountId, !account.isEmpty,
              let email = identity.email, !email.isEmpty else {
            throw RemoteAccessError("Sign in with ChatGPT. This runtime must expose its active workspace before access can be enabled.")
        }
        let home = try store.home(config.remoteId)
        let credentialFile = home.appendingPathComponent("auth.json")
        try store.validate(credentialFile, privateMode: true)
        let stored = savedAccount(home: home)
        guard stored.id == account, stored.email?.caseInsensitiveCompare(email) == .orderedSame else {
            throw RemoteAccessError("Isolated file-based ChatGPT credentials could not be verified. Check your organization's credential-storage requirements.")
        }
        if let expected = config.expectedAccountId {
            guard account == expected else { throw RemoteAccessError("The remote workspace changed. Access is blocked; sign in to the intended account.") }
        } else if !allowUnconfirmed { throw RemoteAccessError("Confirm the remote account by enabling access in Doppel.") }
        if let expected = config.expectedEmail, email.caseInsensitiveCompare(expected) != .orderedSame {
            throw RemoteAccessError("The remote account changed. Access is blocked; sign in to the intended account.")
        }
        let desktop = savedAccount(home: URL(fileURLWithPath: config.desktopHome))
        if let expected = desktop.id,
           expected != account {
            throw RemoteAccessError("The remote workspace does not match this desktop profile. Sign in to the matching account.")
        }
        if let expected = desktop.email, email.caseInsensitiveCompare(expected) != .orderedSame {
            throw RemoteAccessError("The remote account does not match this desktop profile. Sign in to the matching account.")
        }
    }

    private func savedAccount(home: URL) -> (id: String?, email: String?) {
        // This is an expectation/display hint only. Live RPC identity remains
        // authoritative, and no token is copied to the remote home.
        let path = home.appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: path), data.count <= 1_048_576,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = json["tokens"] as? [String: Any] else { return (nil, nil) }
        var claims: [String: Any] = [:]
        if let token = tokens["id_token"] as? String, token.split(separator: ".").count == 3 {
            var payload = String(token.split(separator: ".")[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
            if let decoded = Data(base64Encoded: payload), let object = try? JSONSerialization.jsonObject(with: decoded) as? [String: Any] { claims = object }
        }
        let scope = claims["https://api.openai.com/auth"] as? [String: Any]
        return (tokens["account_id"] as? String ?? scope?["chatgpt_account_id"] as? String, claims["email"] as? String)
    }

    public func login(emit: @escaping (DeviceLogin) -> Void) async throws {
        let operation = try store.acquireLock(id: configuration().remoteId)
        defer { operation.release() }
        let config = try configuration()
        guard !config.enabled else { throw RemoteAccessError("Disable Remote Access before changing its account.") }
        try ensureRuntime(config)
        let rpc = try client(config)
        do {
            _ = try await rpc.initialize(expectedHome: store.home(config.remoteId).path)
            let login = try await rpc.beginDeviceLogin()
            guard let url = URL(string: login.verificationUrl), url.scheme == "https", url.host == "auth.openai.com" else {
                try await rpc.cancelLogin(loginId: login.loginId)
                throw RemoteAccessError("Codex returned an unexpected verification address. Sign-in was cancelled.")
            }
            emit(login)
            try await rpc.waitForLogin(loginId: login.loginId)
            let result = try await rpc.readIdentity(expectedHome: store.home(config.remoteId).path)
            // Signing in on a disabled profile is an explicit account change, so
            // the old pin no longer applies. The desktop match is still enforced,
            // and Enable pins the account the user confirms next.
            var unpinned = config
            unpinned.expectedAccountId = nil
            unpinned.expectedEmail = nil
            try requireIdentity(result, configuration: unpinned, allowUnconfirmed: true)
            if config.expectedAccountId != nil || config.expectedEmail != nil { try store.save(unpinned) }
            await rpc.close()
        } catch {
            await rpc.close()
            if let message = CodexRuntimeClient.safeErrorMessage(error) { throw RemoteAccessError(message) }
            throw error
        }
    }

    public func status() async -> RemoteAccessStatus {
        let networks = RemoteNetworkAddress.available()
        var config: RemoteConfiguration?
        var live: RuntimeIdentity?
        var state = "notConfigured", detail: String?
        do {
            config = try store.find(profileSlug: profile.slug)
            if let config {
                _ = try configuration()
                state = config.enabled ? "blocked" : "disabled"
                let socket = try store.home(config.remoteId).appendingPathComponent("app-server-control/app-server-control.sock")
                if fm.fileExists(atPath: socket.path) {
                    live = try await identity(config)
                    if let live, live.isChatGPT {
                        try requireIdentity(live, configuration: config, allowUnconfirmed: !config.enabled)
                    } else if config.enabled {
                        throw RemoteAccessError("The active remote account is missing. Sign in before enabling access.")
                    }
                }
                if !config.enabled && config.expectedAccountId == nil && live?.accountId == nil { state = "signInRequired" }
                if config.enabled {
                    if !networks.contains(where: { $0.address == config.bindAddress }) { state = "networkUnavailable" }
                    else if live == nil { detail = "The remote daemon is not responding." }
                    else if try listenerAlive(config) { state = "ready" }
                    else { detail = "The SSH listener is not running. Disable and enable this profile to retry." }
                }
            }
        } catch { state = "blocked"; detail = (error as? RemoteAccessError)?.message ?? "Could not inspect remote setup safely." }
        let saved = config.flatMap { try? store.home($0.remoteId) }.map { savedAccount(home: $0) }
        let fingerprint = config.flatMap { try? hostFingerprint($0) }
        return .init(profileSlug: profile.slug, remoteId: config?.remoteId, state: state,
            enabled: config?.enabled ?? false, host: config?.connectionHost, bindAddress: config?.bindAddress,
            port: config?.port, username: RemoteSystem.username, email: live?.email ?? saved?.email,
            accountId: live?.accountId ?? saved?.id, runtimeVersion: live?.appServerVersion,
            hostKeyFingerprint: fingerprint, checkedAt: live?.accountId == nil ? nil : Date(), detail: detail, networks: networks)
    }

    private func preflightShell(_ config: RemoteConfiguration) throws {
        for flags in [["-l", "-i", "-c"], ["-c"]] {
            let output = try RemoteSystem.requireSuccess(RemoteSystem.shell,
                flags + ["printf '%s' \"$CODEX_HOME\""], environment: try runtimeEnvironment(config),
                message: "Your login shell could not be checked. Remote Access requires a working login shell.", timeout: 8)
            guard String(data: output, encoding: .utf8) == (try store.home(config.remoteId).path) else {
                throw RemoteAccessError("Your shell changes CODEX_HOME or prints startup output. Remove that override/output from shell initialization before enabling Remote Access.")
            }
        }
    }

    private func ensureKeys(_ config: RemoteConfiguration) throws {
        let dir = try store.directory(config.remoteId)
        let client = dir.appendingPathComponent("client-key.pem")
        if try !store.validateIfPresent(client, privateMode: true) {
            _ = try store.validateIfPresent(client.appendingPathExtension("pub"))
            try Self.generatePhoneKey(at: client)
            let generatedPublic = client.appendingPathExtension("pub")
            try store.write(Data(contentsOf: generatedPublic), to: dir.appendingPathComponent("client-key.pub"))
        }
        try store.validate(client, privateMode: true)
        let bytes = try Data(contentsOf: client)
        let text = String(data: bytes, encoding: .utf8) ?? ""
        guard text.hasPrefix("-----BEGIN EC PRIVATE KEY-----") || text.hasPrefix("-----BEGIN PRIVATE KEY-----") else {
            throw RemoteAccessError("The phone key is not ECDSA PEM.")
        }
        let derived = try RemoteSystem.requireSuccess("/usr/bin/ssh-keygen", ["-y", "-f", client.path], message: "The phone key could not be validated.")
        let publicFile = dir.appendingPathComponent("client-key.pub")
        try store.validate(publicFile, privateMode: true)
        func fields(_ data: Data) -> [Substring] { String(decoding: data, as: UTF8.self).split(whereSeparator: \.isWhitespace).prefix(2).map { $0 } }
        guard fields(derived) == fields(try Data(contentsOf: publicFile)) else { throw RemoteAccessError("The phone key does not match its authorization.") }
        let host = dir.appendingPathComponent("host-key")
        if try !store.validateIfPresent(host, privateMode: true) {
            _ = try store.validateIfPresent(host.appendingPathExtension("pub"))
            _ = try RemoteSystem.requireSuccess("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", host.path], message: "Could not generate the SSH host key.")
        }
        try store.validate(host, privateMode: true)
    }

    static func generatePhoneKey(at path: URL) throws {
        _ = try RemoteSystem.requireSuccess("/usr/bin/ssh-keygen", ["-q", "-t", "ecdsa", "-b", "256", "-m", "PKCS8", "-N", "", "-f", path.path],
            message: "Could not generate the phone's PEM key.")
        try encodePhoneKey(at: path)
    }

    static func encodePhoneKey(at path: URL) throws {
        _ = try RemoteSystem.requireSuccess("/usr/bin/ssh-keygen", ["-p", "-m", "PKCS8", "-P", "", "-N", "", "-f", path.path],
            message: "Could not encode the phone key as PKCS8 PEM.")
    }

    private func hostFingerprint(_ config: RemoteConfiguration) throws -> String {
        let path = try store.directory(config.remoteId).appendingPathComponent("host-key.pub")
        try store.validate(path)
        let output = try RemoteSystem.requireSuccess("/usr/bin/ssh-keygen", ["-l", "-E", "sha256", "-f", path.path], message: "Could not read the host fingerprint.")
        let fields = String(decoding: output, as: UTF8.self).split(whereSeparator: \.isWhitespace)
        guard fields.count >= 2 else { throw RemoteAccessError("The host fingerprint is unavailable.") }
        return String(fields[1])
    }

    private func jobURL(_ config: RemoteConfiguration) -> URL {
        fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/ai.doppel.remote.\(config.remoteId).plist")
    }

    private func service(_ config: RemoteConfiguration) -> String { "gui/\(getuid())/ai.doppel.remote.\(config.remoteId)" }

    private func writeListenerConfiguration(_ config: RemoteConfiguration) throws {
        let dir = try store.directory(config.remoteId)
        let command = [profile.cliPath, "remote", "__session", profile.slug].map(RemoteSystem.shellQuote).joined(separator: " ")
        func sshPath(_ name: String) -> String {
            "\"" + dir.appendingPathComponent(name).path.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let text = """
        AddressFamily inet
        ListenAddress \(config.bindAddress):\(config.port)
        HostKey \(sshPath("host-key"))
        PidFile \(sshPath("sshd.pid"))
        AuthorizedKeysFile \(sshPath("authorized_keys"))
        ForceCommand \(command)
        AuthenticationMethods publickey
        PasswordAuthentication no
        KbdInteractiveAuthentication no
        PermitRootLogin no
        AllowUsers \(RemoteSystem.username)
        AllowAgentForwarding no
        AllowTcpForwarding no
        AllowStreamLocalForwarding no
        X11Forwarding no
        PermitTunnel no
        PermitTTY no
        PermitUserEnvironment no
        PermitUserRC no
        LogLevel ERROR
        """ + "\n"
        try store.write(Data(text.utf8), to: dir.appendingPathComponent("sshd_config"))
        _ = try RemoteSystem.requireSuccess("/usr/sbin/sshd", ["-t", "-f", dir.appendingPathComponent("sshd_config").path],
                                           message: "This Mac's SSH server rejected the secure listener configuration.")
    }

    public func enable(expectedAccountId: String? = nil, expectedEmail: String? = nil) async throws {
        let operation = try store.acquireLock(id: configuration().remoteId)
        defer { operation.release() }
        var config = try configuration()
        guard RemoteNetworkAddress.available().contains(where: { $0.address == config.bindAddress }) else {
            throw RemoteAccessError("The selected private address is not currently available.")
        }
        if config.enabled, try listenerAlive(config) {
            let live = try await identity(config)
            try requireIdentity(live, configuration: config)
            if let expectedAccountId, expectedAccountId != live.accountId {
                throw RemoteAccessError("The remote identity changed since confirmation. Check Again before enabling.")
            }
            if let expectedEmail, live.email?.caseInsensitiveCompare(expectedEmail) != .orderedSame {
                throw RemoteAccessError("The remote identity changed since confirmation. Check Again before enabling.")
            }
            return
        }
        guard RemoteConfigurationStore.portAvailable(config.port, address: config.bindAddress) else {
            throw RemoteAccessError("This profile's port is occupied. Free that port before enabling; the endpoint was not changed.")
        }
        try ensureRuntime(config)
        let live = try await identity(config)
        try requireIdentity(live, configuration: config, allowUnconfirmed: true)
        if let expectedAccountId, expectedAccountId != live.accountId {
            throw RemoteAccessError("The remote identity changed since confirmation. Check Again before enabling.")
        }
        if let expectedEmail, live.email?.caseInsensitiveCompare(expectedEmail) != .orderedSame {
            throw RemoteAccessError("The remote identity changed since confirmation. Check Again before enabling.")
        }
        try preflightShell(config); try ensureKeys(config); try writeListenerConfiguration(config)
        config.expectedAccountId = live.accountId
        config.expectedEmail = live.email
        let dir = try store.directory(config.remoteId)
        let publicKey = try Data(contentsOf: dir.appendingPathComponent("client-key.pub"))
        try store.write(Data("restrict ".utf8) + publicKey, to: dir.appendingPathComponent("authorized_keys"))
        let job = jobURL(config)
        if !fm.fileExists(atPath: job.deletingLastPathComponent().path) {
            try fm.createDirectory(at: job.deletingLastPathComponent(), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        let plist: [String: Any] = ["Label": "ai.doppel.remote.\(config.remoteId)",
            "ProgramArguments": ["/bin/zsh", profile.cliPath, "remote", "__serve", profile.slug],
            "RunAtLoad": true, "KeepAlive": true, "ThrottleInterval": 30,
            "ProcessType": "Standard", "Umask": 0o077]
        try store.write(PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0), to: job)
        config.enabled = true; try store.save(config)
        do {
            _ = try RemoteSystem.run("/bin/launchctl", ["enable", service(config)], timeout: 8)
            _ = try RemoteSystem.requireSuccess("/bin/launchctl", ["bootstrap", "gui/\(getuid())", job.path],
                                               message: "Could not register this profile's background listener.", timeout: 8)
        } catch {
            config.enabled = false; try store.save(config)
            try store.write(Data(), to: dir.appendingPathComponent("authorized_keys"))
            _ = try? RemoteSystem.run("/bin/launchctl", ["disable", service(config)], timeout: 8)
            throw error
        }
        // The LaunchAgent acquires this lock before starting sshd.
        operation.release()
        let deadline = Date().addingTimeInterval(8)
        while try !listenerAlive(config) {
            try Task.checkCancellation()
            guard Date() < deadline else {
                throw RemoteAccessError("Remote Access is enabled, but its listener is not ready yet. Check Again shortly.")
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func listenerAlive(_ config: RemoteConfiguration) throws -> Bool {
        try listenerPID(config) != nil
    }

    private func listenerPID(_ config: RemoteConfiguration) throws -> Int32? {
        let path = try store.directory(config.remoteId).appendingPathComponent("sshd.pid")
        guard fm.fileExists(atPath: path.path) else { return nil }
        try store.validate(path, privateMode: true)
        guard let pid = Int32(String(decoding: try Data(contentsOf: path), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1,
              kill(pid, 0) == 0 else { return nil }
        let result = try RemoteSystem.run("/usr/sbin/lsof", ["-a", "-p", String(pid), "-d", "txt", "-Fn"], timeout: 8)
        guard String(decoding: result.output, as: UTF8.self).split(separator: "\n").contains("n/usr/sbin/sshd") else { return nil }
        let sockets = try RemoteSystem.run("/usr/sbin/lsof", ["-nP", "-a", "-p", String(pid), "-iTCP", "-sTCP:LISTEN", "-Fn"], timeout: 8)
        guard String(decoding: sockets.output, as: UTF8.self).split(separator: "\n")
            .contains("n\(config.bindAddress):\(config.port)") else { return nil }
        return pid
    }

    private func sshDescendants(of listener: Int32) throws -> [Int32] {
        let result = try RemoteSystem.run("/bin/ps", ["-axo", "pid=,ppid="], timeout: 8)
        guard result.status == 0 else { throw RemoteAccessError("Could not inspect this listener's sessions. Disable was stopped safely.") }
        let parents = String(decoding: result.output, as: UTF8.self).split(separator: "\n").compactMap { line -> (Int32, Int32)? in
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            guard fields.count == 2, let pid = Int32(fields[0]), let parent = Int32(fields[1]) else { return nil }
            return (pid, parent)
        }
        var descendants: Set<Int32> = [listener]
        while true {
            let next = Set(parents.filter { descendants.contains($0.1) }.map { $0.0 })
            let count = descendants.count; descendants.formUnion(next)
            if descendants.count == count { break }
        }
        descendants.remove(listener)
        return descendants.sorted()
    }

    private func stopSSHTransports(_ candidates: [Int32]) throws {
        for pid in candidates where kill(pid, 0) == 0 {
            let executable = try RemoteSystem.run("/usr/sbin/lsof", ["-a", "-p", String(pid), "-d", "txt", "-Fn"], timeout: 8)
            let paths = Set(String(decoding: executable.output, as: UTF8.self).split(separator: "\n").map(String.init))
            let trusted: Set<String> = ["n/usr/sbin/sshd", "n/usr/libexec/sshd-session", "n/usr/libexec/sshd-auth"]
            if !paths.isDisjoint(with: trusted), kill(pid, SIGTERM) != 0 && errno != ESRCH {
                throw RemoteAccessError("A remote SSH session could not be revoked. Profile removal is blocked.")
            }
        }
    }

    public func disable() throws {
        guard let configured = try store.find(profileSlug: profile.slug) else { return }
        let operation = try store.acquireLock(id: configured.remoteId)
        defer { operation.release() }
        guard var config = try store.find(profileSlug: profile.slug) else { return }
        let dir = try store.directory(config.remoteId)
        let sessions = try listenerPID(config).map { try sshDescendants(of: $0) } ?? []
        config.enabled = false; try store.save(config)
        try store.write(Data(), to: dir.appendingPathComponent("authorized_keys"))
        _ = try RemoteSystem.requireSuccess("/bin/launchctl", ["disable", service(config)], message: "Could not disable the background listener.", timeout: 8)
        _ = try RemoteSystem.run("/bin/launchctl", ["bootout", service(config)], timeout: 8)
        try stopSSHTransports(sessions)
        guard try !listenerAlive(config) else { throw RemoteAccessError("The listener did not stop. Removal is blocked to preserve safe revocation.") }
        let binary = try codex(config)
        _ = try RemoteSystem.requireSuccess(binary.path, ["app-server", "daemon", "stop"],
            environment: try runtimeEnvironment(config), message: "The listener is disabled, but the remote daemon did not stop.", timeout: 75)
    }

    public func exportKey() throws -> Data {
        let operation = try store.acquireLock(id: configuration().remoteId)
        defer { operation.release() }
        let config = try configuration(); try ensureKeys(config)
        let dir = try store.directory(config.remoteId)
        let client = dir.appendingPathComponent("client-key.pem")
        let bytes = try Data(contentsOf: client)
        // A PKCS8 header alone does not guarantee named-curve encoding.
        // Preserve the original and normalize both SEC1 and PKCS8 exports.
        let encoded = dir.appendingPathComponent("client-key-pkcs8.pem")
        try store.write(bytes, to: encoded)
        try Self.encodePhoneKey(at: encoded)
        try store.validate(encoded, privateMode: true)
        let publicKey = try RemoteSystem.requireSuccess("/usr/bin/ssh-keygen", ["-y", "-f", encoded.path], message: "The encoded phone key could not be validated.")
        let expected = try Data(contentsOf: dir.appendingPathComponent("client-key.pub"))
        guard String(decoding: publicKey, as: UTF8.self).split(whereSeparator: \.isWhitespace).prefix(2) ==
              String(decoding: expected, as: UTF8.self).split(whereSeparator: \.isWhitespace).prefix(2) else {
            throw RemoteAccessError("The encoded phone key does not match its authorization.")
        }
        return try Data(contentsOf: encoded)
    }

    public func replaceKey() throws {
        let operation = try store.acquireLock(id: configuration().remoteId)
        defer { operation.release() }
        let config = try configuration()
        guard !config.enabled else { throw RemoteAccessError("Disable this connection before replacing its key.") }
        let dir = try store.directory(config.remoteId)
        let archive = dir.appendingPathComponent("previous-key-\(UUID().uuidString)")
        try fm.createDirectory(at: archive, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        for name in ["client-key.pem", "client-key.pem.pub", "client-key.pub", "client-key-pkcs8.pem"] {
            let path = dir.appendingPathComponent(name)
            if fm.fileExists(atPath: path.path) { try store.validate(path); try fm.moveItem(at: path, to: archive.appendingPathComponent(name)) }
        }
        try store.write(Data(), to: dir.appendingPathComponent("authorized_keys")); try ensureKeys(config)
    }

    public func updateRuntime() throws {
        let operation = try store.acquireLock(id: configuration().remoteId)
        defer { operation.release() }
        let config = try configuration()
        guard !config.enabled else { throw RemoteAccessError("Disable this profile before updating its remote runtime.") }
        _ = try RemoteSystem.requireSuccess(codex(config).path, ["app-server", "daemon", "update"],
            environment: try runtimeEnvironment(config), message: "The managed runtime update failed.", timeout: 600)
    }

    public func remove(purge: Bool) throws {
        guard let config = try store.find(profileSlug: profile.slug) else { return }
        try disable()
        if purge {
            let directory = try store.directory(config.remoteId)
            try store.validateParents(directory)
            try store.validate(directory, privateMode: true)
            try fm.trashItem(at: directory, resultingItemURL: nil)
        }
    }

    public func serve() async throws -> Never {
        let operation = try store.acquireLock(id: configuration().remoteId)
        defer { operation.release() }
        let config = try configuration()
        guard config.enabled else { throw RemoteAccessError("Remote Access is disabled.") }
        guard RemoteNetworkAddress.available().contains(where: { $0.address == config.bindAddress }) else {
            throw RemoteAccessError("The selected private network is unavailable.")
        }
        try ensureRuntime(config)
        try requireIdentity(await identity(config), configuration: config)
        let path = try store.directory(config.remoteId).appendingPathComponent("sshd_config")
        try store.validate(path, privateMode: true)
        try Task.checkCancellation()
        operation.release()
        return try RemoteSystem.execute("/usr/sbin/sshd", ["-D", "-e", "-f", path.path], environment: try runtimeEnvironment(config))
    }

    public func session(originalCommand: String) async throws -> Never {
        guard !originalCommand.isEmpty else { throw RemoteAccessError("Interactive SSH sessions are disabled.") }
        let operation = try store.acquireLock(id: configuration().remoteId)
        defer { operation.release() }
        let config = try configuration()
        guard config.enabled else { throw RemoteAccessError("Remote Access is disabled.") }
        try ensureRuntime(config)
        try requireIdentity(await identity(config), configuration: config)
        try preflightShell(config)
        try Task.checkCancellation()
        operation.release()
        return try RemoteSystem.execute(RemoteSystem.shell, ["-c", originalCommand], environment: try runtimeEnvironment(config))
    }
}
