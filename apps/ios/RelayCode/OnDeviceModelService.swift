import Foundation
import RelayCodeCore

enum OnDeviceModelDownloadSession {
    static let identifier = "com.minseo.relaycode.on-device-model-download"
}

private struct OnDeviceModelDownloadMetadata: Codable, Sendable {
    let descriptorID: String
    let generation: UUID
    let stagingPath: String
    let expectedByteCount: Int64
}

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
final class OnDeviceModelService: NSObject, ObservableObject {
    @Published private(set) var installationState: OnDeviceModelInstallationState = .checking
    @Published private(set) var inferenceState: OnDeviceInferenceState = .idle
    @Published private(set) var descriptor: OnDeviceModelDescriptor
    @Published private(set) var performanceMode: OnDevicePerformanceMode
    @Published private(set) var activeConfiguration: OnDeviceInferenceConfiguration
    @Published private(set) var lastMetrics: OnDeviceInferenceMetrics?
    @Published private(set) var isBenchmarking = false
    @Published private(set) var benchmarkErrorMessage: String?

    private let llamaEngine = OnDeviceInferenceEngine()
    private let liteRTEngine = OnDeviceLiteRTInferenceEngine()
    private let fileManager: FileManager
    private let defaults: UserDefaults
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(
            withIdentifier: OnDeviceModelDownloadSession.identifier
        )
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.waitsForConnectivity = true
        configuration.allowsCellularAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        configuration.allowsExpensiveNetworkAccess = true
        configuration.timeoutIntervalForRequest = 3_600
        configuration.timeoutIntervalForResource = 7 * 24 * 3_600
        configuration.httpMaximumConnectionsPerHost = 1

        let delegateQueue = OperationQueue()
        delegateQueue.name = "RelayCode.ModelDownload"
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.qualityOfService = .utility
        return URLSession(
            configuration: configuration,
            delegate: self,
            delegateQueue: delegateQueue
        )
    }()
    private var downloadTask: URLSessionDownloadTask?
    private var idleUnloadTask: Task<Void, Never>?
    private var downloadGeneration = UUID()

    init(
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard
    ) {
        self.fileManager = fileManager
        self.defaults = defaults

        let initialDescriptor = OnDeviceModelDescriptor.initialSelection(
            storedModelID: defaults.string(forKey: DefaultsKey.modelID),
            storedCatalogVersion: defaults.integer(
                forKey: DefaultsKey.modelCatalogVersion
            ),
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory
        )
        let initialPerformanceMode = OnDevicePerformanceMode(
            rawValue: defaults.string(forKey: DefaultsKey.performanceMode) ?? ""
        ) ?? .automatic
        descriptor = initialDescriptor
        defaults.set(initialDescriptor.id, forKey: DefaultsKey.modelID)
        defaults.set(
            OnDeviceModelDescriptor.currentCatalogVersion,
            forKey: DefaultsKey.modelCatalogVersion
        )
        performanceMode = initialPerformanceMode
        activeConfiguration = Self.resolveConfiguration(
            mode: initialPerformanceMode,
            descriptor: initialDescriptor
        )

        super.init()
        _ = session
        reconnectBackgroundDownload()
    }

    var modelURL: URL {
        modelURL(for: descriptor)
    }

    var availableModels: [OnDeviceModelDescriptor] {
        OnDeviceModelDescriptor.relayCodeModels
    }

    var recommendedDescriptor: OnDeviceModelDescriptor {
        OnDeviceModelDescriptor.recommended(
            forPhysicalMemory: ProcessInfo.processInfo.physicalMemory
        )
    }

    var isSelectedModelRecommended: Bool {
        ProcessInfo.processInfo.physicalMemory
            >= descriptor.minimumRecommendedMemoryBytes
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
        defaults.set(
            OnDeviceModelDescriptor.currentCatalogVersion,
            forKey: DefaultsKey.modelCatalogVersion
        )
        activeConfiguration = Self.resolveConfiguration(
            mode: performanceMode,
            descriptor: selected
        )
        lastMetrics = nil
        installationState = .checking
        Task {
            await unloadEngines()
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
            await unloadEngines()
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
        request.timeoutInterval = 7 * 24 * 3_600
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")

        let requestedDescriptor = descriptor
        let stagingURL = modelDirectory.appendingPathComponent(
            ".\(requestedDescriptor.filename).\(generation.uuidString).download",
            isDirectory: false
        )
        let metadata = OnDeviceModelDownloadMetadata(
            descriptorID: requestedDescriptor.id,
            generation: generation,
            stagingPath: stagingURL.path,
            expectedByteCount: requestedDescriptor.expectedByteCount
        )
        let task: URLSessionDownloadTask
        if let resumeData = try? Data(contentsOf: resumeDataURL) {
            task = session.downloadTask(withResumeData: resumeData)
            try? fileManager.removeItem(at: resumeDataURL)
        } else {
            task = session.downloadTask(with: request)
        }

        task.taskDescription = Self.encodedMetadata(metadata)
        task.countOfBytesClientExpectsToReceive = requestedDescriptor.expectedByteCount
        task.priority = URLSessionTask.highPriority
        downloadTask = task
        task.resume()
    }

    func cancelDownload() {
        downloadGeneration = UUID()
        downloadTask?.cancel()
        downloadTask = nil
        removeResumeData()
        removeStagingDownloads(for: descriptor)
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
        removeResumeData()
        removeStagingDownloads(for: descriptor)
        await unloadEngines()
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
            let stream = inferenceStream(
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
        await unloadEngines()
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
            await unloadEngines()
            activeConfiguration = Self.resolveConfiguration(
                mode: performanceMode,
                descriptor: descriptor
            )
            let stream = inferenceStream(
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
        generation: UUID,
        descriptor requestedDescriptor: OnDeviceModelDescriptor
    ) async {
        guard requestedDescriptor == descriptor else {
            try? fileManager.removeItem(at: stagingURL)
            return
        }

        downloadGeneration = generation
        downloadTask = nil
        removeResumeData()

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
                [
                    .protectionKey:
                        FileProtectionType.completeUntilFirstUserAuthentication,
                ],
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

    private func inferenceStream(
        modelURL: URL,
        descriptor: OnDeviceModelDescriptor,
        messages: [ModelChatMessage],
        configuration: OnDeviceInferenceConfiguration,
        maximumOutputTokens: Int? = nil
    ) -> AsyncThrowingStream<OnDeviceInferenceEvent, Error> {
        switch descriptor.runtime {
        case .llamaCPP:
            llamaEngine.tokenStream(
                modelURL: modelURL,
                descriptor: descriptor,
                messages: messages,
                configuration: configuration,
                maximumOutputTokens: maximumOutputTokens
            )
        case .liteRTLM:
            liteRTEngine.tokenStream(
                modelURL: modelURL,
                descriptor: descriptor,
                messages: messages,
                configuration: configuration,
                maximumOutputTokens: maximumOutputTokens
            )
        }
    }

    private func unloadEngines() async {
        await llamaEngine.unload()
        await liteRTEngine.unload()
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
        try fileManager.setAttributes(
            [
                .protectionKey:
                    FileProtectionType.completeUntilFirstUserAuthentication,
            ],
            ofItemAtPath: modelDirectory.path
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

    private var resumeDataURL: URL {
        modelDirectory.appendingPathComponent(
            ".\(descriptor.filename).resume-data",
            isDirectory: false
        )
    }

    private func reconnectBackgroundDownload() {
        session.getAllTasks { [weak self] tasks in
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }

                var selectedTask: URLSessionDownloadTask?
                for task in tasks {
                    guard let task = task as? URLSessionDownloadTask,
                          let metadata = Self.decodedMetadata(
                              from: task.taskDescription
                          ) else {
                        task.cancel()
                        continue
                    }
                    guard metadata.descriptorID == self.descriptor.id else {
                        task.cancel()
                        continue
                    }
                    if let existing = selectedTask {
                        if existing.taskIdentifier < task.taskIdentifier {
                            existing.cancel()
                            selectedTask = task
                        } else {
                            task.cancel()
                        }
                    } else {
                        selectedTask = task
                    }
                }

                if let selectedTask,
                   let metadata = Self.decodedMetadata(
                       from: selectedTask.taskDescription
                   ) {
                    self.downloadGeneration = metadata.generation
                    self.downloadTask = selectedTask
                    self.installationState = .downloading(
                        progress: Self.normalizedProgress(selectedTask.progress)
                    )
                    selectedTask.resume()
                } else {
                    await self.recoverStagedDownloadOrRefresh()
                }
            }
        }
    }

    private func recoverStagedDownloadOrRefresh() async {
        let prefix = ".\(descriptor.filename)."
        let suffix = ".download"
        let candidates = (
            try? fileManager.contentsOfDirectory(
                at: modelDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: []
            )
        ) ?? []
        let stagedDownloads = candidates
            .filter {
                $0.lastPathComponent.hasPrefix(prefix)
                    && $0.lastPathComponent.hasSuffix(suffix)
            }
            .sorted {
                let left = try? $0.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ).contentModificationDate
                let right = try? $1.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ).contentModificationDate
                return (left ?? .distantPast) > (right ?? .distantPast)
            }

        if let stagedURL = stagedDownloads.first,
           let generation = Self.generation(
               fromStagingFilename: stagedURL.lastPathComponent,
               descriptor: descriptor
           ) {
            for obsolete in stagedDownloads.dropFirst() {
                try? fileManager.removeItem(at: obsolete)
            }
            await finishDownload(
                stagingURL: stagedURL,
                generation: generation,
                descriptor: descriptor
            )
            return
        }

        await refreshInstallation()
    }

    private func handleDownloadFailure(
        error: Error,
        metadata: OnDeviceModelDownloadMetadata?
    ) {
        guard metadata?.descriptorID == descriptor.id else {
            return
        }
        downloadTask = nil

        let nsError = error as NSError
        if nsError.code == NSURLErrorCancelled {
            return
        }
        if let resumeData = nsError.userInfo[
            NSURLSessionDownloadTaskResumeData
        ] as? Data {
            do {
                try prepareModelDirectory()
                try resumeData.write(to: resumeDataURL, options: .atomic)
                installationState = .failed(
                    message: "다운로드가 일시 중단됐습니다. 다시 시도하면 이어받습니다."
                )
                return
            } catch {
                try? fileManager.removeItem(at: resumeDataURL)
            }
        }
        installationState = .failed(
            message: "모델 다운로드 실패: \(error.localizedDescription)"
        )
    }

    private func handleDownloadProgress(
        taskIdentifier: Int,
        metadata: OnDeviceModelDownloadMetadata?,
        totalBytesWritten: Int64,
        totalBytesExpected: Int64
    ) {
        guard metadata?.descriptorID == descriptor.id,
              downloadTask?.taskIdentifier == taskIdentifier else {
            return
        }
        let expected = totalBytesExpected > 0
            ? totalBytesExpected
            : descriptor.expectedByteCount
        let progress = Double(totalBytesWritten) / Double(expected)
        installationState = .downloading(
            progress: max(0, min(1, progress))
        )
    }

    private func removeResumeData() {
        if fileManager.fileExists(atPath: resumeDataURL.path) {
            try? fileManager.removeItem(at: resumeDataURL)
        }
    }

    private func removeStagingDownloads(
        for descriptor: OnDeviceModelDescriptor
    ) {
        let prefix = ".\(descriptor.filename)."
        let candidates = (
            try? fileManager.contentsOfDirectory(
                at: modelDirectory,
                includingPropertiesForKeys: nil
            )
        ) ?? []
        for candidate in candidates
        where candidate.lastPathComponent.hasPrefix(prefix)
            && candidate.pathExtension == "download" {
            try? fileManager.removeItem(at: candidate)
        }
    }

    private nonisolated static func encodedMetadata(
        _ metadata: OnDeviceModelDownloadMetadata
    ) -> String? {
        guard let data = try? JSONEncoder().encode(metadata) else {
            return nil
        }
        return data.base64EncodedString()
    }

    private nonisolated static func decodedMetadata(
        from taskDescription: String?
    ) -> OnDeviceModelDownloadMetadata? {
        guard let taskDescription,
              let data = Data(base64Encoded: taskDescription) else {
            return nil
        }
        return try? JSONDecoder().decode(
            OnDeviceModelDownloadMetadata.self,
            from: data
        )
    }

    private nonisolated static func normalizedProgress(
        _ progress: Progress
    ) -> Double {
        let fraction = progress.fractionCompleted
        guard fraction.isFinite else {
            return 0
        }
        return max(0, min(1, fraction))
    }

    private nonisolated static func generation(
        fromStagingFilename filename: String,
        descriptor: OnDeviceModelDescriptor
    ) -> UUID? {
        let prefix = ".\(descriptor.filename)."
        let suffix = ".download"
        guard filename.hasPrefix(prefix),
              filename.hasSuffix(suffix) else {
            return nil
        }
        let start = filename.index(
            filename.startIndex,
            offsetBy: prefix.count
        )
        let end = filename.index(
            filename.endIndex,
            offsetBy: -suffix.count
        )
        return UUID(uuidString: String(filename[start..<end]))
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

extension OnDeviceModelService: URLSessionDownloadDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let metadata = Self.decodedMetadata(
            from: downloadTask.taskDescription
        )
        Task { @MainActor [weak self] in
            self?.handleDownloadProgress(
                taskIdentifier: downloadTask.taskIdentifier,
                metadata: metadata,
                totalBytesWritten: totalBytesWritten,
                totalBytesExpected: totalBytesExpectedToWrite
            )
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let metadata = Self.decodedMetadata(
            from: downloadTask.taskDescription
        ) else {
            return
        }

        var failure: Error?
        if let response = downloadTask.response as? HTTPURLResponse,
           !(200..<300).contains(response.statusCode) {
            failure = OnDeviceModelDownloadError.http(response.statusCode)
        } else if let expected = downloadTask.response?.expectedContentLength,
                  expected > 0,
                  expected != metadata.expectedByteCount {
            failure = OnDeviceModelDownloadError.unexpectedFileSize
        } else {
            do {
                let stagingURL = URL(fileURLWithPath: metadata.stagingPath)
                let manager = FileManager.default
                if manager.fileExists(atPath: stagingURL.path) {
                    try manager.removeItem(at: stagingURL)
                }
                try manager.moveItem(at: location, to: stagingURL)
                try manager.setAttributes(
                    [
                        .protectionKey:
                            FileProtectionType
                                .completeUntilFirstUserAuthentication,
                    ],
                    ofItemAtPath: stagingURL.path
                )
            } catch {
                failure = error
            }
        }

        if let failure {
            Task { @MainActor [weak self] in
                self?.handleDownloadFailure(
                    error: failure,
                    metadata: metadata
                )
            }
            return
        }

        let stagingURL = URL(fileURLWithPath: metadata.stagingPath)
        Task { @MainActor [weak self] in
            guard let self,
                  let requestedDescriptor = self.availableModels.first(
                      where: { $0.id == metadata.descriptorID }
                  ) else {
                try? FileManager.default.removeItem(at: stagingURL)
                return
            }
            await self.finishDownload(
                stagingURL: stagingURL,
                generation: metadata.generation,
                descriptor: requestedDescriptor
            )
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else {
            return
        }
        let metadata = Self.decodedMetadata(from: task.taskDescription)
        Task { @MainActor [weak self] in
            self?.handleDownloadFailure(
                error: error,
                metadata: metadata
            )
        }
    }

    nonisolated func urlSessionDidFinishEvents(
        forBackgroundURLSession session: URLSession
    ) {
        Task { @MainActor in
            RelayCodeBackgroundSessionEvents.shared.finish(
                identifier: session.configuration.identifier
            )
        }
    }
}

private enum OnDeviceModelDownloadError: LocalizedError {
    case http(Int)
    case unexpectedFileSize

    var errorDescription: String? {
        switch self {
        case let .http(statusCode):
            "내부 모델 다운로드가 HTTP \(statusCode)로 실패했습니다."
        case .unexpectedFileSize:
            "모델 서버가 예상과 다른 크기의 파일을 반환했습니다."
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
    static let modelCatalogVersion = "relaycode.on-device.model-catalog-version"
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
