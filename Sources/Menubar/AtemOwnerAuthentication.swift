import Foundation
import LocalAuthentication

/// The embedded context cannot present password entry; fallback owns a fresh one.
final class AtemOwnerAuthentication {
    private let biometricContext: LAContext
    private let makePasswordContext: () -> LAContext
    private var passwordContext: LAContext?
    private var attempt: UUID?
    private var biometricInvalidated = false
    private var cancelled = false

    init(context: LAContext, makePasswordContext: @escaping () -> LAContext = { LAContext() }) {
        biometricContext = context
        self.makePasswordContext = makePasswordContext
        context.localizedFallbackTitle = ""
        context.touchIDAuthenticationAllowableReuseDuration = 0
    }

    @discardableResult
    func biometrics(reason: String, completion: @escaping (Bool) -> Void) -> Bool {
        guard !cancelled, !biometricInvalidated else { return false }
        return evaluate(biometricContext, policy: .deviceOwnerAuthenticationWithBiometrics,
                        reason: reason, completion: completion)
    }

    @discardableResult
    func password(reason: String, completion: @escaping (Bool) -> Void) -> Bool {
        guard !cancelled else { return false }
        attempt = nil
        invalidateBiometrics()
        passwordContext?.invalidate()
        let context = makePasswordContext()
        passwordContext = context
        context.localizedFallbackTitle = "Use Password..."
        context.touchIDAuthenticationAllowableReuseDuration = 0
        return evaluate(context, policy: .deviceOwnerAuthentication, reason: reason, completion: completion)
    }

    private func evaluate(_ context: LAContext, policy: LAPolicy, reason: String,
                          completion: @escaping (Bool) -> Void) -> Bool {
        var error: NSError?
        guard context.canEvaluatePolicy(policy, error: &error) else { return false }
        let id = UUID()
        attempt = id
        context.evaluatePolicy(policy, localizedReason: reason) { [weak self] accepted, _ in
            DispatchQueue.main.async {
                guard let self, !self.cancelled, self.attempt == id else { return }
                self.attempt = nil
                completion(accepted)
            }
        }
        return true
    }

    func cancel() {
        guard !cancelled else { return }
        cancelled = true
        attempt = nil
        invalidateBiometrics()
        passwordContext?.invalidate()
        passwordContext = nil
    }

    private func invalidateBiometrics() {
        guard !biometricInvalidated else { return }
        biometricInvalidated = true
        biometricContext.invalidate()
    }
}
