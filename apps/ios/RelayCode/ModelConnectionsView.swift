import RelayCodeCore
import SwiftUI

struct ModelConnectionsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showingAddProvider = false

    var body: some View {
        NavigationStack {
            List {
                if model.modelConnections.isEmpty {
                    ContentUnavailableView {
                        Label("등록된 모델 없음", systemImage: "cpu")
                    } description: {
                        Text("Ollama, LM Studio 또는 사내 OpenAI 호환 서버를 연결할 수 있습니다.")
                    } actions: {
                        Button("모델 서버 추가") {
                            showingAddProvider = true
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .listRowBackground(Color.clear)
                } else {
                    Section("온프레미스 모델") {
                        ForEach(model.modelConnections) { connection in
                            ModelConnectionRow(connection: connection)
                        }
                        .onDelete(perform: deleteConnections)
                    }
                }

                Section {
                    Label {
                        Text("인증정보는 이 기기의 Keychain에만 저장되며 URL이나 웹 저장소로 전달되지 않습니다.")
                    } icon: {
                        Image(systemName: "lock.shield")
                            .foregroundStyle(.tint)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .navigationTitle("모델")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingAddProvider = true
                    } label: {
                        Label("모델 서버 추가", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAddProvider) {
                AddModelConnectionView()
                    .environmentObject(model)
            }
        }
    }

    private func deleteConnections(at offsets: IndexSet) {
        let ids = offsets.compactMap { index in
            model.modelConnections.indices.contains(index)
                ? model.modelConnections[index].id
                : nil
        }
        for id in ids {
            model.deleteModelConnection(id: id)
        }
    }
}

private struct ModelConnectionRow: View {
    @EnvironmentObject private var appModel: AppModel
    let connection: ModelConnectionConfiguration

    @State private var state: VerificationState = .idle
    private let client = OpenAICompatibleModelClient()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "server.rack")
                    .frame(width: 28, height: 28)
                    .foregroundStyle(.tint)
                    .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 3) {
                    Text(connection.displayName)
                        .font(.headline)
                    Text(connection.modelID ?? "모델 미지정")
                        .font(.subheadline.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let host = connection.baseURL?.host {
                        Text(host)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer()

                Button {
                    Task {
                        await verify()
                    }
                } label: {
                    switch state {
                    case .checking:
                        ProgressView()
                            .controlSize(.small)
                    default:
                        Text("확인")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(state == .checking)
            }

            switch state {
            case .idle, .checking:
                EmptyView()
            case let .online(count):
                Label("연결됨 · 모델 \(count)개", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption.weight(.semibold))
            case let .failed(message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }

    @MainActor
    private func verify() async {
        state = .checking
        do {
            guard let baseURL = connection.baseURL else {
                throw RuntimeProfileError.missingBaseURL
            }
            let endpoint = try OpenAICompatibleEndpoint(baseURL: baseURL)
            let credential = try appModel.credential(for: connection)
            let models = try await client.listModels(endpoint: endpoint, bearerToken: credential)
            state = .online(modelCount: models.count)
        } catch {
            state = .failed(message: error.localizedDescription)
        }
    }
}

private enum VerificationState: Equatable {
    case idle
    case checking
    case online(modelCount: Int)
    case failed(message: String)
}

private struct AddModelConnectionView: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var connectionID = "provider-\(UUID().uuidString.lowercased())"
    @State private var displayName = ""
    @State private var baseURLText = ""
    @State private var credential = ""
    @State private var modelID = ""
    @State private var discoveredModels: [ProviderModel] = []
    @State private var isChecking = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?

    private let client = OpenAICompatibleModelClient()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("이름 · 예: 집 Ollama", text: $displayName)
                        .textInputAutocapitalization(.never)

                    TextField("HTTPS 기본 URL · https://host/v1", text: $baseURLText)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    SecureField("API 키 · 없으면 비워두기", text: $credential)
                        .textContentType(.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("모델 서버")
                } footer: {
                    Text("원격 주소는 HTTPS만 허용합니다. Ollama 기본값은 API 키가 필요하지 않습니다.")
                }

                Section("모델") {
                    Button {
                        Task {
                            await discover()
                        }
                    } label: {
                        HStack {
                            Label("연결 확인 및 모델 조회", systemImage: "arrow.triangle.2.circlepath")
                            Spacer()
                            if isChecking {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isChecking || normalizedBaseURL.isEmpty)

                    if !discoveredModels.isEmpty {
                        Picker("검색된 모델", selection: $modelID) {
                            ForEach(discoveredModels) { model in
                                Text(model.id).tag(model.id)
                            }
                        }
                    }

                    TextField("모델 ID", text: $modelID)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    if let statusMessage {
                        Label(statusMessage, systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }

                Section {
                    Label(
                        "API 키는 WhenUnlockedThisDeviceOnly Keychain 항목으로 저장됩니다.",
                        systemImage: "key.fill"
                    )
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .navigationTitle("모델 서버 추가")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장") {
                        save()
                    }
                    .disabled(!canSave || isChecking)
                }
            }
            .alert(
                "모델 연결",
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
    }

    private var normalizedName: String {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedBaseURL: String {
        baseURLText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedCredential: String {
        credential.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedModelID: String {
        modelID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        !normalizedName.isEmpty
            && !normalizedBaseURL.isEmpty
            && !normalizedModelID.isEmpty
    }

    @MainActor
    private func discover() async {
        isChecking = true
        statusMessage = nil
        defer { isChecking = false }

        do {
            let endpoint = try makeEndpoint()
            let models = try await client.listModels(
                endpoint: endpoint,
                bearerToken: normalizedCredential.isEmpty ? nil : normalizedCredential
            )
            discoveredModels = models
            if !models.contains(where: { $0.id == normalizedModelID }) {
                modelID = models[0].id
            }
            statusMessage = "연결됨 · 모델 \(models.count)개"
        } catch {
            discoveredModels = []
            errorMessage = error.localizedDescription
        }
    }

    private func save() {
        do {
            let endpoint = try makeEndpoint()
            let credentialReference = normalizedCredential.isEmpty
                ? nil
                : "credential.\(connectionID)"
            let connection = try ModelConnectionConfiguration(
                id: connectionID,
                displayName: normalizedName,
                kind: .openAICompatible,
                baseURL: endpoint.baseURL,
                modelID: normalizedModelID,
                credentialReference: credentialReference
            )
            try appModel.saveModelConnection(
                connection,
                credential: normalizedCredential.isEmpty ? nil : normalizedCredential
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func makeEndpoint() throws -> OpenAICompatibleEndpoint {
        guard let url = URL(string: normalizedBaseURL) else {
            throw RuntimeProfileError.invalidBaseURL
        }
        return try OpenAICompatibleEndpoint(baseURL: url)
    }
}
