import Foundation
import Combine

@MainActor
final class AndroidDeviceManager: ObservableObject {
    @Published private(set) var devices: [AndroidDevice] = []
    @Published private(set) var addresses: [AndroidNetworkAddress] = []
    @Published var selectedAddressID: String {
        didSet { defaults.set(selectedAddressID, forKey: "androidSharing.address") }
    }
    @Published var portText: String {
        didSet { defaults.set(portText, forKey: "androidSharing.port") }
    }
    @Published private(set) var adbPath: String?
    @Published private(set) var adbVersion = ""
    @Published private(set) var deviceError: String?
    @Published private(set) var sharingError: String?
    @Published private(set) var wirelessMessage: String?
    @Published private(set) var isBusy = false
    @Published private(set) var boundAddress: String?
    @Published private(set) var boundPort: Int?
    @Published private(set) var isReady = false

    var isSharing: Bool { boundPort != nil }
    var endpoint: String? {
        guard let boundAddress, let boundPort else { return nil }
        return "\(boundAddress):\(boundPort)"
    }
    var shellSetup: String? {
        endpoint.map { "export ADB_SERVER_SOCKET=\(AndroidCommands.quote("tcp:" + $0))" }
    }
    var selectedAddress: AndroidNetworkAddress? { addresses.first { $0.id == selectedAddressID } }

    private let defaults: UserDefaults
    private let server: AndroidSharingServer
    private let addressProvider: () -> [AndroidNetworkAddress]
    private var client: ADBClient?
    private var protocolVersion: Int?
    private var monitor: Task<Void, Never>?
    private var networkMonitor: Task<Void, Never>?
    private var operation: Task<Void, Never>?
    private var closed = false

    init(defaults: UserDefaults = .standard, server: AndroidSharingServer = AndroidSharingServer(),
         addressProvider: @escaping () -> [AndroidNetworkAddress] = AndroidNetworkInterfaces.addresses) {
        self.defaults = defaults
        self.server = server
        self.addressProvider = addressProvider
        selectedAddressID = defaults.string(forKey: "androidSharing.address") ?? ""
        portText = defaults.string(forKey: "androidSharing.port") ?? "5038"
        adbPath = ADBClient.discover(saved: defaults.string(forKey: "androidSharing.adbPath"))
    }

    func startMonitoring() {
        guard !closed, networkMonitor == nil else { return }
        networkMonitor = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.addresses = self.addressProvider()
                if self.isSharing, !self.addresses.contains(where: { $0.id == self.selectedAddressID && $0.address == self.boundAddress }) {
                    await self.stopSharing(reason: "The selected network address disappeared. Select an available network address and start sharing again.")
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        beginPolling(allowStart: true)
    }

    private func beginPolling(allowStart: Bool) {
        guard !closed else { return }
        monitor = Task { [weak self] in
            var canStart = allowStart
            while !Task.isCancelled {
                guard let self else { return }
                do { try await self.refresh(allowStart: canStart) }
                catch is CancellationError { return }
                catch {
                    guard !Task.isCancelled else { return }
                    self.isReady = false
                    self.devices = []
                    self.deviceError = error.localizedDescription
                    if self.isSharing { await self.stopSharing(reason: "Local ADB is unavailable. Retry after resolving the device error.") }
                }
                canStart = false
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func refresh(allowStart: Bool) async throws {
        guard let adbPath else { throw AndroidSharingError.message("ADB was not found. Install Android SDK Platform-Tools or choose your adb executable.") }
        let client = ADBClient(executable: adbPath)
        if self.client?.executable != adbPath || protocolVersion == nil {
            let result = try await client.run(["version"])
            try Task.checkCancellation()
            guard result.status == 0, let version = ADBClient.protocolVersion(result.output) else {
                throw AndroidSharingError.message("The selected executable did not report a supported ADB version.")
            }
            self.client = client
            self.protocolVersion = version
            adbVersion = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var backendVersion = try await server.backendVersion()
        try Task.checkCancellation()
        if backendVersion == nil && allowStart {
            let result = try await client.run(["start-server"])
            try Task.checkCancellation()
            guard result.status == 0 else { throw AndroidSharingError.message("Could not start local ADB: \(result.output.prefix(500))") }
            backendVersion = try await server.backendVersion()
        }
        try Task.checkCancellation()
        guard let backendVersion else { throw AndroidSharingError.message("Local ADB is not running. Click Retry to start it.") }
        guard backendVersion == protocolVersion else {
            throw AndroidSharingError.message("The running ADB server and selected executable have different protocol versions. Choose the same SDK used by local tools. Astation has not restarted that server.")
        }
        let result = try await client.run(["devices", "-l"])
        try Task.checkCancellation()
        guard result.status == 0 else { throw AndroidSharingError.message("Could not list Android devices: \(result.output.prefix(500))") }
        devices = AndroidDevice.parse(result.output)
        deviceError = nil
        isReady = true
    }

    /// Serialize device commands and sharing mutations; await cancelled polling before resuming.
    private func perform(_ action: @escaping @MainActor () async -> Void) {
        guard !closed, !isBusy else { return }
        isBusy = true
        let previous = monitor
        previous?.cancel()
        monitor = nil
        operation = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled else { return }
            await action()
            self.isBusy = false
            self.operation = nil
            self.beginPolling(allowStart: false)
        }
    }

    func retry() {
        perform { [weak self] in
            guard let self else { return }
            self.adbPath = ADBClient.discover(saved: self.defaults.string(forKey: "androidSharing.adbPath"))
            do { try await self.refresh(allowStart: true) }
            catch { self.deviceError = error.localizedDescription; self.isReady = false }
        }
    }

    func chooseADB(_ path: String) {
        guard !isSharing, !isBusy else { return }
        defaults.set(path, forKey: "androidSharing.adbPath")
        adbPath = path
        client = nil
        protocolVersion = nil
        retry()
    }

    func startSharing() {
        perform { [weak self] in
            guard let self else { return }
            self.sharingError = nil
            do {
                guard let port = AndroidCommands.port(self.portText) else {
                    throw AndroidSharingError.message("Enter a sharing port between 1024 and 65535.")
                }
                let currentAddresses = self.addressProvider()
                guard let address = currentAddresses.first(where: { $0.id == self.selectedAddressID }) else {
                    throw AndroidSharingError.message("Choose an IPv4 address assigned to this Mac that your development machine can reach.")
                }
                try await self.refresh(allowStart: true)
                let boundPort = try await self.server.start(address: address.address, port: port)
                try Task.checkCancellation()
                guard self.addressProvider().contains(address) else {
                    throw AndroidSharingError.message("The selected network address changed while starting sharing.")
                }
                self.boundAddress = address.address
                self.boundPort = boundPort
            } catch {
                await self.server.stop()
                self.sharingError = "Could not start sharing: \(error.localizedDescription)"
            }
        }
    }

    func stopSharing() {
        perform { [weak self] in await self?.stopSharing(reason: nil) }
    }

    private func stopSharing(reason: String?) async {
        boundPort = nil
        boundAddress = nil
        await server.stop()
        sharingError = reason
    }

    func connectWireless(pairingEndpoint: String, code: String, connectionEndpoint: String, pairFirst: Bool) {
        guard AndroidCommands.wirelessEndpoint(connectionEndpoint),
              !pairFirst || (AndroidCommands.wirelessEndpoint(pairingEndpoint) && code.count == 6 && code.allSatisfy({ $0.isASCII && $0.isNumber })) else {
            wirelessMessage = "Enter IPv4:port for each endpoint and a six-digit pairing code."
            return
        }
        wirelessMessage = nil
        perform { [weak self] in
            guard let self else { return }
            do {
                try await self.refresh(allowStart: true)
                guard let client = self.client else { return }
                if pairFirst {
                    let result = try await client.run(["pair", pairingEndpoint], input: code + "\n", timeout: 30)
                    try Task.checkCancellation()
                    guard result.status == 0, result.output.localizedCaseInsensitiveContains("Successfully paired") else {
                        throw AndroidSharingError.message("Pairing failed. Check the phone's pairing address and generate a fresh code.")
                    }
                }
                let result = try await client.run(["connect", connectionEndpoint], timeout: 15)
                try Task.checkCancellation()
                guard result.status == 0,
                      result.output.localizedCaseInsensitiveContains("connected to \(connectionEndpoint)") else {
                    throw AndroidSharingError.message("Could not connect. Use the debugging port on the phone's Wireless debugging screen, which may differ from its pairing port.")
                }
                try await self.refresh(allowStart: false)
                self.wirelessMessage = "Connection requested. Check that the phone appears as Authorized in the device list."
            } catch {
                // Pairing output can contain the temporary secret; never surface raw output here.
                self.wirelessMessage = error.localizedDescription.replacingOccurrences(of: code.isEmpty ? "\u{0}" : code, with: "[redacted]")
            }
        }
    }

    func shutdown() {
        guard !closed else { return }
        closed = true
        monitor?.cancel()
        networkMonitor?.cancel()
        operation?.cancel()
        server.shutdown()
    }
}
