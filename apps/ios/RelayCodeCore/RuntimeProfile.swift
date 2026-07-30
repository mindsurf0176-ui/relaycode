import Foundation

public enum ModelConnectionKind: String, Codable, CaseIterable, Sendable {
    case pairedCodex
    case openAICompatible
    case appleFoundationModel
    case downloadedOnDevice
}

public struct OpenAICompatibleEndpoint: Codable, Hashable, Sendable {
    public let baseURL: URL

    public init(baseURL: URL) throws {
        guard let components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              scheme == "https" || scheme == "http" else {
            throw RuntimeProfileError.invalidBaseURL
        }
        let isLoopback = ["127.0.0.1", "localhost", "::1"].contains(host)
        guard scheme == "https" || isLoopback else {
            throw RuntimeProfileError.insecureRemoteProvider
        }
        guard components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            throw RuntimeProfileError.providerURLContainsSecrets
        }
        self.baseURL = baseURL
    }

    public var modelsURL: URL {
        baseURL.appendingPathComponent("models", isDirectory: false)
    }

    public var chatCompletionsURL: URL {
        baseURL.appendingPathComponent("chat/completions", isDirectory: false)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(baseURL: container.decode(URL.self, forKey: .baseURL))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(baseURL, forKey: .baseURL)
    }

    private enum CodingKeys: String, CodingKey {
        case baseURL
    }
}

public struct ModelConnectionConfiguration: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let displayName: String
    public let kind: ModelConnectionKind
    public let baseURL: URL?
    public let modelID: String?
    public let credentialReference: String?

    public init(
        id: String,
        displayName: String,
        kind: ModelConnectionKind,
        baseURL: URL? = nil,
        modelID: String? = nil,
        credentialReference: String? = nil
    ) throws {
        let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedModelID = Self.nonEmpty(modelID)
        let normalizedCredentialReference = Self.nonEmpty(credentialReference)

        guard normalizedID.range(
            of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"#,
            options: .regularExpression
        ) != nil else {
            throw RuntimeProfileError.invalidIdentifier
        }
        guard !normalizedName.isEmpty, normalizedName.count <= 80 else {
            throw RuntimeProfileError.invalidDisplayName
        }
        if let normalizedCredentialReference {
            guard normalizedCredentialReference.range(
                of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#,
                options: .regularExpression
            ) != nil else {
                throw RuntimeProfileError.invalidCredentialReference
            }
        }

        switch kind {
        case .pairedCodex:
            guard baseURL == nil, normalizedModelID == nil, normalizedCredentialReference == nil else {
                throw RuntimeProfileError.unexpectedProviderFields
            }
        case .openAICompatible:
            guard let baseURL else {
                throw RuntimeProfileError.missingBaseURL
            }
            guard normalizedModelID != nil else {
                throw RuntimeProfileError.missingModelID
            }
            _ = try OpenAICompatibleEndpoint(baseURL: baseURL)
        case .appleFoundationModel:
            guard baseURL == nil, normalizedModelID == nil, normalizedCredentialReference == nil else {
                throw RuntimeProfileError.unexpectedProviderFields
            }
        case .downloadedOnDevice:
            guard normalizedModelID != nil else {
                throw RuntimeProfileError.missingModelID
            }
            guard baseURL == nil, normalizedCredentialReference == nil else {
                throw RuntimeProfileError.unexpectedProviderFields
            }
        }

        self.id = normalizedID
        self.displayName = normalizedName
        self.kind = kind
        self.baseURL = baseURL
        self.modelID = normalizedModelID
        self.credentialReference = normalizedCredentialReference
    }

    public static func pairedCodex() throws -> ModelConnectionConfiguration {
        try ModelConnectionConfiguration(
            id: "paired-codex",
            displayName: "Paired Codex",
            kind: .pairedCodex
        )
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(String.self, forKey: .id),
            displayName: container.decode(String.self, forKey: .displayName),
            kind: container.decode(ModelConnectionKind.self, forKey: .kind),
            baseURL: container.decodeIfPresent(URL.self, forKey: .baseURL),
            modelID: container.decodeIfPresent(String.self, forKey: .modelID),
            credentialReference: container.decodeIfPresent(String.self, forKey: .credentialReference)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(baseURL, forKey: .baseURL)
        try container.encodeIfPresent(modelID, forKey: .modelID)
        try container.encodeIfPresent(credentialReference, forKey: .credentialReference)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case kind
        case baseURL
        case modelID
        case credentialReference
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !normalized.isEmpty else {
            return nil
        }
        return normalized
    }

}

public enum ExecutionRuntimeKind: String, Codable, CaseIterable, Sendable {
    case pairedHost
    case nativeSandbox
    case wasiSandbox
    case interpretedLinux

    public var isOnDevice: Bool {
        self != .pairedHost
    }

    public var isFullLinuxVM: Bool {
        false
    }
}

public struct RuntimeProfile: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let displayName: String
    public let model: ModelConnectionConfiguration
    public let execution: ExecutionRuntimeKind

    public init(
        id: String,
        displayName: String,
        model: ModelConnectionConfiguration,
        execution: ExecutionRuntimeKind
    ) throws {
        let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedID.range(
            of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"#,
            options: .regularExpression
        ) != nil else {
            throw RuntimeProfileError.invalidIdentifier
        }
        guard !normalizedName.isEmpty, normalizedName.count <= 80 else {
            throw RuntimeProfileError.invalidDisplayName
        }

        self.id = normalizedID
        self.displayName = normalizedName
        self.model = model
        self.execution = execution
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(String.self, forKey: .id),
            displayName: container.decode(String.self, forKey: .displayName),
            model: container.decode(ModelConnectionConfiguration.self, forKey: .model),
            execution: container.decode(ExecutionRuntimeKind.self, forKey: .execution)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(model, forKey: .model)
        try container.encode(execution, forKey: .execution)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case model
        case execution
    }
}

public enum RuntimeProfileError: LocalizedError, Equatable {
    case invalidIdentifier
    case invalidDisplayName
    case missingBaseURL
    case invalidBaseURL
    case insecureRemoteProvider
    case providerURLContainsSecrets
    case invalidCredentialReference
    case missingModelID
    case unexpectedProviderFields

    public var errorDescription: String? {
        switch self {
        case .invalidIdentifier:
            "프로필 식별자는 영문, 숫자, 점, 밑줄, 하이픈만 사용할 수 있습니다."
        case .invalidDisplayName:
            "프로필 이름이 비어 있거나 너무 깁니다."
        case .missingBaseURL:
            "온프레미스 모델 주소가 필요합니다."
        case .invalidBaseURL:
            "모델 주소는 올바른 HTTP 또는 HTTPS URL이어야 합니다."
        case .insecureRemoteProvider:
            "원격 모델 연결에는 HTTPS가 필요합니다."
        case .providerURLContainsSecrets:
            "모델 주소에 인증 정보, 쿼리, 또는 프래그먼트를 넣을 수 없습니다."
        case .invalidCredentialReference:
            "모델 인증정보 식별자가 올바르지 않습니다."
        case .missingModelID:
            "모델 식별자가 필요합니다."
        case .unexpectedProviderFields:
            "선택한 모델 연결 방식에서 지원하지 않는 설정이 포함되어 있습니다."
        }
    }
}
