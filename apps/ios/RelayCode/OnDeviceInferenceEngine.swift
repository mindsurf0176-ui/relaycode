import Foundation
import llama
import RelayCodeCore

actor OnDeviceInferenceEngine {
    private let resources = OnDeviceLlamaResources()
    private var loadedModelURL: URL?

    nonisolated func tokenStream(
        modelURL: URL,
        descriptor: OnDeviceModelDescriptor,
        messages: [ModelChatMessage]
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.generate(
                        modelURL: modelURL,
                        descriptor: descriptor,
                        messages: messages,
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
        resources.unload()
        loadedModelURL = nil
    }

    private func generate(
        modelURL: URL,
        descriptor: OnDeviceModelDescriptor,
        messages: [ModelChatMessage],
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) throws {
        try Task.checkCancellation()
        try loadModelIfNeeded(at: modelURL, descriptor: descriptor)

        guard let context = resources.context,
              let vocab = resources.vocab else {
            throw OnDeviceInferenceError.modelNotLoaded
        }

        let maximumPromptTokens = descriptor.contextLength
            - descriptor.maximumOutputTokens
        var retainedMessages = messages
        var prompt = try QwenChatPromptFormatter.format(
            messages: retainedMessages
        )
        var promptTokens = try tokenize(prompt, vocabulary: vocab)

        while promptTokens.count > maximumPromptTokens,
              retainedMessages.count > 1 {
            retainedMessages.removeFirst()
            while retainedMessages.count > 1,
                  retainedMessages.first?.role == .assistant {
                retainedMessages.removeFirst()
            }
            prompt = try QwenChatPromptFormatter.format(
                messages: retainedMessages
            )
            promptTokens = try tokenize(prompt, vocabulary: vocab)
        }

        guard promptTokens.count <= maximumPromptTokens else {
            throw OnDeviceInferenceError.contextTooLarge
        }

        let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())
        llama_sampler_chain_add(sampler, llama_sampler_init_top_k(20))
        llama_sampler_chain_add(sampler, llama_sampler_init_top_p(0.85, 1))
        llama_sampler_chain_add(sampler, llama_sampler_init_temp(0.15))
        llama_sampler_chain_add(sampler, llama_sampler_init_dist(0x52434F44))
        defer {
            llama_sampler_free(sampler)
            llama_memory_clear(llama_get_memory(context), true)
        }

        var batch = llama_batch_init(512, 0, 1)
        defer {
            llama_batch_free(batch)
        }

        llama_memory_clear(llama_get_memory(context), true)
        try decodePrompt(promptTokens, context: context, batch: &batch)

        var position = Int32(promptTokens.count)
        var pendingUTF8: [UInt8] = []
        var generatedText = ""

        for _ in 0..<descriptor.maximumOutputTokens {
            try Task.checkCancellation()

            let token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, token) {
                break
            }
            llama_sampler_accept(sampler, token)

            pendingUTF8.append(contentsOf: tokenBytes(token, vocabulary: vocab))
            if let piece = String(bytes: pendingUTF8, encoding: .utf8) {
                pendingUTF8.removeAll(keepingCapacity: true)
                generatedText += piece
                continuation.yield(piece)
            }

            clearBatch(&batch)
            addToken(
                token,
                position: position,
                logits: true,
                to: &batch
            )
            guard llama_decode(context, batch) == 0 else {
                throw OnDeviceInferenceError.decodeFailed
            }
            position += 1
        }

        if !pendingUTF8.isEmpty {
            let tail = String(decoding: pendingUTF8, as: UTF8.self)
            generatedText += tail
            continuation.yield(tail)
        }

        guard !generatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OnDeviceInferenceError.emptyCompletion
        }
    }

    private func loadModelIfNeeded(
        at modelURL: URL,
        descriptor: OnDeviceModelDescriptor
    ) throws {
        let normalizedURL = modelURL.standardizedFileURL
        if loadedModelURL == normalizedURL,
           resources.model != nil,
           resources.context != nil {
            return
        }

        unload()
        var modelParameters = llama_model_default_params()
        modelParameters.check_tensors = true
#if targetEnvironment(simulator)
        modelParameters.n_gpu_layers = 0
#else
        modelParameters.n_gpu_layers = 99
#endif

        guard let loadedModel = llama_model_load_from_file(
            normalizedURL.path,
            modelParameters
        ) else {
            throw OnDeviceInferenceError.modelLoadFailed
        }

        var contextParameters = llama_context_default_params()
        contextParameters.n_ctx = UInt32(descriptor.contextLength)
        contextParameters.n_batch = 512
        contextParameters.n_ubatch = 512
        let threads = max(1, min(6, ProcessInfo.processInfo.activeProcessorCount - 2))
        contextParameters.n_threads = Int32(threads)
        contextParameters.n_threads_batch = Int32(threads)

        guard let loadedContext = llama_init_from_model(
            loadedModel,
            contextParameters
        ) else {
            llama_model_free(loadedModel)
            throw OnDeviceInferenceError.contextCreationFailed
        }

        resources.model = loadedModel
        resources.context = loadedContext
        resources.vocab = llama_model_get_vocab(loadedModel)
        loadedModelURL = normalizedURL
    }

    private func decodePrompt(
        _ tokens: [llama_token],
        context: OpaquePointer,
        batch: inout llama_batch
    ) throws {
        var offset = 0
        while offset < tokens.count {
            try Task.checkCancellation()
            clearBatch(&batch)
            let end = min(offset + 512, tokens.count)
            for index in offset..<end {
                addToken(
                    tokens[index],
                    position: Int32(index),
                    logits: index == tokens.count - 1,
                    to: &batch
                )
            }
            guard llama_decode(context, batch) == 0 else {
                throw OnDeviceInferenceError.decodeFailed
            }
            offset = end
        }
    }

    private func tokenize(
        _ text: String,
        vocabulary: OpaquePointer
    ) throws -> [llama_token] {
        let utf8Count = text.utf8.count
        guard utf8Count <= Int(Int32.max) else {
            throw OnDeviceInferenceError.contextTooLarge
        }

        var tokens = [llama_token](repeating: 0, count: max(32, utf8Count + 32))
        var count = text.withCString { pointer in
            llama_tokenize(
                vocabulary,
                pointer,
                Int32(utf8Count),
                &tokens,
                Int32(tokens.count),
                true,
                true
            )
        }
        if count < 0 {
            tokens = [llama_token](repeating: 0, count: Int(-count))
            count = text.withCString { pointer in
                llama_tokenize(
                    vocabulary,
                    pointer,
                    Int32(utf8Count),
                    &tokens,
                    Int32(tokens.count),
                    true,
                    true
                )
            }
        }
        guard count > 0 else {
            throw OnDeviceInferenceError.tokenizationFailed
        }
        return Array(tokens.prefix(Int(count)))
    }

    private func tokenBytes(
        _ token: llama_token,
        vocabulary: OpaquePointer
    ) -> [UInt8] {
        var bytes = [CChar](repeating: 0, count: 64)
        var count = llama_token_to_piece(
            vocabulary,
            token,
            &bytes,
            Int32(bytes.count),
            0,
            false
        )
        if count < 0 {
            bytes = [CChar](repeating: 0, count: Int(-count))
            count = llama_token_to_piece(
                vocabulary,
                token,
                &bytes,
                Int32(bytes.count),
                0,
                false
            )
        }
        guard count > 0 else {
            return []
        }
        return bytes.prefix(Int(count)).map { UInt8(bitPattern: $0) }
    }

    private func clearBatch(_ batch: inout llama_batch) {
        batch.n_tokens = 0
    }

    private func addToken(
        _ token: llama_token,
        position: llama_pos,
        logits: Bool,
        to batch: inout llama_batch
    ) {
        let index = Int(batch.n_tokens)
        batch.token[index] = token
        batch.pos[index] = position
        batch.n_seq_id[index] = 1
        batch.seq_id[index]![0] = 0
        batch.logits[index] = logits ? 1 : 0
        batch.n_tokens += 1
    }
}

private final class OnDeviceLlamaResources: @unchecked Sendable {
    var model: OpaquePointer?
    var context: OpaquePointer?
    var vocab: OpaquePointer?

    init() {
        llama_backend_init()
    }

    deinit {
        unload()
        llama_backend_free()
    }

    func unload() {
        if let context {
            llama_free(context)
        }
        if let model {
            llama_model_free(model)
        }
        context = nil
        model = nil
        vocab = nil
    }
}

enum OnDeviceInferenceError: LocalizedError {
    case modelNotLoaded
    case modelLoadFailed
    case contextCreationFailed
    case contextTooLarge
    case tokenizationFailed
    case decodeFailed
    case emptyCompletion

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            "내부 모델이 메모리에 로드되지 않았습니다."
        case .modelLoadFailed:
            "내부 GGUF 모델을 불러오지 못했습니다."
        case .contextCreationFailed:
            "내부 모델의 추론 컨텍스트를 만들지 못했습니다."
        case .contextTooLarge:
            "마지막 요청이 내부 모델의 컨텍스트 한도를 초과했습니다."
        case .tokenizationFailed:
            "대화를 내부 모델 토큰으로 변환하지 못했습니다."
        case .decodeFailed:
            "내부 모델 추론 중 llama.cpp 디코딩이 실패했습니다."
        case .emptyCompletion:
            "내부 모델이 비어 있는 응답을 생성했습니다."
        }
    }
}
