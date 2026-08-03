import Foundation
import RelayCodeCore

@main
struct OnDeviceModelSmoke {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else {
            throw SmokeError.missingModelPath
        }

        let modelURL = URL(fileURLWithPath: CommandLine.arguments[1])
        guard let descriptor = OnDeviceModelDescriptor.relayCodeModels.first(
            where: { $0.filename == modelURL.lastPathComponent }
        ) else {
            throw SmokeError.unknownModel
        }
        try OnDeviceModelArtifactVerifier.verify(
            fileURL: modelURL,
            descriptor: descriptor
        )

        let engine = OnDeviceInferenceEngine()
        let configuration = OnDeviceInferenceConfiguration.resolve(
            requestedMode: .turbo,
            environment: OnDeviceRuntimeEnvironment(
                physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
                processorCount: ProcessInfo.processInfo.activeProcessorCount,
                isLowPowerModeEnabled: false,
                thermalLevel: .nominal
            ),
            descriptor: descriptor
        )
        let stream = engine.tokenStream(
            modelURL: modelURL,
            descriptor: descriptor,
            messages: [
                ModelChatMessage(
                    role: .user,
                    content: "Reply with exactly RELAYCODE_ON_DEVICE_OK and no other text."
                ),
            ],
            configuration: configuration
        )

        var outputPieces: [String] = []
        var metrics: OnDeviceInferenceMetrics?
        for try await event in stream {
            switch event {
            case let .token(token):
                outputPieces.append(token)
            case let .metrics(result):
                metrics = result
            }
        }
        let output = outputPieces.joined()
        let normalized = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.contains("RELAYCODE_ON_DEVICE_OK") else {
            throw SmokeError.unexpectedOutput(normalized)
        }
        print("On-device model inference passed: \(normalized)")
        if let metrics {
            print(
                String(
                    format: "first-token=%.0fms generation=%.1f tok/s prompt=%.1f tok/s",
                    metrics.firstTokenMilliseconds,
                    metrics.generatedTokensPerSecond,
                    metrics.promptTokensPerSecond
                )
            )
        }

        let cachedStream = engine.tokenStream(
            modelURL: modelURL,
            descriptor: descriptor,
            messages: [
                ModelChatMessage(
                    role: .user,
                    content: "Reply with exactly RELAYCODE_ON_DEVICE_OK and no other text."
                ),
                ModelChatMessage(role: .assistant, content: normalized),
                ModelChatMessage(
                    role: .user,
                    content: "Now reply with exactly RELAYCODE_CACHE_OK and no other text."
                ),
            ],
            configuration: configuration
        )
        var cachedOutputPieces: [String] = []
        var cachedMetrics: OnDeviceInferenceMetrics?
        for try await event in cachedStream {
            switch event {
            case let .token(token):
                cachedOutputPieces.append(token)
            case let .metrics(result):
                cachedMetrics = result
            }
        }
        await engine.unload()

        let cachedOutput = cachedOutputPieces.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard cachedOutput.contains("RELAYCODE_CACHE_OK") else {
            throw SmokeError.unexpectedOutput(cachedOutput)
        }
        guard let cachedMetrics,
              cachedMetrics.reusedPromptTokenCount > 0 else {
            throw SmokeError.promptCacheNotReused
        }
        print(
            "Prompt cache passed: reused "
                + "\(cachedMetrics.reusedPromptTokenCount) tokens"
        )
    }
}

private enum SmokeError: LocalizedError {
    case missingModelPath
    case unknownModel
    case unexpectedOutput(String)
    case promptCacheNotReused

    var errorDescription: String? {
        switch self {
        case .missingModelPath:
            "Expected one GGUF model path argument."
        case .unknownModel:
            "The GGUF filename does not match a pinned RelayCode model."
        case let .unexpectedOutput(output):
            "On-device model returned unexpected output: \(output)"
        case .promptCacheNotReused:
            "On-device model did not reuse the previous prompt cache."
        }
    }
}
