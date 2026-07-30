import RelayCodeCore
import SwiftUI

struct InferenceView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var selectedConnectionID: String?
    @State private var messages: [ModelChatMessage] = []
    @State private var prompt = ""
    @State private var isGenerating = false
    @State private var errorMessage: String?
    @State private var inferenceTask: Task<Void, Never>?
    @FocusState private var promptFocused: Bool

    private let client = OpenAICompatibleModelClient()

    var body: some View {
        NavigationStack {
            Group {
                if availableConnections.isEmpty {
                    ContentUnavailableView {
                        Label("연결할 모델이 없습니다", systemImage: "sparkles")
                    } description: {
                        Text("모델 탭에서 OpenAI 호환 서버와 모델을 먼저 등록하세요.")
                    }
                } else {
                    conversation
                }
            }
            .navigationTitle("추론")
            .toolbar {
                if !messages.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("대화 지우기", role: .destructive) {
                            inferenceTask?.cancel()
                            messages = []
                            isGenerating = false
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
        .onAppear(perform: selectDefaultConnection)
        .onChange(of: appModel.modelConnections) { _, _ in
            selectDefaultConnection()
        }
        .onDisappear {
            inferenceTask?.cancel()
        }
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    providerPicker

                    if messages.isEmpty {
                        Label(
                            "프롬프트는 선택한 서버로 직접 전송됩니다.",
                            systemImage: "lock.shield"
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
                            Text("모델이 응답을 생성하고 있습니다…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .id("generating")
                    }
                }
                .padding(16)
            }
            .onChange(of: messages.count) { _, _ in
                if let lastID = messages.last?.id {
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

            Picker("실행 모델", selection: $selectedConnectionID) {
                ForEach(availableConnections) { connection in
                    Text("\(connection.displayName) · \(connection.modelID ?? "")")
                        .tag(Optional(connection.id))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
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
                Text(selectedConnection?.baseURL?.host ?? "")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)

                Spacer()

                if isGenerating {
                    Button("중지", role: .destructive) {
                        inferenceTask?.cancel()
                        isGenerating = false
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
        availableConnections.first { $0.id == selectedConnectionID }
    }

    private var normalizedPrompt: String {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSend: Bool {
        !normalizedPrompt.isEmpty && selectedConnection != nil && !isGenerating
    }

    private func selectDefaultConnection() {
        guard !availableConnections.isEmpty else {
            selectedConnectionID = nil
            return
        }
        if !availableConnections.contains(where: { $0.id == selectedConnectionID }) {
            selectedConnectionID = availableConnections[0].id
        }
    }

    private func send() {
        guard canSend,
              let connection = selectedConnection,
              let baseURL = connection.baseURL,
              let modelID = connection.modelID else {
            return
        }

        let userMessage = ModelChatMessage(role: .user, content: normalizedPrompt)
        messages.append(userMessage)
        prompt = ""
        promptFocused = false
        isGenerating = true

        let history = Array(messages.suffix(24))
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
