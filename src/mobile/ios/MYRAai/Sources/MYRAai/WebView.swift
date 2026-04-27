import SwiftUI
import WebKit
import UIKit
import Network
import UniformTypeIdentifiers

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
            Task { @MainActor [weak self] in
                guard let self else { return }
                if path.status == .satisfied && self.wasOffline {
                    self.wasOffline = false
                    self.reload()
                } else if path.status != .satisfied {
                    self.wasOffline = true
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "eu.myra.myraai.network"))
    }

    func reload() {
        showOffline = false
        isLoaded = false
        webView?.reload()
    }

    deinit {
        networkMonitor?.cancel()
    }
}

// MARK: - Weak proxy — breaks WKScriptMessageHandler retain cycle

private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var delegate: WKScriptMessageHandler?
    init(_ delegate: WKScriptMessageHandler) { self.delegate = delegate }
    func userContentController(_ controller: WKUserContentController,
                                didReceive message: WKScriptMessage) {
        delegate?.userContentController(controller, didReceive: message)
    }
}

// MARK: - WebView

struct WebView: UIViewRepresentable {
    @ObservedObject var state: WebViewState

    func makeCoordinator() -> Coordinator { Coordinator(state: state) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.preferredContentMode = .mobile
        config.applicationNameForUserAgent = "MYRAai-iOS/1.0"

        let proxy = WeakScriptMessageHandler(context.coordinator.bridge)
        for name in NativeBridge.handlerNames {
            config.userContentController.add(proxy, name: name)
        }

        let shim = WKUserScript(source: jsShim,
                                injectionTime: .atDocumentStart,
                                forMainFrameOnly: true)
        config.userContentController.addUserScript(shim)

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.bounces = false
        webView.scrollView.keyboardDismissMode = .interactive
        webView.backgroundColor = UIColor(red: 13/255, green: 27/255, blue: 42/255, alpha: 1)
        webView.isOpaque = false
        webView.allowsBackForwardNavigationGestures = false

        context.coordinator.webView = webView
        context.coordinator.setupKeyboardObservers()

        MainActor.assumeIsolated {
            state.webView = webView
            state.startNetworkMonitor()
        }
        webView.load(URLRequest(url: URL(string: "https://ai.myra.eu")!))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

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
            },
            getDeviceToken: function(callbackName) {
                window.webkit.messageHandlers.getDeviceToken.postMessage(callbackName);
            },
            requestFullPushPermission: function() {
                window.webkit.messageHandlers.requestFullPushPermission.postMessage(null);
            }
        };
        // Inject a privacy policy link visible before login, and a flag for the file picker.
        // The link attaches to the login form so users can review privacy terms before signing up.
        // The frontend reads this flag to disable the attach button on older devices.
        window.__MYRAFilePickerSupported = \(filePickerAvailable ? "true" : "false");
        var style = document.createElement('style');
        style.textContent = '* { -webkit-touch-callout: none; } ' +
            'input, textarea, [contenteditable] { -webkit-touch-callout: default; user-select: text; } ' +
            '#myra-privacy-link { display:block; text-align:center; margin-top:16px; font-size:12px; color:#8899aa; } ' +
            '#myra-privacy-link a { color:#8899aa; text-decoration:underline; }';
        document.head.appendChild(style);
        function injectPrivacyLink() {
            if (document.getElementById('myra-privacy-link')) return;
            var form = document.querySelector('form');
            if (!form) return;
            var div = document.createElement('div');
            div.id = 'myra-privacy-link';
            div.innerHTML = '<a href="https://ai.myra.eu/privacy" target="_blank">Privacy Policy</a>';
            form.parentNode.insertBefore(div, form.nextSibling);
        }
        var _privacyObserver = new MutationObserver(injectPrivacyLink);
        _privacyObserver.observe(document.body || document.documentElement,
            { childList: true, subtree: true });
        injectPrivacyLink();
    })();
    """

    private var filePickerAvailable: Bool {
        if #available(iOS 18.4, *) { return true }
        return false
    }
}

// MARK: - Coordinator

extension WebView {
    final class Coordinator: NSObject,
                              WKNavigationDelegate,
                              WKUIDelegate,
                              UIDocumentPickerDelegate {
        let state: WebViewState
        let bridge: NativeBridge
        weak var webView: WKWebView?
        private var filePickerCompletion: (([URL]?) -> Void)?

        init(state: WebViewState) {
            self.state = state
            self.bridge = NativeBridge()
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
            filePickerCompletion?(nil)
        }

        // MARK: Keyboard — entirely in UIKit to match system animation curve precisely
        // and avoid SwiftUI layout shifts that cause double-scroll in the chat input.

        func setupKeyboardObservers() {
            NotificationCenter.default.addObserver(
                self, selector: #selector(keyboardWillChange(_:)),
                name: UIResponder.keyboardWillShowNotification, object: nil)
            NotificationCenter.default.addObserver(
                self, selector: #selector(keyboardWillHide(_:)),
                name: UIResponder.keyboardWillHideNotification, object: nil)
        }

        @objc private func keyboardWillChange(_ notification: Notification) {
            guard let webView,
                  let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
                  let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double,
                  let curveInt = notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int
            else { return }
            let safeBottom = webView.safeAreaInsets.bottom
            let inset = max(0, frame.height - safeBottom)
            UIView.animate(
                withDuration: duration, delay: 0,
                options: UIView.AnimationOptions(rawValue: UInt(curveInt << 16))
            ) { [weak webView] in
                webView?.scrollView.contentInset.bottom = inset
                webView?.scrollView.verticalScrollIndicatorInsets.bottom = inset
            }
        }

        @objc private func keyboardWillHide(_ notification: Notification) {
            guard let webView,
                  let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double,
                  let curveInt = notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int
            else { return }
            UIView.animate(
                withDuration: duration, delay: 0,
                options: UIView.AnimationOptions(rawValue: UInt(curveInt << 16))
            ) { [weak webView] in
                webView?.scrollView.contentInset.bottom = 0
                webView?.scrollView.verticalScrollIndicatorInsets.bottom = 0
            }
        }

        // MARK: External link interception

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url,
                  let host = url.host else {
                decisionHandler(.allow); return
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
            guard (error as NSError).code != NSURLErrorCancelled else { return }
            Task { @MainActor in self.state.showOffline = true }
        }

        func webView(_ webView: WKWebView,
                     didFail navigation: WKNavigation!, withError error: Error) {
            Task { @MainActor in self.state.showOffline = true }
        }

        // MARK: File picker — iOS 16.4+ (WKUIDelegate)

        @available(iOS 18.4, *)
        func webView(_ webView: WKWebView,
                     runOpenPanelWith parameters: WKOpenPanelParameters,
                     initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping ([URL]?) -> Void) {
            filePickerCompletion = completionHandler
            let types: [UTType] = [.data, .image, .pdf, .plainText, .spreadsheet, .presentation]
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: types)
            picker.allowsMultipleSelection = false
            picker.delegate = self
            guard let root = UIApplication.shared.keyWindow?.rootViewController else {
                completionHandler(nil); filePickerCompletion = nil; return
            }
            if let popover = picker.popoverPresentationController {
                popover.sourceView = root.view
                popover.sourceRect = CGRect(x: root.view.bounds.midX,
                                            y: root.view.bounds.midY, width: 1, height: 1)
                popover.permittedArrowDirections = []
            }
            root.present(picker, animated: true)
        }

        // MARK: UIDocumentPickerDelegate

        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            filePickerCompletion?(urls); filePickerCompletion = nil
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            filePickerCompletion?(nil); filePickerCompletion = nil
        }
    }
}
