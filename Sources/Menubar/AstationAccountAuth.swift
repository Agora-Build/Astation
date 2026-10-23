import AppKit
import AstationRemote
import Foundation
import LocalAuthentication
import NIO
import NIOHTTP1
import Security

struct AccountKeychainStorage: AccountSessionStorage {
    let service: String
    init(service: String = "build.agora.astation.oidc-account-v1") { self.service = service }
    private var query: [String: Any] {
        let context = LAContext(); context.interactionNotAllowed = true
        return [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "account-session", kSecUseDataProtectionKeychain as String: true,
            kSecUseAuthenticationContext as String: context]
    }
    func read() throws -> AccountSessionRecord? {
        var request = query; request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let record = try? PropertyListDecoder().decode(AccountSessionRecord.self, from: data) else { throw AccountLoginError.storage }
        return record
    }
    func write(_ record: AccountSessionRecord?) throws {
        guard let record else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw AccountLoginError.storage }
            return
        }
        let data = try PropertyListEncoder().encode(record)
        let attributes = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; item.removeValue(forKey: kSecUseAuthenticationContext as String)
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw AccountLoginError.storage }
        } else if status != errSecSuccess { throw AccountLoginError.storage }
    }
}

final class AstationAccountAuth: Sendable {
    let configuration: AccountOIDCConfiguration?
    private let client: AccountOIDCClient?
    private let provider: AccountTokenProvider?

    init(environment: [String: String] = ProcessInfo.processInfo.environment,
         info: [String: Any] = Bundle.main.infoDictionary ?? [:], storage: AccountSessionStorage = AccountKeychainStorage(),
         defaults: UserDefaults = .standard) {
        func value(_ env: String, _ key: String) -> String? { environment[env] ?? defaults.string(forKey: key) ?? info[key] as? String }
        if let clientID = value("ASTATION_ACCOUNT_CLIENT_ID", "AstationAccountClientID"),
           let resource = value("ASTATION_ACCOUNT_RESOURCE", "AstationAccountResource"),
           let scope = value("ASTATION_ACCOUNT_SCOPE", "AstationAccountScope"),
           let config = try? AccountOIDCConfiguration(issuer: value("ASTATION_ACCOUNT_ISSUER", "AstationAccountIssuer") ?? AccountServiceSettings.defaultIssuer,
                clientID: clientID, resource: resource, requiredScope: scope) {
            configuration = config
            let oidc = AccountOIDCClient(configuration: config); client = oidc
            provider = AccountTokenProvider(configuration: config, client: oidc, storage: storage)
        } else { configuration = nil; client = nil; provider = nil }
    }

    init(configuration: AccountOIDCConfiguration, storage: AccountSessionStorage) {
        self.configuration = configuration
        let oidc = AccountOIDCClient(configuration: configuration)
        client = oidc
        provider = AccountTokenProvider(configuration: configuration, client: oidc, storage: storage)
    }

    func accessToken() async throws -> String {
        guard let provider else { throw AccountLoginError.configuration }
        return try await provider.validToken()
    }

    func clearSession() async throws { try await provider?.signOut() }

    func accessToken(relayURL: String) async throws -> String {
        guard let configuration, let provider else { throw AccountLoginError.configuration }
        guard configuration.permitsRelay(relayURL) else { throw AccountLoginError.configuration }
        return try await provider.validToken()
    }
    func current() async throws -> AccountSessionRecord? {
        guard let provider else { throw AccountLoginError.configuration }
        return try await provider.current()
    }
    func signOut() async throws {
        guard let provider else { throw AccountLoginError.configuration }
        try await provider.signOut()
    }

    @MainActor func signIn(fresh: Bool = false) async throws {
        guard let client, let provider else { throw AccountLoginError.configuration }
        let generation = try await provider.beginLogin()
        do {
            let attempt = try AccountLoginAttempt()
            let listener = try await AccountLoopbackListener.bind(attempt: attempt)
            let session: AccountLoginSession
            do {
                let redirect = "http://127.0.0.1:\(listener.port)/callback"
                let url = try await client.authorizationURL(attempt: attempt, redirectURI: redirect, fresh: fresh)
                guard NSWorkspace.shared.open(url) else { throw AccountLoginError.unavailable }
                let code = try await listener.code()
                session = try await client.exchange(code: code, attempt: attempt, redirectURI: redirect)
            } catch { await listener.close(); throw error }
            await listener.close()
            try await provider.finishLogin(session, attempt: generation)
        } catch { await provider.cancelLogin(generation); throw error }
    }
}

/// All callbacks, timeouts and cancellation run on this listener's one event loop.
private final class AccountCallbackGate {
    let promise: EventLoopPromise<String>
    var completed = false
    init(_ promise: EventLoopPromise<String>) { self.promise = promise }
    func finish(_ result: Result<String, Error>) {
        guard !completed else { return }; completed = true; promise.completeWith(result)
    }
}

final class AccountLoopbackListener {
    let port: Int
    private let group: MultiThreadedEventLoopGroup
    private let channel: Channel
    private let gate: AccountCallbackGate
    private let timeout: Scheduled<Void>
    private var closed = false
    private init(group: MultiThreadedEventLoopGroup, channel: Channel, gate: AccountCallbackGate, timeout: Scheduled<Void>) {
        self.group = group; self.channel = channel; self.gate = gate; self.timeout = timeout; port = channel.localAddress!.port!
    }
    static func bind(attempt: AccountLoginAttempt, deadline: TimeAmount = .seconds(300)) async throws -> AccountLoopbackListener {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let gate = AccountCallbackGate(group.next().makePromise(of: String.self))
        do {
            let channel = try await ServerBootstrap(group: group).serverChannelOption(ChannelOptions.backlog, value: 4)
                .childChannelInitializer { channel in
                    channel.pipeline.configureHTTPServerPipeline().flatMap {
                        channel.pipeline.addHandler(AccountCallbackHandler(attempt: attempt, gate: gate))
                    }
                }.bind(host: "127.0.0.1", port: 0).get()
            let timeout = gate.promise.futureResult.eventLoop.scheduleTask(in: deadline) { gate.finish(.failure(SsoError.timeout)) }
            return AccountLoopbackListener(group: group, channel: channel, gate: gate, timeout: timeout)
        } catch { try? await group.shutdownGracefully(); throw error }
    }
    func code() async throws -> String {
        try await withTaskCancellationHandler(operation: { try await gate.promise.futureResult.get() }, onCancel: {
            self.gate.promise.futureResult.eventLoop.execute { self.gate.finish(.failure(CancellationError())) }
        })
    }
    func close() async {
        guard !closed else { return }; closed = true
        timeout.cancel()
        await gate.promise.futureResult.eventLoop.submit { self.gate.finish(.failure(CancellationError())) }.getIgnoringFailure()
        try? await channel.close(); try? await group.shutdownGracefully()
    }
}

private final class AccountCallbackHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    let attempt: AccountLoginAttempt
    let gate: AccountCallbackGate
    init(attempt: AccountLoginAttempt, gate: AccountCallbackGate) { self.attempt = attempt; self.gate = gate }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            // Don't let an unfinished body hold the callback channel open.
            let code: String?
            var cancelled = false
            do { code = try attempt.callbackCode(method: head.method.rawValue, uri: head.uri) }
            catch AccountLoginError.cancelled { code = nil; cancelled = !gate.completed }
            catch { code = nil }
            let accepted = !gate.completed && code != nil
            if let code, accepted { gate.finish(.success(code)) }
            if cancelled { gate.finish(.failure(AccountLoginError.cancelled)) }
            let text = accepted ? "Sign-in received. Return to Astation to continue."
                : cancelled ? "Sign-in cancelled. You can return to Astation." : "This is not a valid Astation sign-in callback."
            var headers = HTTPHeaders(); headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
            headers.add(name: "Content-Length", value: String(text.utf8.count)); headers.add(name: "Connection", value: "close")
            headers.add(name: "Cache-Control", value: "no-store"); headers.add(name: "Referrer-Policy", value: "no-referrer")
            context.write(NIOAny(HTTPServerResponsePart.head(HTTPResponseHead(version: head.version, status: accepted || cancelled ? .ok : .badRequest, headers: headers))), promise: nil)
            var buffer = context.channel.allocator.buffer(capacity: text.utf8.count); buffer.writeString(text)
            context.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
            context.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil))).whenComplete { _ in context.close(promise: nil) }
        default: break
        }
    }
}

private extension EventLoopFuture where Value == Void {
    func getIgnoringFailure() async { _ = try? await get() }
}
