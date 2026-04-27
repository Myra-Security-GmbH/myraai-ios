import WebKit
import SwiftUI

// MARK: - State

final class WebViewState: ObservableObject {
    @Published var isLoaded = false
    @Published var showOffline = false

    weak var webView: WKWebView?

    func reload() {
        showOffline = false
        isLoaded = false
        webView?.reload()
    }

    func load() {
        let url = URL(string: "https://ai.myra.eu")!
        webView?.load(URLRequest(url: url))
    }
}

// MARK: - WebView (UIViewRepresentable)

struct WebView: UIViewRepresentable {
    @ObservedObject var state: WebViewState

    func makeCoordinator() -> Coordinator {
        Coordinator(state: state)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.preferredContentMode = .mobile

        // Register message handlers for JS bridge
        let bridge = context.coordinator.bridge
        for handler in NativeBridge.handlerNames {
            config.userContentController.add(bridge, name: handler)
        }

        // Inject window.Android shim + long-press suppression at document start
        let shim = WKUserScript(
            source: jsShim,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        config.userContentController.addUserScript(shim)

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.bounces = true
        webView.backgroundColor = UIColor(red: 13/255, green: 27/255, blue: 42/255, alpha: 1)
        webView.isOpaque = false
        webView.allowsBackForwardNavigationGestures = false

        // Custom User-Agent
        webView.evaluateJavaScript("navigator.userAgent") { result, _ in
            if let ua = result as? String {
                webView.customUserAgent = "\(ua) MYRAai-iOS/1.0"
            }
        }

        state.webView = webView
        webView.load(URLRequest(url: URL(string: "https://ai.myra.eu")!))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    // MARK: - JS shim injected into every page

    private let jsShim = """
    (function() {
        // Map window.Android to iOS WKScriptMessageHandler so web app needs no changes
        window.Android = {
            hapticFeedback: function(type) {
                window.webkit.messageHandlers.hapticFeedback.postMessage(type);
            },
            share: function(text, url) {
                window.webkit.messageHandlers.share.postMessage({text: text, url: url});
            },
            copyToClipboard: function(text) {
                window.webkit.messageHandlers.copyToClipboard.postMessage(text);
            },
            notifyScrollTop: function(scrolled) {
                window.webkit.messageHandlers.notifyScrollTop.postMessage(scrolled);
            }
        };
        // Suppress long-press text selection on non-input elements
        var style = document.createElement('style');
        style.textContent = '* { -webkit-touch-callout: none; } input, textarea, [contenteditable] { -webkit-touch-callout: default; user-select: text; }';
        document.head.appendChild(style);
    })();
    """
}

// MARK: - Coordinator (Navigation + UI delegate)

extension WebView {
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let state: WebViewState
        let bridge: NativeBridge

        init(state: WebViewState) {
            self.state = state
            self.bridge = NativeBridge()
        }

        // External link interception
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url,
                  let host = url.host else {
                decisionHandler(.allow)
                return
            }
            let ownedHosts = ["ai.myra.eu", "ai-api.myra.eu", "ai-api-admin.myra.eu"]
            if ownedHosts.contains(where: { host == $0 || host.hasSuffix(".\($0)") }) {
                decisionHandler(.allow)
            } else {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
            }
        }

        // Page loaded — dismiss launch overlay
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.state.isLoaded = true
                self.state.showOffline = false
            }
        }

        // Offline / error
        func webView(_ webView: WKWebView,
                     didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            let nsError = error as NSError
            // Ignore cancelled navigations (e.g. redirects)
            guard nsError.code != NSURLErrorCancelled else { return }
            DispatchQueue.main.async {
                self.state.showOffline = true
            }
        }

        func webView(_ webView: WKWebView,
                     didFail navigation: WKNavigation!,
                     withError error: Error) {
            DispatchQueue.main.async {
                self.state.showOffline = true
            }
        }

        // File picker
        func webView(_ webView: WKWebView,
                     runOpenPanelWith parameters: WKOpenPanelParameters,
                     initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping ([URL]?) -> Void) {
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data, .image, .pdf, .text])
            picker.allowsMultipleSelection = false
            picker.completionHandler = completionHandler
            if let root = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .flatMap({ $0.windows })
                .first(where: { $0.isKeyWindow })?.rootViewController {
                root.present(picker, animated: true)
            } else {
                completionHandler(nil)
            }
        }
    }
}
