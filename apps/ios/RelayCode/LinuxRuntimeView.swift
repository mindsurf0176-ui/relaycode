import SwiftUI

struct LinuxRuntimeView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var controller = LinuxRuntimeController()
    @State private var command = ""
    @State private var showingNotices = false
    @FocusState private var commandFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                runtimeSummary
                terminal
                commandBar
            }
            .navigationTitle("Linux")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        showingNotices = true
                    } label: {
                        Label("오픈소스 고지", systemImage: "info.circle")
                    }
                    runtimeAction
                }
            }
            .sheet(isPresented: $showingNotices) {
                LinuxLegalNoticesView()
            }
            .onDisappear {
                controller.stop()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active {
                    controller.stop()
                }
            }
        }
    }

    private var runtimeSummary: some View {
        HStack(spacing: 12) {
            Image(systemName: statusSymbol)
                .foregroundStyle(statusColor)
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                Text(controller.status.label)
                    .font(.subheadline.weight(.semibold))
                Text("Linux 6.1 · riscv32 · RAM 64MB · 휘발성")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(uiColor: .secondarySystemBackground))
    }

    private var terminal: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(controller.output.isEmpty ? idleMessage : controller.output)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(controller.output.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(14)
                    .id("terminal-bottom")
            }
            .background(Color.black.opacity(0.86))
            .onChange(of: controller.output) { _, _ in
                proxy.scrollTo("terminal-bottom", anchor: .bottom)
            }
        }
    }

    private var commandBar: some View {
        VStack(spacing: 9) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    quickCommand("uname -a")
                    quickCommand("pwd")
                    quickCommand("ls -la")
                    quickCommand("free")
                    quickCommand("cat /proc/version")
                }
            }

            HStack(spacing: 10) {
                TextField("Linux 명령", text: $command)
                    .focused($commandFocused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                    .submitLabel(.send)
                    .onSubmit(sendCommand)

                Button(action: sendCommand) {
                    Image(systemName: "return")
                        .fontWeight(.bold)
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    !controller.canSendInput
                        || command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.bar)
    }

    @ViewBuilder
    private var runtimeAction: some View {
        switch controller.status {
        case .booting, .ready:
            Button("중지", role: .destructive) {
                controller.stop()
            }
        case .stopped, .poweredOff, .failed:
            Button("시작") {
                controller.start()
            }
        }
    }

    private func quickCommand(_ value: String) -> some View {
        Button(value) {
            controller.send(command: value)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(!controller.canSendInput)
    }

    private func sendCommand() {
        let value = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            return
        }
        controller.send(command: value)
        command = ""
        commandFocused = true
    }

    private var idleMessage: String {
        """
        실제 RISC-V Linux 커널과 BusyBox 셸이 iPhone 안에서 실행됩니다.

        • JIT 또는 탈옥을 사용하지 않습니다.
        • 파일 변경은 현재 세션 RAM에만 남습니다.
        • 네트워크와 호스트 파일 접근은 아직 연결하지 않았습니다.
        """
    }

    private var statusSymbol: String {
        switch controller.status {
        case .ready:
            "checkmark.circle.fill"
        case .booting:
            "hourglass.circle.fill"
        case .failed:
            "exclamationmark.triangle.fill"
        case .stopped, .poweredOff:
            "power.circle"
        }
    }

    private var statusColor: Color {
        switch controller.status {
        case .ready:
            .green
        case .booting:
            .orange
        case .failed:
            .red
        case .stopped, .poweredOff:
            .secondary
        }
    }
}

private struct LinuxLegalNoticesView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(notices)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .navigationTitle("오픈소스 고지")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("완료") {
                        dismiss()
                    }
                }
            }
        }
    }

    private var notices: String {
        let notice = resourceText(
            name: "THIRD_PARTY_NOTICES",
            extension: "md"
        )
        let guestLicense = resourceText(
            name: "linux-guest-license",
            extension: "txt",
            subdirectory: "Linux"
        )
        return [notice, guestLicense]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n---\n\n")
    }

    private func resourceText(
        name: String,
        extension fileExtension: String,
        subdirectory: String? = nil
    ) -> String {
        let url = Bundle.main.url(
            forResource: name,
            withExtension: fileExtension,
            subdirectory: subdirectory
        ) ?? Bundle.main.url(
            forResource: name,
            withExtension: fileExtension
        )
        guard let url else {
            return "고지 파일을 불러올 수 없습니다: \(name).\(fileExtension)"
        }
        return (try? String(contentsOf: url, encoding: .utf8))
            ?? "고지 파일을 읽을 수 없습니다: \(name).\(fileExtension)"
    }
}
