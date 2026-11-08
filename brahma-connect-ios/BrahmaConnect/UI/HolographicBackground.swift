import SwiftUI
import WebKit

/// Same three.js holographic background the Android app renders in a WebView,
/// loaded from the `web_background` folder bundled into the app.
struct HolographicBackground: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.isUserInteractionEnabled = false
        if let folder = Bundle.main.url(forResource: "web_background", withExtension: nil) {
            webView.loadFileURL(folder.appendingPathComponent("index.html"), allowingReadAccessTo: folder)
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
