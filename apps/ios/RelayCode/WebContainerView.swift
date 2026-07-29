import RelayCodeCore
import SwiftUI
import UIKit
import WebKit

struct WebContainerView: UIViewRepresentable {
    let pairing: PairingConfiguration
    let resumeGeneration: UUID
    let onSavePairing: (String, String) -> Void
    let onClearPairing: () -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            allowedWebURL: pairing.webURL,
            onSavePairing: onSavePairing,
            onClearPairing: onClearPairing,
            onError: onError
        )
    }

    func makeUIView(context: Context) -> WKWebView {
        let userContent = WKUserContentController()
        userContent.addUserScript(
            WKUserScript(
                source: Self.injectionSource(for: pairing),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
        userContent.add(context.coordinator, name: "relaycode")

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = userContent
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never
#if DEBUG
        webView.isInspectable = true
#endif
        context.coordinator.lastResumeGeneration = resumeGeneration
        webView.load(
            URLRequest(
                url: pairing.webURL,
                cachePolicy: .reloadRevalidatingCacheData,
                timeoutInterval: 15
            )
        )
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.lastResumeGeneration != resumeGeneration else {
            return
        }
        context.coordinator.lastResumeGeneration = resumeGeneration
        webView.evaluateJavaScript(
            "window.dispatchEvent(new Event('relaycode:native-resume'))"
        )
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "relaycode")
        webView.navigationDelegate = nil
    }

    private static func injectionSource(for pairing: PairingConfiguration) -> String {
        let payload = [
            "token": pairing.token,
            "bridge": pairing.bridgeURL.absoluteString,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            return "window.__RELAYCODE_NATIVE__ = true;"
        }
        return """
        window.__RELAYCODE_NATIVE__ = true;
        window.__RELAYCODE_NATIVE_PAIRING__ = \(json);
        """
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let allowedWebURL: URL
        let onSavePairing: (String, String) -> Void
        let onClearPairing: () -> Void
        let onError: (String) -> Void
        var lastResumeGeneration: UUID?

        init(
            allowedWebURL: URL,
            onSavePairing: @escaping (String, String) -> Void,
            onClearPairing: @escaping () -> Void,
            onError: @escaping (String) -> Void
        ) {
            self.allowedWebURL = allowedWebURL
            self.onSavePairing = onSavePairing
            self.onClearPairing = onClearPairing
            self.onError = onError
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == "relaycode",
                  let body = message.body as? [String: Any],
                  let type = body["type"] as? String else {
                return
            }
            switch type {
            case "savePairing":
                guard let token = body["token"] as? String,
                      let bridge = body["bridge"] as? String else {
                    return
                }
                onSavePairing(token, bridge)
            case "clearPairing":
                onClearPairing()
            default:
                break
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            if url.scheme == "about" {
                decisionHandler(.allow)
                return
            }
            if url.scheme == "relaycode" {
                decisionHandler(.cancel)
                return
            }
            guard isSameOrigin(url, allowedWebURL) else {
                if navigationAction.navigationType == .linkActivated {
                    UIApplication.shared.open(url)
                }
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation?,
            withError error: Error
        ) {
            onError("RelayCode 화면을 불러오지 못했습니다. \(error.localizedDescription)")
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation?,
            withError error: Error
        ) {
            onError("RelayCode 연결이 끊겼습니다. \(error.localizedDescription)")
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            webView.reload()
        }

        private func isSameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
            lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
                && lhs.host?.lowercased() == rhs.host?.lowercased()
                && effectivePort(lhs) == effectivePort(rhs)
        }

        private func effectivePort(_ url: URL) -> Int? {
            if let port = url.port {
                return port
            }
            switch url.scheme?.lowercased() {
            case "https":
                return 443
            case "http":
                return 80
            default:
                return nil
            }
        }
    }
}
