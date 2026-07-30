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
    @Published private(set) var descriptor: OnDeviceModelDescriptor
    @Published private(set) var performanceMode: OnDevicePerformanceMode
    @Published private(set) var activeConfiguration: OnDeviceInferenceConfiguration
    @Published private(set) var lastMetrics: OnDeviceInferenceMetrics?
    @Published private(set) var isBenchmarking = false
    @Published private(set) var benchmarkErrorMessage: String?

    private let engine = OnDeviceInferenceEngine()
    private let fileManager: FileManager
    private let session: URLSession
    private let defaults: UserDefaults
    private var downloadTask: URLSessionDownloadTask?
    private var progressTask: Task<Void, Never>?
    private var idleUnloadTask: Task<Void, Never>?
    private var downloadGeneration = UUID()

    init(
        fileManager: FileManager = .default,
        session: URLSession = .shared,
        defaults: UserDefaults = .standard
    ) {
        self.fileManager = fileManager
        self.session = session
        self.defaults = defaults

        let storedModelID = defaults.string(forKey: DefaultsKey.modelID)
        let initialDescriptor = OnDeviceModelDescriptor.relayCodeModels.first {
            $0.id == storedModelID
        } ?? OnDeviceModelDescriptor.recommended(
            forPhysicalMemory: ProcessInfo.processInfo.physicalMemory
        )
        let initialPerformanceMode = OnDevicePerformanceMode(
            rawValue: defaults.string(forKey: DefaultsKey.performanceMode) ?? ""
        ) ?? .automatic
        descriptor = initialDescriptor
        performanceMode = initialPerformanceMode
        activeConfiguration = Self.resolveConfiguration(
            mode: initialPerformanceMode,
            descriptor: initialDescriptor
        )

        Task {
            await refreshInstallation()
        }
    }

    var modelURL: URL {
        modelURL(for: descriptor)
    }

    var availableModels: [OnDeviceModelDescriptor] {
        OnDeviceModelDescriptor.relayCodeModels
    }

    var isQualityModelRecommended: Bool {
        ProcessInfo.processInfo.physicalMemory
            >= OnDeviceModelDescriptor.relayCodeCoderQuality.minimumRecommendedMemoryBytes
    }

    func selectModel(id: String) {
        guard let selected = availableModels.first(where: { $0.id == id }),
              selected != descriptor else {
            return
        }

        cancelDownload()
        idleUnloadTask?.cancel()
        descriptor = selected
        defaults.set(selected.id, forKey: DefaultsKey.modelID)
        activeConfiguration = Self.resolveConfiguration(
            mode: performanceMode,
            descriptor: selected
        )
        lastMetrics = nil
        installationState = .checking
        Task {
            await engine.unload()
            await refreshInstallation()
        }
    }

    func setPerformanceMode(_ mode: OnDevicePerformanceMode) {
        guard performanceMode != mode else {
            return
        }
        performanceMode = mode
        defaults.set(mode.rawValue, forKey: DefaultsKey.performanceMode)
        activeConfiguration = Self.resolveConfiguration(
            mode: mode,
            descriptor: descriptor
        )
        lastMetrics = nil
        Task {
            await engine.unload()
        }
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

        let requestedDescriptor = descriptor
        let stagingURL = modelDirectory.appendingPathComponent(
            ".\(requestedDescriptor.filename).\(generation.uuidString).download",
            isDirectory: false
        )
        let expectedByteCount = requestedDescriptor.expectedByteCount
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
                    generation: generation,
                    descriptor: requestedDescriptor
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
        idleUnloadTask?.cancel()
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
        idleUnloadTask?.cancel()
        activeConfiguration = Self.resolveConfiguration(
            mode: performanceMode,
            descriptor: descriptor
        )
        var resultPieces: [String] = []
        var pendingPieces: [String] = []
        var lastFlush = Date.timeIntervalSinceReferenceDate
        do {
            let stream = engine.tokenStream(
                modelURL: modelURL,
                descriptor: descriptor,
                messages: messages,
                configuration: activeConfiguration
            )
            for try await event in stream {
                try Task.checkCancellation()
                switch event {
                case let .token(token):
                    if inferenceState == .loading {
                        inferenceState = .generating
                    }
                    resultPieces.append(token)
                    pendingPieces.append(token)
                    let now = Date.timeIntervalSinceReferenceDate
                    if now - lastFlush >= 0.05 {
                        onToken(pendingPieces.joined())
                        pendingPieces.removeAll(keepingCapacity: true)
                        lastFlush = now
                    }
                case let .metrics(metrics):
                    lastMetrics = metrics
                }
            }
            if !pendingPieces.isEmpty {
                onToken(pendingPieces.joined())
            }
            inferenceState = .idle
            scheduleIdleUnload()
            return resultPieces.joined()
        } catch {
            inferenceState = .idle
            scheduleIdleUnload()
            throw error
        }
    }

    func unload() async {
        idleUnloadTask?.cancel()
        inferenceState = .idle
        await engine.unload()
    }

    func runBenchmark() async {
        guard installationState.isReady,
              inferenceState == .idle,
              !isBenchmarking else {
            return
        }
        isBenchmarking = true
        inferenceState = .loading
        benchmarkErrorMessage = nil
        defer {
            isBenchmarking = false
            inferenceState = .idle
        }

        do {
            await engine.unload()
            activeConfiguration = Self.resolveConfiguration(
                mode: performanceMode,
                descriptor: descriptor
            )
            let stream = engine.tokenStream(
                modelURL: modelURL,
                descriptor: descriptor,
                messages: [
                    ModelChatMessage(
                        role: .user,
                        content: "Swift로 정수 배열의 합을 반환하는 함수를 짧게 작성해줘."
                    ),
                ],
                configuration: activeConfiguration,
                maximumOutputTokens: 64
            )
            for try await event in stream {
                if case let .metrics(metrics) = event {
                    lastMetrics = metrics
                }
            }
            scheduleIdleUnload()
        } catch {
            benchmarkErrorMessage = "성능 측정 실패: \(error.localizedDescription)"
        }
    }

    private func finishDownload(
        stagingURL: URL,
        failureMessage: String?,
        generation: UUID,
        descriptor requestedDescriptor: OnDeviceModelDescriptor
    ) async {
        guard generation == downloadGeneration,
              requestedDescriptor == descriptor else {
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
            try await Task.detached(priority: .utility) {
                try OnDeviceModelArtifactVerifier.verify(
                    fileURL: stagingURL,
                    descriptor: requestedDescriptor
                )
            }.value

            let finalModelURL = modelURL(for: requestedDescriptor)
            if fileManager.fileExists(atPath: finalModelURL.path) {
                _ = try fileManager.replaceItemAt(
                    finalModelURL,
                    withItemAt: stagingURL
                )
            } else {
                try fileManager.moveItem(at: stagingURL, to: finalModelURL)
            }
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.complete],
                ofItemAtPath: finalModelURL.path
            )
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var finalURL = finalModelURL
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
              available >= descriptor.expectedByteCount + 600_000_000 else {
            throw OnDeviceModelServiceError.insufficientStorage
        }
    }

    private func modelURL(for descriptor: OnDeviceModelDescriptor) -> URL {
        modelDirectory.appendingPathComponent(
            descriptor.filename,
            isDirectory: false
        )
    }

    private func scheduleIdleUnload() {
        idleUnloadTask?.cancel()
        idleUnloadTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(300))
            guard !Task.isCancelled, let self else {
                return
            }
            await self.unload()
        }
    }

    private static func resolveConfiguration(
        mode: OnDevicePerformanceMode,
        descriptor: OnDeviceModelDescriptor
    ) -> OnDeviceInferenceConfiguration {
        OnDeviceInferenceConfiguration.resolve(
            requestedMode: mode,
            environment: OnDeviceRuntimeEnvironment(
                physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
                processorCount: ProcessInfo.processInfo.activeProcessorCount,
                isLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
                thermalLevel: ProcessInfo.processInfo.relayCodeThermalLevel
            ),
            descriptor: descriptor
        )
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
            "내부 모델 설치에는 모델 용량 외에 최소 600MB의 여유 공간이 더 필요합니다."
        case .modelNotInstalled:
            "모델 탭에서 내부 모델을 먼저 다운로드하세요."
        }
    }
}

private enum DefaultsKey {
    static let modelID = "relaycode.on-device.model-id"
    static let performanceMode = "relaycode.on-device.performance-mode"
}

private extension ProcessInfo {
    var relayCodeThermalLevel: OnDeviceThermalLevel {
        switch thermalState {
        case .nominal:
            .nominal
        case .fair:
            .fair
        case .serious:
            .serious
        case .critical:
            .critical
        @unknown default:
            .serious
        }
    }
}
