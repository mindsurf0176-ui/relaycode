import CryptoKit
import Foundation

public struct OnDeviceModelDescriptor: Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let filename: String
    public let downloadURL: URL
    public let expectedByteCount: Int64
    public let expectedSHA256: String
    public let contextLength: Int
    public let maximumOutputTokens: Int

    public init(
        id: String,
        displayName: String,
        filename: String,
        downloadURL: URL,
        expectedByteCount: Int64,
        expectedSHA256: String,
        contextLength: Int,
        maximumOutputTokens: Int
    ) {
        precondition(expectedByteCount > 0)
        precondition(expectedSHA256.range(
            of: #"^[0-9a-f]{64}$"#,
            options: .regularExpression
        ) != nil)
        precondition(contextLength > maximumOutputTokens)

        self.id = id
        self.displayName = displayName
        self.filename = filename
        self.downloadURL = downloadURL
        self.expectedByteCount = expectedByteCount
        self.expectedSHA256 = expectedSHA256
        self.contextLength = contextLength
        self.maximumOutputTokens = maximumOutputTokens
    }

    public static let relayCodeCoder = OnDeviceModelDescriptor(
        id: "qwen2.5-coder-1.5b-instruct-q4_k_m",
        displayName: "Qwen2.5 Coder 1.5B",
        filename: "qwen2.5-coder-1.5b-instruct-q4_k_m.gguf",
        downloadURL: URL(
            string: "https://huggingface.co/Qwen/Qwen2.5-Coder-1.5B-Instruct-GGUF/resolve/f86cb2c1fa58255f8052cc32aeede1b7482d4361/qwen2.5-coder-1.5b-instruct-q4_k_m.gguf?download=true"
        )!,
        expectedByteCount: 1_117_320_768,
        expectedSHA256: "cc324af070c2ecbfd324a30884d2f951a7ff756aba85cb811a6ec436933bb046",
        contextLength: 8_192,
        maximumOutputTokens: 768
    )

    public static let legacyFilenames = [
        "qwen2.5-coder-0.5b-instruct-q4_0.gguf",
    ]

    public var formattedDownloadSize: String {
        ByteCountFormatter.string(
            fromByteCount: expectedByteCount,
            countStyle: .file
        )
    }
}

public enum OnDeviceModelArtifactVerifier {
    public static func verify(
        fileURL: URL,
        descriptor: OnDeviceModelDescriptor
    ) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard let byteCount = attributes[.size] as? NSNumber,
              byteCount.int64Value == descriptor.expectedByteCount else {
            throw OnDeviceModelArtifactError.invalidByteCount
        }

        let handle = try FileHandle(forReadingFrom: fileURL)
        defer {
            try? handle.close()
        }

        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty {
                break
            }
            hasher.update(data: data)
        }

        let digest = hasher.finalize().map {
            String(format: "%02x", $0)
        }.joined()
        guard digest == descriptor.expectedSHA256 else {
            throw OnDeviceModelArtifactError.invalidSHA256
        }
    }
}

public enum QwenChatPromptFormatter {
    public static func format(messages: [ModelChatMessage]) throws -> String {
        guard !messages.isEmpty, messages.count <= 32 else {
            throw OnDeviceModelArtifactError.invalidConversation
        }

        var prompt = """
        <|im_start|>system
        You are RelayCode, an offline coding assistant running privately on the user's device.
        Follow these rules:
        - Reply in the same language as the user unless asked otherwise.
        - Give the direct solution first. Prefer correct, complete, runnable code over generic advice.
        - Preserve the user's stack and constraints. Do not invent APIs, files, command results, or successful execution.
        - For debugging, identify the likely root cause and provide the smallest safe fix plus a verification step.
        - When critical context is missing, state one concise assumption or ask one focused question.
        - Keep explanations compact, but include important edge cases and security risks.<|im_end|>

        """

        for message in messages {
            let content = try sanitized(message.content)
            prompt += "<|im_start|>\(message.role.rawValue)\n\(content)<|im_end|>\n"
        }
        prompt += "<|im_start|>assistant\n"
        return prompt
    }

    private static func sanitized(_ content: String) throws -> String {
        let normalized = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized.utf8.count <= 64 * 1_024,
              !normalized.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw OnDeviceModelArtifactError.invalidConversation
        }

        return normalized
            .replacingOccurrences(of: "<|im_start|>", with: "‹|im_start|›")
            .replacingOccurrences(of: "<|im_end|>", with: "‹|im_end|›")
    }
}

public enum OnDeviceModelArtifactError: LocalizedError, Equatable {
    case invalidByteCount
    case invalidSHA256
    case invalidConversation

    public var errorDescription: String? {
        switch self {
        case .invalidByteCount:
            "다운로드한 모델의 파일 크기가 공식 배포본과 다릅니다."
        case .invalidSHA256:
            "다운로드한 모델의 SHA-256이 공식 배포본과 다릅니다."
        case .invalidConversation:
            "온디바이스 모델에 보낼 대화가 비어 있거나 너무 큽니다."
        }
    }
}
