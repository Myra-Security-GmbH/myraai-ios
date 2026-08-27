import SwiftUI
import WebKit
import UIKit
import Network
import Darwin
import ObjectiveC

// Read the raw machine identifier (e.g. "iPhone15,2") via sysctl. Used to
// extend the WebView UA so the gateway server can resolve the marketing
// name ("iPhone 14 Pro") via a small server-side lookup table — keeps the
// app independent of new iPhone model announcements.
private func deviceMachineIdentifier() -> String {
    var sys = utsname()
    uname(&sys)
    return withUnsafePointer(to: &sys.machine) { ptr in
        ptr.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) {
            String(cString: $0)
        }
    }
}

// MARK: - State

@MainActor
final class WebViewState: ObservableObject {
    @Published var isLoaded = false
    @Published var showOffline = false

    weak var webView: WKWebView?
    private var networkMonitor: NWPathMonitor?
    private var wasOffline = false
    // A universal-link URL that arrived before the WebView was built (cold
    // launch). makeUIView consumes it for the initial load. Lifetime: one launch.
    var pendingURL: URL?

    /// Point the WebView at a deep-linked URL (from a tapped ai.myra.eu
    /// universal link). If the WebView isn't built yet (cold launch), stash it
    /// so makeUIView loads it instead of the home screen.
    func navigate(to url: URL) {
        if let webView {
            webView.load(URLRequest(url: url))
        } else {
            pendingURL = url
        }
    }

    func startNetworkMonitor() {
        let monitor = NWPathMonitor()
        networkMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                if path.status == .satisfied && self.wasOffline {
                    self.wasOffline = false
                    // Only reload if the page actually failed to load (showOffline).
                    // A brief connectivity blip while a response is streaming must
                    // NOT trigger a reload — that would wipe the in-progress stream.
                    // The web app recovers transient fetch errors on its own.
                    if self.showOffline { self.reload() }
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

// AGF-1937: kill WebKit's input accessory bar — the ∧/∨ prev-next-field arrows + Done row iOS
// mounts above the keyboard for every web form. Dead weight on the single-page chat (no next field
// to jump to; keyboard dismissal stays available via the interactive swipe — scrollView.
// keyboardDismissMode below) and it costs ~44pt of the visible band on every keyboard open.
//
// Implementation: replace the getter IMPLEMENTATION of the public UIResponder.inputAccessoryView
// property ON THE EXISTING WKContentView class (WebKit's internal first responder inside the scroll
// view). Deliberately NOT the classic "runtime subclass + object_setClass" trick: XCUITest computes
// a web view's automation type from the CLASS NAME, and a renamed subclass
// ("WKContentView_MyraNoInputAccessory") reclassified the content view as "Other" — emptying the
// webview's whole accessibility tree (every LoginTests/ScreenshotTests web query stopped matching;
// caught by the Codemagic prod-smoke logs). Patching in place keeps the class identity, so both
// assistive tech and UI automation keep seeing a normal web view. Process-wide and one-shot: the
// app hosts exactly this one WKWebView, and a WebContent process swap re-creates content views of
// the SAME (patched) class, so no re-application hook is needed.
private enum AccessoryBarKiller {
    private static var installed = false

    static func install(near webView: WKWebView) {
        guard !installed else { return }
        guard let contentView = webView.scrollView.subviews.first(where: {
            String(describing: type(of: $0)).hasPrefix("WKContent")
        }), let cls = object_getClass(contentView) else { return }
        let selector = #selector(getter: UIResponder.inputAccessoryView)
        let block: @convention(block) (AnyObject) -> UIView? = { _ in nil }
        // class_replaceMethod adds an override when the class only inherits the getter, and swaps
        // the implementation when it defines one — both land on "this class returns nil".
        class_replaceMethod(cls, selector, imp_implementationWithBlock(block), "@@:")
        installed = true
    }
}

struct WebView: UIViewRepresentable {
    @ObservedObject var state: WebViewState

    func makeCoordinator() -> Coordinator { Coordinator(state: state) }

    func makeUIView(context: Context) -> WKWebView {
        // XCTestConfigurationFilePath is set only in the test runner process, not in the app
        // process. ScreenshotTests sets launchEnvironment["SCREENSHOT_MODE"]="1" instead,
        // which IS forwarded to the app process by XCUIApplication.launch().
        let isScreenshotMode = ProcessInfo.processInfo.environment["SCREENSHOT_MODE"] == "1"
        let config = WKWebViewConfiguration()
        // Under screenshot runs use a throwaway store so no cached JS bundles interfere.
        config.websiteDataStore = isScreenshotMode ? .nonPersistent() : .default()
        config.defaultWebpagePreferences.preferredContentMode = .mobile
        // UA extension: append app version+build, raw device machine identifier,
        // OS version, and arch so request_log / feedback_context can attribute
        // every request without a separate native bridge call. Mirrors the
        // Android side in MainActivity.kt:setupWebView. arch is "arm64e" on
        // every modern iPhone we ship to (A12 Bionic and later); we hardcode
        // rather than sysctl-read since a JS Layer-2 collector cannot derive
        // it any other way.
        let ver   = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        let machine = deviceMachineIdentifier()
        let osVer = UIDevice.current.systemVersion
        config.applicationNameForUserAgent = "MYRAai-iOS/\(ver) (\(build)) \(machine) / iOS \(osVer) / arm64e"

        let proxy = WeakScriptMessageHandler(context.coordinator.bridge)
        for name in NativeBridge.handlerNames {
            config.userContentController.add(proxy, name: name)
        }

        let shim = WKUserScript(source: jsShim,
                                injectionTime: .atDocumentStart,
                                forMainFrameOnly: true)
        config.userContentController.addUserScript(shim)

        if isScreenshotMode {
            let screenshotScript = WKUserScript(
                source: "window.__myraScreenshotMode = true;",
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
            config.userContentController.addUserScript(screenshotScript)
        }

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.bounces = false
        webView.scrollView.keyboardDismissMode = .interactive
        webView.backgroundColor = .brandBackground
        webView.isOpaque = false
        webView.allowsBackForwardNavigationGestures = false
        // AGF-1937: no form-assistant bar above the keyboard (see AccessoryBarKiller above).
        AccessoryBarKiller.install(near: webView)

        context.coordinator.webView = webView
        context.coordinator.setupKeyboardObservers()
        context.coordinator.observeApnsToken()

        state.webView = webView
        state.startNetworkMonitor()
        // Deep link first (if a universal link launched the app before the
        // WebView existed), else the home URL. pendingURL is one-shot.
        let initialURL = state.pendingURL ?? WebView.startURL()
        state.pendingURL = nil
        #if DEBUG
        // AGF-1948: CI session grant. When the XCUITest runner supplies a pre-minted aig_admin token
        // (-MyraCISessionCookie) + the admin-API host (-MyraAdminHost), pre-seed the session cookie
        // so the app boots ALREADY AUTHENTICATED — no login-UI drive, killing the whole iOS login
        // flake class. The cookie MUST be scoped to the ADMIN-API host (the SPA calls it cross-origin
        // with credentials; a cookie on the SPA host would never be sent there), and the initial load
        // MUST run in setCookie's completion handler (setCookie is async — loading first sends the
        // first navigation unauthenticated). DEBUG-only: -MyraCISessionCookie is physically absent
        // from the Release archive, and the token is a ≤60-min synthetic @local.test session anyway.
        if let ciToken = WebView.launchArgValue("-MyraCISessionCookie"),
           let adminHost = WebView.launchArgValue("-MyraAdminHost"),
           let cookie = HTTPCookie(properties: [
               .name: "aig_admin", .value: ciToken, .domain: adminHost, .path: "/", .secure: "TRUE",
           ]) {
            // The websiteDataStore is PERSISTENT across launches, so a prior test's login session
            // (a different identity) survives and would win over a naive setCookie. DELETE every
            // existing aig_admin cookie first, THEN set ours, THEN load — all in completion handlers
            // (each step is async; racing them reintroduces the wrong-identity boot).
            let store = webView.configuration.websiteDataStore.httpCookieStore
            store.getAllCookies { existing in
                let stale = existing.filter { $0.name == "aig_admin" }
                func setAndLoad() {
                    store.setCookie(cookie) { webView.load(URLRequest(url: initialURL)) }
                }
                guard !stale.isEmpty else { setAndLoad(); return }
                var remaining = stale.count
                for c in stale {
                    store.delete(c) {
                        remaining -= 1
                        if remaining == 0 { setAndLoad() }
                    }
                }
            }
        } else if ProcessInfo.processInfo.arguments.contains("-MyraUITestLocalFileInput") {
            // UI-test hook: load a bare <input type=file> page instead of the live SPA so the attach
            // regression guard (RegressionGuards T-4) can verify WebKit's native upload sheet
            // deterministically — no login, no network. Gated on #if DEBUG AND this launch argument.
            webView.loadHTMLString(WebView.fileInputTestPage, baseURL: nil)
        } else {
            webView.load(URLRequest(url: initialURL))
        }
        #else
        webView.load(URLRequest(url: initialURL))
        #endif
        return webView
    }

    #if DEBUG
    /// Value following a launch-arg flag (e.g. `-MyraCISessionCookie <token>`), or nil. DEBUG-only.
    static func launchArgValue(_ flag: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: flag), args.indices.contains(i + 1) else { return nil }
        let v = args[i + 1]
        return v.isEmpty ? nil : v
    }
    #endif

    #if DEBUG
    // Minimal page for the T-4 attach guard — see the makeUIView hook above.
    private static let fileInputTestPage = """
    <!doctype html><meta name="viewport" content="width=device-width">
    <body style="font:17px -apple-system;padding:40px">
    <input id="f" type="file" aria-label="ui test file input">
    </body>
    """
    #endif

    // Build the initial URL with the system language hint as `?lang=` so the SPA
    // boots in the matching locale on the very first paint (before the user
    // signs in and the DB-stored preference takes over). Only languages the SPA
    // supports are forwarded; everything else falls through to English.
    private static func startURL() -> URL {
        let supported: Set<String> = ["en", "de"]
        let lang = Locale.preferredLanguages.first
            .flatMap { Locale(identifier: $0).language.languageCode?.identifier }
            ?? "en"
        var base = "https://ai.myra.eu"
        #if DEBUG
        // CI hook (AGF-1937): `-MyraBaseURL https://ai-int.myra.eu` points the WebView at another
        // environment, so the Codemagic smoke tests INT (where fixes land pre-prod) instead of prod.
        // DEBUG-only — physically absent from the Release archive shipped to users; xcodebuild test
        // builds Debug, so the XCUITest runner can always pass it.
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-MyraBaseURL"), args.indices.contains(i + 1),
           let override = URL(string: args[i + 1]), override.scheme == "https" {
            base = args[i + 1]
        }
        #endif
        if supported.contains(lang) && lang != "en" {
            return URL(string: "\(base)/?lang=\(lang)")!
        }
        return URL(string: base)!
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    private var jsShim: String { """
    (function() {
        // Capability handshake: this build ships NSMicrophoneUsageDescription
        // and a WKUIDelegate capture-permission handler, so getUserMedia for the
        // mic is safe here. The web /easy composer keys dictation off this flag —
        // older app builds that lack it (and would SIGABRT on mic access) leave it
        // undefined, so the web side hides dictation instead of crashing.
        window.__myraNativeCaps = { microphone: true };
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
        style.textContent = '* { -webkit-touch-callout: none; } ' +
            'input, textarea, [contenteditable] { -webkit-touch-callout: default; user-select: text; }';
        document.head.appendChild(style);
    })();
    """ }
}

// MARK: - Coordinator

extension WebView {
    final class Coordinator: NSObject,
                              WKNavigationDelegate,
                              WKUIDelegate {
        let state: WebViewState
        let bridge: NativeBridge
        weak var webView: WKWebView?
        private var apnsObserver: NSObjectProtocol?

        init(state: WebViewState) {
            self.state = state
            self.bridge = NativeBridge()
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
            if let apnsObserver { NotificationCenter.default.removeObserver(apnsObserver) }
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

        // ai-int.* included so the CI base-URL override (int-targeted smoke) navigates in-app
        // instead of bouncing to Safari; the int hosts are ours.
        private static let ownedHosts = ["ai.myra.eu", "ai-api.myra.eu", "ai-api-admin.myra.eu",
                                         "ai-int.myra.eu", "ai-api-admin-int.myra.eu"]

        // Non-web schemes a web view cannot load itself — hand them to the
        // system so the mail/phone/SMS/maps app opens instead of a silent
        // no-op. Deliberately an allowlist: blob:, data:, about: must stay in
        // the web view, so we never route "everything that isn't http".
        private static let externalSchemes: Set<String> =
            ["mailto", "tel", "sms", "facetime", "facetime-audio", "maps"]

        private static func isOwned(_ host: String) -> Bool {
            ownedHosts.contains(where: { host == $0 || host.hasSuffix(".\($0)") })
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow); return
            }
            if let scheme = url.scheme?.lowercased(), Self.externalSchemes.contains(scheme) {
                if UIApplication.shared.canOpenURL(url) { UIApplication.shared.open(url) }
                decisionHandler(.cancel); return
            }
            guard let host = url.host else {
                decisionHandler(.allow); return
            }
            if Self.isOwned(host) {
                decisionHandler(.allow)
            } else {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
            }
        }

        // target="_blank" / window.open: WKWebView drops these by default (no
        // new-window support), so citation sources and the pre-login privacy
        // link silently do nothing. Owned hosts load in the existing web view;
        // everything else opens in Safari. Returning nil declines the new view.
        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            guard let url = navigationAction.request.url else { return nil }
            if let host = url.host, Self.isOwned(host) {
                webView.load(navigationAction.request)
            } else {
                UIApplication.shared.open(url)
            }
            return nil
        }

        // MARK: Media capture permission (microphone dictation in /easy)
        //
        // Without this delegate WebKit denies every getUserMedia by default, so
        // dictation would silently fail even with NSMicrophoneUsageDescription
        // present. Grant capture only to our own first-party content; anything
        // else (an embedded third-party iframe) is denied. External top-level
        // navigations never reach here — decidePolicyFor routes them to Safari.

        func webView(_ webView: WKWebView,
                     requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                     initiatedByFrame frame: WKFrameInfo,
                     type: WKMediaCaptureType,
                     decisionHandler: @escaping (WKPermissionDecision) -> Void) {
            decisionHandler(Self.isOwned(origin.host) ? .grant : .deny)
        }

        // MARK: Page lifecycle

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // AGF-1937: one-shot late retry — if the content view didn't exist yet at makeUIView
            // time, install the in-place accessory-bar patch now (no-op once installed).
            AccessoryBarKiller.install(near: webView)
            Task { @MainActor in
                self.state.isLoaded = true
                self.state.showOffline = false
            }
            if let token = AppDelegate.apnsToken {
                Self.dispatchApnsToken(token, into: webView)
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

        // MARK: APNs token forwarding

        func observeApnsToken() {
            apnsObserver = NotificationCenter.default.addObserver(
                forName: .apnsTokenReceived, object: nil, queue: .main
            ) { [weak self] note in
                guard let token = note.object as? String, let webView = self?.webView else { return }
                Self.dispatchApnsToken(token, into: webView)
            }
        }

        private static func dispatchApnsToken(_ token: String, into webView: WKWebView) {
            // Token is 64 hex chars from APNs — safe to interpolate.
            let script = "window.__myraApnsToken='\(token)';" +
                         "window.dispatchEvent(new CustomEvent('myra:apns-token',{detail:{token:'\(token)'}}));"
            webView.evaluateJavaScript(script, completionHandler: nil)
        }

        // MARK: File picker
        //
        // We intentionally do NOT implement runOpenPanelWith. WebKit's built-in
        // WKFileUploadPanel already presents the full native sheet (Photo Library
        // / Take Photo or Video / Choose File) and handles security-scoped URLs
        // correctly via import-mode copy. An earlier custom override presented a
        // Files-only UIDocumentPickerViewController in open-in-place mode, which
        // handed WebKit unreadable security-scoped URLs (silent attachment drop,
        // AGF-198) AND removed the camera/photo-library options. Letting WebKit
        // own the panel restores all three sources with zero native code.

        // MARK: WebContent process recovery

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            // The WebContent process can be jettisoned under memory pressure
            // (large image uploads make this more likely), leaving a permanently
            // blank screen — fatal for an app that is nothing but this web view.
            // Reload to recover.
            webView.reload()
        }
    }
}
