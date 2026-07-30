import Foundation
@preconcurrency import LiteRTLM
import RelayCodeCore

actor OnDeviceLiteRTInferenceEngine {
    private var engine: LiteRTLM.Engine?
    private var loadedModelURL: URL?
    private var loadedConfiguration: OnDeviceInferenceConfiguration?

    nonisolated func tokenStream(
        modelURL: URL,
        descriptor: OnDeviceModelDescriptor,
        messages: [ModelChatMessage],
        configuration: OnDeviceInferenceConfiguration,
        maximumOutputTokens: Int? = nil
    ) -> AsyncThrowingStream<OnDeviceInferenceEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.generate(
                        modelURL: modelURL,
                        descriptor: descriptor,
                        messages: messages,
                        configuration: configuration,
                        maximumOutputTokens: maximumOutputTokens,
                        continuation: continuation
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func unload() {
        engine = nil
        loadedModelURL = nil
        loadedConfiguration = nil
    }

    private func generate(
        modelURL: URL,
        descriptor: OnDeviceModelDescriptor,
        messages: [ModelChatMessage],
        configuration: OnDeviceInferenceConfiguration,
        maximumOutputTokens: Int?,
        continuation: AsyncThrowingStream<OnDeviceInferenceEvent, Error>.Continuation
    ) async throws {
        try Task.checkCancellation()
        guard descriptor.runtime == .liteRTLM else {
            throw OnDeviceLiteRTInferenceError.unsupportedRuntime
        }

        let sanitizedMessages = try OnDevicePromptPolicy.sanitizedMessages(messages)
        guard sanitizedMessages.last?.role == .user,
              !sanitizedMessages.contains(where: { $0.role == .system }) else {
            throw OnDeviceModelArtifactError.invalidConversation
        }
        let outputTokenLimit = min(
            maximumOutputTokens ?? descriptor.maximumOutputTokens,
            descriptor.maximumOutputTokens
        )
        guard outputTokenLimit > 0 else {
            throw OnDeviceInferenceError.invalidOutputLimit
        }

        let requestStartedAt = Date.timeIntervalSinceReferenceDate
        let modelLoadMilliseconds = try await loadModelIfNeeded(
            at: modelURL,
            configuration: configuration
        )
        guard let engine else {
            throw OnDeviceLiteRTInferenceError.modelNotLoaded
        }

        let systemPrompt = try OnDevicePromptPolicy.systemPrompt(
            messages: sanitizedMessages,
            descriptor: descriptor
        )
        let initialMessages = sanitizedMessages.dropLast().map {
            LiteRTLM.Message(
                $0.content,
                role: $0.role == .assistant ? .model : .user
            )
        }
        let sampler = try SamplerConfig(
            topK: 64,
            topP: 0.95,
            temperature: 1.0,
            seed: 0x52434F44
        )
        let conversation = try await engine.createConversation(
            with: ConversationConfig(
                systemMessage: LiteRTLM.Message(systemPrompt, role: .system),
                initialMessages: Array(initialMessages),
                samplerConfig: sampler
            )
        )

        var generatedText = ""
        var measuredFirstTokenMilliseconds = 0.0
        do {
            let finalUserMessage = sanitizedMessages[sanitizedMessages.count - 1]
            for try await chunk in conversation.sendMessageStream(
                LiteRTLM.Message(finalUserMessage.content),
                maximumOutputTokens: outputTokenLimit
            ) {
                try Task.checkCancellation()
                let text = chunk.toString
                guard !text.isEmpty else {
                    continue
                }
                if generatedText.isEmpty {
                    measuredFirstTokenMilliseconds = (
                        Date.timeIntervalSinceReferenceDate - requestStartedAt
                    ) * 1_000
                }
                generatedText += text
                continuation.yield(.token(text))
            }
        } catch is CancellationError {
            try? conversation.cancel()
            throw CancellationError()
        }

        guard !generatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OnDeviceInferenceError.emptyCompletion
        }

        let benchmark = try? conversation.getBenchmarkInfo()
        continuation.yield(
            .metrics(
                OnDeviceInferenceMetrics(
                    modelLoadMilliseconds: modelLoadMilliseconds,
                    firstTokenMilliseconds: benchmark.map {
                        $0.timeToFirstTokenInSecond * 1_000
                    } ?? measuredFirstTokenMilliseconds,
                    promptTokenCount: benchmark?.lastPrefillTokenCount ?? 0,
                    reusedPromptTokenCount: 0,
                    promptTokensPerSecond: benchmark?.lastPrefillTokensPerSecond ?? 0,
                    generatedTokenCount: benchmark?.lastDecodeTokenCount ?? 0,
                    generatedTokensPerSecond: benchmark?.lastDecodeTokensPerSecond ?? 0,
                    configuration: configuration
                )
            )
        )
    }

    private func loadModelIfNeeded(
        at modelURL: URL,
        configuration: OnDeviceInferenceConfiguration
    ) async throws -> Double {
        let normalizedURL = modelURL.standardizedFileURL
        if loadedModelURL == normalizedURL,
           loadedConfiguration == configuration,
           engine != nil {
            return 0
        }

        unload()
        let loadStartedAt = Date.timeIntervalSinceReferenceDate
        let cacheDirectory = try prepareCacheDirectory()

        ExperimentalFlags.optIntoExperimentalAPIs()
        ExperimentalFlags.enableBenchmark = true
        ExperimentalFlags.enableSpeculativeDecoding = true

        let config = try EngineConfig(
            modelPath: normalizedURL.path,
            backend: .gpu,
            maxNumTokens: configuration.contextLength,
            cacheDir: cacheDirectory.path
        )
        let loadedEngine = LiteRTLM.Engine(engineConfig: config)
        try await loadedEngine.initialize()

        engine = loadedEngine
        loadedModelURL = normalizedURL
        loadedConfiguration = configuration
        return (
            Date.timeIntervalSinceReferenceDate - loadStartedAt
        ) * 1_000
    }

    private func prepareCacheDirectory() throws -> URL {
        let root = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        )[0]
        let directory = root
            .appendingPathComponent("RelayCode", isDirectory: true)
            .appendingPathComponent("LiteRTLM", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDirectory = directory
        try mutableDirectory.setResourceValues(values)
        return directory
    }
}

enum OnDeviceLiteRTInferenceError: LocalizedError {
    case modelNotLoaded
    case unsupportedRuntime

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            "Gemma 4 내부 모델이 메모리에 로드되지 않았습니다."
        case .unsupportedRuntime:
            "선택한 모델은 LiteRT-LM 형식이 아닙니다."
        }
    }
}
