import Foundation
import RelayCodeCore

@main
struct OnDeviceModelSmoke {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else {
            throw SmokeError.missingModelPath
        }

        let modelURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let descriptor = OnDeviceModelDescriptor.relayCodeCoder
        try OnDeviceModelArtifactVerifier.verify(
            fileURL: modelURL,
            descriptor: descriptor
        )

        let engine = OnDeviceInferenceEngine()
        let stream = engine.tokenStream(
            modelURL: modelURL,
            descriptor: descriptor,
            messages: [
                ModelChatMessage(
                    role: .user,
                    content: "Reply with exactly RELAYCODE_ON_DEVICE_OK and no other text."
                ),
            ]
        )

        var output = ""
        for try await token in stream {
            output += token
        }
        await engine.unload()

        let normalized = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.contains("RELAYCODE_ON_DEVICE_OK") else {
            throw SmokeError.unexpectedOutput(normalized)
        }
        print("On-device model inference passed: \(normalized)")
    }
}

private enum SmokeError: LocalizedError {
    case missingModelPath
    case unexpectedOutput(String)

    var errorDescription: String? {
        switch self {
        case .missingModelPath:
            "Expected one GGUF model path argument."
        case let .unexpectedOutput(output):
            "On-device model returned unexpected output: \(output)"
        }
    }
}
