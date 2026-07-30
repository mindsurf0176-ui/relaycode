import XCTest
@testable import RelayCodeCore

final class RuntimeProfileTests: XCTestCase {
    func testAcceptsPrivateHTTPSOnPremProviderWithoutPersistingSecret() throws {
        let provider = try ModelConnectionConfiguration(
            id: "office-ollama",
            displayName: "Office Ollama",
            kind: .openAICompatible,
            baseURL: XCTUnwrap(URL(string: "https://ollama.example.ts.net/v1")),
            modelID: "qwen-coder",
            credentialReference: "provider.office-ollama"
        )

        XCTAssertEqual(provider.kind, .openAICompatible)
        XCTAssertEqual(provider.modelID, "qwen-coder")
        XCTAssertEqual(provider.credentialReference, "provider.office-ollama")
    }

    func testRejectsPlainHTTPForRemoteProvider() throws {
        XCTAssertThrowsError(
            try ModelConnectionConfiguration(
                id: "office-ollama",
                displayName: "Office Ollama",
                kind: .openAICompatible,
                baseURL: XCTUnwrap(URL(string: "http://ollama.example.ts.net/v1")),
                modelID: "qwen-coder"
            )
        ) { error in
            XCTAssertEqual(error as? RuntimeProfileError, .insecureRemoteProvider)
        }
    }

    func testAllowsLoopbackHTTPForDevelopment() throws {
        let provider = try ModelConnectionConfiguration(
            id: "local-dev",
            displayName: "Local development",
            kind: .openAICompatible,
            baseURL: XCTUnwrap(URL(string: "http://127.0.0.1:11434/v1")),
            modelID: "test-model"
        )

        XCTAssertEqual(provider.baseURL?.host, "127.0.0.1")
    }

    func testRejectsCredentialsEmbeddedInProviderURL() throws {
        XCTAssertThrowsError(
            try ModelConnectionConfiguration(
                id: "bad-secret",
                displayName: "Bad secret",
                kind: .openAICompatible,
                baseURL: XCTUnwrap(URL(string: "https://token@example.com/v1")),
                modelID: "test-model"
            )
        ) { error in
            XCTAssertEqual(error as? RuntimeProfileError, .providerURLContainsSecrets)
        }
    }

    func testDownloadedModelRequiresModelIdentifier() {
        XCTAssertThrowsError(
            try ModelConnectionConfiguration(
                id: "phone-model",
                displayName: "Phone model",
                kind: .downloadedOnDevice
            )
        ) { error in
            XCTAssertEqual(error as? RuntimeProfileError, .missingModelID)
        }
    }

    func testExecutionKindsNeverClaimHardwareVirtualization() {
        for runtime in ExecutionRuntimeKind.allCases {
            XCTAssertFalse(runtime.isFullLinuxVM)
        }
        XCTAssertTrue(ExecutionRuntimeKind.interpretedLinux.isOnDevice)
        XCTAssertFalse(ExecutionRuntimeKind.pairedHost.isOnDevice)
    }

    func testDecodedProviderRevalidatesRemoteTransport() throws {
        let data = try XCTUnwrap(
            """
            {
              "id": "tampered-provider",
              "displayName": "Tampered",
              "kind": "openAICompatible",
              "baseURL": "http://model.example.com/v1",
              "modelID": "test-model"
            }
            """.data(using: .utf8)
        )

        XCTAssertThrowsError(
            try JSONDecoder().decode(ModelConnectionConfiguration.self, from: data)
        ) { error in
            XCTAssertEqual(error as? RuntimeProfileError, .insecureRemoteProvider)
        }
    }

    func testRejectsInvalidCredentialReferenceDuringDecode() throws {
        let data = try XCTUnwrap(
            """
            {
              "id": "tampered-provider",
              "displayName": "Tampered",
              "kind": "openAICompatible",
              "baseURL": "https://model.example.com/v1",
              "modelID": "test-model",
              "credentialReference": "../outside-keychain-scope"
            }
            """.data(using: .utf8)
        )

        XCTAssertThrowsError(
            try JSONDecoder().decode(ModelConnectionConfiguration.self, from: data)
        ) { error in
            XCTAssertEqual(
                error as? RuntimeProfileError,
                .invalidCredentialReference
            )
        }
    }
}
