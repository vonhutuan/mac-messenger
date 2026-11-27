import AppKit
import AVFoundation
import WebKit

/// Hosts secondary popup windows spawned via `window.open(...)` — most importantly
/// Facebook Messenger's voice and video call windows — preserving `window.opener` and WebRTC sessions.
@MainActor
final class PopupWindowController: NSWindowController, NSWindowDelegate, WKUIDelegate, WKNavigationDelegate {
    let webView: WKWebView
    private let onClose: (PopupWindowController) -> Void

    init(
        configuration: WKWebViewConfiguration,
        windowFeatures: WKWindowFeatures,
        onClose: @escaping (PopupWindowController) -> Void
    ) {
        self.onClose = onClose
        self.webView = WKWebView(frame: .zero, configuration: configuration)

        let width = windowFeatures.width?.doubleValue ?? 960
        let height = windowFeatures.height?.doubleValue ?? 680
        let rect = NSRect(
            x: 0,
            y: 0,
            width: max(420, width),
            height: max(360, height)
        )

        let window = NSWindow(
            contentRect: rect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Messenger Call"
        window.center()
        window.isReleasedWhenClosed = false

        super.init(window: window)

        window.delegate = self

        webView.customUserAgent = InjectedScripts.safariUserAgent
        webView.uiDelegate = self
        webView.navigationDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: rect)
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        window.contentView = container
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // Stop any active call/audio streams when the user manually closes the popup window.
        webView.loadHTMLString("", baseURL: nil)
        onClose(self)
    }

    // MARK: - WKUIDelegate

    func webViewDidClose(_ webView: WKWebView) {
        window?.close()
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
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if let title = webView.title, !title.isEmpty {
            window?.title = title
        }
        decisionHandler(.allow)
    }
}

@MainActor
enum MediaPermissionHelper {
    private static let allowedHostSuffixes = [
        "facebook.com",
        "messenger.com",
        "fbcdn.net"
    ]

    static func isTrustedHost(_ host: String) -> Bool {
        let lower = host.lowercased()
        return allowedHostSuffixes.contains { lower == $0 || lower.hasSuffix(".\($0)") }
    }

    static func handleCaptureRequest(
        origin: WKSecurityOrigin,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        guard isTrustedHost(origin.host) else {
            decisionHandler(.deny)
            return
        }

        Task {
            var audioOK = true
            var videoOK = true

            if type == .microphone || type == .cameraAndMicrophone {
                audioOK = await requestSystemAccess(for: .audio)
            }
            if type == .camera || type == .cameraAndMicrophone {
                videoOK = await requestSystemAccess(for: .video)
            }

            if audioOK && videoOK {
                decisionHandler(.grant)
            } else {
                decisionHandler(.prompt)
            }
        }
    }

    private static func requestSystemAccess(for mediaType: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: mediaType) { granted in
                    continuation.resume(returning: granted)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }
}
