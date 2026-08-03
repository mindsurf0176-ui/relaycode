import Foundation

public enum OnDevicePerformanceMode: String, CaseIterable, Codable, Sendable {
    case automatic
    case lowPower
    case balanced
    case turbo

    public var displayName: String {
        switch self {
        case .automatic:
            "자동"
        case .lowPower:
            "저전력"
        case .balanced:
            "균형"
        case .turbo:
            "터보"
        }
    }
}

public enum OnDeviceThermalLevel: String, Codable, Sendable {
    case nominal
    case fair
    case serious
    case critical
}

public struct OnDeviceRuntimeEnvironment: Hashable, Sendable {
    public let physicalMemoryBytes: UInt64
    public let processorCount: Int
    public let isLowPowerModeEnabled: Bool
    public let thermalLevel: OnDeviceThermalLevel

    public init(
        physicalMemoryBytes: UInt64,
        processorCount: Int,
        isLowPowerModeEnabled: Bool,
        thermalLevel: OnDeviceThermalLevel
    ) {
        self.physicalMemoryBytes = physicalMemoryBytes
        self.processorCount = processorCount
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
        self.thermalLevel = thermalLevel
    }
}

public struct OnDeviceInferenceConfiguration: Hashable, Sendable {
    public let resolvedMode: OnDevicePerformanceMode
    public let contextLength: Int
    public let batchSize: Int
    public let microBatchSize: Int
    public let threadCount: Int
    public let usesQuantizedKVCache: Bool

    public init(
        resolvedMode: OnDevicePerformanceMode,
        contextLength: Int,
        batchSize: Int,
        microBatchSize: Int,
        threadCount: Int,
        usesQuantizedKVCache: Bool = true
    ) {
        precondition(contextLength >= 2_048)
        precondition(batchSize > 0)
        precondition(microBatchSize > 0 && microBatchSize <= batchSize)
        precondition(threadCount > 0)

        self.resolvedMode = resolvedMode
        self.contextLength = contextLength
        self.batchSize = batchSize
        self.microBatchSize = microBatchSize
        self.threadCount = threadCount
        self.usesQuantizedKVCache = usesQuantizedKVCache
    }

    public static func resolve(
        requestedMode: OnDevicePerformanceMode,
        environment: OnDeviceRuntimeEnvironment,
        descriptor: OnDeviceModelDescriptor
    ) -> Self {
        let resolvedMode: OnDevicePerformanceMode
        if environment.thermalLevel == .critical
            || environment.thermalLevel == .serious
            || environment.isLowPowerModeEnabled {
            resolvedMode = .lowPower
        } else if requestedMode == .automatic {
            resolvedMode = environment.thermalLevel == .nominal
                && environment.physicalMemoryBytes >= max(
                    6_000_000_000,
                    descriptor.minimumRecommendedMemoryBytes
                )
                ? .turbo
                : .balanced
        } else {
            resolvedMode = requestedMode
        }

        let availableThreads = max(1, environment.processorCount - 2)
        switch resolvedMode {
        case .automatic:
            preconditionFailure("Automatic must resolve to a concrete mode.")
        case .lowPower:
            return Self(
                resolvedMode: .lowPower,
                contextLength: min(4_096, descriptor.contextLength),
                batchSize: 128,
                microBatchSize: 128,
                threadCount: min(3, availableThreads)
            )
        case .balanced:
            return Self(
                resolvedMode: .balanced,
                contextLength: min(6_144, descriptor.contextLength),
                batchSize: 256,
                microBatchSize: 256,
                threadCount: min(4, availableThreads)
            )
        case .turbo:
            return Self(
                resolvedMode: .turbo,
                contextLength: descriptor.contextLength,
                batchSize: 512,
                microBatchSize: 256,
                threadCount: min(6, availableThreads)
            )
        }
    }
}

public struct OnDeviceInferenceMetrics: Hashable, Sendable {
    public let modelLoadMilliseconds: Double
    public let firstTokenMilliseconds: Double
    public let promptTokenCount: Int
    public let reusedPromptTokenCount: Int
    public let promptTokensPerSecond: Double
    public let generatedTokenCount: Int
    public let generatedTokensPerSecond: Double
    public let configuration: OnDeviceInferenceConfiguration

    public init(
        modelLoadMilliseconds: Double,
        firstTokenMilliseconds: Double,
        promptTokenCount: Int,
        reusedPromptTokenCount: Int,
        promptTokensPerSecond: Double,
        generatedTokenCount: Int,
        generatedTokensPerSecond: Double,
        configuration: OnDeviceInferenceConfiguration
    ) {
        self.modelLoadMilliseconds = modelLoadMilliseconds
        self.firstTokenMilliseconds = firstTokenMilliseconds
        self.promptTokenCount = promptTokenCount
        self.reusedPromptTokenCount = reusedPromptTokenCount
        self.promptTokensPerSecond = promptTokensPerSecond
        self.generatedTokenCount = generatedTokenCount
        self.generatedTokensPerSecond = generatedTokensPerSecond
        self.configuration = configuration
    }
}
