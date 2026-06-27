import Foundation

/// Splits an HTML email body into the *new* content the sender just wrote and
/// the *quoted* reply history trailing it, so the UI can collapse the history
/// behind a disclosure (the way HEY / Gmail / Apple Mail trim quoted text).
///
/// Detection is heuristic — inbound mail has no machine-readable "this is the
/// quote" marker — so we look for the boundary markers real clients emit and
/// cut at the earliest one:
///   • `<blockquote>` (Apple Mail, many clients)
///   • Gmail's `gmail_quote` container
///   • Thunderbird's `moz-cite-prefix`
///   • Outlook's `divRplyFwdMsg` / `OutlookMessageHeader` / `appendonsend`
///   • Outlook's "From: … Sent: … Subject: …" header block
///   • an "On <date>, <name> wrote:" preamble
///   • a plain-text "-----Original Message-----" separator
///
/// We deliberately do *not* treat `<hr>` or `border-top` divs as boundaries:
/// signatures use those too, and cutting there would swallow the signature of
/// the new message into the quote.
enum QuotedText {

    /// Returns the leading new content and, when a quote boundary is found, the
    /// trailing quoted history. `quoted` is nil when there's no quote, when the
    /// content before the quote is effectively empty (the whole body is a
    /// quote), or when the quote itself carries no visible text.
    static func split(_ html: String) -> (visible: String, quoted: String?) {
        guard let offset = boundaryOffset(html) else { return (html, nil) }
        let ns = html as NSString
        guard offset > 0, offset < ns.length else { return (html, nil) }

        let visible = ns.substring(to: offset)
        let quoted = ns.substring(from: offset)

        // Don't collapse if there's no real new content before the quote, or if
        // the "quote" has no visible text after stripping markup.
        if visible.strippingHTML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return (html, nil)
        }
        if quoted.strippingHTML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return (html, nil)
        }
        return (visible, quoted)
    }

    // MARK: - Boundary detection

    /// Container / preamble markers, matched case-insensitively. The earliest
    /// match across all detectors wins.
    private static let markers = [
        "(?is)<div[^>]*\\bid\\s*=\\s*[\"']?appendonsend",
        "(?is)<div[^>]*\\bclass\\s*=\\s*[\"'][^\"']*gmail_quote",
        "(?is)<div[^>]*\\bid\\s*=\\s*[\"']?divRplyFwdMsg",
        "(?is)<div[^>]*\\bclass\\s*=\\s*[\"'][^\"']*moz-cite-prefix",
        "(?is)<div[^>]*\\bclass\\s*=\\s*[\"'][^\"']*OutlookMessageHeader",
        "(?is)<blockquote\\b",
        "(?i)-{2,}\\s*Original Message\\s*-{2,}",
    ]

    private static func boundaryOffset(_ html: String) -> Int? {
        var best = Int.max
        for pattern in markers {
            if let off = firstMatchLocation(html, pattern), off < best { best = off }
        }
        if let off = outlookHeaderOffset(html), off < best { best = off }
        if let off = onWroteOffset(html), off < best { best = off }
        return best == Int.max ? nil : best
    }

    /// The "From: … Sent:/Date: … Subject: …" header Outlook prepends to a
    /// quoted reply. We require all three labels close together to avoid
    /// tripping on a stray "From:" in prose, then back the cut up to the start
    /// of the enclosing block so we don't slice a tag in half.
    private static func outlookHeaderOffset(_ html: String) -> Int? {
        guard let re = try? NSRegularExpression(pattern: "(?is)\\bFrom:") else { return nil }
        let ns = html as NSString
        let full = NSRange(location: 0, length: ns.length)
        for m in re.matches(in: html, range: full) {
            let loc = m.range.location
            let window = ns.substring(with: NSRange(location: loc, length: min(1500, ns.length - loc)))
            let hasSent = window.range(of: "(?is)\\b(Sent|Date):", options: .regularExpression) != nil
            let hasSubject = window.range(of: "(?is)\\bSubject:", options: .regularExpression) != nil
            if hasSent && hasSubject {
                return blockStartBefore(html, loc)
            }
        }
        return nil
    }

    /// An "On <date>, <name> wrote:" preamble (Apple Mail / Gmail). Capped in
    /// length and required to end in "wrote:" to limit false positives.
    private static func onWroteOffset(_ html: String) -> Int? {
        guard let loc = firstMatchLocation(html, "(?is)\\bOn\\b[^<>]{1,200}?\\bwrote:") else { return nil }
        return blockStartBefore(html, loc)
    }

    /// Offset of the nearest block-level tag opening before `location`, so a cut
    /// lands on a tag boundary rather than inside text. Falls back to `location`.
    private static func blockStartBefore(_ html: String, _ location: Int) -> Int {
        let head = (html as NSString).substring(to: location)
        guard let re = try? NSRegularExpression(pattern: "(?is)<(div|p|table|hr|blockquote)\\b[^>]*>") else {
            return location
        }
        let headLen = (head as NSString).length
        let ms = re.matches(in: head, range: NSRange(location: 0, length: headLen))
        return ms.last?.range.location ?? location
    }

    private static func firstMatchLocation(_ html: String, _ pattern: String) -> Int? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let len = (html as NSString).length
        guard let m = re.firstMatch(in: html, range: NSRange(location: 0, length: len)) else { return nil }
        return m.range.location
    }
}
