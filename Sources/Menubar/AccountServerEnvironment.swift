import Foundation

enum AccountServerEnvironment: Int, CaseIterable {
    case development, production

    var portalURL: String { self == .development ? "https://dev.agora.build" : "https://agora.build" }
    var stationURL: String { self == .development ? "https://station-dev.agora.build" : "https://station.agora.build" }
    var issuerURL: String { self == .development ? "https://auth.dev.agora.build" : "https://auth.agora.build" }

    static var buildDefault: Self {
        #if DEBUG
        .development
        #else
        .production
        #endif
    }

    static func matching(portalURL: String, stationURL: String) -> Self? {
        allCases.first { $0.portalURL == portalURL && $0.stationURL == stationURL }
    }
}
