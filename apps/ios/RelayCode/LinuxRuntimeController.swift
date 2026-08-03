import CryptoKit
import Foundation

enum LinuxRuntimeStatus: Equatable {
    case stopped
    case booting
    case ready
    case poweredOff
    case failed(String)

    var label: String {
        switch self {
        case .stopped:
            "중지됨"
        case .booting:
            "Linux 부팅 중"
        case .ready:
            "셸 준비됨"
        case .poweredOff:
            "전원 꺼짐"
        case .failed:
            "실행 실패"
        }
    }
}

@MainActor
final class LinuxRuntimeController: ObservableObject {
    @Published private(set) var status: LinuxRuntimeStatus = .stopped
    @Published private(set) var output = ""
    let memoryMegabytes: Int
    let instructionBudget: UInt32

    private var didRequestLogin = false
    private var ansiSanitizer = ANSISanitizer()
    private lazy var engine = LinuxRuntimeEngine { [weak self] event in
        Task { @MainActor [weak self] in
            self?.handle(event)
        }
    }

    init() {
        let processInfo = ProcessInfo.processInfo
        let isConstrained = processInfo.isLowPowerModeEnabled
            || processInfo.thermalState == .serious
            || processInfo.thermalState == .critical
        memoryMegabytes = !isConstrained
            && processInfo.physicalMemory >= 6_000_000_000
            ? 128
            : 64
        instructionBudget = isConstrained ? 65_536 : 262_144
    }

    var canSendInput: Bool {
        status == .ready || status == .booting
    }

    func start() {
        guard status != .booting, status != .ready else {
            return
        }
        guard let imageURL = linuxImageURL() else {
            status = .failed("번들에서 Linux 이미지를 찾을 수 없습니다.")
            return
        }
        do {
            let image = try Data(contentsOf: imageURL, options: .mappedIfSafe)
            let digest = SHA256.hash(data: image)
                .map { String(format: "%02x", $0) }
                .joined()
            guard image.count == 3_476_752,
                  digest == "5f596134705d5aa8e7c8c406695a560d08faaff4a86bc715659e53cbebba6c7e" else {
                throw LinuxRuntimeControllerError.invalidImage
            }
            output = ""
            didRequestLogin = false
            ansiSanitizer = ANSISanitizer()
            status = .booting
            engine.start(
                image: image,
                memoryBytes: memoryMegabytes * 1_024 * 1_024,
                instructionBudget: instructionBudget
            )
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func stop() {
        engine.stop()
    }

    func send(command: String) {
        let normalized = command.trimmingCharacters(in: .newlines)
        guard canSendInput, !normalized.isEmpty else {
            return
        }
        engine.send(text: normalized + "\n")
    }

    private func handle(_ event: LinuxRuntimeEvent) {
        switch event {
        case let .output(chunk):
            let clean = ansiSanitizer.consume(chunk)
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
            output.append(clean)
            if output.count > 240_000 {
                output.removeFirst(output.count - 200_000)
            }

            if !didRequestLogin, output.contains("buildroot login:") {
                didRequestLogin = true
                engine.send(text: "root\n")
            }
            if didRequestLogin,
               output.contains("root login on"),
               output.hasSuffix("# ") {
                status = .ready
            }
        case .started:
            status = .booting
        case .poweredOff:
            status = .poweredOff
        case .stopped:
            status = .stopped
        case let .failed(message):
            status = .failed(message)
        }
    }

    private func linuxImageURL() -> URL? {
        Bundle.main.url(
            forResource: "linux-rv32",
            withExtension: "img",
            subdirectory: "Linux"
        ) ?? Bundle.main.url(
            forResource: "linux-rv32",
            withExtension: "img"
        )
    }
}

private enum LinuxRuntimeControllerError: LocalizedError {
    case invalidImage

    var errorDescription: String? {
        "Linux 이미지의 크기 또는 형식이 올바르지 않습니다."
    }
}

private struct ANSISanitizer {
    private var inEscapeSequence = false
    private var inControlSequence = false

    mutating func consume(_ value: String) -> String {
        var result = String()
        for scalar in value.unicodeScalars {
            if inControlSequence {
                if (0x40...0x7e).contains(scalar.value) {
                    inControlSequence = false
                    inEscapeSequence = false
                }
                continue
            }
            if inEscapeSequence {
                if scalar.value == 0x5b {
                    inControlSequence = true
                } else {
                    inEscapeSequence = false
                }
                continue
            }
            if scalar.value == 0x1b {
                inEscapeSequence = true
                continue
            }
            if scalar.value == 0x08 {
                if !result.isEmpty {
                    result.removeLast()
                }
                continue
            }
            if scalar.value == 0x00 {
                continue
            }
            result.unicodeScalars.append(scalar)
        }
        return result
    }
}

private enum LinuxRuntimeEvent: Sendable {
    case started
    case output(String)
    case poweredOff
    case stopped
    case failed(String)
}

private final class LinuxRuntimeEngine: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "com.minseo.relaycode.linux-runtime",
        qos: .userInitiated
    )
    private let onEvent: @Sendable (LinuxRuntimeEvent) -> Void
    private var virtualMachine: OpaquePointer?
    private var lastStepNanoseconds: UInt64 = 0
    private var instructionBudget: UInt32 = 65_536

    init(onEvent: @escaping @Sendable (LinuxRuntimeEvent) -> Void) {
        self.onEvent = onEvent
    }

    func start(
        image: Data,
        memoryBytes: Int,
        instructionBudget: UInt32
    ) {
        queue.async { [self] in
            guard virtualMachine == nil else {
                return
            }
            let machine = image.withUnsafeBytes { bytes in
                "console=ttyS0 quiet".withCString { commandLine in
                    rc_linux_vm_create(
                        bytes.bindMemory(to: UInt8.self).baseAddress,
                        image.count,
                        memoryBytes,
                        commandLine
                    )
                }
            }
            guard let machine else {
                onEvent(.failed("Linux 가상 머신 메모리를 초기화하지 못했습니다."))
                return
            }
            virtualMachine = machine
            self.instructionBudget = instructionBudget
            lastStepNanoseconds = DispatchTime.now().uptimeNanoseconds
            onEvent(.started)
            runSlice()
        }
    }

    func stop() {
        queue.async { [self] in
            guard let virtualMachine else {
                onEvent(.stopped)
                return
            }
            rc_linux_vm_destroy(virtualMachine)
            self.virtualMachine = nil
            onEvent(.stopped)
        }
    }

    func send(text: String) {
        guard let data = text.data(using: .utf8) else {
            return
        }
        queue.async { [self] in
            guard let virtualMachine else {
                return
            }
            data.withUnsafeBytes { bytes in
                _ = rc_linux_vm_send_input(
                    virtualMachine,
                    bytes.bindMemory(to: UInt8.self).baseAddress,
                    data.count
                )
            }
        }
    }

    private func runSlice() {
        guard let virtualMachine else {
            return
        }

        let now = DispatchTime.now().uptimeNanoseconds
        let elapsedNanoseconds = now > lastStepNanoseconds
            ? now - lastStepNanoseconds
            : 0
        lastStepNanoseconds = now
        let elapsedMicroseconds = UInt32(
            min(max(elapsedNanoseconds / 1_000, 1), UInt64(UInt32.max))
        )

        let result = rc_linux_vm_step(
            virtualMachine,
            instructionBudget,
            elapsedMicroseconds
        )
        drainOutput(from: virtualMachine)

        switch result {
        case RC_LINUX_STEP_RUNNING:
            queue.async { [self] in runSlice() }
        case RC_LINUX_STEP_IDLE:
            queue.asyncAfter(deadline: .now() + .milliseconds(1)) { [self] in
                runSlice()
            }
        case RC_LINUX_STEP_POWERED_OFF:
            rc_linux_vm_destroy(virtualMachine)
            self.virtualMachine = nil
            onEvent(.poweredOff)
        case RC_LINUX_STEP_REBOOT_REQUESTED:
            rc_linux_vm_destroy(virtualMachine)
            self.virtualMachine = nil
            onEvent(.failed("게스트가 재부팅을 요청했습니다. 다시 시작해 주세요."))
        default:
            rc_linux_vm_destroy(virtualMachine)
            self.virtualMachine = nil
            onEvent(.failed("Linux CPU 실행 중 복구할 수 없는 오류가 발생했습니다."))
        }
    }

    private func drainOutput(from machine: OpaquePointer) {
        var bytes = [UInt8](repeating: 0, count: 32 * 1_024)
        while true {
            let count = bytes.withUnsafeMutableBufferPointer { buffer in
                rc_linux_vm_read_output(
                    machine,
                    buffer.baseAddress,
                    buffer.count
                )
            }
            guard count > 0 else {
                return
            }
            onEvent(.output(String(decoding: bytes.prefix(count), as: UTF8.self)))
        }
    }
}
