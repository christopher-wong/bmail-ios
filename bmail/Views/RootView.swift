import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ZStack {
            switch app.phase {
            case .bootstrap:
                BootstrapView()
            case .unauthenticated:
                LoginView()
            case .authenticated:
                MainShellView()
            }
        }
        .task {
            if app.phase == .bootstrap { await app.bootstrap() }
        }
    }
}

private struct BootstrapView: View {
    var body: some View {
        VStack(spacing: 20) {
            Text("CFEMAIL")
                .font(.mono(16, .bold))
                .tracking(2)
            ProgressView()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.inverseInk)
    }
}
