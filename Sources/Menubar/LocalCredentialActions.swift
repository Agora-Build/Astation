import AppKit
import LocalAuthentication

final class LocalCredentialActions {
    typealias Authenticate = (String, @escaping (Bool) -> Void) -> (() -> Void)
    private let account: () -> String
    private let authenticate: Authenticate
    private var attempt: UUID?
    private var cancelAuthentication: (() -> Void)?
    private var finishCancellation: (() -> Void)?
    var isBusy: Bool { attempt != nil }

    init(account: @escaping () -> String, authenticate: @escaping Authenticate = LocalCredentialActions.touchID) {
        self.account = account
        self.authenticate = authenticate
    }

    static func touchID(reason: String, completion: @escaping (Bool) -> Void) -> (() -> Void) {
        let context = LAContext()
        context.localizedFallbackTitle = ""
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            DispatchQueue.main.async { completion(false) }
            return { context.invalidate() }
        }
        context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { accepted, _ in
            DispatchQueue.main.async { completion(accepted) }
        }
        return { context.invalidate() }
    }

    func perform<T>(account expected: String, reason: String, operation: @escaping () throws -> T,
                    completion: @escaping (Result<T, Error>) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !isBusy else { completion(.failure(LocalCredentialError.busy)); return }
        guard account() == expected else { completion(.failure(LocalCredentialError.accountChanged)); return }
        let id = UUID()
        attempt = id
        finishCancellation = { completion(.failure(LocalCredentialError.denied)) }
        let cancel = authenticate(reason) { [weak self] accepted in
            guard let self, self.attempt == id else { return }
            self.attempt = nil
            self.finishCancellation = nil
            self.cancelAuthentication = nil
            guard accepted else { completion(.failure(LocalCredentialError.denied)); return }
            guard self.account() == expected else { completion(.failure(LocalCredentialError.accountChanged)); return }
            do { completion(.success(try operation())) } catch { completion(.failure(error)) }
        }
        if attempt == id { cancelAuthentication = cancel } else { cancel() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 180) { [weak self] in
            guard self?.attempt == id else { return }
            self?.cancel()
        }
    }

    func cancel() {
        attempt = nil
        let cancel = cancelAuthentication, completion = finishCancellation
        cancelAuthentication = nil
        finishCancellation = nil
        cancel?()
        completion?()
    }
}

final class CredentialClipboard {
    static let shared = CredentialClipboard()
    private let pasteboard: NSPasteboard
    private var writtenChangeCount: Int?
    private var terminationObserver: NSObjectProtocol?

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main) { [weak self] _ in self?.clear() }
    }

    deinit {
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
    }

    func copy(_ value: String, schedule: (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }) {
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        let changeCount = pasteboard.changeCount
        writtenChangeCount = changeCount
        schedule(30) { [weak self] in
            guard self?.writtenChangeCount == changeCount else { return }
            self?.clear()
        }
    }

    func clear() {
        if let writtenChangeCount, pasteboard.changeCount == writtenChangeCount { pasteboard.clearContents() }
        writtenChangeCount = nil
    }
}
