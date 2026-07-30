import Foundation

public struct ProviderModel: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let ownedBy: String?

    public init(id: String, ownedBy: String? = nil) {
        self.id = id
        self.ownedBy = ownedBy
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case ownedBy = "owned_by"
    }
}

public enum ModelChatRole: String, Codable, Hashable, Sendable {
    case system
    case user
    case assistant
}

public struct ModelChatMessage: Encodable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let role: ModelChatRole
    public let content: String

    public init(id: UUID = UUID(), role: ModelChatRole, content: String) {
        self.id = id
        self.role = role
        self.content = content
    }

    private enum CodingKeys: String, CodingKey {
        case role
        case content
    }
}

public struct OpenAICompatibleModelClient: Sendable {
    private static let maximumResponseBytes = 2 * 1_024 * 1_024
    private static let maximumCompletionBytes = 8 * 1_024 * 1_024
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func listModels(
        endpoint: OpenAICompatibleEndpoint,
        bearerToken: String? = nil
    ) async throws -> [ProviderModel] {
        let request = try modelsRequest(endpoint: endpoint, bearerToken: bearerToken)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ModelProviderClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ModelProviderClientError.httpStatus(http.statusCode)
        }
        guard data.count <= Self.maximumResponseBytes else {
            throw ModelProviderClientError.responseTooLarge
        }
        return try decodeModels(from: data)
    }

    public func complete(
        endpoint: OpenAICompatibleEndpoint,
        modelID: String,
        messages: [ModelChatMessage],
        bearerToken: String? = nil
    ) async throws -> String {
        let request = try completionRequest(
            endpoint: endpoint,
            modelID: modelID,
            messages: messages,
            bearerToken: bearerToken
        )
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ModelProviderClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ModelProviderClientError.httpStatus(http.statusCode)
        }
        guard data.count <= Self.maximumCompletionBytes else {
            throw ModelProviderClientError.responseTooLarge
        }
        return try decodeCompletion(from: data)
    }

    func modelsRequest(
        endpoint: OpenAICompatibleEndpoint,
        bearerToken: String?
    ) throws -> URLRequest {
        var request = URLRequest(url: endpoint.modelsURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let token = bearerToken?.trimmingCharacters(in: .whitespacesAndNewlines),
           !token.isEmpty {
            let containsHeaderBreak = token.unicodeScalars.contains {
                $0.value == 0x0A || $0.value == 0x0D
            }
            guard !containsHeaderBreak else {
                throw ModelProviderClientError.invalidCredential
            }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    func completionRequest(
        endpoint: OpenAICompatibleEndpoint,
        modelID: String,
        messages: [ModelChatMessage],
        bearerToken: String?
    ) throws -> URLRequest {
        let normalizedModelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedModelID.isEmpty, normalizedModelID.count <= 256 else {
            throw ModelProviderClientError.invalidModelID
        }
        guard !messages.isEmpty,
              messages.count <= 64,
              messages.allSatisfy({
                  !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && $0.content.utf8.count <= 128 * 1_024
              }) else {
            throw ModelProviderClientError.invalidMessages
        }

        var request = URLRequest(url: endpoint.chatCompletionsURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        try setAuthorizationHeader(bearerToken, on: &request)

        do {
            request.httpBody = try JSONEncoder().encode(
                CompletionRequestPayload(
                    model: normalizedModelID,
                    messages: messages,
                    stream: false
                )
            )
        } catch {
            throw ModelProviderClientError.invalidMessages
        }
        return request
    }

    func decodeModels(from data: Data) throws -> [ProviderModel] {
        let payload: ProviderModelsPayload
        do {
            payload = try JSONDecoder().decode(ProviderModelsPayload.self, from: data)
        } catch {
            throw ModelProviderClientError.invalidPayload
        }

        var seen = Set<String>()
        let models = payload.data.compactMap { model -> ProviderModel? in
            let id = model.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, seen.insert(id).inserted else {
                return nil
            }
            return ProviderModel(id: id, ownedBy: model.ownedBy)
        }
        .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }

        guard !models.isEmpty else {
            throw ModelProviderClientError.noModels
        }
        return models
    }

    func decodeCompletion(from data: Data) throws -> String {
        let payload: CompletionResponsePayload
        do {
            payload = try JSONDecoder().decode(CompletionResponsePayload.self, from: data)
        } catch {
            throw ModelProviderClientError.invalidPayload
        }
        guard let content = payload.choices.first?.message.content
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty else {
            throw ModelProviderClientError.emptyCompletion
        }
        return content
    }

    private func setAuthorizationHeader(
        _ bearerToken: String?,
        on request: inout URLRequest
    ) throws {
        guard let token = bearerToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            return
        }
        let containsHeaderBreak = token.unicodeScalars.contains {
            $0.value == 0x0A || $0.value == 0x0D
        }
        guard !containsHeaderBreak else {
            throw ModelProviderClientError.invalidCredential
        }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
}

private struct ProviderModelsPayload: Decodable {
    let data: [ProviderModel]
}

private struct CompletionRequestPayload: Encodable {
    let model: String
    let messages: [ModelChatMessage]
    let stream: Bool
}

private struct CompletionResponsePayload: Decodable {
    let choices: [CompletionChoice]
}

private struct CompletionChoice: Decodable {
    let message: CompletionMessage
}

private struct CompletionMessage: Decodable {
    let content: String
}

public enum ModelProviderClientError: LocalizedError, Equatable {
    case invalidResponse
    case httpStatus(Int)
    case responseTooLarge
    case invalidPayload
    case noModels
    case invalidCredential
    case invalidModelID
    case invalidMessages
    case emptyCompletion

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "모델 서버가 올바른 HTTP 응답을 반환하지 않았습니다."
        case let .httpStatus(status):
            "모델 서버 연결에 실패했습니다. HTTP \(status)"
        case .responseTooLarge:
            "모델 목록 응답이 허용 크기를 초과했습니다."
        case .invalidPayload:
            "모델 서버의 /models 응답 형식을 읽을 수 없습니다."
        case .noModels:
            "모델 서버에서 사용할 수 있는 모델을 찾지 못했습니다."
        case .invalidCredential:
            "모델 서버 인증 정보가 올바르지 않습니다."
        case .invalidModelID:
            "사용할 모델 식별자가 올바르지 않습니다."
        case .invalidMessages:
            "모델에 보낼 대화가 비어 있거나 허용 크기를 초과했습니다."
        case .emptyCompletion:
            "모델이 비어 있는 응답을 반환했습니다."
        }
    }
}
