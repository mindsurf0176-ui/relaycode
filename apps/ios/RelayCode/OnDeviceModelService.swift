import Foundation
import RelayCodeCore

enum OnDeviceModelInstallationState: Equatable {
    case checking
    case notInstalled
    case downloading(progress: Double)
    case verifying
    case ready
    case failed(message: String)

    var isReady: Bool {
        self == .ready
    }
}

enum OnDeviceInferenceState: Equatable {
    case idle
    case loading
    case generating
}

@MainActor
final class OnDeviceModelService: ObservableObject {
    @Published private(set) var installationState: OnDeviceModelInstallationState = .checking
    @Published private(set) var inferenceState: OnDeviceInferenceState = .idle

    let descriptor = OnDeviceModelDescriptor.relayCodeCoder

    private let engine = OnDeviceInferenceEngine()
    private let fileManager: FileManager
    private let session: URLSession
    private var downloadTask: URLSessionDownloadTask?
    private var progressTask: Task<Void, Never>?
    private var downloadGeneration = UUID()

    init(
        fileManager: FileManager = .default,
        session: URLSession = .shared
    ) {
        self.fileManager = fileManager
        self.session = session
        Task {
            await refreshInstallation()
        }
    }

    var modelURL: URL {
        modelDirectory.appendingPathComponent(
            descriptor.filename,
            isDirectory: false
        )
    }

    func refreshInstallation() async {
        guard downloadTask == nil else {
            return
        }
        guard fileManager.fileExists(atPath: modelURL.path) else {
            installationState = .notInstalled
            return
        }

        installationState = .verifying
        do {
            let url = modelURL
            let descriptor = descriptor
            try await Task.detached(priority: .utility) {
                try OnDeviceModelArtifactVerifier.verify(
                    fileURL: url,
                    descriptor: descriptor
                )
            }.value
            removeLegacyModels()
            installationState = .ready
        } catch {
            installationState = .failed(message: error.localizedDescription)
        }
    }

    func download() {
        guard downloadTask == nil else {
            return
        }

        do {
            try prepareModelDirectory()
            try requireAvailableStorage()
        } catch {
            installationState = .failed(message: error.localizedDescription)
            return
        }

        let generation = UUID()
        downloadGeneration = generation
        installationState = .downloading(progress: 0)

        var request = URLRequest(url: descriptor.downloadURL)
        request.timeoutInterval = 3_600
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")

        let stagingURL = modelDirectory.appendingPathComponent(
            ".\(descriptor.filename).\(generation.uuidString).download",
            isDirectory: false
        )
        let expectedByteCount = descriptor.expectedByteCount
        let task = session.downloadTask(with: request) { [weak self] temporaryURL, response, error in
            var failureMessage: String?

            if let error {
                failureMessage = error.localizedDescription
            } else if let http = response as? HTTPURLResponse,
                      !(200..<300).contains(http.statusCode) {
                failureMessage = "내부 모델 다운로드가 HTTP \(http.statusCode)로 실패했습니다."
            } else if let expected = response?.expectedContentLength,
                      expected > 0,
                      expected != expectedByteCount {
                failureMessage = "모델 서버가 예상과 다른 크기의 파일을 반환했습니다."
            } else if let temporaryURL {
                do {
                    if FileManager.default.fileExists(atPath: stagingURL.path) {
                        try FileManager.default.removeItem(at: stagingURL)
                    }
                    try FileManager.default.moveItem(
                        at: temporaryURL,
                        to: stagingURL
                    )
                } catch {
                    failureMessage = error.localizedDescription
                }
            } else {
                failureMessage = "내부 모델 다운로드 파일을 찾지 못했습니다."
            }

            Task { @MainActor [weak self] in
                await self?.finishDownload(
                    stagingURL: stagingURL,
                    failureMessage: failureMessage,
                    generation: generation
                )
            }
        }

        downloadTask = task
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let task = self.downloadTask else {
                    return
                }
                let progress = task.progress.fractionCompleted
                self.installationState = .downloading(
                    progress: max(0, min(1, progress))
                )
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        task.resume()
    }

    func cancelDownload() {
        downloadGeneration = UUID()
        downloadTask?.cancel()
        downloadTask = nil
        progressTask?.cancel()
        progressTask = nil
        if fileManager.fileExists(atPath: modelURL.path) {
            installationState = .checking
            Task {
                await refreshInstallation()
            }
        } else {
            installationState = .notInstalled
        }
    }

    func removeModel() async {
        downloadGeneration = UUID()
        downloadTask?.cancel()
        downloadTask = nil
        progressTask?.cancel()
        progressTask = nil
        await engine.unload()
        do {
            if fileManager.fileExists(atPath: modelURL.path) {
                try fileManager.removeItem(at: modelURL)
            }
            removeLegacyModels()
            installationState = .notInstalled
        } catch {
            installationState = .failed(message: error.localizedDescription)
        }
    }

    func complete(
        messages: [ModelChatMessage],
        onToken: @escaping (String) -> Void
    ) async throws -> String {
        guard installationState.isReady,
              fileManager.fileExists(atPath: modelURL.path) else {
            throw OnDeviceModelServiceError.modelNotInstalled
        }

        inferenceState = .loading
        var result = ""
        do {
            let stream = engine.tokenStream(
                modelURL: modelURL,
                descriptor: descriptor,
                messages: messages
            )
            for try await token in stream {
                try Task.checkCancellation()
                if inferenceState == .loading {
                    inferenceState = .generating
                }
                result += token
                onToken(token)
            }
            inferenceState = .idle
            return result
        } catch {
            inferenceState = .idle
            throw error
        }
    }

    func unload() async {
        inferenceState = .idle
        await engine.unload()
    }

    private func finishDownload(
        stagingURL: URL,
        failureMessage: String?,
        generation: UUID
    ) async {
        guard generation == downloadGeneration else {
            try? fileManager.removeItem(at: stagingURL)
            return
        }

        downloadTask = nil
        progressTask?.cancel()
        progressTask = nil

        if let failureMessage {
            try? fileManager.removeItem(at: stagingURL)
            installationState = .failed(message: failureMessage)
            return
        }

        installationState = .verifying
        do {
            let descriptor = descriptor
            try await Task.detached(priority: .utility) {
                try OnDeviceModelArtifactVerifier.verify(
                    fileURL: stagingURL,
                    descriptor: descriptor
                )
            }.value

            if fileManager.fileExists(atPath: modelURL.path) {
                _ = try fileManager.replaceItemAt(
                    modelURL,
                    withItemAt: stagingURL
                )
            } else {
                try fileManager.moveItem(at: stagingURL, to: modelURL)
            }
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.complete],
                ofItemAtPath: modelURL.path
            )
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var finalURL = modelURL
            try finalURL.setResourceValues(values)
            removeLegacyModels()
            installationState = .ready
        } catch {
            try? fileManager.removeItem(at: stagingURL)
            installationState = .failed(message: error.localizedDescription)
        }
    }

    private var modelDirectory: URL {
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return applicationSupport
            .appendingPathComponent("RelayCode", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    private func prepareModelDirectory() throws {
        try fileManager.createDirectory(
            at: modelDirectory,
            withIntermediateDirectories: true
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var directory = modelDirectory
        try directory.setResourceValues(values)
    }

    private func requireAvailableStorage() throws {
        let values = try modelDirectory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        guard let available = values.volumeAvailableCapacityForImportantUsage,
              available >= descriptor.expectedByteCount + 300_000_000 else {
            throw OnDeviceModelServiceError.insufficientStorage
        }
    }

    private func removeLegacyModels() {
        for filename in OnDeviceModelDescriptor.legacyFilenames
        where filename != descriptor.filename {
            let legacyURL = modelDirectory.appendingPathComponent(
                filename,
                isDirectory: false
            )
            if fileManager.fileExists(atPath: legacyURL.path) {
                try? fileManager.removeItem(at: legacyURL)
            }
        }
    }
}

enum OnDeviceModelServiceError: LocalizedError {
    case insufficientStorage
    case modelNotInstalled

    var errorDescription: String? {
        switch self {
        case .insufficientStorage:
            "내부 모델 설치에는 모델 용량 외에 최소 300MB의 여유 공간이 더 필요합니다."
        case .modelNotInstalled:
            "모델 탭에서 내부 모델을 먼저 다운로드하세요."
        }
    }
}
