import Foundation

enum IntegrationAccessNotice {
    private static let builtInOrigins: Set<String> = [
        "https://station.agora.build", "https://station-dev.agora.build"
    ]

    static func operatorName(stationOrigin: String) -> String {
        builtInOrigins.contains(stationOrigin) ? "Agora.Build" : "The operator of \(stationOrigin)"
    }

    static func disclosure(stationOrigin: String) -> String {
        "\(operatorName(stationOrigin: stationOrigin)) can read and process the agent content permitted by this integration. This grants no access to your vault or saved credentials."
    }

    static func ownerAuthenticationReason(stationOrigin: String) -> String {
        "approve agent access on \(stationOrigin). \(operatorName(stationOrigin: stationOrigin)) can read and process the permitted agent content"
    }
}
