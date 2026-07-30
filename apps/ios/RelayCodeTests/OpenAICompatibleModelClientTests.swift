import XCTest
@testable import RelayCodeCore

final class OpenAICompatibleModelClientTests: XCTestCase {
    private let client = OpenAICompatibleModelClient()

    func testBuildsModelsURLFromVersionedBaseURL() throws {
        let endpoint = try OpenAICompatibleEndpoint(
            baseURL: XCTUnwrap(URL(string: "https://ollama.example.ts.net/v1"))
        )

        XCTAssertEqual(endpoint.modelsURL.absoluteString, "https://ollama.example.ts.net/v1/models")
    }

    func testModelsRequestKeepsCredentialOutOfURL() throws {
        let endpoint = try OpenAICompatibleEndpoint(
            baseURL: XCTUnwrap(URL(string: "https://ollama.example.ts.net/v1"))
        )

        let request = try client.modelsRequest(endpoint: endpoint, bearerToken: "secret-token")

        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-token")
        XCTAssertFalse(try XCTUnwrap(request.url?.absoluteString).contains("secret-token"))
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalAndRemoteCacheData)
    }

    func testRejectsHeaderInjectionInCredential() throws {
        let endpoint = try OpenAICompatibleEndpoint(
            baseURL: XCTUnwrap(URL(string: "https://ollama.example.ts.net/v1"))
        )

        XCTAssertThrowsError(
            try client.modelsRequest(endpoint: endpoint, bearerToken: "token\r\nX-Test: bad")
        ) { error in
            XCTAssertEqual(error as? ModelProviderClientError, .invalidCredential)
        }
    }

    func testDecodesSortsAndDeduplicatesModels() throws {
        let data = try XCTUnwrap(
            """
            {
              "object": "list",
              "data": [
                {"id": "qwen-coder", "owned_by": "local"},
                {"id": "gpt-oss:20b", "owned_by": "local"},
                {"id": "qwen-coder", "owned_by": "duplicate"},
                {"id": "  "}
              ]
            }
            """.data(using: .utf8)
        )

        let models = try client.decodeModels(from: data)

        XCTAssertEqual(models.map(\.id), ["gpt-oss:20b", "qwen-coder"])
    }

    func testRejectsMalformedModelPayload() throws {
        let data = try XCTUnwrap(#"{"models":[]}"#.data(using: .utf8))

        XCTAssertThrowsError(try client.decodeModels(from: data)) { error in
            XCTAssertEqual(error as? ModelProviderClientError, .invalidPayload)
        }
    }

    func testRejectsEmptyModelList() throws {
        let data = try XCTUnwrap(#"{"data":[]}"#.data(using: .utf8))

        XCTAssertThrowsError(try client.decodeModels(from: data)) { error in
            XCTAssertEqual(error as? ModelProviderClientError, .noModels)
        }
    }

    func testBuildsChatCompletionRequestWithoutCredentialInBodyOrURL() throws {
        let endpoint = try OpenAICompatibleEndpoint(
            baseURL: XCTUnwrap(URL(string: "https://ollama.example.ts.net/v1"))
        )
        let request = try client.completionRequest(
            endpoint: endpoint,
            modelID: "qwen-coder",
            messages: [
                ModelChatMessage(role: .user, content: "Explain this diff."),
            ],
            bearerToken: "private-token"
        )

        XCTAssertEqual(
            request.url?.absoluteString,
            "https://ollama.example.ts.net/v1/chat/completions"
        )
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer private-token"
        )
        let body = try XCTUnwrap(request.httpBody)
        let bodyString = try XCTUnwrap(String(data: body, encoding: .utf8))
        XCTAssertFalse(bodyString.contains("private-token"))
        XCTAssertFalse(try XCTUnwrap(request.url?.absoluteString).contains("private-token"))
        XCTAssertTrue(bodyString.contains(#""stream":false"#))
        XCTAssertFalse(bodyString.contains(#""id""#))
    }

    func testDecodesChatCompletion() throws {
        let data = try XCTUnwrap(
            """
            {
              "id": "chatcmpl-local",
              "choices": [
                {
                  "index": 0,
                  "message": {
                    "role": "assistant",
                    "content": "  The build is healthy.  "
                  }
                }
              ]
            }
            """.data(using: .utf8)
        )

        XCTAssertEqual(
            try client.decodeCompletion(from: data),
            "The build is healthy."
        )
    }

    func testRejectsEmptyChatCompletion() throws {
        let data = try XCTUnwrap(
            #"{"choices":[{"message":{"content":"  "}}]}"#.data(using: .utf8)
        )

        XCTAssertThrowsError(try client.decodeCompletion(from: data)) { error in
            XCTAssertEqual(error as? ModelProviderClientError, .emptyCompletion)
        }
    }

    func testRejectsInvalidChatInput() throws {
        let endpoint = try OpenAICompatibleEndpoint(
            baseURL: XCTUnwrap(URL(string: "https://ollama.example.ts.net/v1"))
        )

        XCTAssertThrowsError(
            try client.completionRequest(
                endpoint: endpoint,
                modelID: " ",
                messages: [ModelChatMessage(role: .user, content: "hello")],
                bearerToken: nil
            )
        ) { error in
            XCTAssertEqual(error as? ModelProviderClientError, .invalidModelID)
        }

        XCTAssertThrowsError(
            try client.completionRequest(
                endpoint: endpoint,
                modelID: "qwen-coder",
                messages: [],
                bearerToken: nil
            )
        ) { error in
            XCTAssertEqual(error as? ModelProviderClientError, .invalidMessages)
        }
    }

    func testPerformsCompletionThroughURLSession() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CompletionURLProtocol.self]
        let client = OpenAICompatibleModelClient(
            session: URLSession(configuration: configuration)
        )
        let endpoint = try OpenAICompatibleEndpoint(
            baseURL: XCTUnwrap(URL(string: "http://127.0.0.1:11434/v1"))
        )

        let result = try await client.complete(
            endpoint: endpoint,
            modelID: "qwen-coder",
            messages: [
                ModelChatMessage(role: .user, content: "Return the marker."),
            ],
            bearerToken: "test-token"
        )

        XCTAssertEqual(result, "RELAYCODE_INFERENCE_OK")
    }
}

private final class CompletionURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard request.httpMethod == "POST",
              request.url?.path == "/v1/chat/completions",
              request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token",
              let url = request.url,
              let data = #"{"choices":[{"message":{"content":"RELAYCODE_INFERENCE_OK"}}]}"#
                .data(using: .utf8),
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 200,
                  httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "application/json"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
