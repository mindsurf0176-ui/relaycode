import Foundation
import RelayCodeCore

enum HostHealth: Equatable {
    case idle
    case checking
    case online(agent: String)
    case offline(message: String)
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var pairing: PairingConfiguration?
    @Published private(set) var health: HostHealth = .idle
    @Published private(set) var resumeGeneration = UUID()
    @Published var errorMessage: String?

    private let store: any PairingStoring
    private var healthTask: Task<Void, Never>?

    init(store: any PairingStoring = KeychainPairingStore()) {
        self.store = store
        do {
            pairing = try store.load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func importPairing(_ rawLink: String) {
        do {
            let value = try PairingConfiguration.parse(rawLink)
            try persist(value)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveFromWeb(token: String, bridge: String) {
        do {
            guard let bridgeURL = URL(string: bridge) else {
                throw PairingError.invalidBridge
            }
            try persist(PairingConfiguration(token: token, bridgeURL: bridgeURL))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func forgetPairing() {
        healthTask?.cancel()
        do {
            try store.delete()
        } catch {
            errorMessage = error.localizedDescription
        }
        pairing = nil
        health = .idle
    }

    func sceneBecameActive() {
        resumeGeneration = UUID()
        refreshHealth()
    }

    func refreshHealth() {
        healthTask?.cancel()
        guard let pairing else {
            health = .idle
            return
        }
        health = .checking
        healthTask = Task {
            var request = URLRequest(url: pairing.webURL.appending(path: "healthz"))
            request.timeoutInterval = 5
            request.cachePolicy = .reloadIgnoringLocalCacheData
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard !Task.isCancelled else { return }
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    throw HealthError.unavailable
                }
                let payload = try JSONDecoder().decode(HealthPayload.self, from: data)
                health = payload.ok ? .online(agent: payload.agent) : .offline(message: "Mac agent가 준비되지 않았습니다.")
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                health = .offline(message: "Mac에 연결할 수 없습니다.")
            }
        }
    }

    private func persist(_ value: PairingConfiguration) throws {
        try store.save(value)
        pairing = value
        errorMessage = nil
        resumeGeneration = UUID()
        refreshHealth()
    }
}

private struct HealthPayload: Decodable {
    let ok: Bool
    let agent: String
}

private enum HealthError: Error {
    case unavailable
}
