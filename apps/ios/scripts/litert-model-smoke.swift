import Foundation
import RelayCodeCore

@main
struct LiteRTModelSmoke {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else {
            throw SmokeError.missingModelPath
        }

        let modelURL = URL(fileURLWithPath: CommandLine.arguments[1])
        guard let descriptor = OnDeviceModelDescriptor.relayCodeModels.first(
            where: {
                $0.runtime == .liteRTLM
                    && $0.filename == modelURL.lastPathComponent
            }
        ) else {
            throw SmokeError.unknownModel
        }
        try OnDeviceModelArtifactVerifier.verify(
            fileURL: modelURL,
            descriptor: descriptor
        )

        let engine = OnDeviceLiteRTInferenceEngine()
        let configuration = OnDeviceInferenceConfiguration.resolve(
            requestedMode: .balanced,
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
                    content: """
                    다음 요구를 정확히 수행해. 설명 없이
                    RELAYCODE_GEMMA4_OK
                    이 한 줄만 출력해.
                    """
                ),
            ],
            configuration: configuration,
            maximumOutputTokens: 64
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
        await engine.unload()

        let output = outputPieces.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard output.contains("RELAYCODE_GEMMA4_OK") else {
            throw SmokeError.unexpectedOutput(output)
        }

        print("Gemma 4 LiteRT-LM inference passed: \(output)")
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
    }
}

private enum SmokeError: LocalizedError {
    case missingModelPath
    case unknownModel
    case unexpectedOutput(String)

    var errorDescription: String? {
        switch self {
        case .missingModelPath:
            "Expected one LiteRT-LM model path argument."
        case .unknownModel:
            "The LiteRT-LM filename does not match a pinned RelayCode model."
        case let .unexpectedOutput(output):
            "Gemma 4 returned unexpected output: \(output)"
        }
    }
}
