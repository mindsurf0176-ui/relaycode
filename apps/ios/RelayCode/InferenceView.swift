import RelayCodeCore
import SwiftUI

struct InferenceView: View {
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var onDeviceModel: OnDeviceModelService
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTarget: InferenceTarget = .onDevice
    @State private var messages: [ModelChatMessage] = []
    @State private var prompt = ""
    @State private var isGenerating = false
    @State private var errorMessage: String?
    @State private var inferenceTask: Task<Void, Never>?
    @FocusState private var promptFocused: Bool

    private let client = OpenAICompatibleModelClient()

    var body: some View {
        NavigationStack {
            conversation
                .navigationTitle("추론")
                .toolbar {
                    if !messages.isEmpty {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("대화 지우기", role: .destructive) {
                                stopInference()
                                messages = []
                            }
                        }
                    }
                }
                .alert(
                    "모델 추론",
                    isPresented: Binding(
                        get: { errorMessage != nil },
                        set: { if !$0 { errorMessage = nil } }
                    )
                ) {
                    Button("확인", role: .cancel) {
                        errorMessage = nil
                    }
                } message: {
                    Text(errorMessage ?? "")
                }
        }
        .onChange(of: appModel.modelConnections) { _, _ in
            if case let .remote(id) = selectedTarget,
               !availableConnections.contains(where: { $0.id == id }) {
                selectedTarget = .onDevice
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                stopInference()
                Task {
                    await onDeviceModel.unload()
                }
            }
        }
        .onDisappear {
            stopInference()
            Task {
                await onDeviceModel.unload()
            }
        }
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    providerPicker

                    if isOnDeviceSelected && !onDeviceModel.installationState.isReady {
                        onDeviceSetup
                    } else if messages.isEmpty {
                        Label(
                            privacyMessage,
                            systemImage: isOnDeviceSelected
                                ? "iphone.gen3"
                                : "lock.shield"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)
                    }

                    ForEach(messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }

                    if isGenerating {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(generationStatus)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .id("generating")
                    }
                }
                .padding(16)
            }
            .onChange(of: messages) { _, updatedMessages in
                if let lastID = updatedMessages.last?.id {
                    withAnimation {
                        proxy.scrollTo(lastID, anchor: .bottom)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                composer
            }
        }
    }

    private var providerPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("실행 모델")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Picker("실행 모델", selection: $selectedTarget) {
                Label(
                    "\(onDeviceModel.descriptor.displayName) · 내부",
                    systemImage: "iphone.gen3"
                )
                .tag(InferenceTarget.onDevice)

                ForEach(availableConnections) { connection in
                    Label(
                        "\(connection.displayName) · \(connection.modelID ?? "")",
                        systemImage: "server.rack"
                    )
                    .tag(InferenceTarget.remote(connection.id))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(isGenerating)
        }
        .padding(14)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 16)
        )
    }

    private var onDeviceSetup: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("내부 모델 준비", systemImage: "square.and.arrow.down")
                .font(.headline)

            switch onDeviceModel.installationState {
            case .checking:
                ProgressView("설치 상태 확인 중…")
            case .notInstalled:
                Text("공식 Qwen 코딩 모델 \(onDeviceModel.descriptor.formattedDownloadSize)을 한 번 다운로드하면 오프라인으로 추론할 수 있습니다.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button {
                    onDeviceModel.download()
                } label: {
                    Label("내부 모델 다운로드", systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(.borderedProminent)
            case let .downloading(progress):
                ProgressView(value: progress) {
                    Text("모델 다운로드")
                } currentValueLabel: {
                    Text("\(Int(progress * 100))%")
                        .monospacedDigit()
                }
                Button("다운로드 취소", role: .destructive) {
                    onDeviceModel.cancelDownload()
                }
            case .verifying:
                ProgressView("SHA-256 무결성 확인 중…")
            case .ready:
                EmptyView()
            case let .failed(message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Button("다시 다운로드") {
                    onDeviceModel.download()
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            Color(uiColor: .secondarySystemBackground),
            in: RoundedRectangle(cornerRadius: 16)
        )
    }

    private var composer: some View {
        VStack(spacing: 10) {
            TextEditor(text: $prompt)
                .focused($promptFocused)
                .font(.body)
                .frame(minHeight: 44, maxHeight: 120)
                .padding(8)
                .scrollContentBackground(.hidden)
                .background(
                    Color(uiColor: .secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 14)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color(uiColor: .separator), lineWidth: 0.5)
                }
                .accessibilityLabel("모델에 보낼 프롬프트")

            HStack {
                Label(
                    targetLocation,
                    systemImage: isOnDeviceSelected ? "lock.iphone" : "network"
                )
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)

                Spacer()

                if isGenerating {
                    Button("중지", role: .destructive) {
                        stopInference()
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button {
                        send()
                    } label: {
                        Label("전송", systemImage: "arrow.up.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSend)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var availableConnections: [ModelConnectionConfiguration] {
        appModel.modelConnections.filter {
            $0.kind == .openAICompatible && $0.modelID != nil && $0.baseURL != nil
        }
    }

    private var selectedConnection: ModelConnectionConfiguration? {
        guard case let .remote(id) = selectedTarget else {
            return nil
        }
        return availableConnections.first { $0.id == id }
    }

    private var isOnDeviceSelected: Bool {
        selectedTarget == .onDevice
    }

    private var normalizedPrompt: String {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSend: Bool {
        guard !normalizedPrompt.isEmpty, !isGenerating else {
            return false
        }
        if isOnDeviceSelected {
            return onDeviceModel.installationState.isReady
        }
        return selectedConnection != nil
    }

    private var targetLocation: String {
        if isOnDeviceSelected {
            return "이 iPhone · 오프라인"
        }
        return selectedConnection?.baseURL?.host ?? "외부 서버"
    }

    private var privacyMessage: String {
        if isOnDeviceSelected {
            return "프롬프트와 응답은 이 기기 안에서만 처리됩니다."
        }
        return "프롬프트는 선택한 온프레미스 서버로 직접 전송됩니다."
    }

    private var generationStatus: String {
        if isOnDeviceSelected && onDeviceModel.inferenceState == .loading {
            return "내부 모델을 메모리에 불러오고 있습니다…"
        }
        return isOnDeviceSelected
            ? "이 기기에서 응답을 생성하고 있습니다…"
            : "모델 서버가 응답을 생성하고 있습니다…"
    }

    private func send() {
        guard canSend else {
            return
        }

        let userMessage = ModelChatMessage(role: .user, content: normalizedPrompt)
        messages.append(userMessage)
        prompt = ""
        promptFocused = false
        isGenerating = true

        let history = Array(messages.suffix(24))
        switch selectedTarget {
        case .onDevice:
            runOnDevice(history: history)
        case .remote:
            runRemote(history: history)
        }
    }

    private func runOnDevice(history: [ModelChatMessage]) {
        let assistantID = UUID()
        messages.append(
            ModelChatMessage(
                id: assistantID,
                role: .assistant,
                content: ""
            )
        )

        inferenceTask = Task {
            defer {
                isGenerating = false
                inferenceTask = nil
            }
            do {
                _ = try await onDeviceModel.complete(messages: history) { token in
                    append(token: token, to: assistantID)
                }
                try Task.checkCancellation()
            } catch is CancellationError {
                removeEmptyMessage(id: assistantID)
            } catch {
                removeEmptyMessage(id: assistantID)
                errorMessage = error.localizedDescription
            }
        }
    }

    private func runRemote(history: [ModelChatMessage]) {
        guard let connection = selectedConnection,
              let baseURL = connection.baseURL,
              let modelID = connection.modelID else {
            isGenerating = false
            return
        }

        inferenceTask = Task {
            defer {
                isGenerating = false
                inferenceTask = nil
            }
            do {
                let endpoint = try OpenAICompatibleEndpoint(baseURL: baseURL)
                let credential = try appModel.credential(for: connection)
                let response = try await client.complete(
                    endpoint: endpoint,
                    modelID: modelID,
                    messages: history,
                    bearerToken: credential
                )
                try Task.checkCancellation()
                messages.append(
                    ModelChatMessage(role: .assistant, content: response)
                )
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func append(token: String, to messageID: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else {
            return
        }
        let message = messages[index]
        messages[index] = ModelChatMessage(
            id: message.id,
            role: message.role,
            content: message.content + token
        )
    }

    private func removeEmptyMessage(id: UUID) {
        messages.removeAll {
            $0.id == id
                && $0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func stopInference() {
        inferenceTask?.cancel()
        inferenceTask = nil
        isGenerating = false
    }
}

private enum InferenceTarget: Hashable {
    case onDevice
    case remote(String)
}

private struct MessageBubble: View {
    let message: ModelChatMessage

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer(minLength: 44)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(message.role == .user ? "나" : "모델")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                Text(message.content)
                    .textSelection(.enabled)
                    .font(.body)
            }
            .padding(13)
            .background(
                message.role == .user
                    ? Color.accentColor.opacity(0.18)
                    : Color(uiColor: .secondarySystemBackground),
                in: RoundedRectangle(cornerRadius: 16)
            )

            if message.role != .user {
                Spacer(minLength: 28)
            }
        }
    }
}
