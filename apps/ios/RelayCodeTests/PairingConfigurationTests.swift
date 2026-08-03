import XCTest
@testable import RelayCodeCore

final class PairingConfigurationTests: XCTestCase {
    func testParsesWebPairingFragment() throws {
        let token = String(repeating: "a", count: 43)
        let link = "https://mac.example.ts.net/#pair=\(token)&bridge=wss%3A%2F%2Fmac.example.ts.net%2Fws"

        let pairing = try PairingConfiguration.parse(link)

        XCTAssertEqual(pairing.token, token)
        XCTAssertEqual(pairing.bridgeURL.absoluteString, "wss://mac.example.ts.net/ws")
        XCTAssertEqual(pairing.webURL.absoluteString, "https://mac.example.ts.net/")
    }

    func testParsesNativePairingURL() throws {
        let token = String(repeating: "b", count: 43)
        let link = "relaycode://pair?pair=\(token)&bridge=wss%3A%2F%2Fmac.example.ts.net%2Fws"

        let pairing = try PairingConfiguration.parse(link)

        XCTAssertEqual(pairing.bridgeURL.scheme, "wss")
        XCTAssertEqual(pairing.webURL.scheme, "https")
    }

    func testAllowsLoopbackDevelopmentWebSocket() throws {
        let token = String(repeating: "c", count: 43)
        let pairing = try PairingConfiguration(
            token: token,
            bridgeURL: XCTUnwrap(URL(string: "ws://127.0.0.1:8787/ws"))
        )

        XCTAssertEqual(pairing.webURL.absoluteString, "http://127.0.0.1:8787/")
    }

    func testRejectsInsecureRemoteWebSocket() throws {
        let token = String(repeating: "d", count: 43)
        let bridge = try XCTUnwrap(URL(string: "ws://mac.example.ts.net/ws"))

        XCTAssertThrowsError(try PairingConfiguration(token: token, bridgeURL: bridge))
    }

    func testDecodedPairingRevalidatesBridgeAndDerivesWebURL() throws {
        let token = String(repeating: "e", count: 43)
        let validData = try XCTUnwrap(
            """
            {
              "token": "\(token)",
              "bridgeURL": "wss://mac.example.ts.net/ws",
              "webURL": "https://attacker.example/"
            }
            """.data(using: .utf8)
        )

        let pairing = try JSONDecoder().decode(PairingConfiguration.self, from: validData)

        XCTAssertEqual(pairing.webURL.absoluteString, "https://mac.example.ts.net/")

        let insecureData = try XCTUnwrap(
            """
            {
              "token": "\(token)",
              "bridgeURL": "ws://mac.example.ts.net/ws"
            }
            """.data(using: .utf8)
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(PairingConfiguration.self, from: insecureData)
        )
    }
}
