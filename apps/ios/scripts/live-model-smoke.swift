import Foundation

@main
private struct LiveModelSmoke {
    static func main() async throws {
        guard CommandLine.arguments.count == 3,
              let baseURL = URL(string: CommandLine.arguments[1]) else {
            throw LiveModelSmokeError.usage
        }

        let endpoint = try OpenAICompatibleEndpoint(baseURL: baseURL)
        let modelID = CommandLine.arguments[2]
        let token = ProcessInfo.processInfo.environment["RELAYCODE_MODEL_TOKEN"]
        let marker = "RELAYCODE_LIVE_INFERENCE_OK"
        let response = try await OpenAICompatibleModelClient().complete(
            endpoint: endpoint,
            modelID: modelID,
            messages: [
                ModelChatMessage(
                    role: .system,
                    content: "Follow the user's output-format instruction exactly."
                ),
                ModelChatMessage(
                    role: .user,
                    content: "Reply with exactly \(marker) and nothing else."
                ),
            ],
            bearerToken: token
        )

        guard response.contains(marker) else {
            throw LiveModelSmokeError.missingMarker(response)
        }
        print("Live model inference passed: \(response)")
    }
}

private enum LiveModelSmokeError: LocalizedError {
    case usage
    case missingMarker(String)

    var errorDescription: String? {
        switch self {
        case .usage:
            "usage: live-model-smoke <base-url> <model-id>"
        case let .missingMarker(response):
            "model response did not contain the expected marker: \(response)"
        }
    }
}
