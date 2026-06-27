import Foundation

/// Remote-image handling for inbound HTML email.
///
/// The WKWebView renderer is locked to `img-src data:`, so it never loads
/// remote images on its own. We pre-process the HTML here: when images are
/// blocked we swap every remote `<img src>` for a transparent pixel (so the
/// layout doesn't fill with broken-image glyphs); when the user opts in we
/// swap in the bytes fetched through the proxy as `data:` URIs.
enum RemoteImages {
    /// 1×1 transparent GIF — stands in for a blocked remote image.
    static let blankPixel =
        "data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"

    /// Does this HTML reference any remote (`http(s)`) image?
    static func hasRemote(in html: String) -> Bool { !remoteURLs(in: html).isEmpty }

    /// Distinct, absolute remote image URLs referenced by `<img src>`.
    static func remoteURLs(in html: String) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for tag in matches(in: html, pattern: imgTagPattern) {
            guard let src = attrValue(tag, "src"),
                  let norm = normalizedRemoteURL(src),
                  !seen.contains(norm) else { continue }
            seen.insert(norm)
            out.append(norm)
        }
        return out
    }

    /// Rewrite every `<img>`: replace a remote `src` with `replacement(url)`
    /// (a `data:` URI or the blank pixel) and strip `srcset` so it can't slip
    /// a remote load past the rewrite.
    ///
    /// Images the sandboxed renderer can't load at all — `cid:` inline parts,
    /// relative paths, anything that isn't `data:` — are swapped for the blank
    /// pixel too. The CSP (`img-src data:`) would block them and leave a
    /// broken-image box; blanking them renders clean empty space instead.
    static func rewrite(_ html: String, replacement: (String) -> String) -> String {
        replaceMatches(in: html, pattern: imgTagPattern) { tag in
            var t = tag
            if let src = attrValue(tag, "src") {
                if let norm = normalizedRemoteURL(src) {
                    t = setAttr(t, "src", replacement(norm))
                } else if !src.trimmingCharacters(in: .whitespacesAndNewlines)
                            .lowercased().hasPrefix("data:") {
                    t = setAttr(t, "src", blankPixel)
                }
            }
            if attrValue(tag, "srcset") != nil {
                t = removeAttr(t, "srcset")
            }
            return t
        }
    }

    // MARK: - URL helpers

    /// Returns an absolute http(s) URL, or nil if `raw` isn't a remote ref
    /// (data:, cid:, relative paths, etc. all return nil).
    static func normalizedRemoteURL(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = t.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") { return t }
        if t.hasPrefix("//") { return "https:" + t }
        return nil
    }

    // MARK: - Tiny regex-backed HTML helpers
    //
    // Full DOM parsing isn't worth a dependency here: inbound email <img>
    // tags are well-formed in practice, and the renderer's CSP is the real
    // safety net. These operate on individual <img ...> tag substrings.

    private static let imgTagPattern = "(?is)<img\\b[^>]*>"

    private static func attrValue(_ tag: String, _ attr: String) -> String? {
        let pattern = "(?i)\\b\(attr)\\s*=\\s*(\"([^\"]*)\"|'([^']*)')"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let full = NSRange(tag.startIndex..., in: tag)
        guard let m = re.firstMatch(in: tag, range: full) else { return nil }
        for group in [2, 3] {
            if let r = Range(m.range(at: group), in: tag) { return String(tag[r]) }
        }
        return nil
    }

    private static func setAttr(_ tag: String, _ attr: String, _ value: String) -> String {
        let pattern = "(?i)\\b\(attr)\\s*=\\s*(\"[^\"]*\"|'[^']*')"
        // value is a data: URI (safe characters) — quote with double quotes.
        return replaceFirst(tag, pattern: pattern) { _ in "\(attr)=\"\(value)\"" }
    }

    private static func removeAttr(_ tag: String, _ attr: String) -> String {
        let pattern = "(?i)\\s*\\b\(attr)\\s*=\\s*(\"[^\"]*\"|'[^']*')"
        return replaceFirst(tag, pattern: pattern) { _ in "" }
    }

    private static func matches(in s: String, pattern: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }
    }

    private static func replaceMatches(
        in s: String,
        pattern: String,
        transform: (String) -> String
    ) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        let ns = s as NSString
        let ms = re.matches(in: s, range: NSRange(location: 0, length: ns.length))
        guard !ms.isEmpty else { return s }
        var result = ""
        var last = 0
        for m in ms {
            let r = m.range
            result += ns.substring(with: NSRange(location: last, length: r.location - last))
            result += transform(ns.substring(with: r))
            last = r.location + r.length
        }
        result += ns.substring(with: NSRange(location: last, length: ns.length - last))
        return result
    }

    private static func replaceFirst(
        _ s: String,
        pattern: String,
        transform: (String) -> String
    ) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return s }
        let r = m.range
        return ns.substring(to: r.location)
            + transform(ns.substring(with: r))
            + ns.substring(from: r.location + r.length)
    }
}

extension String {
    /// The domain of an email address, unwrapping a `Name <a@b.com>` form.
    /// Returns "" when there's no `@`.
    var emailHostDomain: String {
        var s = self
        if let lt = s.firstIndex(of: "<"), let gt = s.firstIndex(of: ">"), lt < gt {
            s = String(s[s.index(after: lt)..<gt])
        }
        guard let at = s.lastIndex(of: "@") else { return "" }
        return s[s.index(after: at)...]
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
    }
}
