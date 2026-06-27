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

private let bridgeWorld = WKContentWorld.world(name: "bmail-bridge")

private struct SandboxedHTMLWebView: UIViewRepresentable {
    let html: String
    @Binding var measuredHeight: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()

        // Block all JavaScript in the document (page) world. Inbound email HTML
        // is hostile by default, so any inline <script> stays inert.
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = false
        config.defaultWebpagePreferences = prefs

        config.suppressesIncrementalRendering = false

        // Privileged height bridge runs in a named isolated world. User scripts
        // and message handlers in non-page worlds still execute when content JS
        // is disabled in the page world, so the document JS context stays off
        // while we still get the rendered height back from layout.
        let userContent = WKUserContentController()
        let script = WKUserScript(
            source: bridgeScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true,
            in: bridgeWorld
        )
        userContent.addUserScript(script)
        userContent.add(context.coordinator, contentWorld: bridgeWorld, name: "heightDidChange")
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
        web.configuration.userContentController.removeScriptMessageHandler(
            forName: "heightDidChange",
            contentWorld: bridgeWorld
        )
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
        return """
        <!doctype html>
        <html><head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <meta http-equiv="Content-Security-Policy" content="\(csp)">
          <style>\(css)</style>
        </head>
        <body>\(body)</body></html>
        """
    }

    private var bridgeScript: String {
        // Injected into the bmail-bridge isolated world via WKUserScript.
        // Runs even with allowsContentJavaScript=false because that flag only
        // gates the page world.
        """
        (function() {
          function post() {
            try {
              window.webkit.messageHandlers.heightDidChange.postMessage(
                document.documentElement.scrollHeight
              );
            } catch (_) {}
          }
          post();
          window.addEventListener('load', post);
          if (typeof ResizeObserver !== 'undefined') {
            new ResizeObserver(post).observe(document.documentElement);
          }
        })();
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

// MARK: - HTML text helpers

extension String {
    /// Heuristic: does this string contain HTML markup worth rendering as a web
    /// document rather than as plain text? Used to catch messages whose HTML
    /// landed in the plain-text body field.
    var looksLikeHTML: Bool {
        range(
            of: "<(/?)(html|body|div|p|br|table|span|a|img|ul|ol|li|h[1-6]|blockquote|strong|em|b|i|font|head|style)\\b[^>]*>",
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    /// A plain-text rendering of HTML suitable for previews/snippets: drops
    /// style/script/head/comment blocks, turns block boundaries into spaces,
    /// strips remaining tags, and decodes a handful of common entities.
    var strippingHTML: String {
        var s = self
        let removals = [
            "(?is)<!--.*?-->",
            "(?is)<style\\b[^>]*>.*?</style>",
            "(?is)<script\\b[^>]*>.*?</script>",
            "(?is)<head\\b[^>]*>.*?</head>"
        ]
        for pattern in removals {
            s = s.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        // Block-closers / line breaks → spaces so words don't run together.
        s = s.replacingOccurrences(
            of: "(?i)<(br|/p|/div|/tr|/li|/h[1-6])\\b[^>]*>",
            with: " ",
            options: .regularExpression
        )
        // Strip all remaining tags.
        s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        // Decode the entities that actually show up in mail previews.
        let entities: [String: String] = [
            "&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">",
            "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&mdash;": "—",
            "&ndash;": "–", "&hellip;": "…", "&zwnj;": "", "&#8203;": ""
        ]
        for (key, value) in entities {
            s = s.replacingOccurrences(of: key, with: value, options: .caseInsensitive)
        }
        // Collapse whitespace runs (incl. newlines) into single spaces.
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
