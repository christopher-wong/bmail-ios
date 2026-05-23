import SwiftUI

@main
struct bmailApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(.light)
                .tint(Theme.ink)
        }
    }
}
