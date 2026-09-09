import Foundation

struct AndroidDevice: Identifiable, Equatable {
    let serial: String
    let state: String
    let model: String
    let transport: String
    var id: String { serial }
    var isAuthorized: Bool { state == "device" }
    var status: String {
        switch state {
        case "device": return "Authorized"
        case "unauthorized": return "Unlock phone and allow USB debugging"
        case "offline": return "Offline"
        default: return state
        }
    }

    static func parse(_ output: String) -> [AndroidDevice] {
        var devices: [String: AndroidDevice] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 2,
                  ["device", "offline", "unauthorized", "recovery", "sideload", "bootloader", "no"].contains(fields[1]) else { continue }
            let serial = fields[0]
            let model = fields.dropFirst(2).first { $0.hasPrefix("model:") }
                .map { String($0.dropFirst(6)).replacingOccurrences(of: "_", with: " ") } ?? serial
            let transport: String
            if serial.hasPrefix("emulator-") { transport = "Emulator" }
            else if fields.contains(where: { $0.hasPrefix("usb:") }) { transport = "USB" }
            else if serial.contains(":") || serial.contains("._adb") { transport = "Wireless" }
            else { transport = "USB / unknown" }
            devices[serial] = AndroidDevice(serial: serial, state: fields[1] == "no" ? "No permissions" : fields[1], model: model, transport: transport)
        }
        return devices.values.sorted { $0.serial < $1.serial }
    }
}

enum AndroidSharingError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

enum AndroidCommands {
    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func port(_ text: String) -> Int? {
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }),
              let value = Int(text), (1024...65535).contains(value) else { return nil }
        return value
    }

    static func deviceCommand(address: String, port: Int, serial: String) -> String {
        "adb -H \(quote(address)) -P \(port) -s \(quote(serial)) shell"
    }

    static func wirelessEndpoint(_ value: String) -> Bool {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let port = Int(parts[1]), (1...65535).contains(port) else { return false }
        return AndroidNetworkInterfaces.isIPv4(String(parts[0]))
    }
}
