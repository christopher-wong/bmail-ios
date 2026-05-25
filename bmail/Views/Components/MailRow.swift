import SwiftUI

/// Shared mail-list row used by InboxView, SentView, and DraftsView.
///
/// Renders the four-region layout from the Liquid Glass style guide:
/// leading avatar · sender/subject/snippet · trailing timestamp.
/// Unread state drives the 8pt accent dot and semibold sender weight.
struct MailRow: View {
    /// Sender (inbox) or recipient(s) (sent/drafts).
    let primary: String
    let subject: String?
    let snippet: String?
    /// Unix-millisecond timestamp.
    let timestamp: Int64?
    let unread: Bool
    /// Show paperclip glyph in trailing meta.
    let attachments: Bool
    /// Show star glyph in trailing meta.
    let starred: Bool

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.m) {
            // MARK: Avatar
            DSAvatar(initials: initials(from: primary), size: .row)
                .overlay(alignment: .topLeading) {
                    if unread {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 8, height: 8)
                            .offset(x: -2, y: -2)
                    }
                }

            // MARK: Content stack
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.xs) {
                    Text(primary)
                        .font(.callout.weight(unread ? .semibold : .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Spacer(minLength: DS.Space.xs)

                    // Trailing meta: timestamp + optional glyphs
                    HStack(spacing: DS.Space.xs) {
                        if starred {
                            Image(systemName: "star.fill")
                                .font(.caption2)
                                .foregroundStyle(Color.accentColor)
                        }
                        if attachments {
                            Image(systemName: "paperclip")
                                .font(.caption2)
                                .foregroundStyle(DS.Color.inkFaint)
                        }
                        if let ts = timestamp {
                            Text(RelativeDate.format(ts))
                                .font(.footnote.monospacedDigit())
                                .foregroundStyle(DS.Color.inkFaint)
                        }
                    }
                }

                if let subj = subject, !subj.isEmpty {
                    Text(subj)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                } else {
                    Text("(no subject)")
                        .font(.subheadline)
                        .foregroundStyle(DS.Color.inkFaint)
                        .lineLimit(1)
                }

                if let snip = snippet, !snip.isEmpty {
                    Text(snip)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
            }
        }
        .padding(.vertical, DS.Space.s)
        .accessibilityElement(children: .combine)
    }

    // MARK: Private helpers

    /// Up to two initials from the first word(s) of an address or name.
    private func initials(from raw: String) -> String {
        // Strip angle-bracket address form: "Alice B <alice@example.com>" → "Alice B"
        let name: String
        if let lt = raw.firstIndex(of: "<") {
            name = String(raw[raw.startIndex..<lt]).trimmingCharacters(in: .whitespaces)
        } else {
            name = raw
        }
        // Use local part of bare email: alice@example.com → "A"
        let parts = name.split(separator: " ").map(String.init)
        if parts.count >= 2,
           let f = parts[0].first,
           let s = parts[1].first {
            return "\(f)\(s)".uppercased()
        }
        let localPart = name.split(separator: "@").first.map(String.init) ?? name
        return String(localPart.prefix(2)).uppercased()
    }
}

#if DEBUG
#Preview("MailRow — unread") {
    List {
        MailRow(
            primary: "Addison Jakubowicz",
            subject: "Series A close — final docs",
            snippet: "Wire instructions and signed SAFEs attached. Let's sync Friday.",
            timestamp: Int64(Date().timeIntervalSince1970 * 1000),
            unread: true,
            attachments: true,
            starred: false
        )
        MailRow(
            primary: "Kristy Tan",
            subject: "Mendocino weekend?",
            snippet: "Found a place with a hot tub and no cell service.",
            timestamp: Int64(Date().addingTimeInterval(-86400).timeIntervalSince1970 * 1000),
            unread: false,
            attachments: false,
            starred: true
        )
    }
    .listStyle(.insetGrouped)
    .background(Wallpaper())
    .scrollContentBackground(.hidden)
}
#endif
