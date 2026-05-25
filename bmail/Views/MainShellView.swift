import SwiftUI
import UIKit

/// Root tab shell — five tabs, system Liquid Glass tab bar, deep-link sheet wiring.
struct MainShellView: View {
    @Environment(AppModel.self) private var app

    /// Pending hosted link forwarded from RootView's Universal Link / deep link handler.
    @Binding var pendingHostedLink: HostedLinkTarget?

    /// Pending secret link token forwarded from RootView.
    @Binding var pendingSecretToken: String?

    @State private var selectedTab: AppTab = .inbox
    @State private var net = NetworkMonitor.shared
    @State private var push = PushCenter.shared

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab(value: AppTab.inbox) {
                NavigationStack { InboxView() }
            } label: {
                tabLabel("Inbox", systemName: "tray.fill", color: .systemBlue)
            }

            Tab(value: AppTab.sent) {
                NavigationStack { SentView() }
            } label: {
                tabLabel("Sent", systemName: "paperplane.fill", color: .systemGreen)
            }

            Tab(value: AppTab.drafts) {
                NavigationStack { DraftsView() }
            } label: {
                tabLabel("Drafts", systemName: "doc.text", color: .systemOrange)
            }

            Tab(value: AppTab.search) {
                NavigationStack { SearchView() }
            } label: {
                tabLabel("Search", systemName: "magnifyingglass", color: .systemPurple)
            }

            Tab(value: AppTab.me) {
                NavigationStack { SettingsView() }
            } label: {
                tabLabel("Me", systemName: "person.crop.circle", color: .systemTeal)
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tabBarMinimizeBehavior(.onScrollDown)
        // Deep-link sheets — wiring from RootView must be preserved exactly.
        .sheet(item: $pendingHostedLink) { link in
            HostedView(token: link.token, cek: link.cek)
                .environment(app)
        }
        .sheet(item: Binding(
            get: { pendingSecretToken.map { SecretLinkToken(token: $0) } },
            set: { pendingSecretToken = $0?.token }
        )) { target in
            SecretLinkView(token: target.token)
                .environment(app)
        }
        .tint(.accentColor)
        // Status banner (offline) + in-app push toast share the top overlay slot.
        .safeAreaInset(edge: .top) {
            VStack(spacing: DS.Space.xs) {
                if !net.isOnline {
                    OfflineBanner()
                }
            }
            .animation(.snappy(duration: 0.22), value: net.isOnline)
        }
        .overlay(alignment: .top) {
            if let toast = push.currentToast {
                ToastView(payload: toast) {
                    push.dismissToast()
                }
                .padding(.horizontal, DS.Space.l)
                .padding(.top, DS.Space.s)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: toast.id) {
                    // Auto-dismiss after 4 seconds. Cancelled implicitly when
                    // a new toast replaces this one (different .task id).
                    try? await Task.sleep(for: .seconds(4))
                    if push.currentToast?.id == toast.id {
                        push.dismissToast()
                    }
                }
            }
        }
    }

    /// Pre-tinted SF Symbol via `UIImage` so the tab bar renders each icon in
    /// its own colour instead of one accent tint across all of them.
    private func tabLabel(_ title: String, systemName: String, color: UIColor) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(uiImage: tintedSymbol(systemName, color: color))
        }
    }
}

// MARK: - Tab identity

private enum AppTab: Hashable {
    case inbox, sent, drafts, search, me
}

// MARK: - Symbol tinting helper

/// Renders an SF Symbol pre-tinted to `color` and marks it `.alwaysOriginal`
/// so the tab bar doesn't repaint it with the active accent.
private func tintedSymbol(_ systemName: String, color: UIColor) -> UIImage {
    let base = UIImage(systemName: systemName) ?? UIImage()
    let cfg = UIImage.SymbolConfiguration(paletteColors: [color])
    let configured = base.applyingSymbolConfiguration(cfg) ?? base
    return configured.withRenderingMode(.alwaysOriginal)
}

// MARK: - Offline banner

private struct OfflineBanner: View {
    var body: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: "wifi.slash")
                .font(.footnote.weight(.semibold))
            Text("Offline — showing last loaded content")
                .font(.footnote.weight(.medium))
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.s)
        .background(Color.orange.opacity(0.92))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Offline. Showing last loaded content.")
    }
}

// MARK: - In-app toast

private struct ToastView: View {
    let payload: PushCenter.ToastPayload
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.m) {
            Image(systemName: "envelope.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(payload.title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if !payload.body.isEmpty {
                    Text(payload.body)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 0)

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss notification")
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.m)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .glassEdge(radius: DS.Radius.card)
        .shadow(color: .black.opacity(0.18), radius: 16, x: 0, y: 8)
        .onTapGesture {
            // Tap-to-dismiss for the whole toast; doesn't intercept the
            // explicit close button which already calls onDismiss.
            onDismiss()
        }
    }
}
