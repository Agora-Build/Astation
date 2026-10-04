enum EncryptionDisableAction {
    static func request(
        authenticate: (@escaping (Bool) -> Void) -> Void = {
            DeviceOwnerAuth.authenticate(reason: "turn off end-to-end encryption", completion: $0)
        },
        confirm: @escaping () -> Bool,
        disable: @escaping () -> Void
    ) {
        authenticate { authenticated in
            guard authenticated, confirm() else { return }
            disable()
        }
    }
}
