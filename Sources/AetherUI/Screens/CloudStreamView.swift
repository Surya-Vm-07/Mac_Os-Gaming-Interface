import AetherCore
import SwiftUI
import WebKit

/// Borderless in-window player for a cloud service's web client.
///
/// - Login cookies persist in the default website data store (non-sandboxed app).
/// - The user agent ends in Safari's product token. Both services officially support Safari
///   on macOS, and some refuse unknown embedded browsers.
/// - Element fullscreen is enabled so the service's own fullscreen button works.
/// - Pop-up logins are loaded in the same view instead of being dropped.
/// - When the view is dismantled the page is torn down, and WebKit ends its content process
///   (where the video decoder's memory lives).
struct CloudStreamView: NSViewRepresentable {
    let service: CloudService

    func makeCoordinator() -> PopupRedirector {
        PopupRedirector()
    }

    func makeNSView(context: Context) -> StreamWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.applicationNameForUserAgent = "Version/18.0 Safari/605.1.15"
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.mediaTypesRequiringUserActionForPlayback = []

        let webView = StreamWebView(frame: .zero, configuration: configuration)
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        webView.load(URLRequest(url: service.webURL))
        return webView
    }

    func updateNSView(_ webView: StreamWebView, context: Context) {}

    static func dismantleNSView(_ webView: StreamWebView, coordinator: PopupRedirector) {
        webView.stopLoading()
        webView.uiDelegate = nil
        webView.loadHTMLString("", baseURL: nil)
    }
}

/// Grabs keyboard focus when it lands in a window, so keys reach the stream, not the library.
final class StreamWebView: WKWebView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }
}

@MainActor
final class PopupRedirector: NSObject, WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }
}
