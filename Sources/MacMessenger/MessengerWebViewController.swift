import AppKit
import WebKit

@MainActor
final class MessengerWebViewController: NSViewController,
    WKUIDelegate,
    WKNavigationDelegate,
    WKScriptMessageHandler,
    WKDownloadDelegate
{
    static let messengerURL = URL(string: "https://www.facebook.com/messages/t/")!

    private(set) var webView: WKWebView!
    private var popupControllers: [PopupWindowController] = []
    private var downloadDestinations: [ObjectIdentifier: URL] = [:]

    var onUnreadCountChanged: ((Int) -> Void)?

    private static let cleanModeDefaultsKey = "HideFacebookTopNav"

    var isCleanModeEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: Self.cleanModeDefaultsKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: Self.cleanModeDefaultsKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.cleanModeDefaultsKey)
            applyCleanModeToWebView(newValue)
        }
    }

    override func loadView() {
        let contentController = WKUserContentController()
        contentController.add(self, name: "messengerNotification")
        contentController.add(self, name: "messengerUnread")

        contentController.addUserScript(
            WKUserScript(
                source: InjectedScripts.notificationShimJS,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
        )
        contentController.addUserScript(
            WKUserScript(
                source: InjectedScripts.unreadObserverJS,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
        )
        contentController.addUserScript(
            WKUserScript(
                source: InjectedScripts.cleanModeScript(enabled: isCleanModeEnabled),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )

        let config = WKWebViewConfiguration()
        config.userContentController = contentController
        config.websiteDataStore = .default()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1120, height: 760), configuration: config)
        webView.customUserAgent = InjectedScripts.safariUserAgent
        webView.allowsBackForwardNavigationGestures = true
        webView.uiDelegate = self
        webView.navigationDelegate = self
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }

        self.view = webView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        loadMessenger()
    }

    func loadMessenger() {
        webView.load(URLRequest(url: Self.messengerURL))
    }

    func reload() {
        webView.reload()
    }

    func adjustZoom(by delta: CGFloat) {
        let next = min(max(webView.pageZoom + delta, 0.7), 2.0)
        webView.pageZoom = next
    }

    func resetZoom() {
        webView.pageZoom = 1.0
    }

    func triggerNotificationClick(jsId: String, threadHref: String = "") {
        let escapedId = jsId.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        let escapedHref = threadHref.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        webView.evaluateJavaScript(
            "window.__macMessengerNotificationClicked && window.__macMessengerNotificationClicked('\(escapedId)', '\(escapedHref)');"
        )
    }

    func copyDebugInfoToPasteboard() {
        webView.evaluateJavaScript("JSON.stringify(window.__macMessengerDebugState || {}, null, 2)") { result, _ in
            let text = (result as? String) ?? "{}"
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
        }
    }

    private func applyCleanModeToWebView(_ enabled: Bool) {
        let flag = enabled ? "true" : "false"
        webView?.evaluateJavaScript("window.__macMessengerSetCleanMode && window.__macMessengerSetCleanMode(\(flag));")
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let payload = message.body as? [String: Any] else { return }

        switch message.name {
        case "messengerNotification":
            let id = payload["id"] as? String ?? UUID().uuidString
            let title = payload["title"] as? String ?? "Messenger"
            let body = payload["body"] as? String ?? ""
            let silent = payload["silent"] as? Bool ?? false
            let threadHref = payload["threadHref"] as? String ?? ""
            NotificationBridge.shared.postNotification(
                id: id,
                title: title,
                body: body,
                silent: silent,
                threadHref: threadHref
            )

        case "messengerUnread":
            let count = payload["count"] as? Int ?? 0
            onUnreadCountChanged?(count)

        default:
            break
        }
    }

    // MARK: - WKUIDelegate (Popups for Voice/Video Calls, Media Capture, File Uploads)

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // External links clicked from chats should open in the user's default browser.
        if let url = navigationAction.request.url, shouldOpenInExternalBrowser(url: url) {
            NSWorkspace.shared.open(url)
            return nil
        }

        // Messenger voice/video calls and internal popups open via `window.open(...)`
        // (sometimes starting at `about:blank` or `facebook.com/groupcall/...`).
        // Returning a real child WKWebView using WebKit's `configuration` preserves `window.opener` and WebRTC state.
        let popup = PopupWindowController(configuration: configuration, windowFeatures: windowFeatures) { [weak self] closed in
            self?.popupControllers.removeAll { $0 === closed }
        }
        popupControllers.append(popup)
        popup.showWindow(nil)
        popup.window?.makeKeyAndOrderFront(nil)
        return popup.webView
    }

    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        MediaPermissionHelper.handleCaptureRequest(origin: origin, type: type, decisionHandler: decisionHandler)
    }

    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping ([URL]?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection

        guard let window = view.window else {
            completionHandler(nil)
            return
        }

        panel.beginSheetModal(for: window) { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download)
            return
        }

        if navigationAction.navigationType == .linkActivated,
           let url = navigationAction.request.url,
           shouldOpenInExternalBrowser(url: url)
        {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }

        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        if !navigationResponse.canShowMIMEType {
            decisionHandler(.download)
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    private func shouldOpenInExternalBrowser(url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        if scheme == "about" || scheme == "blob" || scheme == "data" {
            return false
        }
        guard scheme == "http" || scheme == "https" else {
            return true
        }
        guard let host = url.host?.lowercased() else { return false }

        // Facebook's outbound link shim (`l.facebook.com/l.php?u=...`) always points to external sites.
        if host == "l.facebook.com" || host == "lm.facebook.com" || host == "l.messenger.com" {
            return true
        }

        // Keep Facebook/Messenger/Meta login & call hosts inside the app.
        let internalSuffixes = ["facebook.com", "messenger.com", "fbcdn.net", "fb.com", "meta.com", "accountscenter.facebook.com"]
        let isInternal = internalSuffixes.contains { host == $0 || host.hasSuffix(".\($0)") }
        return !isInternal
    }

    // MARK: - WKDownloadDelegate

    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        let downloadsDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let safeName = suggestedFilename.isEmpty ? "messenger-download" : suggestedFilename
        let target = uniqueDestinationURL(in: downloadsDir, filename: safeName)
        downloadDestinations[ObjectIdentifier(download)] = target
        completionHandler(target)
    }

    func downloadDidFinish(_ download: WKDownload) {
        let key = ObjectIdentifier(download)
        if let destination = downloadDestinations.removeValue(forKey: key) {
            NotificationBridge.shared.postNotification(
                id: "download-\(UUID().uuidString)",
                title: "Download Complete",
                body: destination.lastPathComponent,
                silent: true
            )
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        downloadDestinations.removeValue(forKey: ObjectIdentifier(download))
        NSLog("MacMessenger: Download failed: %@", error.localizedDescription)
    }

    private func uniqueDestinationURL(in directory: URL, filename: String) -> URL {
        let baseURL = directory.appendingPathComponent(filename)
        if !FileManager.default.fileExists(atPath: baseURL.path) {
            return baseURL
        }
        let stem = baseURL.deletingPathExtension().lastPathComponent
        let ext = baseURL.pathExtension
        var index = 1
        while true {
            let candidateName = ext.isEmpty ? "\(stem) (\(index))" : "\(stem) (\(index)).\(ext)"
            let candidate = directory.appendingPathComponent(candidateName)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            index += 1
        }
    }
}
