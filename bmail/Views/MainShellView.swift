import SwiftUI

/// Root tab shell — five tabs, system Liquid Glass tab bar, deep-link sheet wiring.
struct MainShellView: View {
    @Environment(AppModel.self) private var app

    /// Pending hosted link forwarded from RootView's Universal Link / deep link handler.
    @Binding var pendingHostedLink: HostedLinkTarget?

    /// Pending secret link token forwarded from RootView.
    @Binding var pendingSecretToken: String?

    @State private var selectedTab: AppTab = .inbox

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Inbox", systemImage: "tray.fill", value: AppTab.inbox) {
                NavigationStack { InboxView() }
            }

            Tab("Sent", systemImage: "paperplane.fill", value: AppTab.sent) {
                NavigationStack { SentView() }
            }

            Tab("Drafts", systemImage: "doc.text", value: AppTab.drafts) {
                NavigationStack { DraftsView() }
            }

            Tab("Search", systemImage: "magnifyingglass", value: AppTab.search) {
                NavigationStack { SearchPlaceholderView() }
            }

            Tab("Me", systemImage: "person.crop.circle", value: AppTab.me) {
                NavigationStack { SettingsView() }
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
    }
}

// MARK: - Tab identity

private enum AppTab: Hashable {
    case inbox, sent, drafts, search, me
}

// MARK: - Search placeholder

private struct SearchPlaceholderView: View {
    @State private var query = ""

    var body: some View {
        DSEmptyState(
            systemName: "magnifyingglass",
            title: "Search mail",
            hint: "Search is coming soon."
        )
        .navigationTitle("Search")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $query, prompt: "Search messages")
    }
}
