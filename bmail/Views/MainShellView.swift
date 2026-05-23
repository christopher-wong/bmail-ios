import SwiftUI

enum MailboxSection: String, Hashable, CaseIterable, Identifiable {
    case inbox = "INBOX"
    case drafts = "DRAFTS"
    case sent = "SENT"
    case labels = "LABELS"
    case settings = "SETTINGS"
    case admin = "ADMIN"

    var id: String { rawValue }
    var requiresAdmin: Bool { self == .admin }

    var systemImage: String {
        switch self {
        case .inbox:    return "tray"
        case .drafts:   return "doc.text"
        case .sent:     return "paperplane"
        case .labels:   return "tag"
        case .settings: return "gearshape"
        case .admin:    return "person.crop.circle"
        }
    }
}

struct MainShellView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var section: MailboxSection = .inbox
    @State private var showCompose = false

    /// Tab order — INBOX sits in the middle. Drafts is no longer a tab; it
    /// lives inside the compose sheet (tap COMPOSE → "DRAFTS" to resume).
    var visibleSections: [MailboxSection] {
        var s: [MailboxSection] = [.sent, .labels, .inbox, .settings]
        if app.me?.is_admin == true { s.append(.admin) }
        return s
    }

    var body: some View {
        TabView(selection: $section) {
            Tab(MailboxSection.sent.rawValue, systemImage: MailboxSection.sent.systemImage, value: MailboxSection.sent) {
                SentView()
            }
            Tab(MailboxSection.labels.rawValue, systemImage: MailboxSection.labels.systemImage, value: MailboxSection.labels) {
                LabelsView()
            }
            Tab(MailboxSection.inbox.rawValue, systemImage: MailboxSection.inbox.systemImage, value: MailboxSection.inbox) {
                InboxView()
            }
            Tab(MailboxSection.settings.rawValue, systemImage: MailboxSection.settings.systemImage, value: MailboxSection.settings) {
                SettingsView()
            }
            if app.me?.is_admin == true {
                Tab(MailboxSection.admin.rawValue, systemImage: MailboxSection.admin.systemImage, value: MailboxSection.admin) {
                    AdminView()
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tabBarMinimizeBehavior(.onScrollDown)
        // Insets the FAB above the tab bar's safe-area inset so it floats
        // just above the floating glass tab bar without overlapping it.
        .safeAreaInset(edge: .bottom, alignment: .trailing, spacing: 0) {
            ComposeFAB(showCompose: $showCompose)
                .padding(.trailing, 20)
                .padding(.bottom, 10)
        }
        .sheet(isPresented: $showCompose) { ComposeView() }
        .tint(Theme.ink)
        .gesture(swipeBetweenTabs)
    }

    // Horizontal-only swipe between adjacent tabs. Tight thresholds so it
    // doesn't compete with intrinsic vertical scrolls inside section views.
    private var swipeBetweenTabs: some Gesture {
        DragGesture(minimumDistance: 30)
            .onEnded { value in
                let dx = value.translation.width
                let dy = value.translation.height
                guard abs(dx) > 60, abs(dx) > abs(dy) * 2 else { return }
                let order = visibleSections
                guard let idx = order.firstIndex(of: section) else { return }
                let advance: () -> Void
                if dx < 0, idx < order.count - 1 {
                    advance = { section = order[idx + 1] }
                } else if dx > 0, idx > 0 {
                    advance = { section = order[idx - 1] }
                } else {
                    return
                }
                if reduceMotion {
                    advance()
                } else {
                    withAnimation(.snappy, advance)
                }
            }
    }
}

private struct ComposeFAB: View {
    @Binding var showCompose: Bool
    /// FAB size scales modestly with Dynamic Type so it stays
    /// proportional, capped so it doesn't take over the screen at AX5.
    @ScaledMetric(relativeTo: .title2) private var diameter: CGFloat = 58

    var body: some View {
        Button {
            showCompose = true
        } label: {
            Image(systemName: "square.and.pencil")
                .font(.system(.title3, design: .default).weight(.semibold))
                .foregroundStyle(Theme.ink)
                .frame(width: min(diameter, 96), height: min(diameter, 96))
                .accessibilityHidden(true)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .accessibilityLabel("Compose")
        .accessibilityAddTraits(.isButton)
    }
}
