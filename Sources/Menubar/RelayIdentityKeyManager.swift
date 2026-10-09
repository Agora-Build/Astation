import Foundation

enum RelayIdentityKeyLoadState {
    case notLoaded
    case loading
    case loaded(RelayIdentityKey)
    case failed(RelayIdentityKeyError)
}

/// Owns key access retries independently of WebSocket reconnects. Main-queue owned.
final class RelayIdentityKeyManager {
    private(set) var state: RelayIdentityKeyLoadState = .notLoaded
    var onChange: ((RelayIdentityKeyLoadState) -> Void)?

    private let loadKey: (Bool) throws -> RelayIdentityKey
    private let repairKey: () throws -> RelayIdentityKey
    private let perform: (@escaping () -> Void) -> Void
    private let deliver: (@escaping () -> Void) -> Void
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private var generation = 0
    private var retryDelay: TimeInterval = 30

    init(
        loadKey: @escaping (Bool) throws -> RelayIdentityKey = {
            try RelayIdentityKey.loadOrCreate(
                storage: KeychainRelayIdentityKeyStorage(allowAuthenticationUI: $0)
            )
        },
        repairKey: @escaping () throws -> RelayIdentityKey = { try RelayIdentityKey.repair() },
        perform: @escaping (@escaping () -> Void) -> Void = {
            DispatchQueue.global(qos: .userInitiated).async(execute: $0)
        },
        deliver: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) },
        schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = {
            DispatchQueue.main.asyncAfter(deadline: .now() + $0, execute: $1)
        }
    ) {
        self.loadKey = loadKey
        self.repairKey = repairKey
        self.perform = perform
        self.deliver = deliver
        self.schedule = schedule
    }

    var isBusy: Bool {
        if case .loading = state { return true }
        return false
    }

    var canRepair: Bool {
        if case .failed(let failure) = state { return failure.allowsRepair }
        return false
    }

    func loadIfNeeded() {
        guard case .notLoaded = state else { return }
        begin { try self.loadKey(false) }
    }

    func retry() {
        guard !isBusy else { return }
        begin { try self.loadKey(true) }
    }

    func repair(completion: @escaping (RelayIdentityKeyError?) -> Void) {
        guard canRepair, !isBusy else {
            completion(.repairNotNeeded)
            return
        }
        begin(operation: repairKey, completion: completion)
    }

    func signingFailed(_ error: Error) {
        generation &+= 1
        finish(.failure(RelayIdentityKeyError.capture(error)))
    }

    private func begin(
        operation: @escaping () throws -> RelayIdentityKey,
        completion: ((RelayIdentityKeyError?) -> Void)? = nil
    ) {
        generation &+= 1
        let expectedGeneration = generation
        state = .loading
        onChange?(state)
        perform { [weak self] in
            let result: Result<RelayIdentityKey, RelayIdentityKeyError>
            do { result = .success(try operation()) }
            catch { result = .failure(RelayIdentityKeyError.capture(error)) }
            self?.deliver { [weak self] in
                guard let self, self.generation == expectedGeneration else { return }
                self.finish(result)
                if case .failure(let failure) = result { completion?(failure) }
                else { completion?(nil) }
            }
        }
    }

    private func finish(_ result: Result<RelayIdentityKey, RelayIdentityKeyError>) {
        switch result {
        case .success(let key):
            retryDelay = 30
            state = .loaded(key)
        case .failure(let failure):
            state = .failed(failure)
            if failure.retriesAutomatically {
                let expectedGeneration = generation
                let delay = retryDelay
                retryDelay = min(300, retryDelay * 2)
                schedule(delay) { [weak self] in
                    guard let self, self.generation == expectedGeneration,
                          case .failed = self.state else { return }
                    self.begin { try self.loadKey(false) }
                }
            }
        }
        onChange?(state)
    }
}

struct RelayIdentityKeyRepairRecord: Equatable {
    let astationId: String
    let relayURL: String
    let operationId: String
    static let defaultsKey = "AstationPendingRelayDeviceKeyRepair"

    init(astationId: String, relayURL: String, operationId: String = UUID().uuidString) {
        self.astationId = astationId
        self.relayURL = StationRelayURL.normalizedBase(relayURL)
        self.operationId = operationId
    }

    static func load(astationId: String, relayURL: String, defaults: UserDefaults) -> Self? {
        guard let record = defaults.dictionary(forKey: defaultsKey),
              let savedId = record["astationId"] as? String,
              let savedRelay = record["relayURL"] as? String,
              let operationId = record["operationId"] as? String,
              savedId == astationId,
              savedRelay == StationRelayURL.normalizedBase(relayURL) else { return nil }
        return Self(astationId: savedId, relayURL: savedRelay, operationId: operationId)
    }

    func save(to defaults: UserDefaults) -> Bool {
        defaults.set(["astationId": astationId, "relayURL": relayURL, "operationId": operationId],
                     forKey: Self.defaultsKey)
        // The pause must reach disk before replacing the Keychain item.
        return defaults.synchronize()
    }

    @discardableResult
    func clear(from defaults: UserDefaults) -> Bool {
        guard Self.load(astationId: astationId, relayURL: relayURL, defaults: defaults) == self else { return false }
        defaults.removeObject(forKey: Self.defaultsKey)
        return defaults.synchronize()
    }

    var resetCommand: String {
        let quotedId = astationId.replacingOccurrences(of: "'", with: "'\\''")
        return "station-relay-server admin forget-key '\(quotedId)'"
    }
}

enum RelayIdentityKeyRepairAction {
    enum Cancellation: Equatable { case notAuthenticated, unavailable, notConfirmed }

    static func request(
        authenticate: (@escaping (Bool) -> Void) -> Void = {
            DeviceOwnerAuth.authenticate(reason: "repair this Mac's relay device key", completion: $0)
        },
        canRepair: @escaping () -> Bool,
        confirm: @escaping () -> Bool,
        repair: @escaping () -> Void,
        cancelled: @escaping (Cancellation) -> Void
    ) {
        guard canRepair() else { cancelled(.unavailable); return }
        var answered = false
        authenticate { authenticated in
            guard !answered else { return }
            answered = true
            guard authenticated else { cancelled(.notAuthenticated); return }
            guard canRepair() else { cancelled(.unavailable); return }
            guard confirm() else { cancelled(.notConfirmed); return }
            guard canRepair() else { cancelled(.unavailable); return }
            repair()
        }
    }
}
