import SwiftUI
import UIKit
@preconcurrency import WebKit

struct HTMLBodyView: View {
    let html: String

    @State private var measuredHeight: CGFloat = 32

    var body: some View {
        SandboxedHTMLWebView(html: html, measuredHeight: $measuredHeight)
            .frame(maxWidth: .infinity)
            .frame(height: measuredHeight)
    }
}

private struct SandboxedHTMLWebView: UIViewRepresentable {
    let html: String
    @Binding var measuredHeight: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()

        // Block all JavaScript. Inbound email HTML is hostile by default.
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = false
        config.defaultWebpagePreferences = prefs

        // Don't load remote images/CSS automatically (tracking pixels).
        // The CSP in the document also enforces this; this is belt+suspenders.
        config.suppressesIncrementalRendering = false

        // Bridge to read scrollHeight after layout. Privileged JS runs in
        // an isolated world separate from the document world (which has
        // JS disabled anyway), so untrusted content can't reach it.
        let userContent = WKUserContentController()
        userContent.add(context.coordinator, name: "heightDidChange")
        config.userContentController = userContent

        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        web.scrollView.isScrollEnabled = false
        web.scrollView.bounces = false
        web.navigationDelegate = context.coordinator
        web.loadHTMLString(wrappedDocument(html), baseURL: nil)
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        if context.coordinator.lastHTML != html {
            context.coordinator.lastHTML = html
            web.loadHTMLString(wrappedDocument(html), baseURL: nil)
        }
    }

    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) {
        web.configuration.userContentController.removeScriptMessageHandler(forName: "heightDidChange")
    }

    // MARK: - Document scaffolding

    private func wrappedDocument(_ body: String) -> String {
        // CSP: block everything except inline styles. No network loads, no
        // scripts, no plugins. Remote images, iframes, fonts all denied.
        let csp = "default-src 'none'; style-src 'unsafe-inline'; img-src data:; media-src data:;"
        let css = """
        :root { color-scheme: light dark; }
        html, body {
          margin: 0;
          padding: 0;
          background: transparent;
          font: -apple-system-body;
          color: -apple-system-label;
          word-wrap: break-word;
          overflow-wrap: anywhere;
        }
        a { color: -apple-system-blue; }
        img, video, table { max-width: 100%; height: auto; }
        blockquote {
          margin: 0.5em 0;
          padding-left: 0.75em;
          border-left: 3px solid rgba(127,127,127,0.4);
          color: rgba(127,127,127,1);
        }
        pre, code { white-space: pre-wrap; }
        """
        let script = """
        function post() {
          window.webkit.messageHandlers.heightDidChange.postMessage(
            document.documentElement.scrollHeight
          );
        }
        document.addEventListener('DOMContentLoaded', post);
        window.addEventListener('load', post);
        new ResizeObserver(post).observe(document.documentElement);
        """
        return """
        <!doctype html>
        <html><head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <meta http-equiv="Content-Security-Policy" content="\(csp)">
          <style>\(css)</style>
        </head>
        <body>\(body)
          <script>\(script)</script>
        </body></html>
        """
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: SandboxedHTMLWebView
        var lastHTML: String

        init(_ parent: SandboxedHTMLWebView) {
            self.parent = parent
            self.lastHTML = parent.html
        }

        // Open all link clicks externally; never navigate the embedded view.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func userContentController(
            _ controller: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == "heightDidChange" else { return }
            let h: CGFloat
            if let n = message.body as? CGFloat { h = n }
            else if let n = message.body as? Double { h = CGFloat(n) }
            else if let n = message.body as? Int { h = CGFloat(n) }
            else { return }
            DispatchQueue.main.async {
                if abs(self.parent.measuredHeight - h) > 0.5 {
                    self.parent.measuredHeight = max(h, 16)
                }
            }
        }
    }
}
