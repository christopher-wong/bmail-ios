import SwiftUI

/// Renders an HTML email body with a privacy-preserving remote-image gate and a
/// collapsible quoted-reply trail.
///
/// Remote images are blocked by default — opening a message shouldn't fire a
/// tracking pixel. When the user opts in (per-message, an allowlisted sender
/// domain, or the global default), the images are fetched through the worker
/// proxy and inlined as `data:` URIs, so the sender never sees the recipient's
/// IP and the WKWebView never makes a network request of its own.
///
/// The quoted reply history trailing the new message is detected and collapsed
/// behind a disclosure, so a thread shows what the sender just wrote rather than
/// the whole re-quoted chain.
struct MessageBodyView: View {
    let html: String
    let senderDomain: String

    // Computed once when the view is built — not on every @State change — so the
    // regex scans (remote-image detection, blocked-state rewrite, quote split)
    // don't re-run each render.
    private let remoteURLs: [String]
    private let blockedVisible: String
    private let blockedQuoted: String?

    @Environment(AppModel.self) private var app
    @State private var revealed = false
    @State private var didDecide = false
    @State private var loadedVisible: String?
    @State private var loadedQuoted: String?
    @State private var loading = false
    @State private var showQuoted = false

    init(html: String, senderDomain: String) {
        self.html = html
        self.senderDomain = senderDomain
        let urls = RemoteImages.remoteURLs(in: html)
        self.remoteURLs = urls
        // Neutralize remote images (transparent pixel) and any scheme the
        // sandboxed renderer can't load (cid:, relative), then split off the
        // quoted reply trail.
        let blocked = RemoteImages.rewrite(html) { _ in RemoteImages.blankPixel }
        let parts = QuotedText.split(blocked)
        self.blockedVisible = parts.visible
        self.blockedQuoted = parts.quoted
    }

    private var hasRemote: Bool { !remoteURLs.isEmpty }
    private var useLoaded: Bool { loadedVisible != nil }
    private var visibleHTML: String { loadedVisible ?? blockedVisible }
    private var quotedHTML: String? { useLoaded ? loadedQuoted : blockedQuoted }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            if hasRemote && !revealed {
                blockedBanner
            }

            HTMLBodyView(html: visibleHTML)

            if let quoted = quotedHTML {
                quotedDisclosure
                if showQuoted {
                    HTMLBodyView(html: quoted)
                }
            }
        }
        .task(id: revealed) { await react() }
    }

    private func react() async {
        if !revealed && !didDecide {
            didDecide = true
            if hasRemote && app.shouldAutoLoadImages(senderDomain: senderDomain) {
                revealed = true // re-triggers this task with revealed == true
                return
            }
        }
        if revealed { await inlineImages() }
    }

    private func inlineImages() async {
        guard loadedVisible == nil, !loading else { return }
        loading = true
        defer { loading = false }

        var map: [String: String] = [:]
        await withTaskGroup(of: (String, String?).self) { group in
            for u in remoteURLs {
                group.addTask {
                    (u, try? await APIClient.shared.proxyImageDataURI(remoteURL: u))
                }
            }
            for await (u, dataURI) in group where dataURI != nil {
                map[u] = dataURI
            }
        }
        let full = RemoteImages.rewrite(html) { url in map[url] ?? RemoteImages.blankPixel }
        let parts = QuotedText.split(full)
        loadedVisible = parts.visible
        loadedQuoted = parts.quoted
    }

    // MARK: - Quoted-reply disclosure

    private var quotedDisclosure: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { showQuoted.toggle() }
        } label: {
            Image(systemName: showQuoted ? "chevron.up" : "ellipsis")
                .font(.footnote.weight(.bold))
                .foregroundStyle(.secondary)
                .frame(width: 38, height: 24)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().stroke(Color(.separator), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(showQuoted ? "Hide quoted text" : "Show quoted text")
        .padding(.vertical, 2)
    }

    // MARK: - Remote-image banner

    private var blockedBanner: some View {
        HStack(alignment: .center, spacing: DS.Space.s) {
            Image(systemName: "eye.slash.fill")
                .font(.footnote)
                .foregroundStyle(DS.Color.inkFaint)

            VStack(alignment: .leading, spacing: 1) {
                Text("Images hidden")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.primary)
                Text("Protects your location from the sender")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: DS.Space.s)

            Menu {
                Button {
                    revealed = true
                } label: {
                    Label("Load images once", systemImage: "photo")
                }
                if !senderDomain.isEmpty {
                    Button {
                        revealed = true
                        Task { await app.allowImageDomain(senderDomain) }
                    } label: {
                        Label("Always load from \(senderDomain)", systemImage: "checkmark.shield")
                    }
                }
            } label: {
                Text("Load images")
                    .font(.footnote.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .tint(.accentColor)
            .fixedSize()
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, DS.Space.s)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
    }
}
