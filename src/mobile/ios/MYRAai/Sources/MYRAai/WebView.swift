import WebKit
import SwiftUI
import Network

// MARK: - State

@MainActor
final class WebViewState: ObservableObject {
    @Published var isLoaded = false
    @Published var showOffline = false

    weak var webView: WKWebView?
    private var networkMonitor: NWPathMonitor?
    private var wasOffline = false

    func startNetworkMonitor() {
        let monitor = NWPathMonitor()
        networkMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            Task { @MainActor in
                if path.status == .satisfied && self.wasOffline {
                    self.wasOffline = false
                    self.reload()
                } else if path.status != .satisfied {
                    self.wasOffline = true
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "network.monitor"))
    }

    func reload() {
        showOffline = false
        isLoaded = false
        if let webView {
            webView.reload()
        } else {
            webView?.load(URLRequest(url: URL(string: "https://ai.myra.eu")!))
        }
    }

    deinit {
        networkMonitor?.cancel()
    }
}

// MARK: - Weak proxy to break WKScriptMessageHandler retain cycle

private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var delegate: WKScriptMessageHandler?
    init(_ delegate: WKScriptMessageHandler) { self.delegate = delegate }
    func userContentController(_ controller: WKUserContentController,
                                didReceive message: WKScriptMessage) {
        delegate?.userContentController(controller, didReceive: message)
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
        // Appends to default UA — no async required, no race condition
        config.applicationNameForUserAgent = "MYRAai-iOS/1.0"

        // Register message handlers via weak proxy to break retain cycle
        let proxy = WeakScriptMessageHandler(context.coordinator.bridge)
        for handler in NativeBridge.handlerNames {
            config.userContentController.add(proxy, name: handler)
        }

        // Inject window.Android shim + long-press suppression — main frame only
        let shim = WKUserScript(
            source: jsShim,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true  // must be true: prevents injection into iframes
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

        state.webView = webView
        state.startNetworkMonitor()
        webView.load(URLRequest(url: URL(string: "https://ai.myra.eu")!))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    // MARK: - JS shim injected into every page (main frame only)

    private let jsShim = """
    (function() {
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
        var style = document.createElement('style');
        style.textContent = '* { -webkit-touch-callout: none; } input, textarea, [contenteditable] { -webkit-touch-callout: default; user-select: text; }';
        document.head.appendChild(style);
    })();
    """
}

// MARK: - Coordinator

extension WebView {
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate,
                              UIDocumentPickerDelegate {
        let state: WebViewState
        let bridge: NativeBridge
        private var filePickerCompletion: (([URL]?) -> Void)?

        init(state: WebViewState) {
            self.state = state
            self.bridge = NativeBridge()
        }

        // MARK: External link interception

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

        // MARK: Page lifecycle

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in
                self.state.isLoaded = true
                self.state.showOffline = false
            }
        }

        func webView(_ webView: WKWebView,
                     didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            let nsError = error as NSError
            guard nsError.code != NSURLErrorCancelled else { return }
            Task { @MainActor in self.state.showOffline = true }
        }

        func webView(_ webView: WKWebView,
                     didFail navigation: WKNavigation!,
                     withError error: Error) {
            Task { @MainActor in self.state.showOffline = true }
        }

        // MARK: File picker (WKUIDelegate)
        // UIDocumentPickerViewController uses delegate pattern — no completionHandler property

        func webView(_ webView: WKWebView,
                     runOpenPanelWith parameters: WKOpenPanelParameters,
                     initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping ([URL]?) -> Void) {
            filePickerCompletion = completionHandler
            let picker = UIDocumentPickerViewController(
                forOpeningContentTypes: [.data, .image, .pdf, .text]
            )
            picker.allowsMultipleSelection = false
            picker.delegate = self
            guard let root = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .flatMap({ $0.windows })
                .first(where: { $0.isKeyWindow })?.rootViewController else {
                completionHandler(nil)
                filePickerCompletion = nil
                return
            }
            root.present(picker, animated: true)
        }

        // MARK: UIDocumentPickerDelegate

        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            filePickerCompletion?(urls)
            filePickerCompletion = nil
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            filePickerCompletion?(nil)
            filePickerCompletion = nil
        }
    }
}
