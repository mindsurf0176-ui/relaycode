import Foundation

public struct PairingConfiguration: Codable, Hashable, Sendable {
    public let token: String
    public let bridgeURL: URL
    public let webURL: URL

    public init(token: String, bridgeURL: URL) throws {
        let normalizedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedToken.range(
            of: #"^[A-Za-z0-9_-]{40,100}$"#,
            options: .regularExpression
        ) != nil else {
            throw PairingError.invalidToken
        }

        guard var components = URLComponents(url: bridgeURL, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              scheme == "ws" || scheme == "wss" else {
            throw PairingError.invalidBridge
        }

        if scheme == "ws" && !["127.0.0.1", "localhost", "::1"].contains(host) {
            throw PairingError.insecureRemoteBridge
        }

        let originalBridgeURL = bridgeURL
        components.scheme = scheme == "wss" ? "https" : "http"
        components.query = nil
        components.fragment = nil
        if components.path.hasSuffix("/ws") {
            components.path.removeLast(3)
        }
        if components.path.isEmpty {
            components.path = "/"
        }
        guard let webURL = components.url else {
            throw PairingError.invalidBridge
        }

        self.token = normalizedToken
        self.bridgeURL = originalBridgeURL
        self.webURL = webURL
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            token: container.decode(String.self, forKey: .token),
            bridgeURL: container.decode(URL.self, forKey: .bridgeURL)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(token, forKey: .token)
        try container.encode(bridgeURL, forKey: .bridgeURL)
    }

    public static func parse(_ input: String) throws -> PairingConfiguration {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: value) else {
            throw PairingError.invalidLink
        }

        var items = components.queryItems ?? []
        if let fragment = components.percentEncodedFragment, !fragment.isEmpty {
            var fragmentComponents = URLComponents()
            fragmentComponents.percentEncodedQuery = fragment
            items.append(contentsOf: fragmentComponents.queryItems ?? [])
        }

        guard let token = items.first(where: { $0.name == "pair" || $0.name == "token" })?.value,
              let bridgeValue = items.first(where: { $0.name == "bridge" })?.value,
              let bridgeURL = URL(string: bridgeValue) else {
            throw PairingError.missingPairingData
        }

        return try PairingConfiguration(token: token, bridgeURL: bridgeURL)
    }

    private enum CodingKeys: String, CodingKey {
        case token
        case bridgeURL
    }
}

public enum PairingError: LocalizedError {
    case invalidLink
    case missingPairingData
    case invalidToken
    case invalidBridge
    case insecureRemoteBridge

    public var errorDescription: String? {
        switch self {
        case .invalidLink:
            "페어링 링크 형식이 올바르지 않습니다."
        case .missingPairingData:
            "링크에 토큰 또는 Bridge 주소가 없습니다."
        case .invalidToken:
            "페어링 토큰이 올바르지 않습니다."
        case .invalidBridge:
            "Bridge WebSocket 주소가 올바르지 않습니다."
        case .insecureRemoteBridge:
            "원격 Mac 연결은 wss:// HTTPS 주소만 허용합니다."
        }
    }
}
