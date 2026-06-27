import SwiftUI

/// Renders an HTML email body with a privacy-preserving remote-image gate.
///
/// Remote images are blocked by default — opening a message shouldn't fire a
/// tracking pixel. When the user opts in (per-message, an allowlisted sender
/// domain, or the global default), the images are fetched through the worker
/// proxy and inlined as `data:` URIs, so the sender never sees the recipient's
/// IP and the WKWebView never makes a network request of its own.
struct MessageBodyView: View {
    let html: String
    let senderDomain: String

    // Computed once when the view is built — not on every @State change — so
    // the regex scan and the blocked-state rewrite don't re-run each render.
    private let remoteURLs: [String]
    private let blockedHTML: String

    @Environment(AppModel.self) private var app
    @State private var revealed = false
    @State private var didDecide = false
    @State private var loadedHTML: String?
    @State private var loading = false

    init(html: String, senderDomain: String) {
        self.html = html
        self.senderDomain = senderDomain
        let urls = RemoteImages.remoteURLs(in: html)
        self.remoteURLs = urls
        // Blocked view neutralizes remote images so we render neither
        // broken-image glyphs nor an actual remote load.
        self.blockedHTML = urls.isEmpty
            ? html
            : RemoteImages.rewrite(html) { _ in RemoteImages.blankPixel }
    }

    private var hasRemote: Bool { !remoteURLs.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            if hasRemote && !revealed {
                blockedBanner
            }
            HTMLBodyView(html: loadedHTML ?? blockedHTML)
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
        guard loadedHTML == nil, !loading else { return }
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
        loadedHTML = RemoteImages.rewrite(html) { url in map[url] ?? RemoteImages.blankPixel }
    }

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
