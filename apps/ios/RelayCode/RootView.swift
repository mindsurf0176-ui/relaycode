import RelayCodeCore
import SwiftUI
import UIKit

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if let pairing = model.pairing {
                NativeWebShell(pairing: pairing)
            } else {
                PairingView()
            }
        }
        .preferredColorScheme(.dark)
        .onOpenURL { url in
            model.importPairing(url.absoluteString)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                model.sceneBecameActive()
            }
        }
        .alert(
            "RelayCode",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("확인", role: .cancel) {
                model.errorMessage = nil
            }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

private struct PairingView: View {
    @EnvironmentObject private var model: AppModel
    @State private var link = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Spacer(minLength: 34)

                BrandMark()

                VStack(alignment: .leading, spacing: 10) {
                    Text("PRIVATE DEV LINK")
                        .font(.caption2.monospaced().weight(.bold))
                        .tracking(1.6)
                        .foregroundStyle(.tint)
                    Text("Mac의 개발 환경을\n안전하게 연결하세요.")
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .tracking(-1.4)
                    Text("저장소와 로그인 정보는 Mac에 남습니다. iPhone에는 페어링 키만 Keychain에 저장합니다.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineSpacing(4)
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("페어링 링크")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            link = UIPasteboard.general.string ?? ""
                        } label: {
                            Label("붙여넣기", systemImage: "doc.on.clipboard")
                                .font(.caption.weight(.semibold))
                        }
                    }

                    TextEditor(text: $link)
                        .font(.footnote.monospaced())
                        .frame(minHeight: 112)
                        .padding(10)
                        .scrollContentBackground(.hidden)
                        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
                        .overlay {
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(Color(uiColor: .separator), lineWidth: 0.5)
                        }
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Text("Mac에서 `npm run pair`로 만든 전체 링크를 붙여넣으세요.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Button {
                    model.importPairing(link)
                } label: {
                    Label("Mac 연결", systemImage: "link")
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .fontWeight(.bold)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.roundedRectangle(radius: 16))
                .disabled(link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Label(
                    "원격 연결은 Tailscale의 HTTPS 주소를 권장합니다.",
                    systemImage: "lock.shield"
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Spacer(minLength: 24)
            }
            .frame(maxWidth: 520, alignment: .leading)
            .padding(.horizontal, 22)
        }
        .background(Color(uiColor: .systemBackground))
    }
}

private struct BrandMark: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22)
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.42, green: 0.91, blue: 0.78), Color(red: 0.49, green: 0.56, blue: 1)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 27, weight: .black))
                .foregroundStyle(Color(uiColor: .systemBackground))
        }
        .frame(width: 68, height: 68)
        .shadow(color: Color.accentColor.opacity(0.2), radius: 24, y: 12)
        .accessibilityLabel("RelayCode")
    }
}

private struct NativeWebShell: View {
    @EnvironmentObject private var model: AppModel
    let pairing: PairingConfiguration

    var body: some View {
        ZStack(alignment: .top) {
            WebContainerView(
                pairing: pairing,
                resumeGeneration: model.resumeGeneration,
                onSavePairing: model.saveFromWeb,
                onClearPairing: model.forgetPairing,
                onError: { model.errorMessage = $0 }
            )
            .id(pairing)
            .ignoresSafeArea()

            if case let .offline(message) = model.health {
                Button {
                    model.refreshHealth()
                } label: {
                    Label(message, systemImage: "wifi.exclamationmark")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
                .accessibilityHint("다시 연결을 확인합니다")
            }
        }
        .task {
            model.refreshHealth()
        }
    }
}
